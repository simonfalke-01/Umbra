import Foundation
import UmbraCore
import UmbraLSPTransport
import UmbraMedia

struct LSPProductPairingStart: Sendable {
    var session: LSPClientSession
    var prompt: LSPPairingPrompt
}

struct LSPProductPairingOperations: Sendable {
    var begin: @Sendable (LSPDiscoveredPairingHost) async throws -> LSPProductPairingStart
    var verify: @Sendable (LSPProductPairingStart) async throws -> LSPTrustRecord
    var cancel: @Sendable (LSPProductPairingStart) async -> Void
}

/// Discovery-registry change released after an in-flight pairing snapshot becomes terminal.
public enum LSPPairingDiscoveryMutation: Equatable, Sendable {
    case replaced(oldHostID: UUID, host: LSPDiscoveredPairingHost)
    case removed(hostID: UUID)
}

/// Coarse product owner for LSP persistence, pairing, auth, and application browsing.
public actor LSPProductClient {
    private struct ReconnectAttempt {
        var id: UUID
        var task: Task<LSPClientSession, Error>
    }
    private struct VerifiedPairing: Sendable {
        var start: LSPProductPairingStart
        var trust: LSPTrustRecord
        var host: LSPHostRecord
    }
    private struct PairingAttempt {
        var id: UUID
        var candidate: LSPDiscoveredPairingHost
        var beginTask: Task<LSPProductPairingStart, Error>
        var verificationTask: Task<VerifiedPairing, Error>?
        var verified: VerifiedPairing?
        var persistenceTask: Task<LSPHostRecord, Error>?
        var expiryTask: Task<Void, Never>?
        var cancelling: Bool
    }
    private enum QuarantinedPairingDiscovery {
        case updated(LSPDiscoveredPairingHost)
        case removed
    }
    private let trustStore: JSONFileStore<LSPTrustSnapshot>
    private let hostStore: JSONFileStore<LSPHostSnapshot>
    private let identityStore: JSONFileStore<LSPClientIdentitySnapshot>
    private var sessions: [UUID: LSPClientSession] = [:]
    private var reconnectAttempts: [UUID: ReconnectAttempt] = [:]
    private var discoveredPairingHosts: [UUID: LSPDiscoveredPairingHost] = [:]
    private var pairingAttempts: [UUID: PairingAttempt] = [:]
    private var quarantinedPairingDiscovery: [UUID: QuarantinedPairingDiscovery] = [:]
    private let videoRenderer: (any MetalVideoRendering)?
    private let pairingOperations: LSPProductPairingOperations
    private let afterPairingTrustWrite: @Sendable () throws -> Void
    private var pairingDiscoveryMutationHandler: (@Sendable (LSPPairingDiscoveryMutation) -> Void)?

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
        pairingOperations = Self.livePairingOperations(
            identityStore: identityStore,
            videoRenderer: videoRenderer
        )
        afterPairingTrustWrite = {}
    }

    init(
        trustStore: JSONFileStore<LSPTrustSnapshot>,
        hostStore: JSONFileStore<LSPHostSnapshot>,
        identityStore: JSONFileStore<LSPClientIdentitySnapshot>,
        videoRenderer: (any MetalVideoRendering)? = nil,
        pairingOperations: LSPProductPairingOperations,
        afterPairingTrustWrite: @escaping @Sendable () throws -> Void = {}
    ) {
        self.trustStore = trustStore
        self.hostStore = hostStore
        self.identityStore = identityStore
        self.videoRenderer = videoRenderer
        self.pairingOperations = pairingOperations
        self.afterPairingTrustWrite = afterPairingTrustWrite
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

    /// Installs the coarse product callback for quarantined discovery changes released at terminal state.
    public func setPairingDiscoveryMutationHandler(
        _ handler: (@Sendable (LSPPairingDiscoveryMutation) -> Void)?
    ) {
        pairingDiscoveryMutationHandler = handler
    }

    /// Adds or refreshes one PIN-capable LSP host from validated discovery metadata.
    @discardableResult
    public func registerDiscoveredPairingHost(
        _ host: LSPDiscoveredPairingHost
    ) -> LSPDiscoveredPairingHost {
        let active = pairingAttempts.first { activeHostID, attempt in
            activeHostID == host.hostID || attempt.candidate.discoveryServiceID == host.discoveryServiceID
        }
        if let (activeHostID, attempt) = active {
            if attempt.candidate != host {
                quarantinedPairingDiscovery[activeHostID] = .updated(host)
            }
            return attempt.candidate
        }
        let replacedHostIDs = discoveredPairingHosts.compactMap { existingHostID, existing in
            existing.discoveryServiceID == host.discoveryServiceID && existingHostID != host.hostID
                ? existingHostID : nil
        }
        for existingHostID in replacedHostIDs {
            discoveredPairingHosts.removeValue(forKey: existingHostID)
        }
        discoveredPairingHosts[host.hostID] = host
        return host
    }

    /// Removes one vanished discovery candidate unless its pairing is already active.
    @discardableResult
    public func unregisterDiscoveredPairingHost(
        hostID: UUID,
        discoveryServiceID: String
    ) -> Bool {
        if let (activeHostID, _) = pairingAttempts.first(where: { activeHostID, attempt in
            activeHostID == hostID || attempt.candidate.discoveryServiceID == discoveryServiceID
        }) {
            quarantinedPairingDiscovery[activeHostID] = .removed
            return false
        }
        discoveredPairingHosts.removeValue(forKey: hostID)
        return true
    }

    /// Starts one discovered-host PIN transaction and returns its six digits for local display.
    public func beginPairing(hostID: UUID) async throws -> LSPPairingPrompt {
        if let existing = pairingAttempts[hostID] {
            guard !existing.cancelling else { throw CancellationError() }
            return try await resolvePairingBegin(
                hostID: hostID,
                attemptID: existing.id,
                task: existing.beginTask
            )
        }
        guard let host = discoveredPairingHosts[hostID] else {
            throw LSPTransportError.invalidEndpoint
        }
        let attemptID = UUID()
        let operation = pairingOperations.begin
        let task = Task { try await operation(host) }
        pairingAttempts[hostID] = .init(
            id: attemptID,
            candidate: host,
            beginTask: task,
            verificationTask: nil,
            verified: nil,
            persistenceTask: nil,
            expiryTask: nil,
            cancelling: false
        )
        return try await resolvePairingBegin(hostID: hostID, attemptID: attemptID, task: task)
    }

    /// Completes one approved PIN transaction and only then persists LSP trust and host state.
    public func completePairing(hostID: UUID) async throws -> LSPHostRecord {
        guard var attempt = pairingAttempts[hostID], !attempt.cancelling else {
            throw LSPTransportError.invalidState
        }
        let verified: VerifiedPairing
        if let existing = attempt.verified {
            verified = existing
        } else {
            let verificationTask: Task<VerifiedPairing, Error>
            if let existing = attempt.verificationTask {
                verificationTask = existing
            } else {
                let beginTask = attempt.beginTask
                let candidate = attempt.candidate
                let verify = pairingOperations.verify
                let attemptID = attempt.id
                verificationTask = Task { [weak self] in
                    let start = try await beginTask.value
                    let trust = try await verify(start)
                    let verified = VerifiedPairing(
                        start: start,
                        trust: trust,
                        host: LSPHostRecord(
                            hostID: candidate.hostID,
                            name: candidate.name,
                            address: candidate.host,
                            port: candidate.port,
                            lastSeen: Date(),
                            discoveryDomain: candidate.domain,
                            interfaceName: candidate.interfaceName
                        )
                    )
                    await self?.recordVerifiedPairing(
                        verified,
                        hostID: candidate.hostID,
                        attemptID: attemptID
                    )
                    return verified
                }
                attempt.verificationTask = verificationTask
                pairingAttempts[hostID] = attempt
            }
            do {
                verified = try await verificationTask.value
                guard var current = pairingAttempts[hostID], current.id == attempt.id else {
                    throw CancellationError()
                }
                current.verified = verified
                current.expiryTask?.cancel()
                current.expiryTask = nil
                pairingAttempts[hostID] = current
                attempt = current
            } catch {
                finishPairingAttempt(hostID: hostID, attemptID: attempt.id)
                throw error
            }
        }

        let persistenceTask: Task<LSPHostRecord, Error>
        if let existing = attempt.persistenceTask {
            persistenceTask = existing
        } else {
            let trustStore = self.trustStore
            let hostStore = self.hostStore
            let afterTrustWrite = afterPairingTrustWrite
            persistenceTask = Task {
                try await LSPPairingPersistenceTransaction.commit(
                    trust: verified.trust,
                    host: verified.host,
                    trustStore: trustStore,
                    hostStore: hostStore,
                    afterTrustWrite: afterTrustWrite
                )
                return verified.host
            }
            guard var current = pairingAttempts[hostID], current.id == attempt.id else {
                throw CancellationError()
            }
            current.persistenceTask = persistenceTask
            current.verified = verified
            pairingAttempts[hostID] = current
        }
        do {
            let host = try await persistenceTask.value
            sessions[host.hostID] = verified.start.session
            finishPairingAttempt(hostID: hostID, attemptID: attempt.id)
            return host
        } catch {
            if var current = pairingAttempts[hostID], current.id == attempt.id {
                current.verified = verified
                current.persistenceTask = nil
                pairingAttempts[hostID] = current
            }
            throw error
        }
    }

    /// Cancels and zeroizes one incomplete PIN transaction without persistence.
    public func cancelPairing(hostID: UUID) async {
        guard var attempt = pairingAttempts[hostID], !attempt.cancelling else { return }
        guard attempt.verified == nil, attempt.persistenceTask == nil else { return }
        attempt.cancelling = true
        pairingAttempts[hostID] = attempt
        attempt.beginTask.cancel()
        attempt.verificationTask?.cancel()
        if let start = try? await attempt.beginTask.value,
           pairingAttempts[hostID]?.id == attempt.id {
            await pairingOperations.cancel(start)
            finishPairingAttempt(hostID: hostID, attemptID: attempt.id)
        }
    }

    private func resolvePairingBegin(
        hostID: UUID,
        attemptID: UUID,
        task: Task<LSPProductPairingStart, Error>
    ) async throws -> LSPPairingPrompt {
        let start: LSPProductPairingStart
        do {
            start = try await task.value
        } catch {
            finishPairingAttempt(hostID: hostID, attemptID: attemptID)
            throw error
        }
        do {
            try Task.checkCancellation()
            guard var current = pairingAttempts[hostID],
                  current.id == attemptID,
                  !current.cancelling else {
                throw CancellationError()
            }
            if current.expiryTask == nil {
                current.expiryTask = makePairingExpiryTask(
                    hostID: hostID,
                    attemptID: attemptID,
                    expiresAtUTCSeconds: start.prompt.expiresAtUTCSeconds
                )
                pairingAttempts[hostID] = current
            }
            return start.prompt
        } catch {
            await tearDownStalePairingStart(start, hostID: hostID, attemptID: attemptID)
            throw error
        }
    }

    private func recordVerifiedPairing(
        _ verified: VerifiedPairing,
        hostID: UUID,
        attemptID: UUID
    ) {
        guard var current = pairingAttempts[hostID],
              current.id == attemptID,
              !current.cancelling else { return }
        current.verified = verified
        current.expiryTask?.cancel()
        current.expiryTask = nil
        pairingAttempts[hostID] = current
    }

    private func makePairingExpiryTask(
        hostID: UUID,
        attemptID: UUID,
        expiresAtUTCSeconds: UInt64
    ) -> Task<Void, Never> {
        Task { [weak self] in
            let delay = max(0, TimeInterval(expiresAtUTCSeconds) - Date().timeIntervalSince1970)
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.expirePairingAttempt(hostID: hostID, attemptID: attemptID)
        }
    }

    private func expirePairingAttempt(hostID: UUID, attemptID: UUID) async {
        guard var attempt = pairingAttempts[hostID],
              attempt.id == attemptID,
              attempt.verified == nil,
              !attempt.cancelling else { return }
        attempt.cancelling = true
        pairingAttempts[hostID] = attempt
        attempt.beginTask.cancel()
        attempt.verificationTask?.cancel()
        if let start = try? await attempt.beginTask.value {
            await pairingOperations.cancel(start)
        }
        finishPairingAttempt(hostID: hostID, attemptID: attemptID)
    }

    private func tearDownStalePairingStart(
        _ start: LSPProductPairingStart,
        hostID: UUID,
        attemptID: UUID
    ) async {
        if sessions[hostID] === start.session { return }
        if var attempt = pairingAttempts[hostID], attempt.id == attemptID {
            attempt.cancelling = true
            attempt.expiryTask?.cancel()
            pairingAttempts[hostID] = attempt
            attempt.verificationTask?.cancel()
            await pairingOperations.cancel(start)
            finishPairingAttempt(hostID: hostID, attemptID: attemptID)
            return
        }
        return
    }

    private func finishPairingAttempt(hostID: UUID, attemptID: UUID) {
        guard pairingAttempts[hostID]?.id == attemptID else { return }
        pairingAttempts[hostID]?.expiryTask?.cancel()
        pairingAttempts.removeValue(forKey: hostID)
        if let quarantined = quarantinedPairingDiscovery.removeValue(forKey: hostID) {
            switch quarantined {
            case .updated(let host):
                discoveredPairingHosts.removeValue(forKey: hostID)
                discoveredPairingHosts[host.hostID] = host
                pairingDiscoveryMutationHandler?(.replaced(oldHostID: hostID, host: host))
            case .removed:
                discoveredPairingHosts.removeValue(forKey: hostID)
                pairingDiscoveryMutationHandler?(.removed(hostID: hostID))
            }
        }
    }

    private static func livePairingOperations(
        identityStore: JSONFileStore<LSPClientIdentitySnapshot>,
        videoRenderer: (any MetalVideoRendering)?
    ) -> LSPProductPairingOperations {
        .init(
            begin: { host in
                let session = try await LSPClientSession.persistent(
                    identityStore: identityStore,
                    videoRenderer: videoRenderer
                )
                return .init(session: session, prompt: try await session.beginPairing(host: host))
            },
            verify: { start in
                try await start.session.completePairing()
            },
            cancel: { start in
                await start.session.cancelPairing()
            }
        )
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
        reason: LSPReconnectReason,
        quiesceOldCapture: (@Sendable () async throws -> Void)? = nil
    ) async throws -> LSPClientSession {
        try Task.checkCancellation()
        if let existing = reconnectAttempts[hostID] {
            let value = try await existing.task.value
            try Task.checkCancellation()
            return value
        }
        let attemptID = UUID()
        let task = Task { [self] in
            try await performReconnect(
                hostID: hostID,
                reason: reason,
                attemptID: attemptID,
                quiesceOldCapture: quiesceOldCapture
            )
        }
        reconnectAttempts[hostID] = .init(id: attemptID, task: task)
        do {
            let replacement = try await task.value
            try Task.checkCancellation()
            if reconnectAttempts[hostID]?.id == attemptID { reconnectAttempts.removeValue(forKey: hostID) }
            return replacement
        } catch {
            if reconnectAttempts[hostID]?.id == attemptID { reconnectAttempts.removeValue(forKey: hostID) }
            throw error
        }
    }

    private func performReconnect(
        hostID: UUID,
        reason: LSPReconnectReason,
        attemptID: UUID,
        quiesceOldCapture: (@Sendable () async throws -> Void)?
    ) async throws -> LSPClientSession {
        try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
        guard let previous = sessions[hostID] else {
            throw LSPTransportError.invalidState
        }
        let hosts = try await hostStore.load().records
        try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
        let trusts = try await trustStore.load().records
        try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
        guard let host = hosts.first(where: { $0.hostID == hostID }),
              let trust = trusts.first(where: { $0.hostID == hostID })
        else {
            throw LSPControlStatus.authenticationFailed
        }
        let prior = try await previous.activeInputAuthority()
        try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
        let nativeHandoff = try await previous.makeNativeHandoff()
        try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
        if reason == .transportLoss {
            try await previous.markActiveLost(in: nativeHandoff)
            try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
        }
        do {
            let replacement = try await authenticatedCandidate(
                host: host,
                trust: trust,
                attemptID: attemptID
            )
            try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
            try await replacement.enroll(in: nativeHandoff, reason: reason)
            try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
            try await quiesceOldCapture?()
            try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
            do {
                _ = try await replacement.attach(
                    previous: previous,
                    reason: reason,
                    nativeHandoff: nativeHandoff
                )
                try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
                sessions[hostID] = replacement
                return replacement
            } catch let ambiguous as LSPAmbiguousAttachFailure {
                do {
                    let presumed = try presumedCommittedAuthority(from: ambiguous)
                    if ambiguous.outcome == .submittedNoAuthenticatedOutcome {
                        try nativeHandoff.cancelAmbiguous()
                    }
                    nativeHandoff.releaseBindings()
                    let forwardHandoff = try await replacement.makeNativeHandoff(authority: presumed)
                    try await replacement.markActiveLost(in: forwardHandoff)
                    let forward = try await authenticatedCandidate(
                        host: host,
                        trust: trust,
                        attemptID: attemptID
                    )
                    try await forward.enroll(in: forwardHandoff, reason: .transportLoss)
                    try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
                    do {
                        _ = try await forward.attach(
                            previous: previous,
                            reason: .transportLoss,
                            presentedAuthority: presumed,
                            neutralizePrevious: true,
                            nativeHandoff: forwardHandoff
                        )
                        try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
                        await replacement.invalidateAuthorityAfterAmbiguousAttach()
                        try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
                        sessions[hostID] = forward
                        return forward
                    } catch let status as LSPControlStatus
                        where ambiguous.outcome == .submittedNoAuthenticatedOutcome &&
                              status == .authenticationFailed {
                        // Authenticated successor rejection proves the first ATTACH did not commit.
                        // Continue forward on a fresh association with the predecessor token;
                        // the prior local core remains terminal and is never restored.
                        let fallback = try await authenticatedCandidate(
                            host: host,
                            trust: trust,
                            attemptID: attemptID
                        )
                        try forwardHandoff.cancelAmbiguous()
                        forwardHandoff.releaseBindings()
                        let fallbackHandoff = try await previous.makeNativeHandoff(authority: prior)
                        try await previous.markActiveLost(in: fallbackHandoff)
                        try await fallback.enroll(in: fallbackHandoff, reason: .transportLoss)
                        try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
                        _ = try await fallback.attach(
                            previous: previous,
                            reason: .transportLoss,
                            presentedAuthority: prior,
                            neutralizePrevious: true,
                            nativeHandoff: fallbackHandoff
                        )
                        try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
                        await replacement.invalidateAuthorityAfterAmbiguousAttach()
                        try ensureAttemptCurrent(hostID: hostID, attemptID: attemptID)
                        sessions[hostID] = fallback
                        return fallback
                    }
                } catch {
                    await previous.invalidateAuthorityAfterAmbiguousAttach()
                    throw error
                }
            }
        }
    }

    private func authenticatedCandidate(
        host: LSPHostRecord,
        trust: LSPTrustRecord,
        attemptID: UUID
    ) async throws -> LSPClientSession {
        try ensureAttemptCurrent(hostID: trust.hostID, attemptID: attemptID)
        let candidate = try await LSPClientSession.persistent(identityStore: identityStore, videoRenderer: videoRenderer)
        try ensureAttemptCurrent(hostID: trust.hostID, attemptID: attemptID)
        await candidate.beginReconnect(attemptID: attemptID)
        try ensureAttemptCurrent(hostID: trust.hostID, attemptID: attemptID)
        let updatedTrust = try await candidate.authenticate(host: host, trust: trust)
        try ensureAttemptCurrent(hostID: trust.hostID, attemptID: attemptID)
        await candidate.markCandidateAuthenticated()
        try ensureAttemptCurrent(hostID: trust.hostID, attemptID: attemptID)
        _ = try await trustStore.update { snapshot in
            var snapshot = snapshot
            snapshot.records.removeAll { $0.hostID == trust.hostID }
            snapshot.records.append(updatedTrust)
            return snapshot
        }
        try ensureAttemptCurrent(hostID: trust.hostID, attemptID: attemptID)
        return candidate
    }

    private func ensureAttemptCurrent(hostID: UUID, attemptID: UUID) throws {
        try Task.checkCancellation()
        guard reconnectAttempts[hostID]?.id == attemptID else { throw CancellationError() }
    }

    private func presumedCommittedAuthority(
        from failure: LSPAmbiguousAttachFailure
    ) throws -> LSPActiveInputAuthority {
        var authority = failure.prior
        guard authority.nativeConfiguration.inputGeneration < UInt32.max,
              authority.audioConfiguration.audioGeneration < UInt32.max,
              authority.videoSelection.nativeConfiguration.videoGeneration < UInt32.max else {
            throw LSPTransportError.internalFailure
        }
        authority.attachToken = failure.successorAttachToken
        authority.connectionGeneration = failure.candidateConnectionGeneration
        authority.nativeConfiguration.inputGeneration += 1
        authority.audioConfiguration.audioGeneration += 1
        authority.videoSelection.nativeConfiguration.videoGeneration += 1
        if authority.microphoneConfiguration != nil {
            guard authority.microphoneConfiguration!.microphoneGeneration < UInt32.max else {
                throw LSPTransportError.internalFailure
            }
            authority.microphoneConfiguration!.microphoneGeneration += 1
        }
        return authority
    }

    public func markCaptureTransferred(hostID: UUID, session: LSPClientSession) async {
        guard sessions[hostID] === session else { return }
        await session.markCaptureTransferred()
    }

    public func isCurrentSession(_ session: LSPClientSession, hostID: UUID) -> Bool {
        sessions[hostID] === session
    }

    public func currentSession(hostID: UUID) -> LSPClientSession? {
        sessions[hostID]
    }

    public func reconnectTelemetry(hostID: UUID) async -> LSPReconnectSnapshot? {
        guard let session = sessions[hostID] else { return nil }
        return await session.reconnectTelemetry()
    }

    /// Planned rekey is the same fresh-DTLS ATTACH path as reconnect.
    public func rekeyInput(hostID: UUID) async throws -> LSPClientSession {
        try await reconnectInput(hostID: hostID, reason: .plannedRekey)
    }

    public func stop(hostID: UUID) async {
        reconnectAttempts.removeValue(forKey: hostID)?.task.cancel()
        guard let session = sessions[hostID], [.authenticated, .inputActive].contains(await session.state) else { return }
        try? await session.stop()
    }

    /// Removes only native LSP host/trust state and stops its session.
    public func remove(hostID: UUID) async throws {
        reconnectAttempts.removeValue(forKey: hostID)?.task.cancel()
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
