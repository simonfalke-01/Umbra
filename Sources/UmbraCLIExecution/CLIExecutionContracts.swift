import Foundation
import UmbraCLI
import UmbraCore
import UmbraServices

/// The service surface required to execute Umbra's command-line commands.
///
/// Keeping this protocol narrower than `UmbraApplicationService` makes the executor deterministic
/// in tests and prevents command-line execution from depending on AppKit or SwiftUI state.
public protocol UmbraCLIExecutionServicing: Sendable {
    func hosts() async throws -> [StreamHost]
    func refreshHost(id: String) async throws -> StreamHost
    func addHost(address: String, port: UInt16?) async throws -> StreamHost
    func applications(
        hostID: String,
        refresh: Bool,
        includeHidden: Bool
    ) async throws -> [StreamApplication]
    func pairHost(id: String, pin: String) async throws -> StreamHost
    /// Returns the host snapshot produced by the service's authoritative quit confirmation.
    func cancelHostApplication(hostID: String, applicationID: Int) async throws -> StreamHost
}

extension UmbraApplicationService: UmbraCLIExecutionServicing {}

public struct CLILSPHost: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String
    public var paired: Bool

    public init(id: UUID, name: String, address: String, paired: Bool) {
        self.id = id; self.name = name; self.address = address; self.paired = paired
    }
}

public struct CLILSPApplication: Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct CLILSPPairingPrompt: Equatable, Sendable {
    public var host: CLILSPHost
    public var pin: String
    public var expiresAtUTCSeconds: UInt64
    public init(host: CLILSPHost, pin: String, expiresAtUTCSeconds: UInt64) {
        self.host = host; self.pin = pin; self.expiresAtUTCSeconds = expiresAtUTCSeconds
    }
}

public struct CLILSPStartRequest: Equatable, Sendable {
    public var hostID: UUID
    public var applicationID: String
    public var resume: Bool
    public var preferences: StreamingPreferences
    public var pointerRate: UInt32
    public var controllerRate: UInt32
    public var sensorRate: UInt32
    public var reconciliationRate: UInt32
    public var microphone: CLILSPMicrophoneMode

    public init(
        hostID: UUID, applicationID: String, resume: Bool,
        preferences: StreamingPreferences, pointerRate: UInt32,
        controllerRate: UInt32, sensorRate: UInt32,
        reconciliationRate: UInt32, microphone: CLILSPMicrophoneMode
    ) {
        self.hostID = hostID; self.applicationID = applicationID; self.resume = resume
        self.preferences = preferences; self.pointerRate = pointerRate
        self.controllerRate = controllerRate; self.sensorRate = sensorRate
        self.reconciliationRate = reconciliationRate; self.microphone = microphone
    }
}

public enum CLILSPStopOutcome: Equatable, Sendable {
    case notRunning
    case stopped
    case rejected(String)
    case transportFailed(String)
}

/// A bounded-window distribution for one coarse LSP media-processing stage.
///
/// The sample count is the number of values retained in the current bounded window. It is not a
/// lifetime frame or packet count, and the duration does not represent physical presentation.
public struct CLILSPTimingDistribution: Equatable, Sendable {
    public var boundedWindowSampleCount: Int
    public var p50Microseconds: UInt64
    public var p95Microseconds: UInt64
    public var p99Microseconds: UInt64
    public var maximumMicroseconds: UInt64
    public var measurementDrops: UInt64
    public var clockDomain: String

    public init(
        boundedWindowSampleCount: Int,
        p50Microseconds: UInt64,
        p95Microseconds: UInt64,
        p99Microseconds: UInt64,
        maximumMicroseconds: UInt64,
        measurementDrops: UInt64,
        clockDomain: String
    ) {
        self.boundedWindowSampleCount = boundedWindowSampleCount
        self.p50Microseconds = p50Microseconds
        self.p95Microseconds = p95Microseconds
        self.p99Microseconds = p99Microseconds
        self.maximumMicroseconds = maximumMicroseconds
        self.measurementDrops = measurementDrops
        self.clockDomain = clockDomain
    }
}

/// Transport counters and optional live media-stage timing for an LSP session.
///
/// A `nil` media value means that measurement is unavailable. A present zero counter remains a
/// measured zero and must not be collapsed into the unavailable state.
public struct CLILSPTelemetry: Equatable, Sendable {
    public var lifecycle: String
    public var receivedDatagrams: UInt64
    public var transmittedDatagrams: UInt64
    public var droppedDatagrams: UInt64
    public var authenticationFailures: UInt64
    public var currentUDPPayloadSize: UInt16
    public var reconnectPhase: String?
    public var completeFrameReceiveToVideoToolboxSubmit: CLILSPTimingDistribution?
    public var videoToolboxSubmitToDecodeCompletion: CLILSPTimingDistribution?
    public var completeFrameReceiveToMetalEnqueue: CLILSPTimingDistribution?
    public var metalEnqueueToCommit: CLILSPTimingDistribution?
    public var audioReceiveToDecode: CLILSPTimingDistribution?
    public var audioDecodeAndRenderEnqueue: CLILSPTimingDistribution?
    public var audioUnderruns: UInt64?
    public var audioRebuffers: UInt64?

