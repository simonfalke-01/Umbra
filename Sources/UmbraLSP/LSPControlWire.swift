import Foundation
import UmbraLSPTransport

/// Exact LSP/1 control-message registry implemented by Lumen and Umbra.
public enum LSPControlMessageType: UInt16, Sendable {
    case clientHello = 0x0001
    case serverHello = 0x0002
    case pairRequest = 0x0010
    case pairResponse = 0x0011
    case authRequest = 0x0020
    case authResponse = 0x0021
    case listApplications = 0x0100
    case applications = 0x0101
    case start = 0x0200
    case startResponse = 0x0201
    case attach = 0x0202
    case attachResponse = 0x0203
    case audioConfig = 0x0212
    case audioConfigAck = 0x0213
}

/// Stable status codes in exact LSP control responses.
public enum LSPControlStatus: UInt8, Error, Sendable {
    case success = 0
    case malformed = 1
    case unsupported = 2
    case authenticationFailed = 3
    case permissionDenied = 4
    case busy = 5
    case unsupportedMediaTuple = 6
    case staleGeneration = 7
    case timeout = 8
    case pathCapacityInsufficient = 9
    case internalFailure = 10
}

/// A validated SERVER_HELLO response.
public struct LSPServerHello: Equatable, Sendable {
    public var connectionGeneration: UInt32
    public var hostID: UUID
    public var hostIdentityKey: Data
    public var serverSPKISHA256: Data
    public var serverNonce: Data
}

/// A validated PAIR_RESPONSE.
public struct LSPPairingResponse: Equatable, Sendable {
    public var permissions: LSPPermission
    public var revocationGeneration: UInt32
    public var serverSignature: Data
}

/// A validated AUTH_RESPONSE.
public struct LSPAuthenticationResponse: Equatable, Sendable {
    public var permissions: LSPPermission
    public var revocationGeneration: UInt32
    public var connectionGeneration: UInt32
    public var serverSignature: Data
}

/// One native LSP application returned by the authenticated host.
public struct LSPApplication: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var imagePath: String
}

/// Requested input-only START rates and aggregate wire budget.
public struct LSPInputStartRequest: Equatable, Sendable {
    public var applicationID: String
    public var pointerRate: UInt32
    public var controllerRate: UInt32
    public var sensorRate: UInt32
    public var reconciliationRate: UInt32
    public var maximumInputWireBitsPerSecond: UInt64
    public var audioOffers: [LSPAudioOffer]
    public var offeredMaximumUDPPayload: UInt16

    public init(
        applicationID: String,
        pointerRate: UInt32 = 1_000,
        controllerRate: UInt32 = 250,
        sensorRate: UInt32 = 250,
        reconciliationRate: UInt32 = 250,
        maximumInputWireBitsPerSecond: UInt64 = 32_000_000,
        audioOffers: [LSPAudioOffer] = [],
        offeredMaximumUDPPayload: UInt16 = 1_472
    ) {
        self.applicationID = applicationID
        self.pointerRate = pointerRate
        self.controllerRate = controllerRate
        self.sensorRate = sensorRate
        self.reconciliationRate = reconciliationRate
        self.maximumInputWireBitsPerSecond = maximumInputWireBitsPerSecond
        self.audioOffers = audioOffers
        self.offeredMaximumUDPPayload = offeredMaximumUDPPayload
    }
}

/// One ordered Opus capability in START.
public struct LSPAudioOffer: Equatable, Sendable {
    public var channels: UInt8
    public var frameSamples: UInt16
    public var maximumBitrate: UInt32
    public var inbandFEC: Bool
    public var dtx: Bool

    public static let adaptiveDefaults: [Self] = [
        .init(channels: 2, frameSamples: 480, maximumBitrate: 256_000, inbandFEC: false, dtx: true),
        .init(channels: 2, frameSamples: 240, maximumBitrate: 256_000, inbandFEC: false, dtx: true),
        .init(channels: 6, frameSamples: 480, maximumBitrate: 768_000, inbandFEC: false, dtx: true),
        .init(channels: 8, frameSamples: 480, maximumBitrate: 1_024_000, inbandFEC: false, dtx: true),
        .init(channels: 2, frameSamples: 960, maximumBitrate: 256_000, inbandFEC: true, dtx: true),
    ]

