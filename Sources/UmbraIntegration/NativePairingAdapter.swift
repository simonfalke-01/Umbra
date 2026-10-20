import Foundation
import UmbraNetworking
import UmbraPairing
import UmbraServices

public protocol PairingHandshakeCoordinating: AnyObject, Sendable {
    func pair(
        host: HostAddress,
        pin: String,
        appVersion: String,
        onProgress: @escaping @Sendable (PairingProgress) -> Void
    ) async throws -> PairedHostIdentity

    func cancel()
}

extension GameStreamPairingCoordinator: PairingHandshakeCoordinating {}

/// Connects the application service's pairing boundary to the complete secure
/// GameStream certificate handshake. The underlying coordinator permits only one
/// active operation, so service cancellation intentionally cancels that operation
/// regardless of the persisted host identifier supplied by the caller.
public struct NativeHostPairingAdapter: HostPairingAdapting, Sendable {
    private let coordinator: any PairingHandshakeCoordinating

    public init(coordinator: any PairingHandshakeCoordinating) {
        self.coordinator = coordinator
    }

    public func pair(
        host: HostAddress,
        pin: String,
        appVersion: String,
        isNVIDIAServerSoftware: Bool,
        progress: @escaping @Sendable (PairingProgress) -> Void
    ) async throws -> Data {
        do {
            return try await coordinator.pair(
                host: host,
                pin: pin,
                appVersion: appVersion,
                onProgress: progress
            ).serverCertificateDER
        } catch PairingError.cancelled {
            throw CancellationError()
        }
    }

    public func cancel(hostID: String) async {
        coordinator.cancel()
    }
}

/// Creates a fresh transcript for each host so the certificate-pinned HTTPS leg
/// uses that host's advertised/configured secure port. Callers should key the
/// provider by hostname when several saved hosts use distinct Lumen ports.
public final class FactoryBackedHostPairingAdapter: HostPairingAdapting, @unchecked Sendable {
    public typealias SecurePortProvider = @Sendable (HostAddress) -> UInt16
    public typealias CoordinatorFactory = @Sendable (
        _ host: HostAddress,
        _ securePort: UInt16,
        _ appVersion: String,
        _ isNVIDIAServerSoftware: Bool
    ) throws -> any PairingHandshakeCoordinating

    private let securePortProvider: SecurePortProvider
    private let coordinatorFactory: CoordinatorFactory
    private let lock = NSLock()
    private struct ActiveAttempt {
        let id: UUID
        var coordinator: (any PairingHandshakeCoordinating)?
        var task: Task<PairedHostIdentity, Error>?
        var cancellationRequested = false
    }
    private var activeAttempt: ActiveAttempt?

    public init(
        securePortProvider: @escaping SecurePortProvider,
        coordinatorFactory: @escaping CoordinatorFactory
    ) {
        self.securePortProvider = securePortProvider
        self.coordinatorFactory = coordinatorFactory
    }

    public convenience init(
        uniqueID: String,
        securePortProvider: @escaping SecurePortProvider,
        identityProvider: any ClientIdentityProviding = FileBackedClientIdentityProvider()
    ) {
        self.init(securePortProvider: securePortProvider) { _, securePort, appVersion, isNVIDIAServerSoftware in
            GameStreamPairingCoordinator(
                transcript: URLSessionPairingHTTPTranscript(
                    securePort: securePort,
                    uniqueID: uniqueID,
                    useTrueUniqueID: !isNVIDIAServerSoftware
                ),
                identityProvider: identityProvider,
                appVersion: appVersion
            )
        }
    }

    public func pair(
        host: HostAddress,
        pin: String,
        appVersion: String,
        isNVIDIAServerSoftware: Bool,
        progress: @escaping @Sendable (PairingProgress) -> Void
    ) async throws -> Data {
        let attemptID = UUID()
        guard lock.withLock({
            guard activeAttempt == nil else { return false }
            activeAttempt = ActiveAttempt(id: attemptID)
            return true
        }) else {
            throw PairingError.alreadyInProgress
        }
        defer {
            lock.withLock {
                if activeAttempt?.id == attemptID { activeAttempt = nil }
            }
        }

        let coordinator = try coordinatorFactory(
            host,
            securePortProvider(host),
            appVersion,
            isNVIDIAServerSoftware
        )
        let pairingTask = Task {
            try await coordinator.pair(
                host: host,
                pin: pin,
                appVersion: appVersion,
                onProgress: progress
            )
        }
        let shouldCancel = lock.withLock {
            guard activeAttempt?.id == attemptID else { return true }
            activeAttempt?.coordinator = coordinator
            activeAttempt?.task = pairingTask
            return activeAttempt?.cancellationRequested ?? true
        }
        if shouldCancel {
            coordinator.cancel()
            pairingTask.cancel()
        }
        do {
            return try await withTaskCancellationHandler {
                try await pairingTask.value.serverCertificateDER
            } onCancel: {
                coordinator.cancel()
                pairingTask.cancel()
            }
        } catch PairingError.cancelled {
            throw CancellationError()
        }
    }

    public func cancel(hostID: String) async {
        let cancellables = lock.withLock {
            guard activeAttempt != nil else {
                return (nil as (any PairingHandshakeCoordinating)?, nil as Task<PairedHostIdentity, Error>?)
            }
            activeAttempt?.cancellationRequested = true
            return (activeAttempt?.coordinator, activeAttempt?.task)
        }
        cancellables.0?.cancel()
        cancellables.1?.cancel()
    }
}
