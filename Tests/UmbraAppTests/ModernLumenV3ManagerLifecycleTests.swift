import CryptoKit
import Foundation
import XCTest
import UmbraCore
import UmbraIntegration
import UmbraMedia
import UmbraMicrophone
import UmbraNetworking
import UmbraPlatform
import UmbraProtocolV3
import UmbraQUICTransport
import UmbraServices
import UmbraStreaming
@testable import UmbraApp

@MainActor
final class ModernLumenV3ManagerLifecycleTests: XCTestCase {
    func testStopWithoutRetainedSessionFailsClosed() async throws {
        let fixture = try makeFixture(applications: [])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            try await fixture.manager.stopSession(quitApplication: false)
            XCTFail("STOP without retained session must fail closed.")
        } catch let error as ProtocolV3ClientError {
            XCTAssertEqual(error, .invalidState)
        }
    }

    func testControlKeepalivePolicyRequiresEchoedProbeAndOrderedHostTimes() {
        let fields = ProtocolV3ControlKeepalivePolicy.requestFields(
            clientSendNanoseconds: 100,
            probe: 7
        )
        XCTAssertEqual(fields, [1: .unsigned(100), 2: .unsigned(7)])
        XCTAssertTrue(ProtocolV3ControlKeepalivePolicy.acceptsResponse(
            [
                1: .unsigned(100), 2: .unsigned(7),
                3: .unsigned(200), 4: .unsigned(201),
            ],
            clientSendNanoseconds: 100,
            probe: 7
        ))
        XCTAssertFalse(ProtocolV3ControlKeepalivePolicy.acceptsResponse(
            [
                1: .unsigned(100), 2: .unsigned(8),
                3: .unsigned(200), 4: .unsigned(201),
            ],
            clientSendNanoseconds: 100,
            probe: 7
        ))
        XCTAssertFalse(ProtocolV3ControlKeepalivePolicy.acceptsResponse(
            [
                1: .unsigned(100), 2: .unsigned(7),
                3: .unsigned(202), 4: .unsigned(201),
            ],
            clientSendNanoseconds: 100,
            probe: 7
        ))
    }

    private enum HostileConfiguration {
        case wrongVideoSession
        case wrongAudioGeneration
    }
    func testApplicationListResponsePersistsTheAuthoritativeCatalog() async throws {
        let fixture = try makeFixture(applications: [])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let refresh = Task { @MainActor in
            try await fixture.manager.refreshApplications(hostID: fixture.displayHostID, mode: .quality)
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)
        let request = try await transport.controlRequest(type: 0x0200)
        transport.receive(
            type: 0x0201,
            requestID: request.requestID,
            flags: 1,
            fields: applicationPageFields(),
            codec: fixture.codec
        )

        let applications = try await refresh.value
        XCTAssertEqual(applications.map(\.name), ["Desktop", "Steam Big Picture"])
        XCTAssertEqual(applications.map(\.isRunning), [false, true])
        XCTAssertEqual(try fixture.catalog.host(hostID: fixture.hostID)?.applicationRevision, 9)
        XCTAssertEqual(
            try fixture.catalog.host(hostID: fixture.hostID)?.runningApplicationID,
            2
        )
        await fixture.manager.stopAll()
    }

    func testApplicationListRejectsTwoRunningAppsAcrossDifferentPages() async throws {
        let fixture = try makeFixture(applications: [])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refresh = Task { @MainActor in
            try await fixture.manager.refreshApplications(hostID: fixture.displayHostID, mode: .quality)
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)
        let first = try await transport.controlRequest(type: 0x0200)
        transport.receive(
            type: 0x0201,
            requestID: first.requestID,
            flags: 1,
            fields: applicationPageFields(
                revision: 9,
                applications: (1...128).map {
                    applicationEntry(id: UInt64($0), name: "Application \($0)", state: $0 == 1 ? 2 : 0)
                },
                nextCursor: 128
            ),
            codec: fixture.codec
        )
        let second = try await transport.controlRequest(type: 0x0200, ordinal: 1)
        transport.receive(
            type: 0x0201,
            requestID: second.requestID,
            flags: 1,
            fields: applicationPageFields(
                revision: 9,
                applications: [applicationEntry(id: 129, name: "Second Running", state: 2)],
                nextCursor: nil
            ),
            codec: fixture.codec
        )
        do {
            _ = try await refresh.value
            XCTFail("Expected cross-page running-state collision rejection.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("application-list running state"))
        }
        XCTAssertTrue(try fixture.catalog.host(hostID: fixture.hostID)?.applications.isEmpty == true)
        await fixture.manager.stopAll()
    }

    func testApplicationListRestartsOnceWhenHostSnapshotChangesDuringPagination() async throws {
        let fixture = try makeFixture(applications: [])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refresh = Task { @MainActor in
            try await fixture.manager.refreshApplications(hostID: fixture.displayHostID, mode: .quality)
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)

        let first = try await transport.controlRequest(type: 0x0200)
        transport.receive(
            type: 0x0201,
            requestID: first.requestID,
            flags: 1,
            fields: applicationPageFields(
                revision: 9,
                applications: (1...128).map {
                    applicationEntry(id: UInt64($0), name: "Application \($0)", state: 0)
                },
                nextCursor: 128
            ),
            codec: fixture.codec
        )
        let stalePage = try await transport.controlRequest(type: 0x0200, ordinal: 1)
        transport.receive(
            type: 0x0201,
            requestID: stalePage.requestID,
            flags: 1,
            fields: applicationPageFields(
                revision: 10,
                applications: [],
                nextCursor: nil,
                status: 8
            ),
            codec: fixture.codec
        )

        let restarted = try await transport.controlRequest(type: 0x0200, ordinal: 2)
        let restartedFields = try decodeFields(restarted.request.payload, codec: fixture.codec)
        XCTAssertEqual(restartedFields[1]?.unsignedValue, 0)
        transport.receive(
            type: 0x0201,
            requestID: restarted.requestID,
            flags: 1,
            fields: applicationPageFields(
                revision: 10,
                applications: [applicationEntry(id: 200, name: "Fresh Snapshot", state: 0)],
                nextCursor: nil
            ),
            codec: fixture.codec
        )

        let applications = try await refresh.value
        XCTAssertEqual(applications.map(\.name), ["Fresh Snapshot"])
        XCTAssertEqual(try fixture.catalog.host(hostID: fixture.hostID)?.applicationRevision, 10)
        await fixture.manager.stopAll()
    }

    func testNotModifiedApplicationListPreservesOneValidatedRunningApplication() async throws {
        let cached = [ModernLumenV3ApplicationRecord(
            id: 1,
            name: "Running",
            isRunning: true,
            artworkSHA256: nil,
            isHidden: false,
            isDirectLaunch: false
        )]
        let fixture = try makeFixture(applications: cached)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refresh = Task { @MainActor in
            try await fixture.manager.refreshApplications(hostID: fixture.displayHostID, mode: .quality)
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)
        let request = try await transport.controlRequest(type: 0x0200)
        transport.receive(
            type: 0x0201,
            requestID: request.requestID,
            flags: 1,
            fields: applicationPageFields(
                revision: 1,
                applications: [],
                nextCursor: nil,
                notModified: true
            ),
            codec: fixture.codec
        )
        let result = try await refresh.value
        XCTAssertEqual(result.map(\.name), ["Running"])
        XCTAssertEqual(result.filter(\.isRunning).count, 1)
        await fixture.manager.stopAll()
    }

    func testLaunchWaitsForBothConfigurationACKsBeforeStreamingAndStopCompletes() async throws {
        let lifecycle = RecordingManagerLifecycle()
        let output = RecordingManagerOutput()
        let fixture = try makeFixture(
            applications: [ModernLumenV3ApplicationRecord(
                id: 1,
                name: "Desktop",
                isRunning: false,
                artworkSHA256: nil,
                isHidden: false,
                isDirectLaunch: false
            )],
            lifecycle: lifecycle,
            output: output
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = LockedManagerValues<UmbraClientEvent>()
        fixture.manager.setSessionEventHandler { events.append($0) }

        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1),
                hostID: fixture.displayHostID,
                resume: false,
                preferences: .default,
                activationUptime: 1
            )
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)
        let start = try await transport.controlRequest(type: 0x0100)
        let preparedEvents = await lifecycle.snapshot()
        XCTAssertEqual(preparedEvents, [.prepare])

        let offer = try decodeFields(start.request.payload, codec: fixture.codec)
        let selection = successfulStartResponse(offer)
        transport.receive(
            type: 0x0101,
            requestID: start.requestID,
            flags: 1,
            fields: selection,
            codec: fixture.codec
        )
        transport.receive(
            type: 0x0140,
            requestID: 2,
            flags: 0,
            fields: videoConfigurationFields(selection),
            codec: fixture.codec
        )
        _ = try await transport.controlRequest(type: 0x0141)
        await eventually { await lifecycle.snapshot() == [.prepare, .updatePreparation] }
        let beforeAudioEvents = await lifecycle.snapshot()
        XCTAssertFalse(beforeAudioEvents.contains(.commitStreaming))
        XCTAssertFalse(events.values.contains { if case .sessionStreaming = $0 { true } else { false } })

        transport.receive(
            type: 0x0142,
            requestID: 4,
            flags: 0,
            fields: audioConfigurationFields(selection),
            codec: fixture.codec
        )
        _ = try await transport.controlRequest(type: 0x0143)
        try await launch.value
        let streamingEvents = await lifecycle.snapshot()
        XCTAssertEqual(streamingEvents, [.prepare, .updatePreparation, .commitStreaming])
        XCTAssertEqual(output.beginCount, 1)
        XCTAssertTrue(events.values.contains { if case .sessionStreaming = $0 { true } else { false } })

        let stop = Task { @MainActor in
            try await fixture.manager.stopSession(quitApplication: false)
        }
        let stopRequest = try await transport.controlRequest(type: 0x0130)
        let stopFields = try decodeFields(stopRequest.request.payload, codec: fixture.codec)
        transport.receive(
            type: 0x0131,
            requestID: stopRequest.requestID,
            flags: 1,
            fields: [
                1: .unsigned(0),
                2: selection[3]!,
                3: stopFields[4]!,
                4: .boolean(false),
            ],
            codec: fixture.codec
        )
        transport.receive(
            type: 0x0133,
            requestID: 0,
            flags: 0,
            fields: sessionEndedFields(sessionID: selection[3]!.bytesValue!),
            codec: fixture.codec
        )
        transport.emit(.mediaSessionEnded("concurrent terminal notification"))
        try await stop.value
        await eventually { output.endCount == 1 }
        let stoppedEvents = await lifecycle.snapshot()
        XCTAssertEqual(Array(stoppedEvents.suffix(2)), [.finishPresentation, .finish])
        XCTAssertEqual(output.endCount, 1)
        await fixture.manager.stopAll()
    }

    func testMissingConfigurationACKTimesOutAndClosesTheAcceptedSession() async throws {
        let lifecycle = RecordingManagerLifecycle()
        let fixture = try makeFixture(
            applications: [ModernLumenV3ApplicationRecord(
                id: 1,
                name: "Desktop",
                isRunning: false,
                artworkSHA256: nil,
                isHidden: false,
                isDirectLaunch: false
            )],
            lifecycle: lifecycle,
            configurationBarrierTimeout: .milliseconds(40)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1),
                hostID: fixture.displayHostID,
                resume: false,
                preferences: .default,
                activationUptime: 1
            )
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)
        let start = try await transport.controlRequest(type: 0x0100)
        let offer = try decodeFields(start.request.payload, codec: fixture.codec)
        transport.receive(
            type: 0x0101,
            requestID: start.requestID,
            flags: 1,
            fields: successfulStartResponse(offer),
            codec: fixture.codec
        )
        transport.receive(
            type: 0x0140,
            requestID: 2,
            flags: 0,
            fields: videoConfigurationFields(successfulStartResponse(offer)),
            codec: fixture.codec
        )
        _ = try await transport.controlRequest(type: 0x0141)

        do {
            try await launch.value
            XCTFail("Expected the missing configuration acknowledgement to fail closed.")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("VIDEO_CONFIG"), error.localizedDescription)
            XCTAssertTrue(
                error.localizedDescription.contains("AUDIO_CONFIG"),
                error.localizedDescription
            )
        }
        await eventually { transport.cancelCount == 1 }
        let failedEvents = await lifecycle.snapshot()
        XCTAssertEqual(Array(failedEvents.suffix(2)), [.finishPresentation, .finish])
    }

    func testCancellationDuringConfigurationWaitPropagatesAndNeverInstallsInput() async throws {
        let lifecycle = RecordingManagerLifecycle()
        let fixture = try makeFixture(
            applications: [ModernLumenV3ApplicationRecord(
                id: 1,
                name: "Desktop",
                isRunning: false,
                artworkSHA256: nil,
                isHidden: false,
                isDirectLaunch: false
            )],
            lifecycle: lifecycle,
            configurationBarrierTimeout: .seconds(1)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clientEvents = LockedManagerValues<UmbraClientEvent>()
        fixture.manager.setSessionEventHandler { clientEvents.append($0) }
        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1),
                hostID: fixture.displayHostID,
                resume: false,
                preferences: .default,
                activationUptime: 1
            )
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)
        let start = try await transport.controlRequest(type: 0x0100)
        let offer = try decodeFields(start.request.payload, codec: fixture.codec)
        let selection = successfulStartResponse(offer)
        transport.receive(
            type: 0x0101,
            requestID: start.requestID,
            flags: 1,
            fields: selection,
            codec: fixture.codec
        )
        transport.receive(
            type: 0x0140,
            requestID: 2,
            flags: 0,
            fields: videoConfigurationFields(selection),
            codec: fixture.codec
        )
        _ = try await transport.controlRequest(type: 0x0141)
        XCTAssertFalse(fixture.inputInstaller.installations.contains(true))

        launch.cancel()
        do {
            try await launch.value
            XCTFail("Expected configuration wait cancellation.")
        } catch {
            XCTAssertTrue(error is CancellationError, error.localizedDescription)
        }
        await eventually { transport.cancelCount == 1 }
        XCTAssertFalse(fixture.inputInstaller.installations.contains(true))
        let cancelledLifecycle = await lifecycle.snapshot()
        XCTAssertFalse(cancelledLifecycle.contains(.commitStreaming))

        transport.receive(
            type: 0x0142,
            requestID: 4,
            flags: 0,
            fields: audioConfigurationFields(selection),
            codec: fixture.codec
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(fixture.inputInstaller.installations.contains(true))
        let afterLateConfiguration = await lifecycle.snapshot()
        XCTAssertFalse(afterLateConfiguration.contains(.commitStreaming))
        XCTAssertFalse(clientEvents.values.contains {
            if case .sessionFailed = $0 { true } else { false }
        })
    }

    func testConfigurationBarrierRejectsWrongSessionAndGenerationCollisions() async throws {
        try await assertHostileConfigurationRejected(.wrongVideoSession)
        try await assertHostileConfigurationRejected(.wrongAudioGeneration)
    }

    func testOptionalSelectedMicrophoneConfigurationRemainsPartOfTheBarrier() async throws {
        let capture = ManagerMicrophoneCapture()
        let fixture = try makeFixture(
            applications: [ModernLumenV3ApplicationRecord(
                id: 1,
                name: "Desktop",
                isRunning: false,
                artworkSHA256: nil,
                isHidden: false,
                isDirectLaunch: false
            )],
            grantedPermissions: 0x1f,
            microphoneAuthorization: ManagerMicrophoneAuthorization(.authorized),
            microphoneCaptureFactory: ManagerMicrophoneCaptureFactory(capture: capture)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var preferences = StreamingPreferences.default
        preferences.clientMicrophoneEnabled = true
        preferences.clientMicrophoneRequired = false
        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1),
                hostID: fixture.displayHostID,
                resume: false,
                preferences: preferences,
                activationUptime: 1
            )
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)
        let start = try await transport.controlRequest(type: 0x0100)
        let offer = try decodeFields(start.request.payload, codec: fixture.codec)
        let selection = successfulStartResponse(offer, selectMicrophone: true)
        transport.receive(
            type: 0x0101,
            requestID: start.requestID,
            flags: 1,
            fields: selection,
            codec: fixture.codec
        )
        transport.receive(
            type: 0x0140,
            requestID: 2,
            flags: 0,
            fields: videoConfigurationFields(selection),
            codec: fixture.codec
        )
        transport.receive(
            type: 0x0142,
            requestID: 4,
            flags: 0,
            fields: audioConfigurationFields(selection),
            codec: fixture.codec
        )
        _ = try await transport.controlRequest(type: 0x0141)
        _ = try await transport.controlRequest(type: 0x0143)
        XCTAssertFalse(fixture.inputInstaller.installations.contains(true))

        transport.receive(
            type: 0x0144,
            requestID: 6,
            flags: 0,
            fields: microphoneConfigurationFields(selection),
            codec: fixture.codec
        )
        _ = try await transport.controlRequest(type: 0x0145)
        try await launch.value
        XCTAssertTrue(fixture.inputInstaller.installations.contains(true))
        XCTAssertGreaterThanOrEqual(capture.startCount, 2)
        transport.emit(.mediaSessionEnded("test teardown"))
        await eventually { fixture.inputInstaller.installations.last == false }
        await fixture.manager.stopAll()
    }

    func testReconnectRetriesStableATTACHAndWithholdsInputUntilINPUTRESET() async throws {
        let fixture = try makeFixture(
            applications: [ModernLumenV3ApplicationRecord(
                id: 1,
                name: "Desktop",
                isRunning: false,
                artworkSHA256: nil,
                isHidden: false,
                isDirectLaunch: false
            )],
            recoveryPhaseTimeouts: .init(
                authentication: .milliseconds(200),
                activeSessionAnnouncement: .milliseconds(100),
                attachResponse: .milliseconds(120),
                inputResetResponse: .milliseconds(100)
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1),
                hostID: fixture.displayHostID,
                resume: false,
                preferences: .default,
                activationUptime: 1
            )
        }
        let firstTransport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: firstTransport)
        let start = try await firstTransport.controlRequest(type: 0x0100)
        let offer = try decodeFields(start.request.payload, codec: fixture.codec)
        let selection = successfulStartResponse(offer)
        firstTransport.receive(
            type: 0x0101,
            requestID: start.requestID,
            flags: 1,
            fields: selection,
            codec: fixture.codec
        )
        firstTransport.receive(
            type: 0x0140,
            requestID: 2,
            flags: 0,
            fields: videoConfigurationFields(selection),
            codec: fixture.codec
        )
        firstTransport.receive(
            type: 0x0142,
            requestID: 4,
            flags: 0,
            fields: audioConfigurationFields(selection),
            codec: fixture.codec
        )
        _ = try await firstTransport.controlRequest(type: 0x0141)
        _ = try await firstTransport.controlRequest(type: 0x0143)
        try await launch.value
        XCTAssertEqual(fixture.inputInstaller.installations, [true])

        firstTransport.emit(.stateChanged(.failed("injected reconnect")))
        let replacement = try await fixture.factory.waitForTransport(ordinal: 1)
        await eventually { fixture.inputInstaller.installations == [true, false] }
        try await authenticate(
            fixture,
            transport: replacement,
            activeSessionID: selection[3]!.bytesValue!
        )
        let firstAttach = try await replacement.controlRequest(type: 0x0102)
        let retriedAttach = try await replacement.controlRequest(type: 0x0102, ordinal: 1)
        XCTAssertEqual(firstAttach.request.payload, retriedAttach.request.payload)
        let attachFields = try decodeFields(retriedAttach.request.payload, codec: fixture.codec)
        replacement.receive(
            type: 0x0103,
            requestID: retriedAttach.requestID,
            flags: 1,
            fields: [
                1: .unsigned(0),
                2: selection[3]!,
                3: .unsigned(2),
                4: .unsigned(2),
                5: .boolean(true),
                6: .map([1: .unsigned(1), 2: .unsigned(1), 3: .unsigned(1)]),
            ],
            codec: fixture.codec
        )
        let inputReset = try await replacement.controlRequest(type: 0x0120)
        XCTAssertEqual(fixture.inputInstaller.installations, [true, false])
        XCTAssertEqual(attachFields[1], selection[3])
        replacement.receive(
            type: 0x0121,
            requestID: inputReset.requestID,
            flags: 1,
            fields: [1: .unsigned(0), 2: .unsigned(2)],
            codec: fixture.codec
        )
        await eventually { fixture.inputInstaller.installations == [true, false, true] }
        replacement.emit(.stateChanged(.failed("second injected reconnect")))
        let delayedReplacement = try await fixture.factory.waitForTransport(ordinal: 2)
        await eventually { fixture.inputInstaller.installations == [true, false, true, false] }
        try await authenticate(
            fixture,
            transport: delayedReplacement,
            activeSessionID: selection[3]!.bytesValue!
        )
        let delayedAttach = try await delayedReplacement.controlRequest(type: 0x0102)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(delayedReplacement.controlRequestCount(type: 0x0102), 1)
        delayedReplacement.receive(
            type: 0x0103,
            requestID: delayedAttach.requestID,
            flags: 1,
            fields: [
                1: .unsigned(0), 2: selection[3]!, 3: .unsigned(3),
                4: .unsigned(3), 5: .boolean(true),
                6: .map([1: .unsigned(1), 2: .unsigned(1), 3: .unsigned(1)]),
            ],
            codec: fixture.codec
        )
        let delayedInputReset = try await delayedReplacement.controlRequest(type: 0x0120)
        delayedReplacement.receive(
            type: 0x0121,
            requestID: delayedInputReset.requestID,
            flags: 1,
            fields: [1: .unsigned(0), 2: .unsigned(3)],
            codec: fixture.codec
        )
        await eventually {
            fixture.inputInstaller.installations == [true, false, true, false, true]
        }
        delayedReplacement.emit(.mediaSessionEnded("test teardown"))
        await eventually { fixture.inputInstaller.installations.last == false }
        await fixture.manager.stopAll()
    }

    func testBusySTARTRejectionReachesTheManagerCallerWithAnActionableCause() async throws {
        let fixture = try makeFixture(applications: [ModernLumenV3ApplicationRecord(
            id: 1,
            name: "Desktop",
            isRunning: false,
            artworkSHA256: nil,
            isHidden: false,
            isDirectLaunch: false
        )])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1),
                hostID: fixture.displayHostID,
                resume: false,
                preferences: .default,
                activationUptime: 1
            )
        }
        for attempt in 0..<3 {
            let transport = try await fixture.factory.waitForTransport(ordinal: attempt)
            try await authenticate(fixture, transport: transport)
            let start = try await transport.controlRequest(type: 0x0100)
            let offer = try decodeFields(start.request.payload, codec: fixture.codec)
            transport.receive(
                type: 0x0101,
                requestID: start.requestID,
                flags: 1,
                fields: failedStartResponse(status: 8, intent: offer[1]!),
                codec: fixture.codec
            )
        }

        do {
            try await launch.value
            XCTFail("Expected Lumen's busy status to reject START.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("busy with another stream"))
            XCTAssertTrue(error.localizedDescription.contains("status 8"))
            XCTAssertTrue(error.localizedDescription.contains("stop the active stream or wait"))
        }
    }

    func testControlOnlyConnectionRejectsLaunchBeforePreparationOrSTARTButStillBrowses() async throws {
        let lifecycle = RecordingManagerLifecycle()
        let output = RecordingManagerOutput()
        let fixture = try makeFixture(
            applications: [ModernLumenV3ApplicationRecord(
                id: 1,
                name: "Desktop",
                isRunning: false,
                artworkSHA256: nil,
                isHidden: false,
                isDirectLaunch: false
            )],
            lifecycle: lifecycle,
            output: output,
            initialDatagramPayloadByteCount: 0
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1),
                hostID: fixture.displayHostID,
                resume: false,
                preferences: .default,
                activationUptime: 1
            )
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)

        do {
            try await launch.value
            XCTFail("Expected a control-only QUIC connection to reject streaming.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("requires QUIC DATAGRAM support"))
            XCTAssertTrue(error.localizedDescription.contains("control streams only"))
            XCTAssertTrue(error.localizedDescription.contains("no stream was started"))
        }
        XCTAssertEqual(transport.controlRequestCount(type: 0x0100), 0)
        XCTAssertTrue(transport.activeSessionMutations.isEmpty)
        let lifecycleEvents = await lifecycle.snapshot()
        XCTAssertTrue(lifecycleEvents.isEmpty)
        XCTAssertEqual(output.beginCount, 0)
        XCTAssertNil(try fixture.catalog.host(hostID: fixture.hostID)?.runningApplicationID)

        let refresh = Task { @MainActor in
            try await fixture.manager.refreshApplications(hostID: fixture.displayHostID, mode: .quality)
        }
        let browse = try await transport.controlRequest(type: 0x0200)
        transport.receive(
            type: 0x0201,
            requestID: browse.requestID,
            flags: 1,
            fields: applicationPageFields(),
            codec: fixture.codec
        )
        let refreshedApplications = try await refresh.value
        XCTAssertEqual(refreshedApplications.map(\.name), ["Desktop", "Steam Big Picture"])
        XCTAssertEqual(transport.controlRequestCount(type: 0x0100), 0)
        await fixture.manager.stopAll()
    }

    func testAuthorizationBeforeZeroCapacityStillRejectsWithoutSTART() async throws {
        let lifecycle = RecordingManagerLifecycle()
        let fixture = try makeFixture(
            applications: [ModernLumenV3ApplicationRecord(
                id: 1, name: "Desktop", isRunning: false, artworkSHA256: nil,
                isHidden: false, isDirectLaunch: false
            )],
            lifecycle: lifecycle,
            initialDatagramPayloadByteCount: nil,
            datagramPayloadByteCountAfterAuthorization: 0
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1), hostID: fixture.displayHostID, resume: false,
                preferences: .default, activationUptime: 1
            )
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)
        do {
            try await launch.value
            XCTFail("Expected reordered control-only admission failure.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("requires QUIC DATAGRAM support"))
        }
        XCTAssertEqual(transport.controlRequestCount(type: 0x0100), 0)
        XCTAssertTrue(transport.activeSessionMutations.isEmpty)
        let values = await lifecycle.snapshot()
        XCTAssertTrue(values.isEmpty)
        await fixture.manager.stopAll()
    }

    func testLaunchWaitsForSlightlyLateDatagramCapacityBeforeSTART() async throws {
        let lifecycle = RecordingManagerLifecycle()
        let fixture = try makeFixture(
            applications: [ModernLumenV3ApplicationRecord(
                id: 1, name: "Desktop", isRunning: false, artworkSHA256: nil,
                isHidden: false, isDirectLaunch: false
            )],
            lifecycle: lifecycle,
            initialDatagramPayloadByteCount: nil
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1), hostID: fixture.displayHostID, resume: false,
                preferences: .default, activationUptime: 1
            )
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.controlRequestCount(type: 0x0100), 0)
        let preCapacityEvents = await lifecycle.snapshot()
        XCTAssertTrue(preCapacityEvents.isEmpty)

        transport.emit(.datagramCapacityChanged(
            wireByteCount: QUICTransportProfile.semanticDatagramByteCount,
            payloadByteCount: QUICTransportProfile.semanticDatagramPayloadByteCount
        ))
        let start = try await transport.controlRequest(type: 0x0100)
        let preparedEvents = await lifecycle.snapshot()
        XCTAssertEqual(preparedEvents, [.prepare])
        let offer = try decodeFields(start.request.payload, codec: fixture.codec)
        transport.receive(
            type: 0x0101,
            requestID: start.requestID,
            flags: 1,
            fields: failedStartResponse(status: 10, intent: offer[1]!),
            codec: fixture.codec
        )
        do {
            try await launch.value
            XCTFail("Expected the injected START rejection.")
        } catch {
            XCTAssertEqual(error as? ProtocolV3ClientError, .startRejected(10))
        }
        let completedEvents = await lifecycle.snapshot()
        XCTAssertEqual(Array(completedEvents.suffix(2)), [.finishPresentation, .finish])
        await fixture.manager.stopAll()
    }

    func testSubPhaseOneDatagramCapacityRejectsWithoutSTART() async throws {
        let fixture = try makeFixture(
            applications: [ModernLumenV3ApplicationRecord(
                id: 1, name: "Desktop", isRunning: false, artworkSHA256: nil,
                isHidden: false, isDirectLaunch: false
            )],
            initialDatagramPayloadByteCount:
                QUICTransportProfile.semanticDatagramPayloadByteCount - 1
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1), hostID: fixture.displayHostID, resume: false,
                preferences: .default, activationUptime: 1
            )
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)
        do {
            try await launch.value
            XCTFail("Expected sub-phase-one DATAGRAM capacity to reject streaming.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("complete 1108-byte phase-one payload"))
        }
        XCTAssertEqual(transport.controlRequestCount(type: 0x0100), 0)
        XCTAssertTrue(transport.activeSessionMutations.isEmpty)
        await fixture.manager.stopAll()
    }

    func testCapacityDropDuringPreparationPreventsSTARTAndCleansUp() async throws {
        let lifecycle = SuspendedManagerLifecycle()
        let fixture = try makeFixture(
            applications: [ModernLumenV3ApplicationRecord(
                id: 1, name: "Desktop", isRunning: false, artworkSHA256: nil,
                isHidden: false, isDirectLaunch: false
            )],
            lifecycle: lifecycle
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1), hostID: fixture.displayHostID, resume: false,
                preferences: .default, activationUptime: 1
            )
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)
        await lifecycle.waitUntilPreparationStarted()
        transport.emit(.datagramCapacityChanged(wireByteCount: 0, payloadByteCount: 0))
        try? await Task.sleep(for: .milliseconds(20))
        await lifecycle.releasePreparation()
        do {
            try await launch.value
            XCTFail("Expected DATAGRAM loss during preparation to reject START.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("requires QUIC DATAGRAM support"))
        }
        XCTAssertEqual(transport.controlRequestCount(type: 0x0100), 0)
        XCTAssertTrue(transport.activeSessionMutations.isEmpty)
        XCTAssertFalse(fixture.inputInstaller.installations.contains(true))
        let finishCount = await lifecycle.finishCount
        XCTAssertEqual(finishCount, 1)
        await fixture.manager.stopAll()
    }

    private func makeFixture(
        applications: [ModernLumenV3ApplicationRecord],
        lifecycle: any StreamSessionLifecycleCoordinating = RecordingManagerLifecycle(),
        output: RecordingManagerOutput = RecordingManagerOutput(),
        configurationBarrierTimeout: Duration = .seconds(1),
        initialDatagramPayloadByteCount: Int? = 1_108,
        datagramPayloadByteCountAfterAuthorization: Int? = nil,
        grantedPermissions: UInt64 = 0x17,
        microphoneAuthorization: any ClientMicrophoneAuthorizing = ManagerMicrophoneAuthorization(),
        microphoneCaptureFactory: any ClientMicrophoneCaptureCreating = ManagerMicrophoneCaptureFactory(),
        recoveryPhaseTimeouts: ModernLumenV3Manager.RecoveryPhaseTimeouts = .wireContract
    ) throws -> ManagerLifecycleFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraManagerLifecycle-\(UUID().uuidString)", isDirectory: true)
        let trustStore = FileBackedProtocolV3TrustStore(url: root.appendingPathComponent("trust.json"))
        let catalog = FileBackedModernLumenV3HostCatalog(url: root.appendingPathComponent("hosts.json"))
        let identity = try trustStore.identity()
        let hostKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(32..<64))
        let hostID = Data(SHA256.hash(data: hostKey.publicKey.rawRepresentation).prefix(16))
        let spki = Data(repeating: 0x71, count: 32)
        let trust = try ProtocolV3TrustRecord(
            hostID: hostID,
            hostPublicKey: hostKey.publicKey.rawRepresentation,
            tlsSPKIHash: spki,
            clientID: identity.clientID,
            grantedPermissions: grantedPermissions,
            pairingGeneration: 1
        )
        try trustStore.commit(identity: identity, trust: trust)
        try catalog.upsert(ModernLumenV3HostRecord(
            hostID: hostID,
            hostname: "lumen.local",
            hostnameIsIPLiteral: false,
            port: 48_030,
            displayName: "Lumen",
            applications: applications,
            applicationRevision: applications.isEmpty ? nil : 1,
            runningApplicationID: applications.first(where: \.isRunning)?.id
        ))
        let factory = ManagerPairedSessionFactory(
            hostKey: hostKey,
            spki: spki,
            initialDatagramPayloadByteCount: initialDatagramPayloadByteCount,
            datagramPayloadByteCountAfterAuthorization: datagramPayloadByteCountAfterAuthorization
        )
        let inputInstaller = ManagerInputInstaller()
        let mediaProvider = ManagerMediaProvider()
        let manager = ModernLumenV3Manager(
            trustStore: trustStore,
            hostCatalog: catalog,
            mediaCapabilities: .init(
                hasMetalDevice: true,
                supportsHardwareH264: true,
                supportsHardwareHEVC: false,
                supportsHardwareAV1: false,
                hasDefaultAudioOutput: true,
                supportsNativeAudioOutput: true,
                audioOutputChannelCount: 2
            ),
            mediaProvider: mediaProvider,
            output: output,
            motionPolicy: ControllerMotionPolicy(),
            inputInstaller: inputInstaller,
            lifecycle: lifecycle,
            microphoneAuthorization: microphoneAuthorization,
            microphoneCaptureFactory: microphoneCaptureFactory,
            pairedSessionFactory: factory.make,
            configurationBarrierTimeout: configurationBarrierTimeout,
            recoveryPhaseTimeouts: recoveryPhaseTimeouts,
            log: nil
        )
        return ManagerLifecycleFixture(
            root: root,
            manager: manager,
            factory: factory,
            inputInstaller: inputInstaller,
            mediaProvider: mediaProvider,
            catalog: catalog,
            hostID: hostID,
            displayHostID: ModernLumenV3Manager.hostID(for: hostID),
            grantedPermissions: grantedPermissions,
            hostKey: hostKey,
            spki: spki
        )
    }

    private func assertHostileConfigurationRejected(
        _ hostile: HostileConfiguration
    ) async throws {
        let lifecycle = RecordingManagerLifecycle()
        let fixture = try makeFixture(
            applications: [ModernLumenV3ApplicationRecord(
                id: 1,
                name: "Desktop",
                isRunning: false,
                artworkSHA256: nil,
                isHidden: false,
                isDirectLaunch: false
            )],
            lifecycle: lifecycle,
            configurationBarrierTimeout: .milliseconds(100)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launch = Task { @MainActor in
            try await fixture.manager.launchApplication(
                id: ApplicationID(1),
                hostID: fixture.displayHostID,
                resume: false,
                preferences: .default,
                activationUptime: 1
            )
        }
        let transport = try await fixture.factory.waitForTransport()
        try await authenticate(fixture, transport: transport)
        let start = try await transport.controlRequest(type: 0x0100)
        let offer = try decodeFields(start.request.payload, codec: fixture.codec)
        let selection = successfulStartResponse(offer)
        transport.receive(
            type: 0x0101,
            requestID: start.requestID,
            flags: 1,
            fields: selection,
            codec: fixture.codec
        )
        let errorAcknowledgement: ManagerLifecycleTransport.ControlRequest
        switch hostile {
        case .wrongVideoSession:
            var fields = videoConfigurationFields(selection)
            fields[1] = .bytes(Data(repeating: 0x7f, count: 16))
            transport.receive(
                type: 0x0140,
                requestID: 2,
                flags: 0,
                fields: fields,
                codec: fixture.codec
            )
            errorAcknowledgement = try await transport.controlRequest(type: 0x0141)
            XCTAssertEqual(fixture.mediaProvider.videoDecoder.configureCount, 0)
        case .wrongAudioGeneration:
            transport.receive(
                type: 0x0140,
                requestID: 2,
                flags: 0,
                fields: videoConfigurationFields(selection),
                codec: fixture.codec
            )
            _ = try await transport.controlRequest(type: 0x0141)
            var fields = audioConfigurationFields(selection)
            fields[2] = .unsigned(99)
            transport.receive(
                type: 0x0142,
                requestID: 4,
                flags: 0,
                fields: fields,
                codec: fixture.codec
            )
            errorAcknowledgement = try await transport.controlRequest(type: 0x0143)
        }
        guard case let .control(flags, _, _) = errorAcknowledgement.request.wireMetadata else {
            return XCTFail("Expected configuration error ACK metadata.")
        }
        XCTAssertEqual(flags, 0x03)
        do {
            try await launch.value
            XCTFail("Expected hostile configuration binding rejection.")
        } catch {
            XCTAssertTrue(error is ProtocolV3SessionMediaError, error.localizedDescription)
        }
        await eventually { transport.cancelCount >= 1 }
        XCTAssertFalse(fixture.inputInstaller.installations.contains(true))
        let values = await lifecycle.snapshot()
        XCTAssertFalse(values.contains(.commitStreaming))
        await fixture.manager.stopAll()
    }

    private func authenticate(
        _ fixture: ManagerLifecycleFixture,
        transport: ManagerLifecycleTransport,
        activeSessionID: Data? = nil
    ) async throws {
        let clientHello = try await transport.controlRequest(type: 0x0001)
        let clientHelloFields = try decodeFields(clientHello.request.payload, codec: fixture.codec)
        let attemptID = try XCTUnwrap(clientHelloFields[8]?.bytesValue)
        let serverHelloFields: [UInt64: ProtocolV3CBORValue] = [
            1: .unsigned(3),
            2: .bytes(Data(repeating: 0x51, count: 32)),
            3: .bytes(fixture.hostID),
            4: .bytes(fixture.hostKey.publicKey.rawRepresentation),
            5: .bytes(fixture.spki),
            6: .unsigned(0x37f),
            7: .unsigned(UInt64(QUICTransportProfile.semanticDatagramByteCount)),
            8: .bytes(attemptID),
        ]
        let serverHello = try managerFrame(
            type: 0x0002,
            requestID: 1,
            flags: 1,
            fields: serverHelloFields,
            codec: fixture.codec
        )
        transport.receive(
            type: 0x0002,
            requestID: 1,
            flags: 1,
            fields: serverHelloFields,
            codec: fixture.codec
        )

        let authorization = try await transport.controlRequest(type: 0x0003)
        let identity = try await fixture.factory.waitForIdentity()
        var response: [UInt64: ProtocolV3CBORValue] = [
            1: .unsigned(0),
            2: .bytes(identity.clientID),
            3: .unsigned(fixture.grantedPermissions),
            4: .unsigned(1),
            5: activeSessionID.map(ProtocolV3CBORValue.bytes) ?? .null,
            6: .bytes(attemptID),
        ]
        let unsigned = try managerFrame(
            type: 0x0004,
            requestID: 3,
            flags: 1,
            fields: response,
            codec: fixture.codec
        )
        response[7] = .bytes(try fixture.hostKey.signature(for: managerTranscript(
            domain: "lumen/3 auth host\0",
            spki: fixture.spki,
            frames: [
                try managerFrame(for: clientHello.request),
                serverHello,
                try managerFrame(for: authorization.request),
                unsigned,
            ]
        )))
        transport.receive(
            type: 0x0004,
            requestID: 3,
            flags: 1,
            fields: response,
            codec: fixture.codec
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, file: file, line: line)
    }
}

