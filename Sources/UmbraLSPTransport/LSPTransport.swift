import CLSPCore
import Dispatch
import Foundation

/// Congestion profile selected for an LSP connection.
public enum LSPTransportProfile: Equatable, Sendable {
    /// Safe delay-adaptive behavior for ordinary networks.
    case adaptiveLowLatency

    /// Explicitly provisioned competition-LAN behavior.
    case competitionLAN(capacityMbps: UInt32)
}

/// Coarse native transport construction settings.
public struct LSPTransportConfiguration: Equatable, Sendable {
    /// LSP UDP application port.
    public var port: UInt16

    /// Congestion-control profile and optional explicit capacity ceiling.
    public var profile: LSPTransportProfile

    /// Low-rate telemetry publication interval.
    public var telemetryInterval: Duration

    /// Maximum synchronous DTLS authentication time.
    public var handshakeTimeout: Duration

    /// Creates transport settings without starting a connection.
    ///
    /// - Parameters:
    ///   - port: Nonzero LSP UDP application port.
    ///   - profile: Safe adaptive profile by default.
    ///   - telemetryInterval: Snapshot interval; values below 250 ms are rejected.
    ///   - handshakeTimeout: Exact-security startup deadline from one through 30 seconds.
    public init(
        port: UInt16 = 48_030,
        profile: LSPTransportProfile = .adaptiveLowLatency,
        telemetryInterval: Duration = .seconds(1),
        handshakeTimeout: Duration = .seconds(5)
    ) {
        self.port = port
        self.profile = profile
        self.telemetryInterval = telemetryInterval
        self.handshakeTimeout = handshakeTimeout
    }
}

/// Exact remote LSP endpoint derived from validated discovery or persisted trust.
public struct LSPTransportEndpoint: Equatable, Sendable {
    /// DNS name or numeric IP literal.
    public var host: String

    /// Single LSP UDP application port.
    public var port: UInt16

    /// SHA-256 digest of the server certificate's DER SubjectPublicKeyInfo.
    public var serverSPKISHA256: Data

    /// Creates a pinned endpoint.
    public init(host: String, port: UInt16 = 48_030, serverSPKISHA256: Data) {
        self.host = host
        self.port = port
        self.serverSPKISHA256 = serverSPKISHA256
    }
}

/// Security providers linked into the native LSP core.
public struct LSPTransportProviders: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Commercial wolfSSL DTLS 1.3 provider.
    public static let wolfSSL = Self(rawValue: UInt32(CLSP_PROVIDER_WOLFSSL.rawValue))

    /// libSRTP AES-128-GCM provider.
    public static let libSRTP = Self(rawValue: UInt32(CLSP_PROVIDER_LIBSRTP.rawValue))
}

/// Native lifecycle state copied at telemetry frequency.
public enum LSPTransportLifecycle: UInt32, Sendable {
    case created = 0
    case connecting = 1
    case authenticated = 2
    case stopped = 3
    case failed = 4
}

/// Native handoff reason mirrored from the versioned C ABI.
public enum LSPNativeHandoffReason: UInt32, Sendable {
    case transportLoss = 1
    case plannedRekey = 2
}

/// Native reconnect authority phase copied at telemetry frequency.
public enum LSPNativeHandoffPhase: UInt32, Sendable {
    case authoritative = 1
    case activeLost = 2
    case candidateHandshake = 3
    case candidateAuthenticated = 4
    case oldInputNeutralized = 5
    case attachSubmitted = 6
    case rollbackPending = 7
    case committedBaseline = 8
    case terminal = 9
}

/// Secret-free native handoff snapshot.
public struct LSPNativeHandoffSnapshot: Sendable, Equatable {
    public var phase: LSPNativeHandoffPhase
    public var activeConnectionGeneration: UInt32
    public var activeInputGeneration: UInt32
    public var candidateConnectionGeneration: UInt32
    public var inputAuthorityEpoch: UInt32
    public var connectionGenerationHighWatermark: UInt32
    public var rollbackConnectionGeneration: UInt32
    public var retiringConnectionGeneration: UInt32
    public var baselineRequired: Bool
    public var forwardOnly: Bool
    public var committedCount: UInt64
    public var rollbackCount: UInt64
    public var terminalCount: UInt64
}

public enum LSPNativeBaselineEventKind: UInt32, Sendable {
    case required = 1
    case acknowledged = 2
}

public struct LSPNativeBaselineEvent: Sendable, Equatable {
    public var kind: LSPNativeBaselineEventKind
    public var inputGeneration: UInt32
    public var inputAuthorityEpoch: UInt32
    public var connectionGeneration: UInt32
    public var rollbackConnectionGeneration: UInt32
}

/// Association-local baseline readiness that does not claim a handoff observer.
public struct LSPNativeInputBaselineSnapshot: Sendable, Equatable {
    public var connectionGeneration: UInt32
    public var inputGeneration: UInt32
    public var inputAuthorityEpoch: UInt32
    public var eventGeneration: UInt64
    public var acknowledged: Bool
}

/// Coarse authenticated LSPI delivery and effective-rate evidence.
public struct LSPNativeInputFeedbackSnapshot: Sendable, Equatable {
    public var streamGeneration: UInt32
    public var inputGeneration: UInt32
    public var acceptedBaselineID: UInt64
    public var contiguousEdgeID: UInt64
    public var edgeReceptionBitmap: UInt64
    public var receivedAtMicroseconds: UInt64
    public var pointerRate: UInt32
    public var controllerRate: UInt32
    public var sensorRate: UInt32
    public var reconciliationRate: UInt32
    public var reservedInputWireBitsPerSecond: UInt64
    public var baselineAcknowledged: Bool
    public var baselineRequested: Bool
}

/// Newest locally assigned edge identity used for atomic text/IME barriers.
public struct LSPNativeInputEdgeSnapshot: Sendable, Equatable {
    public var streamGeneration: UInt32
    public var inputGeneration: UInt32
    public var latestAssignedEdgeID: UInt64
    public var latestEdgeSampleTimeMicroseconds: UInt64
}

/// Clock-domain and availability evidence attached to native timing samples.
public struct LSPNativeTimingFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let available = Self(rawValue: 1 << 0)
    public static let clientMonotonic = Self(rawValue: 1 << 1)
    public static let kernelTimestamped = Self(rawValue: 1 << 2)
    public static let sameEndpoint = Self(rawValue: 1 << 3)
    public static let unknownComponent = Self(rawValue: 1 << 4)
    public static let partialWireBytes = Self(rawValue: 1 << 5)
    public static let allKnown: Self = [
        .available, .clientMonotonic, .kernelTimestamped,
        .sameEndpoint, .unknownComponent, .partialWireBytes,
    ]
}

/// Allocation-free native fixed-bucket distribution published at coarse cadence.
public struct LSPNativeDistribution: Sendable, Equatable {
    public var count: UInt64
    public var p50Microseconds: UInt64
    public var p95Microseconds: UInt64
    public var p99Microseconds: UInt64
    public var maximumMicroseconds: UInt64
    public var drops: UInt64
    public var flags: LSPNativeTimingFlags
}

/// Low-rate native device-generation offer for automatic INPUT_RATE negotiation.
public struct LSPNativeDeviceOffer: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case arrived = 1, removed = 2, rateObserved = 3 }
    public enum DeviceType: UInt8, Sendable { case pointer = 1, controller = 2 }
    public enum CaptureSource: UInt8, Sendable { case ioHID = 1, gameController = 2, appKit = 3 }
    public var sequence: UInt64
    public var kind: Kind
    public var deviceType: DeviceType
    public var captureSource: CaptureSource
    public var deviceID: UInt32
    public var instanceGeneration: UInt32
    public var observedCaptureHz: UInt32
    public var observedSensorHz: UInt32
    public var minimumStateRate: UInt32
    public var maximumStateRate: UInt32
    public var minimumSensorRate: UInt32
    public var maximumSensorRate: UInt32
    public var capturedSamples: UInt64
    public var droppedSamples: UInt64
    public var attributedWireBytes: UInt64
    public var effectiveWireBitsPerSecond: UInt64
    public var stateSpacing: LSPNativeDistribution
    public var sensorSpacing: LSPNativeDistribution
    public var minimumSampleIntervalMicroseconds: UInt32
    public var maximumSampleIntervalMicroseconds: UInt32
    public var maximumStatePacketBytes: UInt16
    public var maximumSensorPacketBytes: UInt16
}

/// Client-side native PIN-pairing lifecycle copied only at control frequency.
public enum LSPNativePairingPhase: UInt32, Sendable {
    case created = 0
    case begun = 1
    case pendingBound = 2
    case challengeAccepted = 3
    case complete = 4
    case cancelled = 5
    case failed = 6
}

/// Native-generated public PAKE material and the user-visible six-digit PIN.
public struct LSPNativePairingBegin: Equatable, Sendable {
    public var pin: String
    public var scryptSalt: Data
    public var clientPairingNonce: Data
    public var clientPublicValue: Data
}

/// Native-generated client confirmation and exact Ed25519 signature input.
public struct LSPNativePairingClientConfirmation: Equatable, Sendable {
    public var sessionID: UUID
    public var approvalGeneration: UInt32
    public var permissions: UInt32
    public var expiresAtUTCSeconds: UInt64
    public var clientConfirmation: Data
    public var clientSignatureInput: Data
}

/// Native-verified host confirmation and exact Ed25519 signature input.
public struct LSPNativePairingResult: Equatable, Sendable {
    public var sessionID: UUID
    public var approvalGeneration: UInt32
    public var permissions: UInt32
    public var revocationGeneration: UInt32
    public var expiresAtUTCSeconds: UInt64
    public var hostSignatureInput: Data
}

/// Secret-free native pairing state suitable for UI polling and diagnostics.
public struct LSPNativePairingSnapshot: Equatable, Sendable {
    public var phase: LSPNativePairingPhase
    public var permissions: UInt32
    public var approvalGeneration: UInt32
    public var revocationGeneration: UInt32
    public var expiresAtUTCSeconds: UInt64
}

/// Authenticated version-one LSPC flags.
public struct LSPControlFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let acknowledgementRequired = Self(rawValue: 1 << 0)
    public static let response = Self(rawValue: 1 << 1)
    public static let errorResponse = Self(rawValue: 1 << 2)
    public static let acknowledgementOnly = Self(rawValue: 1 << 3)
    public static let finalChunk = Self(rawValue: 1 << 4)
}

/// One authenticated, de-duplicated LSPC frame copied at control frequency.
public struct LSPControlEvent: Equatable, Sendable {
    public var messageType: UInt16
    public var flags: LSPControlFlags
    public var connectionGeneration: UInt32
    public var messageID: UInt64
    public var requestID: UInt64
    public var payload: Data
}

/// Exact input-only START_RESPONSE mapping installed in the native packet worker.
public struct LSPNativeInputConfiguration: Equatable, Sendable {
    public var streamGeneration: UInt32
    public var inputGeneration: UInt32
    public var inputSSRC: UInt32
    public var acknowledgementSSRC: UInt32
    public var inputPayloadType: UInt8
    public var pointerRate: UInt32
    public var controllerRate: UInt32
    public var sensorRate: UInt32
    public var reconciliationRate: UInt32
    public var reservedInputWireBitsPerSecond: UInt64
    public var baselineRequired: Bool

    public init(
        streamGeneration: UInt32,
        inputGeneration: UInt32,
        inputSSRC: UInt32,
        acknowledgementSSRC: UInt32,
        inputPayloadType: UInt8,
        pointerRate: UInt32,
        controllerRate: UInt32,
        sensorRate: UInt32,
        reconciliationRate: UInt32,
        reservedInputWireBitsPerSecond: UInt64,
        baselineRequired: Bool
    ) {
        self.streamGeneration = streamGeneration
        self.inputGeneration = inputGeneration
        self.inputSSRC = inputSSRC
        self.acknowledgementSSRC = acknowledgementSSRC
        self.inputPayloadType = inputPayloadType
        self.pointerRate = pointerRate
        self.controllerRate = controllerRate
        self.sensorRate = sensorRate
        self.reconciliationRate = reconciliationRate
        self.reservedInputWireBitsPerSecond = reservedInputWireBitsPerSecond
        self.baselineRequired = baselineRequired
    }
}

/// Exact native host-audio SSRC/PT/generation admission tuple.
public struct LSPNativeAudioConfiguration: Equatable, Sendable {
    public var streamGeneration: UInt32
    public var audioGeneration: UInt32
    public var audioSSRC: UInt32
    public var audioPayloadType: UInt8
    public var channels: UInt8
    public var streams: UInt8
    public var coupledStreams: UInt8
    public var mapping: [UInt8]
    public var frameSamples: UInt16
    public var bitrate: UInt32
    public var inbandFEC: Bool
    public var dtx: Bool
    public var udpPayloadSize: UInt16

