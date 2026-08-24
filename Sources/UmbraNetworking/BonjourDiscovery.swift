import Foundation
import Network

public struct DiscoveredHostService: Hashable, Sendable, Identifiable {
    public var name: String
    public var type: String
    public var domain: String
    public var interfaceName: String?

    public var id: String {
        "\(name)|\(type)|\(domain)|\(interfaceName ?? "")"
    }

    public init(name: String, type: String, domain: String, interfaceName: String? = nil) {
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceName = interfaceName
    }
}

public enum DiscoveryEvent: Equatable, Sendable {
    case added(DiscoveredHostService)
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

protocol BonjourBrowserCreating: Sendable {
    func makeBrowser() -> any BonjourBrowsing
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
    func makeBrowser() -> any BonjourBrowsing {
        NWBonjourBrowser()
    }
}

private final class NWBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let browser: NWBrowser

    init() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        browser = NWBrowser(
            for: .bonjour(type: "_nvstream._tcp", domain: "local."),
            using: parameters
        )
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
        return DiscoveredHostService(
            name: name,
            type: type,
            domain: domain,
            interfaceName: interface?.name
        )
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

/// Discovers GameStream/Sunshine hosts using Moonlight's `_nvstream._tcp.local.` service.
public final class NetworkBonjourDiscovery: BonjourDiscovering, @unchecked Sendable {
    private let queue: DispatchQueue
    private let browserFactory: any BonjourBrowserCreating
    private let retryScheduler: any BonjourRetryScheduling
    private let retryPolicy: BonjourRetryPolicy
    private let lock = NSLock()
    private var browser: (any BonjourBrowsing)?
    private var retryCancellation: (any BonjourRetryCancellable)?
    private var eventHandler: (@Sendable (DiscoveryEvent) -> Void)?
    private var knownServices: Set<DiscoveredHostService> = []
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
            retryPolicy: .default
        )
    }

    init(
        queue: DispatchQueue,
        browserFactory: any BonjourBrowserCreating,
        retryScheduler: any BonjourRetryScheduling,
        retryPolicy: BonjourRetryPolicy = .default
    ) {
        self.queue = queue
        self.browserFactory = browserFactory
        self.retryScheduler = retryScheduler
        self.retryPolicy = retryPolicy
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
        let browser = browserFactory.makeBrowser()

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
        let added = services.subtracting(knownServices)
        let removed = knownServices.subtracting(services)
        knownServices = services
        let eventHandler = eventHandler
        lock.unlock()

        added.sorted(by: { $0.id < $1.id }).forEach { eventHandler?(.added($0)) }
        removed.sorted(by: { $0.id < $1.id }).forEach { eventHandler?(.removed($0)) }
    }

    private func isCurrentBrowser(generation: UInt64, browserToken: UInt64) -> Bool {
        isRunning && self.generation == generation && self.browserToken == browserToken && browser != nil
    }
}
