import CryptoKit
import Foundation
import UmbraQUICTransport

public enum ProtocolV3ClientError: LocalizedError, Equatable, Sendable {
    case invalidState
    case invalidMessage(String)
    case authenticationFailed
    case startRejected(UInt8)

    public var errorDescription: String? {
        switch self {
        case .invalidState:
            "The secure protocol-v3 session is not ready for this operation."
        case let .invalidMessage(context):
            "Lumen sent an invalid protocol-v3 message (\(context))."
        case .authenticationFailed:
            "Secure protocol-v3 authentication failed. "
                + "Pair the host again if its identity or authorization changed."
        case let .startRejected(status):
            Self.startRejectionDescription(status)
        }
    }

    private static func startRejectionDescription(_ status: UInt8) -> String {
        let reason = switch status {
        case 1: "the START request was malformed"
        case 2: "the client is not authenticated"
        case 3: "the paired client is not authorized to start streams"
        case 4: "the START authorization expired"
        case 5: "the START intent was already consumed"
        case 6: "the client and host protocol versions do not match"
        case 7: "the requested capabilities are not available"
        case 8:
            "Lumen is busy with another stream or lifecycle transition; "
                + "stop the active stream or wait for it to finish, then try again"
        case 9: "the selected application no longer exists; refresh the application list and try again"
        case 10: "the requested video, audio, HDR, or fidelity mode is unsupported by the host"
        case 11: "Lumen could not activate a required display, encoder, audio, or application resource"
        case 12: "Lumen encountered an internal stream-start failure"
        default: "Lumen returned an unknown START failure"
        }
        return "Secure stream START was rejected because \(reason) (status \(status))."
    }
}

