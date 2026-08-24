import Foundation
import XCTest
import UmbraCLI
import UmbraCore
@testable import UmbraCLIExecution
import UmbraServices

final class UmbraCLICommandExecutorTests: XCTestCase {
    func testListUsesSavedHostRefreshesRemoteCatalogAndStreamsPlainOutput() async throws {
        let host = makeHost(applications: applications)
        let service = FakeCLIService(hosts: [host], refreshedHosts: [host], applications: applications)
        let recorder = LockedRecorder<String>()
        let progress = LockedRecorder<CLIExecutionProgress>()
        let executor = makeExecutor(service: service, output: recorder, progress: progress)

        let outcome = await executor.execute(.list(.init(host: "mac-studio")))

        XCTAssertEqual(
            outcome,
            .terminate(
                CLIExecutionResult(
                    exitCode: 0,
                    standardOutput: "Desktop\nHades\n",
                    standardError: ""
                )
            )
        )
        XCTAssertEqual(recorder.values, ["Desktop\nHades\n"])
        XCTAssertEqual(
            progress.values,
            [.resolvingHost("mac-studio"), .loadingApplications("Mac Studio")]
        )
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls.refreshHostIDs, [host.uuid])
        XCTAssertEqual(calls.applicationRequests, [.init(hostID: host.uuid, refresh: true, includeHidden: true)])
        XCTAssertTrue(calls.addHostAddresses.isEmpty)
    }

    func testVerboseCSVListAddsAnUnsavedRemoteHostAndPreservesAllOutput() async throws {
        let remote = makeHost(name: "Remote Mac", applications: applications)
        let service = FakeCLIService(hosts: [], addedHost: remote, applications: applications)
        let recorder = LockedRecorder<String>()
        let executor = makeExecutor(service: service, output: recorder)

        let outcome = await executor.execute(
            .list(.init(host: "203.0.113.20", csv: true, verbose: true))
        )

        let expected =
            "Establishing connection to PC...\n"
            + "Loading app list...\n"
            + CLIListOutputFormatter.format(
                applications: applications,
                command: .init(host: "203.0.113.20", csv: true, verbose: true)
            )
        XCTAssertEqual(outcome, .terminate(.success(expected)))
        XCTAssertEqual(recorder.values.joined(), expected)
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls.addHostAddresses, ["203.0.113.20"])
        XCTAssertTrue(calls.refreshHostIDs.isEmpty)
    }

    func testHostResolutionFailureUsesHostUnavailableExitContract() async throws {
        let service = FakeCLIService(
            hosts: [],
            addHostError: .hostUnavailable(hostID: nil, message: "Failed to connect to missing-host")
        )
        let errorRecorder = LockedRecorder<String>()
        let executor = UmbraCLICommandExecutor(
            service: service,
            output: CLIOutputSink(standardError: errorRecorder.append)
        )

        let outcome = await executor.execute(.list(.init(host: "missing-host")))

        XCTAssertEqual(
            outcome,
            .terminate(.hostUnavailable("Failed to connect to missing-host\n"))
        )
        XCTAssertEqual(errorRecorder.values, ["Failed to connect to missing-host\n"])
    }

    func testPairReportsGeneratedPINAndRequiresConfirmedCertificate() async throws {
        let unpaired = makeHost(pairState: .notPaired)
        let paired = makeHost(pairState: .paired, certificate: Data([1, 2, 3]))
        let service = FakeCLIService(
            hosts: [unpaired],
            refreshedHosts: [unpaired],
            pairedHost: paired
        )
        let output = LockedRecorder<String>()
        let progress = LockedRecorder<CLIExecutionProgress>()
        let executor = makeExecutor(
            service: service,
            output: output,
            progress: progress,
            pin: "0042"
        )

        let outcome = await executor.execute(.pair(.init(host: unpaired.uuid)))

        let expected =
            "Establishing connection to PC...\n"
            + "Pairing... Please enter '0042' on Mac Studio.\n"
            + "Pairing completed successfully\n"
        XCTAssertEqual(outcome, .terminate(.success(expected)))
        XCTAssertEqual(output.values.joined(), expected)
        XCTAssertEqual(
            progress.values,
            [
                .resolvingHost(unpaired.uuid),
                .pairing(host: "Mac Studio", pin: "0042"),
                .pairingCompleted("Mac Studio"),
            ]
        )
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls.pairRequests, [.init(hostID: unpaired.uuid, pin: "0042")])
    }

    func testPairDoesNotReportSuccessForUnconfirmedServiceResult() async throws {
        let host = makeHost(pairState: .notPaired)
        let service = FakeCLIService(
            hosts: [host],
            refreshedHosts: [host],
            pairedHost: host
        )
        let executor = makeExecutor(service: service, pin: "1234")

        let outcome = await executor.execute(.pair(.init(host: host.name)))

        guard case let .terminate(result) = outcome else {
            return XCTFail("Expected a terminal pairing failure")
        }
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(
            result.standardError,
            "Pairing did not produce a confirmed paired host certificate.\n"
        )
        XCTAssertFalse(result.succeeded)
    }

    func testQuitUsesAuthoritativeServiceResultWithoutRefreshingAgain() async throws {
        let running = makeHost(currentGameID: applications[0].id, applications: applications)
        let stopped = makeHost(currentGameID: nil, applications: applications)
        let service = FakeCLIService(
            hosts: [running],
            refreshedHosts: [running, running],
            cancelledHost: stopped
        )
        let progress = LockedRecorder<CLIExecutionProgress>()
        let executor = makeExecutor(service: service, progress: progress)

        let outcome = await executor.execute(.quit(.init(host: running.name)))

        XCTAssertEqual(
            outcome,
            .terminate(.success("Establishing connection to PC...\nQuitting app...\n"))
        )
        let calls = await service.recordedCalls()
        XCTAssertEqual(
            calls.cancelRequests,
            [.init(hostID: running.uuid, applicationID: applications[0].id)]
        )
        XCTAssertEqual(calls.refreshHostIDs, [running.uuid])
        XCTAssertEqual(
            Array(progress.values.suffix(1)),
            [
                .quittingApplication(host: "Mac Studio", application: "Desktop"),
            ]
        )
    }

    func testQuitSurfacesServiceConfirmationFailure() async throws {
        let running = makeHost(currentGameID: applications[0].id, applications: applications)
        let service = FakeCLIService(
            hosts: [running],
            refreshedHosts: [running],
            cancelError: .protocolFailure(
                operation: .cancel,
                statusCode: 599,
                message: "The host did not confirm that the application quit."
            )
        )
        let executor = UmbraCLICommandExecutor(service: service)

        let outcome = await executor.execute(.quit(.init(host: running.uuid)))

        guard case let .terminate(result) = outcome else {
            return XCTFail("Expected a terminal quit failure")
        }
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.standardError.contains("did not confirm"))
    }

    func testStreamReturnsResolvedIntentWithExactParsedPreferencesAndWarnings() async throws {
        let running = makeHost(currentGameID: applications[1].id, applications: applications)
        let service = FakeCLIService(
            hosts: [running],
            refreshedHosts: [running],
            applications: applications
        )
        var preferences = StreamingPreferences.default
        preferences.width = 3_840
        preferences.height = 2_160
        preferences.fps = 144
        preferences.optimizationMode = .latency
        preferences.enableVSync = false
        preferences.framePacing = false
        preferences.videoCodecPreference = .hevc
        let errors = LockedRecorder<String>()
        let executor = UmbraCLICommandExecutor(
            service: service,
            output: CLIOutputSink(standardError: errors.append)
        )

        let outcome = await executor.execute(
            .stream(
                .init(
                    host: "MAC-STUDIO",
                    applicationName: "hAdEs",
                    preferences: preferences
                )
            ),
            warnings: ["FPS may exceed the display refresh rate."]
        )

        XCTAssertEqual(
            outcome,
            .stream(
                CLIStreamLaunchRequest(
                    intent: SessionIntent(
                        hostID: running.uuid,
                        applicationID: applications[1].id,
                        kind: .resume,
                        preferences: preferences
                    ),
                    standardError: "Warning: FPS may exceed the display refresh rate.\n"
                )
            )
        )
        XCTAssertEqual(errors.values, ["Warning: FPS may exceed the display refresh rate.\n"])
        guard case let .stream(request) = outcome else {
            return XCTFail("Expected a streaming launch request")
        }
        XCTAssertEqual(
            request.intent.effectivePolicy,
            EffectiveStreamingPolicy.resolve(for: preferences)
        )
        let calls = await service.recordedCalls()
        XCTAssertTrue(calls.cancelRequests.isEmpty)
        XCTAssertTrue(calls.pairRequests.isEmpty)
    }

    func testStreamPreservesForcedGamepadOneIntentFromCLIPreferences() async throws {
        let host = makeHost(applications: applications)
        let service = FakeCLIService(
            hosts: [host],
            refreshedHosts: [host],
            applications: applications
        )
        var preferences = StreamingPreferences.default
        preferences.multiController = false
        let executor = makeExecutor(service: service)

        let outcome = await executor.execute(.stream(.init(
            host: host.name,
            applicationName: applications[0].name,
            preferences: preferences
        )))

        guard case let .stream(request) = outcome else {
            return XCTFail("Expected a stream launch request")
        }
        XCTAssertEqual(request.intent.gamepadMask, 1)
        XCTAssertTrue(request.intent.persistGameControllers)
    }

    func testStreamYUV444RequestWarnsAboutTruthful420PreparationWithoutMutatingIntent() async throws {
        let host = makeHost(applications: applications)
        let service = FakeCLIService(
            hosts: [host],
            refreshedHosts: [host],
            applications: applications
        )
        var preferences = StreamingPreferences.default
        preferences.enableYUV444 = true
        let errors = LockedRecorder<String>()
        let executor = UmbraCLICommandExecutor(
            service: service,
            output: CLIOutputSink(standardError: errors.append)
        )

        let outcome = await executor.execute(.stream(.init(
            host: host.name,
            applicationName: applications[0].name,
            preferences: preferences
        )))

        guard case let .stream(request) = outcome else {
            return XCTFail("Expected a stream launch request")
        }
        let warning = "Warning: YUV 4:4:4 was requested, but the native macOS decoder has no "
            + "proven 4:4:4 format. Stream preparation will use YUV 4:2:0.\n"
        XCTAssertEqual(request.standardError, warning)
        XCTAssertEqual(errors.values, [warning])
        XCTAssertTrue(request.intent.preferences.enableYUV444)
    }

    func testStreamRefusesToQuitDifferentRunningApplicationWithoutExplicitOption() async throws {
        let running = makeHost(currentGameID: applications[0].id, applications: applications)
        let service = FakeCLIService(
            hosts: [running],
            refreshedHosts: [running],
            applications: applications
        )
        let executor = makeExecutor(service: service)

        let outcome = await executor.execute(.stream(.init(
            host: running.name,
            applicationName: applications[1].name,
            preferences: .default
        )))

        guard case let .terminate(result) = outcome else {
            return XCTFail("Expected an explicit replacement failure")
        }
        XCTAssertEqual(result.exitCode, CLIExitCode.failure.rawValue)
        XCTAssertEqual(
            result.standardError,
            "Desktop is already running on Mac Studio. Re-run with --quit-running-app "
                + "to quit it before launching Hades.\n"
        )
        let calls = await service.recordedCalls()
        XCTAssertTrue(calls.cancelRequests.isEmpty)
    }

    func testStreamExplicitlyQuitsDifferentApplicationAndWaitsForAuthoritativeStop() async throws {
        let running = makeHost(currentGameID: applications[0].id, applications: applications)
        let stopped = makeHost(currentGameID: nil, applications: applications)
        let service = FakeCLIService(
            hosts: [running],
            refreshedHosts: [running, running],
            applications: applications,
            cancelledHost: stopped
        )
        let progress = LockedRecorder<CLIExecutionProgress>()
        let executor = makeExecutor(service: service, progress: progress)

        let outcome = await executor.execute(.stream(.init(
            host: running.name,
            applicationName: applications[1].name,
            preferences: .default,
            quitRunningApplication: true
        )))

        guard case let .stream(request) = outcome else {
            return XCTFail("Expected a stream launch request after replacement")
        }
        XCTAssertEqual(request.intent.kind, .launch)
        XCTAssertEqual(request.intent.applicationID, applications[1].id)
        XCTAssertEqual(request.standardOutput, "Quitting Desktop...\n")
        let calls = await service.recordedCalls()
        XCTAssertEqual(
            calls.cancelRequests,
            [.init(hostID: running.uuid, applicationID: applications[0].id)]
        )
        XCTAssertEqual(calls.refreshHostIDs, [running.uuid])
        XCTAssertEqual(
            Array(progress.values.suffix(2)),
            [
                .quittingApplication(host: "Mac Studio", application: "Desktop"),
                .preparingStream(host: "Mac Studio", application: "Hades"),
            ]
        )
    }

    func testParserTerminalResultIsForwardedWithoutServiceCalls() async throws {
        let service = FakeCLIService(hosts: [])
        let output = LockedRecorder<String>()
        let executor = makeExecutor(service: service, output: output)
        let terminal = CLIExecutionResult.failure("usage\n")

        let outcome = await executor.execute(CLIParseResult.terminal(terminal))

        XCTAssertEqual(outcome, .terminate(terminal))
        XCTAssertEqual(output.values, ["usage\n"])
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, .init())
    }

    private var applications: [StreamApplication] {
        [
            StreamApplication(id: 1, name: "Desktop", supportsDirectLaunch: true),
            StreamApplication(id: 7, name: "Hades", hdrSupported: true),
        ]
    }

    private func makeHost(
        name: String = "Mac Studio",
        pairState: PairState = .paired,
        certificate: Data = Data([9]),
        currentGameID: Int? = nil,
        applications: [StreamApplication] = []
    ) -> StreamHost {
        StreamHost(
            uuid: "host-uuid",
            name: name,
            localAddress: NetworkEndpoint(hostname: "mac-studio", port: 47_989),
            serverCertificate: certificate,
            applications: applications,
            status: .online,
            pairState: pairState,
            currentGameID: currentGameID,
            appVersion: "7.1.0"
        )
    }

    private func makeExecutor(
        service: FakeCLIService,
        output: LockedRecorder<String> = LockedRecorder(),
        progress: LockedRecorder<CLIExecutionProgress> = LockedRecorder(),
        pin: String = "1234"
    ) -> UmbraCLICommandExecutor {
        UmbraCLICommandExecutor(
            service: service,
            progress: CLIProgressSink(progress.append),
            output: CLIOutputSink(
                standardOutput: output.append,
                standardError: output.append
            ),
            pinGenerator: FixedPINGenerator(pin: pin)
        )
    }
}

