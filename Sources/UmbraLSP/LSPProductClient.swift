import Foundation
import UmbraCore
import UmbraLSPTransport
import UmbraMedia

/// Coarse product owner for LSP persistence, pairing, auth, and application browsing.
public actor LSPProductClient {
    private let trustStore: JSONFileStore<LSPTrustSnapshot>
    private let hostStore: JSONFileStore<LSPHostSnapshot>
    private let identityStore: JSONFileStore<LSPClientIdentitySnapshot>
    private var sessions: [UUID: LSPClientSession] = [:]
    private let videoRenderer: (any MetalVideoRendering)?

    public init(
        trustStore: JSONFileStore<LSPTrustSnapshot>,
        hostStore: JSONFileStore<LSPHostSnapshot>,
        identityStore: JSONFileStore<LSPClientIdentitySnapshot>,
        videoRenderer: (any MetalVideoRendering)? = nil
    ) {
        self.trustStore = trustStore
        self.hostStore = hostStore
        self.identityStore = identityStore
        self.videoRenderer = videoRenderer
    }

    /// Creates a product client using Umbra's normal owner-private Application Support files.
    public static func applicationSupport(videoRenderer: (any MetalVideoRendering)? = nil) throws -> LSPProductClient {
        let stores = try LSPPersistence.applicationSupportStores()
        return LSPProductClient(
            trustStore: stores.trust,
            hostStore: stores.hosts,
            identityStore: stores.identity,
            videoRenderer: videoRenderer
        )
    }

    /// Returns persisted native hosts without contacting legacy GameStream services.
    public func hosts() async throws -> [LSPHostRecord] {
        try await hostStore.load().records
    }

    /// Imports a single-use invitation, performs real pairing, and persists fresh LSP trust.
    public func pair(invitationURI: String) async throws -> LSPHostRecord {
        let invitation = try LSPPairingInvitation.decode(uri: invitationURI)
        let session = try await LSPClientSession.persistent(identityStore: identityStore, videoRenderer: videoRenderer)
        let trust = try await session.pair(invitation: invitation)
        let host = LSPHostRecord(
            hostID: invitation.hostID,
            name: invitation.host,
            address: invitation.host,
            port: invitation.port,
            lastSeen: Date()
        )
        _ = try await trustStore.update { snapshot in
            var snapshot = snapshot
            snapshot.records.removeAll { $0.hostID == trust.hostID }
            snapshot.records.append(trust)
            return snapshot
        }
        _ = try await hostStore.update { snapshot in
            var snapshot = snapshot
            snapshot.records.removeAll { $0.hostID == host.hostID }
            snapshot.records.append(host)
            return snapshot
        }
        sessions[host.hostID] = session
        return host
    }

    /// Authenticates stored trust and returns the exact host application snapshot.
    public func applications(hostID: UUID) async throws -> [LSPApplication] {
        let hosts = try await hostStore.load().records
        let trusts = try await trustStore.load().records
        guard let host = hosts.first(where: { $0.hostID == hostID }),
              let trust = trusts.first(where: { $0.hostID == hostID })
        else {
            throw LSPControlStatus.authenticationFailed
        }
        let session: LSPClientSession
        if let existing = sessions[hostID], [.authenticated, .inputActive].contains(await existing.state) {
            session = existing
        } else {
            let created = try await LSPClientSession.persistent(identityStore: identityStore, videoRenderer: videoRenderer)
            let updatedTrust = try await created.authenticate(host: host, trust: trust)
            _ = try await trustStore.update { snapshot in
                var snapshot = snapshot
                snapshot.records.removeAll { $0.hostID == hostID }
                snapshot.records.append(updatedTrust)
                return snapshot
            }
            sessions[hostID] = created
            session = created
        }
        return try await session.listApplications()
    }

    /// Starts the negotiated input-only session for one authenticated native application.
    public func startInput(
        hostID: UUID,
        applicationID: String,
        pointerRate: UInt32 = 1_000,
        microphoneOffer: LSPMicrophoneOffer? = nil,
        capabilities: AppleStreamingCapabilities,
        preferences: StreamingPreferences,
        refreshNumerator: UInt32,
        refreshDenominator: UInt32,
        receiveBatchCapacity: UInt8 = 64,
        decoderSurfaces: UInt8 = 3,
        maximumCaptureToPresentMicroseconds: UInt32 = 50_000
    ) async throws -> LSPClientSession {
        guard preferences.videoDecoderPreference != .software,
              preferences.rendererPreference == .automatic || preferences.rendererPreference == .metal
        else { throw LSPControlStatus.unsupportedMediaTuple }
        let bitrate = UInt64(preferences.bitrateKbps) * 1_000
        let offers = LSPVideoOffer.hardwareOffers(
            capabilities: capabilities,
            width: UInt32(preferences.width),
            height: UInt32(preferences.height),
            refreshNumerator: refreshNumerator,
            refreshDenominator: refreshDenominator,
            preferredBitsPerSecond: bitrate,
            maximumBitsPerSecond: bitrate,
            codecPreference: preferences.videoCodecPreference,
            enableHDR: preferences.enableHDR,
            hdrTransferPreference: preferences.hdrTransferPreference,
            enableYUV444: preferences.enableYUV444
        )
        guard !offers.isEmpty else { throw LSPControlStatus.unsupportedMediaTuple }
        return try await startInput(
            hostID: hostID,
            applicationID: applicationID,
            pointerRate: pointerRate,
            microphoneOffer: microphoneOffer,
            videoOffers: offers,
            receiveBatchCapacity: receiveBatchCapacity,
            decoderSurfaces: decoderSurfaces,
            maximumCaptureToPresentMicroseconds: maximumCaptureToPresentMicroseconds
        )
    }

    /// Starts with already proven exact offers, primarily for controlled integration callers.
    func startInput(
        hostID: UUID,
        applicationID: String,
        pointerRate: UInt32 = 1_000,
        microphoneOffer: LSPMicrophoneOffer? = nil,
        videoOffers: [LSPVideoOffer],
        receiveBatchCapacity: UInt8 = 64,
        decoderSurfaces: UInt8 = 3,
        maximumCaptureToPresentMicroseconds: UInt32 = 50_000
    ) async throws -> LSPClientSession {
        _ = try await applications(hostID: hostID)
        guard let session = sessions[hostID], await session.state == .authenticated else {
            throw LSPTransportError.notAuthenticated
        }
        _ = try await session.startInput(LSPInputStartRequest(
            applicationID: applicationID,
            pointerRate: pointerRate,
            microphoneOffer: microphoneOffer,
            videoOffers: videoOffers,
            receiveBatchCapacity: receiveBatchCapacity,
            decoderSurfaces: decoderSurfaces,
            maximumCaptureToPresentMicroseconds: maximumCaptureToPresentMicroseconds
        ))
        return session
    }

    /// Reconnects or rekeys through a fresh DTLS association and authenticated ATTACH.
    public func reconnectInput(
        hostID: UUID,
        reason: LSPReconnectReason
    ) async throws -> LSPClientSession {
        guard let previous = sessions[hostID] else {
            throw LSPTransportError.invalidState
        }
        let hosts = try await hostStore.load().records
        let trusts = try await trustStore.load().records
        guard let host = hosts.first(where: { $0.hostID == hostID }),
              let trust = trusts.first(where: { $0.hostID == hostID })
        else {
            throw LSPControlStatus.authenticationFailed
        }
        let replacement = try await LSPClientSession.persistent(identityStore: identityStore, videoRenderer: videoRenderer)
        let updatedTrust = try await replacement.authenticate(host: host, trust: trust)
        _ = try await trustStore.update { snapshot in
            var snapshot = snapshot
            snapshot.records.removeAll { $0.hostID == hostID }
            snapshot.records.append(updatedTrust)
            return snapshot
        }
        _ = try await replacement.attach(previous: previous, reason: reason)
        sessions[hostID] = replacement
        return replacement
    }

    /// Planned rekey is the same fresh-DTLS ATTACH path as reconnect.
    public func rekeyInput(hostID: UUID) async throws -> LSPClientSession {
        try await reconnectInput(hostID: hostID, reason: .plannedRekey)
    }

    public func stop(hostID: UUID) async {
        guard let session = sessions[hostID], [.authenticated, .inputActive].contains(await session.state) else { return }
        try? await session.stop()
    }

    /// Removes only native LSP host/trust state and stops its session.
    public func remove(hostID: UUID) async throws {
        if let session = sessions.removeValue(forKey: hostID), [.authenticated, .inputActive].contains(await session.state) {
            try await session.stop()
        }
        _ = try await trustStore.update { snapshot in
            var snapshot = snapshot
            snapshot.records.removeAll { $0.hostID == hostID }
            return snapshot
        }
        _ = try await hostStore.update { snapshot in
            var snapshot = snapshot
            snapshot.records.removeAll { $0.hostID == hostID }
            return snapshot
        }
    }

    /// Renames one persisted native host without touching legacy records.
    public func rename(hostID: UUID, name: String) async throws -> LSPHostRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeterministicCBORError.malformed }
        _ = try await hostStore.update { snapshot in
            var snapshot = snapshot
            guard let index = snapshot.records.firstIndex(where: { $0.hostID == hostID }) else {
                throw LSPControlStatus.authenticationFailed
            }
            snapshot.records[index].name = trimmed
            return snapshot
        }
        guard let updated = try await hostStore.load().records.first(where: { $0.hostID == hostID }) else {
            throw LSPControlStatus.authenticationFailed
        }
        return updated
    }
}
