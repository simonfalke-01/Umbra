import Darwin
import Foundation
import ServiceManagement
import XPC

/// The operating state reported by macOS for the Apple Wireless Direct Link interface.
public enum AWDLInterfaceState: Equatable, Sendable {
    case up
    case down
    case unavailable
}

/// The installation and approval state of Umbra's restricted AWDL helper.
public enum AWDLHelperRegistrationStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// The outcome of applying or restoring Umbra's per-stream AWDL preference.
public enum AWDLStreamingChangeResult: Equatable, Sendable {
    case notRequested
    case disabled
    case alreadyDisabled
    case unavailable
    case restored
    case unchanged
    case failed(String)
}

/// Registers the bundled helper only from explicit setup UI and exposes its current approval state.
public struct AWDLHelperRegistration: Sendable {
    /// Launch-daemon property list embedded by Umbra's package step.
    public static let propertyListName = "com.umbra.awdl-helper.plist"

    public init() {}

    /// Returns the state recorded by macOS Service Management.
    public func status() -> AWDLHelperRegistrationStatus {
        Self.map(SMAppService.daemon(plistName: Self.propertyListName).status)
    }

    /// Registers the bundled helper after the user explicitly selects setup.
    ///
    /// This method is never called by stream startup or reconnect handling.
    @discardableResult
    public func register() throws -> AWDLHelperRegistrationStatus {
        let service = SMAppService.daemon(plistName: Self.propertyListName)
        if service.status == .notRegistered || service.status == .notFound {
            try service.register()
        }
        return Self.map(service.status)
    }

    /// Opens the standard macOS Login Items panel where an administrator approves the helper once.
    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func map(_ status: SMAppService.Status) -> AWDLHelperRegistrationStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}

/// Provides the fixed operations required to inspect `awdl0` and own one helper-side lease.
public protocol AWDLInterfaceCommandExecuting: Sendable {
    /// Reads the current `awdl0` state without privilege.
    func currentState() async throws -> AWDLInterfaceState

    /// Acquires this authenticated connection's disable lease from the approved helper.
    func acquireDisableLease() async throws -> AWDLInterfaceState

    /// Releases this authenticated connection's lease so the helper can restore prior state.
    func releaseDisableLease() async throws -> AWDLInterfaceState
}