private struct ManagerLifecycleFixture {
    let root: URL
    let manager: ModernLumenV3Manager
    let factory: ManagerPairedSessionFactory
    let inputInstaller: ManagerInputInstaller
    let mediaProvider: ManagerMediaProvider
    let catalog: FileBackedModernLumenV3HostCatalog
    let hostID: Data
    let displayHostID: HostID
    let grantedPermissions: UInt64
    let hostKey: Curve25519.Signing.PrivateKey
    let spki: Data
    let codec = ProtocolV3CBORCodec()
}

@MainActor
private final class ManagerPairedSessionFactory {
    private let hostKey: Curve25519.Signing.PrivateKey
    private let spki: Data
    private let initialDatagramPayloadByteCount: Int?
    private let datagramPayloadByteCountAfterAuthorization: Int?
    private var transport: ManagerLifecycleTransport?
    private var transports: [ManagerLifecycleTransport] = []
    private var identity: ProtocolV3ClientIdentity?

    init(
        hostKey: Curve25519.Signing.PrivateKey,
        spki: Data,
        initialDatagramPayloadByteCount: Int?,
        datagramPayloadByteCountAfterAuthorization: Int?
    ) {
        self.hostKey = hostKey
        self.spki = spki
        self.initialDatagramPayloadByteCount = initialDatagramPayloadByteCount
        self.datagramPayloadByteCountAfterAuthorization = datagramPayloadByteCountAfterAuthorization
    }