    public init(
        streamGeneration: UInt32,
        audioGeneration: UInt32,
        audioSSRC: UInt32,
        audioPayloadType: UInt8,
        channels: UInt8,
        streams: UInt8,
        coupledStreams: UInt8,
        mapping: [UInt8],
        frameSamples: UInt16,
        bitrate: UInt32,
        inbandFEC: Bool,
        dtx: Bool,
        udpPayloadSize: UInt16
    ) {
        self.streamGeneration = streamGeneration
        self.audioGeneration = audioGeneration
        self.audioSSRC = audioSSRC
        self.audioPayloadType = audioPayloadType
        self.channels = channels
        self.streams = streams
        self.coupledStreams = coupledStreams
        self.mapping = mapping
        self.frameSamples = frameSamples
        self.bitrate = bitrate
        self.inbandFEC = inbandFEC
        self.dtx = dtx
        self.udpPayloadSize = udpPayloadSize
    }
}

/// One native-authenticated complete Opus packet.
public struct LSPAudioPacket: Equatable, Sendable {
    public var audioGeneration: UInt32
    public var ssrc: UInt32
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var marker: Bool
    public var opusPacket: Data
}

/// Authenticated RTCP sender-report relation for the 48-kHz audio clock.
public struct LSPAudioTiming: Equatable, Sendable {
    public var audioGeneration: UInt32
    public var ssrc: UInt32
    public var ntpSeconds: UInt32
    public var ntpFraction: UInt32
    public var rtpTimestamp: UInt32
}

/// Exact native reverse-microphone RTP/SRTP sender tuple.
public struct LSPNativeMicrophoneConfiguration: Equatable, Sendable {
    public var streamGeneration: UInt32
    public var microphoneGeneration: UInt32
    public var microphoneSSRC: UInt32
    public var microphonePayloadType: UInt8
    public var bitrate: UInt32
    public var inbandFEC: Bool
    public var dtx: Bool
    public var udpPayloadSize: UInt16

    public init(
        streamGeneration: UInt32,
        microphoneGeneration: UInt32,
        microphoneSSRC: UInt32,
        microphonePayloadType: UInt8,
        bitrate: UInt32,
        inbandFEC: Bool,
        dtx: Bool,
        udpPayloadSize: UInt16
    ) {
        self.streamGeneration = streamGeneration
        self.microphoneGeneration = microphoneGeneration
        self.microphoneSSRC = microphoneSSRC
        self.microphonePayloadType = microphonePayloadType
        self.bitrate = bitrate
        self.inbandFEC = inbandFEC
        self.dtx = dtx
        self.udpPayloadSize = udpPayloadSize
    }
}

/// Encoded access-unit representation retained across the C ABI.
public enum LSPVideoPayloadFormat: UInt8, Equatable, Sendable {
    case annexB = 1
    case av1LowOverheadOBU = 2
}

/// Exact authenticated native video admission tuple.
public struct LSPNativeVideoConfiguration: Equatable, Sendable {
    public var streamGeneration: UInt32
    public var videoGeneration: UInt32
    public var primarySSRC: UInt32
    public var primaryPayloadType: UInt8
    public var codec: UInt8
    public var profile: UInt8
    public var pixelFormat: UInt8
    public var colorPrimaries: UInt8
    public var transferCharacteristics: UInt8
    public var matrixCoefficients: UInt8
    public var fullRange: Bool
    public var delivery: UInt8
    public var payloadFormat: UInt8
    public var width: UInt32
    public var height: UInt32
    public var refreshNumerator: UInt32
    public var refreshDenominator: UInt32
    public var bitrate: UInt32
    public var maximumAccessUnitBytes: UInt32
    public var maximumFrameAgeMicroseconds: UInt32
    public var frameIDOrigin: UInt64
    public var recoveryEpoch: UInt32
    public var decoderSurfaces: UInt8
    public var udpPayloadSize: UInt16
    public var frameMarkingExtension: UInt8
    public var absoluteCaptureExtension: UInt8
    public var frameIDExtension: UInt8
    public var inputWatermarkExtension: UInt8
    public var encoderTimingExtension: UInt8
    public var flexFECSSRC: UInt32
    public var flexFECPayloadType: UInt8
    public var flexFECRepairWindowMicroseconds: UInt32
    public var flexFECMaximumGroupPackets: UInt8
    public var rtxSSRC: UInt32
    public var rtxPayloadType: UInt8
    public var rtxAssociatedPayloadType: UInt8

    public init(
        streamGeneration: UInt32, videoGeneration: UInt32, primarySSRC: UInt32,
        primaryPayloadType: UInt8, codec: UInt8, profile: UInt8,
        pixelFormat: UInt8, colorPrimaries: UInt8, transferCharacteristics: UInt8,
        matrixCoefficients: UInt8, fullRange: Bool, delivery: UInt8, payloadFormat: UInt8,
        width: UInt32,
        height: UInt32, refreshNumerator: UInt32, refreshDenominator: UInt32,
        bitrate: UInt32, maximumAccessUnitBytes: UInt32,
        maximumFrameAgeMicroseconds: UInt32, frameIDOrigin: UInt64,
        recoveryEpoch: UInt32, decoderSurfaces: UInt8, udpPayloadSize: UInt16,
        frameMarkingExtension: UInt8, absoluteCaptureExtension: UInt8,
        frameIDExtension: UInt8, inputWatermarkExtension: UInt8,
        encoderTimingExtension: UInt8,
        flexFECSSRC: UInt32 = 0, flexFECPayloadType: UInt8 = 0,
        flexFECRepairWindowMicroseconds: UInt32 = 0,
        flexFECMaximumGroupPackets: UInt8 = 0,
        rtxSSRC: UInt32 = 0, rtxPayloadType: UInt8 = 0,
        rtxAssociatedPayloadType: UInt8 = 0
    ) {
        self.streamGeneration = streamGeneration; self.videoGeneration = videoGeneration
        self.primarySSRC = primarySSRC; self.primaryPayloadType = primaryPayloadType
        self.codec = codec; self.profile = profile; self.width = width; self.height = height
        self.pixelFormat = pixelFormat; self.colorPrimaries = colorPrimaries
        self.transferCharacteristics = transferCharacteristics
        self.matrixCoefficients = matrixCoefficients; self.fullRange = fullRange
        self.delivery = delivery; self.payloadFormat = payloadFormat
        self.refreshNumerator = refreshNumerator; self.refreshDenominator = refreshDenominator
        self.bitrate = bitrate; self.maximumAccessUnitBytes = maximumAccessUnitBytes
        self.maximumFrameAgeMicroseconds = maximumFrameAgeMicroseconds
        self.frameIDOrigin = frameIDOrigin; self.recoveryEpoch = recoveryEpoch
        self.decoderSurfaces = decoderSurfaces; self.udpPayloadSize = udpPayloadSize
        self.frameMarkingExtension = frameMarkingExtension
        self.absoluteCaptureExtension = absoluteCaptureExtension
        self.frameIDExtension = frameIDExtension
        self.inputWatermarkExtension = inputWatermarkExtension
        self.encoderTimingExtension = encoderTimingExtension
        self.flexFECSSRC = flexFECSSRC; self.flexFECPayloadType = flexFECPayloadType
        self.flexFECRepairWindowMicroseconds = flexFECRepairWindowMicroseconds
        self.flexFECMaximumGroupPackets = flexFECMaximumGroupPackets
        self.rtxSSRC = rtxSSRC; self.rtxPayloadType = rtxPayloadType
        self.rtxAssociatedPayloadType = rtxAssociatedPayloadType
    }
}

/// One native-owned complete encoded access unit transferred without copying.
public struct LSPEncodedVideoAccessUnit: @unchecked Sendable {
    public var videoGeneration: UInt32
    public var rtpTimestamp: UInt32
    public var frameID: UInt64
    public var receiveTimeMicroseconds: UInt64
    public var captureTimeMicroseconds: UInt64
    /// Authenticated host encoder-completion minus encoder-submit duration.
    public var hostEncoderDurationMicroseconds: UInt32?
    public var inputStateSequence: UInt64
    public var inputEdgeID: UInt64
    public var recoveryEpoch: UInt32
    public var independent: Bool
    public var codec: UInt8
    public var payloadFormat: LSPVideoPayloadFormat
    public var encodedAccessUnit: Data
}

/// Typed terminal video outcome sent in protected LSPV feedback.
public enum LSPVideoDecodeStatus: UInt8, Sendable {
    case ready = 0
    case surfaceExhausted = 1
    case recoverableError = 2
    case unrecoverableError = 3
}

/// Coarse native DPLPMTUD event kind; never emitted per media packet.
public enum LSPPathProbeEventKind: UInt8, Sendable {
    case sendIntent = 1
    case received = 2
    case requestFailed = 3
}

/// One native path-probe lifecycle event at reliable-control frequency.
public struct LSPPathProbeEvent: Equatable, Sendable {
    public var kind: LSPPathProbeEventKind
    public var probeID: UInt64
    public var requestID: UInt64
    public var udpPayloadSize: UInt16
}

/// Native exactly-once input-edge kind.
public enum LSPNativeInputEdgeKind: UInt8, Sendable {
    case keyDown = 1
    case keyUp = 2
    case pointerButtonDown = 3
    case pointerButtonUp = 4
}

/// Low-rate telemetry copied from the native packet core.
public struct LSPTelemetrySnapshot: Equatable, Sendable {
    /// Coarse native lifecycle state.
    public var lifecycle: LSPTransportLifecycle

    /// Production security providers linked into the native core.
    public var providers: LSPTransportProviders

    /// Authenticated receive count.
    public var receivedDatagrams: UInt64

    /// Socket submission count.
    public var transmittedDatagrams: UInt64

    /// Count discarded by bounded native policy.
    public var droppedDatagrams: UInt64

    /// DTLS, SRTP, and SRTCP authentication failure count.
    public var authenticationFailures: UInt64

    public var videoReceivedIPBytes: UInt64
    public var congestionFeedbackIPBytes: UInt64
    public var congestionFeedbackPackets: UInt64
    public var videoECNUnknownPackets: UInt64
    public var videoECNCEPackets: UInt64
    public var pathProbesSent: UInt64
    public var pathProbesAcknowledged: UInt64
    public var pathProbeTimeouts: UInt64
    public var currentUDPPayloadSize: UInt16
    public var currentReceiveUDPPayloadSize: UInt16
}

/// Fixed order of same-endpoint native timing stages.
public enum LSPNativeTimingStage: Int, CaseIterable, Sendable {
    case inputCallbackToCompose = 0
    case inputComposeToProtect
    case inputProtectToSubmit
    case inputAcknowledgementAge
    case receiveToAuthentication
    case authenticationToHandoff
    case socketBatchDrain
    case socketBatchOldestAge
}

/// Coarse per-device capture and attributable-wire telemetry.
public struct LSPNativeDeviceTelemetry: Sendable, Equatable {
    public var deviceType: LSPNativeDeviceOffer.DeviceType
    public var captureSource: LSPNativeDeviceOffer.CaptureSource
    public var deviceID: UInt32
    public var instanceGeneration: UInt32
    public var active: Bool
    public var observedStateHz: UInt32
    public var observedSensorHz: UInt32
    public var capturedSamples: UInt64
    public var droppedSamples: UInt64
    public var attributedWireBytes: UInt64
    public var stateSpacing: LSPNativeDistribution
    public var sensorSpacing: LSPNativeDistribution
}

/// Latest worker-published timing distributions and active native generations.
public struct LSPNativeTimingSnapshot: Sendable, Equatable {
    public var generation: UInt64
    public var snapshotTimeMicroseconds: UInt64
    public var streamGeneration: UInt32
    public var inputGeneration: UInt32
    public var videoGeneration: UInt32
    public var audioGeneration: UInt32
    public var pointerGeneration: UInt32
    public var controllerGenerations: [UInt32]
    public var touchGenerations: [UInt32]
    public var penGenerations: [UInt32]
    public var stages: [LSPNativeDistribution]
    public var devices: [LSPNativeDeviceTelemetry]
}

