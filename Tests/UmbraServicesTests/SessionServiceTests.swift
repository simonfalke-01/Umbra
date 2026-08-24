import XCTest
import UmbraCore
import UmbraNetworking
@testable import UmbraServices

final class SessionServiceTests: XCTestCase {
    func testLateEventHandlerImmediatelyReceivesCurrentSession() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let driver = BlockingStreamDriver()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver
        )
        _ = try await service.beginSession(SessionIntent(
            hostID: host.uuid,
            applicationID: 1,
            kind: .launch
        ))
        _ = await eventually { await driver.receivedBootstrap() != nil }

        let recorder = SessionEventRecorder()
        await service.setEventHandler { recorder.append($0) }

        guard case let .session(replayedSession)? = recorder.events.last,
              let session = replayedSession else {
            return XCTFail("Expected the current session to be replayed")
        }
        XCTAssertEqual(session.hostID, host.uuid)
        _ = try await service.stopSession(quitHostApplication: false)
    }

    func testLaunchBuildsRequestStartsDriverTracksStateAndQuitsHost() async throws {
        let host = makeHost()
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let driver = BlockingStreamDriver()
        let credentials = try RemoteInputCredentials(
            key: Data(repeating: 0xAB, count: 16),
            initializationVector: Data([1, 2, 3, 4] + Array(repeating: 0, count: 12))
        )
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let startupTelemetry = SessionStartupTelemetryRecorder()
        let service = UmbraApplicationService(
            persistence: store,
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver,
            credentialProvider: FixedCredentialProvider(credentials: credentials),
            uuidProvider: FixedUUIDProvider(value: sessionID),
            startupTelemetry: startupTelemetry
        )
        var preferences = StreamingPreferences.default
        preferences.width = 3_840
        preferences.height = 2_160
        preferences.fps = 120
        preferences.audioConfiguration = .surround51
        preferences.enableHDR = true

        let started = try await service.beginSession(SessionIntent(
            hostID: host.uuid,
            applicationID: 1,
            kind: .launch,
            preferences: preferences,
            clientRefreshRateX100: 6_000,
            gamepadMask: 3,
            persistGameControllers: true
        ))

        XCTAssertEqual(started.id, sessionID)
        let startupStages = try XCTUnwrap(
            startupTelemetry.snapshot(sessionID: sessionID)
        ).elapsedByStage
        XCTAssertNotNil(startupStages[.uiActivate])
        XCTAssertNotNil(startupStages[.hostLaunch])
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(startupStages[.hostLaunch]),
            try XCTUnwrap(startupStages[.uiActivate])
        )
        guard let call = await client.recordedStartCalls().first else {
            return XCTFail("Missing launch request")
        }
        XCTAssertEqual(call.kind, .launch)
        XCTAssertEqual(call.address.port, 47_984)
        XCTAssertEqual(call.configuration.remoteInputKeyID, 0x0102_0304)
        XCTAssertEqual(call.configuration.width, 3_840)
        XCTAssertEqual(call.configuration.framesPerSecond, 120)
        XCTAssertEqual(call.configuration.surroundAudioInfo, 0x003F_0006)
        XCTAssertEqual(call.configuration.gamepadMask, 3)
        XCTAssertTrue(call.configuration.persistGameControllers)
        XCTAssertTrue(call.configuration.enableHDR)
        let driverStarted = await eventually { await driver.receivedBootstrap() != nil }
        let bootstrap = await driver.receivedBootstrap()
        let reachedStreaming = await eventually {
            guard let current = await service.currentSession() else { return false }
            if case .streaming = current.state { return true }
            return false
        }
        XCTAssertTrue(driverStarted)
        XCTAssertEqual(bootstrap?.rtspSessionURL?.scheme, "rtsp")
        XCTAssertEqual(bootstrap?.clientRefreshRateX100, 6_000)
        XCTAssertTrue(reachedStreaming)

        let stopped = try await service.stopSession(quitHostApplication: true)
        guard case let .finished(result) = stopped.state else {
            return XCTFail("Expected a finished session")
        }
        XCTAssertTrue(result.quitHostApplication)
        let cancelCount = await driver.recordedCancelCount()
        let cancellationAddresses = await client.recordedCancellationAddresses()
        let saved = await store.value()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(cancellationAddresses.count, 1)
        XCTAssertNil(saved.hosts[0].currentGameID)
    }

    func testSuccessfulHostLaunchWithFailedLocalWarmupCompensatesBeforeReturning() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let driver = BlockingStreamDriver()
        await driver.failNextPreparationBarrier(with: .invalidInput(
            field: "renderer",
            message: "warmup failed"
        ))
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver
        )

        do {
            _ = try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .launch
            ))
            XCTFail("Expected local warmup failure")
        } catch {
            // The local failure is returned only after remote launch compensation completes.
        }

        let startCallCount = await client.recordedStartCalls().count
        let cancellationCount = await client.recordedCancellationAddresses().count
        let runBootstrap = await driver.receivedBootstrap()
        let driverCancelCount = await driver.recordedCancelCount()
        XCTAssertEqual(startCallCount, 1)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertNil(runBootstrap)
        XCTAssertGreaterThanOrEqual(driverCancelCount, 1)
    }

    func testPostLaunchPersistenceFailureCompensatesBeforeReturningAndRetryDoesNotDoubleCancel() async throws {
        let host = makeHost()
        let store = FailingUpdateSnapshotStore(
            UmbraSnapshot(hosts: [host]),
            failingUpdate: 2
        )
        let client = FakeGameStreamClient()
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let service = UmbraApplicationService(
            persistence: store,
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: BlockingStreamDriver()
        )
        let intent = SessionIntent(
            hostID: host.uuid,
            applicationID: 1,
            kind: .launch
        )

        do {
            _ = try await service.beginSession(intent)
            XCTFail("Expected the post-launch persistence update to fail")
        } catch let error as UmbraServiceError {
            guard case let .persistence(operation, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, .saving)
        }

        let cancellationAddressesAfterFailure = await client.recordedCancellationAddresses()
        let savedAfterFailure = await store.value()
        XCTAssertEqual(cancellationAddressesAfterFailure.count, 1)
        XCTAssertNil(savedAfterFailure.hosts[0].currentGameID)
        let failedSession = await service.currentSession()
        guard case let .failed(failure)? = failedSession?.state else {
            return XCTFail("Expected persistence failure to terminalize the session")
        }
        XCTAssertNil(failure.stage)

        _ = try await service.beginSession(intent)
        let startCallsAfterRetry = await client.recordedStartCalls()
        let cancellationAddressesAfterRetry = await client.recordedCancellationAddresses()
        XCTAssertEqual(startCallsAfterRetry.count, 2)
        XCTAssertEqual(cancellationAddressesAfterRetry.count, 1)

        _ = try await service.stopSession(quitHostApplication: false)
        let finalCancellationAddresses = await client.recordedCancellationAddresses()
        XCTAssertEqual(finalCancellationAddresses.count, 1)
    }

    func testPostLaunchCompensationFailureReportsOriginalFailureAndRunningRisk() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        let store = FailingUpdateSnapshotStore(
            UmbraSnapshot(hosts: [host]),
            failingUpdate: 2
        ) {
            await client.setError(.serverResponse(
                statusCode: 500,
                message: "Cancel request failed"
            ))
        }
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let service = UmbraApplicationService(
            persistence: store,
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: BlockingStreamDriver()
        )

        do {
            _ = try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .launch
            ))
            XCTFail("Expected preparation and compensation to fail")
        } catch let error as UmbraServiceError {
            guard case let .protocolFailure(operation, _, message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, .cancel)
            XCTAssertTrue(message.contains("Umbra could not update its saved state"))
            XCTAssertTrue(message.contains("Cancel request failed"))
            XCTAssertTrue(message.contains("may still be running"))
        }

        let cancellationAddresses = await client.recordedCancellationAddresses()
        XCTAssertEqual(cancellationAddresses.count, 1)
        let current = await service.currentSession()
        guard case let .failed(failure)? = current?.state else {
            return XCTFail("Expected compensation failure to terminalize the session")
        }
        XCTAssertEqual(failure.kind, .connectionFailed)
        XCTAssertNil(failure.stage)
        XCTAssertTrue(failure.message.contains("may still be running"))
    }

    func testPostResumePersistenceFailureDoesNotQuitExistingApplication() async throws {
        let host = makeHost(currentGameID: 1)
        let store = FailingUpdateSnapshotStore(
            UmbraSnapshot(hosts: [host]),
            failingUpdate: 2
        )
        let client = FakeGameStreamClient()
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 1),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let service = UmbraApplicationService(
            persistence: store,
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: BlockingStreamDriver()
        )

        do {
            _ = try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .resume
            ))
            XCTFail("Expected the post-resume persistence update to fail")
        } catch let error as UmbraServiceError {
            guard case let .persistence(operation, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, .saving)
        }

        let startCalls = await client.recordedStartCalls()
        let cancellationAddresses = await client.recordedCancellationAddresses()
        XCTAssertEqual(startCalls.map(\.kind), [.resume])
        XCTAssertTrue(cancellationAddresses.isEmpty)
    }

    func testResumeRequiresMatchingRunningApplication() async throws {
        let host = makeHost(currentGameID: nil)
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let driver = BlockingStreamDriver()
        let service = UmbraApplicationService(
            persistence: store,
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver
        )

        do {
            _ = try await service.beginSession(SessionIntent(hostID: host.uuid, applicationID: 1, kind: .resume))
            XCTFail("Resume must reject a stale session intent")
        } catch let error as UmbraServiceError {
            guard case .protocolFailure(operation: .resume, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let startCalls = await client.recordedStartCalls()
        XCTAssertTrue(startCalls.isEmpty)
    }

    func testStaleLaunchIntentResumesApplicationAlreadyRunningOnHost() async throws {
        let host = makeHost(currentGameID: nil)
        let client = FakeGameStreamClient()
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 1),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let driver = BlockingStreamDriver()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver
        )

        _ = try await service.beginSession(SessionIntent(
            hostID: host.uuid,
            applicationID: 1,
            kind: .launch
        ))

        let startCalls = await client.recordedStartCalls()
        let call = try XCTUnwrap(startCalls.first)
        XCTAssertEqual(call.kind, .resume)
        _ = try await service.stopSession(quitHostApplication: false)
    }

    func testTransientStateChangingResponseRefreshesAndRetriesAsResume() async throws {
        let host = makeHost(currentGameID: nil)
        let client = FakeGameStreamClient()
        let address = HostAddress(host: "192.168.1.10", port: 47_984)
        await client.enqueueServerInfo([
            makeServerInfo(currentGameID: 0),
            makeServerInfo(currentGameID: 1),
        ], at: address)
        await client.enqueueStartResults([
            .failure(.serverResponse(statusCode: 409, message: "Host state is changing")),
            .success(LaunchResponse(sessionURL: URL(string: "rtsp://192.168.1.10:48010/session"))),
        ])
        let clock = ImmediateServiceClock()
        let driver = BlockingStreamDriver()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver,
            clock: clock
        )
        var policyPreferences = StreamingPreferences.default
        policyPreferences.optimizationMode = .latency
        policyPreferences.enableVSync = false
        policyPreferences.framePacing = false
        let exactPolicy = EffectiveStreamingPolicy.resolve(for: policyPreferences)

        _ = try await service.beginSession(SessionIntent(
            hostID: host.uuid,
            applicationID: 1,
            kind: .launch,
            effectivePolicy: exactPolicy
        ))

        let calls = await client.recordedStartCalls()
        XCTAssertEqual(calls.map(\.kind), [.launch, .resume])
        let sleepCount = await clock.recordedSleepCount()
        let prepareCount = await driver.recordedPrepareCount()
        let preparedBootstraps = await driver.receivedPreparedBootstraps()
        _ = await eventually { await driver.receivedBootstrap() != nil }
        let runBootstrap = await driver.receivedBootstrap()
        XCTAssertEqual(sleepCount, 1)
        XCTAssertEqual(prepareCount, 2)
        XCTAssertEqual(preparedBootstraps.map(\.effectivePolicy), [exactPolicy, exactPolicy])
        XCTAssertEqual(runBootstrap?.effectivePolicy, exactPolicy)
        _ = try await service.stopSession(quitHostApplication: false)
    }

    func testTransientRetryReappliesRefreshedVideoCapabilitiesToLaunchAndSession() async throws {
        let host = makeHost(currentGameID: nil)
        let client = FakeGameStreamClient()
        let address = HostAddress(host: "192.168.1.10", port: 47_984)
        await client.enqueueServerInfo([
            makeServerInfo(
                currentGameID: 0,
                serverCodecModeSupport: Int(HostCodecSupport.hevcMain10.rawValue),
                maxLumaPixelsHEVC: 0
            ),
            makeServerInfo(
                currentGameID: 1,
                serverCodecModeSupport: Int(HostCodecSupport.h264.rawValue),
                maxLumaPixelsHEVC: 0
            ),
        ], at: address)
        await client.enqueueStartResults([
            .failure(.serverResponse(statusCode: 409, message: "Host state is changing")),
            .success(LaunchResponse(sessionURL: URL(string: "rtsp://192.168.1.10:48010/session"))),
        ])
        let driver = BlockingStreamDriver()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver,
            clock: ImmediateServiceClock()
        )
        var preferences = StreamingPreferences.default
        preferences.enableHDR = true
        preferences.autoAdjustBitrate = true

        let started = try await service.beginSession(SessionIntent(
            hostID: host.uuid,
            applicationID: 1,
            kind: .launch,
            preferences: preferences
        ))

        let calls = await client.recordedStartCalls()
        XCTAssertEqual(calls.map(\.configuration.enableHDR), [true, false])
        XCTAssertFalse(started.preferences.enableHDR)
        XCTAssertEqual(started.preferences.enableYUV444, false)
        XCTAssertEqual(
            started.preferences.bitrateKbps,
            StreamingPreferences.defaultBitrateKbps(
                width: preferences.width,
                height: preferences.height,
                fps: preferences.fps,
                yuv444: false
            )
        )
        let prepared = await driver.receivedPreparedBootstrap()
        XCTAssertEqual(prepared?.host.codecSupport, [.h264])
        _ = try await service.stopSession(quitHostApplication: false)
    }

    func testHostStartWaitsForLocalStreamPreparation() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let driver = BlockingStreamDriver()
        await driver.suspendNextPreparation()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver
        )

        let start = Task {
            try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .launch
            ))
        }
        let preparationStarted = await eventually {
            await driver.recordedPrepareCount() == 1
        }
        XCTAssertTrue(preparationStarted)
        let callsDuringPreparation = await client.recordedStartCalls()
        XCTAssertTrue(callsDuringPreparation.isEmpty)

        await driver.resumeSuspendedPreparation()
        _ = try await start.value
        let callsAfterPreparation = await client.recordedStartCalls()
        XCTAssertEqual(callsAfterPreparation.count, 1)
        _ = try await service.stopSession(quitHostApplication: false)
    }

    func testLocalStreamPreparationFailureNeverStartsHostAndPreservesTypedFailure() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let failure = SessionFailure(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kind: .decoderUnavailable,
            message: "The requested decoder is unavailable.",
            stage: .platformInitialization,
            errorCode: -17,
            occurredAt: Date(timeIntervalSince1970: 42)
        )
        let driver = FailingPreparationStreamDriver(failure: failure)
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver
        )

        do {
            _ = try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .launch
            ))
            XCTFail("Expected local stream preparation to fail")
        } catch let error as UmbraServiceError {
            XCTAssertEqual(error, .streamFailure(failure))
        }

        let startCalls = await client.recordedStartCalls()
        XCTAssertTrue(startCalls.isEmpty)
        let counts = await driver.recordedCounts()
        XCTAssertEqual(counts.prepare, 1)
        XCTAssertEqual(counts.run, 0)
        XCTAssertEqual(counts.cancel, 1)
        let currentSession = await service.currentSession()
        let current = try XCTUnwrap(currentSession)
        guard case let .failed(recordedFailure) = current.state else {
            return XCTFail("Expected a typed terminal failure")
        }
        XCTAssertEqual(recordedFailure, failure)
    }

    func testConcurrentBeginSessionReservesBeforeRefreshAndStartsRemoteOnce() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        await client.suspendNextServerInfoResponses()
        let driver = BlockingStreamDriver()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver
        )
        let intent = SessionIntent(hostID: host.uuid, applicationID: 1, kind: .launch)

        let first = Task { try await service.beginSession(intent) }
        let reachedSuspendedPreflight = await eventually {
            await client.recordedServerInfoCalls().count == 1
        }
        XCTAssertTrue(reachedSuspendedPreflight)

        do {
            _ = try await service.beginSession(intent)
            XCTFail("A concurrent start must be rejected while preflight is suspended")
        } catch let error as UmbraServiceError {
            XCTAssertEqual(error, .sessionInProgress)
        }

        await client.resumeSuspendedServerInfoResponses()
        _ = try await first.value
        let startCalls = await client.recordedStartCalls()
        XCTAssertEqual(startCalls.count, 1)
        _ = try await service.stopSession(quitHostApplication: false)
    }

    func testCancellingDuringPreflightDoesNotStartRemoteApplication() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        await client.suspendNextServerInfoResponses()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: BlockingStreamDriver()
        )
        let task = Task {
            try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .launch
            ))
        }
        let refreshStarted = await eventually {
            await client.recordedServerInfoCalls().count == 1
        }
        XCTAssertTrue(refreshStarted)

        task.cancel()
        await client.resumeSuspendedServerInfoResponses()
        do {
            _ = try await task.value
            XCTFail("Cancelled preflight unexpectedly started a session")
        } catch is CancellationError {
            // Expected.
        }

        let startCalls = await client.recordedStartCalls()
        XCTAssertTrue(startCalls.isEmpty)
        let current = await service.currentSession()
        guard case let .failed(failure)? = current?.state else {
            return XCTFail("Expected a terminal cancelled session state")
        }
        XCTAssertEqual(failure.kind, .cancelled)
        XCTAssertNil(failure.stage)
    }

    func testRefreshFailureDoesNotMisreportServerHandshakeStage() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: BlockingStreamDriver()
        )

        do {
            _ = try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .launch
            ))
            XCTFail("Expected host refresh to fail")
        } catch let error as UmbraServiceError {
            guard case .hostUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let current = await service.currentSession()
        guard case let .failed(failure)? = current?.state else {
            return XCTFail("Expected refresh failure to terminalize the session")
        }
        XCTAssertEqual(failure.kind, .hostUnavailable)
        XCTAssertNil(failure.stage)
        let startCalls = await client.recordedStartCalls()
        XCTAssertTrue(startCalls.isEmpty)
    }

    func testLaunchProtocolFailureReportsServerHandshakeStage() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        await client.enqueueStartResults([
            .failure(.serverResponse(statusCode: 500, message: "Launch failed")),
        ])
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: BlockingStreamDriver()
        )

        do {
            _ = try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .launch
            ))
            XCTFail("Expected launch handshake to fail")
        } catch let error as UmbraServiceError {
            guard case .protocolFailure(operation: .launch, statusCode: 500, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let current = await service.currentSession()
        guard case let .failed(failure)? = current?.state else {
            return XCTFail("Expected handshake failure to terminalize the session")
        }
        XCTAssertEqual(failure.kind, .connectionFailed)
        XCTAssertEqual(failure.stage, .serverHandshake)
        let cancellationAddresses = await client.recordedCancellationAddresses()
        XCTAssertTrue(cancellationAddresses.isEmpty)
    }

    func testStopDuringSuspendedPreflightReleasesReservationAndDoesNotQuitHost() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        await client.suspendNextServerInfoResponses()
        let driver = BlockingStreamDriver()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver
        )
        let first = Task {
            try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .launch
            ))
        }
        let refreshStarted = await eventually {
            await client.recordedServerInfoCalls().count == 1
        }
        XCTAssertTrue(refreshStarted)

        let stopped = try await service.stopSession(quitHostApplication: true)
        guard case let .finished(result) = stopped.state else {
            return XCTFail("Expected preflight stop to terminalize immediately")
        }
        XCTAssertFalse(result.quitHostApplication)
        do {
            _ = try await first.value
            XCTFail("Stopped preflight unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        let preflightCancellations = await client.recordedCancellationAddresses()
        XCTAssertTrue(preflightCancellations.isEmpty)

        let retry = Task {
            try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .launch
            ))
        }
        await client.resumeSuspendedServerInfoResponses()
        _ = try await retry.value
        _ = try await service.stopSession(quitHostApplication: false)
    }

    func testStopDuringSuspendedLaunchDoesNotLetOldCompensationCancelRetry() async throws {
        let host = makeHost(applications: [
            StreamApplication(id: 1, name: "First"),
            StreamApplication(id: 2, name: "Second"),
        ])
        let client = FakeGameStreamClient()
        let sessionURL = URL(string: "rtsp://192.168.1.10:48010/session")
        await client.setSessionURL(sessionURL)
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        await client.suspendNextStartResponses()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: BlockingStreamDriver()
        )
        let first = Task {
            try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .launch
            ))
        }
        let launchStarted = await eventually {
            await client.recordedStartCalls().count == 1
        }
        XCTAssertTrue(launchStarted)

        _ = try await service.stopSession(quitHostApplication: false)
        do {
            _ = try await first.value
            XCTFail("Stopped launch unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }

        let retryTask = Task {
            try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 2,
                kind: .launch
            ))
        }
        await client.resumeSuspendedStartResponses()
        let retry = try await retryTask.value
        XCTAssertEqual(retry.applicationID, 2)
        for _ in 0..<20 { await Task.yield() }
        let cancellations = await client.recordedCancellationAddresses()
        XCTAssertEqual(cancellations.count, 1)
        _ = try await service.stopSession(quitHostApplication: false)
    }

    func testInvalidRetryWaitsForCancelledLaunchCompensation() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        await client.suspendNextStartResponses()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: BlockingStreamDriver()
        )
        let first = Task {
            try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 1,
                kind: .launch
            ))
        }
        let launchStarted = await eventually {
            await client.recordedStartCalls().count == 1
        }
        XCTAssertTrue(launchStarted)
        _ = try await service.stopSession(quitHostApplication: false)
        do {
            _ = try await first.value
            XCTFail("Stopped launch unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }

        let invalidRetry = Task {
            try await service.beginSession(SessionIntent(
                hostID: host.uuid,
                applicationID: 999,
                kind: .launch
            ))
        }
        await client.resumeSuspendedStartResponses()
        do {
            _ = try await invalidRetry.value
            XCTFail("Invalid retry unexpectedly succeeded")
        } catch let error as UmbraServiceError {
            XCTAssertEqual(error, .applicationNotFound(hostID: host.uuid, applicationID: 999))
        }
        let cancellations = await client.recordedCancellationAddresses()
        XCTAssertEqual(cancellations.count, 1)
    }

    func testLateDriverEventsCannotRegressFinishedSession() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        await client.setSessionURL(URL(string: "rtsp://192.168.1.10:48010/session"))
        await client.setServerInfo(
            makeServerInfo(currentGameID: 0),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let driver = BlockingStreamDriver()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            streamDriver: driver
        )

        _ = try await service.beginSession(SessionIntent(
            hostID: host.uuid,
            applicationID: 1,
            kind: .launch
        ))
        let driverStarted = await eventually { await driver.receivedBootstrap() != nil }
        XCTAssertTrue(driverStarted)
        _ = try await service.stopSession(quitHostApplication: false)

        await driver.emit(.connecting(.audioStreamInitialization))
        await driver.emit(.warning("late warning"))
        await driver.emit(.streaming(Date(timeIntervalSince1970: 200)))
        for _ in 0..<10 { await Task.yield() }

        let currentSession = await service.currentSession()
        let current = try XCTUnwrap(currentSession)
        guard case .finished = current.state else {
            return XCTFail("Late native callbacks regressed the terminal session: \(current.state)")
        }
        XCTAssertTrue(current.launchWarnings.isEmpty)
    }

    func testMissingStreamDriverFailsBeforeLaunchingRemoteApplication() async throws {
        let host = makeHost()
        let client = FakeGameStreamClient()
        let service = UmbraApplicationService(
            persistence: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear)
        )

        do {
            _ = try await service.beginSession(SessionIntent(hostID: host.uuid, applicationID: 1, kind: .launch))
            XCTFail("Expected an unavailable stream adapter error")
        } catch let error as UmbraServiceError {
            XCTAssertEqual(error, .streamingUnavailable)
        }
        let startCalls = await client.recordedStartCalls()
        XCTAssertTrue(startCalls.isEmpty)
    }

    func testCancelHostApplicationPollsUntilServerInfoConfirmsDelayedStop() async throws {
        let host = makeHost(currentGameID: 1)
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        let secureAddress = HostAddress(host: "192.168.1.10", port: 47_984)
        await client.enqueueServerInfo([
            makeServerInfo(currentGameID: 1),
            makeServerInfo(currentGameID: 1),
            makeServerInfo(currentGameID: 0),
        ], at: secureAddress)
        let clock = ImmediateServiceClock()
        let service = UmbraApplicationService(
            persistence: store,
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            clock: clock,
            cancelConfirmationAttempts: 3,
            cancelConfirmationInterval: .seconds(1)
        )

        let confirmed = try await service.cancelHostApplication(
            hostID: host.uuid,
            applicationID: 1
        )
        let cancellationAddresses = await client.recordedCancellationAddresses()
        let serverInfoCalls = await client.recordedServerInfoCalls()
        let sleepCount = await clock.recordedSleepCount()
        let saved = await store.value()
        XCTAssertEqual(cancellationAddresses.count, 1)
        XCTAssertEqual(serverInfoCalls.count, 3)
        XCTAssertEqual(sleepCount, 2)
        XCTAssertNil(confirmed.currentGameID)
        XCTAssertNil(saved.hosts[0].currentGameID)
    }

    func testCancelHostApplicationFailsAndPreservesRunningStateAfterBoundedPolling() async throws {
        let host = makeHost(currentGameID: 1)
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        let secureAddress = HostAddress(host: "192.168.1.10", port: 47_984)
        await client.enqueueServerInfo([
            makeServerInfo(currentGameID: 1),
            makeServerInfo(currentGameID: 1),
            makeServerInfo(currentGameID: 1),
        ], at: secureAddress)
        let clock = ImmediateServiceClock()
        let service = UmbraApplicationService(
            persistence: store,
            clientProvider: FakeClientProvider(value: client),
            discovery: nil,
            connectivityTester: FakeConnectivityTester(result: .clear),
            clock: clock,
            cancelConfirmationAttempts: 3,
            cancelConfirmationInterval: .seconds(1)
        )

        do {
            try await service.cancelHostApplication(hostID: host.uuid, applicationID: 1)
            XCTFail("Expected cancellation confirmation to fail")
        } catch let error as UmbraServiceError {
            guard case .protocolFailure(operation: .cancel, statusCode: 599, let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("may not have been started by this client"))
        }

        let serverInfoCalls = await client.recordedServerInfoCalls()
        let sleepCount = await clock.recordedSleepCount()
        let saved = await store.value()
        XCTAssertEqual(serverInfoCalls.count, 3)
        XCTAssertEqual(sleepCount, 2)
        XCTAssertEqual(saved.hosts[0].currentGameID, 1)
    }

    func testErrorMapperClassifiesAuthenticationAndUnreachableHost() {
        XCTAssertEqual(
            ServiceErrorMapper.map(UmbraNetworkingError.httpStatus(401), operation: .applications),
            .authenticationFailed("The host rejected Umbra's client credentials.")
        )
        let mapped = ServiceErrorMapper.map(URLError(.cannotConnectToHost), operation: .refresh, hostID: "h")
        guard case .hostUnavailable(hostID: "h", _) = mapped else {
            return XCTFail("Unexpected error mapping: \(mapped)")
        }
    }
}