    public static let competitionDefaults: [Self] = [
        .init(channels: 2, frameSamples: 240, maximumBitrate: 256_000, inbandFEC: false, dtx: true),
        .init(channels: 2, frameSamples: 120, maximumBitrate: 256_000, inbandFEC: false, dtx: true),
        .init(channels: 6, frameSamples: 240, maximumBitrate: 768_000, inbandFEC: false, dtx: true),
        .init(channels: 8, frameSamples: 240, maximumBitrate: 1_024_000, inbandFEC: false, dtx: true),
        .init(channels: 2, frameSamples: 480, maximumBitrate: 256_000, inbandFEC: false, dtx: true),
    ]
}

/// Exact input-only START_RESPONSE authority and native lane mapping.
public struct LSPInputStartResponse: Equatable, Sendable {
    public var sessionID: UUID
    public var attachToken: Data
    public var nativeConfiguration: LSPNativeInputConfiguration
    public var audioConfiguration: LSPNativeAudioConfiguration
}

/// Exact ATTACH request ownership values retained from the prior authority.
public struct LSPAttachRequest: Equatable, Sendable {
    public var sessionID: UUID
    public var attachToken: Data
    public var intentID: UUID
}

/// Authenticated ATTACH_RESPONSE with rotated ownership and input mapping.
public struct LSPAttachResponse: Equatable, Sendable {
    public var sessionID: UUID
    public var replacementAttachToken: Data
    public var connectionGeneration: UInt32
    public var nativeConfiguration: LSPNativeInputConfiguration
    public var audioConfiguration: LSPNativeAudioConfiguration
}

/// Exact authenticated AUDIO_CONFIG request.
public struct LSPAudioConfigurationRequest: Equatable, Sendable {
    public var sessionID: UUID
    public var nativeConfiguration: LSPNativeAudioConfiguration
}

/// Exact deterministic-CBOR codecs shared with Lumen's control server.
public enum LSPControlWire {
    public static func clientHello(clientNonce: Data) throws -> Data {
        try fixed(clientNonce, count: 32)
        return try encodeMap([
            .unsigned(1),
            .bytes(clientNonce),
        ])
    }

    public static func serverHello(from event: LSPControlEvent) throws -> LSPServerHello {
        let values = try responseValues(event, type: .serverHello, count: 7)
        try requireSuccess(values[1])
        let generation = try uint32(values[2], nonzero: true)
        let hostID = try uuid(try bytes(values[3], count: 16))
        let hostIdentityKey = try bytes(values[4], count: 32)
        let spki = try bytes(values[5], count: 32)
        let serverNonce = try bytes(values[6], count: 32)
        return LSPServerHello(
            connectionGeneration: generation,
            hostID: hostID,
            hostIdentityKey: hostIdentityKey,
            serverSPKISHA256: spki,
            serverNonce: serverNonce
        )
    }

    public static func pairingTranscript(
        hostID: UUID,
        clientID: UUID,
        invitationID: UUID,
        clientNonce: Data,
        serverNonce: Data,
        permissions: LSPPermission
    ) throws -> Data {
        try fixed(clientNonce, count: 32)
        try fixed(serverNonce, count: 32)
        try knownPermissions(permissions)
        return try encodeMap([
            .text("lumen-stream/1 pair"),
            .bytes(uuidBytes(hostID)),
            .bytes(uuidBytes(clientID)),
            .bytes(uuidBytes(invitationID)),
            .bytes(clientNonce),
            .bytes(serverNonce),
            .unsigned(UInt64(permissions.rawValue)),
        ])
    }

    public static func pairRequest(
        clientID: UUID,
        clientIdentityKey: Data,
        invitationID: UUID,
        invitationSecret: Data,
        clientSignature: Data
    ) throws -> Data {
        try fixed(clientIdentityKey, count: 32)
        try fixed(invitationSecret, count: 32)
        try fixed(clientSignature, count: 64)
        return try encodeMap([
            .unsigned(1),
            .bytes(uuidBytes(clientID)),
            .bytes(clientIdentityKey),
            .bytes(uuidBytes(invitationID)),
            .bytes(invitationSecret),
            .bytes(clientSignature),
        ])
    }

