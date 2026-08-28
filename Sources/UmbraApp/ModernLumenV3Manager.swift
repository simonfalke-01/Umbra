import Foundation
import CryptoKit
import UmbraCore
import UmbraDiagnostics
import UmbraIntegration
import UmbraMedia
import UmbraMicrophone
import UmbraNetworking
import UmbraProtocolV3
import UmbraQUICTransport
import UmbraServices

private enum ModernLumenV3ManagerError: LocalizedError {
    case startTimedOut
    case configurationTimedOut([UInt16])
    case lateStartCompensationFailed(String)
    case bulkTransferFailed(String)

    var errorDescription: String? {
        switch self {
        case .startTimedOut:
            "Secure stream START timed out after 30 seconds and was cancelled."
        case let .configurationTimedOut(types):
            "Secure stream configuration timed out before Lumen acknowledged \(Self.configurationNames(types))."
        case let .lateStartCompensationFailed(message):
            "A late START succeeded but compensating STOP failed: \(message)"
        case let .bulkTransferFailed(message):
            "Secure application artwork transfer failed: \(message)"
        }
    }

    private static func configurationNames(_ types: [UInt16]) -> String {
        types.map {
            switch $0 {
            case 0x0140: "VIDEO_CONFIG"
            case 0x0142: "AUDIO_CONFIG"
            case 0x0144: "MICROPHONE_CONFIG"
            default: String(format: "configuration 0x%04x", $0)
            }
        }.joined(separator: ", ")
    }
}

final class ProtocolV3MediaEventExecutor: @unchecked Sendable {
    typealias EventHandler = @Sendable (ProtocolV3ClientEvent) -> Void

    /// Bounds a burst to roughly one multi-megabyte fragmented key frame while
    /// leaving the downstream latency-mode reassembler responsible for dropping
    /// stale frames. The former 64-event cap could not admit one 4K frame.
    static let defaultMaximumPendingEventCount = 4_096

    private struct Submission {
        let event: ProtocolV3ClientEvent
        let terminalBarrier: Bool
        let completion: (@Sendable () -> Void)?
    }

    private enum Command {
        case submit(Submission)
        case install(EventHandler)
        case pause
        case discardBuffered
        case overflow((@Sendable () -> Void)?)
        case clear(@Sendable () -> Void)
    }

    private let queue = DispatchQueue(
        label: "app.umbra.protocol-v3.media-events",
        qos: .userInteractive
    )
    private let admissionLock = NSLock()
    private let maximumPendingEventCount: Int
    private var commands: [Command] = []
    private var pendingEventCount = 0
    private var drainScheduled = false
    private var admissionFailedClosed = false

    // The remaining state is confined to queue.
    private var handler: EventHandler?
    private var buffered: [Submission] = []
    private var paused = true
    private var failedClosed = false

    init(maximumPendingEventCount: Int = defaultMaximumPendingEventCount) {
        precondition(maximumPendingEventCount > 0)
        self.maximumPendingEventCount = maximumPendingEventCount
    }

    func submit(
        _ event: ProtocolV3ClientEvent,
        terminalBarrier: Bool,
        overflowHandler: (@Sendable () -> Void)? = nil,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let submission = Submission(
            event: event,
            terminalBarrier: terminalBarrier,
            completion: completion
        )
        enqueueEvent(submission, overflowHandler: overflowHandler)
    }

    func installAndResume(_ coordinator: ProtocolV3SessionMediaCoordinator) {
        installAndResume { [coordinator] event in
            coordinator.handle(event)
        }
    }

    func installAndResume(_ handler: @escaping EventHandler) {
        enqueue(.install(handler))
    }

    func pause() {
        enqueue(.pause)
    }

    func discardBuffered() {
        enqueue(.discardBuffered)
    }

    func clearAndWait() async {
        await withCheckedContinuation { continuation in
            enqueue(.clear {
                continuation.resume()
            })
        }
    }

    private func enqueueEvent(
        _ submission: Submission,
        overflowHandler: (@Sendable () -> Void)?
    ) {
        var shouldScheduleDrain = false
        admissionLock.withLock {
            guard !admissionFailedClosed else { return }
            guard pendingEventCount < maximumPendingEventCount else {
                admissionFailedClosed = true
                commands.append(.overflow(overflowHandler))
                if !drainScheduled {
                    drainScheduled = true
                    shouldScheduleDrain = true
                }
                return
            }
            pendingEventCount += 1
            commands.append(.submit(submission))
            if !drainScheduled {
                drainScheduled = true
                shouldScheduleDrain = true
            }
        }
        scheduleDrainIfNeeded(shouldScheduleDrain)
    }

    private func enqueue(_ command: Command) {
        var shouldScheduleDrain = false
        admissionLock.withLock {
            commands.append(command)
            if !drainScheduled {
                drainScheduled = true
                shouldScheduleDrain = true
            }
        }
        scheduleDrainIfNeeded(shouldScheduleDrain)
    }

    private func scheduleDrainIfNeeded(_ shouldSchedule: Bool) {
        guard shouldSchedule else { return }
        queue.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        while let batch = takeNextBatch() {
            for command in batch {
                execute(command)
            }
        }
    }

    private func takeNextBatch() -> [Command]? {
        admissionLock.withLock {
            guard !commands.isEmpty else {
                drainScheduled = false
                return nil
            }
            let batch = commands
            commands.removeAll(keepingCapacity: true)
            return batch
        }
    }

    private func execute(_ command: Command) {
        switch command {
        case let .submit(submission):
            execute(submission)
        case let .install(handler):
            self.handler = handler
            guard !failedClosed else { return }
            paused = false
            let pending = buffered
            buffered.removeAll(keepingCapacity: true)
            for submission in pending {
                handler(submission.event)
                submission.completion?()
                eventFinished()
            }
        case .pause:
            paused = true
        case .discardBuffered:
            discardBufferedOnQueue()
        case let .overflow(overflowHandler):
            failedClosed = true
            paused = true
            discardBufferedOnQueue()
            overflowHandler?()
        case let .clear(completion):
            paused = true
            failedClosed = false
            discardBufferedOnQueue()
            handler = nil
            admissionLock.withLock { admissionFailedClosed = false }
            completion()
        }
    }

    private func execute(_ submission: Submission) {
        guard !failedClosed else {
            eventFinished()
            return
        }
        guard !paused, let handler else {
            if submission.terminalBarrier {
                paused = true
                submission.completion?()
                eventFinished()
            } else {
                buffered.append(submission)
            }
            return
        }
        handler(submission.event)
        if submission.terminalBarrier { paused = true }
        submission.completion?()
        eventFinished()
    }

    private func discardBufferedOnQueue() {
        let discardedCount = buffered.count
        buffered.removeAll(keepingCapacity: true)
        guard discardedCount > 0 else { return }
        admissionLock.withLock {
            pendingEventCount -= discardedCount
        }
    }

    private func eventFinished() {
        admissionLock.withLock {
            pendingEventCount -= 1
        }
    }
}

enum ProtocolV3ControlKeepalivePolicy {
    static let interval: Duration = .seconds(45)
    static let responseTimeout: Duration = .seconds(5)

    static func requestFields(
        clientSendNanoseconds: UInt64,
        probe: UInt64
    ) -> [UInt64: ProtocolV3CBORValue] {
        [1: .unsigned(clientSendNanoseconds), 2: .unsigned(probe)]
    }

    static func acceptsResponse(
        _ fields: [UInt64: ProtocolV3CBORValue],
        clientSendNanoseconds: UInt64,
        probe: UInt64
    ) -> Bool {
        guard Set(fields.keys) == Set(1...4),
              fields[1]?.unsignedValue == clientSendNanoseconds,
              fields[2]?.unsignedValue == probe,
              let hostReceiveNanoseconds = fields[3]?.unsignedValue,
              hostReceiveNanoseconds > 0,
              let hostSendNanoseconds = fields[4]?.unsignedValue,
              hostSendNanoseconds >= hostReceiveNanoseconds else {
            return false
        }
        return true
    }
}

@MainActor
final class ModernLumenV3Manager {
    typealias PairedSessionFactory = @MainActor (
        _ trust: ProtocolV3TrustRecord,
        _ identity: ProtocolV3ClientIdentity,
        _ host: String,
        _ port: UInt16,
        _ hostnameIsIPLiteral: Bool,
        _ mode: QUICOptimizationMode
    ) throws -> ProtocolV3ClientControlSession

    struct RecoveryPhaseTimeouts: Sendable {
        let authentication: Duration
        let activeSessionAnnouncement: Duration
        let attachResponse: Duration
        let inputResetResponse: Duration

        static let wireContract = Self(
            authentication: .seconds(5),
            activeSessionAnnouncement: .seconds(2),
            attachResponse: .seconds(3),
            inputResetResponse: .seconds(2)
        )
    }

    private enum Permission {
        static let browse: UInt64 = 1 << 0
        static let start: UInt64 = 1 << 1
        static let input: UInt64 = 1 << 2
        static let microphone: UInt64 = 1 << 3
        static let stopOwnStream: UInt64 = 1 << 4
        static let quitApplication: UInt64 = 1 << 5
        static let requiredBase: UInt64 = browse | start | input | stopOwnStream
    }
    private struct ControlResponse: Sendable {
        let type: UInt16
        let requestID: UInt64
        let fields: [UInt64: ProtocolV3CBORValue]
    }

    private struct ManagerEventEnvelope: Sendable {
        let event: ProtocolV3ClientEvent
        let session: ProtocolV3ClientControlSession
    }

    private struct PendingControlResponse {
        let expectedType: UInt16
        let continuation: AsyncStream<Result<ControlResponse, ProtocolV3ClientError>>.Continuation
    }

    private struct StartResult: Sendable {
        let sessionID: Data
        let fields: [UInt64: ProtocolV3CBORValue]
    }

    private struct PreparedStream {
        var bootstrap: StreamBootstrap
        let offer: ProtocolV3StartOffer
        let pipeline: StreamingMediaPipeline
        let microphoneCapture: (any ClientMicrophoneCapturing)?
    }

    private struct AttachState {
        let sessionID: Data
        let attachToken: Data
        let startIntentID: Data
        let videoGeneration: UInt32
        let audioGeneration: UInt32
        let microphoneGeneration: UInt32
        let inputGeneration: UInt32
    }

    private struct BulkMetadata: Equatable, Sendable {
        let applicationID: Int
        let sha256: Data
        let mimeType: String
        let kind: UInt8
        let payloadLength: UInt64
        let objectID: UInt64
    }

    private struct PendingBulkObject {
        let metadata: BulkMetadata
        let continuation: AsyncStream<Result<Data, ModernLumenV3ManagerError>>.Continuation
    }

    private struct ConfigurationBinding: Equatable, Sendable {
        let sessionID: Data
        let generation: UInt32
    }

    private final class ConfigurationBarrierState: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [UInt16: ConfigurationBinding]

        init(required: [UInt16: ConfigurationBinding]) {
            pending = required
        }

        func acknowledge(_ acknowledgement: ProtocolV3ConfigurationAcknowledgement) -> Bool {
            lock.withLock {
                let binding = ConfigurationBinding(
                    sessionID: acknowledgement.sessionID,
                    generation: acknowledgement.generation
                )
                guard pending[acknowledgement.type] == binding else { return false }
                pending[acknowledgement.type] = nil
                return pending.isEmpty
            }
        }

