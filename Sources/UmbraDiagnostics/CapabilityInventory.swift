import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case hevc
    case av1
}

public struct DecoderCapability: Codable, Hashable, Sendable {
    public var codec: VideoCodec
    public var hardwareDecodeSupported: Bool

    public init(codec: VideoCodec, hardwareDecodeSupported: Bool) {
        self.codec = codec
        self.hardwareDecodeSupported = hardwareDecodeSupported
    }
}

public struct DecoderCapabilityInventory: Codable, Hashable, Sendable {
    public var decoders: [DecoderCapability]

    public init(decoders: [DecoderCapability]) {
        self.decoders = decoders
    }

    /// Queries only the capability VideoToolbox exposes directly. Profile, bit-depth, and
    /// chroma-format support are deliberately not inferred from the machine model.
    public static func probe() -> Self {
        let av1: CMVideoCodecType = 0x6176_3031 // 'av01'
        return Self(decoders: [
            DecoderCapability(
                codec: .h264,
                hardwareDecodeSupported: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
            ),
            DecoderCapability(
                codec: .hevc,
                hardwareDecodeSupported: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
            ),
            DecoderCapability(
                codec: .av1,
                hardwareDecodeSupported: VTIsHardwareDecodeSupported(av1)
            ),
        ])
    }
}

public struct DisplayCapability: Codable, Hashable, Sendable {
    /// Ephemeral enumeration index for this snapshot, not a persistent display identifier.
    public var index: Int
    public var isMain: Bool
    public var isBuiltIn: Bool
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pointWidth: Double
    public var pointHeight: Double
    public var backingScaleFactor: Double
    public var maximumFramesPerSecond: Int
    public var supportsExtendedDynamicRange: Bool
    public var maximumExtendedDynamicRangeHeadroom: Double
    public var colorSpaceName: String?

    public init(
        index: Int,
        isMain: Bool,
        isBuiltIn: Bool,
        pixelWidth: Int,
        pixelHeight: Int,
        pointWidth: Double,
        pointHeight: Double,
        backingScaleFactor: Double,
        maximumFramesPerSecond: Int,
        supportsExtendedDynamicRange: Bool,
        maximumExtendedDynamicRangeHeadroom: Double,
        colorSpaceName: String?
    ) {
        self.index = index
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.backingScaleFactor = backingScaleFactor
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.supportsExtendedDynamicRange = supportsExtendedDynamicRange
        self.maximumExtendedDynamicRangeHeadroom = maximumExtendedDynamicRangeHeadroom
        self.colorSpaceName = colorSpaceName
    }
}

public struct DisplayCapabilityInventory: Codable, Hashable, Sendable {
    public var displays: [DisplayCapability]

    public init(displays: [DisplayCapability]) {
        self.displays = displays
    }

    @MainActor
    public static func probe(screens: [NSScreen] = NSScreen.screens) -> Self {
        let mainScreen = NSScreen.main
        return Self(displays: screens.enumerated().map { index, screen in
            let displayID = (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) }
            let nativePixelSize = displayID.flatMap(nativeDisplayPixelSize(for:))
            let maximumHeadroom = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
            return DisplayCapability(
                index: index,
                isMain: screen == mainScreen,
                isBuiltIn: displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false,
                pixelWidth: nativePixelSize.map { Int($0.width) }
                    ?? Int(screen.frame.width * screen.backingScaleFactor),
                pixelHeight: nativePixelSize.map { Int($0.height) }
                    ?? Int(screen.frame.height * screen.backingScaleFactor),
                pointWidth: screen.frame.width,
                pointHeight: screen.frame.height,
                backingScaleFactor: screen.backingScaleFactor,
                maximumFramesPerSecond: screen.maximumFramesPerSecond,
                supportsExtendedDynamicRange: maximumHeadroom > 1,
                maximumExtendedDynamicRangeHeadroom: maximumHeadroom,
                colorSpaceName: screen.colorSpace?.localizedName
            )
        })
    }
}

private func nativeDisplayPixelSize(for displayID: CGDirectDisplayID) -> CGSize? {
    guard let displayModes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode]
    else { return nil }
    let nativeFlag = UInt32(kDisplayModeNativeFlag)
    guard let nativeMode = displayModes.first(where: { $0.ioFlags & nativeFlag != 0 })
    else { return nil }
    return CGSize(width: nativeMode.width, height: nativeMode.height)
}
