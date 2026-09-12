import Foundation
import Network
import XCTest
@testable import UmbraNetworking

final class BonjourDiscoveryTests: XCTestCase {
    func testRetryPolicyUsesExponentialBackoffWithAnUpperBound() {
        let policy = BonjourRetryPolicy(initialDelay: 0.25, maximumDelay: 5)

        XCTAssertEqual(policy.delay(afterFailure: 1), 0.25)
        XCTAssertEqual(policy.delay(afterFailure: 2), 0.5)
        XCTAssertEqual(policy.delay(afterFailure: 5), 4)
        XCTAssertEqual(policy.delay(afterFailure: 6), 5)
        XCTAssertEqual(policy.delay(afterFailure: 100), 5)
    }

    func testTerminalFailureCancelsBrowserRetriesAndPublishesRecoveredResults() throws {
        let factory = RecordingBonjourBrowserFactory()
        let scheduler = ManualBonjourRetryScheduler()
        let recorder = DiscoveryEventRecorder()
        let discovery = NetworkBonjourDiscovery(
            queue: DispatchQueue(label: "test.umbra.bonjour-recovery"),
            browserFactory: factory,
            retryScheduler: scheduler
        )

        discovery.start { recorder.record($0) }
        let firstBrowser = try XCTUnwrap(factory.browser(at: 0))
        firstBrowser.send(state: .failed("browser failed"))

        XCTAssertEqual(firstBrowser.cancelCount, 1)
        XCTAssertEqual(scheduler.scheduledDelays, [0.25])
        XCTAssertEqual(recorder.events, [.failed("browser failed")])

        scheduler.fireNext()
        let recoveredBrowser = try XCTUnwrap(factory.browser(at: 1))
        let recoveredService = DiscoveredHostService(
            name: "Sunshine",
            type: "_nvstream._tcp.",
            domain: "local."
        )
        recoveredBrowser.send(state: .ready)
        recoveredBrowser.send(services: [recoveredService])

        XCTAssertEqual(recorder.events, [.failed("browser failed"), .added(recoveredService)])

        firstBrowser.send(services: [
            DiscoveredHostService(name: "Stale", type: "_nvstream._tcp.", domain: "local."),
        ])
        XCTAssertEqual(recorder.events, [.failed("browser failed"), .added(recoveredService)])
    }

    func testStopDuringRetryBackoffCancelsRetryAndPreventsBrowserRecreation() throws {
        let factory = RecordingBonjourBrowserFactory()
        let scheduler = ManualBonjourRetryScheduler()
        let recorder = DiscoveryEventRecorder()
        let discovery = NetworkBonjourDiscovery(
            queue: DispatchQueue(label: "test.umbra.bonjour-stop"),
            browserFactory: factory,
            retryScheduler: scheduler
        )

        discovery.start { recorder.record($0) }
        let browser = try XCTUnwrap(factory.browser(at: 0))
        browser.send(state: .failed("browser failed"))
        discovery.stop()

        XCTAssertEqual(scheduler.cancellationCount, 1)
        scheduler.fireNext(includingCancelled: true)
        XCTAssertEqual(factory.browserCount, 1)

        browser.send(state: .failed("stale failure"))
        browser.send(services: [
            DiscoveredHostService(name: "Stale", type: "_nvstream._tcp.", domain: "local."),
        ])
        XCTAssertEqual(recorder.events, [.failed("browser failed")])
    }

    func testDefaultDiscoveryRequestsOnlyLegacyGameStream() {
        let factory = RecordingBonjourBrowserFactory()
        let discovery = NetworkBonjourDiscovery(
            queue: DispatchQueue(label: "test.umbra.bonjour-legacy-only"),
            browserFactory: factory,
            retryScheduler: ManualBonjourRetryScheduler()
        )

        discovery.start { _ in }

        XCTAssertEqual(factory.requestedKinds, [.legacyGameStream])
        discovery.stop()
    }

    func testExplicitLSPDiscoveryRequestsUDPService() {
        let factory = RecordingBonjourBrowserFactory()
        let discovery = NetworkBonjourDiscovery(
            queue: DispatchQueue(label: "test.umbra.bonjour-lsp"),
            browserFactory: factory,
            retryScheduler: ManualBonjourRetryScheduler(),
            serviceKind: .lumenStreamingProtocol
        )

        discovery.start { _ in }

        XCTAssertEqual(factory.requestedKinds, [.lumenStreamingProtocol])
        discovery.stop()
    }

    func testDiscoveredServicesReflectCurrentBrowserSnapshot() throws {
        let factory = RecordingBonjourBrowserFactory()
        let discovery = NetworkBonjourDiscovery(
            queue: DispatchQueue(label: "test.umbra.bonjour-snapshot"),
            browserFactory: factory,
            retryScheduler: ManualBonjourRetryScheduler(),
            serviceKind: .lumenStreamingProtocol
        )
        let first = DiscoveredHostService(
            name: "First",
            type: "_lumen-stream._udp",
            domain: "local."
        )
        let second = DiscoveredHostService(
            name: "Second",
            type: "_lumen-stream._udp",
            domain: "local."
        )

        discovery.start { _ in }
        let browser = try XCTUnwrap(factory.browser(at: 0))
        browser.send(services: [first, second])

        XCTAssertEqual(Set(discovery.discoveredServices), [first, second])

        browser.send(services: [second])

        XCTAssertEqual(discovery.discoveredServices, [second])
        discovery.stop()
        XCTAssertTrue(discovery.discoveredServices.isEmpty)
    }