    public static func pairResponse(from event: LSPControlEvent) throws -> LSPPairingResponse {
        let values = try responseValues(event, type: .pairResponse, count: 5)
        try requireSuccess(values[1])
        let permissions = LSPPermission(rawValue: try uint32(values[2], nonzero: false))
        try knownPermissions(permissions)
        return LSPPairingResponse(
            permissions: permissions,
            revocationGeneration: try uint32(values[3], nonzero: true),
            serverSignature: try bytes(values[4], count: 64)
        )
    }

    public static func authenticationTranscript(
        hostID: UUID,
        clientID: UUID,
        clientNonce: Data,
        serverNonce: Data,
        connectionGeneration: UInt32
    ) throws -> Data {
        try fixed(clientNonce, count: 32)
        try fixed(serverNonce, count: 32)
        guard connectionGeneration != 0 else { throw DeterministicCBORError.malformed }
        return try encodeMap([
            .text("lumen-stream/1 auth"),
            .bytes(uuidBytes(hostID)),
            .bytes(uuidBytes(clientID)),
            .bytes(clientNonce),
            .bytes(serverNonce),
            .unsigned(UInt64(connectionGeneration)),
        ])
    }

    public static func authRequest(clientID: UUID, clientSignature: Data) throws -> Data {
        try fixed(clientSignature, count: 64)
        return try encodeMap([
            .unsigned(1),
            .bytes(uuidBytes(clientID)),
            .bytes(clientSignature),
        ])
    }

    public static func authResponse(from event: LSPControlEvent) throws -> LSPAuthenticationResponse {
        let values = try responseValues(event, type: .authResponse, count: 6)
        try requireSuccess(values[1])
        let permissions = LSPPermission(rawValue: try uint32(values[2], nonzero: false))
        try knownPermissions(permissions)
        return LSPAuthenticationResponse(
            permissions: permissions,
            revocationGeneration: try uint32(values[3], nonzero: true),
            connectionGeneration: try uint32(values[4], nonzero: true),
            serverSignature: try bytes(values[5], count: 64)
        )
    }

    public static func listApplications() throws -> Data {
        try encodeMap([.unsigned(1)])
    }

    public static func applications(from event: LSPControlEvent) throws -> [LSPApplication] {
        let values = try responseValues(event, type: .applications, count: 3)
        try requireSuccess(values[1])
        guard case .array(let encodedApplications) = values[2], encodedApplications.count <= 64 else {
            throw DeterministicCBORError.malformed
        }
        return try encodedApplications.map { encoded in
            let fields = try DeterministicCBOR.exactMap(encoded, count: 3)
            let id = try text(fields[0], maximum: 128, allowEmpty: false)
            let name = try text(fields[1], maximum: 256, allowEmpty: false)
            let imagePath = try text(fields[2], maximum: 512, allowEmpty: true)
            return LSPApplication(id: id, name: name, imagePath: imagePath)
        }
    }

    public static func start(_ request: LSPInputStartRequest) throws -> Data {
        guard !request.applicationID.isEmpty, request.applicationID.utf8.count <= 128,
              (125...16_000).contains(request.pointerRate),
              (125...2_000).contains(request.controllerRate),
              (125...4_000).contains(request.sensorRate),
              (50...1_000).contains(request.reconciliationRate),
              (1...32_000_000).contains(request.maximumInputWireBitsPerSecond),
              (1...12).contains(request.audioOffers.count),
              (1_200...1_472).contains(request.offeredMaximumUDPPayload)
        else {
            throw DeterministicCBORError.malformed
        }
        let offers = try request.audioOffers.map { offer -> DeterministicCBORValue in
            guard [2, 6, 8].contains(offer.channels), [120, 240, 480, 960].contains(offer.frameSamples),
                  (6_000...2_048_000).contains(offer.maximumBitrate) else {
                throw DeterministicCBORError.malformed
            }
            return .map([
                .init(key: 1, value: .unsigned(UInt64(offer.channels))),
                .init(key: 2, value: .unsigned(UInt64(offer.frameSamples))),
                .init(key: 3, value: .unsigned(UInt64(offer.maximumBitrate))),
                .init(key: 4, value: .boolean(offer.inbandFEC)),
                .init(key: 5, value: .boolean(offer.dtx)),
            ])
        }
        return try encodeMap([
            .unsigned(1),
            .text(request.applicationID),
            .unsigned(UInt64(request.pointerRate)),
            .unsigned(UInt64(request.controllerRate)),
            .unsigned(UInt64(request.sensorRate)),
            .unsigned(UInt64(request.reconciliationRate)),
            .unsigned(request.maximumInputWireBitsPerSecond),
            .array(offers),
            .unsigned(UInt64(request.offeredMaximumUDPPayload)),
        ])
    }