private final class SessionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostServiceEvent] = []
    var events: [HostServiceEvent] { lock.withLock { storage } }
    func append(_ event: HostServiceEvent) { lock.withLock { storage.append(event) } }
}

private actor FailingUpdateSnapshotStore: SnapshotPersisting {
    private var snapshot: UmbraSnapshot
    private let failingUpdate: Int
    private let failureAction: @Sendable () async -> Void
    private var updateCount = 0

    init(
        _ snapshot: UmbraSnapshot,
        failingUpdate: Int,
        failureAction: @escaping @Sendable () async -> Void = {}
    ) {
        self.snapshot = snapshot
        self.failingUpdate = failingUpdate
        self.failureAction = failureAction
    }

    func load() async throws -> UmbraSnapshot { snapshot }

    func save(_ snapshot: UmbraSnapshot) async throws {
        self.snapshot = snapshot
    }

    func update(
        _ transform: @Sendable (UmbraSnapshot) throws -> UmbraSnapshot
    ) async throws -> UmbraSnapshot {
        updateCount += 1
        if updateCount == failingUpdate {
            await failureAction()
            throw ForcedSnapshotUpdateFailure()
        }
        snapshot = try transform(snapshot)
        return snapshot
    }

    func value() -> UmbraSnapshot { snapshot }
}

private struct ForcedSnapshotUpdateFailure: Error, Sendable {}