    func make(
        trust: ProtocolV3TrustRecord,
        identity: ProtocolV3ClientIdentity,
        host _: String,
        port _: UInt16,
        hostnameIsIPLiteral _: Bool,
        mode _: QUICOptimizationMode
    ) throws -> ProtocolV3ClientControlSession {
        XCTAssertEqual(trust.hostPublicKey, hostKey.publicKey.rawRepresentation)
        let transport = ManagerLifecycleTransport(
            spki: spki,
            initialDatagramPayloadByteCount: initialDatagramPayloadByteCount,
            datagramPayloadByteCountAfterAuthorization: datagramPayloadByteCountAfterAuthorization
        )
        self.transport = transport
        transports.append(transport)
        self.identity = identity
        return ProtocolV3ClientControlSession(
            transport: transport,
            identity: identity,
            mode: .paired(trust, replaceExisting: true),
            randomBytes: { count in
                switch count {
                case 32: Data(repeating: 0x31, count: count)
                case 16: Data(repeating: 0x41, count: count)
                default: throw ProtocolV3WireError.invalidField("manager test random byte count")
                }
            }
        )
    }

    func waitForTransport(ordinal: Int = 0) async throws -> ManagerLifecycleTransport {
        try await waitForValue {
            self.transports.indices.contains(ordinal) ? self.transports[ordinal] : nil
        }
    }

