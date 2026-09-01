import Foundation
import UmbraCore
import UmbraLSPTransport
import UmbraMedia

/// Exact LSP/1 control-message registry implemented by Lumen and Umbra.
public enum LSPControlMessageType: UInt16, Sendable {
    case clientHello = 0x0001
    case serverHello = 0x0002
    case pairBegin = 0x0010
    case pairPending = 0x0011
    case pairPoll = 0x0012
    case pairChallenge = 0x0013
    case pairFinish = 0x0014
    case pairResult = 0x0015
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
    case streamEnded = 0x0220
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

/// A validated PIN-pairing pending response.
public struct LSPPairingPending: Equatable, Sendable {
    public var sessionID: UUID
    public var expiresAtUTCSeconds: UInt64
    public var permissions: LSPPermission
}

/// A validated host PAKE challenge after admin PIN approval.
public struct LSPPairingChallenge: Equatable, Sendable {
    public var sessionID: UUID
    public var approvalGeneration: UInt32
    public var serverPublicValue: Data
    public var permissions: LSPPermission
    public var expiresAtUTCSeconds: UInt64
}

/// A verified PIN-pairing result ready for persistence.
public struct LSPPairingResult: Equatable, Sendable {
    public var sessionID: UUID
    public var approvalGeneration: UInt32
    public var permissions: LSPPermission
    public var revocationGeneration: UInt32
    public var serverConfirmation: Data
    public var hostSignature: Data
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

/// LSP video codec identifier frozen by video schema revision three.
public enum LSPVideoCodec: UInt8, CaseIterable, Sendable {
    case h264 = 1
    case hevc = 2
    case av1 = 3
}

/// LSP codec-profile identifier frozen by video schema revision three.
public enum LSPVideoProfile: UInt8, CaseIterable, Sendable {
    case h264High = 1
    case h264High444 = 2
    case hevcMain = 3
    case hevcMain10 = 4
    case hevcRangeExtensions = 5
    case av1Main = 6
    case av1High = 7
}

/// Exact decoded pixel tuple frozen by video schema revision three.
public enum LSPVideoPixelFormat: UInt8, CaseIterable, Sendable {
    case yuv4208Bit = 1
    case yuv42010Bit = 2
    case yuv4448Bit = 3
    case yuv44410Bit = 4

    public var isTenBit: Bool {
        self == .yuv42010Bit || self == .yuv44410Bit
    }

    public var isYUV444: Bool {
        self == .yuv4448Bit || self == .yuv44410Bit
    }
}

/// Coarse encoded-access-unit delivery boundary selected by LSP control.
public enum LSPVideoDelivery: UInt8, Sendable {
    case completeAccessUnit = 1
    case boundedIncremental = 2
}

/// H.273 color tuple carried directly on the LSP wire.
public struct LSPVideoColorDescription: Equatable, Sendable {
    public var colorPrimaries: UInt8
    public var transferCharacteristics: UInt8
    public var matrixCoefficients: UInt8
    public var fullRange: Bool

    public static let rec709SDR = Self(
        colorPrimaries: 1,
        transferCharacteristics: 1,
        matrixCoefficients: 1,
        fullRange: false
    )
    public static let rec2020PQ = Self(
        colorPrimaries: 9,
        transferCharacteristics: 16,
        matrixCoefficients: 9,
        fullRange: false
    )
    public static let rec2020HLG = Self(
        colorPrimaries: 9,
        transferCharacteristics: 18,
        matrixCoefficients: 9,
        fullRange: false
    )

    public var isSupported: Bool {
        if colorPrimaries == 1, transferCharacteristics == 1, matrixCoefficients == 1 {
            return true
        }
        return !fullRange && colorPrimaries == 9 && matrixCoefficients == 9 &&
            (transferCharacteristics == 16 || transferCharacteristics == 18)
    }

    public var isHDR: Bool {
        transferCharacteristics == 16 || transferCharacteristics == 18
    }
}

/// Exact hardware-derived video offer in START key twelve.
public struct LSPVideoOffer: Equatable, Sendable {
    public var codec: LSPVideoCodec
    public var profile: LSPVideoProfile
    public var width: UInt32
    public var height: UInt32
    public var refreshNumerator: UInt32
    public var refreshDenominator: UInt32
    public var preferredBitsPerSecond: UInt64
    public var maximumBitsPerSecond: UInt64
    public var pixelFormat: LSPVideoPixelFormat
    public var color: LSPVideoColorDescription
    public var delivery: LSPVideoDelivery
    public var supportsFlexFEC: Bool
    public var supportsRTX: Bool
    public var maximumAccessUnitBytes: UInt32

