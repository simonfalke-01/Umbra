import Foundation
import Network

/// Native fallback for Moonlight's connection tester. It speaks the same echo protocol to
/// Moonlight's public connectivity-test host and first probes TCP 443 so a missing Internet
/// connection is reported as inconclusive instead of claiming that every stream port is blocked.
public struct NetworkFrameworkConnectivityTester: ConnectivityTesting, Sendable {
    public var server: String
    public var referencePort: UInt16
    public var requiredPorts: [ConnectivityPort]
    public var timeout: Duration

    public init(
        server: String = "qt.conntest.moonlight-stream.org",
        referencePort: UInt16 = 443,
        requiredPorts: [ConnectivityPort] = ConnectivityPort.moonlightRequired,
        timeout: Duration = .seconds(3)
    ) {
        self.server = server
        self.referencePort = referencePort
        self.requiredPorts = requiredPorts
        self.timeout = timeout
    }

    public func testRequiredPorts() async -> ConnectivityTestResult {
        guard await probe(ConnectivityPort(.tcp, referencePort)) else {
            return .inconclusive("The Moonlight connectivity-test server could not be reached on TCP \(referencePort).")
        }

        let failures = await withTaskGroup(of: (ConnectivityPort, Bool).self) { group in
            for port in requiredPorts {
                group.addTask { (port, await probe(port)) }
            }
            var failed: [ConnectivityPort] = []
            for await (port, succeeded) in group where !succeeded { failed.append(port) }
            return failed.sorted(by: Self.portOrder)
        }
        return failures.isEmpty ? .clear : .blocked(failures)
    }

    private func probe(_ target: ConnectivityPort) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: target.port) else { return false }
        let parameters: NWParameters = target.transport == .tcp ? .tcp : .udp
        let connection = NWConnection(host: NWEndpoint.Host(server), port: port, using: parameters)
        let timeoutNanoseconds = UInt64(max(0, timeout.components.seconds)) * 1_000_000_000
            + UInt64(max(0, timeout.components.attoseconds / 1_000_000_000))

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await waitForProbe(connection, transport: target.transport)
                } onCancel: {
                    connection.cancel()
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            connection.cancel()
            return result
        }
    }

    private func waitForProbe(_ connection: NWConnection, transport: ConnectivityProtocol) async -> Bool {
        await withCheckedContinuation { continuation in
            let completion = ProbeCompletion(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready where transport == .tcp:
                    completion.finish(true)
                case .ready:
                    var payload = Data("moonlight-ctest".utf8)
                    payload.append(Data(repeating: 0, count: max(0, 1_040 - payload.count)))
                    connection.send(content: payload, completion: .contentProcessed { error in
                        guard error == nil else {
                            completion.finish(false)
                            return
                        }
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_040) { data, _, _, error in
                            completion.finish(error == nil && !(data?.isEmpty ?? true))
                        }
                    })
                case .failed, .cancelled:
                    completion.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
        }
    }

    private static func portOrder(_ lhs: ConnectivityPort, _ rhs: ConnectivityPort) -> Bool {
        lhs.port == rhs.port ? lhs.transport.rawValue < rhs.transport.rawValue : lhs.port < rhs.port
    }
}

private final class ProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
