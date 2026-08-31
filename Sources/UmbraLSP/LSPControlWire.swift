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
    case stop = 0x0204
    case stopResponse = 0x0205
    case videoConfig = 0x0210
    case videoConfigAck = 0x0211
    case audioConfig = 0x0212
    case audioConfigAck = 0x0213
    case microphoneConfig = 0x0214
    case microphoneConfigAck = 0x0215
    case pathProbe = 0x0300
    case pathProbeAck = 0x0301
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
    public var microphoneOffer: LSPMicrophoneOffer?
    public var networkProfile: UInt8
    public var videoOffers: [LSPVideoOffer]
    public var receiveBatchCapacity: UInt8
    public var decoderSurfaces: UInt8
    public var maximumCaptureToPresentMicroseconds: UInt32

    public init(
        applicationID: String,
        pointerRate: UInt32 = 1_000,
        controllerRate: UInt32 = 250,
        sensorRate: UInt32 = 250,
        reconciliationRate: UInt32 = 250,
        maximumInputWireBitsPerSecond: UInt64 = 32_000_000,
        audioOffers: [LSPAudioOffer] = [],
        offeredMaximumUDPPayload: UInt16 = 1_472,
        microphoneOffer: LSPMicrophoneOffer? = nil,
        networkProfile: UInt8 = 0,
        videoOffers: [LSPVideoOffer] = [],
        receiveBatchCapacity: UInt8 = 64,
        decoderSurfaces: UInt8 = 3,
        maximumCaptureToPresentMicroseconds: UInt32 = 50_000
    ) {
        self.applicationID = applicationID
        self.pointerRate = pointerRate
        self.controllerRate = controllerRate
        self.sensorRate = sensorRate
        self.reconciliationRate = reconciliationRate
        self.maximumInputWireBitsPerSecond = maximumInputWireBitsPerSecond
        self.audioOffers = audioOffers
        self.offeredMaximumUDPPayload = offeredMaximumUDPPayload
        self.microphoneOffer = microphoneOffer
        self.networkProfile = networkProfile
        self.videoOffers = videoOffers
        self.receiveBatchCapacity = receiveBatchCapacity
        self.decoderSurfaces = decoderSurfaces
        self.maximumCaptureToPresentMicroseconds = maximumCaptureToPresentMicroseconds
    }
}

/// Exact hardware-only SDR video offer in START key twelve.
public struct LSPVideoOffer: Equatable, Sendable {
    public var codec: UInt8
    public var profile: UInt8
    public var width: UInt32
    public var height: UInt32
    public var refreshNumerator: UInt32
    public var refreshDenominator: UInt32
    public var preferredBitsPerSecond: UInt64
    public var maximumBitsPerSecond: UInt64

    public init(
        codec: UInt8, profile: UInt8, width: UInt32, height: UInt32,
        refreshNumerator: UInt32, refreshDenominator: UInt32,
        preferredBitsPerSecond: UInt64, maximumBitsPerSecond: UInt64
    ) {
        self.codec = codec; self.profile = profile; self.width = width; self.height = height
        self.refreshNumerator = refreshNumerator; self.refreshDenominator = refreshDenominator
        self.preferredBitsPerSecond = preferredBitsPerSecond
        self.maximumBitsPerSecond = maximumBitsPerSecond
    }
}

/// Exact selected 28-key SDR video tuple.
public struct LSPVideoSelection: Equatable, Sendable {
    public var nativeConfiguration: LSPNativeVideoConfiguration
}

/// Optional mono 20-ms reverse-microphone START offer.
public struct LSPMicrophoneOffer: Equatable, Sendable {
    public var maximumBitrate: UInt32
    public var inbandFEC: Bool
    public var dtx: Bool
    public var required: Bool