    public init(
        lifecycle: String, receivedDatagrams: UInt64, transmittedDatagrams: UInt64,
        droppedDatagrams: UInt64, authenticationFailures: UInt64,
        currentUDPPayloadSize: UInt16, reconnectPhase: String?,
        completeFrameReceiveToVideoToolboxSubmit: CLILSPTimingDistribution? = nil,
        videoToolboxSubmitToDecodeCompletion: CLILSPTimingDistribution? = nil,
        completeFrameReceiveToMetalEnqueue: CLILSPTimingDistribution? = nil,
        metalEnqueueToCommit: CLILSPTimingDistribution? = nil,
        audioReceiveToDecode: CLILSPTimingDistribution? = nil,
        audioDecodeAndRenderEnqueue: CLILSPTimingDistribution? = nil,
        audioUnderruns: UInt64? = nil,
        audioRebuffers: UInt64? = nil
    ) {
        self.lifecycle = lifecycle; self.receivedDatagrams = receivedDatagrams
        self.transmittedDatagrams = transmittedDatagrams; self.droppedDatagrams = droppedDatagrams
        self.authenticationFailures = authenticationFailures
        self.currentUDPPayloadSize = currentUDPPayloadSize; self.reconnectPhase = reconnectPhase
        self.completeFrameReceiveToVideoToolboxSubmit = completeFrameReceiveToVideoToolboxSubmit
        self.videoToolboxSubmitToDecodeCompletion = videoToolboxSubmitToDecodeCompletion
        self.completeFrameReceiveToMetalEnqueue = completeFrameReceiveToMetalEnqueue
        self.metalEnqueueToCommit = metalEnqueueToCommit
        self.audioReceiveToDecode = audioReceiveToDecode
        self.audioDecodeAndRenderEnqueue = audioDecodeAndRenderEnqueue
        self.audioUnderruns = audioUnderruns
        self.audioRebuffers = audioRebuffers
    }

    /// Stable command-line representation shared by direct commands and native-app handoffs.
    public var commandLineOutput: String {
        var output = "lsp.lifecycle=\(lifecycle)\n"
            + "lsp.received_datagrams=\(receivedDatagrams)\n"
            + "lsp.transmitted_datagrams=\(transmittedDatagrams)\n"
            + "lsp.dropped_datagrams=\(droppedDatagrams)\n"
            + "lsp.authentication_failures=\(authenticationFailures)\n"
            + "lsp.udp_payload_size=\(currentUDPPayloadSize)\n"
            + (reconnectPhase.map { "lsp.reconnect_phase=\($0)\n" } ?? "")
        output += Self.timingOutput(
            "complete_frame_receive_to_videotoolbox_submit",
            completeFrameReceiveToVideoToolboxSubmit
        )
        output += Self.timingOutput(
            "videotoolbox_submit_to_decode_completion",
            videoToolboxSubmitToDecodeCompletion
        )
        output += Self.timingOutput(
            "complete_frame_receive_to_metal_enqueue",
            completeFrameReceiveToMetalEnqueue
        )
        output += Self.timingOutput("metal_enqueue_to_commit", metalEnqueueToCommit)
        output += Self.timingOutput("audio_receive_to_decode", audioReceiveToDecode)
        output += Self.timingOutput("audio_decode_and_render_enqueue", audioDecodeAndRenderEnqueue)
        output += "lsp.media.audio_underruns=\(audioUnderruns.map(String.init) ?? "unavailable")\n"
        output += "lsp.media.audio_rebuffers=\(audioRebuffers.map(String.init) ?? "unavailable")\n"
        return output
    }

    private static func timingOutput(
        _ stage: String,
        _ distribution: CLILSPTimingDistribution?
    ) -> String {
        let prefix = "lsp.media.\(stage)"
        guard let distribution else { return "\(prefix).availability=unavailable\n" }
        return "\(prefix).availability=available\n"
            + "\(prefix).bounded_window_samples=\(distribution.boundedWindowSampleCount)\n"
            + "\(prefix).p50_microseconds=\(distribution.p50Microseconds)\n"
            + "\(prefix).p95_microseconds=\(distribution.p95Microseconds)\n"
            + "\(prefix).p99_microseconds=\(distribution.p99Microseconds)\n"
            + "\(prefix).maximum_microseconds=\(distribution.maximumMicroseconds)\n"
            + "\(prefix).measurement_drops=\(distribution.measurementDrops)\n"
            + "\(prefix).clock_domain=\(distribution.clockDomain)\n"
    }
}

