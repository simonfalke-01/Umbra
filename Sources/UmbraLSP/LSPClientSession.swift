import CryptoKit
import Foundation
import UmbraCore
import UmbraLSPTransport

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
}

/// Coarse LSP client-session coordinator over the native packet/security core.
public actor LSPClientSession {
    public private(set) var state: LSPClientSessionState = .idle
    private let transport: LSPTransport
    private let identity: LSPClientIdentity
    private var hello: LSPServerHello?
    private var clientNonce: Data?
    private var inputAuthority: LSPActiveInputAuthority?

    public init(
        configuration: LSPTransportConfiguration = .init(),
        identity: LSPClientIdentity
    ) throws {
        transport = try LSPTransport(configuration: configuration)
        self.identity = identity
    }

    /// Creates a product session from the stable owner-private LSP-only identity store.
    public static func persistent(
        configuration: LSPTransportConfiguration = .init(),
        identityStore: JSONFileStore<LSPClientIdentitySnapshot>
    ) async throws -> LSPClientSession {
        let identity = try await LSPPersistence.loadOrCreateClientIdentity(from: identityStore)
        return try LSPClientSession(configuration: configuration, identity: identity)
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
        let event = try await transport.request(
            messageType: LSPControlMessageType.start.rawValue,
            payload: try LSPControlWire.start(request)
        )
        let response = try LSPControlWire.startResponse(from: event)
        try transport.configureInput(response.nativeConfiguration)
        guard let hello else { throw LSPTransportError.internalFailure }
        inputAuthority = LSPActiveInputAuthority(
            applicationID: request.applicationID,
            sessionID: response.sessionID,
            attachToken: response.attachToken,
            connectionGeneration: hello.connectionGeneration,
            nativeConfiguration: response.nativeConfiguration
        )
        state = .inputActive
        return response
    }

    /// Transfers an existing input session to this freshly authenticated association.
    public func attach(
        previous: LSPClientSession,
        reason: LSPReconnectReason
    ) async throws -> LSPAttachResponse {
        guard state == .authenticated, let hello else { throw LSPTransportError.notAuthenticated }
        let prior = try await previous.activeInputAuthority()
        do {
            try previous.neutralizeInput()
        } catch let error as LSPTransportError {
            if reason == .plannedRekey || (error != .notAuthenticated && error != .invalidState) {
                throw error
            }
        }
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
            nativeConfiguration: response.nativeConfiguration
        )
        state = .inputActive
        await previous.retireAfterAttach()
        return response
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
    public func stop() throws {
        guard state == .authenticated || state == .inputActive else { throw LSPTransportError.invalidState }
        do {
            try transport.stop()
            hello = nil
            clientNonce = nil
            inputAuthority = nil
            state = .stopped
        } catch let error as LSPTransportError {
            state = .failed(error)
            throw error
        }
    }

    private func retireAfterAttach() {
        try? transport.stop()
        inputAuthority = nil
        hello = nil
        clientNonce = nil
        state = .stopped
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
