import CryptoKit
import Foundation
import UmbraCore
import UmbraLSPTransport
import UmbraMedia

/// Product-visible LSP connection state at application/control frequency.
public enum LSPClientSessionState: Equatable, Sendable {
    case idle
    case connecting
    case authenticated
    case inputActive
    case stopped
    case failed(LSPTransportError)
}

/// Reason selecting the same fresh-association ATTACH path.
public enum LSPReconnectReason: Equatable, Sendable {
    case transportLoss
    case plannedRekey
}

/// Observable phases of one fresh-association reconnect transaction.
public enum LSPReconnectPhase: UInt8, Equatable, Sendable {
    case idle
    case candidateHandshake
    case candidateAuthenticated
    case oldCaptureQuiesced
    case attachSubmitted
    case attachCommitted
    case configuring
    case baselineAndMediaReady
    case captureTransferred
    case oldRetired
    case rollbackPending
    case failed
}

/// Low-rate reconnect state suitable for telemetry/UI polling.
public struct LSPReconnectSnapshot: Equatable, Sendable {
    public var phase: LSPReconnectPhase
    public var attemptID: UUID?
    public var phaseStartedAtUptime: TimeInterval
    public var native: LSPNativeHandoffSnapshot?
}

struct LSPAmbiguousAttachFailure: Error, Sendable {
    var prior: LSPActiveInputAuthority
    var successorAttachToken: Data
    var candidateConnectionGeneration: UInt32
    var outcome: LSPAttachOutcome
    var localCommitSucceeded: Bool
}

private struct LSPRollbackCompletedFailure: Error, Sendable {}

private struct LSPPairingContext: Sendable {
    var host: LSPDiscoveredPairingHost
    var serverHello: LSPServerHello
    var pending: LSPPairingPending
    var native: LSPNativePairing
}

enum LSPAttachOutcome: UInt8, Sendable {
    case notSubmitted
    case submittedNoAuthenticatedOutcome
    case authenticatedRejected
    case authenticatedCommitted
}

private final class LSPAttachOutcomeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LSPAttachOutcome = .notSubmitted

    var value: LSPAttachOutcome { lock.withLock { stored } }

    func set(_ value: LSPAttachOutcome) {
        lock.withLock { stored = value }
    }
}

/// Terminal product event emitted once after authenticated stream end or local failure.
public enum LSPClientSessionTermination: Equatable, Sendable {
    case streamEnded(reason: UInt8)
    case failed(LSPTransportError)
}

/// Product-visible remote STOP outcome; local teardown always completes.
public enum LSPRemoteStopResult: Equatable, Sendable {
    case notRunning
    case stopped
    case remoteRejected(LSPControlStatus)
    case transportFailed(LSPTransportError)
}

private struct LSPIncomingObject {
    var totalLength: UInt32
    var sha256: Data
    var bytes: Data
}

final class LSPTerminationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (LSPClientSessionTermination) -> Void)?
    private var terminalEvent: LSPClientSessionTermination?

    func set(_ handler: (@Sendable (LSPClientSessionTermination) -> Void)?) {
        let latched = lock.withLock { () -> LSPClientSessionTermination? in
            self.handler = handler
            return handler == nil ? nil : terminalEvent
        }
        if let handler, let latched { handler(latched) }
    }

    @discardableResult
    func emit(_ event: LSPClientSessionTermination) -> Bool {
        let result = lock.withLock { () -> (Bool, (@Sendable (LSPClientSessionTermination) -> Void)?) in
            guard terminalEvent == nil else { return (false, nil) }
            terminalEvent = event
            return (true, handler)
        }
        guard result.0 else { return false }
        result.1?(event)
        return result.0
    }

    var hasTerminalEvent: Bool {
        lock.withLock { terminalEvent != nil }
    }
}

/// Current single-use session ownership required for ATTACH.
public struct LSPActiveInputAuthority: Equatable, Sendable {
    public var applicationID: String
    public var sessionID: UUID
    public var attachToken: Data
    public var connectionGeneration: UInt32
    public var nativeConfiguration: LSPNativeInputConfiguration
    public var audioConfiguration: LSPNativeAudioConfiguration
    public var microphoneConfiguration: LSPNativeMicrophoneConfiguration?
    public var microphoneRequired: Bool
    public var videoSelection: LSPVideoSelection
}