/// Narrow product seam required for real LSP CLI execution.
///
/// Implementations must use `LSPProductClient`; they must not redirect to
/// GameStream when LSP discovery, authentication, or execution fails.
public protocol UmbraCLILSPServicing: Sendable {
    func resolveHost(query: String, exactHostID: UUID?) async throws -> CLILSPHost
    func applications(hostID: UUID) async throws -> [CLILSPApplication]
    func beginPairing(hostID: UUID, permissions: CLILSPPermissionSet) async throws -> CLILSPPairingPrompt
    func completePairing(hostID: UUID) async throws -> CLILSPHost
    func cancelPairing(hostID: UUID) async
    func configure(profile: LSPNetworkProfilePreference, competitionCapacityMbps: Int) async throws
    func start(_ request: CLILSPStartRequest) async throws
    /// Retains session/process ownership until authenticated remote termination,
    /// explicit STOP, transport failure, or task cancellation.
    func runUntilTerminated(hostID: UUID) async -> CLILSPStopOutcome
    func attach(hostID: UUID) async throws
    func stop(hostID: UUID) async -> CLILSPStopOutcome
    func quit(hostID: UUID) async throws
    func telemetry(hostID: UUID) async throws -> CLILSPTelemetry
}

/// A semantic progress event suitable for a terminal, a progress view, or tests.
public enum CLIExecutionProgress: Equatable, Sendable {
    case resolvingHost(String)
    case loadingApplications(String)
    case pairing(host: String, pin: String)
    case pairingCompleted(String)
    case quittingApplication(host: String, application: String)
    case preparingStream(host: String, application: String)
    case pairingLSP(host: String, pin: String)
    case attachingLSP(String)
    case stoppingLSP(String)
}

/// Receives progress without coupling the executor to a specific presentation surface.
public struct CLIProgressSink: Sendable {
    private let handler: @Sendable (CLIExecutionProgress) -> Void

    public init(_ handler: @escaping @Sendable (CLIExecutionProgress) -> Void = { _ in }) {
        self.handler = handler
    }

    public func report(_ progress: CLIExecutionProgress) {
        handler(progress)
    }
}

/// Receives command output as it is produced. The same bytes are also preserved in the returned
/// execution result so callers can choose live output or buffered output without changing commands.
public struct CLIOutputSink: Sendable {
    private let standardOutputHandler: @Sendable (String) -> Void
    private let standardErrorHandler: @Sendable (String) -> Void

    public init(
        standardOutput: @escaping @Sendable (String) -> Void = { _ in },
        standardError: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.standardOutputHandler = standardOutput
        self.standardErrorHandler = standardError
    }

    public func writeStandardOutput(_ value: String) {
        standardOutputHandler(value)
    }

    public func writeStandardError(_ value: String) {
        standardErrorHandler(value)
    }
}

public protocol CLIPINGenerating: Sendable {
    func makePIN() -> String
}

public struct RandomCLIPINGenerator: CLIPINGenerating, Sendable {
    public init() {}

    public func makePIN() -> String {
        String(format: "%04d", Int.random(in: 0 ... 9_999))
    }
}

/// Information the native application needs to begin a direct stream.
///
/// This request deliberately has no exit code: resolving a host and application is not equivalent
/// to successfully starting a streaming session. The application must dispatch the intent to the
/// real streaming surface and own its eventual session result.
public struct CLILSPStreamLaunchTarget: Equatable, Sendable {
    public var hostID: UUID
    public var applicationID: String
    public var hostName: String
    public var applicationName: String
    public var microphone: CLILSPMicrophoneMode
    public var emitTelemetry: Bool

    public init(
        hostID: UUID,
        applicationID: String,
        hostName: String,
        applicationName: String,
        microphone: CLILSPMicrophoneMode,
        emitTelemetry: Bool
    ) {
        self.hostID = hostID
        self.applicationID = applicationID
        self.hostName = hostName
        self.applicationName = applicationName
        self.microphone = microphone
        self.emitTelemetry = emitTelemetry
    }
}

public struct CLIStreamLaunchRequest: Equatable, Sendable {
    public var intent: SessionIntent
    public var standardOutput: String
    public var standardError: String
    public var lsp: CLILSPStreamLaunchTarget?

    public init(
        intent: SessionIntent,
        standardOutput: String = "",
        standardError: String = "",
        lsp: CLILSPStreamLaunchTarget? = nil
    ) {
        self.intent = intent
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.lsp = lsp
    }
}

/// The result of executing a parsed command.
public enum CLIExecutionOutcome: Equatable, Sendable {
    /// Continue into Umbra's normal native application lifecycle.
    case launchApplication
    /// Hand a validated and resolved stream intent to the native streaming surface.
    case stream(CLIStreamLaunchRequest)
    /// Write the supplied streams (unless live output was used) and terminate with its exit code.
    case terminate(CLIExecutionResult)
}