/// Stable typed failure returned by the coarse LSP transport façade.
public enum LSPTransportError: Error, Equatable, LocalizedError, Sendable {
    case abiMismatch(expected: UInt32, actual: UInt32)
    case sourceDigestMismatch(expected: String, actual: String)
    case missingWolfSSL
    case missingLibSRTP
    case invalidConfiguration
    case invalidState
    case reentrantCallback
    case resourceExhausted
    case unsupported
    case internalFailure
    case invalidEndpoint
    case socketFailure
    case dtlsFailure
    case spkiMismatch
    case srtpFailure
    case notAuthenticated
    case controlWindowFull
    case timeout
    case inputPermissionDenied
    case inputUnavailable
    case rollbackPending
    case pairingFailed
    case pairingExpired
    case pairingGenerationMismatch
    case pairingConfirmationFailed
    case unknownStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .abiMismatch(let expected, let actual):
            "Umbra's streaming component is out of date (expected \(expected), received \(actual)). Reinstall Umbra."
        case .sourceDigestMismatch:
            "Umbra's streaming component does not match this build. Reinstall Umbra."
        case .missingWolfSSL:
            "This build of Umbra is missing its secure streaming support."
        case .missingLibSRTP:
            "This build of Umbra is missing its media encryption support."
        case .invalidConfiguration:
            "The stream connection settings are invalid."
        case .invalidState:
            "The stream connection was in an unexpected state."
        case .reentrantCallback:
            "The stream connection was changed at an unsupported time."
        case .resourceExhausted:
            "Umbra ran out of stream connection resources."
        case .unsupported:
            "This streaming feature is not supported yet."
        case .internalFailure:
            "The stream connection failed unexpectedly."
        case .invalidEndpoint:
            "The saved host address or security identity is invalid. Pair the host again."
        case .socketFailure:
            "Couldn't reach the host. Check the host address, your network connection, and Umbra's Local Network access."
        case .dtlsFailure:
            "Couldn't establish a secure connection to the host."
        case .spkiMismatch:
            "The host's identity changed since pairing. Pair the host again."
        case .srtpFailure:
            "Couldn't set up media encryption for the stream."
        case .notAuthenticated:
            "The connection to the host is not authenticated."
        case .controlWindowFull:
            "The host is busy handling earlier requests. Try again."
        case .timeout:
            "The host didn't respond in time."
        case .inputPermissionDenied:
            "macOS denied preferred raw HID input capture."
        case .inputUnavailable:
            "Preferred native input capture is unavailable."
        case .rollbackPending:
            "Native input rollback is waiting for the fresh baseline acknowledgement."
        case .pairingFailed:
            "PIN pairing failed."
        case .pairingExpired:
            "The pairing PIN expired."
        case .pairingGenerationMismatch:
            "The pairing response does not match this request. Try pairing again."
        case .pairingConfirmationFailed:
            "The host's pairing confirmation could not be verified."
        case .unknownStatus(let status):
            "The stream connection returned an unknown status (\(status))."
        }
    }
}

/// Coarse application lifecycle boundary over the native C++23 LSP core.
///
/// This type never receives a per-packet or raw-input callback. Swift owns only
/// configuration, start/stop, and low-rate telemetry snapshots.
public final class LSPTransport: @unchecked Sendable {
    /// ABI version compiled into the Swift façade.
    public static let abiVersion: UInt32 = 3

    /// Expected source digest for the pinned Photon portable protocol core.
    public static let sourceDigest = "d565644e8c3a00d6c474d6c118b8b8eccd3140d35eda54dbb0bba7c42f1ca7f0"

    /// Providers compiled into the native target.
    public static var availableProviders: LSPTransportProviders {
        LSPTransportProviders(rawValue: clsp_core_provider_flags())
    }

    fileprivate let core: OpaquePointer
    private let callbackState: LSPNativeCallbackState

    /// Validates ABI and source identity, then creates an inactive native handle.
    ///
    /// - Parameter configuration: Coarse construction settings.
    /// - Throws: `LSPTransportError` on ABI, digest, or configuration failure.
    public init(configuration: LSPTransportConfiguration = .init()) throws {
        let actualABIVersion = clsp_core_abi_version()
        guard actualABIVersion == Self.abiVersion else {
            throw LSPTransportError.abiMismatch(expected: Self.abiVersion, actual: actualABIVersion)
        }
        let actualDigest = String(cString: clsp_core_source_digest())
        guard actualDigest == Self.sourceDigest else {
            throw LSPTransportError.sourceDigestMismatch(expected: Self.sourceDigest, actual: actualDigest)
        }

        callbackState = LSPNativeCallbackState()
        var nativeConfiguration = try Self.makeNativeConfiguration(configuration)
        var nativeCallbacks = clsp_callbacks_t()
        nativeCallbacks.abi_version = Self.abiVersion
        nativeCallbacks.structure_size = UInt32(MemoryLayout<clsp_callbacks_t>.size)
        nativeCallbacks.context = Unmanaged.passUnretained(callbackState).toOpaque()
        nativeCallbacks.retain_context = lspRetainCallbackContext
        nativeCallbacks.release_context = lspReleaseCallbackContext
        nativeCallbacks.lifecycle = lspLifecycleCallback
        nativeCallbacks.control = lspControlCallback
        nativeCallbacks.audio_packet = lspAudioPacketCallback
        nativeCallbacks.audio_timing = lspAudioTimingCallback
        nativeCallbacks.video_access_unit = lspVideoAccessUnitCallback
        nativeCallbacks.path_probe = lspPathProbeCallback
        var output: OpaquePointer?
        let status = clsp_core_create(&nativeConfiguration, &nativeCallbacks, &output)
        try Self.requireSuccess(status)
        guard let output else {
            throw LSPTransportError.internalFailure
        }
        core = output
    }

    deinit {
        _ = clsp_core_stop(core)
        clsp_core_release(core)
    }

    /// Starts and synchronously authenticates the pinned DTLS association.
    ///
    /// - Parameter endpoint: Discovery- or trust-derived host, port, and SPKI pin.
    /// - Throws: A fail-closed provider or lifecycle error.
    public func start(endpoint: LSPTransportEndpoint) throws {
        let hostBytes = Array(endpoint.host.utf8)
        guard !hostBytes.isEmpty, hostBytes.count <= 255, endpoint.port != 0,
              endpoint.serverSPKISHA256.count == 32,
              endpoint.serverSPKISHA256.contains(where: { $0 != 0 })
        else {
            throw LSPTransportError.invalidEndpoint
        }
        var native = clsp_endpoint_t()
        native.abi_version = Self.abiVersion
        native.structure_size = UInt32(MemoryLayout<clsp_endpoint_t>.size)
        native.port = endpoint.port
        endpoint.serverSPKISHA256.withUnsafeBytes { pinBytes in
            withUnsafeMutableBytes(of: &native.server_spki_sha256) { destination in
                destination.copyBytes(from: pinBytes)
            }
        }
        try hostBytes.withUnsafeBufferPointer { hostBuffer in
            native.host = clsp_const_byte_span_t(
                data: hostBuffer.baseAddress,
                length: hostBuffer.count
            )
            try Self.requireSuccess(clsp_core_start(core, &native))
        }
    }

    /// Stops and quiesces a running native transport.
    ///
    /// - Throws: A typed lifecycle error.
    public func stop() throws {
        try Self.requireSuccess(clsp_core_stop(core))
    }

    /// Binds the validated SERVER_HELLO identity to this authenticated DTLS association.
    public func bindHostHello(
        connectionGeneration: UInt32,
        hostID: UUID,
        hostIdentityKey: Data,
        serverSPKISHA256: Data,
        clientNonce: Data,
        serverNonce: Data
    ) throws {
        guard connectionGeneration != 0,
              hostIdentityKey.count == 32,
              serverSPKISHA256.count == 32,
              clientNonce.count == 32,
              serverNonce.count == 32 else {
            throw LSPTransportError.invalidConfiguration
        }
        var identity = clsp_host_hello_identity_t()
        identity.abi_version = Self.abiVersion
        identity.structure_size = UInt32(MemoryLayout<clsp_host_hello_identity_t>.size)
        identity.connection_generation = connectionGeneration
        Self.copyUUID(hostID, to: &identity.host_id)
        Self.copy(hostIdentityKey, to: &identity.host_identity_key)
        Self.copy(serverSPKISHA256, to: &identity.server_spki_sha256)
        Self.copy(clientNonce, to: &identity.client_nonce)
        Self.copy(serverNonce, to: &identity.server_nonce)
        try Self.requireSuccess(clsp_core_bind_host_hello(core, &identity))
    }

    /// Creates one native owner for a single six-digit PIN pairing attempt.
    public func makePairing(
        clientID: UUID,
        clientIdentityKey: Data,
        clientName: String,
        requestedPermissions: UInt32
    ) throws -> LSPNativePairing {
        try LSPNativePairing(
            transport: self,
            clientID: clientID,
            clientIdentityKey: clientIdentityKey,
            clientName: clientName,
            requestedPermissions: requestedPermissions
        )
    }

    /// Copies one low-rate telemetry snapshot without exposing packet storage.
    ///
    /// - Returns: Coarse counters and lifecycle state.
    /// - Throws: A typed native status.
    public func telemetrySnapshot() throws -> LSPTelemetrySnapshot {
        var native = clsp_telemetry_snapshot_t()
        try Self.requireSuccess(clsp_core_copy_telemetry(core, &native))
        guard let lifecycle = LSPTransportLifecycle(rawValue: native.lifecycle_state) else {
            throw LSPTransportError.internalFailure
        }
        return LSPTelemetrySnapshot(
            lifecycle: lifecycle,
            providers: LSPTransportProviders(rawValue: native.provider_flags),
            receivedDatagrams: native.received_datagrams,
            transmittedDatagrams: native.transmitted_datagrams,
            droppedDatagrams: native.dropped_datagrams,
            authenticationFailures: native.authentication_failures,
            videoReceivedIPBytes: native.video_received_ip_bytes,
            congestionFeedbackIPBytes: native.congestion_feedback_ip_bytes,
            congestionFeedbackPackets: native.congestion_feedback_packets,
            videoECNUnknownPackets: native.video_ecn_unknown_packets,
            videoECNCEPackets: native.video_ecn_ce_packets,
            pathProbesSent: native.path_probes_sent,
            pathProbesAcknowledged: native.path_probes_acknowledged,
            pathProbeTimeouts: native.path_probe_timeouts,
            currentUDPPayloadSize: native.current_udp_payload_size,
            currentReceiveUDPPayloadSize: native.current_receive_udp_payload_size
        )
    }

    /// Copies the latest worker-published local native timing distributions.
    ///
    /// No cross-machine duration is synthesized; flags expose kernel fallback
    /// and partial per-device wire attribution explicitly.
    public func nativeTimingSnapshot() throws -> LSPNativeTimingSnapshot {
        var native = clsp_native_timing_snapshot_t()
        try Self.requireSuccess(clsp_core_copy_native_timing(core, &native))
        guard native.abi_version == Self.abiVersion,
              native.structure_size == MemoryLayout<clsp_native_timing_snapshot_t>.size else {
            throw LSPTransportError.internalFailure
        }
        func distribution(_ value: clsp_native_distribution_t) throws -> LSPNativeDistribution {
            let flags = LSPNativeTimingFlags(rawValue: value.flags)
            guard value.reserved_zero == 0, flags.subtracting(.allKnown).isEmpty else {
                throw LSPTransportError.internalFailure
            }
            return .init(
                count: value.count,
                p50Microseconds: value.p50_microseconds,
                p95Microseconds: value.p95_microseconds,
                p99Microseconds: value.p99_microseconds,
                maximumMicroseconds: value.maximum_microseconds,
                drops: value.drops,
                flags: flags
            )
        }
        let nativeStages = withUnsafeBytes(of: &native.stages) { raw in
            Array(raw.bindMemory(to: clsp_native_distribution_t.self).prefix(Int(CLSP_NATIVE_TIMING_STAGE_COUNT)))
        }
        let stages = try nativeStages.map(distribution)
        guard stages.count == LSPNativeTimingStage.allCases.count else {
            throw LSPTransportError.internalFailure
        }
        let controllerGenerations = withUnsafeBytes(of: &native.controller_generations) { raw in
            Array(raw.bindMemory(to: UInt32.self).prefix(16))
        }
        let touchGenerations = withUnsafeBytes(of: &native.touch_generations) { raw in
            Array(raw.bindMemory(to: UInt32.self).prefix(16))
        }
        let penGenerations = withUnsafeBytes(of: &native.pen_generations) { raw in
            Array(raw.bindMemory(to: UInt32.self).prefix(16))
        }
        let nativeDevices = withUnsafeBytes(of: &native.devices) { raw in
            Array(raw.bindMemory(to: clsp_native_device_telemetry_t.self).prefix(Int(CLSP_NATIVE_TIMING_DEVICE_COUNT)))
        }
        let devices = try nativeDevices.compactMap { value -> LSPNativeDeviceTelemetry? in
            if value.device_id == 0 { return nil }
            guard let deviceType = LSPNativeDeviceOffer.DeviceType(rawValue: value.device_type),
                  let captureSource = LSPNativeDeviceOffer.CaptureSource(rawValue: value.capture_source),
                  value.instance_generation != 0, value.active <= 1,
                  withUnsafeBytes(of: value.reserved_zero, { $0.allSatisfy { $0 == 0 } }) else {
                throw LSPTransportError.internalFailure
            }
            return .init(
                deviceType: deviceType,
                captureSource: captureSource,
                deviceID: value.device_id,
                instanceGeneration: value.instance_generation,
                active: value.active != 0,
                observedStateHz: value.observed_state_hz,
                observedSensorHz: value.observed_sensor_hz,
                capturedSamples: value.captured_samples,
                droppedSamples: value.dropped_samples,
                attributedWireBytes: value.attributed_wire_bytes,
                stateSpacing: try distribution(value.state_spacing),
                sensorSpacing: try distribution(value.sensor_spacing)
            )
        }
        return .init(
            generation: native.snapshot_generation,
            snapshotTimeMicroseconds: native.snapshot_time_microseconds,
            streamGeneration: native.stream_generation,
            inputGeneration: native.input_generation,
            videoGeneration: native.video_generation,
            audioGeneration: native.audio_generation,
            pointerGeneration: native.pointer_generation,
            controllerGenerations: controllerGenerations,
            touchGenerations: touchGenerations,
            penGenerations: penGenerations,
            stages: stages,
            devices: devices
        )
    }

