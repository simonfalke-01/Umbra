import Foundation
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

    func testLegacyAndModernBrowsersCoexistAndPublishUpdatesForStableServiceIdentity() throws {
        let factory = RecordingBonjourBrowserFactory()
        let scheduler = ManualBonjourRetryScheduler()
        let legacyRecorder = DiscoveryEventRecorder()
        let modernRecorder = DiscoveryEventRecorder()
        let legacy = NetworkBonjourDiscovery(
            queue: DispatchQueue(label: "test.umbra.bonjour-legacy"),
            browserFactory: factory,
            retryScheduler: scheduler,
            serviceKind: .legacyGameStream
        )
        let modern = NetworkBonjourDiscovery(
            queue: DispatchQueue(label: "test.umbra.bonjour-modern"),
            browserFactory: factory,
            retryScheduler: scheduler,
            serviceKind: .modernLumenV3
        )

        legacy.start { legacyRecorder.record($0) }
        modern.start { modernRecorder.record($0) }

        XCTAssertEqual(factory.requestedKinds, [.legacyGameStream, .modernLumenV3])
        let legacyBrowser = try XCTUnwrap(factory.browser(at: 0))
        let modernBrowser = try XCTUnwrap(factory.browser(at: 1))
        let legacyService = DiscoveredHostService(
            name: "Legacy",
            type: "_nvstream._tcp",
            domain: "local."
        )
        let firstModern = modernService(name: "Modern", changeToken: 1)
        let updatedModern = modernService(name: "Modern", changeToken: 2)
        legacyBrowser.send(services: [legacyService])
        modernBrowser.send(services: [firstModern])
        modernBrowser.send(services: [updatedModern])

        XCTAssertEqual(legacyRecorder.events, [.added(legacyService)])
        XCTAssertEqual(modernRecorder.events, [
            .added(firstModern),
            .updated(old: firstModern, new: updatedModern),
        ])
    }

    func testModernTXTContractRejectsUnknownNoncanonicalAndMismatchedFields() throws {
        let valid = modernService(name: "Modern")
        let record = try ProtocolV3DiscoveredServiceRecord(
            service: valid,
            resolvedHost: "modern.local",
            resolvedPort: 47_998
        )
        XCTAssertEqual(record.hostID, Data(repeating: 0x11, count: 16))
        XCTAssertEqual(record.capabilities, 0x17)
        XCTAssertEqual(record.hostname, "modern.local")
        XCTAssertTrue(try ProtocolV3DiscoveredServiceRecord(
            service: valid,
            resolvedHost: "[fe80::1%en0]",
            resolvedPort: 47_998
        ).hostnameIsIPLiteral)

        var invalidCases: [[String: String]] = [
            ["v": "2", "id": String(repeating: "11", count: 16), "port": "47998", "caps": "0000000000000017"],
            ["v": "03", "id": String(repeating: "11", count: 16), "port": "47998", "caps": "0000000000000017"],
            ["v": "3", "id": String(repeating: "11", count: 15), "port": "47998", "caps": "0000000000000017"],
            ["v": "3", "id": String(repeating: "AA", count: 16), "port": "47998", "caps": "0000000000000017"],
            ["v": "3", "id": String(repeating: "00", count: 16), "port": "47998", "caps": "0000000000000017"],
            ["v": "3", "id": String(repeating: "11", count: 16), "port": "047998", "caps": "0000000000000017"],
            ["v": "3", "id": String(repeating: "11", count: 16), "port": "47998", "caps": "17"],
            ["v": "3", "id": String(repeating: "11", count: 16), "port": "47998", "caps": "0000000000000017", "extra": "x"],
        ]
        invalidCases.append([
            "v": "3",
            "id": String(repeating: "11", count: 16),
            "port": "47999",
            "caps": "0000000000000017",
        ])
        for txtRecord in invalidCases {
            let service = DiscoveredHostService(
                name: "Invalid",
                type: "_lumen-v3._udp",
                domain: "local.",
                txtRecord: txtRecord
            )
            XCTAssertThrowsError(try ProtocolV3DiscoveredServiceRecord(
                service: service,
                resolvedHost: "invalid.local",
                resolvedPort: 47_998
            ))
        }
        XCTAssertThrowsError(try ProtocolV3DiscoveredServiceRecord(
            service: DiscoveredHostService(
                name: "Wrong type",
                type: "_nvstream._tcp",
                domain: "local.",
                txtRecord: valid.txtRecord
            ),
            resolvedHost: "invalid.local",
            resolvedPort: 47_998
        ))
    }

    func testModernDiscoveryCoalescesDuplicatesTracksAddressChangesAndRetiresLastRoute() async throws {
        let source = FixtureBonjourDiscovery()
        let resolver = FixtureProtocolV3Resolver()
        let recorder = ProtocolV3DiscoveryEventRecorder()
        let discovery = NetworkProtocolV3Discovery(source: source, resolver: resolver)
        let first = modernService(name: "A", interfaceName: "en0", changeToken: 1)
        let duplicate = modernService(name: "B", interfaceName: "en1", changeToken: 1)
        await resolver.set(.init(hostname: "a.local", port: 47_998), for: first.id)
        await resolver.set(.init(hostname: "b.local", port: 47_998), for: duplicate.id)

        discovery.start { recorder.record($0) }
        source.emit(.added(first))
        source.emit(.added(duplicate))
        await eventually { recorder.events.count == 1 }
        XCTAssertEqual(recorder.events, [
            .available(try ProtocolV3DiscoveredServiceRecord(
                service: first,
                resolvedHost: "a.local",
                resolvedPort: 47_998
            )),
        ])

        let changed = modernService(name: "A", interfaceName: "en0", changeToken: 2)
        await resolver.set(.init(hostname: "a-new.local", port: 47_998), for: changed.id)
        source.emit(.updated(old: first, new: changed))
        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events.last, .available(try ProtocolV3DiscoveredServiceRecord(
            service: changed,
            resolvedHost: "a-new.local",
            resolvedPort: 47_998
        )))

        source.emit(.removed(changed))
        await eventually { recorder.events.count == 3 }
        XCTAssertEqual(recorder.events.last, .available(try ProtocolV3DiscoveredServiceRecord(
            service: duplicate,
            resolvedHost: "b.local",
            resolvedPort: 47_998
        )))
        source.emit(.removed(duplicate))
        await eventually { recorder.events.count == 4 }
        XCTAssertEqual(recorder.events.last, .unavailable(Data(repeating: 0x11, count: 16)))
    }
}

