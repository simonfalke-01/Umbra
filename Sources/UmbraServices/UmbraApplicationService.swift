import Foundation
import UmbraCore
import UmbraNetworking

public enum SessionStartupStage: String, CaseIterable, Sendable, Hashable {
    case uiActivate = "ui.activate"
    case hostLaunch = "host.launch"
    case sessionStart = "session.start"
    case decoderSubmitRequested = "decoder.submit.requested"
    case presentationCommit = "renderer.presentation.commit.proxy"
}

public struct SessionStartupTelemetrySnapshot: Sendable, Equatable {
    public let sessionID: UUID
    public let elapsedByStage: [SessionStartupStage: TimeInterval]

    public init(
        sessionID: UUID,
        elapsedByStage: [SessionStartupStage: TimeInterval]
    ) {
        self.sessionID = sessionID
        self.elapsedByStage = elapsedByStage
    }
}

/// Correlates startup milestones using one monotonic process clock. Values are
/// elapsed stage proxies, never wall-clock timestamps or input-to-photon claims.
public final class SessionStartupTelemetryRecorder: @unchecked Sendable {
    private struct State {
        let origin: TimeInterval
        var lastRecordedTime: TimeInterval
        var stageTimes: [SessionStartupStage: TimeInterval]
    }

    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private let diagnosticHandler: @Sendable (String) -> Void
    private let retainedSessionLimit: Int
    private var states: [UUID: State] = [:]
    private var sessionOrder: [UUID] = []

    public init(
        retainedSessionLimit: Int = 16,
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        diagnosticHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.retainedSessionLimit = max(1, retainedSessionLimit)
        self.now = now
        self.diagnosticHandler = diagnosticHandler
    }

    public func begin(sessionID: UUID, uiActivationTime: TimeInterval? = nil) {
        let sampledNow = now()
        let suppliedOrigin = uiActivationTime.flatMap { $0.isFinite ? $0 : nil }
        let origin = min(suppliedOrigin ?? sampledNow, sampledNow)
        lock.withLock {
            states[sessionID] = State(
                origin: origin,
                lastRecordedTime: origin,
                stageTimes: [.uiActivate: origin]
            )
            sessionOrder.removeAll { $0 == sessionID }
            sessionOrder.append(sessionID)
            while sessionOrder.count > retainedSessionLimit {
                states.removeValue(forKey: sessionOrder.removeFirst())
            }
        }
        emit(sessionID: sessionID, stage: .uiActivate, elapsed: 0, delta: 0)
    }

    public func record(sessionID: UUID, stage: SessionStartupStage) {
        let sampledNow = now()
        let measurement = lock.withLock { () -> (elapsed: TimeInterval, delta: TimeInterval)? in
            guard var state = states[sessionID], state.stageTimes[stage] == nil else {
                return nil
            }
            let monotonicTime = max(sampledNow, state.lastRecordedTime)
            let elapsed = monotonicTime - state.origin
            let delta = monotonicTime - state.lastRecordedTime
            state.lastRecordedTime = monotonicTime
            state.stageTimes[stage] = monotonicTime
            states[sessionID] = state
            return (elapsed, delta)
        }
        guard let measurement else { return }
        emit(
            sessionID: sessionID,
            stage: stage,
            elapsed: measurement.elapsed,
            delta: measurement.delta
        )
    }

    public func snapshot(sessionID: UUID) -> SessionStartupTelemetrySnapshot? {
        lock.withLock {
            guard let state = states[sessionID] else { return nil }
            return SessionStartupTelemetrySnapshot(
                sessionID: sessionID,
                elapsedByStage: state.stageTimes.mapValues { $0 - state.origin }
            )
        }
    }

    private func emit(
        sessionID: UUID,
        stage: SessionStartupStage,
        elapsed: TimeInterval,
        delta: TimeInterval
    ) {
        diagnosticHandler(
            "Startup stage session=\(sessionID.uuidString) stage=\(stage.rawValue) "
                + String(format: "elapsed_proxy_ms=%.3f stage_delta_proxy_ms=%.3f", elapsed * 1_000, delta * 1_000)
        )
    }
}

public protocol UmbraApplicationServicing: Sendable {
    func hosts() async throws -> [StreamHost]
    func refreshHosts() async throws -> [StreamHost]
    func refreshHost(id: String) async throws -> StreamHost
    func addHost(address: String, port: UInt16?) async throws -> StreamHost
    func applications(hostID: String, refresh: Bool, includeHidden: Bool) async throws -> [StreamApplication]
    func boxArt(hostID: String, applicationID: Int) async throws -> Data
    func wakeHost(id: String) async throws -> StreamHost
    func renameHost(id: String, name: String) async throws -> StreamHost
    func removeHost(id: String) async throws
    func details(hostID: String) async throws -> HostDetails
    func beginSession(_ intent: SessionIntent) async throws -> StreamSession
    func stopSession(quitHostApplication: Bool) async throws -> StreamSession
    @discardableResult
    func cancelHostApplication(hostID: String, applicationID: Int) async throws -> StreamHost
    func setDiscoveryEnabled(_ enabled: Bool) async
}