private actor FakeCLIService: UmbraCLIExecutionServicing {
    struct ApplicationRequest: Equatable, Sendable {
        var hostID: String
        var refresh: Bool
        var includeHidden: Bool
    }

    struct PairRequest: Equatable, Sendable {
        var hostID: String
        var pin: String
    }

    struct CancelRequest: Equatable, Sendable {
        var hostID: String
        var applicationID: Int
    }

    struct Calls: Equatable, Sendable {
        var refreshHostIDs: [String] = []
        var addHostAddresses: [String] = []
        var applicationRequests: [ApplicationRequest] = []
        var pairRequests: [PairRequest] = []
        var cancelRequests: [CancelRequest] = []
    }

    private var hostsValue: [StreamHost]
    private var refreshedHosts: [StreamHost]
    private let addedHost: StreamHost?
    private let applicationsValue: [StreamApplication]
    private let pairedHost: StreamHost?
    private let addHostError: UmbraServiceError?
    private let cancelledHost: StreamHost?
    private let cancelError: UmbraServiceError?
    private var calls = Calls()

    init(
        hosts: [StreamHost],
        refreshedHosts: [StreamHost] = [],
        addedHost: StreamHost? = nil,
        applications: [StreamApplication] = [],
        pairedHost: StreamHost? = nil,
        addHostError: UmbraServiceError? = nil,
        cancelledHost: StreamHost? = nil,
        cancelError: UmbraServiceError? = nil
    ) {
        self.hostsValue = hosts
        self.refreshedHosts = refreshedHosts
        self.addedHost = addedHost
        self.applicationsValue = applications
        self.pairedHost = pairedHost
        self.addHostError = addHostError
        self.cancelledHost = cancelledHost
        self.cancelError = cancelError
    }

    func hosts() async throws -> [StreamHost] {
        hostsValue
    }

    func refreshHost(id: String) async throws -> StreamHost {
        calls.refreshHostIDs.append(id)
        if !refreshedHosts.isEmpty {
            return refreshedHosts.removeFirst()
        }
        guard let host = hostsValue.first(where: { $0.uuid == id }) else {
            throw UmbraServiceError.hostNotFound(id)
        }
        return host
    }

    func addHost(address: String, port: UInt16?) async throws -> StreamHost {
        calls.addHostAddresses.append(address)
        if let addHostError { throw addHostError }
        guard let addedHost else {
            throw UmbraServiceError.hostUnavailable(
                hostID: nil,
                message: "Failed to connect to \(address)"
            )
        }
        hostsValue.append(addedHost)
        return addedHost
    }

    func applications(
        hostID: String,
        refresh: Bool,
        includeHidden: Bool
    ) async throws -> [StreamApplication] {
        calls.applicationRequests.append(
            .init(hostID: hostID, refresh: refresh, includeHidden: includeHidden)
        )
        return applicationsValue
    }

    func pairHost(id: String, pin: String) async throws -> StreamHost {
        calls.pairRequests.append(.init(hostID: id, pin: pin))
        guard let pairedHost else {
            throw UmbraServiceError.pairingUnavailable
        }
        return pairedHost
    }

    func cancelHostApplication(hostID: String, applicationID: Int) async throws -> StreamHost {
        calls.cancelRequests.append(.init(hostID: hostID, applicationID: applicationID))
        if let cancelError { throw cancelError }
        guard let cancelledHost else {
            throw UmbraServiceError.hostNotFound(hostID)
        }
        return cancelledHost
    }

    func recordedCalls() -> Calls { calls }
}

private struct FixedPINGenerator: CLIPINGenerating, Sendable {
    let pin: String
    func makePIN() -> String { pin }
}

private final class LockedRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}
