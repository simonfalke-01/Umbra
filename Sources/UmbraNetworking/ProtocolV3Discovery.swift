import Darwin
import Foundation
import Network

public struct ProtocolV3ResolvedEndpoint: Equatable, Sendable {
    public let hostname: String
    public let port: UInt16

    public init(hostname: String, port: UInt16) {
        self.hostname = hostname
        self.port = port
    }
}

public struct ProtocolV3DiscoveredServiceRecord: Equatable, Sendable {
    public let serviceID: String
    public let displayName: String
    public let hostID: Data
    public let hostname: String
    public let hostnameIsIPLiteral: Bool
    public let port: UInt16
    public let capabilities: UInt64

    public init(
        service: DiscoveredHostService,
        resolvedHost: String,
        resolvedPort: UInt16
    ) throws {
        let normalizedType = service.type.hasSuffix(".")
            ? String(service.type.dropLast())
            : service.type
        guard normalizedType == "_lumen-v3._udp",
              service.domain.lowercased() == "local.",
              !service.name.isEmpty,
              service.name.utf8.count <= 63,
              Set(service.txtRecord.keys) == Set(["v", "id", "port", "caps"]),
              service.txtRecord["v"] == "3",
              let identifier = service.txtRecord["id"],
              identifier.count == 32,
              identifier.allSatisfy({ $0.isNumber || ("a" ... "f").contains($0) }),
              let hostID = Self.decodeHex(identifier),
              hostID.contains(where: { $0 != 0 }),
              let portText = service.txtRecord["port"],
              let advertisedPort = UInt16(portText),
              advertisedPort != 0,
              String(advertisedPort) == portText,
              advertisedPort == resolvedPort,
              let capabilityText = service.txtRecord["caps"],
              capabilityText.count == 16,
              capabilityText.allSatisfy({ $0.isNumber || ("a" ... "f").contains($0) }),
              let capabilities = UInt64(capabilityText, radix: 16),
              !resolvedHost.isEmpty,
              resolvedHost.utf8.count <= 253,
              resolvedHost.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            throw ProtocolV3DiscoveryError.invalidAdvertisement
        }
        serviceID = service.id
        displayName = service.name
        self.hostID = hostID
        hostname = resolvedHost
        hostnameIsIPLiteral = Self.isIPLiteral(resolvedHost)
        port = advertisedPort
        self.capabilities = capabilities
    }

    private static func decodeHex(_ value: String) -> Data? {
        var result = Data()
        result.reserveCapacity(value.count / 2)
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let next = value.index(cursor, offsetBy: 2)
            guard let byte = UInt8(value[cursor..<next], radix: 16) else { return nil }
            result.append(byte)
            cursor = next
        }
        return result
    }

    static func advertisedHostID(in service: DiscoveredHostService) -> Data? {
        guard let identifier = service.txtRecord["id"],
              identifier.count == 32,
              identifier.allSatisfy({ $0.isNumber || ("a" ... "f").contains($0) }),
              let hostID = decodeHex(identifier),
              hostID.contains(where: { $0 != 0 }) else {
            return nil
        }
        return hostID
    }

    private static func isIPLiteral(_ hostname: String) -> Bool {
        var address = hostname
        if address.hasPrefix("["), address.hasSuffix("]") {
            address.removeFirst()
            address.removeLast()
        }
        if let zone = address.firstIndex(of: "%") {
            address = String(address[..<zone])
        }
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        return address.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }
}

public enum ProtocolV3DiscoveryEvent: Equatable, Sendable {
    case available(ProtocolV3DiscoveredServiceRecord)
    case unavailable(Data)
    case failed(String)
}

public enum ProtocolV3DiscoveryError: Error, Equatable, Sendable {
    case invalidAdvertisement
    case invalidResolvedEndpoint
}

public protocol ProtocolV3Discovering: AnyObject, Sendable {
    func start(eventHandler: @escaping @Sendable (ProtocolV3DiscoveryEvent) -> Void)
    func stop()
}