    /// Copies association-local baseline readiness without claiming an exclusive handoff observer.
    public func inputBaselineSnapshot() throws -> LSPNativeInputBaselineSnapshot {
        var native = clsp_input_baseline_snapshot_t()
        try Self.requireSuccess(clsp_core_copy_input_baseline(core, &native))
        return try Self.inputBaselineSnapshot(from: native)
    }

    /// Waits off-actor for one exact input generation's authenticated baseline ACK.
    public func waitForInputBaseline(
        inputGeneration: UInt32,
        timeout: Duration = .seconds(2)
    ) async throws -> LSPNativeInputBaselineSnapshot {
        let timeoutMilliseconds = try Self.milliseconds(timeout, minimum: 1, maximum: 30_000)
        return try await Task.detached(priority: .userInitiated) { [self] in
            var native = clsp_input_baseline_snapshot_t()
            try Self.requireSuccess(clsp_core_wait_input_baseline(
                core,
                inputGeneration,
                timeoutMilliseconds,
                &native
            ))
            return try Self.inputBaselineSnapshot(from: native)
        }.value
    }

    private static func inputBaselineSnapshot(
        from native: clsp_input_baseline_snapshot_t
    ) throws -> LSPNativeInputBaselineSnapshot {
        guard native.abi_version == abiVersion,
              native.structure_size == MemoryLayout<clsp_input_baseline_snapshot_t>.size,
              native.reserved_zero == 0,
              withUnsafeBytes(of: native.reserved_tail, { $0.allSatisfy { $0 == 0 } }) else {
            throw LSPTransportError.internalFailure
        }
        return .init(
            connectionGeneration: native.connection_generation,
            inputGeneration: native.input_generation,
            inputAuthorityEpoch: native.input_authority_epoch,
            eventGeneration: native.event_generation,
            acknowledged: native.acknowledged != 0
        )
    }

    /// Sends one deterministic-CBOR LSP request and awaits its authenticated response.
    public func request(
        messageType: UInt16,
        payload: Data,
        timeout: Duration = .seconds(2),
        onSubmissionAccepted: (@Sendable () throws -> Void)? = nil
    ) async throws -> LSPControlEvent {
        guard messageType != 0, payload.count <= 1_100 else {
            throw LSPTransportError.invalidConfiguration
        }
        let deadlineMilliseconds = try Self.milliseconds(
            timeout,
            minimum: 20,
            maximum: 30_000
        )
        let requestID = callbackState.reserveRequestID()
        return try await withCheckedThrowingContinuation { continuation in
            callbackState.install(requestID: requestID) { result in
                continuation.resume(with: result)
            }
            let status = payload.withUnsafeBytes { bytes in
                clsp_core_send_control(
                    core,
                    messageType,
                    requestID,
                    clsp_const_byte_span_t(
                        data: bytes.bindMemory(to: UInt8.self).baseAddress,
                        length: bytes.count
                    ),
                    deadlineMilliseconds
                )
            }
            do {
                try Self.requireSuccess(status)
                try onSubmissionAccepted?()
            } catch {
                callbackState.fail(requestID: requestID, error: error as? LSPTransportError ?? .internalFailure)
                return
            }
            Task.detached { [callbackState] in
                try? await Task.sleep(for: timeout)
                callbackState.fail(requestID: requestID, error: .timeout)
            }
        }
    }

    /// Atomically admits one ATTACH through its native handoff and awaits the authenticated response.
    public func requestAttach(
        handoff: LSPNativeHandoff,
        messageType: UInt16,
        payload: Data,
        timeout: Duration = .seconds(2),
        onSubmissionAccepted: (@Sendable () -> Void)? = nil
    ) async throws -> LSPControlEvent {
        guard messageType == 0x0202, payload.count <= 1_100 else {
            throw LSPTransportError.invalidConfiguration
        }
        let deadlineMilliseconds = try Self.milliseconds(timeout, minimum: 20, maximum: 30_000)
        let requestID = callbackState.reserveRequestID()
        return try await withCheckedThrowingContinuation { continuation in
            callbackState.install(requestID: requestID) { result in continuation.resume(with: result) }
            do {
                try handoff.submitAttach(
                    messageType: messageType,
                    requestID: requestID,
                    payload: payload,
                    deadlineMilliseconds: deadlineMilliseconds
                )
                onSubmissionAccepted?()
            } catch {
                callbackState.fail(
                    requestID: requestID,
                    error: error as? LSPTransportError ?? .internalFailure
                )
                return
            }
            Task.detached { [callbackState] in
                try? await Task.sleep(for: timeout)
                callbackState.fail(requestID: requestID, error: .timeout)
            }
        }
    }

    /// Installs a coarse handler for authenticated unsolicited control events.
    public func setControlEventHandler(
        _ handler: (@Sendable (LSPControlEvent) -> Void)?
    ) {
        callbackState.setEventHandler(handler)
    }

    /// Installs a coarse native lifecycle handler; never called per packet or input sample.
    public func setLifecycleHandler(
        _ handler: (@Sendable (LSPTransportLifecycle) -> Void)?
    ) {
        callbackState.setLifecycleHandler(handler)
    }

    /// Installs the complete-Opus packet handler; no UDP fragment crosses this boundary.
    public func setAudioPacketHandler(
        _ handler: (@Sendable (LSPAudioPacket) -> Void)?
    ) {
        callbackState.setAudioHandler(handler)
    }

    public func setAudioTimingHandler(
        _ handler: (@Sendable (LSPAudioTiming) -> Void)?
    ) {
        callbackState.setAudioTimingHandler(handler)
    }

    /// Installs the complete encoded-access-unit handler; RTP packets never cross this boundary.
    public func setVideoAccessUnitHandler(_ handler: (@Sendable (LSPEncodedVideoAccessUnit) -> Void)?) {
        callbackState.setVideoAccessUnitHandler(handler)
    }

    /// Installs the low-rate path-probe lifecycle handler.
    public func setPathProbeHandler(_ handler: (@Sendable (LSPPathProbeEvent) -> Void)?) {
        callbackState.setPathProbeHandler(handler)
    }

    /// Installs the exact authenticated native video mapping before semantic ACK.
    public func configureVideo(_ configuration: LSPNativeVideoConfiguration) throws {
        var native = clsp_video_configuration_t()
        native.abi_version = Self.abiVersion
        native.structure_size = UInt32(MemoryLayout<clsp_video_configuration_t>.size)
        native.stream_generation = configuration.streamGeneration
        native.video_generation = configuration.videoGeneration
        native.primary_ssrc = configuration.primarySSRC
        native.clock_rate = 90_000
        native.width = configuration.width
        native.height = configuration.height
        native.refresh_numerator = configuration.refreshNumerator
        native.refresh_denominator = configuration.refreshDenominator
        native.bitrate = configuration.bitrate
        native.maximum_access_unit_bytes = configuration.maximumAccessUnitBytes
        native.maximum_frame_age_microseconds = configuration.maximumFrameAgeMicroseconds
        native.frame_id_origin = configuration.frameIDOrigin
        native.recovery_epoch = configuration.recoveryEpoch
        native.udp_payload_size = configuration.udpPayloadSize
        native.primary_payload_type = configuration.primaryPayloadType
        native.codec = configuration.codec
        native.profile = configuration.profile
        native.pixel_format = configuration.pixelFormat
        native.color_primaries = configuration.colorPrimaries
        native.transfer_characteristics = configuration.transferCharacteristics
        native.matrix_coefficients = configuration.matrixCoefficients
        native.full_range = configuration.fullRange ? 1 : 0
        native.delivery = configuration.delivery
        native.payload_format = configuration.payloadFormat
        native.decoder_surfaces = configuration.decoderSurfaces
        native.frame_marking_extension = configuration.frameMarkingExtension
        native.absolute_capture_extension = configuration.absoluteCaptureExtension
        native.frame_id_extension = configuration.frameIDExtension
        native.input_watermark_extension = configuration.inputWatermarkExtension
        native.encoder_timing_extension = configuration.encoderTimingExtension
        native.flexfec_ssrc = configuration.flexFECSSRC
        native.flexfec_payload_type = configuration.flexFECPayloadType
        native.flexfec_repair_window_microseconds = configuration.flexFECRepairWindowMicroseconds
        native.flexfec_maximum_group_packets = configuration.flexFECMaximumGroupPackets
        native.rtx_ssrc = configuration.rtxSSRC
        native.rtx_payload_type = configuration.rtxPayloadType
        native.rtx_associated_payload_type = configuration.rtxAssociatedPayloadType
        try Self.requireSuccess(clsp_core_configure_video(core, &native))
    }

    /// Opens native complete-frame publication after the reliable video ACK is submitted.
    public func activateVideo(videoGeneration: UInt32) throws {
        try Self.requireSuccess(clsp_core_activate_video(core, videoGeneration))
    }

    /// Enables native RFC 8899 search after video ACK and renderer activation.
    public func startPathDiscovery() throws {
        try Self.requireSuccess(clsp_core_start_path_discovery(core))
    }

    /// Sends one reliable client PATH_PROBE intent; native emits LSPP after intent submission.
    public func requestPathProbe(
        probeID: UInt64,
        udpPayloadSize: UInt16,
        payload: Data,
        timeout: Duration = .seconds(60)
    ) async throws -> LSPControlEvent {
        guard probeID != 0, udpPayloadSize >= 1_200, payload.count <= 1_100 else {
            throw LSPTransportError.invalidConfiguration
        }
        let milliseconds = UInt32(60_000)
        let requestID = callbackState.reserveRequestID()
        return try await withCheckedThrowingContinuation { continuation in
            callbackState.install(requestID: requestID) { result in continuation.resume(with: result) }
            let status = payload.withUnsafeBytes { bytes in
                clsp_core_send_path_probe(
                    core,
                    probeID,
                    udpPayloadSize,
                    requestID,
                    clsp_const_byte_span_t(
                        data: bytes.bindMemory(to: UInt8.self).baseAddress,
                        length: bytes.count
                    ),
                    milliseconds
                )
            }
            do {
                try Self.requireSuccess(status)
            } catch {
                callbackState.fail(requestID: requestID, error: error as? LSPTransportError ?? .internalFailure)
                return
            }
            Task.detached { [callbackState] in
                try? await Task.sleep(for: timeout)
                callbackState.fail(requestID: requestID, error: .timeout)
            }
        }
    }

    /// Retains one authenticated host intent until native exact LSPP validation.
    public func acceptPathProbe(probeID: UInt64, udpPayloadSize: UInt16, requestID: UInt64) throws {
        try Self.requireSuccess(clsp_core_accept_path_probe(core, probeID, udpPayloadSize, requestID))
    }

    /// Confirms one exact reliable ACK in native path-search state.
    public func confirmPathProbe(probeID: UInt64, receivedPayloadSize: UInt16) throws {
        try Self.requireSuccess(clsp_core_confirm_path_probe(core, probeID, receivedPayloadSize))
    }