public struct ProtocolV3ClientIdentity: @unchecked Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey
    public let publicKey: Data
    public let clientID: Data
    var privateSeedData: Data { privateKey.rawRepresentation }

    public init(privateSeed: Data) throws {
        guard privateSeed.count == 32 else { throw ProtocolV3WireError.invalidField("Ed25519 seed") }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(privateSeed))
        let publicKey = privateKey.publicKey.rawRepresentation
        self.privateKey = privateKey
        self.publicKey = publicKey
        clientID = Data(SHA256.hash(data: publicKey).prefix(16))
    }

    public static func generate() throws -> Self {
        try Self(privateSeed: secureRandomBytes(count: 32))
    }

    func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message)
    }

    public static func secureRandomBytes(count: Int) throws -> Data {
        guard count > 0 else { throw ProtocolV3WireError.invalidField("random byte count") }
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

public enum ProtocolV3AuthenticationMode: Sendable {
    case invitation(
        ProtocolV3PairingInvitation,
        requestedPermissions: UInt64,
        displayName: String,
        pairAttemptID: Data
    )
    case paired(ProtocolV3TrustRecord, replaceExisting: Bool)
}

public enum ProtocolV3ClientEvent: Sendable {
    case transport(QUICTransportEvent)
    case trustEstablished(ProtocolV3TrustRecord, endpoint: QUICTransportEndpoint)
    case authenticated(
        permissions: UInt64,
        authorityGeneration: UInt64,
        serverCapabilities: UInt64
    )
    case activeSessionAvailable(Data)
    case startAccepted(sessionID: Data, fields: [UInt64: ProtocolV3CBORValue])
    case lateStartAccepted(requestID: UInt64, sessionID: Data, fields: [UInt64: ProtocolV3CBORValue])
    case controlMessage(type: UInt16, requestID: UInt64, fields: [UInt64: ProtocolV3CBORValue])
    case bulkHeader(QUICInboundBulkHeader)
    case bulkObject(QUICInboundBulkObject)
    case bulkFailure(QUICInboundBulkFailure)
    case failed(ProtocolV3ClientError)
}

public final class ProtocolV3ClientControlSession: @unchecked Sendable {
    private struct HostRequest {
        let type: UInt16
        let payload: Data
        var response: (type: UInt16, fields: [UInt64: ProtocolV3CBORValue], isError: Bool)?
    }
    private enum State {
        case idle
        case serverHello
        case authorization
        case ready
        case starting
        case streaming
        case stopping
        case closed
    }

    private let transport: any QUICTransportProtocol
    private let identity: ProtocolV3ClientIdentity
    private let mode: ProtocolV3AuthenticationMode
    private let codec = ProtocolV3CBORCodec()
    private let randomBytes: @Sendable (Int) throws -> Data
    private let trustPersistence: (any ProtocolV3TrustPersisting)?
    private let queue = DispatchQueue(label: "app.umbra.protocol-v3.control")
    private var state: State = .idle
    private var clientHello = Data()
    private var serverHello = Data()
    private var authorizationRequest = Data()
    private var attemptID = Data()
    private var clientNonce = Data()
    private var liveSPKI = Data()
    private var expectedHostID = Data()
    private var expectedHostPublicKey = Data()
    private var permissions: UInt64 = 0
    private var serverCapabilities: UInt64 = 0
    private var nextRequestID: UInt64 = 5
    private var pendingRequests: [UInt64: UInt16] = [:]
    private var hostRequests: [UInt64: HostRequest] = [:]
    private var startRequestID: UInt64?
    private var cancelledStartRequests = Set<UInt64>()
    private var activeSessionID: Data?
    private var eventHandler: (@Sendable (ProtocolV3ClientEvent) -> Void)?

    public init(
        transport: any QUICTransportProtocol,
        identity: ProtocolV3ClientIdentity,
        mode: ProtocolV3AuthenticationMode,
        trustPersistence: (any ProtocolV3TrustPersisting)? = nil,
        randomBytes: @escaping @Sendable (Int) throws -> Data = ProtocolV3ClientIdentity.secureRandomBytes
    ) {
        self.transport = transport
        self.identity = identity
        self.mode = mode
        self.trustPersistence = trustPersistence
        self.randomBytes = randomBytes
    }

    public func setEventHandler(_ handler: (@Sendable (ProtocolV3ClientEvent) -> Void)?) {
        queue.sync { eventHandler = handler }
    }

    public var canBeginStart: Bool {
        queue.sync { state == .ready }
    }

    public func start() throws {
        try queue.sync {
            guard state == .idle else { throw ProtocolV3ClientError.invalidState }
            transport.authenticationHandler = { [weak self] handoff in
                guard let session = self else { return }
                session.queue.async { session.beginAuthentication(handoff) }
            }
            transport.eventHandler = { [weak self] event in
                guard let session = self else { return }
                session.queue.async { session.handle(event) }
            }
            state = .serverHello
            try transport.start()
        }
    }

    public func startStream(fields: [UInt64: ProtocolV3CBORValue]) {
        queue.async { [weak self] in
            guard let self else { return }
            do { _ = try beginStartOnQueue(fields: fields) }
            catch { fail(.invalidMessage("START request")) }
        }
    }

    @discardableResult
    public func beginStart(fields: [UInt64: ProtocolV3CBORValue]) throws -> UInt64 {
        try queue.sync { try beginStartOnQueue(fields: fields) }
    }

    private func beginStartOnQueue(fields: [UInt64: ProtocolV3CBORValue]) throws -> UInt64 {
        guard state == .ready else { throw ProtocolV3ClientError.invalidState }
        try Self.validateStartRequest(fields)
        let requestID = try allocateRequestID(type: 0x0100)
        startRequestID = requestID
        state = .starting
        try send(type: 0x0100, requestID: requestID, fields: fields)
        return requestID
    }

    public func cancelStart(requestID: UInt64) throws {
        try queue.sync {
            guard state == .starting, startRequestID == requestID,
                  pendingRequests[requestID] == 0x0100,
                  cancelledStartRequests.count < 32 else {
                throw ProtocolV3ClientError.invalidState
            }
            cancelledStartRequests.insert(requestID)
            startRequestID = nil
            state = .ready
        }
    }

    @discardableResult
    public func sendControlRequest(
        type: UInt16,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws -> UInt64 {
        try queue.sync {
            guard state == .ready || state == .streaming else { throw ProtocolV3ClientError.invalidState }
            let requestID = try allocateRequestID(type: type)
            try send(type: type, requestID: requestID, fields: fields)
            return requestID
        }
    }

    @discardableResult
    public func stop(fields: [UInt64: ProtocolV3CBORValue]) throws -> UInt64 {
        try sendControlRequest(type: 0x0130, fields: fields)
    }

    public func sendControlResponse(
        type: UInt16,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue],
        isError: Bool = false
    ) throws {
        try queue.sync {
            guard state == .ready || state == .streaming,
                  requestID != 0, requestID.isMultiple(of: 2) else {
                throw ProtocolV3ClientError.invalidState
            }
            guard var request = hostRequests[requestID], type == request.type + 1 else {
                throw ProtocolV3ClientError.invalidMessage("unknown v3 host request")
            }
            if let cached = request.response {
                guard cached.type == type, cached.fields == fields, cached.isError == isError else {
                    throw ProtocolV3ClientError.invalidMessage("conflicting v3 host response")
                }
            } else {
                request.response = (type, fields, isError)
                hostRequests[requestID] = request
            }
            try send(
                type: type,
                requestID: requestID,
                flags: isError ? 0x03 : 0x01,
                fields: fields
            )
        }
    }

    public func sendDatagram(
        lane: QUICSemanticLane,
        sessionID: Data,
        channel: UInt8,
        kind: UInt8,
        flags: UInt8 = 0,
        objectID: UInt64,
        payload: Data,
        deadlineNanoseconds: UInt64? = nil,
        supersessionKey: UInt64? = nil
    ) {
        queue.async { [weak self] in
            guard let self, state == .streaming, sessionID.count == 16 else {
                self?.fail(.invalidState)
                return
            }
            transport.send(.init(
                lane: lane,
                payload: payload,
                deadlineNanoseconds: deadlineNanoseconds,
                supersessionKey: supersessionKey,
                wireMetadata: .datagram(
                    sessionID: sessionID,
                    channel: channel,
                    kind: kind,
                    flags: flags,
                    objectID: objectID
                )
            ))
        }
    }

    public func acceptInboundBulk(requestID: UInt64, objectID: UInt64) {
        transport.acceptInboundBulk(requestID: requestID, objectID: objectID)
    }

    public func rejectInboundBulk(requestID: UInt64, objectID: UInt64) {
        transport.rejectInboundBulk(requestID: requestID, objectID: objectID)
    }

    public func cancel() {
        queue.async { [weak self] in
            self?.state = .closed
            self?.transport.cancel()
        }
    }

    private func beginAuthentication(_ handoff: QUICApplicationAuthenticationHandoff) {
        guard state == .serverHello else { fail(.invalidState); return }
        do {
            liveSPKI = handoff.leafSPKISHA256
            clientNonce = try randomBytes(32)
            switch mode {
            case let .invitation(_, _, _, pairAttemptID): attemptID = pairAttemptID
            case .paired: attemptID = try randomBytes(16)
            }
            guard clientNonce.contains(where: { $0 != 0 }), attemptID.contains(where: { $0 != 0 }) else {
                throw ProtocolV3ClientError.authenticationFailed
            }
            let identityField: ProtocolV3CBORValue
            let invitationField: ProtocolV3CBORValue
            switch mode {
            case let .invitation(invitation, _, _, _):
                guard invitation.tlsSPKIHash == liveSPKI else { throw ProtocolV3ClientError.authenticationFailed }
                expectedHostID = invitation.hostID
                expectedHostPublicKey = invitation.hostPublicKey
                identityField = .null
                invitationField = .bytes(invitation.invitationID)
            case let .paired(record, _):
                guard record.minimumProtocol == 3, !record.legacyFallbackAllowed,
                      record.tlsSPKIHash == liveSPKI,
                      record.clientID == identity.clientID else {
                    throw ProtocolV3ClientError.authenticationFailed
                }
                expectedHostID = record.hostID
                expectedHostPublicKey = record.hostPublicKey
                identityField = .bytes(identity.clientID)
                invitationField = .null
            }
            let fields: [UInt64: ProtocolV3CBORValue] = [
                1: .unsigned(3), 2: .unsigned(3), 3: .bytes(clientNonce),
                4: .unsigned(0x17f), 5: .array([.unsigned(1), .unsigned(2)]),
                6: identityField, 7: invitationField, 8: .bytes(attemptID),
            ]
            clientHello = try frame(type: 0x0001, requestID: 1, flags: 0, fields: fields)
            try send(type: 0x0001, requestID: 1, fields: fields)
        } catch {
            fail(.authenticationFailed)
        }
    }

    private func handle(_ event: QUICTransportEvent) {
        switch event {
        case let .bulkHeader(header):
            eventHandler?(.bulkHeader(header))
            return
        case let .bulkObject(object):
            eventHandler?(.bulkObject(object))
            return
        case let .bulkFailure(failure):
            eventHandler?(.bulkFailure(failure))
            return
        default:
            break
        }
        eventHandler?(.transport(event))
        guard case let .inbound(message) = event, message.lane == .control else { return }
        do {
            guard let type = message.controlType, let flags = message.controlFlags,
                  let requestID = message.requestID else {
                throw ProtocolV3ClientError.invalidMessage("control metadata")
            }
            let complete = try frame(type: type, requestID: requestID, flags: flags, payload: message.payload)
            guard case let .map(fields) = try codec.decode(message.payload) else {
                throw ProtocolV3ClientError.invalidMessage("control payload")
            }
            switch state {
            case .serverHello:
                try receiveServerHello(type: type, flags: flags, requestID: requestID, fields: fields, complete: complete)
            case .authorization:
                try receiveAuthorization(type: type, flags: flags, requestID: requestID, fields: fields, complete: complete)
            case .starting:
                if cancelledStartRequests.contains(requestID) {
                    try receiveLateStart(type: type, flags: flags, requestID: requestID, fields: fields)
                } else {
                    try receiveStart(type: type, flags: flags, requestID: requestID, fields: fields)
                }
            case .ready, .streaming, .stopping:
                if cancelledStartRequests.contains(requestID) {
                    try receiveLateStart(type: type, flags: flags, requestID: requestID, fields: fields)
                } else {
                    try receiveAuthenticatedControl(type: type, flags: flags, requestID: requestID, fields: fields)
                }
            default:
                throw ProtocolV3ClientError.invalidState
            }
        } catch let error as ProtocolV3ClientError {
            fail(error)
        } catch {
            fail(.invalidMessage("v3 control"))
        }
    }

    private func receiveServerHello(
        type: UInt16,
        flags: UInt8,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue],
        complete: Data
    ) throws {
        guard type == 0x0002, flags == 1, requestID == 1, Set(fields.keys) == Set(1...8),
              fields[1]?.unsignedValue == 3,
              let nonce = fields[2]?.bytesValue, nonce.count == 32, nonce.contains(where: { $0 != 0 }),
              fields[3]?.bytesValue == expectedHostID,
              fields[4]?.bytesValue == expectedHostPublicKey,
              fields[5]?.bytesValue == liveSPKI,
              let rawCapabilities = fields[6]?.unsignedValue,
              let capabilities = Self.validatedServerCapabilities(rawCapabilities),
              fields[7]?.unsignedValue == UInt64(QUICTransportProfile.semanticDatagramByteCount),
              fields[8]?.bytesValue == attemptID
        else { throw ProtocolV3ClientError.authenticationFailed }
        serverCapabilities = capabilities
        serverHello = complete
        transport.applicationHelloDidComplete(success: true)
        state = .authorization
        try sendAuthorization()
    }

    private func sendAuthorization() throws {
        switch mode {
        case let .invitation(invitation, requested, displayName, _):
            guard !displayName.isEmpty, displayName.utf8.count <= 64,
                  requested != 0, requested & ~UInt64(0xff) == 0 else {
                throw ProtocolV3ClientError.authenticationFailed
            }
            var fields: [UInt64: ProtocolV3CBORValue] = [
                1: .bytes(invitation.invitationID), 2: .bytes(invitation.invitationToken),
                3: .bytes(invitation.sha256), 4: .bytes(attemptID),
                5: .bytes(identity.clientID), 6: .bytes(identity.publicKey),
                7: .text(displayName.precomposedStringWithCanonicalMapping), 8: .unsigned(requested),
            ]
            let unsigned = try frame(type: 0x0010, requestID: 3, flags: 0, fields: fields)
            let signature = try identity.sign(
                transcript(domain: "lumen/3 pair client\0", frames: [clientHello, serverHello, unsigned])
            )
            fields[9] = .bytes(signature)
            authorizationRequest = try frame(type: 0x0010, requestID: 3, flags: 0, fields: fields)
            try send(type: 0x0010, requestID: 3, fields: fields)
        case let .paired(_, replaceExisting):
            var fields: [UInt64: ProtocolV3CBORValue] = [
                1: .bytes(identity.clientID), 2: .bytes(attemptID), 3: .boolean(replaceExisting),
            ]
            let unsigned = try frame(type: 0x0003, requestID: 3, flags: 0, fields: fields)
            let signature = try identity.sign(
                transcript(domain: "lumen/3 auth client\0", frames: [clientHello, serverHello, unsigned])
            )
            fields[4] = .bytes(signature)
            authorizationRequest = try frame(type: 0x0003, requestID: 3, flags: 0, fields: fields)
            try send(type: 0x0003, requestID: 3, fields: fields)
        }
    }

    private func receiveAuthorization(
        type: UInt16,
        flags: UInt8,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue],
        complete: Data
    ) throws {
        guard flags == 1, requestID == 3, fields[1]?.unsignedValue == 0 else {
            throw ProtocolV3ClientError.authenticationFailed
        }
        switch mode {
        case .invitation:
            guard type == 0x0011, Set(fields.keys) == Set(1...9),
                  fields[2]?.bytesValue == expectedHostID,
                  fields[3]?.bytesValue == expectedHostPublicKey,
                  fields[4]?.bytesValue == identity.clientID,
                  let granted = fields[5]?.unsignedValue, granted != 0, granted & ~UInt64(0xff) == 0,
                  fields[6]?.unsignedValue == 3, fields[7]?.bytesValue == attemptID,
                  let generation = fields[8]?.unsignedValue, generation != 0,
                  let signature = fields[9]?.bytesValue, signature.count == 64
            else { throw ProtocolV3ClientError.authenticationFailed }
            var unsignedFields = fields
            unsignedFields.removeValue(forKey: 9)
            let unsigned = try frame(type: type, requestID: requestID, flags: 1, fields: unsignedFields)
            let hostKey = try Curve25519.Signing.PublicKey(rawRepresentation: expectedHostPublicKey)
            guard hostKey.isValidSignature(
                signature,
                for: transcript(
                    domain: "lumen/3 pair host\0",
                    frames: [clientHello, serverHello, authorizationRequest, unsigned]
                )
            ) else { throw ProtocolV3ClientError.authenticationFailed }
            let trust = try ProtocolV3TrustRecord(
                hostID: expectedHostID, hostPublicKey: expectedHostPublicKey,
                tlsSPKIHash: liveSPKI, clientID: identity.clientID,
                grantedPermissions: granted, pairingGeneration: generation
            )
            guard let trustPersistence,
                  case let .invitation(invitation, _, _, _) = mode else {
                throw ProtocolV3ClientError.authenticationFailed
            }
            try trustPersistence.commitPairing(
                identity: identity,
                trust: trust,
                invitationID: invitation.invitationID,
                attemptID: attemptID
            )
            permissions = granted
            state = .ready
            transport.applicationAuthenticationDidComplete(success: true)
            eventHandler?(.trustEstablished(
                trust,
                endpoint: .init(host: invitation.hostname, port: invitation.port)
            ))
            eventHandler?(.authenticated(
                permissions: granted,
                authorityGeneration: generation,
                serverCapabilities: serverCapabilities
            ))
        case .paired:
            let activeSessionID: Data?
            if fields[5] == .null {
                activeSessionID = nil
            } else if let value = fields[5]?.bytesValue,
                      value.count == 16, value.contains(where: { $0 != 0 }) {
                activeSessionID = value
            } else {
                throw ProtocolV3ClientError.authenticationFailed
            }
            guard type == 0x0004, Set(fields.keys) == Set(1...7),
                  fields[2]?.bytesValue == identity.clientID,
                  let granted = fields[3]?.unsignedValue, granted != 0, granted & ~UInt64(0xff) == 0,
                  let authority = fields[4]?.unsignedValue, authority != 0,
                  fields[6]?.bytesValue == attemptID,
                  let signature = fields[7]?.bytesValue, signature.count == 64
            else { throw ProtocolV3ClientError.authenticationFailed }
            var unsignedFields = fields
            unsignedFields.removeValue(forKey: 7)
            let unsigned = try frame(type: type, requestID: requestID, flags: 1, fields: unsignedFields)
            let hostKey = try Curve25519.Signing.PublicKey(rawRepresentation: expectedHostPublicKey)
            guard hostKey.isValidSignature(
                signature,
                for: transcript(
                    domain: "lumen/3 auth host\0",
                    frames: [clientHello, serverHello, authorizationRequest, unsigned]
                )
            ) else { throw ProtocolV3ClientError.authenticationFailed }
            permissions = granted
            if let activeSessionID {
                try transport.setActiveSessionID(activeSessionID)
                self.activeSessionID = activeSessionID
                state = .streaming
            } else {
                state = .ready
            }
            transport.applicationAuthenticationDidComplete(success: true)
            if let activeSessionID {
                eventHandler?(.activeSessionAvailable(activeSessionID))
            }
            eventHandler?(.authenticated(
                permissions: granted,
                authorityGeneration: authority,
                serverCapabilities: serverCapabilities
            ))
        }
        _ = complete
    }

    private func receiveStart(
        type: UInt16,
        flags: UInt8,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws {
        guard type == 0x0101, flags == 1, requestID == startRequestID,
              Set(fields.keys) == Set(1...23),
              let status = fields[1]?.unsignedValue, status <= UInt64(UInt8.max)
        else { throw ProtocolV3ClientError.invalidMessage("START response") }
        guard status == 0 else { throw ProtocolV3ClientError.startRejected(UInt8(status)) }
        guard permissions & (1 << 1) != 0,
              let sessionID = fields[3]?.bytesValue, sessionID.count == 16,
              sessionID.contains(where: { $0 != 0 }),
              fields[11]?.unsignedValue == UInt64(QUICTransportProfile.semanticDatagramByteCount)
        else { throw ProtocolV3ClientError.invalidMessage("START selection") }
        try transport.setActiveSessionID(sessionID)
        activeSessionID = sessionID
        pendingRequests.removeValue(forKey: requestID)
        startRequestID = nil
        state = .streaming
        eventHandler?(.startAccepted(sessionID: sessionID, fields: fields))
    }

    private func receiveLateStart(
        type: UInt16,
        flags: UInt8,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws {
        guard type == 0x0101, flags == 1, cancelledStartRequests.remove(requestID) != nil,
              pendingRequests.removeValue(forKey: requestID) == 0x0100,
              Set(fields.keys) == Set(1...23),
              let status = fields[1]?.unsignedValue, status <= UInt64(UInt8.max) else {
            throw ProtocolV3ClientError.invalidMessage("late START response")
        }
        guard status == 0 else {
            guard fields[19]?.arrayValue?.isEmpty == true,
                  (3...18).allSatisfy({ fields[UInt64($0)] == .null }),
                  (20...23).allSatisfy({ fields[UInt64($0)] == .null }) else {
                throw ProtocolV3ClientError.invalidMessage("late START failure")
            }
            eventHandler?(.controlMessage(type: type, requestID: requestID, fields: fields))
            return
        }
        guard let sessionID = fields[3]?.bytesValue, sessionID.count == 16,
              sessionID.contains(where: { $0 != 0 }),
              fields[11]?.unsignedValue == UInt64(QUICTransportProfile.semanticDatagramByteCount) else {
            throw ProtocolV3ClientError.invalidMessage("late START selection")
        }
        try transport.setActiveSessionID(sessionID)
        activeSessionID = sessionID
        state = .streaming
        eventHandler?(.lateStartAccepted(requestID: requestID, sessionID: sessionID, fields: fields))
    }

    private func receiveAuthenticatedControl(
        type: UInt16,
        flags: UInt8,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws {
        if requestID == 0 {
            guard flags == 0, state == .streaming || state == .stopping else {
                throw ProtocolV3ClientError.invalidMessage("v3 event authority")
            }
            if type == 0x0132 {
                guard Set(fields.keys) == Set(1...2),
                      fields[1]?.bytesValue == activeSessionID,
                      let reason = fields[2]?.unsignedValue,
                      (1...7).contains(reason) else {
                    throw ProtocolV3ClientError.invalidMessage("SESSION_STOPPING")
                }
            } else if type == 0x0200 {
                guard Self.isValidTelemetryBatch(fields, activeSessionID: activeSessionID) else {
                    throw ProtocolV3ClientError.invalidMessage("TELEMETRY_BATCH")
                }
            } else if type != 0x0133 {
                throw ProtocolV3ClientError.invalidMessage("unsupported v3 event")
            }
        } else if requestID.isMultiple(of: 2) {
            guard state == .streaming, flags == 0, [0x0140, 0x0142, 0x0144].contains(type),
                  type != 0x0144 || permissions & (1 << 3) != 0 else {
                throw ProtocolV3ClientError.invalidMessage("v3 host request flags")
            }
            let payload = try codec.encode(.map(fields))
            if let existing = hostRequests[requestID] {
                guard existing.type == type, existing.payload == payload else {
                    throw ProtocolV3ClientError.invalidMessage("conflicting v3 host request reuse")
                }
                if let response = existing.response {
                    try send(
                        type: response.type,
                        requestID: requestID,
                        flags: response.isError ? 0x03 : 0x01,
                        fields: response.fields
                    )
                }
                return
            }
            guard hostRequests.count < 32 else { throw ProtocolV3ClientError.invalidState }
            hostRequests[requestID] = HostRequest(type: type, payload: payload, response: nil)
        } else {
            guard flags & 1 != 0, let requestType = pendingRequests.removeValue(forKey: requestID) else {
                throw ProtocolV3ClientError.invalidMessage("v3 response authority")
            }
            guard requestType < UInt16.max, type == requestType + 1 else {
                throw ProtocolV3ClientError.invalidMessage("v3 response type")
            }
            if requestType == 0x0130, type == 0x0131, fields[1]?.unsignedValue == 0 {
                try transport.setActiveSessionID(nil)
                hostRequests.removeAll(keepingCapacity: false)
                pendingRequests.removeAll(keepingCapacity: false)
                startRequestID = nil
                state = .stopping
            } else if requestType == 0x0102, type == 0x0103, fields[1]?.unsignedValue == 0 {
                guard Set(fields.keys) == Set(1...6),
                      let sessionID = fields[2]?.bytesValue, sessionID.count == 16,
                      sessionID.contains(where: { $0 != 0 }),
                      fields[3]?.unsignedValue != nil,
                      fields[4]?.unsignedValue != nil,
                      fields[5]?.booleanValue != nil,
                      fields[6]?.mapValue != nil else {
                    throw ProtocolV3ClientError.invalidMessage("ATTACH response")
                }
                try transport.setActiveSessionID(sessionID)
                activeSessionID = sessionID
                state = .streaming
            }
        }
        if type == 0x0133 {
            guard requestID == 0, Set(fields.keys) == Set(1...8),
                  let endedSessionID = fields[1]?.bytesValue,
                  endedSessionID == activeSessionID,
                  let reason = fields[2]?.unsignedValue,
                  (1...7).contains(reason),
                  fields[3]?.unsignedValue != nil,
                  fields[4]?.booleanValue != nil,
                  fields[5]?.unsignedValue != nil,
                  fields[6]?.unsignedValue != nil,
                  fields[7]?.unsignedValue != nil,
                  fields[8]?.unsignedValue != nil else {
                throw ProtocolV3ClientError.invalidMessage("SESSION_ENDED")
            }
            try transport.setActiveSessionID(nil)
            activeSessionID = nil
            hostRequests.removeAll()
            state = .ready
        }
        eventHandler?(.controlMessage(type: type, requestID: requestID, fields: fields))
    }

    private func allocateRequestID(type: UInt16) throws -> UInt64 {
        guard pendingRequests.count < 32, nextRequestID <= UInt64.max - 2 else {
            throw ProtocolV3ClientError.invalidState
        }
        let requestID = nextRequestID
        nextRequestID += 2
        pendingRequests[requestID] = type
        return requestID
    }

    private func send(
        type: UInt16,
        requestID: UInt64,
        flags: UInt8 = 0,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws {
        let payload = try codec.encode(.map(fields))
        transport.send(.init(
            lane: .control,
            payload: payload,
            wireMetadata: .control(flags: flags, type: type, requestID: requestID)
        ))
    }

    private func frame(
        type: UInt16,
        requestID: UInt64,
        flags: UInt8,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws -> Data {
        try frame(type: type, requestID: requestID, flags: flags, payload: codec.encode(.map(fields)))
    }

    private func frame(type: UInt16, requestID: UInt64, flags: UInt8, payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= 1_048_576 else {
            throw ProtocolV3ClientError.invalidMessage("frame size")
        }
        var output = Data("ULC3".utf8)
        output.append(3)
        output.append(flags)
        append(type, to: &output)
        append(requestID, to: &output)
        append(UInt32(payload.count), to: &output)
        append(UInt32(0), to: &output)
        output.append(payload)
        return output
    }

    private func transcript(domain: String, frames: [Data]) -> Data {
        var output = Data(domain.utf8)
        output.append(liveSPKI)
        for frame in frames {
            append(UInt32(frame.count), to: &output)
            output.append(frame)
        }
        return output
    }

    private func fail(_ error: ProtocolV3ClientError) {
        guard state != .closed else { return }
        let failedState = state
        state = .closed
        if failedState == .serverHello {
            transport.applicationHelloDidComplete(success: false)
        } else if failedState == .authorization {
            transport.applicationAuthenticationDidComplete(success: false)
        }
        transport.cancel()
        eventHandler?(.failed(error))
    }

    private static func validateStartRequest(_ fields: [UInt64: ProtocolV3CBORValue]) throws {
        guard Set(fields.keys) == Set(1...18),
              let intent = fields[1]?.bytesValue, intent.count == 16, intent.contains(where: { $0 != 0 }),
              let app = fields[2]?.unsignedValue, app <= UInt64(UInt32.max),
              [1, 2].contains(fields[3]?.unsignedValue),
              let width = fields[4]?.unsignedValue, (320...7_680).contains(width), width.isMultiple(of: 2),
              let height = fields[5]?.unsignedValue, (200...4_320).contains(height), height.isMultiple(of: 2),
              fields[12]?.unsignedValue == UInt64(QUICTransportProfile.semanticDatagramByteCount),
              let trace = fields[13]?.bytesValue, trace.count == 16, trace.contains(where: { $0 != 0 }),
              fields[18]?.booleanValue != nil
        else { throw ProtocolV3ClientError.invalidMessage("START fields") }
    }

    static func validatedServerCapabilities(_ capabilities: UInt64) -> UInt64? {
        capabilities & UInt64(0x17f) == UInt64(0x17f)
            && capabilities & ~UInt64(0x37f) == 0
            ? capabilities
            : nil
    }

    private static func isValidTelemetryBatch(
        _ fields: [UInt64: ProtocolV3CBORValue],
        activeSessionID: Data?
    ) -> Bool {
        guard Set(fields.keys) == Set(1...8),
              fields[1]?.unsignedValue == 2,
              fields[2]?.bytesValue == activeSessionID,
              let traceID = fields[3]?.bytesValue,
              traceID.count == 16,
              traceID.contains(where: { $0 != 0 }),
              let source = fields[4]?.unsignedValue,
              source == 1 || source == 2,
              fields[5]?.unsignedValue == 1,
              isSignedInteger(fields[6]),
              fields[7]?.unsignedValue != nil,
              let samples = fields[8]?.arrayValue,
              samples.count <= 256 else {
            return false
        }
        return samples.allSatisfy { value in
            guard let sample = value.mapValue,
                  Set(sample.keys) == Set(1...5),
                  sample[1]?.unsignedValue != nil,
                  sample[2]?.unsignedValue != nil,
                  sample[3]?.unsignedValue != nil,
                  isSignedInteger(sample[4]),
                  sample[5]?.unsignedValue != nil else {
                return false
            }
            return true
        }
    }

    private static func isSignedInteger(_ value: ProtocolV3CBORValue?) -> Bool {
        switch value {
        case .unsigned, .negative: true
        default: false
        }
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}
