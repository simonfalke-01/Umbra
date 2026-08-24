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
}

private final class RecordingBonjourBrowserFactory: BonjourBrowserCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var browsers: [RecordingBonjourBrowser] = []

    var browserCount: Int {
        lock.withLock { browsers.count }
    }

    func makeBrowser() -> any BonjourBrowsing {
        let browser = RecordingBonjourBrowser()
        lock.withLock { browsers.append(browser) }
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
