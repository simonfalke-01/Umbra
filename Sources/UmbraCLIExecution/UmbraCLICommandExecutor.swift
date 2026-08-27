import Foundation
import UmbraCLI
import UmbraCore
import UmbraServices

public struct UmbraCLICommandExecutor: Sendable {
    private let service: any UmbraCLIExecutionServicing
    private let progress: CLIProgressSink
    private let output: CLIOutputSink
    private let pinGenerator: any CLIPINGenerating

    public init(
        service: any UmbraCLIExecutionServicing,
        progress: CLIProgressSink = CLIProgressSink(),
        output: CLIOutputSink = CLIOutputSink(),
        pinGenerator: any CLIPINGenerating = RandomCLIPINGenerator()
    ) {
        self.service = service
        self.progress = progress
        self.output = output
        self.pinGenerator = pinGenerator
    }

    /// Executes a parser result without writing to global process streams or terminating the process.
    public func execute(_ parseResult: CLIParseResult) async -> CLIExecutionOutcome {
        switch parseResult {
        case let .terminal(result):
            emit(result)
            return .terminate(result)
        case let .ready(command, warnings):
            return await execute(command, warnings: warnings)
        }
    }

    /// Executes a validated command. Parser warnings are written to standard error with Moonlight's
    /// conventional `Warning:` prefix and preserved in the returned transcript.
    public func execute(
        _ command: UmbraCommand,
        warnings: [String] = []
    ) async -> CLIExecutionOutcome {
        let transcript = ExecutionTranscript(output: output)
        for warning in warnings {
            transcript.writeStandardError("Warning: \(warning)\n")
        }

        switch command {
        case .launchApplication:
            return .launchApplication
        case .recoverStorage:
            return .terminate(
                .failure("Storage recovery must be executed before Umbra opens its services.\n")
            )
        case let .list(command):
            return await executeList(command, transcript: transcript)
        case let .pair(command):
            return await executePair(command, transcript: transcript)
        case let .quit(command):
            return await executeQuit(command, transcript: transcript)
        case let .stream(command):
            return await executeStream(command, transcript: transcript)
        }
    }
}

private extension UmbraCLICommandExecutor {
    func executeList(
        _ command: ListAppsCommand,
        transcript: ExecutionTranscript
    ) async -> CLIExecutionOutcome {
        let connectionMessage = CLIListOutputFormatter.verboseMessage(
            for: .establishingConnection,
            command: command
        )
        transcript.writeStandardOutput(connectionMessage)
        progress.report(.resolvingHost(command.host))

        let host: StreamHost
        do {
            host = try await resolveHost(command.host)
        } catch {
            return terminate(error, transcript: transcript, hostResolution: true)
        }

        transcript.writeStandardOutput(
            CLIListOutputFormatter.verboseMessage(for: .loadingApplications, command: command)
        )
        progress.report(.loadingApplications(host.name))
        do {
            let applications = try await service.applications(
                hostID: host.uuid,
                refresh: true,
                includeHidden: true
            )
            transcript.writeStandardOutput(
                CLIListOutputFormatter.format(applications: applications, command: command)
            )
            return .terminate(transcript.result(exitCode: .success))
        } catch {
            return terminate(error, transcript: transcript)
        }
    }