    public init(
        maximumBitrate: UInt32 = 64_000,
        inbandFEC: Bool = true,
        dtx: Bool = true,
        required: Bool = false
    ) {
        self.maximumBitrate = maximumBitrate
        self.inbandFEC = inbandFEC
        self.dtx = dtx
        self.required = required
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
    public var microphoneConfiguration: LSPNativeMicrophoneConfiguration?
    public var videoSelection: LSPVideoSelection
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
    public var microphoneConfiguration: LSPNativeMicrophoneConfiguration?
    public var videoSelection: LSPVideoSelection
}

/// Exact authenticated AUDIO_CONFIG request.
public struct LSPAudioConfigurationRequest: Equatable, Sendable {
    public var sessionID: UUID
    public var nativeConfiguration: LSPNativeAudioConfiguration
}

/// Exact authenticated MICROPHONE_CONFIG request.
public struct LSPMicrophoneConfigurationRequest: Equatable, Sendable {
    public var sessionID: UUID
    public var nativeConfiguration: LSPNativeMicrophoneConfiguration
}

/// Exact authenticated VIDEO_CONFIG request.
public struct LSPVideoConfigurationRequest: Equatable, Sendable {
    public var sessionID: UUID
    public var nativeConfiguration: LSPNativeVideoConfiguration
    public var parameterSets: [Data]
}

/// Exact authenticated PATH_PROBE intent or acknowledgement fields.
public struct LSPPathProbeIntent: Equatable, Sendable {
    public var probeID: UInt64
    public var udpPayloadSize: UInt16
}

/// Exact deterministic-CBOR codecs shared with Lumen's control server.
public enum LSPControlWire {
    private static let videoSchemaVersion: UInt64 = 2

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
              (1_200...1_472).contains(request.offeredMaximumUDPPayload),
              request.networkProfile <= 1,
              (1...8).contains(request.videoOffers.count),
              (1...64).contains(request.receiveBatchCapacity),
              (2...4).contains(request.decoderSurfaces),
              request.maximumCaptureToPresentMicroseconds > 0
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
        let microphone: DeterministicCBORValue
        if let offer = request.microphoneOffer {
            guard (6_000...128_000).contains(offer.maximumBitrate) else {
                throw DeterministicCBORError.malformed
            }
            microphone = .map([
                .init(key: 1, value: .unsigned(1)),
                .init(key: 2, value: .unsigned(960)),
                .init(key: 3, value: .unsigned(UInt64(offer.maximumBitrate))),
                .init(key: 4, value: .boolean(offer.inbandFEC)),
                .init(key: 5, value: .boolean(offer.dtx)),
                .init(key: 6, value: .boolean(offer.required)),
            ])
        } else {
            microphone = .null
        }
        let videoOffers = try request.videoOffers.map { offer -> DeterministicCBORValue in
            guard ((offer.codec == 2 && offer.profile == 2) || (offer.codec == 1 && offer.profile == 1)),
                  offer.width > 0, offer.height > 0,
                  offer.refreshNumerator > 0, offer.refreshDenominator > 0,
                  offer.preferredBitsPerSecond > 0,
                  offer.preferredBitsPerSecond <= offer.maximumBitsPerSecond,
                  offer.maximumBitsPerSecond <= 1_000_000_000
            else { throw DeterministicCBORError.malformed }
            return .map([
                .init(key: 1, value: .unsigned(UInt64(offer.codec))),
                .init(key: 2, value: .unsigned(UInt64(offer.profile))),
                .init(key: 3, value: .unsigned(UInt64(offer.width))),
                .init(key: 4, value: .unsigned(UInt64(offer.height))),
                .init(key: 5, value: .unsigned(UInt64(offer.refreshNumerator))),
                .init(key: 6, value: .unsigned(UInt64(offer.refreshDenominator))),
                .init(key: 7, value: .unsigned(offer.preferredBitsPerSecond)),
                .init(key: 8, value: .unsigned(offer.maximumBitsPerSecond)),
                .init(key: 9, value: .unsigned(1)),
                .init(key: 10, value: .unsigned(1)),
                .init(key: 11, value: .boolean(false)),
                .init(key: 12, value: .boolean(false)),
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
            microphone,
            .unsigned(UInt64(request.networkProfile)),
            .array(videoOffers),
            .unsigned(UInt64(request.receiveBatchCapacity)),
            .unsigned(UInt64(request.decoderSurfaces)),
            .unsigned(1),
            .unsigned(UInt64(request.maximumCaptureToPresentMicroseconds)),
        ])
    }

