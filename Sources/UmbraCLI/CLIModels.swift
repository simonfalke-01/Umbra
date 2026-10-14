import Foundation
import UmbraCore

/// A command that has been validated and is ready for the application layer to execute.
public enum UmbraCommand: Equatable, Sendable {
    /// Launch Umbra's normal graphical interface.
    case launchApplication
    case recoverStorage
    case list(ListAppsCommand)
    case pair(PairHostCommand)
    case stream(StreamAppCommand)
    case quit(QuitHostCommand)
    case attach(AttachHostCommand)
    case stop(StopHostCommand)
    case telemetry(TelemetryHostCommand)
}

public enum CLIStreamingProtocol: String, Equatable, Sendable {
    case legacyGameStream = "legacy"
    case lsp
}

public struct CLILSPPermissionSet: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let browseApplications = Self(rawValue: 1 << 0)
    public static let startOrAttach = Self(rawValue: 1 << 1)
    public static let input = Self(rawValue: 1 << 2)
    public static let microphone = Self(rawValue: 1 << 3)
    public static let stopOwnStream = Self(rawValue: 1 << 4)
    public static let quitApplication = Self(rawValue: 1 << 5)
    public static let controllerOutput = Self(rawValue: 1 << 6)
    public static let clipboard = Self(rawValue: 1 << 7)
    public static let standard: Self = [
        .browseApplications, .startOrAttach, .input, .stopOwnStream, .controllerOutput, .clipboard,
    ]
}

public enum CLILSPMicrophoneMode: String, Equatable, Sendable {
    case off
    case optional
    case required
}

public struct CLILSPOptions: Equatable, Sendable {
    public var hostID: UUID?
    public var permissions: CLILSPPermissionSet
    public var microphone: CLILSPMicrophoneMode
    public var emitTelemetry: Bool

    public init(
        hostID: UUID? = nil,
        permissions: CLILSPPermissionSet = .standard,
        microphone: CLILSPMicrophoneMode = .off,
        emitTelemetry: Bool = false
    ) {
        self.hostID = hostID
        self.permissions = permissions
        self.microphone = microphone
        self.emitTelemetry = emitTelemetry
    }
}

public struct ListAppsCommand: Equatable, Sendable {
    public var host: String
    public var csv: Bool
    public var verbose: Bool
    public var streamingProtocol: CLIStreamingProtocol
    public var lsp: CLILSPOptions

    public init(
        host: String, csv: Bool = false, verbose: Bool = false,
        streamingProtocol: CLIStreamingProtocol = .legacyGameStream,
        lsp: CLILSPOptions = .init()
    ) {
        self.host = host
        self.csv = csv
        self.verbose = verbose
        self.streamingProtocol = streamingProtocol
        self.lsp = lsp
    }
}

public struct PairHostCommand: Equatable, Sendable {
    public var host: String
    public var pin: String?
    public var streamingProtocol: CLIStreamingProtocol
    public var lsp: CLILSPOptions

    public init(
        host: String, pin: String? = nil,
        streamingProtocol: CLIStreamingProtocol = .legacyGameStream,
        lsp: CLILSPOptions = .init()
    ) {
        self.host = host
        self.pin = pin
        self.streamingProtocol = streamingProtocol
        self.lsp = lsp
    }
}

public struct StreamAppCommand: Equatable, Sendable {
    public var host: String
    public var applicationName: String
    public var preferences: StreamingPreferences
    public var quitRunningApplication: Bool
    public var resume: Bool
    public var streamingProtocol: CLIStreamingProtocol
    public var lsp: CLILSPOptions

    public init(
        host: String,
        applicationName: String,
        preferences: StreamingPreferences,
        quitRunningApplication: Bool = false,
        resume: Bool = false,
        streamingProtocol: CLIStreamingProtocol = .legacyGameStream,
        lsp: CLILSPOptions = .init()
    ) {
        self.host = host
        self.applicationName = applicationName
        self.preferences = preferences
        self.quitRunningApplication = quitRunningApplication
        self.resume = resume
        self.streamingProtocol = streamingProtocol
        self.lsp = lsp
    }
}

public struct QuitHostCommand: Equatable, Sendable {
    public var host: String
    public var streamingProtocol: CLIStreamingProtocol
    public var lsp: CLILSPOptions

    public init(
        host: String,
        streamingProtocol: CLIStreamingProtocol = .legacyGameStream,
        lsp: CLILSPOptions = .init()
    ) {
        self.host = host
        self.streamingProtocol = streamingProtocol
        self.lsp = lsp
    }
}

public struct AttachHostCommand: Equatable, Sendable {
    public var host: String
    public var lsp: CLILSPOptions
    public init(host: String, lsp: CLILSPOptions = .init()) { self.host = host; self.lsp = lsp }
}

public struct StopHostCommand: Equatable, Sendable {
    public var host: String
    public var lsp: CLILSPOptions
    public init(host: String, lsp: CLILSPOptions = .init()) { self.host = host; self.lsp = lsp }
}

public struct TelemetryHostCommand: Equatable, Sendable {
    public var host: String
    public var lsp: CLILSPOptions
    public init(host: String, lsp: CLILSPOptions = .init()) { self.host = host; self.lsp = lsp }
}

/// Conventional process exit codes used by the Moonlight-compatible command surface.
public enum CLIExitCode: Int32, Equatable, Sendable {
    case success = 0
    case failure = 1
    /// Moonlight Qt uses -1 when a requested host cannot be reached or is not paired.
    case hostUnavailable = -1
}

/// Output and status returned by parsing or executing a command.
///
/// The reusable CLI library never writes to standard streams and never terminates the process.
/// An executable adapter can write these strings verbatim and exit with `exitCode`.
public struct CLIExecutionResult: Equatable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitCode == CLIExitCode.success.rawValue }

    public static func success(_ output: String = "") -> Self {
        Self(exitCode: CLIExitCode.success.rawValue, standardOutput: output)
    }

    public static func failure(_ error: String) -> Self {
        Self(exitCode: CLIExitCode.failure.rawValue, standardError: error)
    }

    public static func hostUnavailable(_ error: String) -> Self {
        Self(exitCode: CLIExitCode.hostUnavailable.rawValue, standardError: error)
    }
}

/// The deterministic result of command-line parsing.
public enum CLIParseResult: Equatable, Sendable {
    /// Parsing succeeded. Warnings mirror Moonlight's advisory FPS and bitrate diagnostics.
    case ready(command: UmbraCommand, warnings: [String])
    /// Parsing completed without a command, such as help, version, or a usage error.
    case terminal(CLIExecutionResult)

    public var command: UmbraCommand? {
        guard case let .ready(command, _) = self else { return nil }
        return command
    }

    public var warnings: [String] {
        guard case let .ready(_, warnings) = self else { return [] }
        return warnings
    }

    public var terminalResult: CLIExecutionResult? {
        guard case let .terminal(result) = self else { return nil }
        return result
    }
}
