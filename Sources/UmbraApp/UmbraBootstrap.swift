import Darwin
import Foundation
import UmbraCLI
import UmbraCLIExecution
import UmbraCore
import UmbraIntegration
import UmbraNetworking
import UmbraPairing
import UmbraServices

enum UmbraLaunchRequest: Sendable {
    case launchApplication
    case stream(SessionIntent)
}

enum UmbraBootstrap {
    static func resolveLaunchRequest() -> UmbraLaunchRequest {
        let arguments = normalizedProcessArguments(CommandLine.arguments)
        var parser = UmbraCLIParser()
        var parseResult = parser.parseProcessArguments(arguments)
        if case .ready(command: .stream, warnings: _) = parseResult,
           let store: JSONFileStore<UmbraSnapshot> = try? .applicationSupport(),
           let snapshot = runAsyncAndWait({ try? await store.load() }) {
            parser.defaultStreamingPreferences = snapshot.preferences
            parseResult = parser.parseProcessArguments(arguments)
        }
        if case .ready(command: .launchApplication, warnings: []) = parseResult {
            return .launchApplication
        }
        if case let .terminal(result) = parseResult {
            writeStandardOutput(result.standardOutput)
            writeStandardError(result.standardError)
            exit(result.exitCode)
        }

        do {
            let service = try makeHeadlessService()
            let output = CLIOutputSink(
                standardOutput: writeStandardOutput,
                standardError: writeStandardError
            )
            let executor = UmbraCLICommandExecutor(service: service, output: output)
            let commandResult = parseResult
            let outcome = runAsyncAndWait { await executor.execute(commandResult) }
            switch outcome {
            case .launchApplication:
                return .launchApplication
            case let .stream(request):
                return .stream(request.intent)
            case let .terminate(result):
                exit(result.exitCode)
            }
        } catch {
            writeStandardError("\(error.localizedDescription)\n")
            exit(CLIExitCode.failure.rawValue)
        }
    }

    private static func makeHeadlessService() throws -> UmbraApplicationService {
        let identityProvider = FileBackedClientIdentityProvider()
        let uniqueID = try identityProvider.clientID()
        let clientIdentity = try identityProvider.identity()
        let compatibilityVersion = NVIDIAServerCompatibilityUpdater().cachedMaximumVersion
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
            clientIdentityFingerprint: clientIdentity.persistenceFingerprint,
            maximumSupportedNVIDIAVersion: compatibilityVersion
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