public actor UmbraApplicationService: UmbraApplicationServicing {
    public typealias EventHandler = @Sendable (HostServiceEvent) -> Void

    private struct RefreshRequestIdentity: Equatable, Sendable {
        let serverCertificate: Data
        let addresses: [NetworkEndpoint]
        let activeHTTPSPort: UInt16?
    }

    private struct HostRefreshTaskEntry {
        let token: UUID
        let identity: RefreshRequestIdentity
        let task: Task<StreamHost, Error>
    }

    private struct ApplicationRefreshTaskEntry {
        let token: UUID
        let identity: RefreshRequestIdentity
        let task: Task<[StreamApplication], Error>
    }

    private struct SessionPreparationOperation {
        let id: UUID
        let hostID: String
        let completion: CancellableTaskWaiter<StreamSession>
        let task: Task<Void, Never>
    }

    private struct SessionCompensationOperation {
        let token: UUID
        let task: Task<Void, Error>
    }

    private struct CancelledLaunchCompensation: Sendable {
        let client: any GameStreamServing
        let address: HostAddress
        let hostID: String
        let applicationID: Int
    }

    private enum SessionPreparationOwnership: Sendable {
        case localPreparation
        case launchedRemoteApplication(CancelledLaunchCompensation)
        case streamDriver

        var cancelledLaunchCompensation: CancelledLaunchCompensation? {
            guard case let .launchedRemoteApplication(compensation) = self else { return nil }
            return compensation
        }

        var belongsToStreamDriver: Bool {
            if case .streamDriver = self { return true }
            return false
        }
    }

    private struct SupersededSessionPreparation {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let persistence: any SnapshotPersisting
    private let clientProvider: any GameStreamClientProviding
    private let discovery: (any BonjourDiscovering)?
    private let discoveryResolver: any DiscoveredServiceResolving
    private let wakeSender: any WakeOnLANSending
    private let pairingAdapter: (any HostPairingAdapting)?
    private let streamDriver: (any StreamSessionDriving)?
    private let credentialProvider: any RemoteInputCredentialProviding
    private let uuidProvider: any UUIDProviding
    private let clock: any ServiceClock
    private let pollInterval: Duration
    private let offlineFailureThreshold: Int
    private let cancelConfirmationAttempts: Int
    private let cancelConfirmationInterval: Duration
    private let sessionStartAttempts: Int
    private let sessionStartRetryInterval: Duration
    private let clientIdentityFingerprint: Data?
    private let startupTelemetry: SessionStartupTelemetryRecorder
    private let normalizer = AddressNormalizer()
    private var compatibilityPolicy: NVIDIAServerCompatibilityPolicy

    private var snapshot: UmbraSnapshot?
    private var nextPersistenceMutationGeneration: UInt64 = 0
    private var appliedPersistenceMutationGeneration: UInt64 = 0
    private var consecutiveFailures: [String: Int] = [:]
    private var refreshTasks: [String: HostRefreshTaskEntry] = [:]
    private var applicationRefreshTasks: [String: ApplicationRefreshTaskEntry] = [:]
    private var eventHandler: EventHandler?
    private var pollingTask: Task<Void, Never>?
    private var discoveryEnabled: Bool
    private var discoveryIsRunning = false
    private var discoveryGeneration: UInt64 = 0
    private var sessionTask: Task<Void, Never>?
    private var activeSession: StreamSession?
    private var preparingSessionID: UUID?
    private var sessionPreparation: SessionPreparationOperation?
    private var sessionCompensations: [String: SessionCompensationOperation] = [:]
    private var supersededSessionPreparations: [String: [SupersededSessionPreparation]] = [:]
    private var stopInProgress = false

    public init(
        persistence: any SnapshotPersisting,
        clientProvider: any GameStreamClientProviding,
        discovery: (any BonjourDiscovering)? = NetworkBonjourDiscovery(),
        discoveryEnabled: Bool = true,
        discoveryResolver: any DiscoveredServiceResolving = LocalNameServiceResolver(),
        wakeSender: any WakeOnLANSending = NetworkWakeOnLANSender(),
        pairingAdapter: (any HostPairingAdapting)? = nil,
        streamDriver: (any StreamSessionDriving)? = nil,
        credentialProvider: any RemoteInputCredentialProviding = SecureRemoteInputCredentialProvider(),
        uuidProvider: any UUIDProviding = SystemUUIDProvider(),
        clock: any ServiceClock = ContinuousServiceClock(),
        pollInterval: Duration = .seconds(3),
        offlineFailureThreshold: Int = 2,
        cancelConfirmationAttempts: Int = 10,
        cancelConfirmationInterval: Duration = .milliseconds(500),
        sessionStartAttempts: Int = 4,
        sessionStartRetryInterval: Duration = .milliseconds(350),
        clientIdentityFingerprint: Data? = nil,
        startupTelemetry: SessionStartupTelemetryRecorder = SessionStartupTelemetryRecorder(),
        maximumSupportedNVIDIAVersion: String = NVIDIAServerCompatibilityPolicy.bundledMaximumVersion
    ) {
        self.persistence = persistence
        self.clientProvider = clientProvider
        self.discovery = discovery
        self.discoveryEnabled = discoveryEnabled
        self.discoveryResolver = discoveryResolver
        self.wakeSender = wakeSender
        self.pairingAdapter = pairingAdapter
        self.streamDriver = streamDriver
        self.credentialProvider = credentialProvider
        self.uuidProvider = uuidProvider
        self.clock = clock
        self.pollInterval = pollInterval
        self.offlineFailureThreshold = max(1, offlineFailureThreshold)
        self.cancelConfirmationAttempts = max(1, cancelConfirmationAttempts)
        self.cancelConfirmationInterval = cancelConfirmationInterval
        self.sessionStartAttempts = max(1, sessionStartAttempts)
        self.sessionStartRetryInterval = sessionStartRetryInterval
        self.clientIdentityFingerprint = clientIdentityFingerprint
        self.startupTelemetry = startupTelemetry
        self.compatibilityPolicy = NVIDIAServerCompatibilityPolicy(
            maximumSupportedVersion: maximumSupportedNVIDIAVersion
        ) ?? NVIDIAServerCompatibilityPolicy()!
    }

    deinit {
        pollingTask?.cancel()
        sessionPreparation?.task.cancel()
        sessionTask?.cancel()
        sessionCompensations.values.forEach { $0.task.cancel() }
        supersededSessionPreparations.values.joined().forEach { $0.task.cancel() }
        discovery?.stop()
    }

    public func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
        if let activeSession { handler?(.session(activeSession)) }
    }

    @discardableResult
    public func startMonitoring() async throws -> [StreamHost] {
        let initial = try await hosts()
        guard pollingTask == nil else { return initial }
        startDiscoveryIfNeeded()
        pollingTask = Task { [weak self, clock, pollInterval] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: pollInterval)
                    guard !Task.isCancelled else { break }
                    _ = try await self?.refreshHosts()
                } catch is CancellationError {
                    break
                } catch {
                    await self?.publishFailure(ServiceErrorMapper.map(error, operation: .refresh))
                }
            }
        }
        return initial
    }

    public func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
        stopDiscoveryIfNeeded()
    }

    public func setDiscoveryEnabled(_ enabled: Bool) {
        guard discoveryEnabled != enabled else { return }
        discoveryEnabled = enabled
        guard pollingTask != nil else { return }
        if enabled {
            startDiscoveryIfNeeded()
        } else {
            stopDiscoveryIfNeeded()
        }
    }

    public func updateMaximumSupportedNVIDIAVersion(_ version: String) async throws {
        guard let policy = NVIDIAServerCompatibilityPolicy(maximumSupportedVersion: version) else {
            throw UmbraServiceError.invalidInput(
                field: "NVIDIA compatibility version",
                message: "must contain two to four non-negative numeric components"
            )
        }
        compatibilityPolicy = policy
        let mutationGeneration = reservePersistenceMutationGeneration()
        let updated = try await persistence.update { current in
            var value = current
            for index in value.hosts.indices {
                value.hosts[index].isSupportedServerVersion = policy.isSupported(
                    isNVIDIAServerSoftware: value.hosts[index].isNvidiaServerSoftware,
                    gfeVersion: value.hosts[index].gfeVersion
                )
            }
            return value
        }
        applyPersistedSnapshot(updated, generation: mutationGeneration)
    }

    public func hosts() async throws -> [StreamHost] {
        let value = try await ensureSnapshot().hosts
        return value.sorted(by: Self.hostOrder)
    }

    @discardableResult
    public func refreshHosts() async throws -> [StreamHost] {
        let ids = try await ensureSnapshot().hosts.map(\.uuid)
        for id in ids {
            do {
                _ = try await refreshHost(id: id)
            } catch let error as UmbraServiceError {
                // One unreachable machine must not prevent the rest of the saved hosts from
                // being polled. The per-host error is still observable by event consumers.
                publishFailure(error)
            }
        }
        let result = try await hosts()
        publish(.hosts(result))
        return result
    }

    @discardableResult
    public func refreshHost(id: String) async throws -> StreamHost {
        let original = try await storedHost(id)
        let identity = Self.refreshRequestIdentity(for: original)
        if let entry = refreshTasks[id],
           entry.identity == identity {
            return try await awaitSharedTaskRespectingCancellation(entry.task)
        }
        refreshTasks[id]?.task.cancel()
        let token = UUID()
        let task = Task { [weak self, original] () throws -> StreamHost in
            guard let self else { throw CancellationError() }
            return try await self.performHostRefresh(original: original)
        }
        refreshTasks[id] = HostRefreshTaskEntry(
            token: token,
            identity: identity,
            task: task
        )
        Task { [weak self] in
            _ = await task.result
            await self?.clearRefreshTask(hostID: id, token: token)
        }
        return try await awaitSharedTaskRespectingCancellation(task)
    }

    private func performHostRefresh(original: StreamHost) async throws -> StreamHost {
        let id = original.uuid
        let outcome = await fetchServerInfo(for: original)
        try Task.checkCancellation()

        switch outcome {
        case let .success((info, address)):
            let latest = try await storedHost(id)
            let identity = Self.refreshRequestIdentity(for: original)
            guard Self.refreshRequestIdentity(for: latest) == identity else {
                throw CancellationError()
            }
            consecutiveFailures[id] = 0
            let refreshed = merge(existing: latest, info: info, address: address, manualAddress: nil)
            try Task.checkCancellation()
            return try await upsert(
                refreshed,
                expectedRefreshIdentity: identity
            )
        case let .failure(error):
            var latest = try await storedHost(id)
            let identity = Self.refreshRequestIdentity(for: original)
            guard Self.refreshRequestIdentity(for: latest) == identity else {
                throw CancellationError()
            }
            let failures = (consecutiveFailures[id] ?? 0) + 1
            consecutiveFailures[id] = failures
            if failures >= offlineFailureThreshold { latest.status = .offline }
            try Task.checkCancellation()
            let committed = try await upsert(
                latest,
                expectedRefreshIdentity: identity
            )
            if committed.status == .offline { return committed }
            throw ServiceErrorMapper.map(error, operation: .refresh, hostID: id)
        }
    }

    private func clearRefreshTask(hostID: String, token: UUID) {
        guard refreshTasks[hostID]?.token == token else { return }
        refreshTasks[hostID] = nil
    }

    @discardableResult
    public func addHost(address input: String, port: UInt16? = nil) async throws -> StreamHost {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw UmbraServiceError.invalidInput(field: "host address", message: "must not be empty")
        }
        do {
            var address = try normalizer.normalize(trimmed)
            if let port { address.port = port }
            let info = try await clientProvider.client(for: nil).fetchServerInfo(
                address: address,
                secure: false,
                fastFail: false
            )
            let existing = try await ensureSnapshot().hosts.first { $0.uuid == info.uniqueID }
            let host = merge(existing: existing, info: info, address: address, manualAddress: address)
            consecutiveFailures[host.uuid] = 0
            try await upsert(host)
            return host
        } catch {
            throw ServiceErrorMapper.map(error, operation: .addHost)
        }
    }

    @discardableResult
    public func pairHost(id: String, pin: String) async throws -> StreamHost {
        guard pin.count == 4, pin.allSatisfy(\.isNumber), pin.utf8.count == 4 else {
            throw UmbraServiceError.invalidInput(field: "pairing PIN", message: "must contain exactly four digits")
        }
        guard let pairingAdapter else { throw UmbraServiceError.pairingUnavailable }
        var host = try await storedHost(id)
        if host.appVersion?.isEmpty != false {
            host = try await refreshHost(id: id)
        }
        guard let appVersion = host.appVersion, !appVersion.isEmpty else {
            throw UmbraServiceError.protocolFailure(
                operation: .pairing,
                statusCode: nil,
                message: "The host did not report a server version required for secure pairing."
            )
        }
        let address = try address(for: host, secure: false)
        do {
            let certificate = try await pairingAdapter.pair(
                host: address,
                pin: pin,
                appVersion: appVersion,
                isNVIDIAServerSoftware: host.isNvidiaServerSoftware
            ) { [weak self] progress in
                Task { await self?.publish(.pairing(progress)) }
            }
            guard !certificate.isEmpty else {
                throw UmbraServiceError.authenticationFailed("Pairing completed without a server certificate.")
            }
            var latest = try await storedHost(id)
            latest.serverCertificate = certificate
            latest.pairState = .paired
            // Requests started before pairing used a different authentication boundary.
            // Cancel them before persisting the certificate so no insecure response can
            // overwrite the newly paired state.
            refreshTasks[id]?.task.cancel()
            refreshTasks[id] = nil
            applicationRefreshTasks[id]?.task.cancel()
            applicationRefreshTasks[id] = nil
            try await upsert(latest)
            return (try? await refreshHost(id: id)) ?? latest
        } catch {
            throw ServiceErrorMapper.map(error, operation: .pairing, hostID: id)
        }
    }

    public func cancelPairing(hostID: String) async {
        await pairingAdapter?.cancel(hostID: hostID)
    }

    public func renameHost(id: String, name: String) async throws -> StreamHost {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw UmbraServiceError.invalidInput(field: "host name", message: "must not be empty")
        }
        var host = try await storedHost(id)
        host.name = trimmed
        host.hasCustomName = true
        try await upsert(host)
        return host
    }

    public func removeHost(id: String) async throws {
        if let activeSession, activeSession.hostID == id, !activeSession.state.isTerminal {
            throw UmbraServiceError.sessionInProgress
        }
        _ = try await ensureSnapshot()
        consecutiveFailures[id] = nil
        refreshTasks[id]?.task.cancel()
        refreshTasks[id] = nil
        applicationRefreshTasks[id]?.task.cancel()
        applicationRefreshTasks[id] = nil
        do {
            let mutationGeneration = reservePersistenceMutationGeneration()
            let updated = try await persistence.update { current in
                var value = current
                guard value.hosts.contains(where: { $0.uuid == id }) else {
                    throw UmbraServiceError.hostNotFound(id)
                }
                value.hosts.removeAll { $0.uuid == id }
                return value
            }
            applyPersistedSnapshot(updated, generation: mutationGeneration)
        } catch let error as UmbraServiceError {
            throw error
        } catch {
            throw UmbraServiceError.persistence(operation: .saving, message: error.localizedDescription)
        }
    }

    public func details(hostID: String) async throws -> HostDetails {
        HostDetails(host: try await storedHost(hostID))
    }

    public func applications(
        hostID: String,
        refresh: Bool = true,
        includeHidden: Bool = false
    ) async throws -> [StreamApplication] {
        let applications: [StreamApplication]
        if refresh {
            do {
                applications = try await refreshApplicationCatalog(hostID: hostID)
            } catch {
                throw ServiceErrorMapper.map(error, operation: .applications, hostID: hostID)
            }
        } else {
            applications = try await storedHost(hostID).applications
        }
        return applications.filter { includeHidden || !$0.isHidden }
    }

    private func refreshApplicationCatalog(hostID: String) async throws -> [StreamApplication] {
        let original = try await storedHost(hostID)
        try requirePairedAndSupported(original)
        let identity = Self.refreshRequestIdentity(for: original)
        if let entry = applicationRefreshTasks[hostID],
           entry.identity == identity {
            return try await awaitSharedTaskRespectingCancellation(entry.task)
        }
        applicationRefreshTasks[hostID]?.task.cancel()
        let token = UUID()
        let task = Task { [weak self, original] () throws -> [StreamApplication] in
            guard let self else { throw CancellationError() }
            return try await self.performApplicationRefresh(original: original)
        }
        applicationRefreshTasks[hostID] = ApplicationRefreshTaskEntry(
            token: token,
            identity: identity,
            task: task
        )
        Task { [weak self] in
            _ = await task.result
            await self?.clearApplicationRefreshTask(hostID: hostID, token: token)
        }
        return try await awaitSharedTaskRespectingCancellation(task)
    }

    private func performApplicationRefresh(original host: StreamHost) async throws -> [StreamApplication] {
        let fetched = try await clientProvider.client(for: host).fetchApplications(
            address: try address(for: host, secure: true)
        )
        try Task.checkCancellation()
        var seenApplicationIDs = Set<Int>()
        let normalizedApplications: [StreamApplication] = fetched.compactMap { app in
            let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard app.id > 0,
                  !name.isEmpty,
                  seenApplicationIDs.insert(app.id).inserted else {
                return nil
            }
            return StreamApplication(
                id: app.id,
                name: name,
                hdrSupported: app.supportsHDR,
                isAppCollectorGame: app.isAppCollectorGame
            )
        }
        guard fetched.isEmpty || !normalizedApplications.isEmpty else {
            throw UmbraServiceError.protocolFailure(
                operation: .applications,
                statusCode: nil,
                message: "The host returned an invalid application catalog. The saved catalog was preserved."
            )
        }
        try Task.checkCancellation()
        return try await replaceApplicationCatalog(
            hostID: host.uuid,
            applications: normalizedApplications,
            expectedRefreshIdentity: Self.refreshRequestIdentity(for: host)
        )
    }

    private func clearApplicationRefreshTask(hostID: String, token: UUID) {
        guard applicationRefreshTasks[hostID]?.token == token else { return }
        applicationRefreshTasks[hostID] = nil
    }

    public func boxArt(hostID: String, applicationID: Int) async throws -> Data {
        let host = try await storedHost(hostID)
        try requirePairedAndSupported(host)
        guard host.applications.contains(where: { $0.id == applicationID }) else {
            throw UmbraServiceError.applicationNotFound(hostID: hostID, applicationID: applicationID)
        }
        do {
            let data = try await clientProvider.client(for: host).fetchApplicationAsset(
                address: try address(for: host, secure: true),
                appID: applicationID
            )
            guard !data.isEmpty else {
                throw UmbraServiceError.protocolFailure(
                    operation: .artwork,
                    statusCode: nil,
                    message: "The host returned empty box-art data."
                )
            }
            return data
        } catch {
            throw ServiceErrorMapper.map(error, operation: .artwork, hostID: hostID)
        }
    }

    public func setApplicationHidden(hostID: String, applicationID: Int, hidden: Bool) async throws {
        try await updateApplication(hostID: hostID, applicationID: applicationID) { $0.isHidden = hidden }
    }

    public func setDirectLaunch(hostID: String, applicationID: Int, enabled: Bool) async throws {
        try await updateApplications(hostID: hostID) { applications in
            guard applications.contains(where: { $0.id == applicationID }) else {
                throw UmbraServiceError.applicationNotFound(hostID: hostID, applicationID: applicationID)
            }
            for index in applications.indices {
                applications[index].supportsDirectLaunch = enabled && applications[index].id == applicationID
            }
        }
    }

    @discardableResult
    public func wakeHost(id: String) async throws -> StreamHost {
        let host = try await storedHost(id)
        guard host.macAddress.count == 6 else {
            throw UmbraServiceError.wakeFailed("The host did not provide a valid MAC address for Wake-on-LAN.")
        }
        let targets = WakeOnLAN.targets(
            hosts: host.uniqueAddresses.map { HostAddress(host: $0.hostname, port: $0.port) }
        )
        guard !targets.isEmpty else {
            throw UmbraServiceError.wakeFailed("The host has no saved network route for Wake-on-LAN.")
        }
        let results = await wakeSender.send(macAddress: host.macAddress, to: targets)
        guard results.values.contains(where: Self.succeeded) else {
            throw UmbraServiceError.wakeFailed("Wake-on-LAN failed on every saved network route.")
        }
        var latest = try await storedHost(id)
        latest.status = .unknown
        try await upsert(latest)
        return latest
    }

    public func currentSession() -> StreamSession? { activeSession }

    @discardableResult
    public func beginSession(_ intent: SessionIntent) async throws -> StreamSession {
        try await beginSession(intent, uiActivationUptime: nil)
    }

    @discardableResult
    public func beginSession(
        _ intent: SessionIntent,
        uiActivationUptime: TimeInterval?
    ) async throws -> StreamSession {
        guard preparingSessionID == nil,
              sessionTask == nil,
              activeSession?.state.isTerminal != false else {
            throw UmbraServiceError.sessionInProgress
        }
        guard let streamDriver else { throw UmbraServiceError.streamingUnavailable }

        let sessionID = uuidProvider.makeUUID()
        startupTelemetry.begin(
            sessionID: sessionID,
            uiActivationTime: uiActivationUptime
        )
        let session = StreamSession(
            id: sessionID,
            hostID: intent.hostID,
            applicationID: intent.applicationID,
            preferences: intent.preferences,
            state: .preparing
        )
        // Reserve the session before the first suspension. Actor methods are reentrant, so
        // publishing this preparing session is what prevents two rapid activations from both
        // passing the preflight and starting the same remote application.
        preparingSessionID = sessionID
        activeSession = session
        publish(.session(session))
        let completion = CancellableTaskWaiter<StreamSession>()
        let task = Task { [weak self, completion] in
            do {
                guard let self else { throw CancellationError() }
                let prepared = try await self.performSessionPreparation(
                    intent: intent,
                    session: session,
                    streamDriver: streamDriver
                )
                completion.resolve(.success(prepared))
            } catch {
                completion.resolve(.failure(error))
            }
        }
        sessionPreparation = SessionPreparationOperation(
            id: sessionID,
            hostID: intent.hostID,
            completion: completion,
            task: task
        )
        let service = WeakServiceReference(self)
        return try await withTaskCancellationHandler {
            try await completion.value()
        } onCancel: {
            Task { [service] in
                await service.value?.cancelSessionPreparation(sessionID: sessionID)
            }
        }
    }

    private func performSessionPreparation(
        intent: SessionIntent,
        session initialSession: StreamSession,
        streamDriver: any StreamSessionDriving
    ) async throws -> StreamSession {
        let sessionID = initialSession.id
        var session = initialSession
        var startKind: SessionStartKind = intent.kind == .launch ? .launch : .resume
        var ownership = SessionPreparationOwnership.localPreparation
        var failureStage: SessionStage?
        do {
            try await awaitSupersededSessionPreparation(hostID: intent.hostID)
            try await awaitSessionCompensation(hostID: intent.hostID)
            try ensureSessionPreparationIsActive(sessionID)
            try session.validate()
            var host = try await refreshHost(id: intent.hostID)
            try ensureSessionPreparationIsActive(sessionID)
            try requirePairedAndSupported(host)
            guard host.status == .online else {
                throw UmbraServiceError.hostUnavailable(
                    hostID: host.uuid,
                    message: "The host must be online before starting a stream."
                )
            }
            guard var application = host.applications.first(where: { $0.id == intent.applicationID }) else {
                throw UmbraServiceError.applicationNotFound(hostID: host.uuid, applicationID: intent.applicationID)
            }
            startKind = try resolvedStartKind(intent: intent, host: host)

            let credentials = try credentialProvider.makeCredentials()
            var response: LaunchResponse?
            var preparedBootstrap: StreamBootstrap?
            var successfulClient: (any GameStreamServing)?
            var successfulAddress: HostAddress?
            for attempt in 1...sessionStartAttempts {
                let client = clientProvider.client(for: host)
                let sessionAddress = try address(for: host, secure: true)
                var bootstrap = StreamBootstrap(
                    sessionID: sessionID,
                    host: host,
                    application: application,
                    preferences: intent.preferences,
                    clientRefreshRateX100: intent.clientRefreshRateX100,
                    effectivePolicy: intent.effectivePolicy,
                    rtspSessionURL: nil,
                    remoteInputCredentials: credentials
                )
                let preparation = try await streamDriver.prepare(bootstrap)
                bootstrap.preferences = preparation.applying(to: intent.preferences)
                let configuration = launchConfiguration(
                    intent: intent,
                    host: host,
                    application: application,
                    preferences: bootstrap.preferences,
                    credentials: credentials
                )
                try ensureSessionPreparationIsActive(sessionID)
                failureStage = .serverHandshake
                do {
                    startupTelemetry.record(sessionID: sessionID, stage: .hostLaunch)
                    response = try await client.startSession(
                        kind: startKind,
                        address: sessionAddress,
                        configuration: configuration
                    )
                    if startKind == .launch {
                        ownership = .launchedRemoteApplication(CancelledLaunchCompensation(
                            client: client,
                            address: sessionAddress,
                            hostID: intent.hostID,
                            applicationID: application.id
                        ))
                    }
                    try await streamDriver.waitUntilPrepared(sessionID: sessionID)
                    preparedBootstrap = bootstrap
                    successfulClient = client
                    successfulAddress = sessionAddress
                    break
                } catch {
                    guard attempt < sessionStartAttempts,
                          Self.isTransientSessionTransition(error) else {
                        throw error
                    }
                    failureStage = nil
                    try await clock.sleep(for: sessionStartRetryInterval)
                    host = try await refreshHost(id: intent.hostID)
                    try ensureSessionPreparationIsActive(sessionID)
                    try requirePairedAndSupported(host)
                    guard host.status == .online else {
                        throw UmbraServiceError.hostUnavailable(
                            hostID: host.uuid,
                            message: "The host went offline while preparing the stream."
                        )
                    }
                    guard let refreshedApplication = host.applications.first(where: { $0.id == application.id }) else {
                        throw UmbraServiceError.applicationNotFound(
                            hostID: host.uuid,
                            applicationID: application.id
                        )
                    }
                    application = refreshedApplication
                    startKind = try resolvedStartKind(intent: intent, host: host)
                }
            }
            guard let response,
                  var bootstrap = preparedBootstrap,
                  let successfulClient,
                  let successfulAddress else {
                throw UmbraServiceError.protocolFailure(
                    operation: startKind == .launch ? .launch : .resume,
                    statusCode: nil,
                    message: "The host did not start the requested stream."
                )
            }
            failureStage = nil
            if startKind == .launch, ownership.cancelledLaunchCompensation == nil {
                ownership = .launchedRemoteApplication(CancelledLaunchCompensation(
                    client: successfulClient,
                    address: successfulAddress,
                    hostID: intent.hostID,
                    applicationID: application.id
                ))
            }
            try ensureSessionPreparationIsActive(sessionID)

            host = try await storedHost(intent.hostID)
            host.currentGameID = application.id
            try await upsert(host)
            try ensureSessionPreparationIsActive(sessionID)
            session.preferences = bootstrap.preferences
            session.state = .connecting(stage: .connection)
            activeSession = session
            publish(.session(session))

            bootstrap.host = host
            bootstrap.rtspSessionURL = response.sessionURL
            let service = WeakServiceReference(self)
            sessionTask = Task { [service] in
                let (eventStream, eventContinuation) = AsyncStream.makeStream(
                    of: StreamDriverEvent.self
                )
                let eventConsumer = Task { [service] in
                    for await event in eventStream {
                        await service.value?.handleDriverEvent(event, sessionID: sessionID)
                    }
                }
                do {
                    let result = try await streamDriver.run(bootstrap) { event in
                        eventContinuation.yield(event)
                    }
                    eventContinuation.finish()
                    await eventConsumer.value
                    await service.value?.completeSession(result, sessionID: sessionID)
                } catch {
                    eventContinuation.finish()
                    await eventConsumer.value
                    await service.value?.failSession(error, sessionID: sessionID)
                }
            }
            ownership = .streamDriver
            finishSessionPreparation(sessionID: sessionID)
            return session
        } catch {
            var reportedError = error
            if let compensation = ownership.cancelledLaunchCompensation {
                let operation = scheduleCancelledLaunchCompensation(compensation)
                await streamDriver.cancel()
                let compensationResult = await awaitSessionCompensationCompletion(
                    operation,
                    hostID: compensation.hostID
                )
                if case let .failure(compensationError) = compensationResult {
                    let compensationFailure = postLaunchCompensationFailure(
                        preparationError: error,
                        compensationError: compensationError,
                        hostID: compensation.hostID
                    )
                    reportedError = compensationFailure
                    publishFailure(compensationFailure)
                }
            } else if !ownership.belongsToStreamDriver {
                await streamDriver.cancel()
            }
            finishSessionPreparation(sessionID: sessionID)
            let mapped = ServiceErrorMapper.map(
                reportedError,
                operation: startKind == .launch ? .launch : .resume,
                hostID: intent.hostID
            )
            if let current = activeSession,
               current.id == sessionID,
               !current.state.isTerminal {
                if case .stopping = current.state {
                    // stopSession owns the terminal transition for this reservation.
                } else {
                    session.state = .failed(mapped.sessionFailure(stage: failureStage))
                    activeSession = session
                    publish(.session(session))
                }
            }
            throw mapped
        }
    }

    @discardableResult
    public func stopSession(quitHostApplication: Bool) async throws -> StreamSession {
        if stopInProgress {
            guard let activeSession else { throw UmbraServiceError.sessionNotActive }
            return activeSession
        }
        guard var session = activeSession, !session.state.isTerminal else {
            throw UmbraServiceError.sessionNotActive
        }
        let wasPreparing = preparingSessionID == session.id
        let shouldQuitHostApplication = quitHostApplication && !wasPreparing
        stopInProgress = true
        defer { stopInProgress = false }
        session.state = .stopping(quitHostApplication: shouldQuitHostApplication)
        activeSession = session
        publish(.session(session))
        if wasPreparing {
            cancelSessionPreparation(sessionID: session.id)
        }

        let task = sessionTask
        sessionTask = nil
        task?.cancel()
        await streamDriver?.cancel()

        do {
            if shouldQuitHostApplication {
                _ = try await cancelAndConfirmHostApplication(
                    hostID: session.hostID,
                    applicationID: session.applicationID
                )
            }
            session.state = .finished(SessionResult(quitHostApplication: shouldQuitHostApplication))
            activeSession = session
            publish(.session(session))
            return session
        } catch {
            let mapped = ServiceErrorMapper.map(error, operation: .cancel, hostID: session.hostID)
            session.state = .failed(mapped.sessionFailure(stage: .connection))
            activeSession = session
            publish(.session(session))
            throw mapped
        }
    }

    @discardableResult
    public func cancelHostApplication(hostID: String, applicationID: Int) async throws -> StreamHost {
        let host = try await storedHost(hostID)
        try requirePairedAndSupported(host)
        guard host.currentGameID == applicationID else {
            throw UmbraServiceError.applicationNotFound(hostID: hostID, applicationID: applicationID)
        }
        do {
            return try await cancelAndConfirmHostApplication(
                hostID: hostID,
                applicationID: applicationID
            )
        } catch {
            throw ServiceErrorMapper.map(error, operation: .cancel, hostID: hostID)
        }
    }

    /// `/cancel` acknowledges receipt before the host process has necessarily stopped the app.
    /// GameStream keeps the quit operation pending until serverinfo reports no current game, so
    /// Umbra does the same instead of optimistically clearing persisted state.
    private func cancelAndConfirmHostApplication(
        hostID: String,
        applicationID: Int
    ) async throws -> StreamHost {
        let host = try await storedHost(hostID)
        let client = clientProvider.client(for: host)
        try await client.cancelSession(address: try address(for: host, secure: true))

        return try await confirmHostApplicationStopped(
            hostID: hostID,
            applicationID: applicationID
        )
    }

    private func confirmHostApplicationStopped(
        hostID: String,
        applicationID: Int
    ) async throws -> StreamHost {
        var lastFetchError: Error?
        var receivedServerInfo = false
        for attempt in 1...cancelConfirmationAttempts {
            try Task.checkCancellation()
            let latest = try await storedHost(hostID)
            switch await fetchServerInfo(for: latest) {
            case let .success((info, address)):
                receivedServerInfo = true
                let refreshed = merge(existing: latest, info: info, address: address, manualAddress: nil)
                try await upsert(refreshed)
                if refreshed.currentGameID == nil {
                    return refreshed
                }
            case let .failure(error):
                lastFetchError = error
            }

            if attempt < cancelConfirmationAttempts {
                try await clock.sleep(for: cancelConfirmationInterval)
            }
        }

        if !receivedServerInfo, let lastFetchError {
            throw ServiceErrorMapper.map(lastFetchError, operation: .cancel, hostID: hostID)
        }
        throw UmbraServiceError.protocolFailure(
            operation: .cancel,
            statusCode: 599,
            message: "The running application was not stopped. It may not have been started by this client. Quit it on the host or use the device that originally started it (requested application \(applicationID))."
        )
    }

    private func startDiscoveryIfNeeded() {
        guard discoveryEnabled, !discoveryIsRunning, let discovery else { return }
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        discoveryIsRunning = true
        discovery.start { [weak self] event in
            Task { await self?.handleDiscovery(event, generation: generation) }
        }
    }

    private func stopDiscoveryIfNeeded() {
        guard discoveryIsRunning else { return }
        discoveryIsRunning = false
        discoveryGeneration &+= 1
        discovery?.stop()
    }

    private func isCurrentDiscoveryGeneration(_ generation: UInt64) -> Bool {
        discoveryEnabled && discoveryIsRunning && discoveryGeneration == generation
    }

    private func handleDiscovery(_ event: DiscoveryEvent, generation: UInt64) async {
        guard isCurrentDiscoveryGeneration(generation) else { return }
        switch event {
        case let .added(service), let .updated(_, new: service):
            do {
                let address = try await discoveryResolver.resolve(service)
                guard isCurrentDiscoveryGeneration(generation) else { return }
                let info = try await clientProvider.client(for: nil).fetchServerInfo(
                    address: address,
                    secure: false,
                    fastFail: true
                )
                guard isCurrentDiscoveryGeneration(generation) else { return }
                let existing = try await ensureSnapshot().hosts.first { $0.uuid == info.uniqueID }
                guard isCurrentDiscoveryGeneration(generation) else { return }
                if var existing, !existing.serverCertificate.isEmpty {
                    // Bonjour proves only that a route is currently advertised. Runtime and
                    // pairing state for an already paired host must come from certificate-pinned
                    // serverinfo, never the unauthenticated discovery response.
                    let route = Self.endpoint(address)
                    existing.localAddress = route
                    existing.activeAddress = route
                    _ = try await upsert(existing)
                    guard isCurrentDiscoveryGeneration(generation) else { return }
                    _ = try await refreshHost(id: existing.uuid)
                } else {
                    let host = merge(existing: existing, info: info, address: address, manualAddress: nil)
                    consecutiveFailures[host.uuid] = 0
                    guard isCurrentDiscoveryGeneration(generation) else { return }
                    _ = try await upsert(host)
                }
            } catch {
                guard isCurrentDiscoveryGeneration(generation) else { return }
                publishFailure(ServiceErrorMapper.map(error, operation: .discovery))
            }
        case .removed:
            // Removal from mDNS is not proof that a persisted host is offline. Polling owns
            // reachability so transient Wi-Fi and Bonjour changes do not erase user state.
            break
        case let .failed(message):
            publishFailure(.discovery(message))
        }
    }

    private func fetchServerInfo(for host: StreamHost) async -> Result<(ServerInfo, HostAddress), Error> {
        var lastError: Error = UmbraServiceError.hostUnavailable(
            hostID: host.uuid,
            message: "The host has no reachable saved address."
        )
        for endpoint in host.uniqueAddresses {
            if Task.isCancelled { return .failure(CancellationError()) }
            do {
                let secure = !host.serverCertificate.isEmpty
                let address = HostAddress(
                    host: endpoint.hostname,
                    port: secure ? (host.activeHTTPSPort ?? HostAddress.defaultHTTPSPort) : endpoint.port
                )
                let info = try await clientProvider.client(for: host).fetchServerInfo(
                    address: address,
                    secure: secure,
                    fastFail: true
                )
                guard info.uniqueID == host.uuid else {
                    lastError = UmbraServiceError.protocolFailure(
                        operation: .refresh,
                        statusCode: nil,
                        message: "\(address) responded as host \(info.uniqueID), not \(host.uuid)."
                    )
                    continue
                }
                let active = HostAddress(host: address.host, port: endpoint.port)
                return .success((info, active))
            } catch {
                if error is CancellationError || Task.isCancelled {
                    return .failure(CancellationError())
                }
                lastError = error
            }
        }
        return .failure(lastError)
    }

    private func merge(
        existing: StreamHost?,
        info: ServerInfo,
        address: HostAddress,
        manualAddress: HostAddress?
    ) -> StreamHost {
        let local = info.localAddress.map { NetworkEndpoint(hostname: $0, port: address.port) }
        let remote = info.externalAddress.map {
            NetworkEndpoint(hostname: $0, port: info.externalPort ?? address.port)
        }
        let candidate = NetworkEndpoint(hostname: address.host, port: address.port)
        let isLAN = local?.hostname.caseInsensitiveCompare(address.host) == .orderedSame
            || address.host.hasSuffix(".local")
        return StreamHost(
            uuid: info.uniqueID,
            name: existing?.hasCustomName == true ? existing!.name : info.name,
            hasCustomName: existing?.hasCustomName ?? false,
            macAddress: info.macAddress ?? existing?.macAddress ?? Data(),
            localAddress: local ?? existing?.localAddress ?? (isLAN ? candidate : nil),
            remoteAddress: remote ?? existing?.remoteAddress,
            ipv6Address: existing?.ipv6Address,
            manualAddress: manualAddress.map(Self.endpoint) ?? existing?.manualAddress,
            serverCertificate: existing?.serverCertificate ?? Data(),
            applications: existing?.applications ?? [],
            isNvidiaServerSoftware: info.isNVIDIAServerSoftware,
            status: .online,
            pairState: Self.corePairState(info.pairState),
            activeAddress: candidate,
            activeHTTPSPort: info.httpsPort,
            activeAddressReachability: isLAN ? .lan : .vpn,
            currentGameID: info.currentGameID == 0 ? nil : info.currentGameID,
            gfeVersion: info.gfeVersion,
            appVersion: info.appVersion,
            displayModes: info.displayModes.map {
                UmbraCore.DisplayMode(width: $0.width, height: $0.height, refreshRate: $0.refreshRate)
            },
            maxLumaPixelsHEVC: info.maxLumaPixelsHEVC,
            codecSupport: HostCodecSupport(rawValue: UInt32(clamping: info.serverCodecModeSupport)),
            gpuModel: info.gpuModel,
            isSupportedServerVersion: compatibilityPolicy.isSupported(
                isNVIDIAServerSoftware: info.isNVIDIAServerSoftware,
                gfeVersion: info.gfeVersion
            )
        )
    }

    private func resolvedStartKind(
        intent: SessionIntent,
        host: StreamHost
    ) throws -> SessionStartKind {
        if host.currentGameID == intent.applicationID {
            return .resume
        }
        if host.currentGameID != nil {
            throw UmbraServiceError.protocolFailure(
                operation: .launch,
                statusCode: nil,
                message: "Another application is already running on the host."
            )
        }
        if intent.kind == .resume {
            throw UmbraServiceError.protocolFailure(
                operation: .resume,
                statusCode: nil,
                message: "The requested application is not the host's active session."
            )
        }
        return .launch
    }

    private func ensureSessionPreparationIsActive(_ sessionID: UUID) throws {
        try Task.checkCancellation()
        guard preparingSessionID == sessionID,
              let current = activeSession,
              current.id == sessionID else {
            throw CancellationError()
        }
        guard case .preparing = current.state else {
            throw CancellationError()
        }
    }

    private func finishSessionPreparation(sessionID: UUID) {
        if sessionPreparation?.id == sessionID {
            sessionPreparation = nil
        }
        if preparingSessionID == sessionID {
            preparingSessionID = nil
        }
    }

    private func cancelSessionPreparation(sessionID: UUID) {
        guard let operation = sessionPreparation, operation.id == sessionID else { return }
        trackSupersededSessionPreparation(
            hostID: operation.hostID,
            task: operation.task
        )
        operation.task.cancel()
        sessionPreparation = nil
        if preparingSessionID == sessionID {
            preparingSessionID = nil
        }
        if var current = activeSession,
           current.id == sessionID,
           case .preparing = current.state {
            current.state = .failed(
                UmbraServiceError.cancelled.sessionFailure()
            )
            activeSession = current
            publish(.session(current))
        }
        operation.completion.resolve(.failure(CancellationError()))
    }

    private func scheduleCancelledLaunchCompensation(
        _ compensation: CancelledLaunchCompensation
    ) -> SessionCompensationOperation {
        if let operation = sessionCompensations[compensation.hostID] {
            return operation
        }
        let service = WeakServiceReference(self)
        let token = UUID()
        let task = Task.detached(priority: .userInitiated) { [service] in
            try Task.checkCancellation()
            try await compensation.client.cancelSession(address: compensation.address)
            try Task.checkCancellation()
            _ = try await service.value?.confirmHostApplicationStopped(
                hostID: compensation.hostID,
                applicationID: compensation.applicationID
            )
        }
        let operation = SessionCompensationOperation(
            token: token,
            task: task
        )
        sessionCompensations[compensation.hostID] = operation
        Task { [weak self] in
            _ = await task.result
            await self?.clearSessionCompensation(
                hostID: compensation.hostID,
                token: token
            )
        }
        return operation
    }

    private func awaitSessionCompensationCompletion(
        _ operation: SessionCompensationOperation,
        hostID: String
    ) async -> Result<Void, Error> {
        // The preparation task may already be cancelled. Waiting on the detached task's result
        // deliberately ignores that cancellation so ownership cleanup completes before a retry.
        let result = await operation.task.result
        clearSessionCompensation(hostID: hostID, token: operation.token)
        return result
    }

    private func postLaunchCompensationFailure(
        preparationError: Error,
        compensationError: Error,
        hostID: String
    ) -> UmbraServiceError {
        let preparation = ServiceErrorMapper.map(
            preparationError,
            operation: .launch,
            hostID: hostID
        )
        let compensation = ServiceErrorMapper.map(
            compensationError,
            operation: .cancel,
            hostID: hostID
        )
        return .protocolFailure(
            operation: .cancel,
            statusCode: nil,
            message: "Session preparation failed: \(preparation.localizedDescription) "
                + "Umbra then could not stop or confirm the newly launched application: "
                + "\(compensation.localizedDescription) The application may still be running on the host."
        )
    }

    private func awaitSessionCompensation(hostID: String) async throws {
        guard let operation = sessionCompensations[hostID] else { return }
        _ = try? await awaitSharedTaskRespectingCancellation(operation.task)
        if sessionCompensations[hostID]?.token == operation.token {
            sessionCompensations[hostID] = nil
        }
        try Task.checkCancellation()
    }

    private func trackSupersededSessionPreparation(
        hostID: String,
        task: Task<Void, Never>
    ) {
        let token = UUID()
        supersededSessionPreparations[hostID, default: []].append(
            SupersededSessionPreparation(token: token, task: task)
        )
        Task { [weak self] in
            await task.value
            await self?.clearSupersededSessionPreparation(
                hostID: hostID,
                token: token
            )
        }
    }

    private func awaitSupersededSessionPreparation(hostID: String) async throws {
        let operations = supersededSessionPreparations[hostID] ?? []
        for operation in operations {
            _ = try await awaitSharedTaskRespectingCancellation(operation.task)
            clearSupersededSessionPreparation(hostID: hostID, token: operation.token)
        }
    }

    private func clearSupersededSessionPreparation(hostID: String, token: UUID) {
        guard var operations = supersededSessionPreparations[hostID] else { return }
        operations.removeAll { $0.token == token }
        supersededSessionPreparations[hostID] = operations.isEmpty ? nil : operations
    }

    private func clearSessionCompensation(hostID: String, token: UUID) {
        guard sessionCompensations[hostID]?.token == token else { return }
        sessionCompensations[hostID] = nil
    }

    private nonisolated static func isTransientSessionTransition(_ error: Error) -> Bool {
        let statusCode: Int?
        let message: String
        switch error {
        case let serviceError as UmbraServiceError:
            guard case let .protocolFailure(_, code, text) = serviceError else { return false }
            statusCode = code
            message = text
        case let networkingError as UmbraNetworkingError:
            switch networkingError {
            case let .serverResponse(code, text):
                statusCode = code
                message = text
            case let .httpStatus(code):
                statusCode = code
                message = ""
            default:
                return false
            }
        default:
            return false
        }
        if statusCode == 409 || statusCode == 423 { return true }
        let normalized = message.lowercased()
        return normalized.contains("state is changing")
            || normalized.contains("state changing")
    }

    private func launchConfiguration(
        intent: SessionIntent,
        host: StreamHost,
        application: StreamApplication,
        preferences: StreamingPreferences,
        credentials: RemoteInputCredentials
    ) -> LaunchConfiguration {
        LaunchConfiguration(
            appID: application.id,
            width: preferences.width,
            height: preferences.height,
            framesPerSecond: preferences.fps,
            remoteInputKey: credentials.key,
            remoteInputKeyID: credentials.keyID,
            optimizeGameSettings: preferences.gameOptimizations,
            playAudioOnHost: preferences.playAudioOnHost,
            surroundAudioInfo: Self.surroundAudioInfo(preferences.audioConfiguration),
            gamepadMask: intent.gamepadMask,
            persistGameControllers: intent.persistGameControllers,
            enableHDR: preferences.enableHDR,
            isNVIDIAServerSoftware: host.isNvidiaServerSoftware
        )
    }

    private func handleDriverEvent(_ event: StreamDriverEvent, sessionID: UUID) {
        guard var session = activeSession, session.id == sessionID else { return }
        guard !session.state.isTerminal else { return }
        if case .stopping = session.state { return }
        switch event {
        case let .connecting(stage):
            // Driver callbacks can originate on several native networking threads. Preserve
            // monotonic state if an earlier stage callback reaches this actor after streaming.
            if case .streaming = session.state { return }
            session.state = .connecting(stage: stage)
        case let .streaming(startedAt):
            session.state = .streaming(startedAt: startedAt)
        case let .warning(message):
            session.launchWarnings.append(message)
        }
        activeSession = session
        publish(.session(session))
    }

    private func completeSession(_ result: SessionResult, sessionID: UUID) async {
        guard var session = activeSession, session.id == sessionID else { return }
        guard !session.state.isTerminal else { return }
        if case .stopping = session.state { return }
        if result.quitHostApplication {
            do {
                _ = try await cancelHostApplication(
                    hostID: session.hostID,
                    applicationID: session.applicationID
                )
            } catch {
                failSession(error, sessionID: sessionID)
                return
            }
        }
        session.state = .finished(result)
        activeSession = session
        sessionTask = nil
        publish(.session(session))
    }

    private func failSession(_ error: Error, sessionID: UUID) {
        guard var session = activeSession, session.id == sessionID else { return }
        guard !session.state.isTerminal else { return }
        if case .stopping = session.state { return }
        let mapped = ServiceErrorMapper.map(error, operation: .streaming, hostID: session.hostID)
        session.state = .failed(mapped.sessionFailure(stage: .connection))
        activeSession = session
        sessionTask = nil
        publish(.session(session))
    }

    private func updateApplication(
        hostID: String,
        applicationID: Int,
        update: @escaping @Sendable (inout StreamApplication) -> Void
    ) async throws {
        try await updateApplications(hostID: hostID) { applications in
            guard let index = applications.firstIndex(where: { $0.id == applicationID }) else {
                throw UmbraServiceError.applicationNotFound(hostID: hostID, applicationID: applicationID)
            }
            update(&applications[index])
        }
    }

    private func updateApplications(
        hostID: String,
        update: @escaping @Sendable (inout [StreamApplication]) throws -> Void
    ) async throws {
        do {
            let mutationGeneration = reservePersistenceMutationGeneration()
            let updated = try await persistence.update { current in
                var value = current
                guard let hostIndex = value.hosts.firstIndex(where: { $0.uuid == hostID }) else {
                    throw UmbraServiceError.hostNotFound(hostID)
                }
                try update(&value.hosts[hostIndex].applications)
                return value
            }
            applyPersistedSnapshot(updated, generation: mutationGeneration)
        } catch let error as UmbraServiceError {
            throw error
        } catch {
            throw UmbraServiceError.persistence(operation: .saving, message: error.localizedDescription)
        }
    }

    private func replaceApplicationCatalog(
        hostID: String,
        applications: [StreamApplication],
        expectedRefreshIdentity: RefreshRequestIdentity
    ) async throws -> [StreamApplication] {
        do {
            let mutationGeneration = reservePersistenceMutationGeneration()
            let updated = try await persistence.update { current in
                guard !Task.isCancelled else { throw CancellationError() }
                var value = current
                guard let hostIndex = value.hosts.firstIndex(where: { $0.uuid == hostID }) else {
                    throw UmbraServiceError.hostNotFound(hostID)
                }
                guard Self.refreshRequestIdentity(for: value.hosts[hostIndex]) == expectedRefreshIdentity else {
                    throw CancellationError()
                }
                let persistedApplications = value.hosts[hostIndex].applications
                let prior = Dictionary(uniqueKeysWithValues: persistedApplications.map { ($0.id, $0) })
                value.hosts[hostIndex].applications = applications.map { application in
                    var merged = application
                    merged.isHidden = prior[application.id]?.isHidden ?? false
                    merged.supportsDirectLaunch = prior[application.id]?.supportsDirectLaunch ?? false
                    return merged
                }
                return value
            }
            applyPersistedSnapshot(updated, generation: mutationGeneration)
            guard let host = updated.hosts.first(where: { $0.uuid == hostID }) else {
                throw UmbraServiceError.hostNotFound(hostID)
            }
            return host.applications
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as UmbraServiceError {
            throw error
        } catch {
            throw UmbraServiceError.persistence(operation: .saving, message: error.localizedDescription)
        }
    }

    private func requirePairedAndSupported(_ host: StreamHost) throws {
        guard host.pairState == .paired else { throw UmbraServiceError.hostNotPaired(host.uuid) }
        guard host.isSupportedServerVersion else { throw UmbraServiceError.unsupportedServer(host.uuid) }
    }

    private func address(for host: StreamHost, secure: Bool) throws -> HostAddress {
        guard let endpoint = host.activeAddress ?? host.manualAddress ?? host.localAddress
            ?? host.remoteAddress ?? host.ipv6Address else {
            throw UmbraServiceError.hostUnavailable(
                hostID: host.uuid,
                message: "The host has no usable saved address."
            )
        }
        return HostAddress(
            host: endpoint.hostname,
            port: secure ? (host.activeHTTPSPort ?? HostAddress.defaultHTTPSPort) : endpoint.port
        )
    }

    private func ensureSnapshot() async throws -> UmbraSnapshot {
        if let snapshot { return snapshot }
        let compatibilityPolicy = self.compatibilityPolicy
        do {
            var loaded = try await persistence.load()
            if let clientIdentityFingerprint,
               loaded.clientIdentityFingerprint != clientIdentityFingerprint {
                loaded = try await persistence.update { current in
                    var updated = current
                    for index in updated.hosts.indices {
                        updated.hosts[index].serverCertificate = Data()
                        if updated.hosts[index].pairState == .paired {
                            updated.hosts[index].pairState = .notPaired
                        }
                    }
                    updated.schemaVersion = UmbraSnapshot.currentSchemaVersion
                    updated.clientIdentityFingerprint = clientIdentityFingerprint
                    return updated
                }
            }
            if loaded.hosts.contains(where: { host in
                host.isSupportedServerVersion != compatibilityPolicy.isSupported(
                    isNVIDIAServerSoftware: host.isNvidiaServerSoftware,
                    gfeVersion: host.gfeVersion
                )
            }) {
                loaded = try await persistence.update { current in
                    var updated = current
                    for index in updated.hosts.indices {
                        updated.hosts[index].isSupportedServerVersion = compatibilityPolicy.isSupported(
                            isNVIDIAServerSoftware: updated.hosts[index].isNvidiaServerSoftware,
                            gfeVersion: updated.hosts[index].gfeVersion
                        )
                    }
                    return updated
                }
            }
            snapshot = loaded
            return loaded
        } catch {
            throw UmbraServiceError.persistence(operation: .loading, message: error.localizedDescription)
        }
    }

    private func storedHost(_ id: String) async throws -> StreamHost {
        guard let host = try await ensureSnapshot().hosts.first(where: { $0.uuid == id }) else {
            throw UmbraServiceError.hostNotFound(id)
        }
        return host
    }

    private func reservePersistenceMutationGeneration() -> UInt64 {
        nextPersistenceMutationGeneration &+= 1
        return nextPersistenceMutationGeneration
    }

    private func applyPersistedSnapshot(
        _ updated: UmbraSnapshot,
        generation: UInt64
    ) {
        guard generation > appliedPersistenceMutationGeneration else { return }
        appliedPersistenceMutationGeneration = generation
        snapshot = updated
        publish(.hosts(updated.hosts.sorted(by: Self.hostOrder)))
    }

    @discardableResult
    private func upsert(
        _ host: StreamHost,
        expectedRefreshIdentity: RefreshRequestIdentity? = nil
    ) async throws -> StreamHost {
        do {
            let mutationGeneration = reservePersistenceMutationGeneration()
            let updated = try await persistence.update { current in
                if expectedRefreshIdentity != nil, Task.isCancelled {
                    throw CancellationError()
                }
                var value = current
                var mergedHost = host
                if let index = value.hosts.firstIndex(where: { $0.uuid == host.uuid }) {
                    let persisted = value.hosts[index]
                    if let expectedRefreshIdentity,
                       Self.refreshRequestIdentity(for: persisted) != expectedRefreshIdentity {
                        throw CancellationError()
                    }
                    if persisted.hasCustomName, !host.hasCustomName {
                        mergedHost.name = persisted.name
                        mergedHost.hasCustomName = true
                    }
                    if !persisted.serverCertificate.isEmpty, host.serverCertificate.isEmpty {
                        mergedHost.serverCertificate = persisted.serverCertificate
                        if persisted.pairState == .paired { mergedHost.pairState = .paired }
                    }
                    mergedHost.applications = persisted.applications
                    value.hosts[index] = mergedHost
                } else {
                    if expectedRefreshIdentity != nil {
                        throw CancellationError()
                    }
                    value.hosts.append(mergedHost)
                }
                return value
            }
            applyPersistedSnapshot(updated, generation: mutationGeneration)
            guard let committed = updated.hosts.first(where: { $0.uuid == host.uuid }) else {
                throw UmbraServiceError.hostNotFound(host.uuid)
            }
            return committed
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as UmbraServiceError {
            throw error
        } catch {
            throw UmbraServiceError.persistence(operation: .saving, message: error.localizedDescription)
        }
    }

    private func publish(_ event: HostServiceEvent) {
        eventHandler?(event)
    }

    private func publishFailure(_ error: UmbraServiceError) {
        publish(.failure(error))
    }

    private static func endpoint(_ address: HostAddress) -> NetworkEndpoint {
        NetworkEndpoint(hostname: address.host, port: address.port)
    }

    private static func refreshRequestIdentity(for host: StreamHost) -> RefreshRequestIdentity {
        RefreshRequestIdentity(
            serverCertificate: host.serverCertificate,
            addresses: host.uniqueAddresses,
            activeHTTPSPort: host.activeHTTPSPort
        )
    }

    private static func corePairState(_ state: UmbraNetworking.PairState) -> UmbraCore.PairState {
        switch state {
        case .paired: .paired
        case .notPaired: .notPaired
        case .unknown: .unknown
        }
    }

    private static func surroundAudioInfo(_ configuration: AudioConfiguration) -> UInt32 {
        switch configuration {
        case .stereo: 0x0003_0002
        case .surround51: 0x003F_0006
        case .surround71: 0x063F_0008
        }
    }

    private static func succeeded(_ result: Result<Void, Error>) -> Bool {
        if case .success = result { return true }
        return false
    }

    private static func hostOrder(_ lhs: StreamHost, _ rhs: StreamHost) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private final class WeakServiceReference: @unchecked Sendable {
    weak var value: UmbraApplicationService?

    init(_ value: UmbraApplicationService) {
        self.value = value
    }
}

private final class CancellableTaskWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            install(continuation)
        }
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private func awaitSharedTaskRespectingCancellation<Value: Sendable>(
    _ task: Task<Value, Error>
) async throws -> Value {
    let waiter = CancellableTaskWaiter<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            waiter.install(continuation)
            Task {
                waiter.resolve(await task.result)
            }
        }
    } onCancel: {
        waiter.resolve(.failure(CancellationError()))
    }
}

private func awaitSharedTaskRespectingCancellation<Value: Sendable>(
    _ task: Task<Value, Never>
) async throws -> Value {
    let waiter = CancellableTaskWaiter<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            waiter.install(continuation)
            Task {
                waiter.resolve(.success(await task.value))
            }
        }
    } onCancel: {
        waiter.resolve(.failure(CancellationError()))
    }
}