    func testResolvedServiceUsesSRVTargetPortAndInterfaceMetadata() throws {
        let service = DiscoveredHostService(
            name: "Gaming PC",
            type: "_lumen-stream._udp",
            domain: "lab.local.",
            interfaceName: "en7",
            changeToken: 42
        )
        let resolved = try NetworkBonjourDiscovery.resolvedEndpoint(
            from: .hostPort(host: "lumen-target.lab.local", port: 49_999),
            service: service
        )

        XCTAssertEqual(resolved.targetHost, "lumen-target.lab.local")
        XCTAssertEqual(resolved.port, 49_999)
        XCTAssertEqual(resolved.serviceName, "Gaming PC")
        XCTAssertEqual(resolved.domain, "lab.local.")
        XCTAssertEqual(resolved.interfaceName, "en7")
        XCTAssertEqual(resolved.changeToken, 42)
        XCTAssertThrowsError(try NetworkBonjourDiscovery.resolvedEndpoint(
            from: .service(name: "Gaming PC", type: "_lumen-stream._udp", domain: "local.", interface: nil),
            service: service
        ))
    }

    func testResolvedIPv4NeverReceivesAnInterfaceZone() throws {
        let service = DiscoveredHostService(
            name: "Gaming PC",
            type: "_lumen-stream._udp",
            domain: "local.",
            interfaceName: "en7"
        )
        let address = try XCTUnwrap(IPv4Address("192.168.1.236"))

        let resolved = try NetworkBonjourDiscovery.resolvedEndpoint(
            from: .hostPort(host: .ipv4(address), port: 48_030),
            service: service
        )

        XCTAssertEqual(resolved.targetHost, "192.168.1.236")
        XCTAssertEqual(resolved.interfaceName, "en7")
    }

    func testResolvedIPv6UsesAZoneOnlyForScopedAddresses() throws {
        let linkLocal = try XCTUnwrap(IPv6Address("fe80::1234"))
        let global = try XCTUnwrap(IPv6Address("2001:db8::1234"))

        XCTAssertEqual(
            try NetworkBonjourDiscovery.endpointHost(from: .ipv6(linkLocal), interfaceName: "en7"),
            "fe80::1234%en7"
        )
        XCTAssertEqual(
            try NetworkBonjourDiscovery.endpointHost(from: .ipv6(global), interfaceName: "en7"),
            "2001:db8::1234"
        )
    }
}

private final class RecordingBonjourBrowserFactory: BonjourBrowserCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var browsers: [RecordingBonjourBrowser] = []
    private var kinds: [BonjourServiceKind] = []

    var browserCount: Int { lock.withLock { browsers.count } }
    var requestedKinds: [BonjourServiceKind] { lock.withLock { kinds } }

    func makeBrowser(for kind: BonjourServiceKind) -> any BonjourBrowsing {
        let browser = RecordingBonjourBrowser()
        lock.withLock {
            browsers.append(browser)
            kinds.append(kind)
        }
        return browser
    }

    func browser(at index: Int) -> RecordingBonjourBrowser? {
        lock.withLock { browsers.indices.contains(index) ? browsers[index] : nil }
    }
}

private final class RecordingBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var stateHandler: (@Sendable (BonjourBrowserState) -> Void)?
    private var resultsHandler: (@Sendable (Set<DiscoveredHostService>) -> Void)?
    private var cancellations = 0

    var cancelCount: Int { lock.withLock { cancellations } }

    func setStateUpdateHandler(_ handler: @escaping @Sendable (BonjourBrowserState) -> Void) {
        lock.withLock { stateHandler = handler }
    }

    func setResultsChangedHandler(
        _ handler: @escaping @Sendable (Set<DiscoveredHostService>) -> Void
    ) {
        lock.withLock { resultsHandler = handler }
    }

    func start(queue: DispatchQueue) {}
    func cancel() { lock.withLock { cancellations += 1 } }
    func send(state: BonjourBrowserState) { lock.withLock { stateHandler }?(state) }
    func send(services: Set<DiscoveredHostService>) { lock.withLock { resultsHandler }?(services) }
}

private final class ManualBonjourRetryScheduler: BonjourRetryScheduling, @unchecked Sendable {
    private struct Scheduled {
        let delay: TimeInterval
        let action: @Sendable () -> Void
        let cancellation: ManualBonjourRetryCancellation
    }

    private let lock = NSLock()
    private var scheduled: [Scheduled] = []

    var scheduledDelays: [TimeInterval] { lock.withLock { scheduled.map(\.delay) } }
    var cancellationCount: Int {
        lock.withLock { scheduled.filter { $0.cancellation.isCancelled }.count }
    }

    func schedule(
        after delay: TimeInterval,
        on queue: DispatchQueue,
        action: @escaping @Sendable () -> Void
    ) -> any BonjourRetryCancellable {
        let cancellation = ManualBonjourRetryCancellation()
        lock.withLock {
            scheduled.append(Scheduled(delay: delay, action: action, cancellation: cancellation))
        }
        return cancellation
    }

    func fireNext(includingCancelled: Bool = false) {
        let next = lock.withLock { scheduled.isEmpty ? nil : scheduled.removeFirst() }
        guard let next, includingCancelled || !next.cancellation.isCancelled else { return }
        next.action()
    }
}

private final class ManualBonjourRetryCancellation: BonjourRetryCancellable, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

private final class DiscoveryEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [DiscoveryEvent] = []
    var events: [DiscoveryEvent] { lock.withLock { recordedEvents } }
    func record(_ event: DiscoveryEvent) { lock.withLock { recordedEvents.append(event) } }
}