    public static func startResponse(from event: LSPControlEvent) throws -> LSPInputStartResponse {
        let values = try responseValues(event, type: .startResponse, count: 29)
        try requireSuccess(values[1])
        let sessionID = try uuid(try bytes(values[2], count: 16))
        let attachToken = try bytes(values[3], count: 32)
        let streamGeneration = try uint32(values[4], nonzero: true)
        let inputGeneration = try uint32(values[5], nonzero: true)
        let inputSSRC = try uint32(values[6], nonzero: true)
        let acknowledgementSSRC = try uint32(values[7], nonzero: true)
        let payloadType = try uint32(values[8], nonzero: true)
        let pointerRate = try uint32(values[9], nonzero: true)
        let controllerRate = try uint32(values[10], nonzero: true)
        let sensorRate = try uint32(values[11], nonzero: true)
        let reconciliationRate = try uint32(values[12], nonzero: true)
        let reservedBudget = try uint(values[13])
        guard inputSSRC != acknowledgementSSRC,
              (96...127).contains(payloadType),
              (125...16_000).contains(pointerRate),
              (125...2_000).contains(controllerRate),
              (125...4_000).contains(sensorRate),
              (50...1_000).contains(reconciliationRate),
              (1...32_000_000).contains(reservedBudget),
              case .boolean(true) = values[14]
        else {
            throw DeterministicCBORError.malformed
        }
        let audio = try audioConfiguration(values: values, offset: 15, streamGeneration: streamGeneration)
        return LSPInputStartResponse(
            sessionID: sessionID,
            attachToken: attachToken,
            nativeConfiguration: LSPNativeInputConfiguration(
                streamGeneration: streamGeneration,
                inputGeneration: inputGeneration,
                inputSSRC: inputSSRC,
                acknowledgementSSRC: acknowledgementSSRC,
                inputPayloadType: UInt8(payloadType),
                pointerRate: pointerRate,
                controllerRate: controllerRate,
                sensorRate: sensorRate,
                reconciliationRate: reconciliationRate,
                reservedInputWireBitsPerSecond: reservedBudget,
                baselineRequired: true
            ),
            audioConfiguration: audio
        )
    }

    public static func attach(_ request: LSPAttachRequest) throws -> Data {
        try fixed(request.attachToken, count: 32)
        return try encodeMap([
            .unsigned(1),
            .bytes(uuidBytes(request.sessionID)),
            .bytes(request.attachToken),
            .bytes(uuidBytes(request.intentID)),
        ])
    }

