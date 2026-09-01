import Foundation
import Network

/// Network protocol advertised by a discovered host service.
public enum DiscoveredHostProtocol: Hashable, Sendable {
    /// Moonlight-compatible GameStream over `_nvstream._tcp`.
    case legacyGameStream

    /// Native Lumen Streaming Protocol over `_lumen-stream._udp`.
    case lumenStreamingProtocol
}

public struct DiscoveredHostService: Hashable, Sendable, Identifiable {
    public var name: String
    public var type: String
    public var domain: String
    public var interfaceName: String?
    public var txtRecord: [String: String]
    public var changeToken: UInt64
    var networkEndpoint: NWEndpoint?

    public var id: String {
        "\(name)|\(type)|\(domain)|\(interfaceName ?? "")"
    }

    public init(
        name: String,
        type: String,
        domain: String,
        interfaceName: String? = nil,
        txtRecord: [String: String] = [:],
        changeToken: UInt64 = 0
    ) {
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceName = interfaceName
        self.txtRecord = txtRecord
        self.changeToken = changeToken
        networkEndpoint = nil
    }
}

/// Exact host/port selected by Network.framework for one Bonjour SRV service.
public struct ResolvedBonjourServiceEndpoint: Hashable, Sendable {
    public var targetHost: String
    public var port: UInt16
    public var serviceName: String
    public var serviceType: String
    public var domain: String
    public var interfaceName: String?
    public var changeToken: UInt64

    public init(
        targetHost: String,
        port: UInt16,
        serviceName: String,
        serviceType: String,
        domain: String,
        interfaceName: String? = nil,
        changeToken: UInt64 = 0
    ) {
        self.targetHost = targetHost
        self.port = port
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.domain = domain
        self.interfaceName = interfaceName
        self.changeToken = changeToken
    }
}

/// Bounded Bonjour endpoint-resolution failures.
public enum BonjourEndpointResolutionError: Error, Equatable, Sendable {
    case unavailable
    case invalidEndpoint
    case timeout
}

public enum DiscoveryEvent: Equatable, Sendable {
    case added(DiscoveredHostService)
    case updated(old: DiscoveredHostService, new: DiscoveredHostService)
    case removed(DiscoveredHostService)
    case failed(String)
}

public protocol BonjourDiscovering: AnyObject, Sendable {
    func start(eventHandler: @escaping @Sendable (DiscoveryEvent) -> Void)
    func stop()
}

enum BonjourBrowserState: Sendable {
    case ready
    case failed(String)
    case cancelled
    case transient
}

protocol BonjourBrowsing: AnyObject, Sendable {
    func setStateUpdateHandler(_ handler: @escaping @Sendable (BonjourBrowserState) -> Void)
    func setResultsChangedHandler(_ handler: @escaping @Sendable (Set<DiscoveredHostService>) -> Void)
    func start(queue: DispatchQueue)
    func cancel()
}

enum BonjourServiceKind: Hashable, Sendable {
    case legacyGameStream
    case lumenStreamingProtocol

    init(_ serviceProtocol: DiscoveredHostProtocol) {
        switch serviceProtocol {
        case .legacyGameStream:
            self = .legacyGameStream
        case .lumenStreamingProtocol:
            self = .lumenStreamingProtocol
        }
    }
}

protocol BonjourBrowserCreating: Sendable {
    func makeBrowser(for kind: BonjourServiceKind) -> any BonjourBrowsing
}

protocol BonjourRetryCancellable: AnyObject, Sendable {
    func cancel()
}

protocol BonjourRetryScheduling: Sendable {
    func schedule(
        after delay: TimeInterval,
        on queue: DispatchQueue,
        action: @escaping @Sendable () -> Void
    ) -> any BonjourRetryCancellable
}

struct BonjourRetryPolicy: Sendable {
    var initialDelay: TimeInterval
    var maximumDelay: TimeInterval

    static let `default` = BonjourRetryPolicy(initialDelay: 0.25, maximumDelay: 5)

    func delay(afterFailure failureCount: Int) -> TimeInterval {
        guard failureCount > 1 else { return initialDelay }
        let exponent = min(failureCount - 1, 16)
        return min(initialDelay * pow(2, Double(exponent)), maximumDelay)
    }
}

private struct NWBonjourBrowserFactory: BonjourBrowserCreating {
    func makeBrowser(for kind: BonjourServiceKind) -> any BonjourBrowsing {
        NWBonjourBrowser(kind: kind)
    }
}

