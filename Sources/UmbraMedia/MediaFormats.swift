import AVFAudio
import CoreGraphics
import CoreMedia
import Foundation

public enum VideoCodec: String, Sendable, CaseIterable {
    case h264
    case hevc
    case av1

    public var cmCodecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        case .av1: kCMVideoCodecType_AV1
        }
    }
}

/// A single GameStream video format value. These raw values are part of the
/// the GameStream protocol library's client ABI and are deliberately distinct from the host's
/// server codec-mode-support (SCM) bit positions.
public enum GameStreamVideoFormat: Int32, Sendable, CaseIterable {
    case h264 = 0x0001
    case h264High8YUV444 = 0x0004
    case hevc = 0x0100
    case hevcMain10 = 0x0200
    case hevcRext8YUV444 = 0x0400
    case hevcRext10YUV444 = 0x0800
    case av1Main8 = 0x1000
    case av1Main10 = 0x2000
    case av1High8YUV444 = 0x4000
    case av1High10YUV444 = 0x8000

    public static let knownMask = allCases.reduce(Int32.zero) { $0 | $1.rawValue }

    public var isTenBit: Bool {
        switch self {
        case .hevcMain10, .hevcRext10YUV444, .av1Main10, .av1High10YUV444:
            true
        default:
            false
        }
    }

    public var isYUV444: Bool {
        switch self {
        case .h264High8YUV444, .hevcRext8YUV444, .hevcRext10YUV444,
             .av1High8YUV444, .av1High10YUV444:
            true
        default:
            false
        }
    }
}

public struct VideoCodecProfile: Sendable, Equatable {
    public static let h264Mask: Int32 = 0x000F
    public static let hevcMask: Int32 = 0x0F00
    public static let av1Mask: Int32 = 0xF000
    public static let tenBitMask: Int32 = 0xAA00
    public static let yuv444Mask: Int32 = 0xCC04

    public let codec: VideoCodec
    public let isTenBit: Bool
    public let isYUV444: Bool
    public let rawValue: Int32

    public init(codecMask: Int32) throws {
        guard let format = GameStreamVideoFormat(rawValue: codecMask) else {
            throw VideoDecoderError.unsupportedCodecMask(codecMask)
        }
        switch format {
        case .h264, .h264High8YUV444:
            self.codec = .h264
        case .hevc, .hevcMain10, .hevcRext8YUV444, .hevcRext10YUV444:
            self.codec = .hevc
        case .av1Main8, .av1Main10, .av1High8YUV444, .av1High10YUV444:
            self.codec = .av1
        }
        self.isTenBit = format.isTenBit
        self.isYUV444 = format.isYUV444
        self.rawValue = codecMask
    }
}

public enum VideoColorSpace: UInt8, Sendable, CaseIterable {
    case rec601 = 0
    case rec709 = 1
    case rec2020 = 2

    public init(bridgeValue: UInt8) {
        self = VideoColorSpace(rawValue: bridgeValue) ?? .rec709
    }
}

public enum VideoColorRange: Sendable, Equatable {
    case video
    case full
}

public enum VideoTransferFunction: Sendable, Equatable {
    case sdr
    case pq
    case hlg
}

public struct HDRStaticMetadata: Sendable, Equatable {
    public var transferFunction: VideoTransferFunction?
    public var minimumLuminanceNits: Float?
    public var maximumLuminanceNits: Float?
    public var maximumContentLightLevelNits: Float?
    public var maximumFrameAverageLightLevelNits: Float?
    public var maximumFullFrameLuminanceNits: Float?
    public var masteringDisplayColorVolume: Data?
    public var contentLightLevelInfo: Data?

    public init(
        minimumLuminanceNits: Float? = nil,
        maximumLuminanceNits: Float? = nil,
        maximumContentLightLevelNits: Float? = nil,
        maximumFrameAverageLightLevelNits: Float? = nil,
        maximumFullFrameLuminanceNits: Float? = nil,
        masteringDisplayColorVolume: Data? = nil,
        contentLightLevelInfo: Data? = nil,
        transferFunction: VideoTransferFunction? = nil
    ) {
        self.minimumLuminanceNits = minimumLuminanceNits
        self.maximumLuminanceNits = maximumLuminanceNits
        self.maximumContentLightLevelNits = maximumContentLightLevelNits
        self.maximumFrameAverageLightLevelNits = maximumFrameAverageLightLevelNits
        self.maximumFullFrameLuminanceNits = maximumFullFrameLuminanceNits
        self.masteringDisplayColorVolume = masteringDisplayColorVolume
        self.contentLightLevelInfo = contentLightLevelInfo
        self.transferFunction = transferFunction
    }
}

public struct VideoColorMetadata: Sendable, Equatable {
    public var colorSpace: VideoColorSpace
    public var range: VideoColorRange
    public var transferFunction: VideoTransferFunction
    public var hdrStaticMetadata: HDRStaticMetadata?

    public var isHDR: Bool { transferFunction != .sdr }

    public init(
        colorSpace: VideoColorSpace,
        range: VideoColorRange,
        transferFunction: VideoTransferFunction,
        hdrStaticMetadata: HDRStaticMetadata? = nil
    ) {
        self.colorSpace = colorSpace
        self.range = range
        self.transferFunction = transferFunction
        self.hdrStaticMetadata = hdrStaticMetadata
    }

