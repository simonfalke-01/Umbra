import CryptoKit
import Foundation
import UmbraCore
import UmbraLSPTransport

/// Product-visible LSP connection state at application/control frequency.
public enum LSPClientSessionState: Equatable, Sendable {
    case idle
    case connecting
    case authenticated
    case stopped
    case failed(LSPTransportError)
}

/// Coarse LSP client-session coordinator over the native packet/security core.
public actor LSPClientSession {
    public private(set) var state: LSPClientSessionState = .idle
    private let transport: LSPTransport
    private let identity: LSPClientIdentity
    private var hello: LSPServerHello?
    private var clientNonce: Data?

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
        guard state == .authenticated else { throw LSPTransportError.notAuthenticated }
        let event = try await transport.request(
            messageType: LSPControlMessageType.listApplications.rawValue,
            payload: try LSPControlWire.listApplications()
        )
        return try LSPControlWire.applications(from: event)
    }

    /// Stops and destroys transport authority.
    public func stop() throws {
        guard state == .authenticated else { throw LSPTransportError.invalidState }
        do {
            try transport.stop()
            hello = nil
            clientNonce = nil
            state = .stopped
        } catch let error as LSPTransportError {
            state = .failed(error)
            throw error
        }
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
