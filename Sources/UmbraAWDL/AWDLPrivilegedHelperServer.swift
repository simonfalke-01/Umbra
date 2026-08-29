import Foundation

private final class AWDLXPCReply: @unchecked Sendable {
    private let reply: (NSDictionary) -> Void

    init(_ reply: @escaping (NSDictionary) -> Void) { self.reply = reply }
    func callAsFunction(_ value: NSDictionary) { reply(value) }
}

public final class AWDLPrivilegedHelperService: NSObject, AWDLPrivilegedHelperXPC,
    @unchecked Sendable {
    private let stateMachine: AWDLLeaseStateMachine
    private let lock = NSLock()
    private var ownedLeaseIdentifier: String?
    private var activeOperation: Task<Void, Never>?
    private var operationInProgress = false
    private var restorationStarted = false

    public init(stateMachine: AWDLLeaseStateMachine) {
        self.stateMachine = stateMachine
    }

    public func status(reply: @escaping (NSDictionary) -> Void) {
        let reply = AWDLXPCReply(reply)
        Task {
            do {
                reply(try await stateMachine.status().reply())
            } catch {
                reply(AWDLHelperStatus.reply(success: false, error: error.localizedDescription))
            }
        }
    }

    public func down(leaseIdentifier: String, reply: @escaping (NSDictionary) -> Void) {
        let reply = AWDLXPCReply(reply)
        let accepted = lock.withLock { () -> Bool in
            guard !operationInProgress,
                  ownedLeaseIdentifier == nil || ownedLeaseIdentifier == leaseIdentifier else {
                return false
            }
            operationInProgress = true
            ownedLeaseIdentifier = leaseIdentifier
            return true
        }
        guard accepted else {
            reply(AWDLHelperStatus.reply(success: false, error: "busy"))
            return
        }
        let operation = Task { [stateMachine, lock] in
            do {
                let status = try await stateMachine.down(leaseIdentifier: leaseIdentifier)
                reply(status.reply())
            } catch {
                reply(AWDLHelperStatus.reply(success: false, error: Self.wireError(error)))
            }
            lock.withLock {
                self.activeOperation = nil
                self.operationInProgress = false
            }
        }
        lock.withLock { activeOperation = operation }
    }

    public func up(leaseIdentifier: String, reply: @escaping (NSDictionary) -> Void) {
        let reply = AWDLXPCReply(reply)
        let accepted = lock.withLock { () -> Bool in
            guard !operationInProgress,
                  ownedLeaseIdentifier == nil || ownedLeaseIdentifier == leaseIdentifier else {
                return false
            }
            operationInProgress = true
            return true
        }
        guard accepted else {
            reply(AWDLHelperStatus.reply(success: false, error: "busy"))
            return
        }
        let operation = Task { [stateMachine, lock] in
            do {
                let status = try await stateMachine.up(leaseIdentifier: leaseIdentifier)
                lock.withLock {
                    if ownedLeaseIdentifier == leaseIdentifier { ownedLeaseIdentifier = nil }
                }
                reply(status.reply())
            } catch {
                reply(AWDLHelperStatus.reply(success: false, error: Self.wireError(error)))
            }
            lock.withLock {
                self.activeOperation = nil
                self.operationInProgress = false
            }
        }
        lock.withLock { activeOperation = operation }
    }

    public func connectionInvalidated() {
        let values = lock.withLock { () -> (String?, Task<Void, Never>?) in
            guard !restorationStarted else { return (nil, nil) }
            restorationStarted = true
            return (ownedLeaseIdentifier, activeOperation)
        }
        guard let leaseIdentifier = values.0 else {
            lock.withLock { restorationStarted = false }
            return
        }
        Task { [stateMachine, lock] in
            await values.1?.value
            while true {
                do {
                    try await stateMachine.restoreOwnedLeaseIfPresent(
                        leaseIdentifier: leaseIdentifier
                    )
                    lock.withLock {
                        self.ownedLeaseIdentifier = nil
                        self.restorationStarted = false
                    }
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private static func wireError(_ error: Error) -> String {
        switch error as? AWDLHelperError {
        case .busy: "busy"
        case .invalidLeaseIdentifier: "invalid lease identifier"
        default: error.localizedDescription
        }
    }
}

public final class AWDLPrivilegedHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let stateMachine: AWDLLeaseStateMachine

    public init(stateMachine: AWDLLeaseStateMachine) {
        self.stateMachine = stateMachine
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let service = AWDLPrivilegedHelperService(stateMachine: stateMachine)
        newConnection.exportedInterface = NSXPCInterface(with: AWDLPrivilegedHelperXPC.self)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [service] in
            service.connectionInvalidated()
        }
        newConnection.interruptionHandler = { [service] in
            service.connectionInvalidated()
        }
        newConnection.activate()
        return true
    }
}

public final class AWDLPrivilegedHelperDaemon {
    private let listener: NSXPCListener
    private let delegate: AWDLPrivilegedHelperListenerDelegate

    public init(stateMachine: AWDLLeaseStateMachine) throws {
        listener = NSXPCListener(machServiceName: AWDLHelperContract.machServiceName)
        delegate = AWDLPrivilegedHelperListenerDelegate(stateMachine: stateMachine)
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(
            try AWDLCodeSigning.peerRequirement(
                identifier: AWDLHelperContract.applicationBundleIdentifier
            )
        )
    }

    public func activate() {
        listener.activate()
    }
}
