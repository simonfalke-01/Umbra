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
}

public struct ListAppsCommand: Equatable, Sendable {
    public var host: String
    public var csv: Bool
    public var verbose: Bool

    public init(host: String, csv: Bool = false, verbose: Bool = false) {
        self.host = host
        self.csv = csv
        self.verbose = verbose
    }
}

public struct PairHostCommand: Equatable, Sendable {
    public var host: String
    public var pin: String?

    public init(host: String, pin: String? = nil) {
        self.host = host
        self.pin = pin
    }
}

public struct StreamAppCommand: Equatable, Sendable {
    public var host: String
    public var applicationName: String
    public var preferences: StreamingPreferences
    public var quitRunningApplication: Bool

    public init(
        host: String,
        applicationName: String,
        preferences: StreamingPreferences,
        quitRunningApplication: Bool = false
    ) {
        self.host = host
        self.applicationName = applicationName
        self.preferences = preferences
        self.quitRunningApplication = quitRunningApplication
    }
}

public struct QuitHostCommand: Equatable, Sendable {
    public var host: String

    public init(host: String) {
        self.host = host
    }
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