    public init(
        codec: LSPVideoCodec, profile: LSPVideoProfile, width: UInt32, height: UInt32,
        refreshNumerator: UInt32, refreshDenominator: UInt32,
        preferredBitsPerSecond: UInt64, maximumBitsPerSecond: UInt64,
        pixelFormat: LSPVideoPixelFormat = .yuv4208Bit,
        color: LSPVideoColorDescription = .rec709SDR,
        delivery: LSPVideoDelivery = .completeAccessUnit,
        supportsFlexFEC: Bool = true,
        supportsRTX: Bool = true,
        maximumAccessUnitBytes: UInt32 = 16 * 1_024 * 1_024
    ) {
        self.codec = codec; self.profile = profile; self.width = width; self.height = height
        self.refreshNumerator = refreshNumerator; self.refreshDenominator = refreshDenominator
        self.preferredBitsPerSecond = preferredBitsPerSecond
        self.maximumBitsPerSecond = maximumBitsPerSecond
        self.pixelFormat = pixelFormat
        self.color = color
        self.delivery = delivery
        self.supportsFlexFEC = supportsFlexFEC
        self.supportsRTX = supportsRTX
        self.maximumAccessUnitBytes = maximumAccessUnitBytes
    }
}

public extension LSPVideoOffer {
    /// Builds only exact tuples proven by VideoToolbox and the selected product policy.
    static func hardwareOffers(
        capabilities: AppleStreamingCapabilities,
        width: UInt32,
        height: UInt32,
        refreshNumerator: UInt32,
        refreshDenominator: UInt32,
        preferredBitsPerSecond: UInt64,
        maximumBitsPerSecond: UInt64,
        codecPreference: VideoCodecPreference,
        enableHDR: Bool,
        hdrTransferPreference: HDRTransferPreference,
        enableYUV444: Bool,
        maximumAccessUnitBytes: UInt32 = 16 * 1_024 * 1_024
    ) -> [Self] {
        guard capabilities.hasMetalDevice,
              width > 0, height > 0,
              refreshNumerator > 0, refreshDenominator > 0,
              preferredBitsPerSecond >= 1_000,
              preferredBitsPerSecond <= maximumBitsPerSecond,
              maximumBitsPerSecond <= 1_000_000_000,
              maximumAccessUnitBytes > 0,
              maximumAccessUnitBytes <= 16 * 1_024 * 1_024
        else { return [] }

        let priority: [VideoCodec] = switch codecPreference {
        case .automatic: [.hevc, .h264, .av1]
        case .h264: [.h264]
        case .hevc, .hevcHDRDeprecated: [.hevc, .h264]
        case .av1: [.av1, .hevc, .h264]
        }
        let formatOrder = priority.flatMap { codec in
            capabilities.supportedHardwareVideoFormats
                .filter { Self.codec(for: $0) == codec }
                .sorted { left, right in
                    let leftRank = Self.formatRank(
                        left,
                        wantsYUV444: enableYUV444,
                        wantsTenBit: enableHDR
                    )
                    let rightRank = Self.formatRank(
                        right,
                        wantsYUV444: enableYUV444,
                        wantsTenBit: enableHDR
                    )
                    return leftRank < rightRank
                }
        }

        var offers: [Self] = []
        for format in formatOrder where format.isYUV444 == enableYUV444 {
            guard let tuple = Self.lspTuple(for: format) else { continue }
            let colors: [LSPVideoColorDescription]
            if enableHDR {
                guard tuple.pixel.isTenBit else { continue }
                colors = switch hdrTransferPreference {
                case .automatic: [.rec2020PQ, .rec2020HLG]
                case .pq: [.rec2020PQ]
                case .hlg: [.rec2020HLG]
                }
            } else {
                colors = [.rec709SDR]
            }
            for color in colors {
                offers.append(.init(
                    codec: tuple.codec,
                    profile: tuple.profile,
                    width: width,
                    height: height,
                    refreshNumerator: refreshNumerator,
                    refreshDenominator: refreshDenominator,
                    preferredBitsPerSecond: preferredBitsPerSecond,
                    maximumBitsPerSecond: maximumBitsPerSecond,
                    pixelFormat: tuple.pixel,
                    color: color,
                    supportsFlexFEC: true,
                    supportsRTX: true,
                    maximumAccessUnitBytes: maximumAccessUnitBytes
                ))
            }
        }
        return Array(offers.prefix(8))
    }

    private static func codec(for format: MoonlightVideoFormat) -> VideoCodec {
        switch format {
        case .h264, .h264High8YUV444: .h264
        case .hevc, .hevcMain10, .hevcRext8YUV444, .hevcRext10YUV444: .hevc
        case .av1Main8, .av1Main10, .av1High8YUV444, .av1High10YUV444: .av1
        }
    }