private final class RecordingBonjourBrowserFactory: BonjourBrowserCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var browsers: [RecordingBonjourBrowser] = []
    private var kinds: [BonjourServiceKind] = []

    var browserCount: Int {
        lock.withLock { browsers.count }
    }

    var requestedKinds: [BonjourServiceKind] {
        lock.withLock { kinds }
    }

    func makeBrowser(for kind: BonjourServiceKind) -> any BonjourBrowsing {
        let browser = RecordingBonjourBrowser()
        lock.withLock {
            browsers.append(browser)
            kinds.append(kind)
        }
        return browser
    }

    func browser(at index: Int) -> RecordingBonjourBrowser? {
        lock.withLock {
            guard browsers.indices.contains(index) else { return nil }
            return browsers[index]
        }
    }
}

private final class RecordingBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var stateUpdateHandler: (@Sendable (BonjourBrowserState) -> Void)?
    private var resultsChangedHandler: (@Sendable (Set<DiscoveredHostService>) -> Void)?
    private var cancellations = 0

    var cancelCount: Int {
        lock.withLock { cancellations }
    }

    func setStateUpdateHandler(_ handler: @escaping @Sendable (BonjourBrowserState) -> Void) {
        lock.withLock { stateUpdateHandler = handler }
    }

    func setResultsChangedHandler(
        _ handler: @escaping @Sendable (Set<DiscoveredHostService>) -> Void
    ) {
        lock.withLock { resultsChangedHandler = handler }
    }

    func start(queue _: DispatchQueue) {}

    func cancel() {
        lock.withLock { cancellations += 1 }
    }

    func send(state: BonjourBrowserState) {
        let handler = lock.withLock { stateUpdateHandler }
        handler?(state)
    }

    func send(services: Set<DiscoveredHostService>) {
        let handler = lock.withLock { resultsChangedHandler }
        handler?(services)
    }
}