private final class NWBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let browser: NWBrowser

    init(kind: BonjourServiceKind) {
        let parameters: NWParameters
        let descriptor: NWBrowser.Descriptor
        switch kind {
        case .legacyGameStream:
            parameters = .tcp
            descriptor = .bonjour(type: "_nvstream._tcp", domain: "local.")
        case .lumenStreamingProtocol:
            parameters = .udp
            descriptor = .bonjour(type: "_lumen-stream._udp", domain: "local.")
        }
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: descriptor, using: parameters)
    }

    func setStateUpdateHandler(_ handler: @escaping @Sendable (BonjourBrowserState) -> Void) {
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                handler(.ready)
            case .failed(let error):
                handler(.failed(String(describing: error)))
            case .cancelled:
                handler(.cancelled)
            default:
                handler(.transient)
            }
        }
    }

    func setResultsChangedHandler(
        _ handler: @escaping @Sendable (Set<DiscoveredHostService>) -> Void
    ) {
        browser.browseResultsChangedHandler = { results, _ in
            handler(Set(results.compactMap(Self.service(from:))))
        }
    }

    func start(queue: DispatchQueue) {
        browser.start(queue: queue)
    }

    func cancel() {
        browser.cancel()
    }

    private static func service(from result: NWBrowser.Result) -> DiscoveredHostService? {
        guard case let .service(name, type, domain, interface) = result.endpoint else { return nil }
        let txtRecord: [String: String]
        if case let .bonjour(record) = result.metadata {
            txtRecord = record.dictionary
        } else {
            txtRecord = [:]
        }
        var service = DiscoveredHostService(
            name: name,
            type: type,
            domain: domain,
            interfaceName: interface?.name,
            txtRecord: txtRecord,
            changeToken: UInt64(bitPattern: Int64(result.hashValue))
        )
        service.networkEndpoint = result.endpoint
        return service
    }
}

private struct DispatchBonjourRetryScheduler: BonjourRetryScheduling {
    func schedule(
        after delay: TimeInterval,
        on queue: DispatchQueue,
        action: @escaping @Sendable () -> Void
    ) -> any BonjourRetryCancellable {
        let workItem = DispatchWorkItem(block: action)
        let cancellation = DispatchBonjourRetryCancellation(workItem: workItem)
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return cancellation
    }
}

private final class DispatchBonjourRetryCancellation: BonjourRetryCancellable, @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

/// Discovers either legacy GameStream or native LSP hosts through Bonjour.
public final class NetworkBonjourDiscovery: BonjourDiscovering, @unchecked Sendable {
    private let queue: DispatchQueue
    private let browserFactory: any BonjourBrowserCreating
    private let retryScheduler: any BonjourRetryScheduling
    private let retryPolicy: BonjourRetryPolicy
    private let serviceKind: BonjourServiceKind
    private let lock = NSLock()
    private var browser: (any BonjourBrowsing)?
    private var retryCancellation: (any BonjourRetryCancellable)?
    private var eventHandler: (@Sendable (DiscoveryEvent) -> Void)?
    private var knownServices: [String: DiscoveredHostService] = [:]
    private var generation: UInt64 = 0
    private var browserToken: UInt64 = 0
    private var retryToken: UInt64 = 0
    private var consecutiveFailures = 0
    private var isRunning = false

    public convenience init(queue: DispatchQueue = DispatchQueue(label: "app.umbra.bonjour-discovery")) {
        self.init(
            queue: queue,
            browserFactory: NWBonjourBrowserFactory(),
            retryScheduler: DispatchBonjourRetryScheduler(),
            retryPolicy: .default,
            serviceKind: .legacyGameStream
        )
    }

    /// Creates a discovery browser for one explicit streaming protocol.
    ///
    /// - Parameters:
    ///   - serviceProtocol: Legacy GameStream or native LSP service family.
    ///   - queue: Private browser and retry queue.
    public convenience init(
        serviceProtocol: DiscoveredHostProtocol,
        queue: DispatchQueue = DispatchQueue(label: "app.umbra.bonjour-discovery")
    ) {
        self.init(
            queue: queue,
            browserFactory: NWBonjourBrowserFactory(),
            retryScheduler: DispatchBonjourRetryScheduler(),
            retryPolicy: .default,
            serviceKind: BonjourServiceKind(serviceProtocol)
        )
    }

