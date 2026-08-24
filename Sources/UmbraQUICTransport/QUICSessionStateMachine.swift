import Foundation

public final class QUICSessionStateMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var storedState: QUICConnectionState = .idle
    private var peerVerified = false
    private var transportReady = false
    private var stateBeforeWaiting: QUICConnectionState?

    public init() {}

    public var state: QUICConnectionState { lock.withLock { storedState } }
    public var isTerminal: Bool {
        lock.withLock {
            if case .failed = storedState { return true }
            return storedState == .cancelled
        }
    }

    @discardableResult
    public func start() throws -> QUICConnectionState {
        try lock.withLock {
            guard storedState == .idle else { throw QUICTransportError.invalidState }
            storedState = .preparing
            return storedState
        }
    }

    @discardableResult
    public func beginPeerVerification() throws -> QUICConnectionState {
        try lock.withLock {
            guard storedState == .preparing else { throw QUICTransportError.invalidState }
            storedState = .verifyingPeer
            return storedState
        }
    }

    @discardableResult
    public func peerVerificationCompleted(success: Bool) -> QUICConnectionState {
        lock.withLock {
            guard !isTerminalState(storedState) else { return storedState }
            guard success else {
                storedState = .failed("peer verification failed")
                return storedState
            }
            peerVerified = true
            storedState = transportReady ? .authenticatingApplication : .preparing
            return storedState
        }
    }

    @discardableResult
    public func networkBecameReady() throws -> QUICConnectionState {
        try lock.withLock {
            guard storedState == .preparing || storedState == .verifyingPeer else {
                throw QUICTransportError.invalidState
            }
            transportReady = true
            if peerVerified {
                storedState = .authenticatingApplication
            }
            return storedState
        }
    }

    @discardableResult
    public func applicationAuthenticationCompleted(success: Bool) throws -> QUICConnectionState {
        try lock.withLock {
            guard storedState == .authenticatingApplication else {
                throw QUICTransportError.invalidState
            }
            storedState = success ? .ready : .failed("application authentication failed")
            return storedState
        }
    }

    @discardableResult
    public func wait(reason: String) -> QUICConnectionState {
        lock.withLock {
            guard !isTerminalState(storedState) else { return storedState }
            if case .waiting = storedState {
                return storedState
            }
            stateBeforeWaiting = storedState
            storedState = .waiting(reason)
            return storedState
        }
    }

    @discardableResult
    public func networkRecovered() throws -> QUICConnectionState {
        try lock.withLock {
            guard case .waiting = storedState, let previous = stateBeforeWaiting else {
                throw QUICTransportError.invalidState
            }
            stateBeforeWaiting = nil
            storedState = previous
            return storedState
        }
    }

    @discardableResult
    public func fail(reason: String) -> QUICConnectionState {
        lock.withLock {
            guard !isTerminalState(storedState) else { return storedState }
            storedState = .failed(reason)
            return storedState
        }
    }

    @discardableResult
    public func cancel() -> QUICConnectionState {
        lock.withLock {
            guard !isTerminalState(storedState) else { return storedState }
            storedState = .cancelled
            stateBeforeWaiting = nil
            return storedState
        }
    }

    private func isTerminalState(_ state: QUICConnectionState) -> Bool {
        if case .failed = state { return true }
        return state == .cancelled
    }
}
