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

/// A semantic progress event suitable for a terminal, a progress view, or tests.
public enum CLIExecutionProgress: Equatable, Sendable {
    case resolvingHost(String)
    case loadingApplications(String)
    case pairing(host: String, pin: String)
    case pairingCompleted(String)
    case quittingApplication(host: String, application: String)
    case preparingStream(host: String, application: String)
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
public struct CLIStreamLaunchRequest: Equatable, Sendable {
    public var intent: SessionIntent
    public var standardOutput: String
    public var standardError: String

    public init(
        intent: SessionIntent,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.intent = intent
        self.standardOutput = standardOutput
        self.standardError = standardError
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
