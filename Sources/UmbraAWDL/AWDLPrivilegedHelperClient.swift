import Foundation

public protocol AWDLPrivilegedHelperControlling: Sendable {
    func status() async throws -> AWDLHelperStatus
    func down(leaseIdentifier: String) async throws -> AWDLHelperStatus
    func up(leaseIdentifier: String) async throws -> AWDLHelperStatus
}

public actor AWDLPrivilegedHelperClient: AWDLPrivilegedHelperControlling {
    private final class ReplyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<
            Result<AWDLHelperStatus, AWDLHelperError>, Never
        >?

        func install(
            _ continuation: CheckedContinuation<
                Result<AWDLHelperStatus, AWDLHelperError>, Never
            >
        ) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(with reply: NSDictionary) {
            do {
                resume(with: .success(try AWDLHelperStatus.decode(reply)))
            } catch let error as AWDLHelperError {
                resume(with: .failure(error))
            } catch {
                resume(with: .failure(.operationFailed(error.localizedDescription)))
            }
        }

        func resume(with result: Result<AWDLHelperStatus, AWDLHelperError>) {
            let continuation = lock.withLock { () -> CheckedContinuation<
                Result<AWDLHelperStatus, AWDLHelperError>, Never
            >? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: result)
        }
    }

    private var connection: NSXPCConnection?
    private let capabilityChecker: any AWDLHelperCapabilityChecking
    private let requestTimeout: Duration
    private let diagnosticHandler: @Sendable (String) -> Void

    public init(
        requestTimeout: Duration = .seconds(2),
        capabilityChecker: any AWDLHelperCapabilityChecking = SystemAWDLHelperCapabilityChecker(),
        diagnosticHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.requestTimeout = requestTimeout
        self.capabilityChecker = capabilityChecker
        self.diagnosticHandler = diagnosticHandler
    }

    public func status() async throws -> AWDLHelperStatus {
        try await request { $0.status(reply: $1) }
    }

    public func down(leaseIdentifier: String) async throws -> AWDLHelperStatus {
        try await request { $0.down(leaseIdentifier: leaseIdentifier, reply: $1) }
    }

    public func up(leaseIdentifier: String) async throws -> AWDLHelperStatus {
        try await request { $0.up(leaseIdentifier: leaseIdentifier, reply: $1) }
    }

    private func request(
        _ operation: @escaping (AWDLPrivilegedHelperXPC, @escaping (NSDictionary) -> Void) -> Void
    ) async throws -> AWDLHelperStatus {
        do {
            try capabilityChecker.requireEnabled()
        } catch {
            invalidateConnection(reason: error.localizedDescription)
            throw error
        }
        let connection = try activeConnection()
        let gate = ReplyGate()
        let result = await withCheckedContinuation { continuation in
            gate.install(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                gate.resume(with: .failure(.unavailable(error.localizedDescription)))
            }
            guard let helper = proxy as? AWDLPrivilegedHelperXPC else {
                gate.resume(with: .failure(.unavailable("invalid XPC proxy")))
                return
            }
            operation(helper) { gate.resume(with: $0) }
            Task { [requestTimeout] in
                try? await Task.sleep(for: requestTimeout)
                gate.resume(with: .failure(.unavailable("request timed out")))
            }
        }
        switch result {
        case .success(let status):
            return status
        case .failure(let error):
            invalidateConnection(reason: error.localizedDescription)
            throw error
        }
    }

    private func activeConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(
            machServiceName: AWDLHelperContract.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: AWDLPrivilegedHelperXPC.self
        )
        connection.setCodeSigningRequirement(
            try AWDLCodeSigning.peerRequirement(
                identifier: AWDLHelperContract.helperBundleIdentifier
            )
        )
        connection.interruptionHandler = { [diagnosticHandler] in
            diagnosticHandler("helper connection interrupted")
        }
        connection.invalidationHandler = { [diagnosticHandler] in
            diagnosticHandler("helper connection invalidated")
        }
        connection.activate()
        self.connection = connection
        return connection
    }

    private func invalidateConnection(reason: String) {
        guard let connection else { return }
        self.connection = nil
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        diagnosticHandler(reason)
    }
}