    /// Resolves one discovered SRV service to Network.framework's selected remote host and port.
    public func resolveEndpoint(
        for service: DiscoveredHostService,
        timeout: Duration = .seconds(3)
    ) async throws -> ResolvedBonjourServiceEndpoint {
        guard let endpoint = service.networkEndpoint else {
            throw BonjourEndpointResolutionError.unavailable
        }
        return try await NWBonjourEndpointResolution(
            endpoint: endpoint,
            service: service,
            queue: queue
        ).resolve(timeout: timeout)
    }

    static func resolvedEndpoint(
        from endpoint: NWEndpoint,
        service: DiscoveredHostService
    ) throws -> ResolvedBonjourServiceEndpoint {
        guard case let .hostPort(host, port) = endpoint, port.rawValue != 0 else {
            throw BonjourEndpointResolutionError.invalidEndpoint
        }
        let hostValue: String
        switch host {
        case .name(let name, _):
            hostValue = name
        case .ipv4, .ipv6:
            hostValue = host.debugDescription
        @unknown default:
            throw BonjourEndpointResolutionError.invalidEndpoint
        }
        let trimmedHost = hostValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw BonjourEndpointResolutionError.invalidEndpoint }
        return .init(
            targetHost: trimmedHost,
            port: port.rawValue,
            serviceName: service.name,
            serviceType: service.type,
            domain: service.domain,
            interfaceName: host.interface?.name ?? service.interfaceName,
            changeToken: service.changeToken
        )
    }

    convenience init(
        serviceKind: BonjourServiceKind,
        queue: DispatchQueue = DispatchQueue(label: "app.umbra.bonjour-discovery")
    ) {
        self.init(
            queue: queue,
            browserFactory: NWBonjourBrowserFactory(),
            retryScheduler: DispatchBonjourRetryScheduler(),
            retryPolicy: .default,
            serviceKind: serviceKind
        )
    }

    init(
        queue: DispatchQueue,
        browserFactory: any BonjourBrowserCreating,
        retryScheduler: any BonjourRetryScheduling,
        retryPolicy: BonjourRetryPolicy = .default,
        serviceKind: BonjourServiceKind = .legacyGameStream
    ) {
        self.queue = queue
        self.browserFactory = browserFactory
        self.retryScheduler = retryScheduler
        self.retryPolicy = retryPolicy
        self.serviceKind = serviceKind
    }

    public func start(eventHandler: @escaping @Sendable (DiscoveryEvent) -> Void) {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        generation &+= 1
        let generation = generation
        self.eventHandler = eventHandler
        consecutiveFailures = 0
        lock.unlock()

        launchBrowser(for: generation)
    }

    public func stop() {
        lock.lock()
        isRunning = false
        generation &+= 1
        browserToken &+= 1
        retryToken &+= 1
        let browser = self.browser
        let retryCancellation = self.retryCancellation
        self.browser = nil
        self.retryCancellation = nil
        eventHandler = nil
        knownServices.removeAll()
        consecutiveFailures = 0
        lock.unlock()

        retryCancellation?.cancel()
        browser?.cancel()
    }

    private func launchBrowser(for generation: UInt64) {
        let browser = browserFactory.makeBrowser(for: serviceKind)

        lock.lock()
        guard isRunning, self.generation == generation, self.browser == nil else {
            lock.unlock()
            browser.cancel()
            return
        }
        browserToken &+= 1
        let browserToken = browserToken
        self.browser = browser
        browser.setStateUpdateHandler { [weak self] state in
            self?.process(state: state, generation: generation, browserToken: browserToken)
        }
        browser.setResultsChangedHandler { [weak self] services in
            self?.process(services: services, generation: generation, browserToken: browserToken)
        }
        browser.start(queue: queue)
        lock.unlock()
    }

    private func process(
        state: BonjourBrowserState,
        generation: UInt64,
        browserToken: UInt64
    ) {
        switch state {
        case .ready:
            lock.lock()
            if isCurrentBrowser(generation: generation, browserToken: browserToken) {
                consecutiveFailures = 0
            }
            lock.unlock()
        case .failed(let message):
            recoverFromFailure(message, generation: generation, browserToken: browserToken)
        case .cancelled, .transient:
            break
        }
    }

    private func recoverFromFailure(
        _ message: String,
        generation: UInt64,
        browserToken: UInt64
    ) {
        lock.lock()
        guard isCurrentBrowser(generation: generation, browserToken: browserToken) else {
            lock.unlock()
            return
        }
        let failedBrowser = browser
        browser = nil
        consecutiveFailures += 1
        let retryDelay = retryPolicy.delay(afterFailure: consecutiveFailures)
        retryToken &+= 1
        let retryToken = retryToken
        let eventHandler = eventHandler
        lock.unlock()

        failedBrowser?.cancel()
        eventHandler?(.failed(message))

        let retryCancellation = retryScheduler.schedule(after: retryDelay, on: queue) { [weak self] in
            self?.performRetry(generation: generation, retryToken: retryToken)
        }

        lock.lock()
        guard isRunning, self.generation == generation, self.retryToken == retryToken else {
            lock.unlock()
            retryCancellation.cancel()
            return
        }
        self.retryCancellation = retryCancellation
        lock.unlock()
    }

    private func performRetry(generation: UInt64, retryToken: UInt64) {
        lock.lock()
        guard isRunning, self.generation == generation, self.retryToken == retryToken else {
            lock.unlock()
            return
        }
        retryCancellation = nil
        lock.unlock()

        launchBrowser(for: generation)
    }

    private func process(
        services: Set<DiscoveredHostService>,
        generation: UInt64,
        browserToken: UInt64
    ) {
        lock.lock()
        guard isCurrentBrowser(generation: generation, browserToken: browserToken) else {
            lock.unlock()
            return
        }
        var next: [String: DiscoveredHostService] = [:]
        for service in services.sorted(by: { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.changeToken < rhs.changeToken
        }) {
            next[service.id] = service
        }
        let previous = knownServices
        let removed = previous.keys.filter { next[$0] == nil }.sorted()
        let added = next.keys.filter { previous[$0] == nil }.sorted()
        let updated = next.keys.filter {
            guard let old = previous[$0], let new = next[$0] else { return false }
            return old != new
        }.sorted()
        knownServices = next
        let eventHandler = eventHandler
        lock.unlock()

        removed.compactMap { previous[$0] }.forEach { eventHandler?(.removed($0)) }
        updated.forEach { id in
            if let old = previous[id], let new = next[id] {
                eventHandler?(.updated(old: old, new: new))
            }
        }
        added.compactMap { next[$0] }.forEach { eventHandler?(.added($0)) }
    }

    private func isCurrentBrowser(generation: UInt64, browserToken: UInt64) -> Bool {
        isRunning && self.generation == generation && self.browserToken == browserToken && browser != nil
    }
}

