import Foundation
import Testing
@testable import UmbraAWDL

@Suite("AWDL lease state")
struct AWDLLeaseStateMachineTests {
    @Test("restores the exact prior up state and treats repeated ownership idempotently")
    func restoresPriorUpState() async throws {
        let interface = RecordingInterface(state: .up)
        let persistence = RecordingPersistence()
        let machine = AWDLLeaseStateMachine(interface: interface, persistence: persistence)
        let lease = UUID().uuidString

        let first = try await machine.down(leaseIdentifier: lease)
        let repeated = try await machine.down(leaseIdentifier: lease)
        #expect(first.interfaceState == .down)
        #expect(repeated.interfaceState == .down)
        #expect(interface.states == [.up, .down])

        let restored = try await machine.up(leaseIdentifier: lease)
        #expect(restored.interfaceState == .up)
        #expect(interface.states == [.up, .down, .up])
        #expect(persistence.record == nil)
    }

    @Test("restores an initially down interface to down")
    func preservesPriorDownState() async throws {
        let interface = RecordingInterface(state: .down)
        let persistence = RecordingPersistence()
        let machine = AWDLLeaseStateMachine(interface: interface, persistence: persistence)
        let lease = UUID().uuidString

        _ = try await machine.down(leaseIdentifier: lease)
        _ = try await machine.up(leaseIdentifier: lease)

        #expect(interface.states == [.down, .down, .down])
        #expect(try await machine.status().interfaceState == .down)
    }

    @Test("rejects another owner without mutating the active lease")
    func rejectsAnotherOwner() async throws {
        let interface = RecordingInterface(state: .up)
        let persistence = RecordingPersistence()
        let machine = AWDLLeaseStateMachine(interface: interface, persistence: persistence)
        let owner = UUID().uuidString

        _ = try await machine.down(leaseIdentifier: owner)
        await #expect(throws: AWDLHelperError.busy) {
            try await machine.down(leaseIdentifier: UUID().uuidString)
        }
        #expect(persistence.record?.leaseIdentifier == owner)
        #expect(interface.states == [.up, .down])
    }

    @Test("startup recovery restores a persisted crash lease")
    func recoversPersistedLease() async throws {
        let interface = RecordingInterface(state: .down)
        let lease = AWDLLeaseRecord(
            leaseIdentifier: UUID().uuidString,
            priorState: .up
        )
        let persistence = RecordingPersistence(record: lease)
        let machine = AWDLLeaseStateMachine(interface: interface, persistence: persistence)

        try await machine.recoverPersistedLease()

        #expect(interface.states == [.down, .up])
        #expect(persistence.record == nil)
    }

    @Test("a failed down command restores before surfacing the error")
    func failedDownRollsBack() async throws {
        let interface = RecordingInterface(state: .up, failure: .down)
        let persistence = RecordingPersistence()
        let machine = AWDLLeaseStateMachine(interface: interface, persistence: persistence)

        await #expect(throws: InterfaceFailure.injected) {
            try await machine.down(leaseIdentifier: UUID().uuidString)
        }

        #expect(interface.states == [.up, .down, .up])
        #expect(persistence.record == nil)
    }

    @Test("XPC connection invalidation restores the connection-owned lease")
    func connectionInvalidationRestoresLease() async throws {
        let interface = RecordingInterface(state: .up)
        let persistence = RecordingPersistence()
        let machine = AWDLLeaseStateMachine(interface: interface, persistence: persistence)
        let service = AWDLPrivilegedHelperService(stateMachine: machine)
        let lease = UUID().uuidString
        let (replies, continuation) = AsyncStream<Bool>.makeStream()

        service.down(leaseIdentifier: lease) { reply in
            continuation.yield(reply[AWDLHelperContract.ReplyKey.success] as? Bool == true)
            continuation.finish()
        }
        var iterator = replies.makeAsyncIterator()
        #expect(await iterator.next() == true)

        service.connectionInvalidated()
        for _ in 0..<100 {
            if try await machine.status().leaseIdentifier == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let status = try await machine.status()
        #expect(status.interfaceState == .up)
        #expect(status.leaseIdentifier == nil)
        #expect(persistence.record == nil)
    }
}

private enum InterfaceFailure: Error {
    case injected
}

private final class RecordingInterface: AWDLInterfaceControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var currentState: AWDLInterfaceState
    private let failure: AWDLInterfaceState?
    private(set) var states: [AWDLInterfaceState]

    init(state: AWDLInterfaceState, failure: AWDLInterfaceState? = nil) {
        currentState = state
        self.failure = failure
        states = [state]
    }

    func state() throws -> AWDLInterfaceState { lock.withLock { currentState } }

    func setState(_ state: AWDLInterfaceState) throws {
        try lock.withLock {
            states.append(state)
            if state == failure { throw InterfaceFailure.injected }
            currentState = state
        }
    }
}

private final class RecordingPersistence: AWDLLeasePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var record: AWDLLeaseRecord?

    init(record: AWDLLeaseRecord? = nil) { self.record = record }
    func load() throws -> AWDLLeaseRecord? { lock.withLock { record } }
    func save(_ record: AWDLLeaseRecord) throws { lock.withLock { self.record = record } }
    func clear() throws { lock.withLock { record = nil } }
}