    func executePair(
        _ command: PairHostCommand,
        transcript: ExecutionTranscript
    ) async -> CLIExecutionOutcome {
        transcript.writeStandardOutput("Establishing connection to PC...\n")
        progress.report(.resolvingHost(command.host))

        let host: StreamHost
        do {
            host = try await resolveHost(command.host)
        } catch {
            return terminate(error, transcript: transcript, hostResolution: true)
        }

        guard host.pairState != .paired else {
            transcript.writeStandardError("\(host.name) is already paired\n")
            return .terminate(transcript.result(exitCode: .failure))
        }

        let pin = command.pin ?? pinGenerator.makePIN()
        guard isValidPIN(pin) else {
            transcript.writeStandardError("PIN must be 4 digits\n")
            return .terminate(transcript.result(exitCode: .failure))
        }

        transcript.writeStandardOutput("Pairing... Please enter '\(pin)' on \(host.name).\n")
        progress.report(.pairing(host: host.name, pin: pin))
        do {
            let paired = try await service.pairHost(id: host.uuid, pin: pin)
            guard paired.pairState == .paired, !paired.serverCertificate.isEmpty else {
                transcript.writeStandardError(
                    "Pairing did not produce a confirmed paired host certificate.\n"
                )
                return .terminate(transcript.result(exitCode: .failure))
            }
            progress.report(.pairingCompleted(paired.name))
            transcript.writeStandardOutput("Pairing completed successfully\n")
            return .terminate(transcript.result(exitCode: .success))
        } catch {
            return terminate(error, transcript: transcript)
        }
    }

    func executeQuit(
        _ command: QuitHostCommand,
        transcript: ExecutionTranscript
    ) async -> CLIExecutionOutcome {
        transcript.writeStandardOutput("Establishing connection to PC...\n")
        progress.report(.resolvingHost(command.host))

        let host: StreamHost
        do {
            host = try await resolveHost(command.host)
        } catch {
            return terminate(error, transcript: transcript, hostResolution: true)
        }

        guard let runningApplicationID = host.currentGameID else {
            transcript.writeStandardError("No application is currently running on \(host.name).\n")
            return .terminate(transcript.result(exitCode: .failure))
        }
        let runningApplicationName = host.applications
            .first(where: { $0.id == runningApplicationID })?
            .name ?? "application \(runningApplicationID)"

        transcript.writeStandardOutput("Quitting app...\n")
        progress.report(
            .quittingApplication(host: host.name, application: runningApplicationName)
        )
        do {
            _ = try await service.cancelHostApplication(
                hostID: host.uuid,
                applicationID: runningApplicationID
            )
            return .terminate(transcript.result(exitCode: .success))
        } catch {
            return terminate(error, transcript: transcript)
        }
    }

    func executeStream(
        _ command: StreamAppCommand,
        transcript: ExecutionTranscript
    ) async -> CLIExecutionOutcome {
        progress.report(.resolvingHost(command.host))
        var host: StreamHost
        do {
            host = try await resolveHost(command.host)
        } catch {
            return terminate(error, transcript: transcript, hostResolution: true)
        }

        progress.report(.loadingApplications(host.name))
        do {
            let applications = try await service.applications(
                hostID: host.uuid,
                refresh: true,
                includeHidden: true
            )
            guard let application = applications.first(where: {
                $0.name.caseInsensitiveCompare(command.applicationName) == .orderedSame
            }) else {
                transcript.writeStandardError(
                    "Failed to find application \(command.applicationName)\n"
                )
                return .terminate(transcript.result(exitCode: .failure))
            }

            if let runningApplicationID = host.currentGameID,
               runningApplicationID != application.id {
                let runningApplicationName = applications
                    .first(where: { $0.id == runningApplicationID })?
                    .name ?? "application \(runningApplicationID)"
                guard command.quitRunningApplication else {
                    transcript.writeStandardError(
                        "\(runningApplicationName) is already running on \(host.name). "
                            + "Re-run with --quit-running-app to quit it before launching "
                            + "\(application.name).\n"
                    )
                    return .terminate(transcript.result(exitCode: .failure))
                }

                transcript.writeStandardOutput("Quitting \(runningApplicationName)...\n")
                progress.report(
                    .quittingApplication(host: host.name, application: runningApplicationName)
                )
                let refreshed = try await service.cancelHostApplication(
                    hostID: host.uuid,
                    applicationID: runningApplicationID
                )
                host = refreshed
                if let newRunningApplicationID = host.currentGameID,
                   newRunningApplicationID != application.id {
                    transcript.writeStandardError(
                        "Another application started on \(host.name) before \(application.name) "
                            + "could launch.\n"
                    )
                    return .terminate(transcript.result(exitCode: .failure))
                }
            }

            if command.preferences.enableYUV444 {
                transcript.writeStandardError(
                    "Warning: YUV 4:4:4 was requested, but the native macOS decoder has no "
                        + "proven 4:4:4 format. Stream preparation will use YUV 4:2:0.\n"
                )
            }
            let intent = SessionIntent(
                hostID: host.uuid,
                applicationID: application.id,
                kind: host.currentGameID == application.id ? .resume : .launch,
                preferences: command.preferences,
                effectivePolicy: .resolve(for: command.preferences),
                gamepadMask: command.preferences.multiController ? 0 : 1,
                persistGameControllers: !command.preferences.multiController
            )
            progress.report(.preparingStream(host: host.name, application: application.name))
            return .stream(
                CLIStreamLaunchRequest(
                    intent: intent,
                    standardOutput: transcript.standardOutput,
                    standardError: transcript.standardError
                )
            )
        } catch {
            return terminate(error, transcript: transcript)
        }
    }