    public static func attachResponse(from event: LSPControlEvent) throws -> LSPAttachResponse {
        let values = try responseValues(event, type: .attachResponse, count: 30)
        try requireSuccess(values[1])
        let sessionID = try uuid(try bytes(values[2], count: 16))
        let replacement = try bytes(values[3], count: 32)
        let connectionGeneration = try uint32(values[4], nonzero: true)
        let streamGeneration = try uint32(values[5], nonzero: true)
        let inputGeneration = try uint32(values[6], nonzero: true)
        let inputSSRC = try uint32(values[7], nonzero: true)
        let acknowledgementSSRC = try uint32(values[8], nonzero: true)
        let payloadType = try uint32(values[9], nonzero: true)
        let pointerRate = try uint32(values[10], nonzero: true)
        let controllerRate = try uint32(values[11], nonzero: true)
        let sensorRate = try uint32(values[12], nonzero: true)
        let reconciliationRate = try uint32(values[13], nonzero: true)
        let budget = try uint(values[14])
        guard inputSSRC != acknowledgementSSRC,
              (96...127).contains(payloadType),
              (125...16_000).contains(pointerRate),
              (125...2_000).contains(controllerRate),
              (125...4_000).contains(sensorRate),
              (50...1_000).contains(reconciliationRate),
              (1...32_000_000).contains(budget),
              case .boolean(true) = values[15]
        else {
            throw DeterministicCBORError.malformed
        }
        let audio = try audioConfiguration(values: values, offset: 16, streamGeneration: streamGeneration)
        return LSPAttachResponse(
            sessionID: sessionID,
            replacementAttachToken: replacement,
            connectionGeneration: connectionGeneration,
            nativeConfiguration: LSPNativeInputConfiguration(
                streamGeneration: streamGeneration,
                inputGeneration: inputGeneration,
                inputSSRC: inputSSRC,
                acknowledgementSSRC: acknowledgementSSRC,
                inputPayloadType: UInt8(payloadType),
                pointerRate: pointerRate,
                controllerRate: controllerRate,
                sensorRate: sensorRate,
                reconciliationRate: reconciliationRate,
                reservedInputWireBitsPerSecond: budget,
                baselineRequired: true
            ),
            audioConfiguration: audio
        )
    }