/// Owns Umbra's temporary AWDL change for one streaming lifetime.
public actor AWDLStreamingController {
    private let commands: any AWDLInterfaceCommandExecuting
    private var activation: ActiveActivation?
    private var activationTask: (id: UUID, task: Task<ActivationOutcome, Never>)?
    private var finishTask: (id: UUID, task: Task<AWDLStreamingChangeResult, Never>)?
    private var restorationFailure: String?

    /// Creates a controller backed by the approved, restricted helper.
    public init(commands: any AWDLInterfaceCommandExecuting = SystemAWDLInterfaceCommandExecutor()) {
        self.commands = commands
    }

    /// Applies the opt-in preference without registering a helper or requesting authorization.
    public func begin(disableWhileStreaming: Bool) async -> AWDLStreamingChangeResult {
        guard disableWhileStreaming else { return .notRequested }
        if let pendingFinish = finishTask {
            let result = await pendingFinish.task.value
            completeFinish(id: pendingFinish.id, result: result)
            if case .failed(let message) = result {
                return .failed("The previous stream's AWDL restoration is incomplete: \(message)")
            }
        }
        if let restorationFailure {
            return .failed("The previous stream's AWDL restoration is incomplete: \(restorationFailure)")
        }
        if let activation { return activation.result }
        if let activationTask {
            let outcome = await activationTask.task.value
            if self.activationTask?.id != activationTask.id, activation == nil {
                return .failed("AWDL setup ended before stream startup completed.")
            }
            return activation?.result ?? outcome.result
        }

        let operationID = UUID()
        let commands = self.commands
        let task = Task.detached(priority: .userInitiated) {
            await Self.performActivation(commands: commands)
        }
        activationTask = (operationID, task)
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.cancelActivation(id: operationID) }
        }
        guard activationTask?.id == operationID else {
            return .failed("AWDL setup ended before stream startup completed.")
        }
        activationTask = nil
        if let active = outcome.active { activation = active }
        return outcome.result
    }

    /// Releases the helper lease and verifies restoration before a later stream can acquire one.
    public func finish() async -> AWDLStreamingChangeResult {
        if let pendingFinish = finishTask {
            let result = await pendingFinish.task.value
            completeFinish(id: pendingFinish.id, result: result)
            return result
        }
        if let inFlight = activationTask {
            inFlight.task.cancel()
            let outcome = await inFlight.task.value
            if activationTask?.id == inFlight.id { activationTask = nil }
            if activation == nil, let active = outcome.active { activation = active }
        }

        guard let active = activation else { return .unchanged }
        guard active.ownsLease else {
            activation = nil
            restorationFailure = nil
            return .unchanged
        }
        let operationID = UUID()
        let commands = self.commands
        let task = Task.detached(priority: .userInitiated) {
            await Self.performFinish(commands: commands)
        }
        finishTask = (operationID, task)
        let result = await task.value
        completeFinish(id: operationID, result: result)
        return result
    }

    private nonisolated static func performActivation(
        commands: any AWDLInterfaceCommandExecuting
    ) async -> ActivationOutcome {
        do {
            switch try await commands.currentState() {
            case .unavailable:
                return ActivationOutcome(result: .unavailable)
            case .down:
                return ActivationOutcome(
                    result: .alreadyDisabled,
                    active: ActiveActivation(result: .alreadyDisabled, ownsLease: false)
                )
            case .up:
                break
            }
            try Task.checkCancellation()
            do {
                let state = try await commands.acquireDisableLease()
                try Task.checkCancellation()
                guard state == .down, try await commands.currentState() == .down else {
                    _ = try? await commands.releaseDisableLease()
                    return ActivationOutcome(
                        result: .failed("The approved helper did not report awdl0 as disabled.")
                    )
                }
                return ActivationOutcome(
                    result: .disabled,
                    active: ActiveActivation(result: .disabled, ownsLease: true)
                )
            } catch {
                _ = try? await commands.releaseDisableLease()
                throw error
            }
        } catch {
            return ActivationOutcome(result: .failed(error.localizedDescription))
        }
    }

    private nonisolated static func performFinish(
        commands: any AWDLInterfaceCommandExecuting
    ) async -> AWDLStreamingChangeResult {
        do {
            guard try await commands.releaseDisableLease() == .up,
                  try await commands.currentState() == .up else {
                return .failed("The approved helper did not report awdl0 as restored.")
            }
            return .restored
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func cancelActivation(id: UUID) async {
        if let activationTask, activationTask.id == id {
            activationTask.task.cancel()
        } else if activation != nil {
            _ = await finish()
        }
    }

    private func completeFinish(id: UUID, result: AWDLStreamingChangeResult) {
        guard finishTask?.id == id else { return }
        finishTask = nil
        switch result {
        case .restored, .unchanged:
            activation = nil
            restorationFailure = nil
        case .failed(let message):
            restorationFailure = message
        case .notRequested, .disabled, .alreadyDisabled, .unavailable:
            break
        }
    }

    private struct ActiveActivation: Sendable {
        var result: AWDLStreamingChangeResult
        var ownsLease: Bool
    }

    private struct ActivationOutcome: Sendable {
        var result: AWDLStreamingChangeResult
        var active: ActiveActivation?

        init(result: AWDLStreamingChangeResult, active: ActiveActivation? = nil) {
            self.result = result
            self.active = active
        }
    }
}

/// Connects to the already-approved helper. It never installs, registers, or elevates anything.
public final class SystemAWDLInterfaceCommandExecutor: AWDLInterfaceCommandExecuting, @unchecked Sendable {
    private let helper = AWDLHelperConnection()

    public init() {}

    public func currentState() async throws -> AWDLInterfaceState {
        Self.localInterfaceState()
    }

    public func acquireDisableLease() async throws -> AWDLInterfaceState {
        guard AWDLHelperRegistration().status() == .enabled else {
            throw AWDLHelperClientError.helperNotApproved
        }
        return try await helper.request(.acquire)
    }

    public func releaseDisableLease() async throws -> AWDLInterfaceState {
        try await helper.request(.release)
    }

    private static func localInterfaceState() -> AWDLInterfaceState {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let firstAddress = addresses else {
            return .unavailable
        }
        defer { freeifaddrs(firstAddress) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let address = cursor {
            if String(cString: address.pointee.ifa_name) == "awdl0" {
                return address.pointee.ifa_flags & UInt32(IFF_UP) != 0 ? .up : .down
            }
            cursor = address.pointee.ifa_next
        }
        return .unavailable
    }
}

private enum AWDLHelperOperation: Int64, Sendable {
    case status = 1
    case acquire = 2
    case release = 3
}

private enum AWDLHelperClientError: LocalizedError {
    case helperNotApproved
    case connectionFailed(String)
    case requestFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .helperNotApproved:
            "Set up and approve Umbra's AWDL helper in Advanced settings first."
        case .connectionFailed(let message):
            "Umbra could not connect to its approved AWDL helper: \(message)"
        case .requestFailed(let message):
            message
        case .timedOut:
            "Umbra's AWDL helper did not respond."
        }
    }
}

