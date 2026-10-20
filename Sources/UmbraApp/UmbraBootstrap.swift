import Darwin
import Foundation
import UmbraCLI
import UmbraCLIExecution
import UmbraCore
import UmbraIntegration
import UmbraNetworking
import UmbraPairing
import UmbraServices

/// Describes the work the native application must perform for the current process arguments.
enum UmbraLaunchRequest: Sendable {
    /// Opens Umbra without starting a command-line stream.
    case launchApplication
    /// Starts a stream request that was resolved before application initialization.
    case stream(CLIStreamLaunchRequest)
    /// Resolves and starts a command-line stream after native application initialization.
    case deferredStream(processArguments: [String])
}

enum UmbraBootstrap {
    static func resolveLaunchRequest() -> UmbraLaunchRequest {
        let arguments = normalizedProcessArguments(CommandLine.arguments)
        let parser = UmbraCLIParser()
        let parseResult = parser.parseProcessArguments(arguments)
        if let recoveryResult = storageRecoveryResult(for: parseResult) {
            writeStandardOutput(recoveryResult.standardOutput)
            writeStandardError(recoveryResult.standardError)
            exit(recoveryResult.exitCode)
        }
        if case let .terminal(result) = parseResult {
            writeStandardOutput(result.standardOutput)
            writeStandardError(result.standardError)
            exit(result.exitCode)
        }
        if let failure = unpackagedLaunchFailure(
            bundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) {
            writeStandardError(failure.standardError)
            exit(failure.exitCode)
        }
        try? ObsoleteStreamingStateCleanup.performDefaultIfNeeded()
        if let deferredRequest = deferredStreamLaunchRequest(
            for: parseResult,
            processArguments: arguments
        ) {
            return deferredRequest
        }
        if case .ready(command: .launchApplication, warnings: []) = parseResult {
            return .launchApplication
        }
        do {
            let service = try makeHeadlessService()
            let commandResult = parseResult
            let outcome = runAsyncAndWait {
                await execute(commandResult, service: service)
            }
            switch outcome {
            case .launchApplication:
                return .launchApplication
            case let .stream(request):
                return .stream(request)
            case let .terminate(result):
                exit(result.exitCode)
            }
        } catch {
            writeStandardError("\(error.localizedDescription)\n")
            exit(CLIExitCode.failure.rawValue)
        }
    }

    /// Creates the launch handoff that keeps stream resolution out of synchronous app startup.
    ///
    /// - Parameters:
    ///   - parseResult: The initial command-line parse result.
    ///   - processArguments: Normalized process arguments, including the executable path.
    /// - Returns: A deferred stream request, or `nil` for every non-stream command.
    static func deferredStreamLaunchRequest(
        for parseResult: CLIParseResult,
        processArguments: [String]
    ) -> UmbraLaunchRequest? {
        guard case .ready(command: .stream, warnings: _) = parseResult else { return nil }
        return .deferredStream(processArguments: processArguments)
    }

    /// Resolves a stream command after the native application has completed synchronous startup.
    ///
    /// - Parameters:
    ///   - processArguments: Normalized process arguments, including the executable path.
    ///   - defaultStreamingPreferences: The initialized application's saved preferences.
    ///   - service: The initialized application's service used to resolve the host and application.
    /// - Returns: The command-line execution outcome for the deferred stream command.
    static func resolveDeferredStream(
        processArguments: [String],
        defaultStreamingPreferences: StreamingPreferences,
        service: any UmbraCLIExecutionServicing
    ) async -> CLIExecutionOutcome {
        let parser = UmbraCLIParser(defaultStreamingPreferences: defaultStreamingPreferences)
        let parseResult = parser.parseProcessArguments(processArguments)
        return await execute(parseResult, service: service)
    }

