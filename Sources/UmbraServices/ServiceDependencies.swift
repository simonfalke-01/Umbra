import Foundation
import Network
import UmbraCore
import UmbraNetworking

public protocol SnapshotPersisting: Sendable {
    func load() async throws -> UmbraSnapshot
    func save(_ snapshot: UmbraSnapshot) async throws
    func update(
        _ transform: @Sendable (UmbraSnapshot) throws -> UmbraSnapshot
    ) async throws -> UmbraSnapshot
}

extension JSONFileStore: SnapshotPersisting where Value == UmbraSnapshot {}

public protocol GameStreamClientProviding: Sendable {
    func client(for host: StreamHost?) -> any GameStreamServing
}

public struct LiveGameStreamClientProvider: GameStreamClientProviding, Sendable {
    public var uniqueID: String
    public var useTrueUniqueID: Bool
    private let plainTransport: any HTTPTransport

    public init(
        uniqueID: String,
        useTrueUniqueID: Bool = false,
        plainTransport: any HTTPTransport = BoundedPlainHTTPTransport()
    ) {
        self.uniqueID = uniqueID
        self.useTrueUniqueID = useTrueUniqueID
        self.plainTransport = plainTransport
    }

    public func client(for host: StreamHost?) -> any GameStreamServing {
        let evaluator: (any ServerTrustEvaluating)?
        if let certificate = host?.serverCertificate, !certificate.isEmpty {
            evaluator = PinnedCertificateEvaluator(certificateDER: certificate)
        } else {
            evaluator = nil
        }
        let secureTransport = URLSessionTransport(trustEvaluator: evaluator)
        return GameStreamClient(
            transport: SchemeSelectingHTTPTransport(
                plainTransport: plainTransport,
                secureTransport: secureTransport
            ),
            requestBuilder: GameStreamRequestBuilder(uniqueID: uniqueID, useTrueUniqueID: useTrueUniqueID)
        )
    }
}

public protocol DiscoveredServiceResolving: Sendable {
    func resolve(_ service: DiscoveredHostService) async throws -> HostAddress
}

public struct LocalNameServiceResolver: DiscoveredServiceResolving, Sendable {
    public init() {}

    public func resolve(_ service: DiscoveredHostService) async throws -> HostAddress {
        let trimmed = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UmbraNetworkingError.invalidAddress(service.name) }
        let endpoint = NWEndpoint.service(
            name: trimmed,
            type: service.type,
            domain: service.domain,
            interface: nil
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        let box = ServiceResolutionContinuationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint else {
                            box.finish(.failure(UmbraNetworkingError.invalidAddress(trimmed)))
                            connection.cancel()
                            return
                        }
                        box.finish(.success(HostAddress(
                            host: String(describing: host),
                            port: port.rawValue
                        )))
                        connection.cancel()
                    case let .failed(error):
                        box.finish(.failure(error))
                    case .cancelled:
                        box.finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue(label: "app.umbra.bonjour-resolve"))
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    box.finish(.failure(URLError(.timedOut)))
                    connection.cancel()
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

private final class ServiceResolutionContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HostAddress, Error>?
    private var result: Result<HostAddress, Error>?

    func install(_ continuation: CheckedContinuation<HostAddress, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<HostAddress, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

public protocol ServiceClock: Sendable {
    func sleep(for interval: Duration) async throws
}

public struct ContinuousServiceClock: ServiceClock, Sendable {
    public init() {}

    public func sleep(for interval: Duration) async throws {
        try await ContinuousClock().sleep(for: interval)
    }
}

public protocol ConnectivityTesting: Sendable {
    func testRequiredPorts() async -> ConnectivityTestResult
}

public protocol HostPairingAdapting: Sendable {
    func pair(
        host: HostAddress,
        pin: String,
        appVersion: String,
        isNVIDIAServerSoftware: Bool,
        progress: @escaping @Sendable (PairingProgress) -> Void
    ) async throws -> Data
    func cancel(hostID: String) async
}

public protocol StreamSessionDriving: Sendable {
    @discardableResult
    func prepare(_ bootstrap: StreamBootstrap) async throws -> StreamPreparationResult
    func run(
        _ bootstrap: StreamBootstrap,
        events: @escaping @Sendable (StreamDriverEvent) -> Void
    ) async throws -> SessionResult
    func waitUntilPrepared(sessionID: UUID) async throws
    func cancel() async
}

public extension StreamSessionDriving {
    func waitUntilPrepared(sessionID: UUID) async throws {}
}

public protocol RemoteInputCredentialProviding: Sendable {
    func makeCredentials() throws -> RemoteInputCredentials
}

public struct SecureRemoteInputCredentialProvider: RemoteInputCredentialProviding, Sendable {
    public init() {}

    public func makeCredentials() throws -> RemoteInputCredentials {
        var generator = SystemRandomNumberGenerator()
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        var iv = Data(repeating: 0, count: 16)
        for index in 0..<4 {
            iv[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return try RemoteInputCredentials(key: key, initializationVector: iv)
    }
}

public protocol UUIDProviding: Sendable {
    func makeUUID() -> UUID
}

public struct SystemUUIDProvider: UUIDProviding, Sendable {
    public init() {}
    public func makeUUID() -> UUID { UUID() }
}
