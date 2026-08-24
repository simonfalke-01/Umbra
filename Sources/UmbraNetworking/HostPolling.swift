import Foundation

public enum HostPollingState: Equatable, Sendable {
    case idle
    case probing(attempt: Int)
    case online(ServerInfo)
    case offline(consecutiveFailures: Int, lastError: String)
    case stopped
}

public struct HostPollingStateMachine: Equatable, Sendable {
    public private(set) var state: HostPollingState = .idle
    private var attempt = 0
    private var consecutiveFailures = 0

    public init() {}

    public mutating func start() {
        guard state == .idle || state == .stopped else { return }
        attempt = 0
        consecutiveFailures = 0
        state = .idle
    }

    public mutating func beginProbe() {
        guard state != .stopped else { return }
        attempt += 1
        state = .probing(attempt: attempt)
    }

    public mutating func received(_ serverInfo: ServerInfo) {
        guard state != .stopped else { return }
        consecutiveFailures = 0
        state = .online(serverInfo)
    }

    public mutating func failed(_ error: Error) {
        guard state != .stopped else { return }
        consecutiveFailures += 1
        state = .offline(
            consecutiveFailures: consecutiveFailures,
            lastError: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
    }

    public mutating func stop() {
        state = .stopped
    }
}

public protocol PollingClock: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

public struct TaskPollingClock: PollingClock {
    public init() {}

    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public actor HostPoller {
    public typealias StateHandler = @Sendable (HostPollingState) -> Void

    private let fetcher: any ServerInfoFetching
    private let clock: any PollingClock
    private let intervalNanoseconds: UInt64
    private var stateMachine = HostPollingStateMachine()
    private var pollingTask: Task<Void, Never>?
    private var stateHandler: StateHandler?

    public init(
        fetcher: any ServerInfoFetching,
        interval: TimeInterval = 5,
        clock: any PollingClock = TaskPollingClock()
    ) {
        self.fetcher = fetcher
        self.clock = clock
        self.intervalNanoseconds = UInt64(max(0, interval) * 1_000_000_000)
    }

    deinit {
        pollingTask?.cancel()
    }

    public var state: HostPollingState {
        stateMachine.state
    }

    public func setStateHandler(_ handler: StateHandler?) {
        stateHandler = handler
    }

    public func start() {
        guard pollingTask == nil else { return }
        stateMachine.start()
        publish()
        pollingTask = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        stateMachine.stop()
        publish()
    }

    /// Performs one deterministic transition cycle and is useful for refresh actions and tests.
    @discardableResult
    public func pollOnce() async -> HostPollingState {
        stateMachine.beginProbe()
        publish()
        do {
            let info = try await fetcher.fetchServerInfo()
            stateMachine.received(info)
        } catch {
            stateMachine.failed(error)
        }
        publish()
        return stateMachine.state
    }

    private func run() async {
        while !Task.isCancelled {
            _ = await pollOnce()
            do {
                try await clock.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                break
            }
        }
    }

    private func publish() {
        stateHandler?(stateMachine.state)
    }
}