    private static func formatRank(
        _ format: MoonlightVideoFormat,
        wantsYUV444: Bool,
        wantsTenBit: Bool
    ) -> Int {
        (format.isYUV444 == wantsYUV444 ? 0 : 10) + (format.isTenBit == wantsTenBit ? 0 : 1)
    }

    private static func lspTuple(
        for format: MoonlightVideoFormat
    ) -> (codec: LSPVideoCodec, profile: LSPVideoProfile, pixel: LSPVideoPixelFormat)? {
        switch format {
        case .h264: (.h264, .h264High, .yuv4208Bit)
        case .h264High8YUV444: (.h264, .h264High444, .yuv4448Bit)
        case .hevc: (.hevc, .hevcMain, .yuv4208Bit)
        case .hevcMain10: (.hevc, .hevcMain10, .yuv42010Bit)
        case .hevcRext8YUV444: (.hevc, .hevcRangeExtensions, .yuv4448Bit)
        case .hevcRext10YUV444: (.hevc, .hevcRangeExtensions, .yuv44410Bit)
        case .av1Main8: (.av1, .av1Main, .yuv4208Bit)
        case .av1Main10: (.av1, .av1Main, .yuv42010Bit)
        case .av1High8YUV444: (.av1, .av1High, .yuv4448Bit)
        case .av1High10YUV444: (.av1, .av1High, .yuv44410Bit)
        }
    }
}

/// Selected RFC 8627 single-stream FlexFEC association.
public struct LSPVideoFlexFECSelection: Equatable, Sendable {
    public var ssrc: UInt32
    public var payloadType: UInt8
    public var repairWindowMicroseconds: UInt32
    public var maximumGroupPackets: UInt8
}

/// Selected RFC 4588 retransmission association.
public struct LSPVideoRTXSelection: Equatable, Sendable {
    public var ssrc: UInt32
    public var payloadType: UInt8
    public var associatedPayloadType: UInt8
}

/// Exact selected 30-key video tuple.
public struct LSPVideoSelection: Equatable, Sendable {
    public var nativeConfiguration: LSPNativeVideoConfiguration
}

/// Codec-specific revision-three initialization units.
public struct LSPVideoCodecConfiguration: Equatable, Sendable {
    public var codec: LSPVideoCodec
    public var units: [Data]
}

/// SMPTE ST 2086 / CTA-861 static HDR metadata carried as integer wire units.
public struct LSPVideoHDRMetadata: Equatable, Sendable {
    public var displayPrimaryRedX: UInt32
    public var displayPrimaryRedY: UInt32
    public var displayPrimaryGreenX: UInt32
    public var displayPrimaryGreenY: UInt32
    public var displayPrimaryBlueX: UInt32
    public var displayPrimaryBlueY: UInt32
    public var whitePointX: UInt32
    public var whitePointY: UInt32
    public var maximumDisplayLuminance: UInt32
    public var minimumDisplayLuminance: UInt32
    public var maximumContentLightLevel: UInt32
    public var maximumFrameAverageLightLevel: UInt32
    public var maximumFullFrameLuminance: UInt32
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
    public var successorAttachToken: Data
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
    public var codecConfiguration: LSPVideoCodecConfiguration
    public var hdrMetadata: LSPVideoHDRMetadata?
}

/// Authenticated host notification that one exact LSP stream has ended.
public struct LSPStreamEnded: Equatable, Sendable {
    public var sessionID: UUID
    public var reason: UInt8
}

/// Exact authenticated PATH_PROBE intent or acknowledgement fields.
public struct LSPPathProbeIntent: Equatable, Sendable {
    public var probeID: UInt64
    public var udpPayloadSize: UInt16
}

/// Exact deterministic-CBOR codecs shared with Lumen's control server.
public enum LSPControlWire {
    private static let videoSchemaVersion: UInt64 = 3

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

    public static func pairBegin(
        clientID: UUID,
        clientIdentityKey: Data,
        clientName: String,
        clientPairingNonce: Data,
        scryptSalt: Data,
        clientPublicValue: Data,
        requestedPermissions: LSPPermission
    ) throws -> Data {
        try fixed(clientIdentityKey, count: 32)
        try fixed(clientPairingNonce, count: 16)
        try fixed(scryptSalt, count: 16)
        guard clientPublicValue.count == 65, clientPublicValue.first == 0x04,
              !clientName.isEmpty, clientName.utf8.count <= 64 else {
            throw DeterministicCBORError.malformed
        }
        try knownPermissions(requestedPermissions)
        return try encodeMap([
            .unsigned(1),
            .unsigned(1),
            .bytes(uuidBytes(clientID)),
            .bytes(clientIdentityKey),
            .text(clientName),
            .bytes(clientPairingNonce),
            .bytes(scryptSalt),
            .bytes(clientPublicValue),
            .unsigned(UInt64(requestedPermissions.rawValue)),
        ])
    }