        var remaining: Set<UInt16> { lock.withLock { Set(pending.keys) } }
    }

    private final class InputSenderRelay: @unchecked Sendable {
        private let lock = NSLock()
        private weak var sender: ProtocolV3InputStateSender?

        func install(_ sender: ProtocolV3InputStateSender?) {
            lock.withLock { self.sender = sender }
        }

        func acknowledge(_ edgeID: UInt64) {
            lock.withLock { sender }?.acknowledge(appliedEdgeID: edgeID)
        }

        func resynchronize(_ edgeID: UInt64) {
            try? lock.withLock { sender }?.resynchronize(expectedEdgeID: edgeID)
        }

        func accepts(_ feedback: ProtocolV3ControllerFeedback) -> Bool {
            lock.withLock { sender }?.acceptsControllerFeedback(
                inputGeneration: feedback.inputGeneration,
                controller: feedback.controller,
                controllerGeneration: feedback.controllerGeneration
            ) ?? false
        }

        func updateMaximumPayloadByteCount(_ byteCount: Int) {
            lock.withLock { sender }?.updateMaximumPayloadByteCount(byteCount)
        }
    }

    private final class ActivationTaskRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func install(_ task: Task<Void, Never>?) {
            lock.withLock { self.task = task }
        }

        func cancel() {
            lock.withLock { task }?.cancel()
        }
    }

    private final class RetainedSession {
        var session: ProtocolV3ClientControlSession
        let terminalEvents: AsyncStream<Void>
        let terminalContinuation: AsyncStream<Void>.Continuation
        var authenticationEvents: AsyncStream<Result<Void, ProtocolV3ClientError>>
        var authenticationContinuation: AsyncStream<Result<Void, ProtocolV3ClientError>>.Continuation
        var activeSessionEvents: AsyncStream<Data>
        var activeSessionContinuation: AsyncStream<Data>.Continuation
        var sessionEndedEvents: AsyncStream<Data>
        var sessionEndedContinuation: AsyncStream<Data>.Continuation
        var isAuthenticated = false
        var serverCapabilities: UInt64 = 0
        var inputDatagramPayloadByteCount = 0
        var invitationRecord: ModernLumenV3HostRecord?
        var pairingInvitationID: Data?
        let pairingEvents: AsyncStream<Result<HostDisplayModel, Error>>
        let pairingContinuation: AsyncStream<Result<HostDisplayModel, Error>>.Continuation
        var pendingControlResponses: [UInt64: PendingControlResponse] = [:]
        var activeSessionID: Data?
        var startEvents: AsyncStream<Result<StartResult, Error>>
        var startContinuation: AsyncStream<Result<StartResult, Error>>.Continuation
        var preparedStream: PreparedStream?
        var mediaCoordinator: ProtocolV3SessionMediaCoordinator?
        var inputSender: ProtocolV3InputStateSender?
        var inputLatencyTracker: ProtocolV3InputLatencyTracker?
        var launchAttemptActive = false
        var lifecyclePrepared = false
        var stopTask: Task<Void, Error>?
        var activeStartRequestID: UInt64?
        var cancelledStartOffers: [UInt64: ProtocolV3StartOffer] = [:]
        var attachState: AttachState?
        var isRecovering = false
        var teardownTask: Task<Void, Never>?
        let inputSenderRelay = InputSenderRelay()
        let activationTaskRelay = ActivationTaskRelay()
        var bulkHeaders: [UInt64: QUICInboundBulkHeader] = [:]
        var pendingBulkObjects: [UInt64: PendingBulkObject] = [:]
        var rejectedBulkRequestIDs = Set<UInt64>()
        var statisticsTask: Task<Void, Never>?
        var controlKeepaliveTask: Task<Void, Never>?
        var controlKeepaliveProbe: UInt64 = 0
        let mediaEventExecutor = ProtocolV3MediaEventExecutor()
        let configurationAcknowledgements: AsyncStream<ProtocolV3ConfigurationOutcome>
        let configurationAcknowledgementContinuation:
            AsyncStream<ProtocolV3ConfigurationOutcome>.Continuation
        let managerEvents: AsyncStream<ManagerEventEnvelope>
        let managerEventContinuation: AsyncStream<ManagerEventEnvelope>.Continuation
        var managerEventTask: Task<Void, Never>?

        init(
            session: ProtocolV3ClientControlSession,
            invitationRecord: ModernLumenV3HostRecord?,
            pairingInvitationID: Data? = nil
        ) {
            self.session = session
            self.invitationRecord = invitationRecord
            self.pairingInvitationID = pairingInvitationID
            (terminalEvents, terminalContinuation) = AsyncStream<Void>.makeStream()
            (authenticationEvents, authenticationContinuation) = AsyncStream<
                Result<Void, ProtocolV3ClientError>
            >.makeStream()
            (activeSessionEvents, activeSessionContinuation) = AsyncStream<Data>.makeStream()
            (sessionEndedEvents, sessionEndedContinuation) = AsyncStream<Data>.makeStream()
            (startEvents, startContinuation) = AsyncStream<Result<StartResult, Error>>.makeStream()
            (pairingEvents, pairingContinuation) = AsyncStream<Result<HostDisplayModel, Error>>.makeStream()
            (configurationAcknowledgements, configurationAcknowledgementContinuation) =
                AsyncStream<ProtocolV3ConfigurationOutcome>.makeStream()
            (managerEvents, managerEventContinuation) = AsyncStream<ManagerEventEnvelope>.makeStream()
        }

        func resetAuthenticationEvents() {
            authenticationContinuation.finish()
            activeSessionContinuation.finish()
            (authenticationEvents, authenticationContinuation) = AsyncStream<
                Result<Void, ProtocolV3ClientError>
            >.makeStream()
            (activeSessionEvents, activeSessionContinuation) = AsyncStream<Data>.makeStream()
            isAuthenticated = false
        }

        func resetStartEvents() {
            startContinuation.finish()
            (startEvents, startContinuation) = AsyncStream<Result<StartResult, Error>>.makeStream()
        }

        func resetSessionEndedEvents() {
            sessionEndedContinuation.finish()
            (sessionEndedEvents, sessionEndedContinuation) = AsyncStream<Data>.makeStream()
        }
    }

    private let trustStore: FileBackedProtocolV3TrustStore
    private let hostCatalog: FileBackedModernLumenV3HostCatalog
    nonisolated private let discovery: any ProtocolV3Discovering
    private let log: SupportLog?
    private let mediaCapabilities: AppleStreamingCapabilities?
    private let mediaProvider: (any StreamingMediaProviding)?
    private let output: (any StreamingEventOutputHandling)?
    private let motionPolicy: ControllerMotionPolicy?
    private weak var inputInstaller: (any PlatformInputSinkInstalling)?
    private let lifecycle: (any StreamSessionLifecycleCoordinating)?
    private let microphoneAuthorization: any ClientMicrophoneAuthorizing
    private let microphoneCaptureFactory: any ClientMicrophoneCaptureCreating
    private let startupTelemetry: SessionStartupTelemetryRecorder
    private let pairedSessionFactory: PairedSessionFactory
    private let configurationBarrierTimeout: Duration
    private let recoveryPhaseTimeouts: RecoveryPhaseTimeouts
    private var sessions: [Data: RetainedSession] = [:]
    private var connectionStatuses: [Data: HostConnectionStatus] = [:]
    private var catalogEventHandler: (@MainActor @Sendable ([HostDisplayModel]) -> Void)?
    private var sessionEventHandler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?

    init(
        trustStore: FileBackedProtocolV3TrustStore = .init(),
        hostCatalog: FileBackedModernLumenV3HostCatalog = .init(),
        discovery: any ProtocolV3Discovering = NetworkProtocolV3Discovery(),
        mediaCapabilities: AppleStreamingCapabilities? = nil,
        mediaProvider: (any StreamingMediaProviding)? = nil,
        output: (any StreamingEventOutputHandling)? = nil,
        motionPolicy: ControllerMotionPolicy? = nil,
        inputInstaller: (any PlatformInputSinkInstalling)? = nil,
        lifecycle: (any StreamSessionLifecycleCoordinating)? = nil,
        microphoneAuthorization: any ClientMicrophoneAuthorizing = SystemClientMicrophoneAuthorization(),
        microphoneCaptureFactory: any ClientMicrophoneCaptureCreating = AudioQueueMicrophoneCaptureFactory(),
        startupTelemetry: SessionStartupTelemetryRecorder = SessionStartupTelemetryRecorder(),
        pairedSessionFactory: PairedSessionFactory? = nil,
        configurationBarrierTimeout: Duration = .seconds(3),
        recoveryPhaseTimeouts: RecoveryPhaseTimeouts = .wireContract,
        log: SupportLog?
    ) {
        self.trustStore = trustStore
        self.hostCatalog = hostCatalog
        self.discovery = discovery
        self.mediaCapabilities = mediaCapabilities
        self.mediaProvider = mediaProvider
        self.output = output
        self.motionPolicy = motionPolicy
        self.inputInstaller = inputInstaller
        self.lifecycle = lifecycle
        self.microphoneAuthorization = microphoneAuthorization
        self.microphoneCaptureFactory = microphoneCaptureFactory
        self.startupTelemetry = startupTelemetry
        self.pairedSessionFactory = pairedSessionFactory ?? Self.makePairedSession
        self.configurationBarrierTimeout = configurationBarrierTimeout
        self.recoveryPhaseTimeouts = recoveryPhaseTimeouts
        self.log = log
    }

    func setCatalogEventHandler(
        _ handler: (@MainActor @Sendable ([HostDisplayModel]) -> Void)?
    ) {
        catalogEventHandler = handler
    }

    func startDiscovery() {
        discovery.start { [weak self] event in
            Task { @MainActor in
                self?.handleDiscovery(event)
            }
        }
    }

    nonisolated func stopDiscovery() {
        discovery.stop()
    }

    func setSessionEventHandler(
        _ handler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?
    ) {
        sessionEventHandler = handler
    }

    func displayHosts() throws -> [HostDisplayModel] {
        try reconcilePersistedHosts()
        return try hostCatalog.allHosts().map { record in
            guard let trust = try trustStore.trust(hostID: record.hostID) else {
                throw ProtocolV3ClientError.authenticationFailed
            }
            return displayHost(record, trust: trust)
        }
    }

    func owns(_ hostID: HostID) -> Bool {
        Self.protocolHostID(from: hostID) != nil
    }

    static func requestedPermissions(for preferences: StreamingPreferences) -> UInt64 {
        var permissions = Permission.requiredBase
        if preferences.clientMicrophoneEnabled { permissions |= Permission.microphone }
        if preferences.quitAppAfter { permissions |= Permission.quitApplication }
        return permissions
    }

    func renameHost(id: HostID, name: String) throws -> HostDisplayModel {
        let hostID = try requireProtocolHostID(id)
        var record = try requireHostRecord(hostID)
        record.displayName = name
        try hostCatalog.upsert(record)
        publishCatalog()
        return displayHost(record, trust: try trustStore.trust(hostID: hostID))
    }

    func removeHost(id: HostID) throws {
        let hostID = try requireProtocolHostID(id)
        sessions[hostID]?.session.cancel()
        try trustStore.removeTrust(hostID: hostID)
        try hostCatalog.remove(hostID: hostID)
        connectionStatuses[hostID] = nil
        publishCatalog()
    }

    func applications(hostID: HostID) throws -> [ApplicationDisplayModel] {
        let protocolHostID = try requireProtocolHostID(hostID)
        let record = try requireHostRecord(protocolHostID)
        return record.applications.map {
            ApplicationDisplayModel(
                id: ApplicationID($0.id),
                hostID: hostID,
                name: $0.name,
                artworkURL: nil,
                isRunning: record.runningApplicationID == $0.id,
                isHidden: $0.isHidden,
                isDirectLaunch: $0.isDirectLaunch
            )
        }
    }

    func artworkHashes(hostID: HostID) throws -> [Int: Data] {
        let protocolHostID = try requireProtocolHostID(hostID)
        return Dictionary(uniqueKeysWithValues: try requireHostRecord(protocolHostID)
            .applications.compactMap { application in
                application.artworkSHA256.map { (application.id, $0) }
            })
    }

    func pairInvitation(
        _ uri: String,
        requestedPermissions: UInt64
    ) async throws -> HostDisplayModel {
        let started = try startInvitation(uri, requestedPermissions: requestedPermissions)
        let hostID = started.hostID
        let session = started.session
        let pairingEvents = started.entry.pairingEvents
        return try await withTaskCancellationHandler {
            for await result in pairingEvents {
                try Task.checkCancellation()
                return try result.get()
            }
            try Task.checkCancellation()
            throw ProtocolV3ClientError.invalidState
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelInvitationPairing(
                    session: session,
                    hostID: hostID
                )
            }
        }
    }

    private func startInvitation(
        _ uri: String,
        requestedPermissions: UInt64
    ) throws -> (hostID: Data, session: ProtocolV3ClientControlSession, entry: RetainedSession) {
        let invitation = try ProtocolV3PairingInvitation.decode(
            uri: uri,
            nowUnixSeconds: UInt64(Date().timeIntervalSince1970)
        )
        let abandonedPairings = sessions.filter { $0.value.pairingInvitationID != nil }
        for (hostID, entry) in abandonedPairings {
            entry.pairingContinuation.yield(.failure(CancellationError()))
            entry.pairingContinuation.finish()
            if let pairingInvitationID = entry.pairingInvitationID {
                try? trustStore.cancelPairingAttempt(invitationID: pairingInvitationID)
            }
            entry.session.cancel()
            entry.authenticationContinuation.finish()
            entry.activeSessionContinuation.finish()
            entry.startContinuation.finish()
            sessions[hostID] = nil
        }
        let identity = try trustStore.identity()
        let attempt = try trustStore.beginPairing(
            invitation: invitation,
            requestedPermissions: requestedPermissions,
            displayName: Host.current().localizedName ?? "Umbra"
        )
        let configuration = QUICTransportConfiguration(
            endpoint: .init(host: invitation.hostname, port: invitation.port),
            expectedLeafSPKISHA256: invitation.tlsSPKIHash,
            serverName: invitation.hostnameIsIPLiteral ? nil : invitation.hostname,
            mode: .quality
        )
        let transport = try NetworkQUICTransport(configuration: configuration)
        let session = ProtocolV3ClientControlSession(
            transport: transport,
            identity: identity,
            mode: .invitation(
                invitation,
                requestedPermissions: attempt.requestedPermissions,
                displayName: attempt.displayName,
                pairAttemptID: attempt.attemptID
            ),
            trustPersistence: trustStore
        )
        let invitationRecord = ModernLumenV3HostRecord(
            hostID: invitation.hostID,
            hostname: invitation.hostname,
            hostnameIsIPLiteral: invitation.hostnameIsIPLiteral,
            port: invitation.port,
            displayName: invitation.hostname,
            applications: [],
            applicationRevision: nil,
            runningApplicationID: nil
        )
        retain(
            session,
            hostID: invitation.hostID,
            invitationRecord: invitationRecord,
            pairingInvitationID: invitation.invitationID
        )
        do {
            try session.start()
        } catch {
            try? trustStore.cancelPairingAttempt(invitationID: invitation.invitationID)
            finish(session: session, hostID: invitation.hostID)
            throw error
        }
        guard let entry = sessions[invitation.hostID], entry.session === session else {
            session.cancel()
            throw ProtocolV3ClientError.invalidState
        }
        return (invitation.hostID, session, entry)
    }

    func connectPaired(
        hostID: Data,
        host: String,
        port: UInt16,
        hostnameIsIPLiteral: Bool,
        mode: QUICOptimizationMode
    ) throws -> ProtocolV3ClientControlSession {
        guard let trust = try trustStore.trust(hostID: hostID) else {
            throw ProtocolV3ClientError.authenticationFailed
        }
        let identity = try trustStore.identity()
        guard trust.clientID == identity.clientID else {
            throw ProtocolV3ClientError.authenticationFailed
        }
        let session = try pairedSessionFactory(
            trust,
            identity,
            host,
            port,
            hostnameIsIPLiteral,
            mode
        )
        retain(session, hostID: hostID)
        do {
            try session.start()
        } catch {
            finish(session: session, hostID: hostID)
            throw error
        }
        return session
    }

    func reconnect(hostID: HostID, mode: QUICOptimizationMode) async throws -> ProtocolV3ClientControlSession {
        let protocolHostID = try requireProtocolHostID(hostID)
        if let entry = sessions[protocolHostID], entry.isAuthenticated {
            return entry.session
        }
        let record = try requireHostRecord(protocolHostID)
        let session = try connectPaired(
            hostID: protocolHostID,
            host: record.hostname,
            port: record.port,
            hostnameIsIPLiteral: record.hostnameIsIPLiteral == true,
            mode: mode
        )
        try await waitForAuthentication(hostID: protocolHostID, session: session)
        return session
    }

    func refreshApplications(
        hostID: HostID,
        mode: QUICOptimizationMode
    ) async throws -> [ApplicationDisplayModel] {
        let protocolHostID = try requireProtocolHostID(hostID)
        try requirePermission(hostID: protocolHostID, permission: Permission.browse, feature: "application browsing")
        let session = try await reconnect(hostID: hostID, mode: mode)
        guard let entry = sessions[protocolHostID], entry.session === session else {
            throw ProtocolV3ClientError.invalidState
        }
        var record = try requireHostRecord(protocolHostID)
        var cursor: UInt64 = 0
        var revision: UInt64?
        var applicationRecords: [ModernLumenV3ApplicationRecord] = []
        var paginationRestarts = 0
        while true {
            var request: [UInt64: ProtocolV3CBORValue] = [
                1: .unsigned(cursor),
                2: .unsigned(128),
            ]
            if cursor == 0, let knownRevision = record.applicationRevision {
                request[3] = .unsigned(knownRevision)
            } else if cursor != 0, let revision {
                request[3] = .unsigned(revision)
            }
            let response = try await requestControl(
                entry: entry,
                requestType: 0x0200,
                responseType: 0x0201,
                fields: request
            )
            let page = try Self.decodeApplicationPage(response.fields)
            if page.status == 8, cursor != 0, paginationRestarts == 0 {
                paginationRestarts += 1
                cursor = 0
                revision = nil
                applicationRecords.removeAll(keepingCapacity: true)
                continue
            }
            guard page.status == 0 else {
                throw ProtocolV3ClientError.invalidMessage("application-list status")
            }
            if page.notModified {
                guard cursor == 0,
                      record.applicationRevision == page.revision,
                      page.applications.isEmpty,
                      page.nextCursor == nil,
                      record.applications.filter(\.isRunning).count <= 1,
                      zip(record.applications, record.applications.dropFirst()).allSatisfy({
                          $0.id < $1.id
                      }) else {
                    throw ProtocolV3ClientError.invalidMessage("application-list revalidation")
                }
                return try applications(hostID: hostID)
            }
            if cursor == 0 {
                revision = page.revision
            } else if revision != page.revision {
                throw ProtocolV3ClientError.invalidMessage("application-list revision")
            }
            guard page.applications.count <= 128,
                  page.nextCursor == nil || page.applications.count == 128,
                  applicationRecords.count + page.applications.count <= 4_096,
                  applicationRecords.last.map({ last in
                      page.applications.first.map { last.id < $0.id } ?? true
                  }) ?? true else {
                throw ProtocolV3ClientError.invalidMessage("application-list pagination")
            }
            applicationRecords.append(contentsOf: page.applications)
            guard applicationRecords.filter(\.isRunning).count <= 1 else {
                throw ProtocolV3ClientError.invalidMessage("application-list running state")
            }
            if let nextCursor = page.nextCursor {
                guard nextCursor == cursor + UInt64(page.applications.count) else {
                    throw ProtocolV3ClientError.invalidMessage("application-list cursor")
                }
                cursor = nextCursor
            } else {
                break
            }
        }

        let localPreferences = Dictionary(uniqueKeysWithValues: record.applications.map {
            ($0.id, ($0.isHidden, $0.isDirectLaunch))
        })
        for index in applicationRecords.indices {
            if let local = localPreferences[applicationRecords[index].id] {
                applicationRecords[index].isHidden = local.0
                applicationRecords[index].isDirectLaunch = local.1
            }
        }
        record.applications = applicationRecords
        record.applicationRevision = revision
        record.runningApplicationID = applicationRecords.first(where: { $0.isRunning })?.id
        try hostCatalog.upsert(record)
        publishCatalog()
        return try self.applications(hostID: hostID)
    }

    func applicationArtwork(
        hostID: HostID,
        applicationID: ApplicationID,
        mode: QUICOptimizationMode
    ) async throws -> Data {
        let protocolHostID = try requireProtocolHostID(hostID)
        try requirePermission(hostID: protocolHostID, permission: Permission.browse, feature: "application artwork")
        let session = try await reconnect(hostID: hostID, mode: mode)
        guard let entry = sessions[protocolHostID], entry.session === session else {
            throw ProtocolV3ClientError.invalidState
        }
        let record = try requireHostRecord(protocolHostID)
        guard let expectedHash = record.applications.first(where: {
            $0.id == applicationID.rawValue
        })?.artworkSHA256 else {
            throw UmbraClientServiceError.unavailable("This application has no artwork asset.")
        }
        let response = try await requestControl(
            entry: entry,
            requestType: 0x0202,
            responseType: 0x0203,
            fields: [
                1: .unsigned(UInt64(applicationID.rawValue)),
                2: .bytes(expectedHash),
                3: .unsigned(0),
                4: .unsigned(UInt64(16 * 1_048_576)),
            ]
        )
        guard Set(response.fields.keys) == Set(1...7),
              response.fields[1]?.unsignedValue == 0,
              response.fields[2]?.unsignedValue == UInt64(applicationID.rawValue),
              response.fields[3]?.bytesValue == expectedHash,
              let mimeType = response.fields[4]?.textValue,
              mimeType == "image/png" || mimeType == "image/jpeg",
              response.fields[5]?.unsignedValue == 1,
              let payloadLength = response.fields[6]?.unsignedValue,
              payloadLength <= UInt64(16 * 1_048_576),
              let objectID = response.fields[7]?.unsignedValue,
              objectID != 0 else {
            rejectBulkHeaderIfPresent(entry: entry, requestID: response.requestID)
            throw ProtocolV3ClientError.invalidMessage("application asset metadata")
        }
        let metadata = BulkMetadata(
            applicationID: applicationID.rawValue,
            sha256: expectedHash,
            mimeType: mimeType,
            kind: 1,
            payloadLength: payloadLength,
            objectID: objectID
        )
        let data = try await awaitBulkObject(
            entry: entry,
            requestID: response.requestID,
            metadata: metadata
        )
        guard UInt64(data.count) == payloadLength,
              Data(SHA256.hash(data: data)) == expectedHash else {
            throw ModernLumenV3ManagerError.bulkTransferFailed("final asset binding mismatch")
        }
        return data
    }

    func setApplicationHidden(id: ApplicationID, hostID: HostID, hidden: Bool) throws {
        let protocolHostID = try requireProtocolHostID(hostID)
        var record = try requireHostRecord(protocolHostID)
        guard let index = record.applications.firstIndex(where: { $0.id == id.rawValue }) else {
            throw UmbraClientServiceError.invalidInput("The selected application is unavailable.")
        }
        record.applications[index].isHidden = hidden
        try hostCatalog.upsert(record)
    }

    func setDirectLaunch(id: ApplicationID, hostID: HostID, enabled: Bool) throws {
        let protocolHostID = try requireProtocolHostID(hostID)
        var record = try requireHostRecord(protocolHostID)
        guard record.applications.contains(where: { $0.id == id.rawValue }) else {
            throw UmbraClientServiceError.invalidInput("The selected application is unavailable.")
        }
        for index in record.applications.indices {
            record.applications[index].isDirectLaunch = enabled
                && record.applications[index].id == id.rawValue
        }
        try hostCatalog.upsert(record)
    }

    func launchApplication(
        id: ApplicationID,
        hostID: HostID,
        resume: Bool,
        preferences: StreamingPreferences,
        activationUptime: TimeInterval
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        let backoffMilliseconds = [500, 1_500]
        for attempt in 0...backoffMilliseconds.count {
            do {
                try await launchApplicationAttempt(
                    id: id,
                    hostID: hostID,
                    resume: resume,
                    preferences: preferences,
                    activationUptime: activationUptime
                )
                return
            } catch {
                guard Self.isTransientStartConflict(error), attempt < backoffMilliseconds.count else {
                    throw error
                }
                let delayMilliseconds = backoffMilliseconds[attempt]
                let backoff = Duration.milliseconds(delayMilliseconds)
                guard ContinuousClock.now.advanced(by: backoff) <= deadline else {
                    throw error
                }
                log?.record(
                    source: "Lumen v3",
                    level: .warning,
                    message: "START hit a transient lifecycle conflict; retrying in "
                        + "\(delayMilliseconds) ms "
                        + "(attempt \(attempt + 2) of \(backoffMilliseconds.count + 1))."
                )
                try await Task.sleep(for: backoff)
            }
        }
    }

    private static func isTransientStartConflict(_ error: Error) -> Bool {
        guard let error = error as? ProtocolV3ClientError else { return false }
        return error == .invalidState || error == .startRejected(8)
    }

    private func launchApplicationAttempt(
        id: ApplicationID,
        hostID: HostID,
        resume: Bool,
        preferences: StreamingPreferences,
        activationUptime: TimeInterval
    ) async throws {
        guard let mediaCapabilities, let mediaProvider, output != nil,
              motionPolicy != nil, inputInstaller != nil, let lifecycle else {
            throw UmbraClientServiceError.unavailable(
                "Secure protocol-v3 streaming is unavailable in this build. Legacy fallback was not attempted."
            )
        }
        let protocolHostID = try requireProtocolHostID(hostID)
        try await retireTimedOutConnectionIfNeeded(hostID: protocolHostID)
        try requirePermission(hostID: protocolHostID, permission: Permission.start, feature: "stream START")
        try requirePermission(hostID: protocolHostID, permission: Permission.input, feature: "remote input")
        try requirePermission(hostID: protocolHostID, permission: Permission.stopOwnStream, feature: "stream STOP")
        var streamPreferences = preferences
        if streamPreferences.quitAppAfter {
            try requirePermission(
                hostID: protocolHostID,
                permission: Permission.quitApplication,
                feature: "remote application quit"
            )
        }
        var record = try requireHostRecord(protocolHostID)
        guard let applicationRecord = record.applications.first(where: { $0.id == id.rawValue }) else {
            throw UmbraClientServiceError.invalidInput("The selected application is unavailable.")
        }
        let mode: QUICOptimizationMode = streamPreferences.optimizationMode == .latency ? .latency : .quality
        let session = try await startReadySession(
            hostID: hostID,
            protocolHostID: protocolHostID,
            mode: mode
        )
        guard let entry = sessions[protocolHostID], entry.session === session,
              entry.preparedStream == nil, entry.activeSessionID == nil,
              !entry.launchAttemptActive, !entry.lifecyclePrepared else {
            throw ProtocolV3ClientError.invalidState
        }
        entry.launchAttemptActive = true
        defer { entry.launchAttemptActive = false }
        do {
            try await awaitInitialStreamingDatagramCapacity(
                entry: entry,
                hostID: protocolHostID,
                session: session
            )
            if streamPreferences.clientMicrophoneEnabled {
                let hostAllowsMicrophone = try hasPermission(
                    hostID: protocolHostID,
                    permission: Permission.microphone
                )
                let authorization = hostAllowsMicrophone
                    ? await microphoneAuthorization.requestAuthorization()
                    : nil
                let unavailableReason: String?
                if !hostAllowsMicrophone {
                    unavailableReason = "the paired host did not grant microphone forwarding"
                } else if authorization?.permitsCapture != true {
                    unavailableReason = "macOS microphone access is not authorized"
                } else {
                    unavailableReason = nil
                }
                if let unavailableReason {
                    if streamPreferences.clientMicrophoneRequired {
                        throw UmbraClientServiceError.unavailable(
                            "Microphone forwarding is required, but \(unavailableReason)."
                        )
                    }
                    streamPreferences.clientMicrophoneEnabled = false
                    sessionEventHandler?(.sessionDegraded(
                        "Microphone forwarding is unavailable because \(unavailableReason). Umbra will stream without the microphone."
                    ))
                }
            }
            var preparedMicrophoneCapture: (any ClientMicrophoneCapturing)?
            if streamPreferences.clientMicrophoneEnabled {
                let capture = microphoneCaptureFactory.makeCapture()
                do {
                    try capture.start(
                        frameHandler: { _ in },
                        discontinuityHandler: {},
                        failureHandler: { _ in }
                    )
                    capture.stop()
                    preparedMicrophoneCapture = capture
                } catch {
                    capture.stop()
                    if streamPreferences.clientMicrophoneRequired {
                        throw UmbraClientServiceError.unavailable(
                            "Microphone forwarding is required, but capture could not start: \(error.localizedDescription)"
                        )
                    }
                    streamPreferences.clientMicrophoneEnabled = false
                    sessionEventHandler?(.sessionDegraded(
                        "Microphone capture is unavailable: \(error.localizedDescription). Umbra will stream without the microphone."
                    ))
                }
            }
            let startIntentID = try ProtocolV3ClientIdentity.secureRandomBytes(count: 16)
            let traceID = try ProtocolV3ClientIdentity.secureRandomBytes(count: 16)
            let offer = try ProtocolV3StartRequestMapper.makeOffer(
                applicationID: id.rawValue,
                resume: resume,
                preferences: streamPreferences,
                capabilities: mediaCapabilities,
                startIntentID: startIntentID,
                traceID: traceID
            )
            log?.record(
                source: "Lumen v3",
                level: .info,
                message: "START offer app=\(offer.fields[2]?.unsignedValue ?? 0) "
                    + "profile=\(offer.fields[3]?.unsignedValue ?? 0) "
                    + "mode=\(offer.fields[4]?.unsignedValue ?? 0)x\(offer.fields[5]?.unsignedValue ?? 0)"
                    + "@\(offer.fields[6]?.unsignedValue ?? 0)/\(offer.fields[7]?.unsignedValue ?? 0) "
                    + "bitrate_kbps=\(offer.fields[8]?.unsignedValue ?? 0) "
                    + "codecs=\(offer.fields[9]?.arrayValue?.count ?? 0) "
                    + "audio=\(offer.fields[10]?.arrayValue?.count ?? 0) "
                    + "microphone=\(offer.fields[11]?.mapValue == nil ? 0 : 1) "
                    + "semantic_datagram=\(offer.fields[12]?.unsignedValue ?? 0) "
                    + "negotiated_payload=\(entry.inputDatagramPayloadByteCount) "
                    + "hdr=\(offer.fields[14]?.arrayValue?.count ?? 0) "
                    + "presentation=\(offer.fields[15]?.arrayValue?.count ?? 0) "
                    + "resume=\(offer.fields[16]?.booleanValue == true ? 1 : 0) "
                    + "constraints=\(offer.fields[17]?.mapValue?.count ?? 0) "
                    + "host_audio=\(offer.fields[18]?.booleanValue == true ? 1 : 0)."
            )
            let application = StreamApplication(
                id: applicationRecord.id,
                name: applicationRecord.name,
                hdrSupported: streamPreferences.enableHDR,
                isHidden: applicationRecord.isHidden,
                supportsDirectLaunch: applicationRecord.isDirectLaunch
            )
            let endpoint = NetworkEndpoint(hostname: record.hostname, port: record.port)
            let host = StreamHost(
                uuid: hostID.rawValue,
                name: record.displayName,
                applications: record.applications.map {
                    StreamApplication(
                        id: $0.id,
                        name: $0.name,
                        hdrSupported: streamPreferences.enableHDR,
                        isHidden: $0.isHidden,
                        supportsDirectLaunch: $0.isDirectLaunch
                    )
                },
                status: .online,
                pairState: .paired,
                activeAddress: endpoint,
                currentGameID: resume ? id.rawValue : nil,
                appVersion: "protocol-v3",
                maxLumaPixelsHEVC: streamPreferences.width * streamPreferences.height,
                codecSupport: [
                    .h264, .hevc, .hevcMain10, .av1Main8, .av1Main10,
                    .h264High8YUV444, .hevcRext8YUV444, .hevcRext10YUV444,
                    .av1High8YUV444, .av1High10YUV444,
                    .h264Lossless, .hevcLossless, .av1Lossless,
                ]
            )
            let bootstrap = try StreamBootstrap(
                sessionID: Self.uuid(from: startIntentID),
                host: host,
                application: application,
                preferences: streamPreferences,
                effectivePolicy: .resolve(for: streamPreferences),
                rtspSessionURL: nil,
                remoteInputCredentials: RemoteInputCredentials(
                    key: Data(repeating: 0, count: 16),
                    initializationVector: Data(repeating: 0, count: 16)
                )
            )
            startupTelemetry.begin(
                sessionID: bootstrap.sessionID,
                uiActivationTime: activationUptime
            )
            entry.resetStartEvents()
            entry.resetSessionEndedEvents()
            try requireStreamingDatagramCapacity(
                entry: entry,
                hostID: protocolHostID,
                session: session
            )
            sessionEventHandler?(.sessionPreparing)
            // Claim lifecycle cleanup before entering the fallible preparation boundary.
            entry.lifecyclePrepared = true
            try await lifecycle.prepare(for: bootstrap)
            let pipeline = try mediaProvider.makePipeline(
                for: bootstrap,
                telemetryClient: .umbraV3
            )
            entry.preparedStream = PreparedStream(
                bootstrap: bootstrap,
                offer: offer,
                pipeline: pipeline,
                microphoneCapture: preparedMicrophoneCapture
            )
            try requireStreamingDatagramCapacity(
                entry: entry,
                hostID: protocolHostID,
                session: session
            )
            sessionEventHandler?(.sessionConnecting(.serverHandshake))
            startupTelemetry.record(sessionID: bootstrap.sessionID, stage: .sessionStart)
            let requestID = try session.beginStart(fields: offer.fields)
            entry.activeStartRequestID = requestID
            _ = try await waitForStart(entry: entry, requestID: requestID, offer: offer)
            record.runningApplicationID = id.rawValue
            try hostCatalog.upsert(record)
            publishCatalog()
        } catch {
            await tearDownStream(
                entry: entry,
                hostID: protocolHostID,
                publishEnded: false,
                sendMicrophoneEnd: false
            )
            if Self.isTransientStartConflict(error) {
                await retireForFreshStart(session: session, hostID: protocolHostID)
            }
            throw error
        }
    }

    func stopSession(quitApplication: Bool, reason: UInt64 = 1) async throws {
        guard let (hostID, entry) = sessions.first(where: {
            $0.value.activeSessionID != nil || $0.value.attachState != nil
        }),
              let sessionID = entry.activeSessionID ?? entry.attachState?.sessionID else { return }
        try requirePermission(
            hostID: hostID,
            permission: quitApplication ? Permission.quitApplication : Permission.stopOwnStream,
            feature: quitApplication ? "remote application quit" : "stream STOP"
        )
        if let stopTask = entry.stopTask {
            return try await stopTask.value
        }
        let stopTask = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performStop(
                entry: entry,
                hostID: hostID,
                sessionID: sessionID,
                quitApplication: quitApplication,
                reason: reason
            )
        }
        entry.stopTask = stopTask
        defer { entry.stopTask = nil }
        try await stopTask.value
    }

    private func performStop(
        entry: RetainedSession,
        hostID: Data,
        sessionID: Data,
        quitApplication: Bool,
        reason: UInt64
    ) async throws {
        cancelControlKeepalive(entry: entry)
        let sessionEndedEvents = entry.sessionEndedEvents
        do {
            let stopIntentID = try ProtocolV3ClientIdentity.secureRandomBytes(count: 16)
            let response = try await requestControl(
                entry: entry,
                requestType: 0x0130,
                responseType: 0x0131,
                fields: [
                    1: .bytes(sessionID), 2: .unsigned(quitApplication ? 1 : 0),
                    3: .unsigned(reason), 4: .bytes(stopIntentID),
                ]
            )
            guard Set(response.fields.keys) == Set(1...4),
                  response.fields[1]?.unsignedValue == 0,
                  response.fields[2]?.bytesValue == sessionID,
                  response.fields[3]?.bytesValue == stopIntentID,
                  response.fields[4]?.booleanValue != nil else {
                throw ProtocolV3ClientError.invalidMessage("STOP response")
            }
            try await Self.waitForSessionEnded(
                sessionEndedEvents,
                sessionID: sessionID,
                timeout: .seconds(5)
            )
            await tearDownStream(
                entry: entry,
                hostID: hostID,
                publishEnded: true,
                sendMicrophoneEnd: false
            )
        } catch {
            log?.record(
                source: "Lumen v3",
                level: .error,
                message: "Protocol-v3 STOP failed; the QUIC connection is being closed so the host's disconnect teardown owns the session: \(error)."
            )
            sessionEventHandler?(.sessionFailed(SessionFailure(
                kind: .connectionFailed,
                message: "Secure stream teardown failed and the connection was closed: \(error.localizedDescription)",
                stage: .connection
            )))
            await tearDownStream(
                entry: entry,
                hostID: hostID,
                publishEnded: false,
                sendMicrophoneEnd: false
            )
            let terminalEvents = entry.terminalEvents
            entry.session.cancel()
            await Self.waitForTerminalEvent(terminalEvents)
            if sessions[hostID]?.session === entry.session {
                sessions[hostID] = nil
            }
            connectionStatuses[hostID] = .offline
            publishCatalog()
            throw error
        }
    }

    func stopAll() async {
        do {
            try await stopSession(quitApplication: false, reason: 3)
        } catch {
            log?.record(
                source: "Application",
                level: .error,
                message: "Ordered protocol-v3 shutdown required connection teardown: \(error)."
            )
        }
        let retained = sessions
        for (hostID, entry) in retained {
            await tearDownStream(
                entry: entry,
                hostID: hostID,
                publishEnded: false,
                sendMicrophoneEnd: false
            )
            if let pairingInvitationID = entry.pairingInvitationID {
                try? trustStore.cancelPairingAttempt(invitationID: pairingInvitationID)
                entry.pairingInvitationID = nil
            }
        }
        for entry in retained.values {
            entry.session.cancel()
        }
        await withTaskGroup(of: Void.self) { group in
            for entry in retained.values {
                let terminalEvents = entry.terminalEvents
                group.addTask {
                    await Self.waitForTerminalEvent(terminalEvents)
                }
            }
        }
        for (hostID, entry) in retained where sessions[hostID]?.session === entry.session {
            sessions[hostID] = nil
            entry.terminalContinuation.finish()
        }
    }

    private func retain(
        _ session: ProtocolV3ClientControlSession,
        hostID: Data,
        invitationRecord: ModernLumenV3HostRecord? = nil,
        pairingInvitationID: Data? = nil
    ) {
        if let priorInvitationID = sessions[hostID]?.pairingInvitationID {
            try? trustStore.cancelPairingAttempt(invitationID: priorInvitationID)
        }
        sessions[hostID]?.session.cancel()
        sessions[hostID]?.terminalContinuation.finish()
        sessions[hostID]?.authenticationContinuation.finish()
        sessions[hostID]?.managerEventContinuation.finish()
        sessions[hostID]?.managerEventTask?.cancel()
        sessions[hostID] = RetainedSession(
            session: session,
            invitationRecord: invitationRecord,
            pairingInvitationID: pairingInvitationID
        )
        installEventHandler(session, hostID: hostID)
    }

    private func installEventHandler(
        _ session: ProtocolV3ClientControlSession,
        hostID: Data
    ) {
        guard let entry = sessions[hostID] else { return }
        let mediaExecutor = entry.mediaEventExecutor
        let managerEventContinuation = entry.managerEventContinuation
        if entry.managerEventTask == nil {
            let managerEvents = entry.managerEvents
            entry.managerEventTask = Task<Void, Never> { @MainActor [weak self] in
                for await envelope in managerEvents {
                    guard let self else { return }
                    self.handle(
                        envelope.event,
                        hostID: hostID,
                        session: envelope.session
                    )
                }
            }
        }
        session.setEventHandler { [weak self] (event: ProtocolV3ClientEvent) in
            if let terminalBarrier = Self.mediaExecutorTerminalBarrier(for: event) {
                let terminalCompletion: (@Sendable () -> Void)?
                if terminalBarrier {
                    terminalCompletion = {
                        managerEventContinuation.yield(.init(
                            event: event,
                            session: session
                        ))
                    }
                } else {
                    terminalCompletion = nil
                }
                mediaExecutor.submit(
                    event,
                    terminalBarrier: terminalBarrier,
                    overflowHandler: { [weak self] in
                        Task { @MainActor in
                            guard let self,
                                  let current = self.sessions[hostID],
                                  current.session === session else { return }
                            await self.terminateMediaFailure(
                                entry: current,
                                hostID: hostID,
                                error: ProtocolV3SessionMediaError.invalidConfiguration
                            )
                        }
                    },
                    completion: terminalCompletion
                )
                return
            }
            managerEventContinuation.yield(.init(event: event, session: session))
        }
    }

    private func handle(
        _ event: ProtocolV3ClientEvent,
        hostID: Data,
        session: ProtocolV3ClientControlSession
    ) {
        guard let entry = sessions[hostID], entry.session === session else { return }
        if Self.isRecoverableConnectionLoss(event), entry.attachState != nil {
            guard !entry.isRecovering else { return }
            entry.isRecovering = true
            entry.isAuthenticated = false
            cancelControlKeepalive(entry: entry)
            entry.mediaEventExecutor.pause()
            entry.mediaCoordinator?.suspendForReconnect()
            inputInstaller?.installInputSink(nil)
            entry.inputSenderRelay.install(nil)
            entry.inputSender?.stop()
            entry.inputSender = nil
            sessionEventHandler?(.sessionConnecting(.controlStreamInitialization))
            Task { @MainActor [weak self] in
                await self?.recoverAttachedSession(entry: entry, hostID: hostID)
            }
            return
        }
        if case let .startAccepted(sessionID, fields) = event {
            entry.activeStartRequestID = nil
            let task = Task<Void, Never> { @MainActor [weak self] in
                guard let self else { return }
                await self.activateStream(
                    entry: entry,
                    hostID: hostID,
                    sessionID: sessionID,
                    fields: fields
                )
            }
            entry.activationTaskRelay.install(task)
            return
        }
        if case let .lateStartAccepted(requestID, sessionID, fields) = event {
            Task { @MainActor [weak self] in
                await self?.compensateLateStart(
                    entry: entry,
                    hostID: hostID,
                    requestID: requestID,
                    sessionID: sessionID,
                    fields: fields
                )
            }
            return
        }
        switch event {
        case let .trustEstablished(trust, endpoint):
            guard trust.hostID == hostID,
                  var record = sessions[hostID]?.invitationRecord else { return }
            do {
                record.hostname = endpoint.host
                record.port = endpoint.port
                try hostCatalog.upsert(record)
                guard try trustStore.trust(hostID: hostID) == trust,
                      try hostCatalog.host(hostID: hostID) == record else {
                    throw UmbraClientServiceError.unavailable(
                        "Secure pairing persistence could not be verified."
                    )
                }
                entry.invitationRecord = nil
                entry.pairingInvitationID = nil
                publishCatalog()
                let pairedHost = displayHost(record, trust: trust)
                entry.pairingContinuation.yield(.success(pairedHost))
                entry.pairingContinuation.finish()
            } catch {
                if let pairingInvitationID = entry.pairingInvitationID {
                    try? trustStore.cancelPairingAttempt(invitationID: pairingInvitationID)
                    entry.pairingInvitationID = nil
                }
                try? hostCatalog.remove(hostID: hostID)
                try? trustStore.removeTrust(hostID: hostID)
                let reported = UmbraClientServiceError.unavailable(
                    "Secure pairing was rolled back because the trusted host endpoint could not be saved: "
                        + error.localizedDescription
                )
                log?.record(
                    source: "Lumen v3",
                    level: .error,
                    message: reported.localizedDescription
                )
                entry.pairingContinuation.yield(.failure(reported))
                entry.pairingContinuation.finish()
                session.cancel()
            }
        case let .authenticated(_, _, serverCapabilities):
            entry.isAuthenticated = true
            entry.serverCapabilities = serverCapabilities
            connectionStatuses[hostID] = .online
            entry.authenticationContinuation.yield(.success(()))
            entry.authenticationContinuation.finish()
            publishCatalog()
        case let .transport(.negotiated(parameters)):
            entry.inputDatagramPayloadByteCount = parameters.usableDatagramPayloadSize
            entry.inputSenderRelay.updateMaximumPayloadByteCount(
                parameters.usableDatagramPayloadSize
            )
            entry.mediaCoordinator?.handle(event)
        case let .transport(.datagramCapacityChanged(_, payloadByteCount)):
            entry.inputDatagramPayloadByteCount = payloadByteCount
            entry.inputSenderRelay.updateMaximumPayloadByteCount(payloadByteCount)
            entry.mediaCoordinator?.handle(event)
        case let .activeSessionAvailable(activeSessionID):
            entry.activeSessionID = activeSessionID
            entry.activeSessionContinuation.yield(activeSessionID)
            entry.activeSessionContinuation.finish()
        case let .controlMessage(type, requestID, fields):
            if type == 0x0101,
               let cancelledOffer = entry.cancelledStartOffers.removeValue(forKey: requestID) {
                guard fields[2] == cancelledOffer.fields[1] else {
                    session.cancel()
                    return
                }
                return
            }
            if type == 0x0132, requestID == 0 {
                guard fields[1]?.bytesValue == entry.activeSessionID else { return }
                inputInstaller?.installInputSink(nil)
                entry.inputSenderRelay.install(nil)
                entry.inputSender?.stop()
                entry.inputSender = nil
                return
            }
            if type == 0x0133, requestID == 0 {
                if let sessionID = fields[1]?.bytesValue {
                    entry.sessionEndedContinuation.yield(sessionID)
                    entry.sessionEndedContinuation.finish()
                }
                if entry.stopTask != nil { return }
                Task { @MainActor [weak self] in
                    await self?.tearDownStream(
                        entry: entry,
                        hostID: hostID,
                        publishEnded: true,
                        sendMicrophoneEnd: false
                    )
                }
                return
            }
            guard requestID != 0,
                  let pending = entry.pendingControlResponses.removeValue(forKey: requestID) else {
                return
            }
            guard type == pending.expectedType else {
                pending.continuation.yield(.failure(.invalidMessage("control response type")))
                pending.continuation.finish()
                return
            }
            pending.continuation.yield(.success(ControlResponse(
                type: type,
                requestID: requestID,
                fields: fields
            )))
            pending.continuation.finish()
        case let .bulkHeader(header):
            receiveBulkHeader(header, entry: entry)
        case let .bulkObject(object):
            receiveBulkObject(object, entry: entry)
        case let .bulkFailure(failure):
            receiveBulkFailure(failure, entry: entry)
        case let .failed(error):
            if let pairingInvitationID = entry.pairingInvitationID {
                try? trustStore.cancelPairingAttempt(invitationID: pairingInvitationID)
                entry.pairingInvitationID = nil
            }
            entry.authenticationContinuation.yield(.failure(error))
            entry.authenticationContinuation.finish()
            entry.startContinuation.yield(.failure(error))
            entry.startContinuation.finish()
            connectionStatuses[hostID] = .offline
            failPendingControlResponses(hostID: hostID, error: error)
            log?.record(
                source: "Lumen v3",
                level: .error,
                message: "The explicit protocol-v3 connection failed: \(error). Legacy fallback was not attempted."
            )
            if entry.invitationRecord != nil {
                let reported = UmbraClientServiceError.unavailable(
                    "Secure pairing failed: \(error). Legacy fallback was not attempted."
                )
                entry.pairingContinuation.yield(.failure(reported))
                entry.pairingContinuation.finish()
            }
            Task { @MainActor [weak self] in
                await self?.tearDownStream(
                    entry: entry,
                    hostID: hostID,
                    publishEnded: false,
                    sendMicrophoneEnd: false
                )
            }
            finish(session: session, hostID: hostID)
        case let .transport(.mediaSessionEnded(reason)):
            log?.record(source: "Lumen v3", level: .info, message: "Media session ended: \(reason)")
            Task { @MainActor [weak self] in
                await self?.tearDownStream(
                    entry: entry,
                    hostID: hostID,
                    publishEnded: true,
                    sendMicrophoneEnd: false
                )
            }
        case .transport(.stateChanged(.cancelled)), .transport(.stateChanged(.failed)):
            finish(session: session, hostID: hostID)
        default:
            break
        }
    }

    private func cancelInvitationPairing(
        session: ProtocolV3ClientControlSession,
        hostID: Data
    ) {
        guard let entry = sessions[hostID], entry.session === session,
              entry.invitationRecord != nil else { return }
        entry.pairingContinuation.yield(.failure(CancellationError()))
        entry.pairingContinuation.finish()
        session.cancel()
        finish(session: session, hostID: hostID)
    }

    private func finish(session: ProtocolV3ClientControlSession, hostID: Data) {
        guard let entry = sessions[hostID], entry.session === session else { return }
        if entry.invitationRecord != nil {
            entry.pairingContinuation.yield(.failure(CancellationError()))
        }
        entry.pairingContinuation.finish()
        if let pairingInvitationID = entry.pairingInvitationID {
            try? trustStore.cancelPairingAttempt(invitationID: pairingInvitationID)
            entry.pairingInvitationID = nil
        }
        clearBulkState(entry: entry, reason: "control connection ended")
        sessions[hostID] = nil
        entry.authenticationContinuation.finish()
        entry.activeSessionContinuation.finish()
        entry.sessionEndedContinuation.finish()
        entry.startContinuation.finish()
        entry.configurationAcknowledgementContinuation.finish()
        entry.activationTaskRelay.cancel()
        entry.managerEventContinuation.finish()
        entry.managerEventTask?.cancel()
        entry.terminalContinuation.yield(())
        entry.terminalContinuation.finish()
    }

    private func retireForFreshStart(
        session: ProtocolV3ClientControlSession,
        hostID: Data
    ) async {
        guard let entry = sessions[hostID], entry.session === session else { return }
        let terminalEvents = entry.terminalEvents
        session.cancel()
        await Self.waitForTerminalEvent(terminalEvents)
        finish(session: session, hostID: hostID)
    }

    private func startReadySession(
        hostID: HostID,
        protocolHostID: Data,
        mode: QUICOptimizationMode
    ) async throws -> ProtocolV3ClientControlSession {
        var session = try await reconnect(hostID: hostID, mode: mode)
        for _ in 0..<2 {
            if session.canBeginStart { return session }
            guard let entry = sessions[protocolHostID], entry.session === session else {
                throw ProtocolV3ClientError.invalidState
            }
            if let activeSessionID = entry.activeSessionID {
                log?.record(
                    source: "Lumen v3",
                    level: .warning,
                    message: "Stopping the host's orphaned protocol-v3 session before retrying START."
                )
                try await performStop(
                    entry: entry,
                    hostID: protocolHostID,
                    sessionID: activeSessionID,
                    quitApplication: false,
                    reason: 1
                )
            } else {
                await retireForFreshStart(session: session, hostID: protocolHostID)
                session = try await reconnect(hostID: hostID, mode: mode)
            }
        }
        guard session.canBeginStart else { throw ProtocolV3ClientError.invalidState }
        return session
    }

    private func recoverAttachedSession(
        entry: RetainedSession,
        hostID: Data
    ) async {
        guard let attach = entry.attachState,
              let prepared = entry.preparedStream,
              let coordinator = entry.mediaCoordinator,
              let motionPolicy else {
            await failAttachedRecovery(
                entry: entry,
                hostID: hostID,
                error: ProtocolV3ClientError.invalidState
            )
            return
        }
        do {
            let record = try requireHostRecord(hostID)
            let trust = try requireTrust(hostID)
            let identity = try trustStore.identity()
            guard trust.clientID == identity.clientID else {
                throw ProtocolV3ClientError.authenticationFailed
            }
            let replacement = try pairedSessionFactory(
                trust,
                identity,
                record.hostname,
                record.port,
                record.hostnameIsIPLiteral == true,
                prepared.offer.mode
            )
            entry.resetAuthenticationEvents()
            let oldSession = entry.session
            entry.session = replacement
            installEventHandler(replacement, hostID: hostID)
            oldSession.cancel()
            try replacement.start()
            try await waitForAuthentication(
                hostID: hostID,
                session: replacement,
                timeout: recoveryPhaseTimeouts.authentication
            )
            let ownedSessionID = try await waitForActiveSession(
                entry: entry,
                timeout: recoveryPhaseTimeouts.activeSessionAnnouncement
            )
            guard ownedSessionID == attach.sessionID else {
                throw ProtocolV3ClientError.authenticationFailed
            }

            let attachIntentID = try ProtocolV3ClientIdentity.secureRandomBytes(count: 16)
            let attachFields: [UInt64: ProtocolV3CBORValue] = [
                1: .bytes(attach.sessionID),
                2: .bytes(attach.attachToken),
                3: .bytes(attachIntentID),
                4: .unsigned(UInt64(attach.inputGeneration)),
                5: .map([
                    1: .unsigned(UInt64(attach.videoGeneration)),
                    2: .unsigned(UInt64(attach.audioGeneration)),
                    3: .unsigned(UInt64(attach.microphoneGeneration)),
                ]),
            ]
            let attachResponse = try await requestAttachWithStableIntent(
                entry: entry,
                fields: attachFields,
                timeout: recoveryPhaseTimeouts.attachResponse
            )
            guard Set(attachResponse.fields.keys) == Set(1...6),
                  attachResponse.fields[1]?.unsignedValue == 0,
                  attachResponse.fields[2]?.bytesValue == attach.sessionID,
                  let connectionAuthority = attachResponse.fields[3]?.unsignedValue,
                  connectionAuthority > 0,
                  let sessionAuthority = attachResponse.fields[4]?.unsignedValue,
                  sessionAuthority > 0,
                  attachResponse.fields[5]?.booleanValue != nil,
                  let currentGenerations = attachResponse.fields[6]?.mapValue,
                  Set(currentGenerations.keys) == Set(1...3),
                  currentGenerations[1]?.unsignedValue == UInt64(attach.videoGeneration),
                  currentGenerations[2]?.unsignedValue == UInt64(attach.audioGeneration),
                  currentGenerations[3]?.unsignedValue == UInt64(attach.microphoneGeneration) else {
                throw ProtocolV3ClientError.invalidMessage("ATTACH response")
            }

            let inputFailureHandler = inputFailureHandler(entry: entry, hostID: hostID)
            let inputLatencyTracker = entry.inputLatencyTracker
                ?? ProtocolV3InputLatencyTracker()
            entry.inputLatencyTracker = inputLatencyTracker
            let inputSender = ProtocolV3InputStateSender(
                session: replacement,
                sessionID: attach.sessionID,
                mode: prepared.offer.mode,
                usesAbsolutePointer: prepared.bootstrap.preferences.absoluteMouseMode,
                inputGeneration: attach.inputGeneration,
                supportsCompactStateFormat: entry.serverCapabilities & 0x200 != 0,
                maximumPayloadByteCount: entry.inputDatagramPayloadByteCount,
                latencyTracker: inputLatencyTracker,
                degradationHandler: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.sessionEventHandler?(.sessionDegraded(message))
                    }
                },
                failureHandler: inputFailureHandler
            )
            let resetState = try inputSender.inputResetStateBlock()
            let resetResponse = try await requestControl(
                entry: entry,
                requestType: 0x0120,
                responseType: 0x0121,
                fields: [1: .bytes(attach.sessionID), 2: .bytes(resetState)],
                timeout: recoveryPhaseTimeouts.inputResetResponse
            )
            guard Set(resetResponse.fields.keys) == Set([1, 2]),
                  resetResponse.fields[1]?.unsignedValue == 0,
                  let resetInputGenerationRaw = resetResponse.fields[2]?.unsignedValue,
                  let resetInputGeneration = UInt32(exactly: resetInputGenerationRaw),
                  resetInputGeneration != 0 else {
                throw ProtocolV3ClientError.invalidMessage("INPUT_RESET response")
            }
            try inputSender.updateInputGeneration(resetInputGeneration)
            entry.attachState = AttachState(
                sessionID: attach.sessionID,
                attachToken: attach.attachToken,
                startIntentID: attach.startIntentID,
                videoGeneration: attach.videoGeneration,
                audioGeneration: attach.audioGeneration,
                microphoneGeneration: attach.microphoneGeneration,
                inputGeneration: resetInputGeneration
            )

            try coordinator.rebind(control: replacement, sessionID: attach.sessionID)
            entry.mediaEventExecutor.installAndResume(coordinator)
            entry.inputSender = inputSender
            entry.inputSenderRelay.install(inputSender)
            try inputSender.start()
            inputInstaller?.installInputSink(ProtocolV3PlatformInputSink(
                sender: inputSender,
                motionPolicy: motionPolicy,
                failureHandler: inputFailureHandler
            ))
            entry.activeSessionID = attach.sessionID
            entry.isRecovering = false
            connectionStatuses[hostID] = .online
            publishCatalog()
            sessionEventHandler?(.sessionStreaming)
            startControlKeepalive(entry: entry, hostID: hostID)
        } catch {
            await failAttachedRecovery(entry: entry, hostID: hostID, error: error)
        }
    }

    private func requestAttachWithStableIntent(
        entry: RetainedSession,
        fields: [UInt64: ProtocolV3CBORValue],
        timeout: Duration
    ) async throws -> ControlResponse {
        var lastError: Error = ProtocolV3ClientError.invalidState
        for _ in 0..<2 {
            do {
                return try await requestControl(
                    entry: entry,
                    requestType: 0x0102,
                    responseType: 0x0103,
                    fields: fields,
                    timeout: timeout
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func waitForActiveSession(
        entry: RetainedSession,
        timeout: Duration
    ) async throws -> Data {
        let events = entry.activeSessionEvents
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                guard let value = await iterator.next() else {
                    throw ProtocolV3ClientError.authenticationFailed
                }
                return value
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProtocolV3ClientError.authenticationFailed
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw ProtocolV3ClientError.authenticationFailed
            }
            return value
        }
    }

    private func failAttachedRecovery(
        entry: RetainedSession,
        hostID: Data,
        error: Error
    ) async {
        entry.attachState = nil
        entry.session.cancel()
        await tearDownStream(
            entry: entry,
            hostID: hostID,
            publishEnded: false,
            sendMicrophoneEnd: false
        )
        connectionStatuses[hostID] = .offline
        publishCatalog()
        sessionEventHandler?(.sessionFailed(SessionFailure(
            kind: .connectionFailed,
            message: "Secure session reconnect/ATTACH failed: \(error.localizedDescription)",
            stage: .controlStreamInitialization
        )))
    }

    private func terminateMediaFailure(
        entry: RetainedSession,
        hostID: Data,
        error: Error
    ) async {
        guard sessions[hostID]?.session === entry.session,
              entry.activeSessionID != nil || entry.preparedStream != nil else { return }
        log?.record(
            source: "Lumen v3 media",
            level: .error,
            message: "Terminal native media/configuration failure: \(error)"
        )
        entry.attachState = nil
        inputInstaller?.installInputSink(nil)
        entry.inputSenderRelay.install(nil)
        entry.inputSender?.stop()
        entry.session.cancel()
        await tearDownStream(
            entry: entry,
            hostID: hostID,
            publishEnded: false,
            sendMicrophoneEnd: false
        )
        connectionStatuses[hostID] = .offline
        publishCatalog()
        sessionEventHandler?(.sessionFailed(SessionFailure(
            kind: .streamTerminated,
            message: "Secure stream ended after a terminal media failure: \(error.localizedDescription)",
            stage: .connection
        )))
    }

    private func inputFailureHandler(
        entry: RetainedSession,
        hostID: Data
    ) -> @Sendable (Error) -> Void {
        let expectedSession = entry.session
        return { [weak self, expectedSession] error in
            Task { @MainActor in
                guard let self,
                      let entry = self.sessions[hostID],
                      entry.session === expectedSession else { return }
                await self.terminateInputFailure(entry: entry, hostID: hostID, error: error)
            }
        }
    }

    private func terminateInputFailure(
        entry: RetainedSession,
        hostID: Data,
        error: Error
    ) async {
        guard sessions[hostID]?.session === entry.session,
              entry.activeSessionID != nil || entry.preparedStream != nil else { return }
        log?.record(
            source: "Lumen v3 input",
            level: .error,
            message: "Terminal input delivery failure: \(error)"
        )
        entry.attachState = nil
        inputInstaller?.installInputSink(nil)
        entry.inputSenderRelay.install(nil)
        entry.inputSender?.stop()
        entry.session.cancel()
        await tearDownStream(
            entry: entry,
            hostID: hostID,
            publishEnded: false,
            sendMicrophoneEnd: false
        )
        connectionStatuses[hostID] = .offline
        publishCatalog()
        sessionEventHandler?(.sessionFailed(SessionFailure(
            kind: .streamTerminated,
            message: "Secure stream ended after an input delivery failure: \(error.localizedDescription)",
            stage: .connection
        )))
    }

    private func activateStream(
        entry: RetainedSession,
        hostID: Data,
        sessionID: Data,
        fields: [UInt64: ProtocolV3CBORValue]
    ) async {
        do {
            guard let output, let motionPolicy, let inputInstaller, let lifecycle,
                  var prepared = entry.preparedStream,
                  let startIntentID = prepared.offer.fields[1]?.bytesValue,
                  fields[2]?.bytesValue == startIntentID,
                  fields[3]?.bytesValue == sessionID,
                  fields[4]?.unsignedValue == prepared.offer.fields[3]?.unsignedValue,
                  fields[11]?.unsignedValue == UInt64(QUICTransportProfile.semanticDatagramByteCount),
                  fields[20]?.bytesValue == prepared.offer.fields[13]?.bytesValue,
                  let attachToken = fields[21]?.bytesValue,
                  attachToken.count == 32,
                  let videoGenerationRaw = fields[14]?.unsignedValue,
                  let videoGeneration = UInt32(exactly: videoGenerationRaw),
                  videoGeneration != 0,
                  let audioGenerationRaw = fields[15]?.unsignedValue,
                  let audioGeneration = UInt32(exactly: audioGenerationRaw),
                  audioGeneration != 0,
                  let microphoneGenerationRaw = fields[16]?.unsignedValue,
                  let microphoneGeneration = UInt32(exactly: microphoneGenerationRaw),
                  let inputGenerationRaw = fields[17]?.unsignedValue,
                  let inputGeneration = UInt32(exactly: inputGenerationRaw),
                  inputGeneration != 0 else {
                throw ProtocolV3ClientError.invalidMessage("START selection")
            }
            startupTelemetry.record(
                sessionID: prepared.bootstrap.sessionID,
                stage: .hostLaunch
            )
            let selectedMode = try ProtocolV3StartRequestMapper.selectedMode(
                responseFields: fields,
                offered: prepared.offer
            )
            if prepared.bootstrap.preferences.clientMicrophoneEnabled,
               fields[13] == .null {
                prepared.bootstrap.preferences.clientMicrophoneEnabled = false
                prepared.bootstrap.preferences.clientMicrophoneRequired = false
                sessionEventHandler?(.sessionDegraded(
                    "The host microphone endpoint is unavailable. Umbra will stream without the microphone."
                ))
            }
            let selectedFormat = try ProtocolV3StartRequestMapper.selectedVideoFormat(
                responseFields: fields,
                offered: prepared.offer
            )
            let selectedHDR = fields[23] != .null
            guard !selectedHDR || prepared.bootstrap.preferences.enableHDR else {
                throw ProtocolV3ClientError.invalidMessage("unoffered HDR selection")
            }
            if prepared.offer.fields[17]?.mapValue?[6]?.booleanValue == false {
                guard fields[6] == prepared.offer.fields[4],
                      fields[7] == prepared.offer.fields[5],
                      fields[8] == prepared.offer.fields[6],
                      fields[9] == prepared.offer.fields[7],
                      selectedFormat.isYUV444 == prepared.bootstrap.preferences.enableYUV444,
                      selectedHDR == prepared.bootstrap.preferences.enableHDR else {
                    throw ProtocolV3ClientError.invalidMessage("forbidden START adjustment")
                }
            }
            prepared.bootstrap.preferences.width = selectedMode.width
            prepared.bootstrap.preferences.height = selectedMode.height
            prepared.bootstrap.preferences.setFrameRate(
                numerator: Int(selectedMode.refreshNumerator),
                denominator: Int(selectedMode.refreshDenominator)
            )
            prepared.bootstrap.preferences.bitrateKbps = selectedMode.bitrateKbps
            prepared.bootstrap.preferences.enableYUV444 = selectedFormat.isYUV444
            prepared.bootstrap.preferences.enableHDR = selectedHDR
            try await lifecycle.updatePreparation(for: prepared.bootstrap)
            await output.beginSession()

            let startupSessionID = prepared.bootstrap.sessionID
            let inputLatencyTracker = ProtocolV3InputLatencyTracker()
            let media = try ProtocolV3MediaPipelineAdapter(
                pipeline: prepared.pipeline,
                mode: prepared.offer.mode,
                startResponseFields: fields,
                inputLatencyTracker: inputLatencyTracker,
                firstVideoSubmitHandler: { [startupTelemetry] in
                    startupTelemetry.record(
                        sessionID: startupSessionID,
                        stage: .decoderSubmitRequested
                    )
                },
                diagnosticHandler: { [weak log] message in
                    log?.record(source: "Lumen v3 media", level: .debug, message: message)
                }
            )
            let inputFailureHandler = inputFailureHandler(entry: entry, hostID: hostID)
            let inputSender = ProtocolV3InputStateSender(
                session: entry.session,
                sessionID: sessionID,
                mode: prepared.offer.mode,
                usesAbsolutePointer: prepared.bootstrap.preferences.absoluteMouseMode,
                inputGeneration: inputGeneration,
                supportsCompactStateFormat: entry.serverCapabilities & 0x200 != 0,
                maximumPayloadByteCount: entry.inputDatagramPayloadByteCount,
                latencyTracker: inputLatencyTracker,
                degradationHandler: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.sessionEventHandler?(.sessionDegraded(message))
                    }
                },
                failureHandler: inputFailureHandler
            )
            entry.inputSenderRelay.install(inputSender)
            entry.inputLatencyTracker = inputLatencyTracker
            let mediaCoordinator = ProtocolV3SessionMediaCoordinator(
                control: entry.session,
                media: media,
                microphoneCapture: prepared.bootstrap.preferences.clientMicrophoneEnabled
                    ? prepared.microphoneCapture
                    : nil,
                inputACKHandler: { [inputSenderRelay = entry.inputSenderRelay] acknowledgement in
                    inputSenderRelay.acknowledge(acknowledgement.appliedEdgeID)
                },
                inputResyncHandler: { [inputSenderRelay = entry.inputSenderRelay] resync in
                    inputSenderRelay.resynchronize(resync.expectedEdgeID)
                },
                controllerFeedbackHandler: {
                    [inputSenderRelay = entry.inputSenderRelay, output] feedback in
                    guard inputSenderRelay.accepts(feedback) else { return }
                    switch feedback.command {
                    case let .rumble(lowFrequency, highFrequency):
                        output.handle(.rumble(
                            controller: UInt16(feedback.controller),
                            lowFrequency: lowFrequency,
                            highFrequency: highFrequency
                        ))
                    case let .triggerRumble(left, right):
                        output.handle(.triggerRumble(
                            controller: UInt16(feedback.controller),
                            left: left,
                            right: right
                        ))
                    case let .motionState(type, reportRateHz):
                        output.handle(.motionState(
                            controller: UInt16(feedback.controller),
                            type: type,
                            reportRateHz: reportRateHz
                        ))
                    case let .led(red, green, blue):
                        output.handle(.controllerLED(
                            controller: UInt16(feedback.controller),
                            red: red,
                            green: green,
                            blue: blue
                        ))
                    case let .adaptiveTriggers(flags, leftType, rightType, left, right):
                        output.handle(.adaptiveTriggers(
                            controller: UInt16(feedback.controller),
                            flags: flags,
                            leftType: leftType,
                            rightType: rightType,
                            left: left,
                            right: right
                        ))
                    }
                },
                failureHandler: { [weak self, hostID] error in
                    Task { @MainActor in
                        guard let self, let entry = self.sessions[hostID] else { return }
                        await self.terminateMediaFailure(
                            entry: entry,
                            hostID: hostID,
                            error: error
                        )
                    }
                },
                statisticsHandler: { [output] statistics in
                    output.handleProtocolV3Statistics(statistics)
                    if let video = statistics.media.videoPipeline {
                        output.handleVideoStatistics(video)
                    }
                },
                configurationAcknowledgementHandler: {
                    [
                        configurationAcknowledgementContinuation = entry.configurationAcknowledgementContinuation,
                        startContinuation = entry.startContinuation
                    ] outcome in
                    configurationAcknowledgementContinuation.yield(outcome)
                    if case .rejected = outcome {
                        startContinuation.yield(.failure(
                            ProtocolV3SessionMediaError.invalidConfiguration
                        ))
                        startContinuation.finish()
                    }
                }
            )
            entry.activeSessionID = sessionID
            entry.attachState = AttachState(
                sessionID: sessionID,
                attachToken: attachToken,
                startIntentID: startIntentID,
                videoGeneration: videoGeneration,
                audioGeneration: audioGeneration,
                microphoneGeneration: microphoneGeneration,
                inputGeneration: inputGeneration
            )
            entry.preparedStream = prepared
            entry.mediaCoordinator = mediaCoordinator
            entry.inputSender = inputSender
            entry.statisticsTask?.cancel()
            entry.statisticsTask = Task { [weak entry, output] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let entry, let coordinator = entry.mediaCoordinator else { return }
                    let statistics = coordinator.statistics()
                    output.handleProtocolV3Statistics(statistics)
                    if let video = statistics.media.videoPipeline {
                        output.handleVideoStatistics(video)
                    }
                }
            }
            mediaCoordinator.handle(.startAccepted(sessionID: sessionID, fields: fields))
            entry.mediaEventExecutor.installAndResume(mediaCoordinator)
            // Lumen pipelines configuration requests behind START. Do not expose
            // input or publish streaming until every required success ACK is sent.
            var requiredConfigurations: [UInt16: ConfigurationBinding] = [
                0x0140: .init(sessionID: sessionID, generation: videoGeneration),
                0x0142: .init(sessionID: sessionID, generation: audioGeneration),
            ]
            if fields[13] != .null {
                requiredConfigurations[0x0144] = .init(
                    sessionID: sessionID,
                    generation: microphoneGeneration
                )
            }
            try await Self.waitForConfigurationAcknowledgements(
                entry.configurationAcknowledgements,
                required: requiredConfigurations,
                timeout: configurationBarrierTimeout
            )
            try inputSender.start()
            inputInstaller.installInputSink(ProtocolV3PlatformInputSink(
                sender: inputSender,
                motionPolicy: motionPolicy,
                failureHandler: inputFailureHandler
            ))
            await lifecycle.commitStreaming(for: prepared.bootstrap)
            sessionEventHandler?(.sessionStreaming)
            startControlKeepalive(entry: entry, hostID: hostID)
            entry.startContinuation.yield(.success(StartResult(sessionID: sessionID, fields: fields)))
            entry.startContinuation.finish()
        } catch {
            entry.startContinuation.yield(.failure(error))
            entry.startContinuation.finish()
            if !(error is CancellationError) {
                sessionEventHandler?(.sessionFailed(SessionFailure(
                    kind: .connectionFailed,
                    message: error.localizedDescription,
                    stage: .connection
                )))
            }
            await tearDownStream(
                entry: entry,
                hostID: hostID,
                publishEnded: false,
                sendMicrophoneEnd: true
            )
            entry.session.cancel()
            connectionStatuses[hostID] = .offline
            publishCatalog()
        }
    }

    private func waitForStart(
        entry: RetainedSession,
        requestID: UInt64,
        offer: ProtocolV3StartOffer
    ) async throws -> StartResult {
        let events = entry.startEvents
        do {
            return try await withThrowingTaskGroup(of: StartResult.self) { group in
                group.addTask {
                    var iterator = events.makeAsyncIterator()
                    let result = await iterator.next()
                    try Task.checkCancellation()
                    guard let result else {
                        throw ProtocolV3ClientError.invalidState
                    }
                    return try result.get()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw ModernLumenV3ManagerError.startTimedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw ProtocolV3ClientError.invalidState
                }
                return first
            }
        } catch is CancellationError {
            entry.activationTaskRelay.cancel()
            throw CancellationError()
        } catch let error as ModernLumenV3ManagerError {
            guard case .startTimedOut = error else { throw error }
            if entry.activeStartRequestID == requestID {
                do {
                    try entry.session.cancelStart(requestID: requestID)
                    entry.activeStartRequestID = nil
                    entry.cancelledStartOffers[requestID] = offer
                    throw ModernLumenV3ManagerError.startTimedOut
                } catch let timeout as ModernLumenV3ManagerError {
                    throw timeout
                } catch {
                    // A response won the core queue race just as the deadline fired.
                    // Await the already-authoritative activation result instead of
                    // misclassifying a successful START as cancelled.
                    return try await awaitStartEvent(events)
                }
            }
            return try await awaitStartEvent(events)
        } catch {
            throw error
        }
    }

    private func awaitStartEvent(
        _ events: AsyncStream<Result<StartResult, Error>>
    ) async throws -> StartResult {
        var iterator = events.makeAsyncIterator()
        guard let result = await iterator.next() else {
            throw ProtocolV3ClientError.invalidState
        }
        return try result.get()
    }

    private static func waitForSessionEnded(
        _ events: AsyncStream<Data>,
        sessionID: Data,
        timeout: Duration
    ) async throws {
        let endedSessionID = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
        guard endedSessionID == sessionID else {
            throw ProtocolV3ClientError.invalidMessage("SESSION_ENDED timeout or session mismatch")
        }
    }

    private nonisolated static func waitForConfigurationAcknowledgements(
        _ events: AsyncStream<ProtocolV3ConfigurationOutcome>,
        required: [UInt16: ConfigurationBinding],
        timeout: Duration
    ) async throws {
        let state = ConfigurationBarrierState(required: required)
        let remaining = try await withThrowingTaskGroup(of: Set<UInt16>.self) { group in
            group.addTask {
                for await outcome in events {
                    try Task.checkCancellation()
                    switch outcome {
                    case let .acknowledged(acknowledgement):
                        if state.acknowledge(acknowledgement) { return [] }
                    case .rejected:
                        throw ProtocolV3SessionMediaError.invalidConfiguration
                    }
                }
                try Task.checkCancellation()
                return state.remaining
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return state.remaining
            }
            defer { group.cancelAll() }
            let first = try await group.next() ?? state.remaining
            group.cancelAll()
            return first
        }
        guard remaining.isEmpty else {
            throw ModernLumenV3ManagerError.configurationTimedOut(remaining.sorted())
        }
    }

    private func compensateLateStart(
        entry: RetainedSession,
        hostID: Data,
        requestID: UInt64,
        sessionID: Data,
        fields: [UInt64: ProtocolV3CBORValue]
    ) async {
        guard let offer = entry.cancelledStartOffers[requestID] else {
            entry.mediaEventExecutor.discardBuffered()
            entry.session.cancel()
            return
        }
        let sessionEndedEvents = entry.sessionEndedEvents
        do {
            try ProtocolV3StartRequestMapper.validateSelectedTuples(
                responseFields: fields,
                offered: offer
            )
            let stopIntentID = try ProtocolV3ClientIdentity.secureRandomBytes(count: 16)
            let response = try await requestControl(
                entry: entry,
                requestType: 0x0130,
                responseType: 0x0131,
                fields: [
                    1: .bytes(sessionID), 2: .unsigned(0),
                    3: .unsigned(3), 4: .bytes(stopIntentID),
                ]
            )
            guard response.fields[1]?.unsignedValue == 0,
                  response.fields[2]?.bytesValue == sessionID,
                  response.fields[3]?.bytesValue == stopIntentID else {
                throw ProtocolV3ClientError.invalidMessage("late START compensating STOP")
            }
            try await Self.waitForSessionEnded(
                sessionEndedEvents,
                sessionID: sessionID,
                timeout: .seconds(5)
            )
            entry.cancelledStartOffers[requestID] = nil
            entry.mediaEventExecutor.discardBuffered()
            log?.record(
                source: "Lumen v3",
                level: .warning,
                message: "A START accepted after its 30-second client deadline was immediately stopped."
            )
        } catch {
            entry.cancelledStartOffers[requestID] = nil
            entry.mediaEventExecutor.discardBuffered()
            let reported = ModernLumenV3ManagerError.lateStartCompensationFailed(
                error.localizedDescription
            )
            log?.record(source: "Lumen v3", level: .error, message: reported.localizedDescription)
            sessionEventHandler?(.sessionFailed(SessionFailure(
                kind: .connectionFailed,
                message: reported.localizedDescription,
                stage: .connection
            )))
            entry.session.cancel()
            connectionStatuses[hostID] = .offline
            publishCatalog()
        }
    }

    private func retireTimedOutConnectionIfNeeded(hostID: Data) async throws {
        guard let entry = sessions[hostID], !entry.cancelledStartOffers.isEmpty else { return }
        let terminalEvents = entry.terminalEvents
        entry.session.cancel()
        await Self.waitForTerminalEvent(terminalEvents)
        if sessions[hostID]?.session === entry.session {
            sessions[hostID] = nil
        }
        connectionStatuses[hostID] = .offline
    }

    private func tearDownStream(
        entry: RetainedSession,
        hostID: Data,
        publishEnded: Bool,
        sendMicrophoneEnd: Bool
    ) async {
        if let teardownTask = entry.teardownTask {
            await teardownTask.value
            return
        }
        let teardownTask = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performTearDownStream(
                entry: entry,
                hostID: hostID,
                publishEnded: publishEnded,
                sendMicrophoneEnd: sendMicrophoneEnd
            )
        }
        entry.teardownTask = teardownTask
        await teardownTask.value
        entry.teardownTask = nil
    }

    private func performTearDownStream(
        entry: RetainedSession,
        hostID: Data,
        publishEnded: Bool,
        sendMicrophoneEnd: Bool
    ) async {
        guard entry.lifecyclePrepared || entry.preparedStream != nil
                || entry.mediaCoordinator != nil || entry.inputSender != nil
                || entry.activeSessionID != nil else {
            return
        }
        let prepared = entry.preparedStream
        let coordinator = entry.mediaCoordinator
        let inputSender = entry.inputSender
        cancelControlKeepalive(entry: entry)
        await entry.mediaEventExecutor.clearAndWait()
        entry.preparedStream = nil
        entry.statisticsTask?.cancel()
        entry.statisticsTask = nil
        entry.mediaCoordinator = nil
        entry.inputSender = nil
        entry.inputLatencyTracker = nil
        entry.activeSessionID = nil
        entry.attachState = nil
        entry.isRecovering = false
        let lifecycleWasPrepared = entry.lifecyclePrepared
        entry.lifecyclePrepared = false
        clearBulkState(entry: entry, reason: "stream teardown")
        inputInstaller?.installInputSink(nil)
        entry.inputSenderRelay.install(nil)
        inputSender?.stop()
        coordinator?.stopAndCleanUp(sendMicrophoneEnd: sendMicrophoneEnd)
        if coordinator == nil { prepared?.pipeline.cleanUp() }
        await output?.endSession()
        if lifecycleWasPrepared {
            await lifecycle?.finishPresentation()
            await lifecycle?.finish()
        }
        if var record = try? hostCatalog.host(hostID: hostID) {
            record.runningApplicationID = nil
            try? hostCatalog.upsert(record)
            publishCatalog()
        }
        if publishEnded { sessionEventHandler?(.sessionEnded) }
    }

    private func startControlKeepalive(entry: RetainedSession, hostID: Data) {
        cancelControlKeepalive(entry: entry)
        let expectedSession = entry.session
        entry.controlKeepaliveTask = Task { @MainActor [weak self, weak entry] in
            guard let self, let entry else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: ProtocolV3ControlKeepalivePolicy.interval)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.sessions[hostID] === entry,
                      entry.session === expectedSession,
                      entry.activeSessionID != nil,
                      entry.attachState != nil,
                      !entry.isRecovering else {
                    return
                }
                entry.controlKeepaliveProbe = entry.controlKeepaliveProbe == UInt64.max
                    ? 1
                    : entry.controlKeepaliveProbe + 1
                let probe = entry.controlKeepaliveProbe
                let clientSendNanoseconds = max(DispatchTime.now().uptimeNanoseconds, 1)
                do {
                    let response = try await self.requestControl(
                        entry: entry,
                        requestType: 0x0005,
                        responseType: 0x0006,
                        fields: ProtocolV3ControlKeepalivePolicy.requestFields(
                            clientSendNanoseconds: clientSendNanoseconds,
                            probe: probe
                        ),
                        timeout: ProtocolV3ControlKeepalivePolicy.responseTimeout
                    )
                    guard ProtocolV3ControlKeepalivePolicy.acceptsResponse(
                        response.fields,
                        clientSendNanoseconds: clientSendNanoseconds,
                        probe: probe
                    ) else {
                        throw ProtocolV3ClientError.invalidMessage("PING response")
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.log?.record(
                        source: "Lumen v3",
                        level: .error,
                        message: "Authenticated control keepalive failed: \(error)."
                    )
                    expectedSession.cancel()
                    return
                }
            }
        }
    }

    private func cancelControlKeepalive(entry: RetainedSession) {
        entry.controlKeepaliveTask?.cancel()
        entry.controlKeepaliveTask = nil
    }

    private func receiveBulkHeader(
        _ header: QUICInboundBulkHeader,
        entry: RetainedSession
    ) {
        if entry.rejectedBulkRequestIDs.remove(header.requestID) != nil {
            entry.session.rejectInboundBulk(requestID: header.requestID, objectID: header.objectID)
            return
        }
        guard entry.bulkHeaders[header.requestID] == nil else {
            entry.session.rejectInboundBulk(requestID: header.requestID, objectID: header.objectID)
            failPendingBulk(
                entry: entry,
                requestID: header.requestID,
                reason: "duplicate ULB3 request ID"
            )
            return
        }
        entry.bulkHeaders[header.requestID] = header
        approveBulkIfMatched(entry: entry, requestID: header.requestID)
    }

    private func receiveBulkObject(
        _ object: QUICInboundBulkObject,
        entry: RetainedSession
    ) {
        let requestID = object.header.requestID
        guard let pending = entry.pendingBulkObjects.removeValue(forKey: requestID),
              bulkHeader(object.header, matches: pending.metadata),
              UInt64(object.payload.count) == pending.metadata.payloadLength,
              Data(SHA256.hash(data: object.payload)) == pending.metadata.sha256 else {
            entry.session.cancel()
            return
        }
        entry.bulkHeaders[requestID] = nil
        entry.rejectedBulkRequestIDs.remove(requestID)
        pending.continuation.yield(.success(object.payload))
        pending.continuation.finish()
    }

    private func receiveBulkFailure(
        _ failure: QUICInboundBulkFailure,
        entry: RetainedSession
    ) {
        guard let requestID = failure.requestID else {
            log?.record(source: "Lumen v3 bulk", level: .warning, message: failure.reason)
            return
        }
        entry.bulkHeaders[requestID] = nil
        failPendingBulk(entry: entry, requestID: requestID, reason: failure.reason)
    }

    private func approveBulkIfMatched(entry: RetainedSession, requestID: UInt64) {
        guard let header = entry.bulkHeaders[requestID],
              let pending = entry.pendingBulkObjects[requestID] else { return }
        guard bulkHeader(header, matches: pending.metadata) else {
            entry.bulkHeaders[requestID] = nil
            entry.session.rejectInboundBulk(requestID: requestID, objectID: header.objectID)
            failPendingBulk(
                entry: entry,
                requestID: requestID,
                reason: "ULB3 header does not match authenticated 0x0203 metadata"
            )
            return
        }
        entry.session.acceptInboundBulk(requestID: requestID, objectID: header.objectID)
    }

    private func bulkHeader(
        _ header: QUICInboundBulkHeader,
        matches metadata: BulkMetadata
    ) -> Bool {
        header.kind == metadata.kind
            && header.objectID == metadata.objectID
            && header.payloadLength == metadata.payloadLength
            && header.sha256 == metadata.sha256
    }

    private func awaitBulkObject(
        entry: RetainedSession,
        requestID: UInt64,
        metadata: BulkMetadata
    ) async throws -> Data {
        let (events, continuation) = AsyncStream<
            Result<Data, ModernLumenV3ManagerError>
        >.makeStream()
        guard entry.pendingBulkObjects.count < 4,
              entry.pendingBulkObjects[requestID] == nil else {
            throw ModernLumenV3ManagerError.bulkTransferFailed("pending stream limit or duplicate request")
        }
        entry.pendingBulkObjects[requestID] = PendingBulkObject(
            metadata: metadata,
            continuation: continuation
        )
        approveBulkIfMatched(entry: entry, requestID: requestID)
        let result = await withTaskGroup(of: Result<Data, ModernLumenV3ManagerError>.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next() ?? .failure(.bulkTransferFailed("stream ended without object"))
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return .failure(.bulkTransferFailed("timed out waiting for payload and FIN"))
            }
            let first = await group.next() ?? .failure(.bulkTransferFailed("missing transfer result"))
            group.cancelAll()
            return first
        }
        if entry.pendingBulkObjects.removeValue(forKey: requestID) != nil {
            continuation.finish()
            rejectBulkHeaderIfPresent(entry: entry, requestID: requestID)
        }
        return try result.get()
    }

    private func rejectBulkHeaderIfPresent(entry: RetainedSession, requestID: UInt64) {
        guard let header = entry.bulkHeaders.removeValue(forKey: requestID) else {
            if entry.rejectedBulkRequestIDs.count < 32 {
                entry.rejectedBulkRequestIDs.insert(requestID)
            }
            return
        }
        entry.session.rejectInboundBulk(requestID: requestID, objectID: header.objectID)
    }

    private func failPendingBulk(
        entry: RetainedSession,
        requestID: UInt64,
        reason: String
    ) {
        guard let pending = entry.pendingBulkObjects.removeValue(forKey: requestID) else { return }
        pending.continuation.yield(.failure(.bulkTransferFailed(reason)))
        pending.continuation.finish()
    }

    private func clearBulkState(entry: RetainedSession, reason: String) {
        for header in entry.bulkHeaders.values {
            entry.session.rejectInboundBulk(
                requestID: header.requestID,
                objectID: header.objectID
            )
        }
        entry.bulkHeaders.removeAll()
        entry.rejectedBulkRequestIDs.removeAll()
        let pending = entry.pendingBulkObjects.values
        entry.pendingBulkObjects.removeAll()
        for object in pending {
            object.continuation.yield(.failure(.bulkTransferFailed(reason)))
            object.continuation.finish()
        }
    }

    private func requestControl(
        entry: RetainedSession,
        requestType: UInt16,
        responseType: UInt16,
        fields: [UInt64: ProtocolV3CBORValue],
        timeout: Duration = .seconds(5)
    ) async throws -> ControlResponse {
        let (responses, continuation) = AsyncStream<
            Result<ControlResponse, ProtocolV3ClientError>
        >.makeStream()
        let requestID = try entry.session.sendControlRequest(type: requestType, fields: fields)
        entry.pendingControlResponses[requestID] = PendingControlResponse(
            expectedType: responseType,
            continuation: continuation
        )
        let result: Result<ControlResponse, Error>
        do {
            let response = try await withThrowingTaskGroup(of: ControlResponse.self) { group in
                group.addTask {
                    var iterator = responses.makeAsyncIterator()
                    guard let result = await iterator.next() else {
                        throw ProtocolV3ClientError.invalidState
                    }
                    return try result.get()
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ProtocolV3ClientError.invalidState
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw ProtocolV3ClientError.invalidState
                }
                return first
            }
            result = .success(response)
        } catch {
            result = .failure(error)
        }
        if entry.pendingControlResponses.removeValue(forKey: requestID) != nil {
            continuation.finish()
            if case .failure = result {
                rejectBulkHeaderIfPresent(entry: entry, requestID: requestID)
            }
        }
        return try result.get()
    }

    private func failPendingControlResponses(hostID: Data, error: ProtocolV3ClientError) {
        guard let entry = sessions[hostID] else { return }
        let pending = entry.pendingControlResponses.values
        entry.pendingControlResponses.removeAll()
        for response in pending {
            response.continuation.yield(.failure(error))
            response.continuation.finish()
        }
    }

    private static func decodeApplicationPage(
        _ fields: [UInt64: ProtocolV3CBORValue]
    ) throws -> (
        status: UInt64,
        revision: UInt64,
        applications: [ModernLumenV3ApplicationRecord],
        nextCursor: UInt64?,
        notModified: Bool
    ) {
        guard Set(fields.keys) == Set(1...5),
              let status = fields[1]?.unsignedValue,
              let revision = fields[2]?.unsignedValue,
              let rawApplications = fields[3]?.arrayValue,
              rawApplications.count <= 128,
              let notModified = fields[5]?.booleanValue else {
            throw ProtocolV3ClientError.invalidMessage("application-list fields")
        }
        let nextCursor: UInt64?
        switch fields[4] {
        case let .unsigned(value): nextCursor = value
        case .null: nextCursor = nil
        default: throw ProtocolV3ClientError.invalidMessage("application-list next cursor")
        }
        let applications = try rawApplications.map { value -> ModernLumenV3ApplicationRecord in
            guard let entry = value.mapValue,
                  Set(entry.keys) == Set(1...7),
                  let rawID = entry[1]?.unsignedValue,
                  let id = Int(exactly: rawID),
                  id > 0,
                  let name = entry[2]?.textValue,
                  !name.isEmpty,
                  name.utf8.count <= 256,
                  name == name.precomposedStringWithCanonicalMapping,
                  let state = entry[3]?.unsignedValue,
                  state <= 3,
                  let flags = entry[4]?.unsignedValue,
                  flags & ~UInt64(0x0f) == 0,
                  let changedRevision = entry[6]?.unsignedValue,
                  changedRevision <= revision,
                  let launchCapabilities = entry[7]?.unsignedValue,
                  launchCapabilities & ~UInt64(0x0f) == 0 else {
                throw ProtocolV3ClientError.invalidMessage("application entry")
            }
            let artworkSHA256: Data?
            switch entry[5] {
            case let .bytes(hash) where hash.count == 32: artworkSHA256 = hash
            case .null: artworkSHA256 = nil
            default: throw ProtocolV3ClientError.invalidMessage("application asset hash")
            }
            return ModernLumenV3ApplicationRecord(
                id: id,
                name: name,
                isRunning: state == 2,
                artworkSHA256: artworkSHA256,
                isHidden: false,
                isDirectLaunch: false
            )
        }
        guard zip(applications, applications.dropFirst()).allSatisfy({ $0.id < $1.id }),
              applications.filter(\.isRunning).count <= 1 else {
            throw ProtocolV3ClientError.invalidMessage("application page ordering")
        }
        return (status, revision, applications, nextCursor, notModified)
    }

    private func waitForAuthentication(
        hostID: Data,
        session: ProtocolV3ClientControlSession,
        timeout: Duration = .seconds(5)
    ) async throws {
        guard let entry = sessions[hostID], entry.session === session else {
            throw ProtocolV3ClientError.invalidState
        }
        if entry.isAuthenticated { return }
        let authenticationEvents = entry.authenticationEvents
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = authenticationEvents.makeAsyncIterator()
                guard let result = await iterator.next() else {
                    throw ProtocolV3ClientError.invalidState
                }
                return try result.get()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProtocolV3ClientError.authenticationFailed
            }
            defer { group.cancelAll() }
            guard try await group.next() != nil else {
                throw ProtocolV3ClientError.invalidState
            }
        }
    }

    private func publishCatalog() {
        do {
            catalogEventHandler?(try displayHosts())
        } catch {
            log?.record(
                source: "Lumen v3",
                level: .error,
                message: "The secure host catalog could not be published: \(error)."
            )
        }
    }

    private static func isScopedLinkLocalIPv6(_ hostname: String) -> Bool {
        var address = hostname.lowercased()
        if address.hasPrefix("["), address.hasSuffix("]") {
            address.removeFirst()
            address.removeLast()
        }
        if let zone = address.firstIndex(of: "%") {
            address = String(address[..<zone])
        }
        guard let firstHextet = address.split(separator: ":", maxSplits: 1).first,
              let value = UInt16(firstHextet, radix: 16) else {
            return false
        }
        return value & 0xffc0 == 0xfe80
    }

    private func handleDiscovery(_ event: ProtocolV3DiscoveryEvent) {
        switch event {
        case let .available(discovered):
            do {
                // Discovery is route metadata only. It can refresh a previously pinned
                // modern host, but it can never create trust or enter the legacy path.
                guard try trustStore.trust(hostID: discovered.hostID) != nil,
                      var record = try hostCatalog.host(hostID: discovered.hostID) else {
                    return
                }
                if Self.isScopedLinkLocalIPv6(discovered.hostname),
                   !Self.isScopedLinkLocalIPv6(record.hostname) {
                    return
                }
                guard record.hostname != discovered.hostname
                    || record.hostnameIsIPLiteral != discovered.hostnameIsIPLiteral
                    || record.port != discovered.port else {
                    return
                }
                record.hostname = discovered.hostname
                record.hostnameIsIPLiteral = discovered.hostnameIsIPLiteral
                record.port = discovered.port
                try hostCatalog.upsert(record)
                publishCatalog()
            } catch {
                log?.record(
                    source: "Lumen v3 discovery",
                    level: .error,
                    message: "A pinned secure-host route could not be updated: \(error). Legacy fallback was not attempted."
                )
            }
        case let .unavailable(hostID):
            // mDNS withdrawal is not proof that a pinned host is offline. Preserve the
            // catalog and trust so manual reconnect remains strict protocol v3.
            if connectionStatuses[hostID] == .online {
                connectionStatuses[hostID] = .unknown
                publishCatalog()
            }
        case let .failed(message):
            log?.record(
                source: "Lumen v3 discovery",
                level: .warning,
                message: "\(message) Pinned secure hosts were preserved; legacy fallback was not attempted."
            )
        }
    }

    private func displayHost(
        _ record: ModernLumenV3HostRecord,
        trust: ProtocolV3TrustRecord?
    ) -> HostDisplayModel {
        let permissions = trust?.grantedPermissions ?? 0
        return HostDisplayModel(
            id: Self.hostID(for: record.hostID),
            name: record.displayName,
            status: connectionStatuses[record.hostID] ?? .unknown,
            isPaired: true,
            hasActiveSession: record.runningApplicationID != nil,
            runningApplicationID: record.runningApplicationID.map(ApplicationID.init),
            canWake: false,
            isServerSupported: permissions & Permission.requiredBase == Permission.requiredBase,
            details: [
                "Status: \((connectionStatuses[record.hostID] ?? .unknown).label)",
                "Pairing: Secure protocol v3 (downgrade disabled)",
                "Address: \(record.hostname):\(record.port)",
                "Granted permissions: 0x\(String(permissions, radix: 16))",
                "Microphone: \(permissions & Permission.microphone != 0 ? "Allowed" : "Not granted")",
                "Remote app quit: \(permissions & Permission.quitApplication != 0 ? "Allowed" : "Not granted")",
            ].joined(separator: "\n")
        )
    }

    /// Repairs a crash between the two independently atomic persistence files.
    /// A trust without its pinned endpoint is unusable and is removed fail-closed;
    /// a catalog row without trust is likewise removed instead of being downgraded.
    private func reconcilePersistedHosts() throws {
        let trusts = try trustStore.allTrusts()
        let records = try hostCatalog.allHosts()
        let trustedIDs = Set(trusts.map(\.hostID))
        let catalogIDs = Set(records.map(\.hostID))
        for hostID in catalogIDs.subtracting(trustedIDs) {
            try hostCatalog.remove(hostID: hostID)
        }
        for hostID in trustedIDs.subtracting(catalogIDs) {
            try trustStore.removeTrust(hostID: hostID)
        }
    }

    private func requireHostRecord(_ hostID: Data) throws -> ModernLumenV3HostRecord {
        _ = try requireTrust(hostID)
        guard let record = try hostCatalog.host(hostID: hostID) else {
            throw UmbraClientServiceError.unavailable(
                "This secure host is no longer paired. Legacy fallback was not attempted."
            )
        }
        return record
    }

    private func requireTrust(_ hostID: Data) throws -> ProtocolV3TrustRecord {
        guard let trust = try trustStore.trust(hostID: hostID) else {
            throw UmbraClientServiceError.unavailable(
                "This secure host is no longer paired. Legacy fallback was not attempted."
            )
        }
        return trust
    }

    private func requirePermission(
        hostID: Data,
        permission: UInt64,
        feature: String
    ) throws {
        guard try hasPermission(hostID: hostID, permission: permission) else {
            throw UmbraClientServiceError.unavailable(
                "The paired host did not grant \(feature). Pair again with that feature enabled; legacy fallback was not attempted."
            )
        }
    }

    private func hasPermission(hostID: Data, permission: UInt64) throws -> Bool {
        guard let trust = try trustStore.trust(hostID: hostID) else { return false }
        return trust.grantedPermissions & permission == permission
    }

    private func requireStreamingDatagramCapacity(
        entry: RetainedSession,
        hostID: Data,
        session: ProtocolV3ClientControlSession
    ) throws {
        guard sessions[hostID] === entry,
              entry.session === session,
              !entry.isRecovering else {
            throw ProtocolV3ClientError.invalidState
        }
        let requiredPayloadByteCount = QUICTransportProfile.semanticDatagramPayloadByteCount
        guard entry.inputDatagramPayloadByteCount >= requiredPayloadByteCount else {
            throw UmbraClientServiceError.unavailable(
                "Secure streaming requires QUIC DATAGRAM support with the complete "
                    + "\(requiredPayloadByteCount)-byte phase-one payload, but this connection negotiated "
                    + "\(entry.inputDatagramPayloadByteCount) bytes (control streams only or insufficient capacity). "
                    + "Pairing and application browsing remain available; no stream was started."
            )
        }
    }

    /// Network.framework makes the admitted control stream ready before its
    /// DATAGRAM child flow finishes opening. Give that initial zero-capacity
    /// state a short grace period, while continuing to reject a negotiated
    /// nonzero-but-insufficient capacity and any later capacity loss immediately.
    private func awaitInitialStreamingDatagramCapacity(
        entry: RetainedSession,
        hostID: Data,
        session: ProtocolV3ClientControlSession
    ) async throws {
        let requiredPayloadByteCount = QUICTransportProfile.semanticDatagramPayloadByteCount
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        while true {
            guard sessions[hostID] === entry,
                  entry.session === session,
                  !entry.isRecovering else {
                throw ProtocolV3ClientError.invalidState
            }
            let availablePayloadByteCount = entry.inputDatagramPayloadByteCount
            if availablePayloadByteCount >= requiredPayloadByteCount { return }
            if availablePayloadByteCount > 0 || ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try requireStreamingDatagramCapacity(entry: entry, hostID: hostID, session: session)
    }

    private func requireProtocolHostID(_ hostID: HostID) throws -> Data {
        guard let value = Self.protocolHostID(from: hostID) else {
            throw UmbraClientServiceError.invalidInput("The selected host is not a protocol-v3 host.")
        }
        return value
    }

    static func hostID(for protocolHostID: Data) -> HostID {
        HostID("v3:" + protocolHostID.map { String(format: "%02x", $0) }.joined())
    }

    static func protocolHostID(from hostID: HostID) -> Data? {
        let value = hostID.rawValue
        guard value.hasPrefix("v3:") else { return nil }
        let hex = value.dropFirst(3)
        guard hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var cursor = hex.startIndex
        for _ in 0..<16 {
            let next = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<next], radix: 16) else { return nil }
            bytes.append(byte)
            cursor = next
        }
        let data = Data(bytes)
        return data.contains(where: { $0 != 0 }) ? data : nil
    }

    private static func uuid(from bytes: Data) -> UUID {
        precondition(bytes.count == 16)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-"
            + "\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-"
            + "\(hex.dropFirst(20))"
        return UUID(uuidString: value)!
    }

    private static func makePairedSession(
        trust: ProtocolV3TrustRecord,
        identity: ProtocolV3ClientIdentity,
        host: String,
        port: UInt16,
        hostnameIsIPLiteral: Bool,
        mode: QUICOptimizationMode
    ) throws -> ProtocolV3ClientControlSession {
        let transport = try NetworkQUICTransport(configuration: .init(
            endpoint: .init(host: host, port: port),
            expectedLeafSPKISHA256: trust.tlsSPKIHash,
            serverName: hostnameIsIPLiteral ? nil : host,
            mode: mode
        ))
        return ProtocolV3ClientControlSession(
            transport: transport,
            identity: identity,
            mode: .paired(trust, replaceExisting: true)
        )
    }

    private static func isRecoverableConnectionLoss(_ event: ProtocolV3ClientEvent) -> Bool {
        switch event {
        case .failed,
             .transport(.stateChanged(.failed)),
             .transport(.stateChanged(.cancelled)):
            true
        default:
            false
        }
    }

    private nonisolated static func mediaExecutorTerminalBarrier(
        for event: ProtocolV3ClientEvent
    ) -> Bool? {
        switch event {
        case let .controlMessage(type, requestID, _)
            where requestID.isMultiple(of: 2) && [0x0140, 0x0142, 0x0144].contains(type):
            false
        case let .transport(.inbound(message)) where message.lane != .control:
            false
        case .transport(.sendDisposition),
             .transport(.pathChanged),
             .transport(.laneWaiting),
             .transport(.datagramFlowWaiting),
             .transport(.abuseCounters),
             .transport(.videoRecoveryRequired):
            false
        case .failed,
             .transport(.mediaSessionEnded),
             .transport(.stateChanged(.failed)),
             .transport(.stateChanged(.cancelled)):
            true
        default:
            nil
        }
    }

    private nonisolated static func waitForTerminalEvent(_ events: AsyncStream<Void>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                _ = await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