public protocol ProtocolV3ServiceResolving: Sendable {
    func resolve(_ service: DiscoveredHostService) async throws -> ProtocolV3ResolvedEndpoint
}

public struct NetworkProtocolV3ServiceResolver: ProtocolV3ServiceResolving, Sendable {
    public init() {}

    public func resolve(_ service: DiscoveredHostService) async throws -> ProtocolV3ResolvedEndpoint {
        let endpoint = service.networkEndpoint ?? NWEndpoint.service(
            name: service.name,
            type: service.type,
            domain: service.domain,
            interface: nil
        )
        let connection = NWConnection(to: endpoint, using: .udp)
        let box = ProtocolV3ResolutionContinuationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint else {
                            box.finish(.failure(ProtocolV3DiscoveryError.invalidResolvedEndpoint))
                            connection.cancel()
                            return
                        }
                        box.finish(.success(ProtocolV3ResolvedEndpoint(
                            hostname: String(describing: host),
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
                connection.start(queue: DispatchQueue(label: "app.umbra.protocol-v3-resolve"))
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

public final class NetworkProtocolV3Discovery: ProtocolV3Discovering, @unchecked Sendable {
    private let source: any BonjourDiscovering
    private let resolver: any ProtocolV3ServiceResolving
    private let lock = NSLock()
    private var eventHandler: (@Sendable (ProtocolV3DiscoveryEvent) -> Void)?
    private var resolutionTasks: [String: Task<Void, Never>] = [:]
    private var resolutionTokens: [String: UUID] = [:]
    private var candidateHostIDs: [String: Data] = [:]
    private var services: [String: ProtocolV3DiscoveredServiceRecord] = [:]
    private var advertised: [Data: ProtocolV3DiscoveredServiceRecord] = [:]
    private var generation: UInt64 = 0
    private var running = false

    public convenience init() {
        self.init(
            source: NetworkBonjourDiscovery(serviceKind: .modernLumenV3),
            resolver: NetworkProtocolV3ServiceResolver()
        )
    }

    init(source: any BonjourDiscovering, resolver: any ProtocolV3ServiceResolving) {
        self.source = source
        self.resolver = resolver
    }

    public func start(eventHandler: @escaping @Sendable (ProtocolV3DiscoveryEvent) -> Void) {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        generation &+= 1
        let generation = generation
        self.eventHandler = eventHandler
        lock.unlock()
        source.start { [weak self] event in
            self?.handle(event, generation: generation)
        }
    }

    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        generation &+= 1
        eventHandler = nil
        let tasks = Array(resolutionTasks.values)
        resolutionTasks.removeAll()
        resolutionTokens.removeAll()
        candidateHostIDs.removeAll()
        services.removeAll()
        advertised.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
        source.stop()
    }

    private func handle(_ event: DiscoveryEvent, generation: UInt64) {
        switch event {
        case let .added(service), let .updated(_, new: service):
            resolve(service, generation: generation)
        case let .removed(service):
            remove(serviceID: service.id, generation: generation)
        case let .failed(message):
            publish(.failed(message), generation: generation)
        }
    }

    private func resolve(_ service: DiscoveredHostService, generation: UInt64) {
        guard let candidateHostID = ProtocolV3DiscoveredServiceRecord.advertisedHostID(in: service) else {
            publish(
                .failed("Invalid _lumen-v3._udp advertisement: invalid host id"),
                generation: generation
            )
            return
        }
        let token = UUID()
        lock.lock()
        guard running, self.generation == generation else {
            lock.unlock()
            return
        }
        resolutionTasks[service.id]?.cancel()
        resolutionTokens[service.id] = token
        candidateHostIDs[service.id] = candidateHostID
        let resolver = resolver
        let task = Task { [weak self] in
            do {
                let endpoint = try await resolver.resolve(service)
                try Task.checkCancellation()
                let record = try ProtocolV3DiscoveredServiceRecord(
                    service: service,
                    resolvedHost: endpoint.hostname,
                    resolvedPort: endpoint.port
                )
                self?.install(record, token: token, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.resolutionFailed(
                    serviceID: service.id,
                    token: token,
                    generation: generation,
                    error: error
                )
            }
        }
        resolutionTasks[service.id] = task
        lock.unlock()
    }

    private func install(_ record: ProtocolV3DiscoveredServiceRecord, token: UUID, generation: UInt64) {
        lock.lock()
        guard running, self.generation == generation,
              resolutionTokens[record.serviceID] == token else {
            lock.unlock()
            return
        }
        resolutionTasks[record.serviceID] = nil
        resolutionTokens[record.serviceID] = nil
        let previousHostID = services[record.serviceID]?.hostID
        services[record.serviceID] = record
        var events: [ProtocolV3DiscoveryEvent] = []
        if let previousHostID, previousHostID != record.hostID {
            updateAdvertisement(for: previousHostID, events: &events)
        }
        updateAdvertisement(for: record.hostID, events: &events)
        let handler = eventHandler
        lock.unlock()
        events.forEach { handler?($0) }
    }

    private func remove(serviceID: String, generation: UInt64) {
        lock.lock()
        guard running, self.generation == generation else {
            lock.unlock()
            return
        }
        resolutionTasks.removeValue(forKey: serviceID)?.cancel()
        resolutionTokens[serviceID] = nil
        let candidateHostID = candidateHostIDs.removeValue(forKey: serviceID)
        guard let removed = services.removeValue(forKey: serviceID) else {
            if let candidateHostID {
                var events: [ProtocolV3DiscoveryEvent] = []
                updateAdvertisement(for: candidateHostID, events: &events)
                let handler = eventHandler
                lock.unlock()
                events.forEach { handler?($0) }
                return
            }
            lock.unlock()
            return
        }
        var events: [ProtocolV3DiscoveryEvent] = []
        updateAdvertisement(for: removed.hostID, events: &events)
        if let candidateHostID, candidateHostID != removed.hostID {
            updateAdvertisement(for: candidateHostID, events: &events)
        }
        let handler = eventHandler
        lock.unlock()
        events.forEach { handler?($0) }
    }

    private func resolutionFailed(
        serviceID: String,
        token: UUID,
        generation: UInt64,
        error: Error
    ) {
        lock.lock()
        guard running, self.generation == generation,
              resolutionTokens[serviceID] == token else {
            lock.unlock()
            return
        }
        resolutionTasks[serviceID] = nil
        resolutionTokens[serviceID] = nil
        var events: [ProtocolV3DiscoveryEvent] = []
        if let existing = services[serviceID] {
            candidateHostIDs[serviceID] = existing.hostID
        } else if let hostID = candidateHostIDs.removeValue(forKey: serviceID) {
            updateAdvertisement(for: hostID, events: &events)
        }
        let handler = eventHandler
        lock.unlock()
        events.forEach { handler?($0) }
        handler?(.failed("Invalid _lumen-v3._udp advertisement: \(error)"))
    }

    private func updateAdvertisement(
        for hostID: Data,
        events: inout [ProtocolV3DiscoveryEvent]
    ) {
        let preferredServiceID = candidateHostIDs
            .filter { $0.value == hostID }
            .map(\.key)
            .min()
        let selected = preferredServiceID.flatMap { services[$0] }
        if let selected {
            guard advertised[hostID] != selected else { return }
            advertised[hostID] = selected
            events.append(.available(selected))
        } else if advertised.removeValue(forKey: hostID) != nil {
            events.append(.unavailable(hostID))
        }
    }

    private func publish(_ event: ProtocolV3DiscoveryEvent, generation: UInt64) {
        lock.lock()
        let handler = running && self.generation == generation ? eventHandler : nil
        lock.unlock()
        handler?(event)
    }
}

private final class ProtocolV3ResolutionContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProtocolV3ResolvedEndpoint, Error>?
    private var result: Result<ProtocolV3ResolvedEndpoint, Error>?

    func install(_ continuation: CheckedContinuation<ProtocolV3ResolvedEndpoint, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<ProtocolV3ResolvedEndpoint, Error>) {
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