/// Coarse LSP client-session coordinator over the native packet/security core.
public actor LSPClientSession {
    public private(set) var state: LSPClientSessionState = .idle
    private let transport: LSPTransport
    private let identity: LSPClientIdentity
    private let transportProfile: LSPTransportProfile
    private var hello: LSPServerHello?
    private var clientNonce: Data?
    private var inputAuthority: LSPActiveInputAuthority?
    private let audioPlayout: LSPAudioPlayout
    private let microphoneUplink: LSPMicrophoneUplink
    private let videoPipeline: LSPVideoPipeline?
    private var pendingAudioConfigurations: [LSPControlEvent] = []
    private var controlHandlerInstalled = false
    private var pendingMicrophoneConfigurations: [LSPControlEvent] = []
    private var pendingVideoConfigurations: [LSPControlEvent] = []
    private var installedAudioGeneration: UInt32?
    private var installedMicrophoneGeneration: UInt32?
    private var microphoneConfigurationTerminal = false
    private var installedVideoGeneration: UInt32?
    private var pendingRetirementPrevious: LSPClientSession?
    private var configurationFailure: LSPTransportError?
    private let terminationObserver = LSPTerminationObserver()
    private var reconnectSnapshot = LSPReconnectSnapshot(
        phase: .idle,
        attemptID: nil,
        phaseStartedAtUptime: 0,
        native: nil
    )
    private var captureTransferred = true
    private var pendingNativeHandoff: LSPNativeHandoff?
    private var pairingContext: LSPPairingContext?
    private var authenticatedTrust: LSPTrustRecord?
    private var effectivePermissions: LSPPermission = []
    private var certificateRotationHandler: (@Sendable (LSPTrustRecord) async -> LSPControlStatus)?
    private var incomingObjects: [UUID: LSPIncomingObject] = [:]
    private var completedObjects: [UUID: Data] = [:]
    private var bufferedObjectBytes = 0
    private var deviceRateTelemetry: [String: LSPDeviceRateTelemetry] = [:]
    private var pendingDeviceOffers: [LSPNativeDeviceOffer] = []
    private var reconnectDuration = LSPFixedDurationWindow()
    private var reconnectStartedAtMicroseconds: UInt64?
    private var startInProgress = false

    public init(
        configuration: LSPTransportConfiguration = .init(),
        identity: LSPClientIdentity,
        videoRenderer: (any MetalVideoRendering)? = nil
    ) throws {
        let createdTransport = try LSPTransport(configuration: configuration)
        transport = createdTransport
        self.identity = identity
        transportProfile = configuration.profile
        audioPlayout = LSPAudioPlayout()
        microphoneUplink = LSPMicrophoneUplink()
        if let videoRenderer {
            videoPipeline = LSPVideoPipeline(transport: createdTransport, renderer: videoRenderer)
        } else {
            videoPipeline = nil
        }
        transport.setAudioPacketHandler { [audioPlayout] packet in
            audioPlayout.submit(packet)
        }
        transport.setAudioTimingHandler { [audioPlayout] timing in
            audioPlayout.receiveTiming(timing)
        }
        videoPipeline?.setFailureHandler { [weak self] error in
            Task { await self?.videoGenerationFailed(error) }
        }
    }

    /// Creates a product session from the stable owner-private LSP-only identity store.
    public static func persistent(
        configuration: LSPTransportConfiguration = .init(),
        identityStore: JSONFileStore<LSPClientIdentitySnapshot>,
        videoRenderer: (any MetalVideoRendering)? = nil
    ) async throws -> LSPClientSession {
        let identity = try await LSPPersistence.loadOrCreateClientIdentity(from: identityStore)
        return try LSPClientSession(configuration: configuration, identity: identity, videoRenderer: videoRenderer)
    }

    /// Starts discovered-host PIN pairing and returns the six digits for local display only.
    public func beginPairing(
        host: LSPDiscoveredPairingHost,
        clientName: String = "Umbra",
        requestedPermissions: LSPPermission = [
            .browseApplications,
            .startOrAttach,
            .input,
            .stopOwnStream,
            .controllerOutput,
        ]
    ) async throws -> LSPPairingPrompt {
        try Task.checkCancellation()
        guard pairingContext == nil else { throw LSPControlStatus.busy }
        let serverHello = try await connect(endpoint: host.endpoint)
        try Task.checkCancellation()
        guard serverHello.hostID == host.hostID,
              serverHello.serverSPKISHA256 == host.serverSPKISHA256 else {
            throw LSPTransportError.spkiMismatch
        }
        let native = try transport.makePairing(
            clientID: identity.clientID,
            clientIdentityKey: identity.publicKeyRawRepresentation,
            clientName: clientName,
            requestedPermissions: requestedPermissions.rawValue
        )
        do {
            let material = try native.begin()
            let event = try await transport.request(
                messageType: LSPControlMessageType.pairBegin.rawValue,
                payload: try LSPControlWire.pairBegin(
                    clientID: identity.clientID,
                    clientIdentityKey: identity.publicKeyRawRepresentation,
                    clientName: clientName,
                    clientPairingNonce: material.clientPairingNonce,
                    scryptSalt: material.scryptSalt,
                    clientPublicValue: material.clientPublicValue,
                    requestedPermissions: requestedPermissions
                )
            )
            try Task.checkCancellation()
            if event.flags.contains(.errorResponse) {
                throw try LSPControlWire.controlError(from: event, expectedType: .pairPending)
            }
            let pending = try LSPControlWire.pairPending(from: event)
            guard !pending.permissions.isEmpty,
                  pending.permissions.subtracting(requestedPermissions).isEmpty else {
                throw LSPControlStatus.permissionDenied
            }
            try native.bindPending(
                sessionID: pending.sessionID,
                permissions: pending.permissions.rawValue,
                expiresAtUTCSeconds: pending.expiresAtUTCSeconds
            )
            pairingContext = .init(
                host: host,
                serverHello: serverHello,
                pending: pending,
                native: native
            )
            return .init(
                host: host,
                pin: material.pin,
                expiresAtUTCSeconds: pending.expiresAtUTCSeconds,
                requestedPermissions: requestedPermissions,
                effectivePermissions: pending.permissions
            )
        } catch {
            try? native.cancel()
            state = .failed(.pairingFailed)
            throw error
        }
    }

    /// Polls one active PIN approval and persists nothing until every confirmation verifies.
    public func completePairing() async throws -> LSPTrustRecord {
        guard let pairingContext else { throw LSPTransportError.invalidState }
        do {
            var backoff = Duration.milliseconds(250)
            let challenge: LSPPairingChallenge
            while true {
                try Task.checkCancellation()
                guard UInt64(Date().timeIntervalSince1970) < pairingContext.pending.expiresAtUTCSeconds else {
                    throw LSPTransportError.pairingExpired
                }
                do {
                    let event = try await transport.request(
                        messageType: LSPControlMessageType.pairPoll.rawValue,
                        payload: try LSPControlWire.pairPoll(sessionID: pairingContext.pending.sessionID)
                    )
                    if event.flags.contains(.errorResponse) {
                        let status = try LSPControlWire.controlError(from: event, expectedType: .pairPending)
                        if status == .busy || status == .timeout {
                            try await Task.sleep(for: backoff)
                            backoff = min(backoff * 2, .seconds(2))
                            continue
                        }
                        throw status
                    }
                    if event.messageType == LSPControlMessageType.pairPending.rawValue {
                        let pending = try LSPControlWire.pairPending(from: event)
                        guard pending == pairingContext.pending else {
                            throw LSPTransportError.pairingGenerationMismatch
                        }
                        try await Task.sleep(for: backoff)
                        backoff = min(backoff * 2, .seconds(2))
                        continue
                    }
                    challenge = try LSPControlWire.pairChallenge(from: event)
                    break
                } catch LSPTransportError.timeout {
                    try await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, .seconds(2))
                }
            }

            let confirmation = try pairingContext.native.acceptChallenge(
                sessionID: challenge.sessionID,
                approvalGeneration: challenge.approvalGeneration,
                permissions: challenge.permissions.rawValue,
                expiresAtUTCSeconds: challenge.expiresAtUTCSeconds,
                serverPublicValue: challenge.serverPublicValue
            )
            guard confirmation.sessionID == challenge.sessionID,
                  confirmation.approvalGeneration == challenge.approvalGeneration,
                  confirmation.permissions == challenge.permissions.rawValue,
                  confirmation.expiresAtUTCSeconds == challenge.expiresAtUTCSeconds else {
                throw LSPTransportError.pairingGenerationMismatch
            }
            let clientSignature = try identity.privateKey.signature(for: confirmation.clientSignatureInput)
            let finishEvent = try await transport.request(
                messageType: LSPControlMessageType.pairFinish.rawValue,
                payload: try LSPControlWire.pairFinish(
                    sessionID: confirmation.sessionID,
                    approvalGeneration: confirmation.approvalGeneration,
                    clientConfirmation: confirmation.clientConfirmation,
                    clientSignature: clientSignature
                )
            )
            if finishEvent.flags.contains(.errorResponse) {
                throw try LSPControlWire.controlError(from: finishEvent, expectedType: .pairResult)
            }
            let result = try LSPControlWire.pairResult(from: finishEvent)
            guard result.sessionID == challenge.sessionID,
                  result.approvalGeneration == challenge.approvalGeneration,
                  result.permissions == challenge.permissions else {
                throw LSPTransportError.pairingGenerationMismatch
            }
            let nativeResult = try pairingContext.native.verifyHost(
                sessionID: result.sessionID,
                approvalGeneration: result.approvalGeneration,
                revocationGeneration: result.revocationGeneration,
                serverConfirmation: result.serverConfirmation
            )
            guard nativeResult.sessionID == result.sessionID,
                  nativeResult.approvalGeneration == result.approvalGeneration,
                  nativeResult.permissions == result.permissions.rawValue,
                  nativeResult.revocationGeneration == result.revocationGeneration else {
                throw LSPTransportError.pairingGenerationMismatch
            }
            let hostPublicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: pairingContext.serverHello.hostIdentityKey
            )
            guard hostPublicKey.isValidSignature(result.hostSignature, for: nativeResult.hostSignatureInput) else {
                throw LSPControlStatus.authenticationFailed
            }
            self.pairingContext = nil
            state = .authenticated
            let trust = LSPTrustRecord(
                hostID: pairingContext.host.hostID,
                hostIdentityKey: pairingContext.serverHello.hostIdentityKey,
                dtlsSPKISHA256: pairingContext.host.serverSPKISHA256,
                permissions: result.permissions,
                revocationGeneration: UInt64(result.revocationGeneration)
            )
            authenticatedTrust = trust
            effectivePermissions = trust.permissions
            installControlHandlerIfNeeded()
            return trust
        } catch {
            try? pairingContext.native.cancel()
            self.pairingContext = nil
            state = .failed(error is CancellationError ? .invalidState : .pairingFailed)
            throw error
        }
    }

    /// Cancels the active pairing attempt and zeroizes native PIN material.
    public func cancelPairing() {
        guard let pairingContext else { return }
        try? pairingContext.native.cancel()
        self.pairingContext = nil
        state = .stopped
        try? transport.stop()
    }

    /// Reconnects and authenticates a previously paired LSP identity.
    public func authenticate(
        host: LSPHostRecord,
        trust: LSPTrustRecord,
        serverSPKISHA256: Data? = nil
    ) async throws -> LSPTrustRecord {
        guard host.hostID == trust.hostID else { throw LSPTransportError.invalidEndpoint }
        let selectedSPKI = serverSPKISHA256 ?? trust.pendingDTLSSPKISHA256 ?? trust.dtlsSPKISHA256
        guard selectedSPKI == trust.dtlsSPKISHA256 || selectedSPKI == trust.pendingDTLSSPKISHA256 else {
            throw LSPTransportError.spkiMismatch
        }
        let endpoint = LSPTransportEndpoint(
            host: host.address,
            port: host.port,
            serverSPKISHA256: selectedSPKI
        )
        let serverHello = try await connect(endpoint: endpoint)
        guard serverHello.hostID == trust.hostID,
              serverHello.hostIdentityKey == trust.hostIdentityKey,
              serverHello.serverSPKISHA256 == selectedSPKI,
              let clientNonce
        else {
            throw LSPControlStatus.authenticationFailed
        }
        let transcript = try LSPControlWire.authenticationTranscript(
            hostID: trust.hostID,
            clientID: identity.clientID,
            clientNonce: clientNonce,
            serverNonce: serverHello.serverNonce,
            connectionGeneration: serverHello.connectionGeneration
        )
        let signature = try identity.privateKey.signature(for: transcript)
        let request = try LSPControlWire.authRequest(
            clientID: identity.clientID,
            clientSignature: signature
        )
        let event = try await transport.request(
            messageType: LSPControlMessageType.authRequest.rawValue,
            payload: request
        )
        let response = try LSPControlWire.authResponse(from: event)
        let hostPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: trust.hostIdentityKey)
        guard response.connectionGeneration == serverHello.connectionGeneration,
              hostPublicKey.isValidSignature(response.serverSignature, for: transcript),
              response.isAllowedTransition(from: trust)
        else {
            throw LSPControlStatus.authenticationFailed
        }
        state = .authenticated
        guard var updated = trust.promotingAuthenticatedSPKI(selectedSPKI) else {
            throw LSPTransportError.spkiMismatch
        }
        updated.permissions = response.permissions
        updated.revocationGeneration = UInt64(response.revocationGeneration)
        authenticatedTrust = updated
        effectivePermissions = updated.permissions
        installControlHandlerIfNeeded()
        return updated
    }

    /// Lists applications after pairing or reconnect authentication grants browse permission.
    ///
    /// - Parameter timeout: Bounded wait for the authenticated APPLICATIONS response.
    public func listApplications(timeout: Duration = .seconds(2)) async throws -> [LSPApplication] {
        guard state == .authenticated || state == .inputActive else { throw LSPTransportError.notAuthenticated }
        guard !startInProgress else { throw LSPControlStatus.busy }
        guard effectivePermissions.contains(.browseApplications) else { throw LSPControlStatus.permissionDenied }
        let event = try await transport.request(
            messageType: LSPControlMessageType.listApplications.rawValue,
            payload: try LSPControlWire.listApplications(),
            timeout: timeout
        )
        return try LSPControlWire.applications(from: event)
    }

    /// Starts the exact input-only vertical slice and installs its native SRTP mapping.
    public func startInput(_ request: LSPInputStartRequest) async throws -> LSPInputStartResponse {
        guard state == .authenticated else { throw LSPTransportError.notAuthenticated }
        guard !startInProgress else { throw LSPControlStatus.busy }
        guard effectivePermissions.contains([.startOrAttach, .input]) else {
            throw LSPControlStatus.permissionDenied
        }
        if request.microphoneOffer != nil, !effectivePermissions.contains(.microphone) {
            throw LSPControlStatus.permissionDenied
        }
        startInProgress = true
        defer { startInProgress = false }
        installControlHandlerIfNeeded()
        var resolvedRequest = request
        resolvedRequest.networkProfile = switch transportProfile {
        case .adaptiveLowLatency: 0
        case .competitionLAN: 1
        }
        if resolvedRequest.audioOffers.isEmpty {
            resolvedRequest.audioOffers = switch transportProfile {
            case .adaptiveLowLatency: LSPAudioOffer.adaptiveDefaults
            case .competitionLAN: LSPAudioOffer.competitionDefaults
            }
        }
        let event = try await transport.request(
            messageType: LSPControlMessageType.start.rawValue,
            payload: try LSPControlWire.start(resolvedRequest)
        )
        let response = try LSPControlWire.startResponse(from: event)
        guard videoSelection(response.videoSelection, matches: resolvedRequest) else {
            throw LSPControlStatus.unsupportedMediaTuple
        }
        guard laneIdentifiersAreGloballyUnique(
            input: response.nativeConfiguration,
            audio: response.audioConfiguration,
            microphone: response.microphoneConfiguration,
            video: response.videoSelection.nativeConfiguration
        ) else { throw LSPControlStatus.unsupportedMediaTuple }
        if resolvedRequest.microphoneOffer?.required == true, response.microphoneConfiguration == nil {
            throw LSPControlStatus.unsupportedMediaTuple
        }
        if let selected = response.microphoneConfiguration, let offered = resolvedRequest.microphoneOffer {
            guard selected.bitrate <= offered.maximumBitrate,
                  !selected.inbandFEC || offered.inbandFEC,
                  !selected.dtx || offered.dtx else {
                throw LSPTransportError.internalFailure
            }
        } else if response.microphoneConfiguration != nil {
            throw LSPTransportError.internalFailure
        }
        try transport.configureInput(response.nativeConfiguration)
        guard let hello else { throw LSPTransportError.internalFailure }
        inputAuthority = LSPActiveInputAuthority(
            applicationID: resolvedRequest.applicationID,
            sessionID: response.sessionID,
            attachToken: response.attachToken,
            connectionGeneration: hello.connectionGeneration,
            nativeConfiguration: response.nativeConfiguration,
            audioConfiguration: response.audioConfiguration,
            microphoneConfiguration: response.microphoneConfiguration,
            microphoneRequired: resolvedRequest.microphoneOffer?.required ?? false,
            videoSelection: response.videoSelection
        )
        installedAudioGeneration = nil
        installedMicrophoneGeneration = nil
        installedVideoGeneration = nil
        configurationFailure = nil
        microphoneConfigurationTerminal = response.microphoneConfiguration == nil
        await drainPendingAudioConfigurations()
        await drainPendingMicrophoneConfigurations()
        await drainPendingVideoConfigurations()
        do {
            try await waitForTerminalConfiguration(authority: inputAuthority!)
        } catch let error as LSPTransportError {
            failSession(error)
            throw error
        }
        state = .inputActive
        return response
    }

    /// Retires a browse-only association after the native transport becomes unusable.
    ///
    /// A session that owns or is acquiring input authority is never touched by browse recovery.
    ///
    /// - Parameter error: The native transport failure returned by the browse request.
    /// - Returns: `true` when this browse-only association was retired.
    func retireFailedBrowseAssociation(_ error: LSPTransportError) -> Bool {
        guard Self.canRetireFailedBrowseAssociation(
            state: state,
            hasInputAuthority: inputAuthority != nil,
            startInProgress: startInProgress,
            error: error
        ) else {
            return false
        }
        videoPipeline?.disablePublication()
        try? transport.stop()
        videoPipeline?.retireAfterHandoff()
        resetBulkObjects()
        hello = nil
        clientNonce = nil
        authenticatedTrust = nil
        effectivePermissions = []
        state = .failed(error)
        terminationObserver.emit(.failed(error))
        return true
    }

    static func canRetireFailedBrowseAssociation(
        state: LSPClientSessionState,
        hasInputAuthority: Bool,
        startInProgress: Bool,
        error: LSPTransportError
    ) -> Bool {
        state == .authenticated &&
            !hasInputAuthority &&
            !startInProgress &&
            isRecoverableBrowseFailure(error)
    }

    static func isRecoverableBrowseFailure(_ error: LSPTransportError) -> Bool {
        switch error {
        case .socketFailure, .dtlsFailure, .notAuthenticated, .timeout, .invalidState:
            true
        default:
            false
        }
    }

    /// Sends one reliable UTF-8/IME commit behind the exact applied-edge barrier.
    public func sendText(_ text: String, precedingEdgeID: UInt64) async throws {
        guard state == .inputActive, let authority = inputAuthority else {
            throw LSPTransportError.invalidState
        }
        guard effectivePermissions.contains(.input) else { throw LSPControlStatus.permissionDenied }
        let utf8 = Data(text.utf8)
        guard !utf8.isEmpty, utf8.count <= 16_384, let length = UInt16(exactly: utf8.count) else {
            throw DeterministicCBORError.malformed
        }
        let request: LSPTextInputRequest
        if utf8.count <= 768 {
            request = .init(
                sessionID: authority.sessionID,
                inputGeneration: authority.nativeConfiguration.inputGeneration,
                precedingEdgeID: precedingEdgeID,
                utf8Length: length,
                inlineUTF8: utf8,
                objectID: nil,
                sha256: nil
            )
        } else {
            let objectID = UUID()
            let digest = Data(SHA256.hash(data: utf8))
            try await uploadObject(objectID: objectID, bytes: utf8, sha256: digest)
            request = .init(
                sessionID: authority.sessionID,
                inputGeneration: authority.nativeConfiguration.inputGeneration,
                precedingEdgeID: precedingEdgeID,
                utf8Length: length,
                inlineUTF8: nil,
                objectID: objectID,
                sha256: digest
            )
        }
        let event = try await transport.request(
            messageType: LSPControlMessageType.textInput.rawValue,
            payload: try LSPControlWire.textInput(request)
        )
        try LSPControlWire.requireTextInputResponse(event, request: request)
    }

    /// Sends text behind the newest locally assigned exactly-once input edge.
    public func sendText(_ text: String) async throws {
        guard let authority = inputAuthority else { throw LSPTransportError.invalidState }
        let snapshot = try transport.inputEdgeSnapshot()
        guard snapshot.streamGeneration == authority.nativeConfiguration.streamGeneration,
              snapshot.inputGeneration == authority.nativeConfiguration.inputGeneration else {
            throw LSPTransportError.invalidState
        }
        try await sendText(text, precedingEdgeID: snapshot.latestAssignedEdgeID)
    }

    /// Requests generation-scoped hot-plug input rates without resetting device state.
    public func renegotiateInputRate(_ offer: LSPInputRateOffer) async throws -> LSPInputRateSelection {
        guard state == .inputActive, let authority = inputAuthority,
              offer.sessionID == authority.sessionID,
              offer.inputGeneration == authority.nativeConfiguration.inputGeneration else {
            throw LSPTransportError.invalidState
        }
        guard effectivePermissions.contains(.input) else { throw LSPControlStatus.permissionDenied }
        let event = try await transport.request(
            messageType: LSPControlMessageType.inputRateRequest.rawValue,
            payload: try LSPControlWire.inputRateRequest(offer)
        )
        let selection = try LSPControlWire.inputRateResponse(from: event, offer: offer)
        var updated = authority.nativeConfiguration
        updated.pointerRate = selection.pointerRate
        updated.controllerRate = selection.controllerRate
        updated.sensorRate = selection.aggregateSensorRate
        updated.reconciliationRate = selection.reconciliationRate
        updated.reservedInputWireBitsPerSecond = selection.reservedInputWireBitsPerSecond
        try transport.updateInputRates(updated)
        inputAuthority?.nativeConfiguration = updated
        let key = "\(offer.deviceType.rawValue):\(offer.deviceID):\(offer.instanceGeneration)"
        if offer.kind == .removed {
            deviceRateTelemetry.removeValue(forKey: key)
        } else {
            deviceRateTelemetry[key] = .init(
                kind: offer.kind,
                deviceType: offer.deviceType,
                deviceID: offer.deviceID,
                instanceGeneration: offer.instanceGeneration,
                observedCaptureRate: offer.observedCaptureRate,
                selectedStateRate: selection.stateRate,
                selectedSensorRate: selection.sensorRate
            )
        }
        return selection
    }

    /// Drains every currently queued low-rate native hot-plug/rate event.
    public func drainDeviceOffers() async throws {
        guard state == .inputActive, let authority = inputAuthority else { return }
        while pendingDeviceOffers.count < 32, let offer = try transport.pollDeviceOffer() {
            pendingDeviceOffers.append(offer)
        }
        while let native = pendingDeviceOffers.first {
            guard let deviceType = LSPInputRateDeviceType(rawValue: native.deviceType.rawValue),
                  native.deviceID != 0 else {
                throw LSPTransportError.internalFailure
            }
            let kind: LSPInputRateOffer.Kind = switch native.kind {
            case .arrived: .arrived
            case .removed: .removed
            case .rateObserved: .rateObserved
            }
            let offer = LSPInputRateOffer(
                sessionID: authority.sessionID,
                inputGeneration: authority.nativeConfiguration.inputGeneration,
                kind: kind,
                deviceType: deviceType,
                deviceID: native.deviceID,
                instanceGeneration: native.instanceGeneration,
                observedCaptureRate: native.observedCaptureHz,
                minimumStateRate: native.minimumStateRate,
                maximumStateRate: native.maximumStateRate,
                minimumSensorRate: native.minimumSensorRate,
                maximumSensorRate: native.maximumSensorRate,
                maximumStatePacketBytes: native.maximumStatePacketBytes,
                maximumSensorPacketBytes: native.maximumSensorPacketBytes
            )
            let selection = try await renegotiateInputRate(offer)
            if offer.kind != .removed {
                let key = "\(offer.deviceType.rawValue):\(offer.deviceID):\(offer.instanceGeneration)"
                deviceRateTelemetry[key] = .init(
                    kind: offer.kind,
                    deviceType: offer.deviceType,
                    deviceID: offer.deviceID,
                    instanceGeneration: offer.instanceGeneration,
                    observedCaptureRate: offer.observedCaptureRate,
                    selectedStateRate: selection.stateRate,
                    selectedSensorRate: selection.sensorRate,
                    captureSource: String(describing: native.captureSource),
                    observedSensorRate: native.observedSensorHz,
                    capturedSamples: native.capturedSamples,
                    droppedSamples: native.droppedSamples,
                    attributedWireBytes: native.attributedWireBytes,
                    effectiveWireBitsPerSecond: native.effectiveWireBitsPerSecond,
                    stateSpacing: Self.distribution(native.stateSpacing),
                    sensorSpacing: Self.distribution(native.sensorSpacing)
                )
            }
            pendingDeviceOffers.removeFirst()
        }
    }

    public func deviceRateTelemetrySnapshot() -> [LSPDeviceRateTelemetry] {
        deviceRateTelemetry.values.sorted {
            ($0.deviceType.rawValue, $0.deviceID, $0.instanceGeneration) <
                ($1.deviceType.rawValue, $1.deviceID, $1.instanceGeneration)
        }
    }

    public func productTelemetrySnapshot() -> LSPProductTelemetrySnapshot {
        let video = videoPipeline?.telemetrySnapshot()
        let audio = audioPlayout.telemetrySnapshot()
        return .init(
            videoDecoderStatistics: video?.videoDecoderStatistics,
            hostEncoderDuration: video?.hostEncoderDuration,
            completeFrameReceiveToVideoToolboxSubmit: video?.completeFrameReceiveToVideoToolboxSubmit,
            videoToolboxSubmitToDecodeCompletion: video?.videoToolboxSubmitToDecodeCompletion,
            completeFrameReceiveToMetalEnqueue: video?.completeFrameReceiveToMetalEnqueue,
            metalEnqueueToCommit: video?.metalEnqueueToCommit,
            metalCommitToCompletion: video?.metalCommitToCompletion,
            audioReceiveToDecode: audio.audioReceiveToDecode,
            audioDecodeAndRenderEnqueue: audio.audioDecodeAndRenderEnqueue,
            audioUnderruns: audio.audioUnderruns,
            audioRebuffers: audio.audioRebuffers,
            reconnectDuration: reconnectDuration.snapshot()
        )
    }

    private static func distribution(_ native: LSPNativeDistribution) -> LSPDistributionSnapshot? {
        guard native.flags.contains(.available), native.count > 0 else { return nil }
        let domain: String
        if native.flags.contains(.clientMonotonic) {
            domain = native.flags.contains(.kernelTimestamped)
                ? "client-monotonic/kernel-timestamped" : "client-monotonic"
        } else {
            domain = "unknown"
        }
        return .init(
            count: Int(clamping: native.count),
            p50Microseconds: native.p50Microseconds,
            p95Microseconds: native.p95Microseconds,
            p99Microseconds: native.p99Microseconds,
            maximumMicroseconds: native.maximumMicroseconds,
            drops: native.drops,
            clockDomain: domain
        )
    }

    /// Quits only the application owned by this authenticated session.
    public func quitApplication(applicationID: String) async throws {
        guard state == .inputActive, let authority = inputAuthority else {
            throw LSPTransportError.invalidState
        }
        guard effectivePermissions.contains(.quitApplication) else {
            throw LSPControlStatus.permissionDenied
        }
        let event = try await transport.request(
            messageType: LSPControlMessageType.quitApplication.rawValue,
            payload: try LSPControlWire.quitApplication(
                sessionID: authority.sessionID,
                applicationID: applicationID
            )
        )
        try LSPControlWire.requireQuitApplicationResponse(event, sessionID: authority.sessionID)
    }

    /// Returns one fully authenticated bounded object and removes it from session memory.
    public func takeObject(_ objectID: UUID) -> Data? {
        guard let bytes = completedObjects.removeValue(forKey: objectID) else { return nil }
        bufferedObjectBytes -= bytes.count
        return bytes
    }

    private func uploadObject(objectID: UUID, bytes: Data, sha256: Data) async throws {
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let end = min(offset + 768, bytes.count)
            let chunk = LSPObjectChunk(
                objectID: objectID,
                offset: UInt32(offset),
                totalLength: UInt32(bytes.count),
                bytes: bytes.subdata(in: offset..<end),
                sha256: sha256
            )
            let event = try await transport.request(
                messageType: LSPControlMessageType.objectChunk.rawValue,
                payload: try LSPControlWire.objectChunk(chunk)
            )
            _ = try LSPControlWire.objectChunkAcknowledgement(from: event, chunk: chunk)
            offset = end
        }
    }

    /// Transfers an existing input session to this freshly authenticated association.
    public func attach(
        previous: LSPClientSession,
        reason: LSPReconnectReason,
        presentedAuthority: LSPActiveInputAuthority? = nil,
        neutralizePrevious: Bool = true,
        nativeHandoff: LSPNativeHandoff? = nil
    ) async throws -> LSPAttachResponse {
        try Task.checkCancellation()
        guard state == .authenticated, let hello else { throw LSPTransportError.notAuthenticated }
        installControlHandlerIfNeeded()
        _ = reason
        let prior: LSPActiveInputAuthority
        if let presentedAuthority {
            prior = presentedAuthority
        } else {
            prior = try await previous.activeInputAuthority()
            try Task.checkCancellation()
        }
        let successorToken = try LSPSecureRandom.bytes(count: 32)
        var neutralized = false
        let outcome = LSPAttachOutcomeTracker()
        let effectiveNativeHandoff = nativeHandoff
        var localCommitSucceeded = false
        do {
            if neutralizePrevious {
                if let nativeHandoff {
                    do {
                        try nativeHandoff.neutralize()
                    } catch LSPTransportError.rollbackPending {
                        setReconnectPhase(.rollbackPending)
                        try await nativeHandoff.waitForBaseline(
                            inputGeneration: prior.nativeConfiguration.inputGeneration
                        )
                        throw LSPRollbackCompletedFailure()
                    }
                } else {
                    try previous.neutralizeInput()
                }
                neutralized = true
            }
            try Task.checkCancellation()
            setReconnectPhase(.oldCaptureQuiesced)
            let intentID = UUID()
            let request = LSPAttachRequest(
                sessionID: prior.sessionID,
                attachToken: prior.attachToken,
                intentID: intentID,
                successorAttachToken: successorToken
            )
            let payload = try LSPControlWire.attach(request)
            var receivedEvent: LSPControlEvent?
            var lastRequestError: Error?
            if let nativeHandoff {
                receivedEvent = try await transport.requestAttach(
                    handoff: nativeHandoff,
                    messageType: LSPControlMessageType.attach.rawValue,
                    payload: payload,
                    onSubmissionAccepted: {
                        outcome.set(.submittedNoAuthenticatedOutcome)
                    }
                )
            } else {
                for _ in 0..<3 {
                    do {
                        receivedEvent = try await transport.request(
                        messageType: LSPControlMessageType.attach.rawValue,
                        payload: payload,
                        onSubmissionAccepted: {
                            guard outcome.value == .notSubmitted else { return }
                            outcome.set(.submittedNoAuthenticatedOutcome)
                        }
                    )
                        try Task.checkCancellation()
                        break
                    } catch let error as LSPTransportError
                        where error == .timeout || error == .socketFailure || error == .dtlsFailure {
                        lastRequestError = error
                    }
                }
            }
            guard let event = receivedEvent else {
                throw lastRequestError ?? LSPTransportError.timeout
            }
            setReconnectPhase(.attachSubmitted)
            let response = try LSPControlWire.attachResponse(from: event)
            guard response.sessionID == prior.sessionID,
                  hello.connectionGeneration > prior.connectionGeneration,
                  response.connectionGeneration == hello.connectionGeneration,
                  event.connectionGeneration == hello.connectionGeneration,
                  attachedInputSelection(response.nativeConfiguration, retains: prior.nativeConfiguration),
                  attachedAudioSelection(response.audioConfiguration, retains: prior.audioConfiguration),
                  microphoneAttachSelectionIsValid(response.microphoneConfiguration, prior: prior),
                  response.videoSelection.nativeConfiguration.videoGeneration == advanced(
                      prior.videoSelection.nativeConfiguration.videoGeneration
                  ),
                  response.videoSelection.nativeConfiguration.primarySSRC != prior.videoSelection.nativeConfiguration.primarySSRC,
                  attachedVideoSelection(response.videoSelection, retains: prior.videoSelection),
                  laneIdentifiersAreGloballyUnique(
                      input: response.nativeConfiguration,
                      audio: response.audioConfiguration,
                      microphone: response.microphoneConfiguration,
                      video: response.videoSelection.nativeConfiguration
                  ),
                  response.replacementAttachToken == successorToken
            else {
                throw LSPTransportError.internalFailure
            }
            outcome.set(.authenticatedCommitted)
            setReconnectPhase(.attachCommitted)
            try effectiveNativeHandoff?.commit(inputGeneration: response.nativeConfiguration.inputGeneration)
            localCommitSucceeded = true
            try transport.configureInput(response.nativeConfiguration)
            inputAuthority = LSPActiveInputAuthority(
                applicationID: prior.applicationID,
                sessionID: response.sessionID,
                attachToken: response.replacementAttachToken,
                connectionGeneration: response.connectionGeneration,
                nativeConfiguration: response.nativeConfiguration,
                audioConfiguration: response.audioConfiguration,
                microphoneConfiguration: response.microphoneConfiguration,
                microphoneRequired: prior.microphoneRequired,
                videoSelection: response.videoSelection
            )
            installedAudioGeneration = nil
            installedMicrophoneGeneration = nil
            installedVideoGeneration = nil
            configurationFailure = nil
            microphoneConfigurationTerminal = response.microphoneConfiguration == nil
            pendingRetirementPrevious = previous
            pendingNativeHandoff = effectiveNativeHandoff
            captureTransferred = false
            setReconnectPhase(.configuring)
            await drainPendingAudioConfigurations()
            try Task.checkCancellation()
            await drainPendingMicrophoneConfigurations()
            try Task.checkCancellation()
            await drainPendingVideoConfigurations()
            try Task.checkCancellation()
            try await waitForTerminalConfiguration(authority: inputAuthority!)
            try Task.checkCancellation()
            try await effectiveNativeHandoff?.waitForBaseline(
                inputGeneration: response.nativeConfiguration.inputGeneration
            )
            try Task.checkCancellation()
            state = .inputActive
            setReconnectPhase(.baselineAndMediaReady)
            await completePendingRetirementIfReady()
            return response
        } catch is LSPRollbackCompletedFailure {
            failSession(.rollbackPending)
            setReconnectPhase(.failed)
            throw LSPTransportError.rollbackPending
        } catch let status as LSPControlStatus {
            outcome.set(.authenticatedRejected)
            failSession(.internalFailure)
            if neutralized, presentedAuthority == nil {
                if let effectiveNativeHandoff {
                    setReconnectPhase(.rollbackPending)
                    try await resolveDefiniteRejection(
                        effectiveNativeHandoff,
                        inputGeneration: prior.nativeConfiguration.inputGeneration
                    )
                } else {
                    try await previous.restoreInputAuthority(prior)
                }
            }
            setReconnectPhase(.failed)
            throw status
        } catch {
            let attachOutcome = outcome.value
            if attachOutcome == .notSubmitted || attachOutcome == .authenticatedCommitted {
                failSession((error as? LSPTransportError) ?? .internalFailure)
            }
            if attachOutcome == .notSubmitted, neutralized, presentedAuthority == nil {
                if let effectiveNativeHandoff {
                    setReconnectPhase(.rollbackPending)
                    try await resolveDefiniteRejection(
                        effectiveNativeHandoff,
                        inputGeneration: prior.nativeConfiguration.inputGeneration
                    )
                } else {
                    try await previous.restoreInputAuthority(prior)
                }
            }
            setReconnectPhase(.failed)
            if attachOutcome != .notSubmitted {
                throw LSPAmbiguousAttachFailure(
                    prior: prior,
                    successorAttachToken: successorToken,
                    candidateConnectionGeneration: hello.connectionGeneration,
                    outcome: attachOutcome,
                    localCommitSucceeded: localCommitSucceeded
                )
            }
            throw error
        }
    }

    /// Returns current single-use authority only to the reconnect coordinator.
    public func activeInputAuthority() throws -> LSPActiveInputAuthority {
        guard state == .inputActive, let inputAuthority else {
            throw LSPTransportError.invalidState
        }
        return inputAuthority
    }

    public func reconnectTelemetry() -> LSPReconnectSnapshot {
        var value = reconnectSnapshot
        if let pendingNativeHandoff {
            value.native = try? pendingNativeHandoff.snapshot()
        }
        return value
    }

    public func beginReconnect(attemptID: UUID) {
        setReconnectPhase(.candidateHandshake, attemptID: attemptID)
    }

    public func markCandidateAuthenticated() {
        setReconnectPhase(.candidateAuthenticated)
    }

    public func makeNativeHandoff(
        authority: LSPActiveInputAuthority? = nil
    ) throws -> LSPNativeHandoff {
        let active: LSPActiveInputAuthority
        if let authority {
            active = authority
        } else {
            active = try activeInputAuthority()
        }
        return try LSPNativeHandoff(
            active: transport,
            activeConnectionGeneration: active.connectionGeneration,
            activeInputGeneration: active.nativeConfiguration.inputGeneration
        )
    }

    public func enroll(
        in handoff: LSPNativeHandoff,
        reason: LSPReconnectReason
    ) throws {
        guard let hello else { throw LSPTransportError.notAuthenticated }
        try handoff.begin(
            candidate: transport,
            connectionGeneration: hello.connectionGeneration,
            reason: reason == .plannedRekey ? .plannedRekey : .transportLoss
        )
        try handoff.authenticate(connectionGeneration: hello.connectionGeneration)
    }

    public func markActiveLost(in handoff: LSPNativeHandoff) throws {
        try handoff.markActiveLost(transport)
    }

    /// Completes physical-capture transfer and only then retires the old association.
    public func markCaptureTransferred() async {
        guard state == .inputActive, pendingRetirementPrevious != nil else { return }
        captureTransferred = true
        setReconnectPhase(.captureTransferred)
        await completePendingRetirementIfReady()
    }

    public func invalidateAuthorityAfterAmbiguousAttach() {
        failSession(.invalidState)
    }

    /// Installs a coarse transport lifecycle observer.
    public nonisolated func setTransportLifecycleHandler(
        _ handler: (@Sendable (LSPTransportLifecycle) -> Void)?
    ) {
        transport.setLifecycleHandler(handler)
    }

    /// Installs the coarse terminal stream observer used by the product/UI owner.
    public nonisolated func setTerminationHandler(
        _ handler: (@Sendable (LSPClientSessionTermination) -> Void)?
    ) {
        terminationObserver.set(handler)
    }

    /// Sends one AppKit/IOHID relative-pointer record without actor or Task work per sample.
    public nonisolated func submitPointer(
        sampleTimeMicroseconds: UInt64,
        deltaX: Int64,
        deltaY: Int64,
        verticalScroll: Int64 = 0,
        horizontalScroll: Int64 = 0
    ) throws {
        try transport.submitPointer(
            sampleTimeMicroseconds: sampleTimeMicroseconds,
            deltaX: deltaX,
            deltaY: deltaY,
            verticalScroll: verticalScroll,
            horizontalScroll: horizontalScroll
        )
    }

    /// Sends one AppKit/IOHID keyboard or pointer-button edge synchronously.
    public nonisolated func submitInputEdge(
        sampleTimeMicroseconds: UInt64,
        controlID: UInt16,
        kind: LSPNativeInputEdgeKind
    ) throws {
        try transport.submitInputEdge(
            sampleTimeMicroseconds: sampleTimeMicroseconds,
            controlID: controlID,
            kind: kind
        )
    }

    /// Stops native capture after caller-submitted release edges.
    public nonisolated func neutralizeInput() throws {
        try transport.neutralizeInput()
    }

    /// Restarts the unchanged input mapping with one fresh neutral baseline.
    public nonisolated func restartInputBaseline() throws {
        try transport.restartInputBaseline()
    }

    /// Starts preferred IOHID capture without actor work on physical callbacks.
    public nonisolated func startAppleInputCapture() throws -> LSPAppleInputCapture {
        try transport.startAppleInputCapture()
    }

    /// Starts focused-window AppKit fallback without Swift work on physical callbacks.
    public nonisolated func startAppleAppKitInputCapture() throws -> LSPAppleInputCapture {
        try transport.startAppleAppKitInputCapture()
    }

    /// Stops and destroys transport authority.
    public func stop() async throws {
        guard state == .authenticated || state == .inputActive else { throw LSPTransportError.invalidState }
        videoPipeline?.disablePublication()
        do {
            if let authority = inputAuthority {
                let response = try await transport.request(
                    messageType: LSPControlMessageType.stop.rawValue,
                    payload: try LSPControlWire.stop(sessionID: authority.sessionID)
                )
                try LSPControlWire.requireStopResponse(response)
            }
            try transport.stop()
            videoPipeline?.stop()
            hello = nil
            clientNonce = nil
            inputAuthority = nil
            pendingAudioConfigurations.removeAll(keepingCapacity: true)
            pendingMicrophoneConfigurations.removeAll(keepingCapacity: true)
            pendingVideoConfigurations.removeAll(keepingCapacity: true)
            resetBulkObjects()
            audioPlayout.stop()
            microphoneUplink.stop(transport: transport)
            state = .stopped
        } catch let error as LSPTransportError {
            try? transport.stop()
            videoPipeline?.stop()
            audioPlayout.stop()
            microphoneUplink.stop(transport: transport)
            resetBulkObjects()
            state = .failed(error)
            throw error
        } catch {
            try? transport.stop()
            videoPipeline?.stop()
            audioPlayout.stop()
            microphoneUplink.stop(transport: transport)
            resetBulkObjects()
            state = .failed(.internalFailure)
            throw error
        }
    }

    /// Stops remotely when possible and always completes local teardown with a typed outcome.
    public func stopWithResult() async -> LSPRemoteStopResult {
        guard state == .authenticated || state == .inputActive else { return .notRunning }
        do {
            try await stop()
            return .stopped
        } catch let status as LSPControlStatus {
            return .remoteRejected(status)
        } catch let error as LSPTransportError {
            return .transportFailed(error)
        } catch {
            return .transportFailed(.internalFailure)
        }
    }

    private func retireAfterAttach() {
        videoPipeline?.disablePublication()
        try? transport.stop()
        videoPipeline?.retireAfterHandoff()
        inputAuthority = nil
        pendingAudioConfigurations.removeAll(keepingCapacity: true)
        pendingMicrophoneConfigurations.removeAll(keepingCapacity: true)
        pendingVideoConfigurations.removeAll(keepingCapacity: true)
        resetBulkObjects()
        audioPlayout.stop()
        microphoneUplink.stop(transport: transport)
        hello = nil
        clientNonce = nil
        state = .stopped
    }

    /// Reopens a still-authoritative planned-rekey source with a fresh baseline.
    private func restoreInputAuthority(_ authority: LSPActiveInputAuthority) throws {
        guard state == .inputActive, inputAuthority == authority else {
            throw LSPTransportError.invalidState
        }
        try transport.configureInput(authority.nativeConfiguration)
    }

    private func installControlHandlerIfNeeded() {
        guard !controlHandlerInstalled else { return }
        controlHandlerInstalled = true
        transport.setControlEventHandler { [weak self] event in
            if event.messageType == LSPControlMessageType.audioConfig.rawValue {
                Task { await self?.receiveAudioConfiguration(event) }
            } else if event.messageType == LSPControlMessageType.microphoneConfig.rawValue {
                Task { await self?.receiveMicrophoneConfiguration(event) }
            } else if event.messageType == LSPControlMessageType.videoConfig.rawValue {
                Task { await self?.receiveVideoConfiguration(event) }
            } else if event.messageType == LSPControlMessageType.pathProbe.rawValue {
                Task { await self?.receivePathProbeIntent(event) }
            } else if event.messageType == LSPControlMessageType.streamEnded.rawValue {
                Task { await self?.receiveStreamEnded(event) }
            } else if event.messageType == LSPControlMessageType.objectChunk.rawValue {
                Task { await self?.receiveObjectChunk(event) }
            } else if event.messageType == LSPControlMessageType.certificateRotate.rawValue {
                Task { await self?.receiveCertificateRotation(event) }
            }
        }
        transport.setPathProbeHandler { [weak self] event in
            Task { await self?.handlePathProbeEvent(event) }
        }
    }

    /// Installs the product-owned atomic trust persistence step for signed certificate rotation.
    public func setCertificateRotationHandler(
        _ handler: (@Sendable (LSPTrustRecord) async -> LSPControlStatus)?
    ) {
        certificateRotationHandler = handler
    }

    private func receiveCertificateRotation(_ event: LSPControlEvent) async {
        let rotation: LSPCertificateRotation
        do {
            rotation = try LSPControlWire.certificateRotation(from: event)
        } catch {
            rejectControl(event, responseType: .certificateRotateAck, status: .malformed)
            return
        }
        guard let hello, let trust = authenticatedTrust else {
            rejectControl(event, responseType: .certificateRotateAck, status: .authenticationFailed)
            return
        }
        var status = LSPControlStatus.authenticationFailed
        if rotation.hostID == trust.hostID,
           rotation.connectionGeneration == hello.connectionGeneration,
           (trust.certificateRotationGeneration ?? 0) < UInt32.max,
           rotation.rotationGeneration == (trust.certificateRotationGeneration ?? 0) + 1,
           trust.pendingDTLSSPKISHA256 == nil,
           rotation.newSPKISHA256 != trust.dtlsSPKISHA256,
           let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: trust.hostIdentityKey),
           let transcript = try? LSPControlWire.certificateRotationTranscript(
                rotation: rotation,
                hostIdentityKey: trust.hostIdentityKey,
                currentSPKISHA256: trust.dtlsSPKISHA256
           ),
           publicKey.isValidSignature(rotation.hostSignature, for: transcript),
           let certificateRotationHandler {
            var updated = trust
            updated.pendingDTLSSPKISHA256 = rotation.newSPKISHA256
            updated.certificateRotationGeneration = rotation.rotationGeneration
            status = await certificateRotationHandler(updated)
            if status == .success {
                authenticatedTrust = updated
            }
        }
        do {
            try transport.sendControlResponse(
                messageType: LSPControlMessageType.certificateRotateAck.rawValue,
                requestID: event.requestID,
                payload: status == .success
                    ? try LSPControlWire.certificateRotationAck(status: status, rotation: rotation)
                    : try LSPControlWire.errorResponse(status),
                errorResponse: status != .success
            )
        } catch {
            failSession(.internalFailure)
        }
    }

    private func receiveObjectChunk(_ event: LSPControlEvent) async {
        let chunk: LSPObjectChunk
        do {
            chunk = try LSPControlWire.objectChunk(from: event)
        } catch {
            rejectControl(event, responseType: .objectChunk, status: .malformed)
            return
        }
        guard effectivePermissions.contains(.browseApplications) else {
            do {
                try sendObjectChunkResponse(
                    event: event,
                    chunk: chunk,
                    status: .permissionDenied,
                    nextOffset: chunk.offset
                )
            } catch {
                failSession((error as? LSPTransportError) ?? .internalFailure)
            }
            return
        }
        var status = LSPControlStatus.success
        var nextOffset = chunk.offset
        if completedObjects[chunk.objectID] != nil {
            nextOffset = chunk.totalLength
            do {
                try sendObjectChunkResponse(
                    event: event,
                    chunk: chunk,
                    status: .success,
                    nextOffset: nextOffset
                )
            } catch {
                failSession((error as? LSPTransportError) ?? .internalFailure)
            }
            return
        } else if chunk.offset == 0 {
            if incomingObjects[chunk.objectID] != nil {
                status = .staleGeneration
            } else if incomingObjects.count >= 16 ||
                        bufferedObjectBytes + Int(chunk.totalLength) > 32 * 1_024 * 1_024 {
                status = .busy
            } else {
                incomingObjects[chunk.objectID] = .init(
                    totalLength: chunk.totalLength,
                    sha256: chunk.sha256,
                    bytes: Data()
                )
                bufferedObjectBytes += Int(chunk.totalLength)
            }
        }
        if status == .success, var object = incomingObjects[chunk.objectID] {
            guard object.totalLength == chunk.totalLength,
                  object.sha256 == chunk.sha256,
                  object.bytes.count == Int(chunk.offset) else {
                status = .staleGeneration
                incomingObjects.removeValue(forKey: chunk.objectID)
                bufferedObjectBytes -= Int(object.totalLength)
                do {
                    try sendObjectChunkResponse(
                        event: event,
                        chunk: chunk,
                        status: status,
                        nextOffset: nextOffset
                    )
                } catch {
                    failSession((error as? LSPTransportError) ?? .internalFailure)
                }
                return
            }
            object.bytes.append(chunk.bytes)
            nextOffset = UInt32(object.bytes.count)
            if nextOffset == chunk.totalLength {
                let digest = Data(SHA256.hash(data: object.bytes))
                if digest == object.sha256 {
                    completedObjects[chunk.objectID] = object.bytes
                } else {
                    status = .authenticationFailed
                    bufferedObjectBytes -= Int(object.totalLength)
                }
                incomingObjects.removeValue(forKey: chunk.objectID)
            } else {
                incomingObjects[chunk.objectID] = object
            }
        } else if status == .success {
            status = .staleGeneration
        }
        do {
            try sendObjectChunkResponse(
                event: event,
                chunk: chunk,
                status: status,
                nextOffset: nextOffset
            )
        } catch {
            failSession((error as? LSPTransportError) ?? .internalFailure)
        }
    }

    private func rejectControl(
        _ event: LSPControlEvent,
        responseType: LSPControlMessageType,
        status: LSPControlStatus
    ) {
        guard event.requestID != 0 else {
            failSession(.internalFailure)
            return
        }
        do {
            try transport.sendControlResponse(
                messageType: responseType.rawValue,
                requestID: event.requestID,
                payload: try LSPControlWire.errorResponse(status),
                errorResponse: true
            )
        } catch {
            failSession((error as? LSPTransportError) ?? .internalFailure)
        }
    }

    private func sendObjectChunkResponse(
        event: LSPControlEvent,
        chunk: LSPObjectChunk,
        status: LSPControlStatus,
        nextOffset: UInt32
    ) throws {
        try transport.sendControlResponse(
            messageType: LSPControlMessageType.objectChunk.rawValue,
            requestID: event.requestID,
            payload: status == .success
                ? try LSPControlWire.objectChunkAcknowledgement(
                    status: status,
                    objectID: chunk.objectID,
                    nextOffset: nextOffset,
                    totalLength: chunk.totalLength
                )
                : try LSPControlWire.errorResponse(status),
            errorResponse: status != .success
        )
    }

    private func receiveVideoConfiguration(_ event: LSPControlEvent) async {
        guard inputAuthority != nil else {
            if pendingVideoConfigurations.count < 4 { pendingVideoConfigurations.append(event) }
            return
        }
        await processVideoConfiguration(event)
    }

    private func drainPendingVideoConfigurations() async {
        let pending = pendingVideoConfigurations
        pendingVideoConfigurations.removeAll(keepingCapacity: true)
        for event in pending { await processVideoConfiguration(event) }
    }

    private func processVideoConfiguration(_ event: LSPControlEvent) async {
        guard let request = try? LSPControlWire.videoConfig(from: event) else {
            failSession(.internalFailure)
            return
        }
        var status = LSPControlStatus.staleGeneration
        if let authority = inputAuthority, let videoPipeline,
           authority.sessionID == request.sessionID {
            var expected = authority.videoSelection.nativeConfiguration
            expected.frameIDOrigin = request.nativeConfiguration.frameIDOrigin
            expected.recoveryEpoch = request.nativeConfiguration.recoveryEpoch
            if expected == request.nativeConfiguration {
                do {
                    _ = try videoPipeline.configure(request)
                    status = .success
                } catch is VideoDecoderError {
                    videoPipeline.abortConfiguration()
                    status = .unsupportedMediaTuple
                } catch {
                    videoPipeline.abortConfiguration()
                    status = .internalFailure
                }
            }
        }
        do {
            try transport.sendControlResponse(
                messageType: LSPControlMessageType.videoConfigAck.rawValue,
                requestID: event.requestID,
                payload: try LSPControlWire.videoConfigAck(
                    status: status,
                    sessionID: request.sessionID,
                    videoGeneration: request.nativeConfiguration.videoGeneration,
                    decoderCredit: request.nativeConfiguration.decoderSurfaces
                ),
                errorResponse: status != .success
            )
            if status == .success {
                installedVideoGeneration = request.nativeConfiguration.videoGeneration
                if let previous = pendingRetirementPrevious {
                    await previous.retireVideoAfterAttachAcknowledgement()
                }
                try videoPipeline?.activate()
                try transport.startPathDiscovery()
            } else {
                configurationFailure = status == .unsupportedMediaTuple ? .unsupported : .internalFailure
            }
        } catch {
            if status == .success { videoPipeline?.abortConfiguration() }
            failSession((error as? LSPTransportError) ?? .internalFailure)
            return
        }
        await completePendingRetirementIfReady()
    }

    private func receivePathProbeIntent(_ event: LSPControlEvent) async {
        do {
            let intent = try LSPControlWire.pathProbe(from: event)
            try transport.acceptPathProbe(
                probeID: intent.probeID,
                udpPayloadSize: intent.udpPayloadSize,
                requestID: event.requestID
            )
        } catch {
            try? transport.stop()
            state = .failed(.internalFailure)
        }
    }

    private func handlePathProbeEvent(_ event: LSPPathProbeEvent) async {
        do {
            switch event.kind {
            case .sendIntent:
                let response = try await transport.requestPathProbe(
                    probeID: event.probeID,
                    udpPayloadSize: event.udpPayloadSize,
                    payload: try LSPControlWire.pathProbe(
                        probeID: event.probeID,
                        udpPayloadSize: event.udpPayloadSize
                    )
                )
                let acknowledgement = try LSPControlWire.pathProbeAck(from: response)
                guard acknowledgement.probeID == event.probeID,
                      acknowledgement.udpPayloadSize == event.udpPayloadSize else {
                    throw LSPTransportError.internalFailure
                }
                try transport.confirmPathProbe(
                    probeID: acknowledgement.probeID,
                    receivedPayloadSize: acknowledgement.udpPayloadSize
                )
            case .received:
                guard event.requestID != 0 else { throw LSPTransportError.internalFailure }
                try transport.sendControlResponse(
                    messageType: LSPControlMessageType.pathProbeAck.rawValue,
                    requestID: event.requestID,
                    payload: try LSPControlWire.pathProbeAck(
                        probeID: event.probeID,
                        receivedSize: event.udpPayloadSize
                    )
                )
            case .requestFailed:
                return
            }
        } catch {
            _ = error
        }
    }

    private func receiveAudioConfiguration(_ event: LSPControlEvent) async {
        guard inputAuthority != nil else {
            if pendingAudioConfigurations.count < 4 {
                pendingAudioConfigurations.append(event)
            }
            return
        }
        await processAudioConfiguration(event)
    }

    private func drainPendingAudioConfigurations() async {
        let pending = pendingAudioConfigurations
        pendingAudioConfigurations.removeAll(keepingCapacity: true)
        for event in pending {
            await processAudioConfiguration(event)
        }
    }

    private func processAudioConfiguration(_ event: LSPControlEvent) async {
        let request: LSPAudioConfigurationRequest
        do {
            request = try LSPControlWire.audioConfig(from: event)
        } catch {
            audioPlayout.stop()
            failSession(.internalFailure)
            return
        }
        let status: LSPControlStatus
        if let authority = inputAuthority,
           authority.sessionID == request.sessionID,
           authority.nativeConfiguration.streamGeneration == request.nativeConfiguration.streamGeneration,
           authority.audioConfiguration == request.nativeConfiguration {
            var playoutConfigured = false
            do {
                try audioPlayout.configure(request.nativeConfiguration)
                playoutConfigured = true
                try transport.configureAudio(request.nativeConfiguration)
                status = .success
                installedAudioGeneration = request.nativeConfiguration.audioGeneration
            } catch {
                if playoutConfigured {
                    audioPlayout.stop()
                }
                status = .internalFailure
            }
        } else {
            status = .staleGeneration
        }
        do {
            try transport.sendControlResponse(
                messageType: LSPControlMessageType.audioConfigAck.rawValue,
                requestID: event.requestID,
                payload: try LSPControlWire.audioConfigAck(
                    status: status,
                    sessionID: request.sessionID,
                    audioGeneration: request.nativeConfiguration.audioGeneration
                ),
                errorResponse: status != .success
            )
        } catch {
            if status == .success {
                audioPlayout.stop()
            }
            failSession((error as? LSPTransportError) ?? .internalFailure)
            return
        }
        if status != .success { configurationFailure = .internalFailure }
        await completePendingRetirementIfReady()
    }

    private func receiveMicrophoneConfiguration(_ event: LSPControlEvent) async {
        guard inputAuthority != nil else {
            if pendingMicrophoneConfigurations.count < 4 {
                pendingMicrophoneConfigurations.append(event)
            }
            return
        }
        await processMicrophoneConfiguration(event)
    }

    private func drainPendingMicrophoneConfigurations() async {
        let pending = pendingMicrophoneConfigurations
        pendingMicrophoneConfigurations.removeAll(keepingCapacity: true)
        for event in pending {
            await processMicrophoneConfiguration(event)
        }
    }

    private func processMicrophoneConfiguration(_ event: LSPControlEvent) async {
        let request: LSPMicrophoneConfigurationRequest
        do {
            request = try LSPControlWire.microphoneConfig(from: event)
        } catch {
            microphoneUplink.stop(transport: transport)
            failSession(.internalFailure)
            return
        }
        let status: LSPControlStatus
        if let authority = inputAuthority,
           authority.sessionID == request.sessionID,
           authority.nativeConfiguration.streamGeneration == request.nativeConfiguration.streamGeneration,
           authority.microphoneConfiguration == request.nativeConfiguration {
            do {
                try microphoneUplink.configure(
                    request.nativeConfiguration,
                    transport: transport,
                    failureHandler: { [weak self] error in
                        Task { await self?.microphoneCaptureFailed(error) }
                    }
                )
                status = .success
                installedMicrophoneGeneration = request.nativeConfiguration.microphoneGeneration
            } catch {
                microphoneUplink.stop(transport: transport)
                status = .internalFailure
            }
        } else {
            status = .staleGeneration
        }
        do {
            try transport.sendControlResponse(
                messageType: LSPControlMessageType.microphoneConfigAck.rawValue,
                requestID: event.requestID,
                payload: try LSPControlWire.microphoneConfigAck(
                    status: status,
                    sessionID: request.sessionID,
                    microphoneGeneration: request.nativeConfiguration.microphoneGeneration
                ),
                errorResponse: status != .success
            )
            microphoneConfigurationTerminal = true
        } catch {
            microphoneUplink.stop(transport: transport)
            failSession((error as? LSPTransportError) ?? .internalFailure)
            return
        }
        if status != .success, inputAuthority?.microphoneRequired == true {
            configurationFailure = .internalFailure
        }
        await completePendingRetirementIfReady()
    }

    private func microphoneCaptureFailed(_ error: Error) {
        _ = error
        microphoneUplink.stop(transport: transport)
        installedMicrophoneGeneration = nil
        if inputAuthority?.microphoneRequired == true {
            failSession(.internalFailure)
        }
    }

    private func completePendingRetirementIfReady() async {
        guard let previous = pendingRetirementPrevious, let authority = inputAuthority else { return }
        let audioReady = installedAudioGeneration == authority.audioConfiguration.audioGeneration
        let microphoneReady = authority.microphoneConfiguration == nil || microphoneConfigurationTerminal
        let videoReady = installedVideoGeneration == authority.videoSelection.nativeConfiguration.videoGeneration
        guard audioReady, microphoneReady, videoReady, captureTransferred else { return }
        let nativeHandoff = pendingNativeHandoff
        if let nativeHandoff {
            do {
                try nativeHandoff.retire()
                reconnectSnapshot.native = try nativeHandoff.snapshot()
            } catch {
                reconnectSnapshot.native = try? nativeHandoff.snapshot()
                setReconnectPhase(.failed)
                failSession((error as? LSPTransportError) ?? .internalFailure)
                return
            }
        }
        pendingRetirementPrevious = nil
        pendingNativeHandoff = nil
        await previous.retireAfterAttach()
        setReconnectPhase(.oldRetired)
    }

    private func microphoneAttachSelectionIsValid(
        _ replacement: LSPNativeMicrophoneConfiguration?,
        prior: LSPActiveInputAuthority
    ) -> Bool {
        guard let old = prior.microphoneConfiguration else { return replacement == nil }
        guard let replacement else { return !prior.microphoneRequired }
        return replacement.streamGeneration == old.streamGeneration &&
               replacement.microphoneGeneration == advanced(old.microphoneGeneration) &&
               replacement.microphoneSSRC != old.microphoneSSRC &&
               replacement.microphonePayloadType == old.microphonePayloadType &&
               replacement.bitrate == old.bitrate &&
               replacement.inbandFEC == old.inbandFEC &&
               replacement.dtx == old.dtx &&
               replacement.udpPayloadSize == old.udpPayloadSize
    }

    private func attachedInputSelection(
        _ replacement: LSPNativeInputConfiguration,
        retains old: LSPNativeInputConfiguration
    ) -> Bool {
        replacement.streamGeneration == old.streamGeneration &&
            replacement.inputGeneration == advanced(old.inputGeneration) &&
            replacement.inputSSRC != old.inputSSRC &&
            replacement.inputSSRC != old.acknowledgementSSRC &&
            replacement.acknowledgementSSRC != old.inputSSRC &&
            replacement.acknowledgementSSRC != old.acknowledgementSSRC &&
            replacement.inputPayloadType == old.inputPayloadType &&
            replacement.pointerRate == old.pointerRate &&
            replacement.controllerRate == old.controllerRate &&
            replacement.sensorRate == old.sensorRate &&
            replacement.reconciliationRate == old.reconciliationRate &&
            replacement.reservedInputWireBitsPerSecond == old.reservedInputWireBitsPerSecond &&
            replacement.baselineRequired
    }

    private func attachedAudioSelection(
        _ replacement: LSPNativeAudioConfiguration,
        retains old: LSPNativeAudioConfiguration
    ) -> Bool {
        replacement.streamGeneration == old.streamGeneration &&
            replacement.audioGeneration == advanced(old.audioGeneration) &&
            replacement.audioSSRC != old.audioSSRC &&
            replacement.audioPayloadType == old.audioPayloadType &&
            replacement.channels == old.channels &&
            replacement.streams == old.streams &&
            replacement.coupledStreams == old.coupledStreams &&
            replacement.mapping == old.mapping &&
            replacement.frameSamples == old.frameSamples &&
            replacement.bitrate == old.bitrate &&
            replacement.inbandFEC == old.inbandFEC &&
            replacement.dtx == old.dtx &&
            replacement.udpPayloadSize == old.udpPayloadSize
    }

    private func retireVideoAfterAttachAcknowledgement() {
        videoPipeline?.disablePublication()
        videoPipeline?.retireAfterHandoff()
    }

    private func videoSelection(_ selection: LSPVideoSelection, matches request: LSPInputStartRequest) -> Bool {
        let video = selection.nativeConfiguration
        guard video.decoderSurfaces == request.decoderSurfaces,
              video.maximumFrameAgeMicroseconds > 0,
              video.maximumFrameAgeMicroseconds <= request.maximumCaptureToPresentMicroseconds else { return false }
        return request.videoOffers.contains { offer in
            offer.codec.rawValue == video.codec && offer.profile.rawValue == video.profile &&
            offer.pixelFormat.rawValue == video.pixelFormat &&
            offer.color.colorPrimaries == video.colorPrimaries &&
            offer.color.transferCharacteristics == video.transferCharacteristics &&
            offer.color.matrixCoefficients == video.matrixCoefficients &&
            offer.color.fullRange == video.fullRange &&
            offer.delivery.rawValue == video.delivery &&
            offer.width == video.width && offer.height == video.height &&
            offer.refreshNumerator == video.refreshNumerator &&
            offer.refreshDenominator == video.refreshDenominator &&
            video.bitrate > 0 &&
            UInt64(video.bitrate) <= offer.maximumBitsPerSecond &&
            video.maximumAccessUnitBytes <= offer.maximumAccessUnitBytes &&
            (video.flexFECSSRC == 0 || offer.supportsFlexFEC) &&
            (video.rtxSSRC == 0 || offer.supportsRTX)
        }
    }

    private func attachedVideoSelection(_ replacement: LSPVideoSelection, retains old: LSPVideoSelection) -> Bool {
        let new = replacement.nativeConfiguration
        let old = old.nativeConfiguration
        return new.streamGeneration == old.streamGeneration &&
            new.videoGeneration != old.videoGeneration && new.primarySSRC != old.primarySSRC &&
            new.primaryPayloadType == old.primaryPayloadType && new.codec == old.codec &&
            new.profile == old.profile && new.pixelFormat == old.pixelFormat &&
            new.colorPrimaries == old.colorPrimaries &&
            new.transferCharacteristics == old.transferCharacteristics &&
            new.matrixCoefficients == old.matrixCoefficients && new.fullRange == old.fullRange &&
            new.delivery == old.delivery && new.payloadFormat == old.payloadFormat &&
            new.width == old.width && new.height == old.height &&
            new.refreshNumerator == old.refreshNumerator && new.refreshDenominator == old.refreshDenominator &&
            new.bitrate == old.bitrate && new.maximumAccessUnitBytes == old.maximumAccessUnitBytes &&
            new.maximumFrameAgeMicroseconds == old.maximumFrameAgeMicroseconds &&
            new.frameIDOrigin == old.frameIDOrigin && new.recoveryEpoch == old.recoveryEpoch &&
            new.decoderSurfaces == old.decoderSurfaces && new.udpPayloadSize == old.udpPayloadSize &&
            new.frameMarkingExtension == old.frameMarkingExtension &&
            new.absoluteCaptureExtension == old.absoluteCaptureExtension &&
            new.frameIDExtension == old.frameIDExtension &&
            new.inputWatermarkExtension == old.inputWatermarkExtension &&
            new.encoderTimingExtension == old.encoderTimingExtension &&
            ((old.flexFECSSRC == 0 && new.flexFECSSRC == 0) ||
             (old.flexFECSSRC != 0 && new.flexFECSSRC != 0 && new.flexFECSSRC != old.flexFECSSRC)) &&
            new.flexFECPayloadType == old.flexFECPayloadType &&
            new.flexFECRepairWindowMicroseconds == old.flexFECRepairWindowMicroseconds &&
            new.flexFECMaximumGroupPackets == old.flexFECMaximumGroupPackets &&
            ((old.rtxSSRC == 0 && new.rtxSSRC == 0) ||
             (old.rtxSSRC != 0 && new.rtxSSRC != 0 && new.rtxSSRC != old.rtxSSRC)) &&
            new.rtxPayloadType == old.rtxPayloadType &&
            new.rtxAssociatedPayloadType == old.rtxAssociatedPayloadType
    }

    private func waitForTerminalConfiguration(authority: LSPActiveInputAuthority) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while true {
            if case .failed(let error) = state { throw error }
            if let configurationFailure { throw configurationFailure }
            let audioReady = installedAudioGeneration == authority.audioConfiguration.audioGeneration
            let videoReady = installedVideoGeneration == authority.videoSelection.nativeConfiguration.videoGeneration
            let microphoneReady: Bool
            if let microphone = authority.microphoneConfiguration {
                microphoneReady = microphoneConfigurationTerminal &&
                    (!authority.microphoneRequired || installedMicrophoneGeneration == microphone.microphoneGeneration)
            } else {
                microphoneReady = true
            }
            if audioReady, videoReady, microphoneReady { return }
            guard clock.now < deadline else { throw LSPTransportError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func laneIdentifiersAreGloballyUnique(
        input: LSPNativeInputConfiguration,
        audio: LSPNativeAudioConfiguration,
        microphone: LSPNativeMicrophoneConfiguration?,
        video: LSPNativeVideoConfiguration
    ) -> Bool {
        var ssrcs = [
            input.inputSSRC,
            input.acknowledgementSSRC,
            audio.audioSSRC,
            video.primarySSRC,
        ]
        var payloadTypes = [
            input.inputPayloadType,
            audio.audioPayloadType,
            video.primaryPayloadType,
        ]
        if let microphone {
            ssrcs.append(microphone.microphoneSSRC)
            payloadTypes.append(microphone.microphonePayloadType)
        }
        if video.flexFECSSRC != 0 {
            ssrcs.append(video.flexFECSSRC)
            payloadTypes.append(video.flexFECPayloadType)
        }
        if video.rtxSSRC != 0 {
            ssrcs.append(video.rtxSSRC)
            payloadTypes.append(video.rtxPayloadType)
        }
        return Set(ssrcs).count == ssrcs.count && Set(payloadTypes).count == payloadTypes.count
    }

    private func receiveStreamEnded(_ event: LSPControlEvent) {
        guard !terminationObserver.hasTerminalEvent else { return }
        guard let ended = try? LSPControlWire.streamEnded(from: event),
              ended.sessionID == inputAuthority?.sessionID,
              ended.streamGeneration == inputAuthority?.nativeConfiguration.streamGeneration else {
            failSession(.internalFailure)
            return
        }
        videoPipeline?.disablePublication()
        try? transport.stop()
        videoPipeline?.stop()
        audioPlayout.stop()
        microphoneUplink.stop(transport: transport)
        inputAuthority = nil
        resetBulkObjects()
        state = .stopped
        terminationObserver.emit(.streamEnded(reason: ended.reason))
    }

    private func videoGenerationFailed(_ error: LSPTransportError) {
        failSession(error)
    }

    private func failSession(_ error: LSPTransportError) {
        if terminationObserver.hasTerminalEvent || state == .stopped { return }
        if case .failed = state { return }
        videoPipeline?.disablePublication()
        try? transport.stop()
        videoPipeline?.stop()
        audioPlayout.stop()
        microphoneUplink.stop(transport: transport)
        resetBulkObjects()
        state = .failed(error)
        terminationObserver.emit(.failed(error))
    }

    private func resetBulkObjects() {
        incomingObjects.removeAll(keepingCapacity: true)
        completedObjects.removeAll(keepingCapacity: true)
        bufferedObjectBytes = 0
        pendingDeviceOffers.removeAll(keepingCapacity: true)
        deviceRateTelemetry.removeAll(keepingCapacity: true)
    }

    private func setReconnectPhase(_ phase: LSPReconnectPhase, attemptID: UUID? = nil) {
        let now = max(1, UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000))
        if phase == .candidateHandshake {
            reconnectStartedAtMicroseconds = now
        } else if phase == .oldRetired, let started = reconnectStartedAtMicroseconds, now >= started {
            reconnectDuration.record(now - started)
            reconnectStartedAtMicroseconds = nil
        } else if phase == .failed {
            reconnectDuration.drop()
            reconnectStartedAtMicroseconds = nil
        }
        reconnectSnapshot = .init(
            phase: phase,
            attemptID: attemptID ?? reconnectSnapshot.attemptID,
            phaseStartedAtUptime: ProcessInfo.processInfo.systemUptime,
            native: reconnectSnapshot.native
        )
    }

    private func advanced(_ generation: UInt32) -> UInt32? {
        generation == UInt32.max ? nil : generation + 1
    }

    private func resolveDefiniteRejection(
        _ handoff: LSPNativeHandoff,
        inputGeneration: UInt32
    ) async throws {
        do {
            try handoff.cancelDefiniteRejection()
        } catch LSPTransportError.rollbackPending {
            // Expected after producer neutralization; the exact old generation
            // remains closed until its new baseline is authenticated.
        }
        let snapshot = try handoff.snapshot()
        if snapshot.baselineRequired {
            try await handoff.waitForBaseline(inputGeneration: inputGeneration)
        }
    }

    public func telemetrySnapshot() throws -> LSPTelemetrySnapshot {
        try transport.telemetrySnapshot()
    }

    public func nativeTimingSnapshot() throws -> LSPNativeTimingSnapshot {
        try transport.nativeTimingSnapshot()
    }

    private func connect(endpoint: LSPTransportEndpoint) async throws -> LSPServerHello {
        guard state == .idle || state == .stopped else {
            throw LSPTransportError.invalidState
        }
        state = .connecting
        do {
            try transport.start(endpoint: endpoint)
            let nonce = try LSPSecureRandom.bytes(count: 32)
            let event = try await transport.request(
                messageType: LSPControlMessageType.clientHello.rawValue,
                payload: try LSPControlWire.clientHello(clientNonce: nonce)
            )
            let response = try LSPControlWire.serverHello(from: event)
            guard response.serverSPKISHA256 == endpoint.serverSPKISHA256 else {
                throw LSPTransportError.spkiMismatch
            }
            try transport.bindHostHello(
                connectionGeneration: response.connectionGeneration,
                hostID: response.hostID,
                hostIdentityKey: response.hostIdentityKey,
                serverSPKISHA256: response.serverSPKISHA256,
                clientNonce: nonce,
                serverNonce: response.serverNonce
            )
            clientNonce = nonce
            hello = response
            return response
        } catch let error as LSPTransportError {
            state = .failed(error)
            throw error
        } catch {
            state = .failed(.internalFailure)
            throw error
        }
    }
}