private final class NWBonjourEndpointResolution: @unchecked Sendable {
    private let connection: NWConnection
    private let service: DiscoveredHostService
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ResolvedBonjourServiceEndpoint, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var finished = false

    init(endpoint: NWEndpoint, service: DiscoveredHostService, queue: DispatchQueue) {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        connection = NWConnection(to: endpoint, using: parameters)
        self.service = service
        self.queue = queue
    }

    func resolve(timeout: Duration) async throws -> ResolvedBonjourServiceEndpoint {
        let timeoutSeconds = max(0.1, Self.seconds(timeout))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = lock.withLock { () -> Bool in
                    guard !finished else { return false }
                    self.continuation = continuation
                    return true
                }
                guard shouldStart else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        guard let endpoint = connection.currentPath?.remoteEndpoint else {
                            finish(.failure(BonjourEndpointResolutionError.invalidEndpoint))
                            return
                        }
                        do {
                            finish(.success(try NetworkBonjourDiscovery.resolvedEndpoint(
                                from: endpoint,
                                service: service
                            )))
                        } catch {
                            finish(.failure(error))
                        }
                    case .failed, .cancelled:
                        finish(.failure(BonjourEndpointResolutionError.unavailable))
                    default:
                        break
                    }
                }
                let timeoutWorkItem = DispatchWorkItem { [self] in
                    finish(.failure(BonjourEndpointResolutionError.timeout))
                }
                lock.withLock { self.timeoutWorkItem = timeoutWorkItem }
                queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)
                connection.start(queue: queue)
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<ResolvedBonjourServiceEndpoint, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<ResolvedBonjourServiceEndpoint, Error>? in
            guard !finished else { return nil }
            finished = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            defer { self.continuation = nil }
            return self.continuation
        }
        guard let continuation else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