    /// Reports one terminal decoder outcome for the exact authenticated per-frame epoch and current bounded capacities.
    public func reportVideoDecode(
        videoGeneration: UInt32,
        frameID: UInt64,
        recoveryEpoch: UInt32,
        status: LSPVideoDecodeStatus,
        availableCredit: UInt8,
        mailboxOccupancy: UInt8
    ) throws {
        try Self.requireSuccess(clsp_core_report_video_decode(
            core,
            videoGeneration,
            frameID,
            recoveryEpoch,
            status.rawValue,
            availableCredit,
            mailboxOccupancy
        ))
    }

    /// Reports one actual Metal command-buffer commit.
    public func reportVideoCommit(
        videoGeneration: UInt32,
        frameID: UInt64,
        mailboxOccupancy: UInt8
    ) throws {
        try Self.requireSuccess(clsp_core_report_video_commit(
            core,
            videoGeneration,
            frameID,
            mailboxOccupancy
        ))
    }

    /// Sends one semantic response to an authenticated host control request.
    public func sendControlResponse(
        messageType: UInt16,
        requestID: UInt64,
        payload: Data,
        errorResponse: Bool = false,
        timeout: Duration = .seconds(1)
    ) throws {
        let milliseconds = try Self.milliseconds(timeout, minimum: 20, maximum: 30_000)
        let status = payload.withUnsafeBytes { bytes in
            clsp_core_send_control_response(
                core,
                messageType,
                requestID,
                clsp_const_byte_span_t(
                    data: bytes.bindMemory(to: UInt8.self).baseAddress,
                    length: bytes.count
                ),
                errorResponse ? 1 : 0,
                milliseconds
            )
        }
        try Self.requireSuccess(status)
        try Self.requireSuccess(
            clsp_core_wait_control_response(core, requestID, milliseconds)
        )
    }

    /// Installs the exact authenticated input-only START_RESPONSE mapping.
    public func configureInput(_ configuration: LSPNativeInputConfiguration) throws {
        var native = clsp_input_configuration_t()
        native.abi_version = Self.abiVersion
        native.structure_size = UInt32(MemoryLayout<clsp_input_configuration_t>.size)
        native.stream_generation = configuration.streamGeneration
        native.input_generation = configuration.inputGeneration
        native.input_ssrc = configuration.inputSSRC
        native.acknowledgement_ssrc = configuration.acknowledgementSSRC
        native.pointer_rate = configuration.pointerRate
        native.controller_rate = configuration.controllerRate
        native.sensor_rate = configuration.sensorRate
        native.reconciliation_rate = configuration.reconciliationRate
        native.reserved_input_wire_bits_per_second = configuration.reservedInputWireBitsPerSecond
        native.input_payload_type = configuration.inputPayloadType
        native.baseline_required = configuration.baselineRequired ? 1 : 0
        try Self.requireSuccess(clsp_core_configure_input(core, &native))
    }

    /// Applies one authenticated coarse input-rate renegotiation.
    public func updateInputRates(_ configuration: LSPNativeInputConfiguration) throws {
        var update = clsp_input_rate_update_t()
        update.abi_version = Self.abiVersion
        update.structure_size = UInt32(MemoryLayout<clsp_input_rate_update_t>.size)
        update.stream_generation = configuration.streamGeneration
        update.input_generation = configuration.inputGeneration
        update.pointer_rate = configuration.pointerRate
        update.controller_rate = configuration.controllerRate
        update.sensor_rate = configuration.sensorRate
        update.reconciliation_rate = configuration.reconciliationRate
        update.reserved_input_wire_bits_per_second = configuration.reservedInputWireBitsPerSecond
        try Self.requireSuccess(clsp_core_update_input_rates(core, &update))
    }

    /// Copies the latest authenticated LSPI delivery and effective-rate evidence.
    public func inputFeedbackSnapshot() throws -> LSPNativeInputFeedbackSnapshot {
        var native = clsp_input_feedback_snapshot_t()
        try Self.requireSuccess(clsp_core_copy_input_feedback(core, &native))
        guard native.abi_version == Self.abiVersion,
              native.structure_size == MemoryLayout<clsp_input_feedback_snapshot_t>.size,
              withUnsafeBytes(of: native.reserved_zero, { $0.allSatisfy { $0 == 0 } }) else {
            throw LSPTransportError.internalFailure
        }
        return .init(
            streamGeneration: native.stream_generation,
            inputGeneration: native.input_generation,
            acceptedBaselineID: native.accepted_baseline_id,
            contiguousEdgeID: native.contiguous_edge_id,
            edgeReceptionBitmap: native.edge_reception_bitmap,
            receivedAtMicroseconds: native.received_at_microseconds,
            pointerRate: native.pointer_rate,
            controllerRate: native.controller_rate,
            sensorRate: native.sensor_rate,
            reconciliationRate: native.reconciliation_rate,
            reservedInputWireBitsPerSecond: native.reserved_input_wire_bits_per_second,
            baselineAcknowledged: native.baseline_acknowledged != 0,
            baselineRequested: native.baseline_requested != 0
        )
    }

    /// Copies the newest local exactly-once edge for a text/IME barrier.
    public func inputEdgeSnapshot() throws -> LSPNativeInputEdgeSnapshot {
        var native = clsp_input_edge_snapshot_t()
        try Self.requireSuccess(clsp_core_copy_input_edge_snapshot(core, &native))
        guard native.abi_version == Self.abiVersion,
              native.structure_size == MemoryLayout<clsp_input_edge_snapshot_t>.size else {
            throw LSPTransportError.internalFailure
        }
        return .init(
            streamGeneration: native.stream_generation,
            inputGeneration: native.input_generation,
            latestAssignedEdgeID: native.latest_assigned_edge_id,
            latestEdgeSampleTimeMicroseconds: native.latest_edge_sample_time_microseconds
        )
    }

    /// Drains one coarse native hot-plug/rate offer; returns nil when the queue is empty.
    public func pollDeviceOffer() throws -> LSPNativeDeviceOffer? {
        var native = clsp_device_offer_event_t()
        try Self.requireSuccess(clsp_core_poll_device_offer(core, &native))
        guard native.abi_version == Self.abiVersion,
              native.structure_size == MemoryLayout<clsp_device_offer_event_t>.size,
              withUnsafeBytes(of: native.reserved_zero, { $0.allSatisfy { $0 == 0 } }) else {
            throw LSPTransportError.internalFailure
        }
        if native.kind == 0 { return nil }
        guard let kind = LSPNativeDeviceOffer.Kind(rawValue: native.kind),
              let deviceType = LSPNativeDeviceOffer.DeviceType(rawValue: native.device_type),
              let captureSource = LSPNativeDeviceOffer.CaptureSource(rawValue: native.capture_source),
              native.event_sequence != 0, native.device_id != 0, native.instance_generation != 0 else {
            throw LSPTransportError.internalFailure
        }
        let timingFlags = LSPNativeTimingFlags(rawValue: native.timing_flags)
        guard timingFlags.subtracting(.allKnown).isEmpty else {
            throw LSPTransportError.internalFailure
        }
        if kind == .removed,
           native.observed_capture_hz != 0 || native.observed_sensor_hz != 0 ||
           native.minimum_state_rate != 0 || native.maximum_state_rate != 0 ||
           native.minimum_sensor_rate != 0 || native.maximum_sensor_rate != 0 ||
           native.effective_wire_bits_per_second != 0 ||
           native.minimum_sample_interval_microseconds != 0 ||
           native.maximum_sample_interval_microseconds != 0 ||
           native.maximum_state_packet_bytes != 0 || native.maximum_sensor_packet_bytes != 0 {
            throw LSPTransportError.internalFailure
        }
        return .init(
            sequence: native.event_sequence,
            kind: kind,
            deviceType: deviceType,
            captureSource: captureSource,
            deviceID: native.device_id,
            instanceGeneration: native.instance_generation,
            observedCaptureHz: native.observed_capture_hz,
            observedSensorHz: native.observed_sensor_hz,
            minimumStateRate: native.minimum_state_rate,
            maximumStateRate: native.maximum_state_rate,
            minimumSensorRate: native.minimum_sensor_rate,
            maximumSensorRate: native.maximum_sensor_rate,
            capturedSamples: native.captured_samples,
            droppedSamples: native.dropped_samples,
            attributedWireBytes: native.attributed_wire_bytes,
            effectiveWireBitsPerSecond: native.effective_wire_bits_per_second,
            stateSpacing: .init(
                count: native.state_spacing_count,
                p50Microseconds: native.state_spacing_p50_microseconds,
                p95Microseconds: native.state_spacing_p95_microseconds,
                p99Microseconds: native.state_spacing_p99_microseconds,
                maximumMicroseconds: native.state_spacing_maximum_microseconds,
                drops: native.state_spacing_drops,
                flags: timingFlags
            ),
            sensorSpacing: .init(
                count: native.sensor_spacing_count,
                p50Microseconds: native.sensor_spacing_p50_microseconds,
                p95Microseconds: native.sensor_spacing_p95_microseconds,
                p99Microseconds: native.sensor_spacing_p99_microseconds,
                maximumMicroseconds: native.sensor_spacing_maximum_microseconds,
                drops: native.sensor_spacing_drops,
                flags: native.maximum_sensor_rate != 0 || native.sensor_spacing_count != 0 ? timingFlags : []
            ),
            minimumSampleIntervalMicroseconds: native.minimum_sample_interval_microseconds,
            maximumSampleIntervalMicroseconds: native.maximum_sample_interval_microseconds,
            maximumStatePacketBytes: native.maximum_state_packet_bytes,
            maximumSensorPacketBytes: native.maximum_sensor_packet_bytes
        )
    }