private final class AWDLHelperConnection: @unchecked Sendable {
    private static let serviceName = "app.umbra.Umbra.awdl-helper"
    private static let operationKey = "operation"
    private static let statusKey = "status"
    private static let stateKey = "state"
    private static let messageKey = "message"

    private let queue = DispatchQueue(label: "app.umbra.Umbra.awdl-helper-client")
    private let connection: xpc_connection_t

    init() {
        connection = xpc_connection_create_mach_service(
            Self.serviceName,
            queue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED)
        )
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
    }

    deinit {
        xpc_connection_cancel(connection)
    }

    func request(_ operation: AWDLHelperOperation) async throws -> AWDLInterfaceState {
        try await withCheckedThrowingContinuation { continuation in
            let gate = AWDLHelperReplyGate(continuation: continuation)
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_int64(message, Self.operationKey, operation.rawValue)
            xpc_connection_send_message_with_reply(connection, message, queue) { reply in
                gate.resolve(Self.decode(reply))
            }
            queue.asyncAfter(deadline: .now() + 2) {
                gate.resolve(.failure(AWDLHelperClientError.timedOut))
            }
        }
    }

    private static func decode(_ reply: xpc_object_t) -> Result<AWDLInterfaceState, Error> {
        if xpc_get_type(reply) == XPC_TYPE_ERROR {
            let description = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
                .map(String.init(cString:)) ?? "XPC connection failed."
            return .failure(AWDLHelperClientError.connectionFailed(description))
        }
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
            return .failure(AWDLHelperClientError.connectionFailed("The helper returned an invalid reply."))
        }
        let status = xpc_dictionary_get_int64(reply, statusKey)
        guard status == 0 else {
            let message = xpc_dictionary_get_string(reply, messageKey)
                .map(String.init(cString:)) ?? "The AWDL helper rejected the request."
            return .failure(AWDLHelperClientError.requestFailed(message))
        }
        switch xpc_dictionary_get_int64(reply, stateKey) {
        case 0: return .success(.up)
        case 1: return .success(.down)
        default: return .success(.unavailable)
        }
    }
}

private final class AWDLHelperReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AWDLInterfaceState, Error>?

    init(continuation: CheckedContinuation<AWDLInterfaceState, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<AWDLInterfaceState, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