private final class ManualBonjourRetryScheduler: BonjourRetryScheduling, @unchecked Sendable {
    private struct ScheduledAction {
        let delay: TimeInterval
        let cancellation: ManualBonjourRetryCancellation
        let action: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var scheduledActions: [ScheduledAction] = []

    var scheduledDelays: [TimeInterval] {
        lock.withLock { scheduledActions.map(\.delay) }
    }

    var cancellationCount: Int {
        lock.withLock { scheduledActions.filter(\.cancellation.isCancelled).count }
    }

    func schedule(
        after delay: TimeInterval,
        on _: DispatchQueue,
        action: @escaping @Sendable () -> Void
    ) -> any BonjourRetryCancellable {
        let cancellation = ManualBonjourRetryCancellation()
        lock.withLock {
            scheduledActions.append(
                ScheduledAction(delay: delay, cancellation: cancellation, action: action)
            )
        }
        return cancellation
    }

    func fireNext(includingCancelled: Bool = false) {
        let scheduledAction = lock.withLock { () -> ScheduledAction? in
            guard !scheduledActions.isEmpty else { return nil }
            return scheduledActions.removeFirst()
        }
        guard let scheduledAction else { return }
        if includingCancelled || !scheduledAction.cancellation.isCancelled {
            scheduledAction.action()
        }
    }
}

private final class ManualBonjourRetryCancellation: BonjourRetryCancellable, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private final class DiscoveryEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [DiscoveryEvent] = []

    var events: [DiscoveryEvent] {
        lock.withLock { recordedEvents }
    }

    func record(_ event: DiscoveryEvent) {
        lock.withLock { recordedEvents.append(event) }
    }
}

private final class FixtureBonjourDiscovery: BonjourDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (DiscoveryEvent) -> Void)?

    func start(eventHandler: @escaping @Sendable (DiscoveryEvent) -> Void) {
        lock.withLock { handler = eventHandler }
    }

    func stop() {
        lock.withLock { handler = nil }
    }

    func emit(_ event: DiscoveryEvent) {
        lock.withLock { handler }?(event)
    }
}

private actor FixtureProtocolV3Resolver: ProtocolV3ServiceResolving {
    private var endpoints: [String: ProtocolV3ResolvedEndpoint] = [:]

    func set(_ endpoint: ProtocolV3ResolvedEndpoint, for serviceID: String) {
        endpoints[serviceID] = endpoint
    }

    func resolve(_ service: DiscoveredHostService) async throws -> ProtocolV3ResolvedEndpoint {
        try XCTUnwrap(endpoints[service.id])
    }
}

private final class ProtocolV3DiscoveryEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ProtocolV3DiscoveryEvent] = []

    var events: [ProtocolV3DiscoveryEvent] {
        lock.withLock { recorded }
    }

    func record(_ event: ProtocolV3DiscoveryEvent) {
        lock.withLock { recorded.append(event) }
    }
}

private func modernService(
    name: String,
    interfaceName: String? = nil,
    changeToken: UInt64 = 0
) -> DiscoveredHostService {
    DiscoveredHostService(
        name: name,
        type: "_lumen-v3._udp",
        domain: "local.",
        interfaceName: interfaceName,
        txtRecord: [
            "v": "3",
            "id": String(repeating: "11", count: 16),
            "port": "47998",
            "caps": "0000000000000017",
        ],
        changeToken: changeToken
    )
}

private func eventually(
    _ condition: @escaping @Sendable () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(condition(), file: file, line: line)
}