    public static func audioConfig(from event: LSPControlEvent) throws -> LSPAudioConfigurationRequest {
        guard event.messageType == LSPControlMessageType.audioConfig.rawValue,
              !event.flags.contains(.response), event.requestID != 0 else {
            throw DeterministicCBORError.malformed
        }
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(event.payload), count: 17)
        guard try uint(values[0]) == 1 else { throw DeterministicCBORError.malformed }
        let sessionID = try uuid(try bytes(values[1], count: 16))
        let streamGeneration = try uint32(values[2], nonzero: true)
        let configuration = try audioConfiguration(values: values, offset: 3, streamGeneration: streamGeneration)
        return LSPAudioConfigurationRequest(sessionID: sessionID, nativeConfiguration: configuration)
    }

    public static func audioConfigAck(
        status: LSPControlStatus,
        sessionID: UUID,
        audioGeneration: UInt32
    ) throws -> Data {
        guard audioGeneration != 0 else { throw DeterministicCBORError.malformed }
        return try encodeMap([
            .unsigned(1),
            .unsigned(UInt64(status.rawValue)),
            .bytes(uuidBytes(sessionID)),
            .unsigned(UInt64(audioGeneration)),
        ])
    }

    private static func responseValues(
        _ event: LSPControlEvent,
        type: LSPControlMessageType,
        count: Int
    ) throws -> [DeterministicCBORValue] {
        guard event.messageType == type.rawValue, event.flags.contains(.response) else {
            throw DeterministicCBORError.malformed
        }
        let value = try DeterministicCBOR.decode(event.payload)
        if event.flags.contains(.errorResponse) {
            let errorValues = try DeterministicCBOR.exactMap(value, count: 2)
            guard try uint(errorValues[0]) == 1,
                  let status = LSPControlStatus(rawValue: UInt8(try uint(errorValues[1])))
            else {
                throw DeterministicCBORError.malformed
            }
            throw status
        }
        let values = try DeterministicCBOR.exactMap(value, count: count)
        guard try uint(values[0]) == 1 else { throw DeterministicCBORError.malformed }
        return values
    }

    private static func audioConfiguration(
        values: [DeterministicCBORValue],
        offset: Int,
        streamGeneration: UInt32
    ) throws -> LSPNativeAudioConfiguration {
        guard values.count >= offset + 14 else { throw DeterministicCBORError.malformed }
        let generation = try uint32(values[offset], nonzero: true)
        let ssrc = try uint32(values[offset + 1], nonzero: true)
        let payloadType = try uint32(values[offset + 2], nonzero: true)
        let clock = try uint32(values[offset + 3], nonzero: true)
        let channels = try uint32(values[offset + 4], nonzero: true)
        let streams = try uint32(values[offset + 5], nonzero: true)
        let coupled = try uint32(values[offset + 6], nonzero: false)
        guard case .bytes(let mapping) = values[offset + 7] else { throw DeterministicCBORError.malformed }
        let frameSamples = try uint32(values[offset + 8], nonzero: true)
        let bitrate = try uint32(values[offset + 9], nonzero: true)
        guard case .boolean(let fec) = values[offset + 10],
              case .boolean(let dtx) = values[offset + 11]
        else { throw DeterministicCBORError.malformed }
        let udpPayload = try uint32(values[offset + 12], nonzero: true)
        let preroll = try uint32(values[offset + 13], nonzero: true)
        guard (96...127).contains(payloadType), clock == 48_000,
              [2, 6, 8].contains(channels), streams > 0, coupled <= streams,
              streams + coupled == channels, mapping.count == Int(channels),
              mapping.allSatisfy({ UInt32($0) < channels }),
              [120, 240, 480, 960].contains(frameSamples),
              (6_000...2_048_000).contains(bitrate),
              (1_200...1_472).contains(udpPayload), preroll == 1
        else {
            throw DeterministicCBORError.malformed
        }
        return LSPNativeAudioConfiguration(
            streamGeneration: streamGeneration,
            audioGeneration: generation,
            audioSSRC: ssrc,
            audioPayloadType: UInt8(payloadType),
            channels: UInt8(channels),
            streams: UInt8(streams),
            coupledStreams: UInt8(coupled),
            mapping: Array(mapping),
            frameSamples: UInt16(frameSamples),
            bitrate: bitrate,
            inbandFEC: fec,
            dtx: dtx,
            udpPayloadSize: UInt16(udpPayload)
        )
    }

    private static func requireSuccess(_ value: DeterministicCBORValue) throws {
        guard try uint(value) == UInt64(LSPControlStatus.success.rawValue) else {
            throw DeterministicCBORError.malformed
        }
    }

    private static func encodeMap(_ values: [DeterministicCBORValue]) throws -> Data {
        try DeterministicCBOR.encode(.map(values.enumerated().map {
            DeterministicCBORPair(key: UInt64($0.offset + 1), value: $0.element)
        }))
    }

    private static func uint(_ value: DeterministicCBORValue) throws -> UInt64 {
        guard case .unsigned(let integer) = value else { throw DeterministicCBORError.malformed }
        return integer
    }

    private static func uint32(_ value: DeterministicCBORValue, nonzero: Bool) throws -> UInt32 {
        let integer = try uint(value)
        guard integer <= UInt32.max, !nonzero || integer != 0 else {
            throw DeterministicCBORError.malformed
        }
        return UInt32(integer)
    }

    private static func bytes(_ value: DeterministicCBORValue, count: Int) throws -> Data {
        guard case .bytes(let bytes) = value, bytes.count == count else {
            throw DeterministicCBORError.malformed
        }
        return bytes
    }

    private static func text(
        _ value: DeterministicCBORValue,
        maximum: Int,
        allowEmpty: Bool
    ) throws -> String {
        guard case .text(let text) = value,
              (allowEmpty || !text.isEmpty),
              text.utf8.count <= maximum
        else {
            throw DeterministicCBORError.malformed
        }
        return text
    }

    private static func fixed(_ data: Data, count: Int) throws {
        guard data.count == count, data.contains(where: { $0 != 0 }) else {
            throw DeterministicCBORError.malformed
        }
    }

    private static func knownPermissions(_ permissions: LSPPermission) throws {
        guard permissions.subtracting(.allKnown).isEmpty else {
            throw DeterministicCBORError.malformed
        }
    }

    static func uuidBytes(_ identifier: UUID) -> Data {
        var bytes = identifier.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }

    static func uuid(_ data: Data) throws -> UUID {
        guard data.count == 16, data.contains(where: { $0 != 0 }) else {
            throw DeterministicCBORError.malformed
        }
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { destination in
            destination.copyBytes(from: data)
        }
        return UUID(uuid: bytes)
    }
}
