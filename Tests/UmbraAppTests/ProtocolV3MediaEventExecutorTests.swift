import Foundation
import XCTest
import UmbraProtocolV3
@testable import UmbraApp

final class ProtocolV3MediaEventExecutorTests: XCTestCase {
    func testConcurrentSubmissionsPreserveEachProducerOrder() {
        let producerCount = 8
        let eventsPerProducer = 250
        let executor = ProtocolV3MediaEventExecutor(
            maximumPendingEventCount: producerCount * eventsPerProducer + 1
        )
        let received = LockedMediaEventValues<Int>()
        executor.installAndResume { event in
            if let value = Self.value(from: event) {
                received.append(value)
            }
        }

        let producers = DispatchGroup()
        for producer in 0..<producerCount {
            producers.enter()
            DispatchQueue.global().async {
                for index in 0..<eventsPerProducer {
                    executor.submit(
                        Self.event(producer: producer, index: index),
                        terminalBarrier: false
                    )
                }
                producers.leave()
            }
        }
        XCTAssertEqual(producers.wait(timeout: .now() + 5), .success)

        let drained = expectation(description: "all concurrent events drained")
        executor.submit(
            .failed(.invalidState),
            terminalBarrier: true,
            completion: { drained.fulfill() }
        )
        wait(for: [drained], timeout: 5)

        let values = received.snapshot
        XCTAssertEqual(values.count, producerCount * eventsPerProducer)
        XCTAssertEqual(Set(values).count, values.count)
        for producer in 0..<producerCount {
            XCTAssertEqual(
                values.filter { $0 / eventsPerProducer == producer },
                (0..<eventsPerProducer).map { producer * eventsPerProducer + $0 }
            )
        }
    }

    func testTerminalBarrierPausesLaterEventsUntilResume() {
        let executor = ProtocolV3MediaEventExecutor()
        let received = LockedMediaEventValues<Int>()
        let handler: ProtocolV3MediaEventExecutor.EventHandler = { event in
            if let value = Self.value(from: event) {
                received.append(value)
            }
        }
        executor.installAndResume(handler)
        executor.submit(Self.event(producer: 0, index: 1), terminalBarrier: false)

        let firstTerminal = expectation(description: "first terminal barrier")
        executor.submit(
            .failed(.invalidState),
            terminalBarrier: true,
            completion: { firstTerminal.fulfill() }
        )
        executor.submit(Self.event(producer: 0, index: 2), terminalBarrier: false)
        wait(for: [firstTerminal], timeout: 2)
        XCTAssertEqual(received.snapshot, [1])

        executor.installAndResume(handler)
        let secondTerminal = expectation(description: "second terminal barrier")
        executor.submit(
            .failed(.invalidState),
            terminalBarrier: true,
            completion: { secondTerminal.fulfill() }
        )
        wait(for: [secondTerminal], timeout: 2)
        XCTAssertEqual(received.snapshot, [1, 2])
    }

    func testPausedDiscardAndInstallRemainStrictlyOrdered() {
        let executor = ProtocolV3MediaEventExecutor()
        let received = LockedMediaEventValues<Int>()
        executor.submit(Self.event(producer: 0, index: 1), terminalBarrier: false)
        executor.submit(Self.event(producer: 0, index: 2), terminalBarrier: false)
        executor.discardBuffered()
        executor.submit(Self.event(producer: 0, index: 3), terminalBarrier: false)
        executor.installAndResume { event in
            if let value = Self.value(from: event) {
                received.append(value)
            }
        }

        let drained = expectation(description: "post-discard event drained")
        executor.submit(
            .failed(.invalidState),
            terminalBarrier: true,
            completion: { drained.fulfill() }
        )
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(received.snapshot, [3])
    }

    func testOverflowFailsClosedOnceUntilClear() async {
        let executor = ProtocolV3MediaEventExecutor(maximumPendingEventCount: 4)
        let overflows = LockedMediaEventValues<Int>()
        let overflowed = expectation(description: "bounded buffer overflowed")
        let overflowHandler: @Sendable () -> Void = {
            overflows.append(1)
            overflowed.fulfill()
        }
        for index in 0..<4 {
            executor.submit(
                Self.event(producer: 0, index: index),
                terminalBarrier: false,
                overflowHandler: overflowHandler
            )
        }
        for index in 4..<100 {
            executor.submit(
                Self.event(producer: 0, index: index),
                terminalBarrier: false,
                overflowHandler: overflowHandler
            )
        }
        await fulfillment(of: [overflowed], timeout: 2)
        await executor.clearAndWait()
        XCTAssertEqual(overflows.snapshot, [1])

        let received = LockedMediaEventValues<Int>()
        executor.installAndResume { event in
            if let value = Self.value(from: event) {
                received.append(value)
            }
        }
        let drained = expectation(description: "executor reopened after clear")
        executor.submit(
            Self.event(producer: 0, index: 9),
            terminalBarrier: true,
            completion: { drained.fulfill() }
        )
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(received.snapshot, [9])
    }

    func testSubmissionRetainsEncodedPayloadStorage() {
        let executor = ProtocolV3MediaEventExecutor()
        let payload = Data(repeating: 0xA5, count: 4_096)
        let expectedAddress = payload.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        let observedAddress = LockedMediaEventValues<UInt>()
        let handled = expectation(description: "payload handled")
        executor.installAndResume { event in
            guard case let .controlMessage(_, _, fields) = event,
                  case let .bytes(receivedPayload)? = fields[1] else { return }
            observedAddress.append(receivedPayload.withUnsafeBytes {
                UInt(bitPattern: $0.baseAddress)
            })
            handled.fulfill()
        }
        executor.submit(
            .controlMessage(type: 0x0140, requestID: 2, fields: [1: .bytes(payload)]),
            terminalBarrier: false
        )
        wait(for: [handled], timeout: 2)
        XCTAssertEqual(observedAddress.snapshot, [expectedAddress])
    }

    private static func event(producer: Int, index: Int) -> ProtocolV3ClientEvent {
        let value = producer * 250 + index
        return .controlMessage(
            type: 0x0140,
            requestID: UInt64(value * 2 + 2),
            fields: [1: .unsigned(UInt64(value))]
        )
    }

    private static func value(from event: ProtocolV3ClientEvent) -> Int? {
        guard case let .controlMessage(_, _, fields) = event,
              case let .unsigned(value)? = fields[1] else { return nil }
        return Int(value)
    }
}

private final class LockedMediaEventValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    var snapshot: [Value] {
        lock.withLock { values }
    }

    func append(_ value: Value) {
        lock.withLock { values.append(value) }
    }
}