    func waitForIdentity() async throws -> ProtocolV3ClientIdentity {
        try await waitForValue { self.identity }
    }

    private func waitForValue<Value>(_ value: @escaping @MainActor () -> Value?) async throws -> Value {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while let current = value() {
            return current
        }
        while ContinuousClock.now < deadline {
            if let current = value() { return current }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ProtocolV3WireError.invalidField("manager session factory timeout")
    }
}

private final class ManagerLifecycleTransport: QUICTransportProtocol, @unchecked Sendable {
    struct ControlRequest: Sendable {
        let requestID: UInt64
        let request: QUICOutboundRequest
    }

    private let lock = NSLock()
    private let spki: Data
    private let initialDatagramPayloadByteCount: Int?
    private let datagramPayloadByteCountAfterAuthorization: Int?
    private var requests: [QUICOutboundRequest] = []
    private var storedActiveSessionMutations: [Data?] = []
    private var storedCancelCount = 0
    var eventHandler: (@Sendable (QUICTransportEvent) -> Void)?
    var authenticationHandler: (@Sendable (QUICApplicationAuthenticationHandoff) -> Void)?

    init(
        spki: Data,
        initialDatagramPayloadByteCount: Int?,
        datagramPayloadByteCountAfterAuthorization: Int?
    ) {
        self.spki = spki
        self.initialDatagramPayloadByteCount = initialDatagramPayloadByteCount
        self.datagramPayloadByteCountAfterAuthorization = datagramPayloadByteCountAfterAuthorization
    }
    var cancelCount: Int { lock.withLock { storedCancelCount } }
    var activeSessionMutations: [Data?] { lock.withLock { storedActiveSessionMutations } }