    public static let rec709SDR = VideoColorMetadata(
        colorSpace: .rec709,
        range: .video,
        transferFunction: .sdr
    )
    public static let rec2020HDR10 = VideoColorMetadata(
        colorSpace: .rec2020,
        range: .video,
        transferFunction: .pq
    )
}

/// Row-major coefficients for converting normalized YCbCr samples to RGB.
public struct YUVConversion: Sendable, Equatable {
    public let matrix: [Float]
    public let offset: [Float]

    public init(metadata: VideoColorMetadata) {
        let kr: Float
        let kb: Float
        switch metadata.colorSpace {
        case .rec601: (kr, kb) = (0.299, 0.114)
        case .rec709: (kr, kb) = (0.2126, 0.0722)
        case .rec2020: (kr, kb) = (0.2627, 0.0593)
        }
        let kg = 1 - kr - kb
        let yScale: Float = metadata.range == .video ? 255 / 219 : 1
        let cScale: Float = metadata.range == .video ? 255 / 224 : 1
        let yOffset: Float = metadata.range == .video ? -16 / 255 : 0

        matrix = [
            yScale, 0, 2 * (1 - kr) * cScale,
            yScale, -2 * kb * (1 - kb) / kg * cScale, -2 * kr * (1 - kr) / kg * cScale,
            yScale, 2 * (1 - kb) * cScale, 0,
        ]
        offset = [yOffset, -0.5, -0.5]
    }
}

public enum VideoContentMode: Sendable, Equatable {
    case aspectFit
    case aspectFill
}

public struct VideoQuad: Sendable, Equatable {
    /// Normalized half-width/half-height in clip space.
    public let clipScale: CGPoint
    /// Normalized source texture bounds.
    public let textureRect: CGRect
}

public enum VideoGeometry {
    public static func quad(
        source: CGSize,
        destination: CGSize,
        mode: VideoContentMode
    ) -> VideoQuad {
        guard source.width > 0, source.height > 0,
              destination.width > 0, destination.height > 0 else {
            return VideoQuad(clipScale: .zero, textureRect: .zero)
        }
        let sourceAspect = source.width / source.height
        let destinationAspect = destination.width / destination.height
        switch mode {
        case .aspectFit:
            if sourceAspect > destinationAspect {
                return VideoQuad(
                    clipScale: CGPoint(x: 1, y: destinationAspect / sourceAspect),
                    textureRect: CGRect(x: 0, y: 0, width: 1, height: 1)
                )
            }
            return VideoQuad(
                clipScale: CGPoint(x: sourceAspect / destinationAspect, y: 1),
                textureRect: CGRect(x: 0, y: 0, width: 1, height: 1)
            )
        case .aspectFill:
            if sourceAspect > destinationAspect {
                let visibleWidth = destinationAspect / sourceAspect
                return VideoQuad(
                    clipScale: CGPoint(x: 1, y: 1),
                    textureRect: CGRect(x: (1 - visibleWidth) / 2, y: 0, width: visibleWidth, height: 1)
                )
            }
            let visibleHeight = sourceAspect / destinationAspect
            return VideoQuad(
                clipScale: CGPoint(x: 1, y: 1),
                textureRect: CGRect(x: 0, y: (1 - visibleHeight) / 2, width: 1, height: visibleHeight)
            )
        }
    }
}

public enum AudioOutputLayout: String, Sendable, CaseIterable {
    case stereo
    case surround51
    case surround71

    public var channelCount: AVAudioChannelCount {
        switch self {
        case .stereo: 2
        case .surround51: 6
        case .surround71: 8
        }
    }

    public var audioConfiguration: Int32 {
        switch self {
        case .stereo: (0x3 << 16) | (2 << 8) | 0xCA
        case .surround51: (0x3F << 16) | (6 << 8) | 0xCA
        case .surround71: (0x63F << 16) | (8 << 8) | 0xCA
        }
    }

    public var coreAudioLayoutTag: AudioChannelLayoutTag {
        switch self {
        case .stereo: kAudioChannelLayoutTag_Stereo
        case .surround51: kAudioChannelLayoutTag_MPEG_5_1_A
        // GameStream PCM order is L R C LFE rear-L rear-R side-L side-R.
        case .surround71: kAudioChannelLayoutTag_WAVE_7_1
        }
    }

    public init?(audioConfiguration: Int32) {
        let channelCount = (audioConfiguration >> 8) & 0xFF
        let channelMask = (audioConfiguration >> 16) & 0xFFFF
        switch (channelCount, channelMask) {
        case (2, 0x3): self = .stereo
        case (6, 0x3F): self = .surround51
        case (8, 0x63F): self = .surround71
        default: return nil
        }
    }
}

public struct InactiveMuteState: Sendable, Equatable {
    public var muteWhileInactive: Bool
    public private(set) var isApplicationActive: Bool
    public var manuallyMuted: Bool

    public var isMuted: Bool {
        manuallyMuted || (muteWhileInactive && !isApplicationActive)
    }

    public init(
        muteWhileInactive: Bool = true,
        isApplicationActive: Bool = true,
        manuallyMuted: Bool = false
    ) {
        self.muteWhileInactive = muteWhileInactive
        self.isApplicationActive = isApplicationActive
        self.manuallyMuted = manuallyMuted
    }

    public mutating func setApplicationActive(_ active: Bool) {
        isApplicationActive = active
    }
}