    /// Installs exact native host-audio admission before AUDIO_CONFIG_ACK.
    public func configureAudio(_ configuration: LSPNativeAudioConfiguration) throws {
        guard configuration.mapping.count == Int(configuration.channels), configuration.mapping.count <= 8 else {
            throw LSPTransportError.invalidConfiguration
        }
        var native = clsp_audio_configuration_t()
        native.abi_version = Self.abiVersion
        native.structure_size = UInt32(MemoryLayout<clsp_audio_configuration_t>.size)
        native.stream_generation = configuration.streamGeneration
        native.audio_generation = configuration.audioGeneration
        native.audio_ssrc = configuration.audioSSRC
        native.clock_rate = 48_000
        native.bitrate = configuration.bitrate
        native.frame_samples = configuration.frameSamples
        native.udp_payload_size = configuration.udpPayloadSize
        native.audio_payload_type = configuration.audioPayloadType
        native.channels = configuration.channels
        native.streams = configuration.streams
        native.coupled_streams = configuration.coupledStreams
        native.mapping_length = UInt8(configuration.mapping.count)
        native.inband_fec = configuration.inbandFEC ? 1 : 0
        native.dtx = configuration.dtx ? 1 : 0
        native.preroll_packets = 1
        withUnsafeMutableBytes(of: &native.mapping) { destination in
            configuration.mapping.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        try Self.requireSuccess(clsp_core_configure_audio(core, &native))
    }

    /// Prepares the exact native microphone sender before semantic ACK activation.
    public func configureMicrophone(_ configuration: LSPNativeMicrophoneConfiguration) throws {
        var native = clsp_microphone_configuration_t()
        native.abi_version = Self.abiVersion
        native.structure_size = UInt32(MemoryLayout<clsp_microphone_configuration_t>.size)
        native.stream_generation = configuration.streamGeneration
        native.microphone_generation = configuration.microphoneGeneration
        native.microphone_ssrc = configuration.microphoneSSRC
        native.clock_rate = 48_000
        native.bitrate = configuration.bitrate
        native.frame_samples = 960
        native.udp_payload_size = configuration.udpPayloadSize
        native.microphone_payload_type = configuration.microphonePayloadType
        native.channels = 1
        native.inband_fec = configuration.inbandFEC ? 1 : 0
        native.dtx = configuration.dtx ? 1 : 0
        try Self.requireSuccess(clsp_core_configure_microphone(core, &native))
    }

    /// Queues one complete Opus packet into the two-packet native microphone sender.
    public func submitMicrophonePacket(_ packet: Data) throws {
        let status = packet.withUnsafeBytes { bytes in
            clsp_core_submit_microphone_packet(
                core,
                clsp_const_byte_span_t(
                    data: bytes.bindMemory(to: UInt8.self).baseAddress,
                    length: bytes.count
                )
            )
        }
        try Self.requireSuccess(status)
    }

    public func markMicrophoneDiscontinuity() throws {
        try Self.requireSuccess(clsp_core_mark_microphone_discontinuity(core))
    }

    public func stopMicrophone() throws {
        try Self.requireSuccess(clsp_core_stop_microphone(core))
    }

    /// Submits one relative-pointer sample directly to the native cumulative composer.
    public func submitPointer(
        sampleTimeMicroseconds: UInt64,
        deltaX: Int64,
        deltaY: Int64,
        verticalScroll: Int64 = 0,
        horizontalScroll: Int64 = 0
    ) throws {
        var sample = clsp_pointer_sample_t(
            sample_time_microseconds: sampleTimeMicroseconds,
            delta_x: deltaX,
            delta_y: deltaY,
            vertical_scroll: verticalScroll,
            horizontal_scroll: horizontalScroll
        )
        try Self.requireSuccess(clsp_core_submit_pointer(core, &sample))
    }

    /// Submits one keyboard HID-usage or pointer-button lifecycle edge.
    public func submitInputEdge(
        sampleTimeMicroseconds: UInt64,
        controlID: UInt16,
        kind: LSPNativeInputEdgeKind
    ) throws {
        var edge = clsp_input_edge_t(
            sample_time_microseconds: sampleTimeMicroseconds,
            control_id: controlID,
            kind: kind.rawValue,
            reserved_zero: 0
        )
        try Self.requireSuccess(clsp_core_submit_input_edge(core, &edge))
    }

    /// Stops native input capture after queued release edges are retained for LSPI ACK.
    public func neutralizeInput() throws {
        try Self.requireSuccess(clsp_core_neutralize_input(core))
    }

    /// Restarts unchanged input authority behind a fresh native neutral baseline.
    public func restartInputBaseline() throws {
        try Self.requireSuccess(clsp_core_restart_input_baseline(core))
    }

    /// Starts preferred public IOHID capture on its dedicated native queue.
    public func startAppleInputCapture() throws -> LSPAppleInputCapture {
        var output: OpaquePointer?
        try Self.requireSuccess(clsp_core_start_apple_input_capture(core, &output))
        guard let output else { throw LSPTransportError.internalFailure }
        return LSPAppleInputCapture(handle: output)
    }

    /// Starts focused-window AppKit fallback capture entirely inside the native adapter.
    public func startAppleAppKitInputCapture() throws -> LSPAppleInputCapture {
        var output: OpaquePointer?
        try Self.requireSuccess(clsp_core_start_apple_appkit_input_capture(core, &output))
        guard let output else { throw LSPTransportError.internalFailure }
        return LSPAppleInputCapture(handle: output)
    }

    private static func makeNativeConfiguration(
        _ configuration: LSPTransportConfiguration
    ) throws -> clsp_configuration_t {
        guard configuration.port != 0 else {
            throw LSPTransportError.invalidConfiguration
        }
        let telemetryMilliseconds = try milliseconds(
            configuration.telemetryInterval,
            minimum: 250,
            maximum: UInt32.max
        )
        let handshakeMilliseconds = try milliseconds(
            configuration.handshakeTimeout,
            minimum: 1_000,
            maximum: 30_000
        )

        var native = clsp_configuration_t()
        native.abi_version = Self.abiVersion
        native.structure_size = UInt32(MemoryLayout<clsp_configuration_t>.size)
        native.port = configuration.port
        native.telemetry_interval_milliseconds = telemetryMilliseconds
        native.handshake_timeout_milliseconds = handshakeMilliseconds
        switch configuration.profile {
        case .adaptiveLowLatency:
            native.profile = UInt32(CLSP_PROFILE_ADAPTIVE_LOW_LATENCY.rawValue)
            native.competition_capacity_mbps = 0
        case .competitionLAN(let capacityMbps):
            guard capacityMbps > 0 else {
                throw LSPTransportError.invalidConfiguration
            }
            native.profile = UInt32(CLSP_PROFILE_COMPETITION_LAN.rawValue)
            native.competition_capacity_mbps = capacityMbps
        }
        return native
    }

    private static func milliseconds(
        _ duration: Duration,
        minimum: UInt32,
        maximum: UInt32
    ) throws -> UInt32 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            throw LSPTransportError.invalidConfiguration
        }
        let whole = components.seconds.multipliedReportingOverflow(by: 1_000)
        let fraction = components.attoseconds / 1_000_000_000_000_000
        let total = whole.partialValue.addingReportingOverflow(fraction)
        guard !whole.overflow, !total.overflow,
              total.partialValue >= Int64(minimum),
              total.partialValue <= Int64(maximum)
        else {
            throw LSPTransportError.invalidConfiguration
        }
        return UInt32(total.partialValue)
    }

    fileprivate static func requireSuccess(_ status: clsp_status_t) throws {
        switch status {
        case CLSP_STATUS_OK:
            return
        case CLSP_STATUS_ABI_MISMATCH:
            throw LSPTransportError.abiMismatch(expected: abiVersion, actual: clsp_core_abi_version())
        case CLSP_STATUS_MISSING_WOLFSSL:
            throw LSPTransportError.missingWolfSSL
        case CLSP_STATUS_MISSING_LIBSRTP:
            throw LSPTransportError.missingLibSRTP
        case CLSP_STATUS_INVALID_ARGUMENT, CLSP_STATUS_INVALID_CONFIGURATION:
            throw LSPTransportError.invalidConfiguration
        case CLSP_STATUS_INVALID_STATE:
            throw LSPTransportError.invalidState
        case CLSP_STATUS_REENTRANT_CALLBACK:
            throw LSPTransportError.reentrantCallback
        case CLSP_STATUS_RESOURCE_EXHAUSTED:
            throw LSPTransportError.resourceExhausted
        case CLSP_STATUS_UNSUPPORTED:
            throw LSPTransportError.unsupported
        case CLSP_STATUS_INTERNAL_FAILURE:
            throw LSPTransportError.internalFailure
        case CLSP_STATUS_INVALID_ENDPOINT:
            throw LSPTransportError.invalidEndpoint
        case CLSP_STATUS_SOCKET_FAILURE:
            throw LSPTransportError.socketFailure
        case CLSP_STATUS_DTLS_FAILURE:
            throw LSPTransportError.dtlsFailure
        case CLSP_STATUS_SPKI_MISMATCH:
            throw LSPTransportError.spkiMismatch
        case CLSP_STATUS_SRTP_FAILURE:
            throw LSPTransportError.srtpFailure
        case CLSP_STATUS_NOT_AUTHENTICATED:
            throw LSPTransportError.notAuthenticated
        case CLSP_STATUS_CONTROL_WINDOW_FULL:
            throw LSPTransportError.controlWindowFull
        case CLSP_STATUS_TIMEOUT:
            throw LSPTransportError.timeout
        case CLSP_STATUS_INPUT_PERMISSION_DENIED:
            throw LSPTransportError.inputPermissionDenied
        case CLSP_STATUS_INPUT_UNAVAILABLE:
            throw LSPTransportError.inputUnavailable
        case CLSP_STATUS_ROLLBACK_PENDING:
            throw LSPTransportError.rollbackPending
        case CLSP_STATUS_PAIRING_FAILED:
            throw LSPTransportError.pairingFailed
        case CLSP_STATUS_PAIRING_EXPIRED:
            throw LSPTransportError.pairingExpired
        case CLSP_STATUS_PAIRING_GENERATION_MISMATCH:
            throw LSPTransportError.pairingGenerationMismatch
        case CLSP_STATUS_PAIRING_CONFIRMATION_FAILED:
            throw LSPTransportError.pairingConfirmationFailed
        default:
            throw LSPTransportError.unknownStatus(Int32(status.rawValue))
        }
    }

    static func terminalError(forNativeStatus status: clsp_status_t) -> LSPTransportError {
        do {
            try requireSuccess(status)
            return .invalidState
        } catch let error as LSPTransportError {
            return error
        } catch {
            return .internalFailure
        }
    }

    fileprivate static func copy<T>(_ data: Data, to destination: inout T) {
        data.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &destination) { target in
                target.copyBytes(from: source)
            }
        }
    }

    fileprivate static func copyUUID<T>(_ identifier: UUID, to destination: inout T) {
        var bytes = identifier.uuid
        withUnsafeBytes(of: &bytes) { source in
            withUnsafeMutableBytes(of: &destination) { target in
                target.copyBytes(from: source)
            }
        }
    }

    fileprivate static func data<T>(_ value: T, count: Int? = nil) -> Data {
        var value = value
        return withUnsafeBytes(of: &value) { bytes in
            Data(bytes.prefix(count ?? bytes.count))
        }
    }

    fileprivate static func uuid<T>(_ value: T) throws -> UUID {
        let bytes = data(value)
        guard bytes.count == 16, bytes.contains(where: { $0 != 0 }) else {
            throw LSPTransportError.internalFailure
        }
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { $0.copyBytes(from: bytes) }
        return UUID(uuid: uuid)
    }
}

/// Opaque owner for one native six-digit PIN-pairing transaction.
public final class LSPNativePairing: @unchecked Sendable {
    private let handle: OpaquePointer

    fileprivate init(
        transport: LSPTransport,
        clientID: UUID,
        clientIdentityKey: Data,
        clientName: String,
        requestedPermissions: UInt32
    ) throws {
        let nameBytes = Array(clientName.utf8)
        guard clientIdentityKey.count == 32,
              !nameBytes.isEmpty,
              nameBytes.count <= 64,
              requestedPermissions != 0 else {
            throw LSPTransportError.invalidConfiguration
        }
        var configuration = clsp_pairing_configuration_t()
        configuration.abi_version = LSPTransport.abiVersion
        configuration.structure_size = UInt32(MemoryLayout<clsp_pairing_configuration_t>.size)
        configuration.requested_permissions = requestedPermissions
        LSPTransport.copyUUID(clientID, to: &configuration.client_id)
        LSPTransport.copy(clientIdentityKey, to: &configuration.client_identity_key)
        var output: OpaquePointer?
        try nameBytes.withUnsafeBufferPointer { buffer in
            configuration.client_name = .init(data: buffer.baseAddress, length: buffer.count)
            try LSPTransport.requireSuccess(clsp_pairing_create(transport.core, &configuration, &output))
        }
        guard let output else { throw LSPTransportError.internalFailure }
        handle = output
    }

    deinit {
        clsp_pairing_release(handle)
    }

    /// Generates the PIN and public PAKE material exactly once.
    public func begin() throws -> LSPNativePairingBegin {
        var native = clsp_pairing_begin_t()
        try LSPTransport.requireSuccess(clsp_pairing_begin(handle, &native))
        guard native.abi_version == LSPTransport.abiVersion,
              native.structure_size == MemoryLayout<clsp_pairing_begin_t>.size,
              LSPTransport.data(native.reserved_zero).allSatisfy({ $0 == 0 }),
              LSPTransport.data(native.reserved_tail).allSatisfy({ $0 == 0 }) else {
            throw LSPTransportError.internalFailure
        }
        let pinBytes = LSPTransport.data(native.pin_digits)
        guard pinBytes.count == 6,
              pinBytes.allSatisfy({ (48...57).contains($0) }),
              let pin = String(data: pinBytes, encoding: .ascii) else {
            throw LSPTransportError.internalFailure
        }
        let clientPublicValue = LSPTransport.data(native.client_point)
        guard clientPublicValue.first == 0x04 else { throw LSPTransportError.internalFailure }
        return .init(
            pin: pin,
            scryptSalt: LSPTransport.data(native.scrypt_salt),
            clientPairingNonce: LSPTransport.data(native.client_pairing_nonce),
            clientPublicValue: clientPublicValue
        )
    }

    /// Binds the authenticated host-issued PENDING session and expiry.
    public func bindPending(
        sessionID: UUID,
        permissions: UInt32,
        expiresAtUTCSeconds: UInt64
    ) throws {
        var native = clsp_pairing_pending_t()
        native.abi_version = LSPTransport.abiVersion
        native.structure_size = UInt32(MemoryLayout<clsp_pairing_pending_t>.size)
        native.effective_permissions = permissions
        native.expires_at_utc_seconds = expiresAtUTCSeconds
        LSPTransport.copyUUID(sessionID, to: &native.pairing_session_id)
        try LSPTransport.requireSuccess(clsp_pairing_bind_pending(handle, &native))
    }