    func start() throws {
        if let initialDatagramPayloadByteCount {
            eventHandler?(.datagramCapacityChanged(
                wireByteCount: initialDatagramPayloadByteCount,
                payloadByteCount: initialDatagramPayloadByteCount
            ))
        }
        authenticationHandler?(.init(leafSPKISHA256: spki))
    }

    func send(_ request: QUICOutboundRequest) {
        lock.withLock { requests.append(request) }
    }

    func setActiveSessionID(_ sessionID: Data?) throws {
        lock.withLock { storedActiveSessionMutations.append(sessionID) }
    }
    func applicationHelloDidComplete(success _: Bool) {}
    func applicationAuthenticationDidComplete(success _: Bool) {}
    func acceptInboundBulk(requestID _: UInt64, objectID _: UInt64) {}
    func rejectInboundBulk(requestID _: UInt64, objectID _: UInt64) {}

    func cancel() {
        let handler = lock.withLock { () -> (@Sendable (QUICTransportEvent) -> Void)? in
            storedCancelCount += 1
            return eventHandler
        }
        handler?(.stateChanged(.cancelled))
    }

    func controlRequest(type: UInt16, ordinal: Int = 0) async throws -> ControlRequest {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let request = lock.withLock({ () -> ControlRequest? in
                let matches = requests.compactMap { request -> ControlRequest? in
                    guard case let .control(_, requestType, requestID) = request.wireMetadata,
                          requestType == type else { return nil }
                    return ControlRequest(requestID: requestID, request: request)
                }
                return matches.indices.contains(ordinal) ? matches[ordinal] : nil
            }) {
                return request
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ProtocolV3WireError.invalidField(
            "manager test timed out waiting for control 0x\(String(type, radix: 16))"
        )
    }

    func controlRequestCount(type: UInt16) -> Int {
        lock.withLock {
            requests.count { request in
                guard case let .control(_, requestType, _) = request.wireMetadata else { return false }
                return requestType == type
            }
        }
    }

    func receive(
        type: UInt16,
        requestID: UInt64,
        flags: UInt8,
        fields: [UInt64: ProtocolV3CBORValue],
        codec: ProtocolV3CBORCodec
    ) {
        let payload = try! codec.encode(.map(fields))
        eventHandler?(.inbound(.init(
            lane: .control,
            payload: payload,
            receivedAtNanoseconds: 1,
            semanticSequence: nil,
            objectID: nil,
            controlFlags: flags,
            controlType: type,
            requestID: requestID
        )))
        if type == 0x0004, let datagramPayloadByteCountAfterAuthorization {
            eventHandler?(.datagramCapacityChanged(
                wireByteCount: datagramPayloadByteCountAfterAuthorization,
                payloadByteCount: datagramPayloadByteCountAfterAuthorization
            ))
        }
    }

    func emit(_ event: QUICTransportEvent) {
        eventHandler?(event)
    }
}

private actor RecordingManagerLifecycle: StreamSessionLifecycleCoordinating {
    enum Event: Equatable { case prepare, updatePreparation, commitStreaming, finishPresentation, finish }
    private(set) var values: [Event] = []
    func prepare(for bootstrap: StreamBootstrap) async throws { values.append(.prepare) }
    func updatePreparation(for bootstrap: StreamBootstrap) async throws { values.append(.updatePreparation) }
    func commitStreaming(for bootstrap: StreamBootstrap) async { values.append(.commitStreaming) }
    func finishPresentation() async { values.append(.finishPresentation) }
    func finish() async { values.append(.finish) }
    func snapshot() -> [Event] { values }
}

private actor SuspendedManagerLifecycle: StreamSessionLifecycleCoordinating {
    private var preparationStarted = false
    private var preparationReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var finishCount = 0

    func prepare(for bootstrap: StreamBootstrap) async throws {
        preparationStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !preparationReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func finish() async { finishCount += 1 }

    func waitUntilPreparationStarted() async {
        if preparationStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releasePreparation() {
        preparationReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class RecordingManagerOutput: StreamingEventOutputHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var storedBeginCount = 0
    private var storedEndCount = 0
    var beginCount: Int { lock.withLock { storedBeginCount } }
    var endCount: Int { lock.withLock { storedEndCount } }
    func handle(_ event: StreamingEvent) {}
    func beginSession() async { lock.withLock { storedBeginCount += 1 } }
    func endSession() async { lock.withLock { storedEndCount += 1 } }
}

private final class ManagerMediaProvider: StreamingMediaProviding, @unchecked Sendable {
    let videoDecoder = ManagerVideoDecoder()
    let audioDecoder = ManagerAudioDecoder()
    func makePipeline(for bootstrap: StreamBootstrap) throws -> StreamingMediaPipeline {
        StreamingMediaPipeline(
            videoDecoder: videoDecoder,
            audioDecoder: audioDecoder,
            availableVideoFormats: MoonlightVideoFormat.h264.rawValue
        )
    }
}

private final class ManagerVideoDecoder: UmbraStreaming.VideoDecoding,
    UmbraStreaming.VideoCodecInitializationPreparing,
    UmbraStreaming.VideoDecodeOutcomeReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedConfigureCount = 0
    var configureCount: Int { lock.withLock { storedConfigureCount } }
    func configure(format: UmbraStreaming.VideoStreamFormat) -> Bool {
        lock.withLock { storedConfigureCount += 1 }
        return true
    }
    func prepareCodecInitialization(
        _ data: Data,
        payloadFormat: UmbraStreaming.EncodedVideoPayloadFormat
    ) -> Bool { true }
    func installDecodeOutcomeHandler(
        _ handler: @escaping @Sendable (UmbraStreaming.VideoDecodeOutcome) -> Void
    ) {}
    func start() {}
    func stop() {}
    func cleanUp() {}
    func submit(frame: UmbraStreaming.CompressedVideoFrame) -> UmbraStreaming.VideoFrameDisposition { .accepted }
}

private final class ManagerAudioDecoder: UmbraStreaming.AudioDecoding, @unchecked Sendable {
    func configure(format: UmbraStreaming.OpusStreamFormat) -> Bool { true }
    func start() {}
    func stop() {}
    func cleanUp() {}
    func submit(packet: UmbraStreaming.CompressedAudioPacket) {}
}

@MainActor
private final class ManagerInputInstaller: PlatformInputSinkInstalling {
    private(set) var installations: [Bool] = []
    private var sink: (any PlatformInputPacketSink)?
    func installInputSink(_ sink: (any PlatformInputPacketSink)?) {
        self.sink = sink
        installations.append(sink != nil)
    }
}

private struct ManagerMicrophoneAuthorization: ClientMicrophoneAuthorizing {
    let authorization: ClientMicrophoneAuthorizationStatus
    init(_ authorization: ClientMicrophoneAuthorizationStatus = .authorized) {
        self.authorization = authorization
    }
    func status() -> ClientMicrophoneAuthorizationStatus { authorization }
    func requestAuthorization() async -> ClientMicrophoneAuthorizationStatus { authorization }
}

private final class ManagerMicrophoneCapture: ClientMicrophoneCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedStartCount = 0
    private var storedStopCount = 0
    var startCount: Int { lock.withLock { storedStartCount } }
    var stopCount: Int { lock.withLock { storedStopCount } }
    func start(
        frameHandler: @escaping @Sendable (ClientMicrophonePCMFrame) -> Void,
        discontinuityHandler: @escaping @Sendable () -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        lock.withLock { storedStartCount += 1 }
    }
    func stop() { lock.withLock { storedStopCount += 1 } }
}

private struct ManagerMicrophoneCaptureFactory: ClientMicrophoneCaptureCreating {
    let capture: ManagerMicrophoneCapture
    init(capture: ManagerMicrophoneCapture = ManagerMicrophoneCapture()) {
        self.capture = capture
    }
    func makeCapture() -> any ClientMicrophoneCapturing { capture }
}

private final class LockedManagerValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}

private func applicationPageFields() -> [UInt64: ProtocolV3CBORValue] {
    applicationPageFields(
        revision: 9,
        applications: [
            applicationEntry(id: 1, name: "Desktop", state: 0),
            applicationEntry(id: 2, name: "Steam Big Picture", state: 2),
        ],
        nextCursor: nil
    )
}

private func applicationPageFields(
    revision: UInt64,
    applications: [ProtocolV3CBORValue],
    nextCursor: UInt64?,
    notModified: Bool = false,
    status: UInt64 = 0
) -> [UInt64: ProtocolV3CBORValue] {
    [
        1: .unsigned(status),
        2: .unsigned(revision),
        3: .array(applications),
        4: nextCursor.map(ProtocolV3CBORValue.unsigned) ?? .null,
        5: .boolean(notModified),
    ]
}

private func applicationEntry(id: UInt64, name: String, state: UInt64) -> ProtocolV3CBORValue {
    .map([
        1: .unsigned(id), 2: .text(name), 3: .unsigned(state), 4: .unsigned(0),
        5: .null, 6: .unsigned(9), 7: .unsigned(1),
    ])
}

private func successfulStartResponse(
    _ offer: [UInt64: ProtocolV3CBORValue],
    selectMicrophone: Bool = false
) -> [UInt64: ProtocolV3CBORValue] {
    [
        1: .unsigned(0), 2: offer[1]!, 3: .bytes(Data(repeating: 0x61, count: 16)),
        4: offer[3]!, 5: offer[9]!.arrayValue!.first!, 6: offer[4]!, 7: offer[5]!,
        8: offer[6]!, 9: offer[7]!, 10: offer[8]!, 11: offer[12]!,
        12: offer[10]!.arrayValue!.first!,
        13: selectMicrophone ? offer[11]! : .null,
        14: .unsigned(1), 15: .unsigned(1),
        16: .unsigned(1), 17: .unsigned(1), 18: offer[15]!.arrayValue!.first!,
        19: .array([]), 20: offer[13]!, 21: .bytes(Data(repeating: 0x62, count: 32)),
        22: .unsigned(1), 23: .null,
    ]
}

private func failedStartResponse(
    status: UInt8,
    intent: ProtocolV3CBORValue
) -> [UInt64: ProtocolV3CBORValue] {
    var fields = Dictionary(uniqueKeysWithValues: (1...23).map {
        (UInt64($0), ProtocolV3CBORValue.null)
    })
    fields[1] = .unsigned(UInt64(status))
    fields[2] = intent
    fields[19] = .array([])
    return fields
}

private func videoConfigurationFields(
    _ selection: [UInt64: ProtocolV3CBORValue]
) -> [UInt64: ProtocolV3CBORValue] {
    [
        1: selection[3]!, 2: selection[14]!, 3: selection[5]!,
        4: .bytes(Data([1, 2, 3, 4])), 5: selection[23]!, 6: selection[6]!,
        7: selection[7]!, 8: selection[8]!, 9: selection[9]!,
    ]
}

private func audioConfigurationFields(
    _ selection: [UInt64: ProtocolV3CBORValue]
) -> [UInt64: ProtocolV3CBORValue] {
    [1: selection[3]!, 2: selection[15]!, 3: selection[12]!, 4: .unsigned(0)]
}

private func microphoneConfigurationFields(
    _ selection: [UInt64: ProtocolV3CBORValue]
) -> [UInt64: ProtocolV3CBORValue] {
    [1: selection[3]!, 2: selection[16]!, 3: selection[13]!, 4: .unsigned(0)]
}

private func sessionEndedFields(sessionID: Data) -> [UInt64: ProtocolV3CBORValue] {
    [
        1: .bytes(sessionID), 2: .unsigned(1), 3: .unsigned(1), 4: .boolean(false),
        5: .unsigned(0), 6: .unsigned(0), 7: .unsigned(0), 8: .unsigned(0),
    ]
}

private func decodeFields(
    _ payload: Data,
    codec: ProtocolV3CBORCodec
) throws -> [UInt64: ProtocolV3CBORValue] {
    guard case let .map(fields) = try codec.decode(payload) else {
        throw ProtocolV3WireError.invalidField("manager test control payload")
    }
    return fields
}

private func managerFrame(for request: QUICOutboundRequest) throws -> Data {
    guard case let .control(flags, type, requestID) = request.wireMetadata else {
        throw ProtocolV3WireError.invalidField("manager test control metadata")
    }
    return managerFrame(type: type, requestID: requestID, flags: flags, payload: request.payload)
}

private func managerFrame(
    type: UInt16,
    requestID: UInt64,
    flags: UInt8,
    fields: [UInt64: ProtocolV3CBORValue],
    codec: ProtocolV3CBORCodec
) throws -> Data {
    try managerFrame(
        type: type,
        requestID: requestID,
        flags: flags,
        payload: codec.encode(.map(fields))
    )
}

private func managerFrame(type: UInt16, requestID: UInt64, flags: UInt8, payload: Data) -> Data {
    var output = Data("ULC3".utf8)
    output.append(3)
    output.append(flags)
    managerAppend(type, to: &output)
    managerAppend(requestID, to: &output)
    managerAppend(UInt32(payload.count), to: &output)
    managerAppend(UInt32(0), to: &output)
    output.append(payload)
    return output
}

private func managerTranscript(domain: String, spki: Data, frames: [Data]) -> Data {
    var output = Data(domain.utf8)
    output.append(spki)
    for frame in frames {
        managerAppend(UInt32(frame.count), to: &output)
        output.append(frame)
    }
    return output
}

private func managerAppend<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}