    /// Prevents raw build executables from acquiring separate macOS network-privacy identities.
    /// Help/version and explicit local storage recovery are handled before this guard.
    static func unpackagedLaunchFailure(
        bundleURL: URL,
        bundleIdentifier: String?
    ) -> CLIExecutionResult? {
        guard bundleURL.pathExtension == "app", bundleIdentifier == "app.umbra.Umbra" else {
            return .failure(
                "Run the signed Umbra.app, not the raw build executable. "
                    + "Use open /Applications/Umbra.app, or its Contents/MacOS/Umbra executable for CLI commands.\n"
            )
        }
        return nil
    }

    static func storageRecoveryResult(
        for parseResult: CLIParseResult,
        recover: () throws -> UmbraStorageRecoveryResult = {
            try UmbraStorageRecovery.recoverDefaultStorage()
        }
    ) -> CLIExecutionResult? {
        guard case .ready(command: .recoverStorage, warnings: []) = parseResult else {
            return nil
        }
        do {
            let result = try recover()
            return .success(
                "Umbra storage was moved to this recoverable backup:\n"
                    + "\(result.backupURL.path)\n"
                    + "No fresh identity was created. Start Umbra normally to create fresh storage.\n"
            )
        } catch {
            return .failure("Storage recovery failed: \(error.localizedDescription)\n")
        }
    }

    private static func makeHeadlessService() throws -> UmbraApplicationService {
        let identityProvider = FileBackedClientIdentityProvider()
        let uniqueID = try identityProvider.clientID()
        let clientIdentity = try identityProvider.identity()
        let clientProvider = try AuthenticatedGameStreamClientProvider(
            uniqueID: uniqueID,
            identityProvider: identityProvider
        )
        let pairingAdapter = FactoryBackedHostPairingAdapter(
            uniqueID: uniqueID,
            securePortProvider: { address in
                address.port == HostAddress.defaultHTTPPort
                    ? HostAddress.defaultHTTPSPort
                    : UInt16(clamping: max(Int(address.port) - 5, 1))
            },
            identityProvider: identityProvider
        )
        let persistence: JSONFileStore<UmbraSnapshot> = try .applicationSupport()
        return UmbraApplicationService(
            persistence: persistence,
            clientProvider: clientProvider,
            discovery: nil,
            pairingAdapter: pairingAdapter,
            clientIdentityFingerprint: clientIdentity.persistenceFingerprint
        )
    }

    private static func normalizedProcessArguments(_ arguments: [String]) -> [String] {
        guard let executable = arguments.first else { return arguments }
        var normalized = [executable]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("-psn_") {
                index += 1
                continue
            }
            if argument.hasPrefix("-NS") {
                index += 1
                if index < arguments.count, !arguments[index].hasPrefix("-") { index += 1 }
                continue
            }
            normalized.append(argument)
            index += 1
        }
        return normalized
    }

    private static func writeStandardOutput(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    private static func writeStandardError(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    private static func execute(
        _ parseResult: CLIParseResult,
        service: any UmbraCLIExecutionServicing
    ) async -> CLIExecutionOutcome {
        let output = CLIOutputSink(
            standardOutput: writeStandardOutput,
            standardError: writeStandardError
        )
        let executor = UmbraCLICommandExecutor(
            service: service,
            output: output,
            lspService: try? LiveUmbraCLILSPService()
        )
        return await executor.execute(parseResult)
    }

    private static func runAsyncAndWait<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) -> Value {
        let result = BlockingAsyncResult<Value>()
        Task.detached {
            result.fulfill(await operation())
        }
        return result.wait()
    }
}

private final class BlockingAsyncResult<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case waiting
        case finished(Value)
    }

    private let condition = NSCondition()
    private var state: State = .waiting

    func fulfill(_ value: Value) {
        condition.lock()
        state = .finished(value)
        condition.broadcast()
        condition.unlock()
    }

    func wait() -> Value {
        condition.lock()
        defer { condition.unlock() }
        while case .waiting = state { condition.wait() }
        guard case let .finished(value) = state else { preconditionFailure("unreachable") }
        return value
    }
}
