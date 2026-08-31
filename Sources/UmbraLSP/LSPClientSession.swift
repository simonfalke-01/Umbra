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

    /// Connects and pairs with one fresh single-use invitation.
    public func pair(invitation: LSPPairingInvitation) async throws -> LSPTrustRecord {
        guard !invitation.isExpired else { throw LSPControlStatus.authenticationFailed }
        let serverHello = try await connect(endpoint: invitation.endpoint)
        guard serverHello.hostID == invitation.hostID,
              serverHello.hostIdentityKey == invitation.hostIdentityKey,
              serverHello.serverSPKISHA256 == invitation.serverSPKISHA256,
              let clientNonce
        else {
            throw LSPTransportError.spkiMismatch
        }

        let transcript = try LSPControlWire.pairingTranscript(
            hostID: invitation.hostID,
            clientID: identity.clientID,
            invitationID: invitation.invitationID,
            clientNonce: clientNonce,
            serverNonce: serverHello.serverNonce,
            permissions: invitation.offeredPermissions
        )
        let privateKey = try identity.privateKey
        let signature = try privateKey.signature(for: transcript)
        let request = try LSPControlWire.pairRequest(
            clientID: identity.clientID,
            clientIdentityKey: privateKey.publicKey.rawRepresentation,
            invitationID: invitation.invitationID,
            invitationSecret: invitation.invitationSecret,
            clientSignature: signature
        )
        let event = try await transport.request(
            messageType: LSPControlMessageType.pairRequest.rawValue,
            payload: request
        )
        let response = try LSPControlWire.pairResponse(from: event)
        guard response.permissions == invitation.offeredPermissions else {
            throw LSPControlStatus.authenticationFailed
        }
        let hostPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: invitation.hostIdentityKey)
        guard hostPublicKey.isValidSignature(response.serverSignature, for: transcript) else {
            throw LSPControlStatus.authenticationFailed
        }
        state = .authenticated
        return LSPTrustRecord(
            hostID: invitation.hostID,
            hostIdentityKey: invitation.hostIdentityKey,
            dtlsSPKISHA256: invitation.serverSPKISHA256,
            permissions: response.permissions,
            revocationGeneration: UInt64(response.revocationGeneration)
        )
    }

    /// Reconnects and authenticates a previously paired LSP identity.
    public func authenticate(host: LSPHostRecord, trust: LSPTrustRecord) async throws -> LSPTrustRecord {
        guard host.hostID == trust.hostID else { throw LSPTransportError.invalidEndpoint }
        let endpoint = LSPTransportEndpoint(
            host: host.address,
            port: host.port,
            serverSPKISHA256: trust.dtlsSPKISHA256
        )
        let serverHello = try await connect(endpoint: endpoint)
        guard serverHello.hostID == trust.hostID,
              serverHello.hostIdentityKey == trust.hostIdentityKey,
              serverHello.serverSPKISHA256 == trust.dtlsSPKISHA256,
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
              hostPublicKey.isValidSignature(response.serverSignature, for: transcript)
        else {
            throw LSPControlStatus.authenticationFailed
        }
        state = .authenticated
        return LSPTrustRecord(
            hostID: trust.hostID,
            hostIdentityKey: trust.hostIdentityKey,
            dtlsSPKISHA256: trust.dtlsSPKISHA256,
            permissions: response.permissions,
            revocationGeneration: UInt64(response.revocationGeneration)
        )
    }

    /// Lists applications after pairing or reconnect authentication grants browse permission.
    public func listApplications() async throws -> [LSPApplication] {
        guard state == .authenticated || state == .inputActive else { throw LSPTransportError.notAuthenticated }
        let event = try await transport.request(
            messageType: LSPControlMessageType.listApplications.rawValue,
            payload: try LSPControlWire.listApplications()
        )
        return try LSPControlWire.applications(from: event)
    }

    /// Starts the exact input-only vertical slice and installs its native SRTP mapping.
    public func startInput(_ request: LSPInputStartRequest) async throws -> LSPInputStartResponse {
        guard state == .authenticated else { throw LSPTransportError.notAuthenticated }
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
        microphoneConfigurationTerminal = response.microphoneConfiguration == nil
        state = .inputActive
        await drainPendingAudioConfigurations()
        await drainPendingMicrophoneConfigurations()
        await drainPendingVideoConfigurations()
        return response
    }

    /// Transfers an existing input session to this freshly authenticated association.
    public func attach(
        previous: LSPClientSession,
        reason: LSPReconnectReason
    ) async throws -> LSPAttachResponse {
        guard state == .authenticated, let hello else { throw LSPTransportError.notAuthenticated }
        installControlHandlerIfNeeded()
        let prior = try await previous.activeInputAuthority()
        var neutralizationAttempted = false
        do {
            neutralizationAttempted = true
            try previous.neutralizeInput()
        } catch let error as LSPTransportError {
            if reason == .plannedRekey || (error != .notAuthenticated && error != .invalidState) {
                if reason == .plannedRekey, neutralizationAttempted {
                    try await previous.restoreInputAuthority(prior)
                }
                throw error
            }
        }
        do {
            let intentID = UUID()
            let request = LSPAttachRequest(
                sessionID: prior.sessionID,
                attachToken: prior.attachToken,
                intentID: intentID
            )
            let event = try await transport.request(
                messageType: LSPControlMessageType.attach.rawValue,
                payload: try LSPControlWire.attach(request)
            )
            let response = try LSPControlWire.attachResponse(from: event)
            guard response.sessionID == prior.sessionID,
                  response.connectionGeneration == hello.connectionGeneration,
                  event.connectionGeneration == hello.connectionGeneration,
                  response.nativeConfiguration.streamGeneration == prior.nativeConfiguration.streamGeneration,
                  response.nativeConfiguration.inputGeneration != prior.nativeConfiguration.inputGeneration,
                  response.nativeConfiguration.inputSSRC != prior.nativeConfiguration.inputSSRC,
                  response.nativeConfiguration.inputSSRC != prior.nativeConfiguration.acknowledgementSSRC,
                  response.nativeConfiguration.acknowledgementSSRC != prior.nativeConfiguration.inputSSRC,
                  response.nativeConfiguration.acknowledgementSSRC != prior.nativeConfiguration.acknowledgementSSRC,
                  response.audioConfiguration.audioGeneration != prior.audioConfiguration.audioGeneration,
                  response.audioConfiguration.audioSSRC != prior.audioConfiguration.audioSSRC,
                  microphoneAttachSelectionIsValid(response.microphoneConfiguration, prior: prior),
                  response.videoSelection.nativeConfiguration.videoGeneration != prior.videoSelection.nativeConfiguration.videoGeneration,
                  response.videoSelection.nativeConfiguration.primarySSRC != prior.videoSelection.nativeConfiguration.primarySSRC,
                  attachedVideoSelection(response.videoSelection, retains: prior.videoSelection),
                  response.replacementAttachToken != prior.attachToken
            else {
                throw LSPTransportError.internalFailure
            }
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
            microphoneConfigurationTerminal = response.microphoneConfiguration == nil
            pendingRetirementPrevious = previous
            state = .inputActive
            await drainPendingAudioConfigurations()
            await drainPendingMicrophoneConfigurations()
            await drainPendingVideoConfigurations()
            await completePendingRetirementIfReady()
            return response
        } catch {
            let attachError = error
            if reason == .plannedRekey, neutralizationAttempted {
                try await previous.restoreInputAuthority(prior)
            }
            throw attachError
        }
    }

    /// Returns current single-use authority only to the reconnect coordinator.
    public func activeInputAuthority() throws -> LSPActiveInputAuthority {
        guard state == .inputActive, let inputAuthority else {
            throw LSPTransportError.invalidState
        }
        return inputAuthority
    }

    /// Installs a coarse transport lifecycle observer.
    public nonisolated func setTransportLifecycleHandler(
        _ handler: (@Sendable (LSPTransportLifecycle) -> Void)?
    ) {
        transport.setLifecycleHandler(handler)
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

    /// Starts preferred IOHID capture without actor work on physical callbacks.
    public nonisolated func startAppleInputCapture() throws -> LSPAppleInputCapture {
        try transport.startAppleInputCapture()
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
            audioPlayout.stop()
            microphoneUplink.stop(transport: transport)
            state = .stopped
        } catch let error as LSPTransportError {
            try? transport.stop()
            videoPipeline?.stop()
            audioPlayout.stop()
            microphoneUplink.stop(transport: transport)
            state = .failed(error)
            throw error
        } catch {
            try? transport.stop()
            videoPipeline?.stop()
            audioPlayout.stop()
            microphoneUplink.stop(transport: transport)
            state = .failed(.internalFailure)
            throw error
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
            }
        }
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
            try? transport.stop()
            state = .failed(.internalFailure)
            return
        }
        var status = LSPControlStatus.staleGeneration
        if let authority = inputAuthority, let videoPipeline,
           authority.sessionID == request.sessionID {
            var expected = authority.videoSelection.nativeConfiguration
            expected.frameIDOrigin = request.nativeConfiguration.frameIDOrigin
            expected.recoveryEpoch = request.nativeConfiguration.recoveryEpoch
            expected.maximumAccessUnitBytes = request.nativeConfiguration.maximumAccessUnitBytes
            if expected == request.nativeConfiguration {
                do {
                    _ = try videoPipeline.configure(request)
                    status = .success
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
                videoPipeline?.activate()
            }
        } catch {
            if status == .success { videoPipeline?.abortConfiguration() }
            try? transport.stop()
            state = .failed(.internalFailure)
            return
        }
        await completePendingRetirementIfReady()
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
            try? transport.stop()
            state = .failed(.internalFailure)
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
            try? transport.stop()
            state = .failed(.internalFailure)
        }
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
            try? transport.stop()
            state = .failed(.internalFailure)
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
            try? transport.stop()
            state = .failed(.internalFailure)
            return
        }
        if status != .success, inputAuthority?.microphoneRequired == true {
            state = .failed(.internalFailure)
        }
        await completePendingRetirementIfReady()
    }

    private func microphoneCaptureFailed(_ error: Error) {
        _ = error
        microphoneUplink.stop(transport: transport)
        installedMicrophoneGeneration = nil
        if inputAuthority?.microphoneRequired == true {
            try? transport.stop()
            state = .failed(.internalFailure)
        }
    }

    private func completePendingRetirementIfReady() async {
        guard let previous = pendingRetirementPrevious, let authority = inputAuthority else { return }
        let audioReady = installedAudioGeneration == authority.audioConfiguration.audioGeneration
        let microphoneReady = authority.microphoneConfiguration == nil || microphoneConfigurationTerminal
        let videoReady = installedVideoGeneration == authority.videoSelection.nativeConfiguration.videoGeneration
        guard audioReady, microphoneReady, videoReady else { return }
        pendingRetirementPrevious = nil
        await previous.retireAfterAttach()
    }

    private func microphoneAttachSelectionIsValid(
        _ replacement: LSPNativeMicrophoneConfiguration?,
        prior: LSPActiveInputAuthority
    ) -> Bool {
        guard let old = prior.microphoneConfiguration else { return replacement == nil }
        guard let replacement else { return !prior.microphoneRequired }
        return replacement.streamGeneration == old.streamGeneration &&
               replacement.microphoneGeneration != old.microphoneGeneration &&
               replacement.microphoneSSRC != old.microphoneSSRC &&
               replacement.bitrate == old.bitrate &&
               replacement.inbandFEC == old.inbandFEC &&
               replacement.dtx == old.dtx
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
            offer.codec == video.codec && offer.profile == video.profile &&
            offer.width == video.width && offer.height == video.height &&
            offer.refreshNumerator == video.refreshNumerator &&
            offer.refreshDenominator == video.refreshDenominator &&
            video.bitrate > 0 &&
            UInt64(video.bitrate) <= offer.maximumBitsPerSecond
        }
    }

    private func attachedVideoSelection(_ replacement: LSPVideoSelection, retains old: LSPVideoSelection) -> Bool {
        let new = replacement.nativeConfiguration
        let old = old.nativeConfiguration
        return new.streamGeneration == old.streamGeneration &&
            new.videoGeneration != old.videoGeneration && new.primarySSRC != old.primarySSRC &&
            new.primaryPayloadType == old.primaryPayloadType && new.codec == old.codec &&
            new.profile == old.profile && new.width == old.width && new.height == old.height &&
            new.refreshNumerator == old.refreshNumerator && new.refreshDenominator == old.refreshDenominator &&
            new.bitrate == old.bitrate && new.maximumAccessUnitBytes == old.maximumAccessUnitBytes &&
            new.maximumFrameAgeMicroseconds == old.maximumFrameAgeMicroseconds &&
            new.frameIDOrigin == old.frameIDOrigin && new.recoveryEpoch == old.recoveryEpoch &&
            new.decoderSurfaces == old.decoderSurfaces && new.udpPayloadSize == old.udpPayloadSize &&
            new.frameMarkingExtension == old.frameMarkingExtension &&
            new.absoluteCaptureExtension == old.absoluteCaptureExtension &&
            new.frameIDExtension == old.frameIDExtension &&
            new.inputWatermarkExtension == old.inputWatermarkExtension &&
            new.encoderTimingExtension == old.encoderTimingExtension
    }

    public func telemetrySnapshot() throws -> LSPTelemetrySnapshot {
        try transport.telemetrySnapshot()
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