    /// Validates one authenticated challenge and produces cA plus its signature input.
    public func acceptChallenge(
        sessionID: UUID,
        approvalGeneration: UInt32,
        permissions: UInt32,
        expiresAtUTCSeconds: UInt64,
        serverPublicValue: Data
    ) throws -> LSPNativePairingClientConfirmation {
        guard serverPublicValue.count == 65 else { throw LSPTransportError.invalidConfiguration }
        var challenge = clsp_pairing_challenge_t()
        challenge.abi_version = LSPTransport.abiVersion
        challenge.structure_size = UInt32(MemoryLayout<clsp_pairing_challenge_t>.size)
        challenge.approval_generation = approvalGeneration
        challenge.effective_permissions = permissions
        challenge.expires_at_utc_seconds = expiresAtUTCSeconds
        LSPTransport.copyUUID(sessionID, to: &challenge.pairing_session_id)
        LSPTransport.copy(serverPublicValue, to: &challenge.host_point)
        var output = clsp_pairing_client_confirmation_t()
        try LSPTransport.requireSuccess(clsp_pairing_accept_challenge(handle, &challenge, &output))
        guard output.abi_version == LSPTransport.abiVersion,
              output.structure_size == MemoryLayout<clsp_pairing_client_confirmation_t>.size,
              LSPTransport.data(output.reserved_zero).allSatisfy({ $0 == 0 }),
              output.client_signature_input_length > 0,
              Int(output.client_signature_input_length) <= MemoryLayout.size(ofValue: output.client_signature_input) else {
            throw LSPTransportError.internalFailure
        }
        return .init(
            sessionID: try LSPTransport.uuid(output.pairing_session_id),
            approvalGeneration: output.approval_generation,
            permissions: output.effective_permissions,
            expiresAtUTCSeconds: output.expires_at_utc_seconds,
            clientConfirmation: LSPTransport.data(output.client_confirmation),
            clientSignatureInput: LSPTransport.data(
                output.client_signature_input,
                count: Int(output.client_signature_input_length)
            )
        )
    }

    /// Verifies cB and returns the exact host Ed25519 signature input.
    public func verifyHost(
        sessionID: UUID,
        approvalGeneration: UInt32,
        revocationGeneration: UInt32,
        serverConfirmation: Data
    ) throws -> LSPNativePairingResult {
        guard serverConfirmation.count == 32 else { throw LSPTransportError.invalidConfiguration }
        var confirmation = clsp_pairing_host_confirmation_t()
        confirmation.abi_version = LSPTransport.abiVersion
        confirmation.structure_size = UInt32(MemoryLayout<clsp_pairing_host_confirmation_t>.size)
        confirmation.approval_generation = approvalGeneration
        confirmation.revocation_generation = revocationGeneration
        LSPTransport.copyUUID(sessionID, to: &confirmation.pairing_session_id)
        LSPTransport.copy(serverConfirmation, to: &confirmation.host_confirmation)
        var output = clsp_pairing_result_t()
        try LSPTransport.requireSuccess(clsp_pairing_verify_host(handle, &confirmation, &output))
        guard output.abi_version == LSPTransport.abiVersion,
              output.structure_size == MemoryLayout<clsp_pairing_result_t>.size,
              output.reserved_zero == 0,
              LSPTransport.data(output.reserved_tail).allSatisfy({ $0 == 0 }),
              output.host_signature_input_length > 0,
              Int(output.host_signature_input_length) <= MemoryLayout.size(ofValue: output.host_signature_input) else {
            throw LSPTransportError.internalFailure
        }
        return .init(
            sessionID: try LSPTransport.uuid(output.pairing_session_id),
            approvalGeneration: output.approval_generation,
            permissions: output.effective_permissions,
            revocationGeneration: output.revocation_generation,
            expiresAtUTCSeconds: output.expires_at_utc_seconds,
            hostSignatureInput: LSPTransport.data(
                output.host_signature_input,
                count: Int(output.host_signature_input_length)
            )
        )
    }

    /// Cancels and immediately zeroizes an incomplete pairing transaction.
    public func cancel() throws {
        try LSPTransport.requireSuccess(clsp_pairing_cancel(handle))
    }

    /// Copies secret-free native pairing state.
    public func snapshot() throws -> LSPNativePairingSnapshot {
        var output = clsp_pairing_snapshot_t()
        try LSPTransport.requireSuccess(clsp_pairing_copy_snapshot(handle, &output))
        guard output.abi_version == LSPTransport.abiVersion,
              output.structure_size == MemoryLayout<clsp_pairing_snapshot_t>.size,
              output.reserved_zero == 0,
              let phase = LSPNativePairingPhase(rawValue: output.phase) else {
            throw LSPTransportError.internalFailure
        }
        return .init(
            phase: phase,
            permissions: output.effective_permissions,
            approvalGeneration: output.approval_generation,
            revocationGeneration: output.revocation_generation,
            expiresAtUTCSeconds: output.expires_at_utc_seconds
        )
    }
}

private final class LSPNativeHandoffCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var baseline: LSPNativeBaselineEvent?

    func receive(_ event: LSPNativeBaselineEvent) {
        lock.withLock { baseline = event }
    }

    func latestBaseline() -> LSPNativeBaselineEvent? {
        lock.withLock { baseline }
    }
}

private let lspRetainHandoffCallbackContext: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    _ = Unmanaged<LSPNativeHandoffCallbackState>.fromOpaque(context).retain()
}

private let lspReleaseHandoffCallbackContext: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    Unmanaged<LSPNativeHandoffCallbackState>.fromOpaque(context).release()
}

private let lspHandoffBaselineCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<clsp_handoff_baseline_event_t>?
) -> Void = { context, nativeEvent in
    guard let context, let nativeEvent else { return }
    let native = nativeEvent.pointee
    guard native.abi_version == LSPTransport.abiVersion,
          native.structure_size == MemoryLayout<clsp_handoff_baseline_event_t>.size,
          native.reserved_zero == 0,
          let kind = LSPNativeBaselineEventKind(rawValue: native.kind) else { return }
    Unmanaged<LSPNativeHandoffCallbackState>.fromOpaque(context).takeUnretainedValue().receive(.init(
        kind: kind,
        inputGeneration: native.input_generation,
        inputAuthorityEpoch: native.input_authority_epoch,
        connectionGeneration: native.connection_generation,
        rollbackConnectionGeneration: native.rollback_connection_generation
    ))
}

/// Swift owner for one native reconnect/rekey authority transaction.
public final class LSPNativeHandoff: @unchecked Sendable {
    private let handleLock = NSLock()
    private var handle: OpaquePointer?
    private let callbackState = LSPNativeHandoffCallbackState()

    public init(
        active: LSPTransport,
        activeConnectionGeneration: UInt32,
        activeInputGeneration: UInt32
    ) throws {
        var callbacks = clsp_handoff_callbacks_t()
        callbacks.abi_version = LSPTransport.abiVersion
        callbacks.structure_size = UInt32(MemoryLayout<clsp_handoff_callbacks_t>.size)
        callbacks.context = Unmanaged.passUnretained(callbackState).toOpaque()
        callbacks.retain_context = lspRetainHandoffCallbackContext
        callbacks.release_context = lspReleaseHandoffCallbackContext
        callbacks.baseline = lspHandoffBaselineCallback
        var output: OpaquePointer?
        try LSPTransport.requireSuccess(clsp_handoff_create(
            active.core,
            activeConnectionGeneration,
            activeInputGeneration,
            &callbacks,
            &output
        ))
        guard let output else { throw LSPTransportError.internalFailure }
        handle = output
    }

    deinit { releaseBindings() }

    public func releaseBindings() {
        let released = handleLock.withLock { () -> OpaquePointer? in
            defer { handle = nil }
            return handle
        }
        if let released { clsp_handoff_release(released) }
    }

    private func withHandle<Result>(
        _ operation: (OpaquePointer) throws -> Result
    ) throws -> Result {
        try handleLock.withLock {
            guard let handle else { throw LSPTransportError.invalidState }
            return try operation(handle)
        }
    }

    public func begin(
        candidate: LSPTransport,
        connectionGeneration: UInt32,
        reason: LSPNativeHandoffReason
    ) throws {
        try withHandle { handle in
            try LSPTransport.requireSuccess(clsp_handoff_begin(
                handle,
                candidate.core,
                connectionGeneration,
                reason.rawValue
            ))
        }
    }

    public func authenticate(connectionGeneration: UInt32) throws {
        try withHandle { handle in
            try LSPTransport.requireSuccess(clsp_handoff_authenticate(handle, connectionGeneration))
        }
    }

    public func markActiveLost(_ active: LSPTransport) throws {
        try withHandle { handle in
            try LSPTransport.requireSuccess(clsp_handoff_lost(handle, active.core))
        }
    }

    public func neutralize() throws {
        try withHandle { handle in try LSPTransport.requireSuccess(clsp_handoff_neutralize(handle)) }
    }

    /// Marks accepted native ATTACH admission before awaiting its response.
    fileprivate func submitAttach(
        messageType: UInt16,
        requestID: UInt64,
        payload: Data,
        deadlineMilliseconds: UInt32
    ) throws {
        try payload.withUnsafeBytes { bytes in
            var output = clsp_control_submission_t()
            try withHandle { handle in
                try LSPTransport.requireSuccess(clsp_handoff_submit_attach(
                    handle,
                    messageType,
                    requestID,
                    clsp_const_byte_span_t(
                        data: bytes.bindMemory(to: UInt8.self).baseAddress,
                        length: bytes.count
                    ),
                    deadlineMilliseconds,
                    &output
                ))
            }
            guard output.abi_version == LSPTransport.abiVersion,
                  output.structure_size == MemoryLayout<clsp_control_submission_t>.size,
                  output.request_id == requestID else {
                throw LSPTransportError.internalFailure
            }
        }
    }

    public func commit(inputGeneration: UInt32) throws {
        try withHandle { handle in try LSPTransport.requireSuccess(clsp_handoff_commit(handle, inputGeneration)) }
    }

    public func cancelDefiniteRejection() throws {
        try withHandle { handle in
            try LSPTransport.requireSuccess(clsp_handoff_cancel(
                handle,
                UInt32(CLSP_HANDOFF_CANCEL_DEFINITE_REJECTION.rawValue)
            ))
        }
    }

    public func cancelAmbiguous() throws {
        try withHandle { handle in
            try LSPTransport.requireSuccess(clsp_handoff_cancel(
                handle,
                UInt32(CLSP_HANDOFF_CANCEL_AMBIGUOUS.rawValue)
            ))
        }
    }

    public func retire() throws {
        try withHandle { handle in try LSPTransport.requireSuccess(clsp_handoff_retire(handle)) }
    }

    public func snapshot() throws -> LSPNativeHandoffSnapshot {
        var native = clsp_handoff_snapshot_t()
        try withHandle { handle in
            try LSPTransport.requireSuccess(clsp_handoff_copy_snapshot(handle, &native))
        }
        guard native.abi_version == LSPTransport.abiVersion,
              native.structure_size == MemoryLayout<clsp_handoff_snapshot_t>.size,
              let phase = LSPNativeHandoffPhase(rawValue: native.phase) else {
            throw LSPTransportError.internalFailure
        }
        return .init(
            phase: phase,
            activeConnectionGeneration: native.active_connection_generation,
            activeInputGeneration: native.active_input_generation,
            candidateConnectionGeneration: native.candidate_connection_generation,
            inputAuthorityEpoch: native.input_authority_epoch,
            connectionGenerationHighWatermark: native.connection_generation_high_watermark,
            rollbackConnectionGeneration: native.rollback_connection_generation,
            retiringConnectionGeneration: native.retiring_connection_generation,
            baselineRequired: native.baseline_required != 0,
            forwardOnly: native.forward_only != 0,
            committedCount: native.committed_count,
            rollbackCount: native.definite_rollback_count,
            terminalCount: native.terminal_count
        )
    }

    public func latestBaselineEvent() -> LSPNativeBaselineEvent? {
        callbackState.latestBaseline()
    }

    public func waitForBaseline(
        inputGeneration: UInt32,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let value = try snapshot()
            let baseline = latestBaselineEvent()
            if Self.completedBaselineMatches(
                event: baseline,
                snapshot: value,
                inputGeneration: inputGeneration
            ) {
                return
            }
            guard value.phase != .terminal else { throw LSPTransportError.invalidState }
            guard clock.now < deadline else { throw LSPTransportError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func completedBaselineMatches(
        event: LSPNativeBaselineEvent?,
        snapshot: LSPNativeHandoffSnapshot,
        inputGeneration: UInt32
    ) -> Bool {
        guard let event,
              !snapshot.baselineRequired,
              snapshot.activeInputGeneration == inputGeneration,
              event.kind == .acknowledged,
              event.inputGeneration == inputGeneration,
              event.inputAuthorityEpoch == snapshot.inputAuthorityEpoch,
              event.connectionGeneration == snapshot.activeConnectionGeneration,
              snapshot.phase == .authoritative else { return false }
        if event.rollbackConnectionGeneration == 0 {
            return snapshot.rollbackConnectionGeneration == 0
        }
        return snapshot.rollbackConnectionGeneration == 0 &&
            event.rollbackConnectionGeneration == snapshot.inputAuthorityEpoch
    }
}

/// Owning Swift boundary for one preferred or focused-window native Apple capture source.
public final class LSPAppleInputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    fileprivate init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        stop()
    }