    func resolveHost(_ query: String) async throws -> StreamHost {
        let saved = try await service.hosts()
        if let host = saved.first(where: { matches($0, query: query) }) {
            return try await service.refreshHost(id: host.uuid)
        }
        return try await service.addHost(address: query, port: nil)
    }

    func matches(_ host: StreamHost, query: String) -> Bool {
        if host.uuid.caseInsensitiveCompare(query) == .orderedSame
            || host.name.caseInsensitiveCompare(query) == .orderedSame {
            return true
        }
        return host.uniqueAddresses.contains {
            $0.hostname.caseInsensitiveCompare(query) == .orderedSame
                || "\($0.hostname):\($0.port)".caseInsensitiveCompare(query) == .orderedSame
        }
    }

    func isValidPIN(_ pin: String) -> Bool {
        pin.utf8.count == 4 && pin.utf8.allSatisfy { (48 ... 57).contains($0) }
    }

    func terminate(
        _ error: Error,
        transcript: ExecutionTranscript,
        hostResolution: Bool = false
    ) -> CLIExecutionOutcome {
        transcript.writeStandardError(terminatedMessage(for: error))
        let exitCode: CLIExitCode = hostResolution || isHostUnavailable(error)
            ? .hostUnavailable
            : .failure
        return .terminate(transcript.result(exitCode: exitCode))
    }

    func terminatedMessage(for error: Error) -> String {
        let message = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (message.isEmpty ? "The command failed." : message) + "\n"
    }

    func isHostUnavailable(_ error: Error) -> Bool {
        guard let serviceError = error as? UmbraServiceError else { return false }
        switch serviceError {
        case .hostNotFound, .hostUnavailable, .hostNotPaired:
            return true
        default:
            return false
        }
    }

    func emit(_ result: CLIExecutionResult) {
        if !result.standardOutput.isEmpty {
            output.writeStandardOutput(result.standardOutput)
        }
        if !result.standardError.isEmpty {
            output.writeStandardError(result.standardError)
        }
    }
}

private final class ExecutionTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private let output: CLIOutputSink
    private var outputValue = ""
    private var errorValue = ""

    init(output: CLIOutputSink) {
        self.output = output
    }

    var standardOutput: String {
        lock.withLock { outputValue }
    }

    var standardError: String {
        lock.withLock { errorValue }
    }

    func writeStandardOutput(_ value: String) {
        guard !value.isEmpty else { return }
        lock.withLock { outputValue += value }
        output.writeStandardOutput(value)
    }

    func writeStandardError(_ value: String) {
        guard !value.isEmpty else { return }
        lock.withLock { errorValue += value }
        output.writeStandardError(value)
    }

    func result(exitCode: CLIExitCode) -> CLIExecutionResult {
        CLIExecutionResult(
            exitCode: exitCode.rawValue,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }
}