    public static func startResponse(from event: LSPControlEvent) throws -> LSPInputStartResponse {
        let values = try responseValues(event, type: .startResponse, count: 31)
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
        let microphone = try microphoneConfiguration(value: values[29], streamGeneration: streamGeneration)
        let video = try videoSelection(value: values[30], streamGeneration: streamGeneration)
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
            audioConfiguration: audio,
            microphoneConfiguration: microphone,
            videoSelection: video
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
        let values = try responseValues(event, type: .attachResponse, count: 32)
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
        let microphone = try microphoneConfiguration(value: values[30], streamGeneration: streamGeneration)
        let video = try videoSelection(value: values[31], streamGeneration: streamGeneration)
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
            audioConfiguration: audio,
            microphoneConfiguration: microphone,
            videoSelection: video
        )
    }

    public static func videoConfig(from event: LSPControlEvent) throws -> LSPVideoConfigurationRequest {
        guard event.messageType == LSPControlMessageType.videoConfig.rawValue,
              !event.flags.contains(.response), event.requestID != 0 else {
            throw DeterministicCBORError.malformed
        }
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(event.payload), count: 8)
        guard try uint(values[0]) == videoSchemaVersion else { throw DeterministicCBORError.malformed }
        let sessionID = try uuid(try bytes(values[1], count: 16))
        let streamGeneration = try uint32(values[2], nonzero: true)
        let selection = try videoSelection(value: values[3], streamGeneration: streamGeneration)
        guard case .array(let encodedSets) = values[4], encodedSets.count == (selection.nativeConfiguration.codec == 1 ? 2 : 3) else {
            throw DeterministicCBORError.malformed
        }
        let sets = try encodedSets.map { value -> Data in
            guard case .bytes(let bytes) = value, !bytes.isEmpty, bytes.count <= 4_096 else {
                throw DeterministicCBORError.malformed
            }
            return bytes
        }
        let validTypes: [UInt8] = if selection.nativeConfiguration.codec == 1 {
            sets.map { $0[0] & 0x1f }
        } else {
            sets.map { ($0[0] >> 1) & 0x3f }
        }
        guard validTypes == (selection.nativeConfiguration.codec == 1 ? [7, 8] : [32, 33, 34]),
              sets.allSatisfy({ bytes in
                  !(bytes.count >= 3 && bytes[0] == 0 && bytes[1] == 0 &&
                    (bytes[2] == 1 || (bytes.count >= 4 && bytes[2] == 0 && bytes[3] == 1)))
              })
        else { throw DeterministicCBORError.malformed }
        var native = selection.nativeConfiguration
        native.frameIDOrigin = try uint(values[5])
        native.recoveryEpoch = try uint32(values[6], nonzero: true)
        native.maximumAccessUnitBytes = try uint32(values[7], nonzero: true)
        guard native.frameIDOrigin != 0, native.maximumAccessUnitBytes <= 16 * 1_024 * 1_024 else {
            throw DeterministicCBORError.malformed
        }
        return LSPVideoConfigurationRequest(sessionID: sessionID, nativeConfiguration: native, parameterSets: sets)
    }

    public static func videoConfigAck(
        status: LSPControlStatus,
        sessionID: UUID,
        videoGeneration: UInt32,
        decoderCredit: UInt8
    ) throws -> Data {
        guard videoGeneration != 0, (2...4).contains(decoderCredit) else { throw DeterministicCBORError.malformed }
        return try encodeMap([
            .unsigned(videoSchemaVersion), .unsigned(UInt64(status.rawValue)), .bytes(uuidBytes(sessionID)),
            .unsigned(UInt64(videoGeneration)), .unsigned(UInt64(decoderCredit)),
        ])
    }

    public static func pathProbe(probeID: UInt64, udpPayloadSize: UInt16) throws -> Data {
        guard probeID != 0, (1_200...1_472).contains(udpPayloadSize) else {
            throw DeterministicCBORError.malformed
        }
        return try encodeMap([
            .unsigned(1),
            .unsigned(probeID),
            .unsigned(UInt64(udpPayloadSize)),
        ])
    }

    public static func pathProbe(from event: LSPControlEvent) throws -> LSPPathProbeIntent {
        guard event.messageType == LSPControlMessageType.pathProbe.rawValue,
              !event.flags.contains(.response), event.requestID != 0 else {
            throw DeterministicCBORError.malformed
        }
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(event.payload), count: 3)
        guard try uint(values[0]) == 1 else { throw DeterministicCBORError.malformed }
        let probeID = try uint(values[1])
        let size = try uint(values[2])
        guard probeID != 0, (1_200...1_472).contains(size) else { throw DeterministicCBORError.malformed }
        return .init(probeID: probeID, udpPayloadSize: UInt16(size))
    }

    public static func pathProbeAck(probeID: UInt64, receivedSize: UInt16) throws -> Data {
        try pathProbe(probeID: probeID, udpPayloadSize: receivedSize)
    }

    public static func pathProbeAck(from event: LSPControlEvent) throws -> LSPPathProbeIntent {
        guard event.messageType == LSPControlMessageType.pathProbeAck.rawValue,
              event.flags.contains(.response), !event.flags.contains(.errorResponse), event.requestID != 0 else {
            throw DeterministicCBORError.malformed
        }
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(event.payload), count: 3)
        guard try uint(values[0]) == 1 else { throw DeterministicCBORError.malformed }
        let probeID = try uint(values[1])
        let size = try uint(values[2])
        guard probeID != 0, (1_200...1_472).contains(size) else { throw DeterministicCBORError.malformed }
        return .init(probeID: probeID, udpPayloadSize: UInt16(size))
    }

    public static func stop(sessionID: UUID) throws -> Data {
        try encodeMap([.unsigned(1), .bytes(uuidBytes(sessionID))])
    }

    public static func requireStopResponse(_ event: LSPControlEvent) throws {
        let values = try responseValues(event, type: .stopResponse, count: 2)
        try requireSuccess(values[1])
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

    public static func microphoneConfig(from event: LSPControlEvent) throws -> LSPMicrophoneConfigurationRequest {
        guard event.messageType == LSPControlMessageType.microphoneConfig.rawValue,
              !event.flags.contains(.response), event.requestID != 0 else {
            throw DeterministicCBORError.malformed
        }
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(event.payload), count: 13)
        guard try uint(values[0]) == 1 else { throw DeterministicCBORError.malformed }
        let sessionID = try uuid(try bytes(values[1], count: 16))
        let streamGeneration = try uint32(values[2], nonzero: true)
        let configuration = try microphoneConfigurationMap(values: values, offset: 3, streamGeneration: streamGeneration)
        return LSPMicrophoneConfigurationRequest(sessionID: sessionID, nativeConfiguration: configuration)
    }

    public static func microphoneConfigAck(
        status: LSPControlStatus,
        sessionID: UUID,
        microphoneGeneration: UInt32
    ) throws -> Data {
        guard microphoneGeneration != 0 else { throw DeterministicCBORError.malformed }
        return try encodeMap([
            .unsigned(1),
            .unsigned(UInt64(status.rawValue)),
            .bytes(uuidBytes(sessionID)),
            .unsigned(UInt64(microphoneGeneration)),
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

    private static func microphoneConfiguration(
        value: DeterministicCBORValue,
        streamGeneration: UInt32
    ) throws -> LSPNativeMicrophoneConfiguration? {
        if case .null = value { return nil }
        let values = try DeterministicCBOR.exactMap(value, count: 10)
        return try microphoneConfigurationMap(values: values, offset: 0, streamGeneration: streamGeneration)
    }

    private static func microphoneConfigurationMap(
        values: [DeterministicCBORValue],
        offset: Int,
        streamGeneration: UInt32
    ) throws -> LSPNativeMicrophoneConfiguration {
        guard values.count >= offset + 10 else { throw DeterministicCBORError.malformed }
        let generation = try uint32(values[offset], nonzero: true)
        let ssrc = try uint32(values[offset + 1], nonzero: true)
        let payloadType = try uint32(values[offset + 2], nonzero: true)
        let clock = try uint32(values[offset + 3], nonzero: true)
        let channels = try uint32(values[offset + 4], nonzero: true)
        let frameSamples = try uint32(values[offset + 5], nonzero: true)
        let bitrate = try uint32(values[offset + 6], nonzero: true)
        guard case .boolean(let fec) = values[offset + 7],
              case .boolean(let dtx) = values[offset + 8]
        else { throw DeterministicCBORError.malformed }
        let udp = try uint32(values[offset + 9], nonzero: true)
        guard (96...127).contains(payloadType), clock == 48_000, channels == 1,
              frameSamples == 960, (6_000...128_000).contains(bitrate), udp == 1_200 else {
            throw DeterministicCBORError.malformed
        }
        return LSPNativeMicrophoneConfiguration(
            streamGeneration: streamGeneration,
            microphoneGeneration: generation,
            microphoneSSRC: ssrc,
            microphonePayloadType: UInt8(payloadType),
            bitrate: bitrate,
            inbandFEC: fec,
            dtx: dtx,
            udpPayloadSize: UInt16(udp)
        )
    }

    private static func videoSelection(
        value: DeterministicCBORValue,
        streamGeneration: UInt32
    ) throws -> LSPVideoSelection {
        let values = try DeterministicCBOR.exactMap(value, count: 28)
        let generation = try uint32(values[0], nonzero: true)
        let ssrc = try uint32(values[1], nonzero: true)
        let payloadType = try uint32(values[2], nonzero: true)
        let clock = try uint32(values[3], nonzero: true)
        let codec = try uint32(values[4], nonzero: true)
        let profile = try uint32(values[5], nonzero: true)
        let width = try uint32(values[6], nonzero: true)
        let height = try uint32(values[7], nonzero: true)
        let refreshNumerator = try uint32(values[8], nonzero: true)
        let refreshDenominator = try uint32(values[9], nonzero: true)
        let bitrate = try uint32(values[10], nonzero: true)
        let extensionIDs = try (20...24).map { try uint(values[$0]) }
        guard try uint(values[11]) == 1, try uint(values[12]) == 1,
              try uint(values[13]) == 1, try uint(values[14]) == 1,
              case .boolean(false) = values[15], try uint(values[16]) == 1_200,
              (2...4).contains(try uint(values[17])), try uint(values[18]) == 1,
              try uint(values[19]) == 1,
              extensionIDs == [1, 2, 3, 4, 5],
              case .boolean(false) = values[25], case .boolean(false) = values[26],
              ((codec == 1 && profile == 1) || (codec == 2 && profile == 2)),
              (96...127).contains(payloadType), clock == 90_000
        else { throw DeterministicCBORError.malformed }
        let maximumFrameAge = try uint32(values[27], nonzero: true)
        return LSPVideoSelection(nativeConfiguration: LSPNativeVideoConfiguration(
            streamGeneration: streamGeneration,
            videoGeneration: generation,
            primarySSRC: ssrc,
            primaryPayloadType: UInt8(payloadType),
            codec: UInt8(codec),
            profile: UInt8(profile),
            width: width,
            height: height,
            refreshNumerator: refreshNumerator,
            refreshDenominator: refreshDenominator,
            bitrate: bitrate,
            maximumAccessUnitBytes: 0,
            maximumFrameAgeMicroseconds: maximumFrameAge,
            frameIDOrigin: 0,
            recoveryEpoch: 0,
            decoderSurfaces: UInt8(try uint(values[17])),
            udpPayloadSize: 1_200,
            frameMarkingExtension: UInt8(extensionIDs[0]),
            absoluteCaptureExtension: UInt8(extensionIDs[1]),
            frameIDExtension: UInt8(extensionIDs[2]),
            inputWatermarkExtension: UInt8(extensionIDs[3]),
            encoderTimingExtension: UInt8(extensionIDs[4])
        ))
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