    public static func pairPending(from event: LSPControlEvent) throws -> LSPPairingPending {
        guard event.messageType == LSPControlMessageType.pairPending.rawValue,
              event.flags.contains(.response), !event.flags.contains(.errorResponse) else {
            throw DeterministicCBORError.malformed
        }
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(event.payload), count: 6)
        guard try uint(values[0]) == 1,
              try uint(values[1]) == UInt64(LSPControlStatus.success.rawValue),
              try uint(values[2]) == 1 else { throw DeterministicCBORError.malformed }
        let permissions = LSPPermission(rawValue: try uint32(values[5], nonzero: false))
        try knownPermissions(permissions)
        return .init(
            sessionID: try uuid(try bytes(values[3], count: 16)),
            expiresAtUTCSeconds: try uint(values[4]),
            permissions: permissions
        )
    }

    public static func pairPoll(sessionID: UUID) throws -> Data {
        return try encodeMap([
            .unsigned(1),
            .unsigned(1),
            .bytes(uuidBytes(sessionID)),
        ])
    }

    public static func pairChallenge(from event: LSPControlEvent) throws -> LSPPairingChallenge {
        guard event.messageType == LSPControlMessageType.pairChallenge.rawValue,
              event.flags.contains(.response), !event.flags.contains(.errorResponse) else {
            throw DeterministicCBORError.malformed
        }
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(event.payload), count: 7)
        guard try uint(values[0]) == 1, try uint(values[1]) == 1 else {
            throw DeterministicCBORError.malformed
        }
        let serverPublicValue = try bytes(values[4], count: 65)
        guard serverPublicValue.first == 0x04 else { throw DeterministicCBORError.malformed }
        let permissions = LSPPermission(rawValue: try uint32(values[5], nonzero: false))
        try knownPermissions(permissions)
        return .init(
            sessionID: try uuid(try bytes(values[2], count: 16)),
            approvalGeneration: try uint32(values[3], nonzero: true),
            serverPublicValue: serverPublicValue,
            permissions: permissions,
            expiresAtUTCSeconds: try uint(values[6])
        )
    }

    public static func pairFinish(
        sessionID: UUID,
        approvalGeneration: UInt32,
        clientConfirmation: Data,
        clientSignature: Data
    ) throws -> Data {
        try fixed(clientConfirmation, count: 32)
        try fixed(clientSignature, count: 64)
        guard approvalGeneration != 0 else { throw DeterministicCBORError.malformed }
        return try encodeMap([
            .unsigned(1),
            .unsigned(1),
            .bytes(uuidBytes(sessionID)),
            .unsigned(UInt64(approvalGeneration)),
            .bytes(clientConfirmation),
            .bytes(clientSignature),
        ])
    }

