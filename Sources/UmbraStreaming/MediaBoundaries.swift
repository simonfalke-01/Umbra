import AVFAudio
import CoreMedia
import CoreVideo
import Foundation

/// Immutable codec negotiation passed from moonlight-common-c to a VideoToolbox decoder.
public struct VideoStreamFormat: Sendable, Equatable {
    public let codecMask: Int32
    public let width: Int
    public let height: Int
    public let redrawRate: Int
    public let flags: Int32

    public init(codecMask: Int32, width: Int, height: Int, redrawRate: Int, flags: Int32) {
        self.codecMask = codecMask
        self.width = width
        self.height = height
        self.redrawRate = redrawRate
        self.flags = flags
    }
}

public enum EncodedVideoPayloadFormat: Sendable, Equatable {
    case annexB
    case videoToolboxLengthPrefixed
    case av1LowOverheadOBU
}

/// An owned encoded access unit in the explicitly declared payload format.
public struct CompressedVideoFrame: Sendable, Equatable {
    public let data: Data
    public let payloadFormat: EncodedVideoPayloadFormat
    public let frameNumber: Int
    public let isKeyFrame: Bool
    public let requiresIndependentDecode: Bool
    public let hostProcessingLatencyTenthsOfMillisecond: UInt16
    public let receiveTimeMicroseconds: UInt64
    public let enqueueTimeMicroseconds: UInt64
    public let presentationTimeMicroseconds: UInt64
    public let rtpTimestamp: UInt32
    public let isHDR: Bool
    public let colorSpace: UInt8
    public let hostCaptureTimeMicroseconds: UInt64
    public let appliedInputStateSequence: UInt64
    public let appliedInputEdgeID: UInt64
    public let videoConfigurationGeneration: UInt32

    public init(
        data: Data,
        payloadFormat: EncodedVideoPayloadFormat = .annexB,
        frameNumber: Int,
        isKeyFrame: Bool,
        requiresIndependentDecode: Bool = false,
        hostProcessingLatencyTenthsOfMillisecond: UInt16 = 0,
        receiveTimeMicroseconds: UInt64 = 0,
        enqueueTimeMicroseconds: UInt64 = 0,
        presentationTimeMicroseconds: UInt64,
        rtpTimestamp: UInt32 = 0,
        isHDR: Bool = false,
        colorSpace: UInt8 = 1,
        hostCaptureTimeMicroseconds: UInt64 = 0,
        appliedInputStateSequence: UInt64 = 0,
        appliedInputEdgeID: UInt64 = 0,
        videoConfigurationGeneration: UInt32 = 0
    ) {
        self.data = data
        self.payloadFormat = payloadFormat
        self.frameNumber = frameNumber
        self.isKeyFrame = isKeyFrame
        self.requiresIndependentDecode = requiresIndependentDecode
        self.hostProcessingLatencyTenthsOfMillisecond = hostProcessingLatencyTenthsOfMillisecond
        self.receiveTimeMicroseconds = receiveTimeMicroseconds
        self.enqueueTimeMicroseconds = enqueueTimeMicroseconds
        self.presentationTimeMicroseconds = presentationTimeMicroseconds
        self.rtpTimestamp = rtpTimestamp
        self.isHDR = isHDR
        self.colorSpace = colorSpace
        self.hostCaptureTimeMicroseconds = hostCaptureTimeMicroseconds
        self.appliedInputStateSequence = appliedInputStateSequence
        self.appliedInputEdgeID = appliedInputEdgeID
        self.videoConfigurationGeneration = videoConfigurationGeneration
    }
}

public enum VideoFrameDisposition: Int32, Sendable {
    case accepted = 0
    case requestKeyFrame = -1
}

/// Thread-safe boundary implemented by the VideoToolbox decode pipeline.
public protocol VideoDecoding: AnyObject, Sendable {
    func configure(format: VideoStreamFormat) -> Bool
    func start()
    func stop()
    func cleanUp()
    func submit(frame: CompressedVideoFrame) -> VideoFrameDisposition
}

/// Installs exact codec initialization and creates the native decoder session
/// before a protocol configuration acknowledgement is emitted.
public protocol VideoCodecInitializationPreparing: AnyObject, Sendable {
    func prepareCodecInitialization(
        _ data: Data,
        payloadFormat: EncodedVideoPayloadFormat
    ) -> Bool
}

public enum VideoDecodeOutcome: Sendable, Equatable {
    case decoded(frameNumber: Int)
    case failed(frameNumber: Int)
}

public protocol VideoDecodeOutcomeReporting: AnyObject, Sendable {
    func installDecodeOutcomeHandler(
        _ handler: @escaping @Sendable (VideoDecodeOutcome) -> Void
    )
}

public protocol HDRMetadataReceiving: AnyObject, Sendable {
    func setHDRMode(enabled: Bool, metadata: StreamingHDRMetadata?)
}

/// A decoded VideoToolbox frame with explicit ownership across concurrency domains.
public struct DecodedVideoFrame: @unchecked Sendable {
    public let imageBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let isHDR: Bool

    public init(imageBuffer: CVPixelBuffer, presentationTime: CMTime, isHDR: Bool) {
        self.imageBuffer = imageBuffer
        self.presentationTime = presentationTime
        self.isHDR = isHDR
    }
}

/// Thread-safe boundary between VideoToolbox output and the Metal presentation layer.
public protocol MetalVideoRendering: AnyObject, Sendable {
    func enqueue(_ frame: DecodedVideoFrame)
    func flush()
}

public struct OpusStreamFormat: Sendable, Equatable {
    public let audioConfiguration: Int32
    public let sampleRate: Int
    public let channelCount: Int
    public let streamCount: Int
    public let coupledStreamCount: Int
    public let samplesPerFrame: Int
    public let mapping: [UInt8]
    public let flags: Int32

    public init(
        audioConfiguration: Int32,
        sampleRate: Int,
        channelCount: Int,
        streamCount: Int,
        coupledStreamCount: Int,
        samplesPerFrame: Int,
        mapping: [UInt8],
        flags: Int32
    ) {
        self.audioConfiguration = audioConfiguration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.streamCount = streamCount
        self.coupledStreamCount = coupledStreamCount
        self.samplesPerFrame = samplesPerFrame
        self.mapping = mapping
        self.flags = flags
    }
}

/// An owned Opus packet copied from the Moonlight receive thread.
public struct CompressedAudioPacket: Sendable, Equatable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

/// Thread-safe Opus decode boundary feeding the native AudioQueue output pipeline.
public protocol AudioDecoding: AnyObject, Sendable {
    func configure(format: OpusStreamFormat) -> Bool
    func start()
    func stop()
    func cleanUp()
    func submit(packet: CompressedAudioPacket)
}

public protocol AudioDiscontinuityHandling: AnyObject, Sendable {
    func handleAudioDiscontinuity() -> Bool
}

/// AVAudioPCMBuffer is reference-backed, so ownership is explicit at this concurrency boundary.
public struct DecodedAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

public protocol AudioEngineRendering: AnyObject, Sendable {
    func enqueue(_ buffer: DecodedAudioBuffer)
    func flush()
}