    /// Synchronously quiesces native callbacks before releasing capture ownership.
    public func stop() {
        let owned = lock.withLock { () -> OpaquePointer? in
            defer { handle = nil }
            return handle
        }
        if let owned {
            clsp_apple_input_capture_stop(owned)
        }
    }
}

final class LSPNativeCallbackState: @unchecked Sendable {
    typealias Completion = @Sendable (Result<LSPControlEvent, LSPTransportError>) -> Void

    private let lock = NSLock()
    private let videoDeliveryQueue = DispatchQueue(label: "app.umbra.lsp-video-delivery", qos: .userInteractive)
    private var videoHandlerGeneration: UInt64 = 0
    private var completions: [UInt64: Completion] = [:]
    private var eventHandler: (@Sendable (LSPControlEvent) -> Void)?
    private var lifecycleHandler: (@Sendable (LSPTransportLifecycle) -> Void)?
    private var audioHandler: (@Sendable (LSPAudioPacket) -> Void)?
    private var audioTimingHandler: (@Sendable (LSPAudioTiming) -> Void)?
    private var videoAccessUnitHandler: (@Sendable (LSPEncodedVideoAccessUnit) -> Void)?
    private var pathProbeHandler: (@Sendable (LSPPathProbeEvent) -> Void)?

    func reserveRequestID() -> UInt64 {
        lock.withLock {
            var candidate = UInt64.random(in: 1...UInt64.max)
            while completions[candidate] != nil {
                candidate = UInt64.random(in: 1...UInt64.max)
            }
            return candidate
        }
    }

    func install(requestID: UInt64, completion: @escaping Completion) {
        lock.withLock {
            completions[requestID] = completion
        }
    }

    func receive(_ event: LSPControlEvent) {
        let delivery: Completion? = lock.withLock {
            event.requestID == 0 || !event.flags.contains(.response)
                ? nil
                : completions.removeValue(forKey: event.requestID)
        }
        if let delivery {
            delivery(.success(event))
            return
        }
        let handler = lock.withLock { eventHandler }
        handler?(event)
    }

    func fail(requestID: UInt64, error: LSPTransportError) {
        let delivery = lock.withLock {
            completions.removeValue(forKey: requestID)
        }
        delivery?(.failure(error))
    }

    func setEventHandler(_ handler: (@Sendable (LSPControlEvent) -> Void)?) {
        lock.withLock {
            eventHandler = handler
        }
    }

    func receiveLifecycle(
        _ lifecycle: LSPTransportLifecycle,
        terminalStatus: clsp_status_t
    ) {
        let result = lock.withLock { () -> ((@Sendable (LSPTransportLifecycle) -> Void)?, [Completion]) in
            let pending: [Completion]
            if lifecycle == .failed || lifecycle == .stopped {
                pending = Array(completions.values)
                completions.removeAll(keepingCapacity: true)
            } else {
                pending = []
            }
            return (lifecycleHandler, pending)
        }
        let terminalError: LSPTransportError = lifecycle == .failed
            ? LSPTransport.terminalError(forNativeStatus: terminalStatus)
            : .invalidState
        for completion in result.1 {
            completion(.failure(terminalError))
        }
        let handler = result.0
        handler?(lifecycle)
    }

    func setLifecycleHandler(_ handler: (@Sendable (LSPTransportLifecycle) -> Void)?) {
        lock.withLock { lifecycleHandler = handler }
    }

    func receiveAudio(_ packet: LSPAudioPacket) {
        let handler = lock.withLock { audioHandler }
        handler?(packet)
    }

    func setAudioHandler(_ handler: (@Sendable (LSPAudioPacket) -> Void)?) {
        lock.withLock { audioHandler = handler }
    }

    func receiveAudioTiming(_ timing: LSPAudioTiming) {
        let handler = lock.withLock { audioTimingHandler }
        handler?(timing)
    }

    func setAudioTimingHandler(_ handler: (@Sendable (LSPAudioTiming) -> Void)?) {
        lock.withLock { audioTimingHandler = handler }
    }

    func receiveVideoAccessUnit(_ accessUnit: LSPEncodedVideoAccessUnit) {
        guard let generation = lock.withLock({ videoAccessUnitHandler == nil ? nil : videoHandlerGeneration }) else {
            return
        }
        // Retained native frame buffers bound this queue to decoder surfaces + 2.
        // VideoToolbox can synchronously reject/complete a submission; consumer
        // feedback must therefore run outside the native callback's thread scope.
        videoDeliveryQueue.async { [self, accessUnit] in
            let handler = lock.withLock {
                videoHandlerGeneration == generation ? videoAccessUnitHandler : nil
            }
            handler?(accessUnit)
        }
    }

    func setVideoAccessUnitHandler(_ handler: (@Sendable (LSPEncodedVideoAccessUnit) -> Void)?) {
        lock.withLock {
            videoHandlerGeneration &+= 1
            videoAccessUnitHandler = handler
        }
    }

    func receivePathProbe(_ event: LSPPathProbeEvent) {
        if event.kind == .requestFailed {
            fail(requestID: event.requestID, error: .timeout)
            return
        }
        let handler = lock.withLock { pathProbeHandler }
        handler?(event)
    }

    func setPathProbeHandler(_ handler: (@Sendable (LSPPathProbeEvent) -> Void)?) {
        lock.withLock { pathProbeHandler = handler }
    }
}

private let lspRetainCallbackContext: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    _ = Unmanaged<LSPNativeCallbackState>.fromOpaque(context).retain()
}

private let lspReleaseCallbackContext: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    Unmanaged<LSPNativeCallbackState>.fromOpaque(context).release()
}

private let lspLifecycleCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<clsp_lifecycle_event_t>?
) -> Void = { context, event in
    guard let context else { return }
    let state = Unmanaged<LSPNativeCallbackState>.fromOpaque(context).takeUnretainedValue()
    guard let event,
          event.pointee.abi_version == LSPTransport.abiVersion,
          event.pointee.structure_size == UInt32(MemoryLayout<clsp_lifecycle_event_t>.size),
          event.pointee.reserved_zero == 0,
          let lifecycle = LSPTransportLifecycle(rawValue: event.pointee.state)
    else {
        state.receiveLifecycle(.failed, terminalStatus: CLSP_STATUS_INTERNAL_FAILURE)
        return
    }
    let rawStatus = event.pointee.terminal_status
    let terminalStatus = clsp_status_t(rawValue: rawStatus)
    let assignedStatus = rawStatus >= CLSP_STATUS_OK.rawValue &&
        rawStatus <= CLSP_STATUS_PAIRING_CONFIRMATION_FAILED.rawValue
    let validStatus = assignedStatus && (lifecycle == .failed
        ? terminalStatus != CLSP_STATUS_OK
        : terminalStatus == CLSP_STATUS_OK)
    guard validStatus else {
        state.receiveLifecycle(.failed, terminalStatus: CLSP_STATUS_INTERNAL_FAILURE)
        return
    }
    state.receiveLifecycle(lifecycle, terminalStatus: terminalStatus)
}

private let lspControlCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<clsp_control_event_t>?
) -> Void = { context, nativeEvent in
    guard let context, let nativeEvent else { return }
    let native = nativeEvent.pointee
    let payload: Data
    if native.payload.length == 0 {
        payload = Data()
    } else if let bytes = native.payload.data {
        payload = Data(bytes: bytes, count: native.payload.length)
    } else {
        return
    }
    let event = LSPControlEvent(
        messageType: native.message_type,
        flags: LSPControlFlags(rawValue: native.flags),
        connectionGeneration: native.connection_generation,
        messageID: native.message_id,
        requestID: native.request_id,
        payload: payload
    )
    Unmanaged<LSPNativeCallbackState>.fromOpaque(context).takeUnretainedValue().receive(event)
}

private let lspAudioPacketCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<clsp_audio_packet_event_t>?
) -> Void = { context, nativeEvent in
    guard let context, let nativeEvent else { return }
    let native = nativeEvent.pointee
    let data: Data
    if native.opus_packet.length == 0 {
        return
    } else if let bytes = native.opus_packet.data {
        data = Data(bytes: bytes, count: native.opus_packet.length)
    } else {
        return
    }
    Unmanaged<LSPNativeCallbackState>.fromOpaque(context).takeUnretainedValue().receiveAudio(
        LSPAudioPacket(
            audioGeneration: native.audio_generation,
            ssrc: native.ssrc,
            sequenceNumber: native.sequence_number,
            timestamp: native.timestamp,
            marker: native.marker != 0,
            opusPacket: data
        )
    )
}

private let lspAudioTimingCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<clsp_audio_timing_event_t>?
) -> Void = { context, nativeEvent in
    guard let context, let nativeEvent else { return }
    let native = nativeEvent.pointee
    Unmanaged<LSPNativeCallbackState>.fromOpaque(context).takeUnretainedValue().receiveAudioTiming(
        LSPAudioTiming(
            audioGeneration: native.audio_generation,
            ssrc: native.ssrc,
            ntpSeconds: native.ntp_seconds,
            ntpFraction: native.ntp_fraction,
            rtpTimestamp: native.rtp_timestamp
        )
    )
}

private let lspVideoAccessUnitCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<clsp_video_access_unit_event_t>?
) -> Void = { context, nativeEvent in
    guard let nativeEvent else { return }
    let native = nativeEvent.pointee
    guard let handle = native.encoded_access_unit else { return }
    guard let context,
          native.abi_version == LSPTransport.abiVersion,
          native.structure_size == MemoryLayout<clsp_video_access_unit_event_t>.size,
          native.video_generation != 0,
          native.frame_id != 0,
          native.has_encoder_timing <= 1,
          (1...3).contains(native.codec),
          let payloadFormat = LSPVideoPayloadFormat(rawValue: native.payload_format)
    else {
        clsp_buffer_release(handle)
        return
    }
    var span = clsp_const_byte_span_t()
    guard clsp_buffer_bytes(handle, &span) == CLSP_STATUS_OK,
          span.length > 0,
          let bytes = span.data
    else {
        clsp_buffer_release(handle)
        return
    }
    let storage = NSData(
        bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes),
        length: span.length,
        deallocator: { _, _ in clsp_buffer_release(handle) }
    )
    let hostEncoderDurationMicroseconds: UInt32?
    if native.has_encoder_timing == 1,
       native.capture_to_encoder_complete_microseconds >= native.capture_to_encoder_submit_microseconds {
        hostEncoderDurationMicroseconds =
            native.capture_to_encoder_complete_microseconds - native.capture_to_encoder_submit_microseconds
    } else {
        hostEncoderDurationMicroseconds = nil
    }
    let accessUnit = LSPEncodedVideoAccessUnit(
        videoGeneration: native.video_generation,
        rtpTimestamp: native.rtp_timestamp,
        frameID: native.frame_id,
        receiveTimeMicroseconds: native.receive_time_microseconds,
        captureTimeMicroseconds: native.capture_time_microseconds,
        hostEncoderDurationMicroseconds: hostEncoderDurationMicroseconds,
        inputStateSequence: native.input_state_sequence,
        inputEdgeID: native.input_edge_id,
        recoveryEpoch: native.recovery_epoch,
        independent: native.independent != 0,
        codec: native.codec,
        payloadFormat: payloadFormat,
        encodedAccessUnit: Data(referencing: storage)
    )
    Unmanaged<LSPNativeCallbackState>.fromOpaque(context).takeUnretainedValue().receiveVideoAccessUnit(accessUnit)
}

private let lspPathProbeCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<clsp_path_probe_event_t>?
) -> Void = { context, nativeEvent in
    guard let context, let nativeEvent else { return }
    let native = nativeEvent.pointee
    guard native.abi_version == LSPTransport.abiVersion,
          native.structure_size == MemoryLayout<clsp_path_probe_event_t>.size,
          native.probe_id != 0,
          native.udp_payload_size >= 1_200,
          native.reserved_zero == 0,
          let kind = LSPPathProbeEventKind(rawValue: native.kind)
    else { return }
    Unmanaged<LSPNativeCallbackState>.fromOpaque(context).takeUnretainedValue().receivePathProbe(.init(
        kind: kind,
        probeID: native.probe_id,
        requestID: native.request_id,
        udpPayloadSize: native.udp_payload_size
    ))
}