    public static func pairResult(from event: LSPControlEvent) throws -> LSPPairingResult {
        guard event.messageType == LSPControlMessageType.pairResult.rawValue,
              event.flags.contains(.response), !event.flags.contains(.errorResponse) else {
            throw DeterministicCBORError.malformed
        }
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(event.payload), count: 9)
        guard try uint(values[0]) == 1,
              let status = LSPControlStatus(rawValue: try uint8(values[1], nonzero: false)),
              try uint(values[2]) == 1 else { throw DeterministicCBORError.malformed }
        guard status == .success else { throw status }
        let permissions = LSPPermission(rawValue: try uint32(values[5], nonzero: false))
        try knownPermissions(permissions)
        return .init(
            sessionID: try uuid(try bytes(values[3], count: 16)),
            approvalGeneration: try uint32(values[4], nonzero: true),
            permissions: permissions,
            revocationGeneration: try uint32(values[6], nonzero: true),
            serverConfirmation: try bytes(values[7], count: 32),
            hostSignature: try bytes(values[8], count: 64)
        )
    }

    public static func controlError(
        from event: LSPControlEvent,
        expectedType: LSPControlMessageType
    ) throws -> LSPControlStatus {
        guard event.messageType == expectedType.rawValue,
              event.flags.contains(.response), event.flags.contains(.errorResponse) else {
            throw DeterministicCBORError.malformed
        }
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(event.payload), count: 2)
        guard try uint(values[0]) == 1,
              let status = LSPControlStatus(rawValue: try uint8(values[1], nonzero: false)),
              status != .success else { throw DeterministicCBORError.malformed }
        return status
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
              (1...1_000_000).contains(request.maximumCaptureToPresentMicroseconds)
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
            guard videoTupleIsValid(codec: offer.codec, profile: offer.profile, pixelFormat: offer.pixelFormat),
                  (1...16_384).contains(offer.width), (1...16_384).contains(offer.height),
                  offer.refreshNumerator > 0, offer.refreshDenominator > 0,
                  offer.preferredBitsPerSecond >= 1_000,
                  offer.preferredBitsPerSecond <= offer.maximumBitsPerSecond,
                  offer.maximumBitsPerSecond <= 1_000_000_000,
                  offer.color.isSupported,
                  !offer.color.isHDR || offer.pixelFormat.isTenBit,
                  offer.delivery == .completeAccessUnit,
                  (1...16 * 1_024 * 1_024).contains(offer.maximumAccessUnitBytes)
            else { throw DeterministicCBORError.malformed }
            return .map([
                .init(key: 1, value: .unsigned(videoSchemaVersion)),
                .init(key: 2, value: .unsigned(UInt64(offer.codec.rawValue))),
                .init(key: 3, value: .unsigned(UInt64(offer.profile.rawValue))),
                .init(key: 4, value: .unsigned(UInt64(offer.width))),
                .init(key: 5, value: .unsigned(UInt64(offer.height))),
                .init(key: 6, value: .unsigned(UInt64(offer.refreshNumerator))),
                .init(key: 7, value: .unsigned(UInt64(offer.refreshDenominator))),
                .init(key: 8, value: .unsigned(offer.preferredBitsPerSecond)),
                .init(key: 9, value: .unsigned(offer.maximumBitsPerSecond)),
                .init(key: 10, value: .unsigned(UInt64(offer.pixelFormat.rawValue))),
                .init(key: 11, value: .unsigned(UInt64(offer.color.colorPrimaries))),
                .init(key: 12, value: .unsigned(UInt64(offer.color.transferCharacteristics))),
                .init(key: 13, value: .unsigned(UInt64(offer.color.matrixCoefficients))),
                .init(key: 14, value: .boolean(offer.color.fullRange)),
                .init(key: 15, value: .unsigned(UInt64(offer.delivery.rawValue))),
                .init(key: 16, value: .boolean(offer.supportsFlexFEC)),
                .init(key: 17, value: .boolean(offer.supportsRTX)),
                .init(key: 18, value: .unsigned(UInt64(offer.maximumAccessUnitBytes))),
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
        guard laneIdentifiersAreGloballyUnique(
            inputSSRC: inputSSRC,
            acknowledgementSSRC: acknowledgementSSRC,
            inputPayloadType: UInt8(payloadType),
            audio: audio,
            microphone: microphone,
            video: video.nativeConfiguration
        ) else { throw DeterministicCBORError.malformed }
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
        try fixed(request.successorAttachToken, count: 32)
        guard request.successorAttachToken != request.attachToken else {
            throw DeterministicCBORError.malformed
        }
        return try encodeMap([
            .unsigned(1),
            .bytes(uuidBytes(request.sessionID)),
            .bytes(request.attachToken),
            .bytes(uuidBytes(request.intentID)),
            .bytes(request.successorAttachToken),
        ])
    }

    public static func attachResponse(from event: LSPControlEvent) throws -> LSPAttachResponse {
        let values = try responseValues(event, type: .attachResponse, count: 32)
        guard let status = LSPControlStatus(rawValue: try uint8(values[1], nonzero: false)) else {
            throw DeterministicCBORError.malformed
        }
        guard status == .success else { throw status }
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
        guard laneIdentifiersAreGloballyUnique(
            inputSSRC: inputSSRC,
            acknowledgementSSRC: acknowledgementSSRC,
            inputPayloadType: UInt8(payloadType),
            audio: audio,
            microphone: microphone,
            video: video.nativeConfiguration
        ) else { throw DeterministicCBORError.malformed }
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
              !event.flags.contains(.response),
              event.flags.contains(.acknowledgementRequired),
              event.requestID != 0 else {
            throw DeterministicCBORError.malformed
        }
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(event.payload), count: 8)
        guard try uint(values[0]) == videoSchemaVersion else { throw DeterministicCBORError.malformed }
        let sessionID = try uuid(try bytes(values[1], count: 16))
        let streamGeneration = try uint32(values[2], nonzero: true)
        let selection = try videoSelection(value: values[3], streamGeneration: streamGeneration)
        let codecConfiguration = try videoCodecConfiguration(
            value: values[4],
            expectedCodec: selection.nativeConfiguration.codec
        )
        var native = selection.nativeConfiguration
        native.frameIDOrigin = try uint(values[5])
        native.recoveryEpoch = try uint32(values[6], nonzero: true)
        let hdrMetadata = try videoHDRMetadata(value: values[7])
        guard native.frameIDOrigin != 0,
              (native.transferCharacteristics == 1 && hdrMetadata == nil) ||
              native.transferCharacteristics == 16 ||
              (native.transferCharacteristics == 18 && hdrMetadata == nil),
              (native.transferCharacteristics == 16) == (hdrMetadata != nil)
        else {
            throw DeterministicCBORError.malformed
        }
        return LSPVideoConfigurationRequest(
            sessionID: sessionID,
            nativeConfiguration: native,
            codecConfiguration: codecConfiguration,
            hdrMetadata: hdrMetadata
        )
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

    public static func streamEnded(from event: LSPControlEvent) throws -> LSPStreamEnded {
        guard event.messageType == LSPControlMessageType.streamEnded.rawValue,
              !event.flags.contains(.response), event.requestID == 0 else {
            throw DeterministicCBORError.malformed
        }
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(event.payload), count: 3)
        guard try uint(values[0]) == 1 else { throw DeterministicCBORError.malformed }
        return .init(
            sessionID: try uuid(try bytes(values[1], count: 16)),
            reason: try uint8(values[2], nonzero: false)
        )
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
        let values = try DeterministicCBOR.exactMap(value, count: 30)
        guard try uint(values[0]) == videoSchemaVersion else { throw DeterministicCBORError.malformed }
        let generation = try uint32(values[1], nonzero: true)
        let ssrc = try uint32(values[2], nonzero: true)
        let payloadType = try uint8(values[3], nonzero: true)
        let clock = try uint32(values[4], nonzero: true)
        guard let codec = LSPVideoCodec(rawValue: try uint8(values[5], nonzero: true)),
              let profile = LSPVideoProfile(rawValue: try uint8(values[6], nonzero: true))
        else { throw DeterministicCBORError.malformed }
        let width = try uint32(values[7], nonzero: true)
        let height = try uint32(values[8], nonzero: true)
        let refreshNumerator = try uint32(values[9], nonzero: true)
        let refreshDenominator = try uint32(values[10], nonzero: true)
        let bitrate = try uint32(values[11], nonzero: true)
        guard let pixelFormat = LSPVideoPixelFormat(rawValue: try uint8(values[12], nonzero: true)) else {
            throw DeterministicCBORError.malformed
        }
        let color = LSPVideoColorDescription(
            colorPrimaries: try uint8(values[13], nonzero: true),
            transferCharacteristics: try uint8(values[14], nonzero: true),
            matrixCoefficients: try uint8(values[15], nonzero: true),
            fullRange: try boolean(values[16])
        )
        let extensionIDs = try (21...25).map { try uint(values[$0]) }
        let flexFEC = try flexFECSelection(value: values[26], primarySSRC: ssrc, primaryPayloadType: payloadType)
        let rtx = try rtxSelection(value: values[27], primarySSRC: ssrc, primaryPayloadType: payloadType)
        let delivery = try uint(values[20])
        guard videoTupleIsValid(codec: codec, profile: profile, pixelFormat: pixelFormat),
              color.isSupported, !color.isHDR || pixelFormat.isTenBit,
              width <= 16_384, height <= 16_384,
              flexFEC == nil || rtx == nil ||
                (flexFEC?.ssrc != rtx?.ssrc && flexFEC?.payloadType != rtx?.payloadType),
              try uint(values[17]) == 1_200,
              (2...4).contains(try uint(values[18])), try uint(values[19]) == 1,
              delivery == UInt64(LSPVideoDelivery.completeAccessUnit.rawValue),
              extensionIDs == [1, 2, 3, 4, 5],
              (96...127).contains(payloadType), clock == 90_000
        else { throw DeterministicCBORError.malformed }
        let maximumFrameAge = try uint32(values[28], nonzero: true)
        let maximumAccessUnitBytes = try uint32(values[29], nonzero: true)
        guard bitrate >= 1_000,
              maximumFrameAge <= 1_000_000,
              maximumAccessUnitBytes <= 16 * 1_024 * 1_024,
              flexFEC == nil || (flexFEC?.repairWindowMicroseconds ?? 0) <= maximumFrameAge
        else { throw DeterministicCBORError.malformed }
        return LSPVideoSelection(nativeConfiguration: LSPNativeVideoConfiguration(
            streamGeneration: streamGeneration,
            videoGeneration: generation,
            primarySSRC: ssrc,
            primaryPayloadType: payloadType,
            codec: codec.rawValue,
            profile: profile.rawValue,
            pixelFormat: pixelFormat.rawValue,
            colorPrimaries: color.colorPrimaries,
            transferCharacteristics: color.transferCharacteristics,
            matrixCoefficients: color.matrixCoefficients,
            fullRange: color.fullRange,
            delivery: UInt8(delivery),
            payloadFormat: codec == .av1 ? LSPVideoPayloadFormat.av1LowOverheadOBU.rawValue : LSPVideoPayloadFormat.annexB.rawValue,
            width: width,
            height: height,
            refreshNumerator: refreshNumerator,
            refreshDenominator: refreshDenominator,
            bitrate: bitrate,
            maximumAccessUnitBytes: maximumAccessUnitBytes,
            maximumFrameAgeMicroseconds: maximumFrameAge,
            frameIDOrigin: 0,
            recoveryEpoch: 0,
            decoderSurfaces: UInt8(try uint(values[18])),
            udpPayloadSize: 1_200,
            frameMarkingExtension: UInt8(extensionIDs[0]),
            absoluteCaptureExtension: UInt8(extensionIDs[1]),
            frameIDExtension: UInt8(extensionIDs[2]),
            inputWatermarkExtension: UInt8(extensionIDs[3]),
            encoderTimingExtension: UInt8(extensionIDs[4]),
            flexFECSSRC: flexFEC?.ssrc ?? 0,
            flexFECPayloadType: flexFEC?.payloadType ?? 0,
            flexFECRepairWindowMicroseconds: flexFEC?.repairWindowMicroseconds ?? 0,
            flexFECMaximumGroupPackets: flexFEC?.maximumGroupPackets ?? 0,
            rtxSSRC: rtx?.ssrc ?? 0,
            rtxPayloadType: rtx?.payloadType ?? 0,
            rtxAssociatedPayloadType: rtx?.associatedPayloadType ?? 0
        ))
    }

    private static func videoCodecConfiguration(
        value: DeterministicCBORValue,
        expectedCodec: UInt8
    ) throws -> LSPVideoCodecConfiguration {
        let values = try DeterministicCBOR.exactMap(value, count: 2)
        guard let codec = LSPVideoCodec(rawValue: try uint8(values[0], nonzero: true)),
              codec.rawValue == expectedCodec,
              case .array(let encodedUnits) = values[1]
        else { throw DeterministicCBORError.malformed }
        let expectedCount = switch codec {
        case .h264: 2
        case .hevc: 3
        case .av1: 1
        }
        guard encodedUnits.count == expectedCount else { throw DeterministicCBORError.malformed }
        let units = try encodedUnits.map { value -> Data in
            guard case .bytes(let bytes) = value, !bytes.isEmpty, bytes.count <= 512 else {
                throw DeterministicCBORError.malformed
            }
            return bytes
        }
        switch codec {
        case .h264:
            guard units.map({ $0[0] & 0x1f }) == [7, 8], units.allSatisfy(isPrefixFreeNAL) else {
                throw DeterministicCBORError.malformed
            }
        case .hevc:
            guard units.allSatisfy({ $0.count >= 2 }),
                  units.map({ ($0[0] >> 1) & 0x3f }) == [32, 33, 34],
                  units.allSatisfy(isPrefixFreeNAL) else {
                throw DeterministicCBORError.malformed
            }
        case .av1:
            guard isCanonicalAV1SequenceHeader(units[0]) else { throw DeterministicCBORError.malformed }
        }
        return .init(codec: codec, units: units)
    }

    private static func videoHDRMetadata(value: DeterministicCBORValue) throws -> LSPVideoHDRMetadata? {
        if case .null = value { return nil }
        let values = try DeterministicCBOR.exactMap(value, count: 13)
        let fields = try values.map { try uint32($0, nonzero: false) }
        let points = stride(from: 0, to: 8, by: 2).map { (fields[$0], fields[$0 + 1]) }
        guard points.allSatisfy({ $0.0 > 0 && $0.1 > 0 && $0.0 <= 50_000 && $0.1 <= 50_000 }),
              points[0] != points[1], points[0] != points[2], points[1] != points[2],
              fields[8] > 0, fields[8] <= UInt16.max,
              UInt64(fields[9]) <= UInt64(fields[8]) * 10_000,
              fields[9] <= UInt16.max,
              fields[10] <= UInt16.max, fields[11] <= UInt16.max,
              (fields[10] == 0) == (fields[11] == 0),
              fields[11] <= fields[10],
              fields[12] <= UInt16.max,
              fields[12] == 0 || fields[12] <= fields[8]
        else { throw DeterministicCBORError.malformed }
        return .init(
            displayPrimaryRedX: fields[0], displayPrimaryRedY: fields[1],
            displayPrimaryGreenX: fields[2], displayPrimaryGreenY: fields[3],
            displayPrimaryBlueX: fields[4], displayPrimaryBlueY: fields[5],
            whitePointX: fields[6], whitePointY: fields[7],
            maximumDisplayLuminance: fields[8], minimumDisplayLuminance: fields[9],
            maximumContentLightLevel: fields[10], maximumFrameAverageLightLevel: fields[11],
            maximumFullFrameLuminance: fields[12]
        )
    }

    private static func flexFECSelection(
        value: DeterministicCBORValue,
        primarySSRC: UInt32,
        primaryPayloadType: UInt8
    ) throws -> LSPVideoFlexFECSelection? {
        if case .null = value { return nil }
        let values = try DeterministicCBOR.exactMap(value, count: 4)
        let result = LSPVideoFlexFECSelection(
            ssrc: try uint32(values[0], nonzero: true),
            payloadType: try uint8(values[1], nonzero: true),
            repairWindowMicroseconds: try uint32(values[2], nonzero: true),
            maximumGroupPackets: try uint8(values[3], nonzero: true)
        )
        guard result.ssrc != primarySSRC,
              (96...127).contains(result.payloadType),
              result.payloadType != primaryPayloadType,
              result.repairWindowMicroseconds <= 1_000_000,
              result.maximumGroupPackets == 15
        else { throw DeterministicCBORError.malformed }
        return result
    }

    private static func rtxSelection(
        value: DeterministicCBORValue,
        primarySSRC: UInt32,
        primaryPayloadType: UInt8
    ) throws -> LSPVideoRTXSelection? {
        if case .null = value { return nil }
        let values = try DeterministicCBOR.exactMap(value, count: 3)
        let result = LSPVideoRTXSelection(
            ssrc: try uint32(values[0], nonzero: true),
            payloadType: try uint8(values[1], nonzero: true),
            associatedPayloadType: try uint8(values[2], nonzero: true)
        )
        guard result.ssrc != primarySSRC,
              (96...127).contains(result.payloadType),
              result.payloadType != primaryPayloadType,
              result.associatedPayloadType == primaryPayloadType
        else { throw DeterministicCBORError.malformed }
        return result
    }

    private static func videoTupleIsValid(
        codec: LSPVideoCodec,
        profile: LSPVideoProfile,
        pixelFormat: LSPVideoPixelFormat
    ) -> Bool {
        switch (codec, profile, pixelFormat) {
        case (.h264, .h264High, .yuv4208Bit),
             (.h264, .h264High444, .yuv4448Bit),
             (.hevc, .hevcMain, .yuv4208Bit),
             (.hevc, .hevcMain10, .yuv42010Bit),
             (.hevc, .hevcRangeExtensions, .yuv4448Bit),
             (.hevc, .hevcRangeExtensions, .yuv44410Bit),
             (.av1, .av1Main, .yuv4208Bit),
             (.av1, .av1Main, .yuv42010Bit),
             (.av1, .av1High, .yuv4448Bit),
             (.av1, .av1High, .yuv44410Bit):
            true
        default:
            false
        }
    }

    private static func laneIdentifiersAreGloballyUnique(
        inputSSRC: UInt32,
        acknowledgementSSRC: UInt32,
        inputPayloadType: UInt8,
        audio: LSPNativeAudioConfiguration,
        microphone: LSPNativeMicrophoneConfiguration?,
        video: LSPNativeVideoConfiguration
    ) -> Bool {
        var ssrcs = [inputSSRC, acknowledgementSSRC, audio.audioSSRC, video.primarySSRC]
        var payloadTypes = [inputPayloadType, audio.audioPayloadType, video.primaryPayloadType]
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

    private static func isPrefixFreeNAL(_ bytes: Data) -> Bool {
        !(bytes.count >= 3 && bytes[0] == 0 && bytes[1] == 0 &&
          (bytes[2] == 1 || (bytes.count >= 4 && bytes[2] == 0 && bytes[3] == 1)))
    }

    private static func isCanonicalAV1SequenceHeader(_ bytes: Data) -> Bool {
        guard bytes.count >= 3,
              bytes[0] & 0x81 == 0,
              (bytes[0] >> 3) & 0x0f == 1,
              bytes[0] & 0x02 != 0
        else { return false }
        var value = 0
        var shift = 0
        var index = 1
        var encodedLength = 0
        if bytes[0] & 0x04 != 0 {
            guard index < bytes.count, bytes[index] & 0x07 == 0 else { return false }
            index += 1
        }
        while index < bytes.count, encodedLength < 8 {
            let byte = bytes[index]
            index += 1
            encodedLength += 1
            value |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return value != 0 && value == bytes.count - index &&
                    (encodedLength == 1 || byte & 0x7f != 0)
            }
            shift += 7
        }
        return false
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

    private static func uint8(_ value: DeterministicCBORValue, nonzero: Bool) throws -> UInt8 {
        let integer = try uint(value)
        guard integer <= UInt8.max, !nonzero || integer != 0 else {
            throw DeterministicCBORError.malformed
        }
        return UInt8(integer)
    }

    private static func boolean(_ value: DeterministicCBORValue) throws -> Bool {
        guard case .boolean(let decoded) = value else { throw DeterministicCBORError.malformed }
        return decoded
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
