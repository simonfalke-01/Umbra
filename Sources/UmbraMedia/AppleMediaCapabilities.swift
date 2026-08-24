import CoreAudio
import CoreMedia
import Foundation
import Metal
import VideoToolbox

public struct AppleStreamingCapabilities: Sendable, Equatable {
    private static let hardwareTupleProofs = HardwareVideoTupleProofs()
    public let hasMetalDevice: Bool
    public let supportsHardwareH264: Bool
    public let supportsHardwareHEVC: Bool
    public let supportsHardwareAV1: Bool
    public let supportsHardwareHEVCMain10: Bool
    public let supportsHardwareAV1Main10: Bool
    public let supportedHardwareYUV444FormatMask: Int32
    public let hasDefaultAudioOutput: Bool
    public let supportsNativeAudioOutput: Bool
    public let audioOutputChannelCount: UInt32

    public init(
        hasMetalDevice: Bool,
        supportsHardwareH264: Bool,
        supportsHardwareHEVC: Bool,
        supportsHardwareAV1: Bool,
        hasDefaultAudioOutput: Bool,
        supportsNativeAudioOutput: Bool,
        audioOutputChannelCount: UInt32,
        supportsHardwareHEVCMain10: Bool = false,
        supportsHardwareAV1Main10: Bool = false,
        supportedHardwareYUV444FormatMask: Int32 = 0
    ) {
        self.hasMetalDevice = hasMetalDevice
        self.supportsHardwareH264 = supportsHardwareH264
        self.supportsHardwareHEVC = supportsHardwareHEVC
        self.supportsHardwareAV1 = supportsHardwareAV1
        self.supportsHardwareHEVCMain10 = supportsHardwareHEVCMain10
        self.supportsHardwareAV1Main10 = supportsHardwareAV1Main10
        self.supportedHardwareYUV444FormatMask = supportedHardwareYUV444FormatMask
        self.hasDefaultAudioOutput = hasDefaultAudioOutput
        self.supportsNativeAudioOutput = supportsNativeAudioOutput
        self.audioOutputChannelCount = audioOutputChannelCount
    }

    /// Formats which can be truthfully advertised from explicit hardware evidence.
    /// Codec-family availability alone does not prove HEVC Main10 or any 4:4:4 profile.
    public var supportedVideoFormatMask: Int32 {
        var formats: Int32 = 0
        if supportsHardwareH264 { formats |= 0x0001 }
        if supportsHardwareHEVC {
            formats |= 0x0100
            if supportsHardwareHEVCMain10 { formats |= 0x0200 }
        }
        if supportsHardwareAV1 {
            formats |= 0x1000
            if supportsHardwareAV1Main10 { formats |= 0x2000 }
        }
        formats |= supportedHardwareYUV444FormatMask & VideoCodecProfile.yuv444Mask
        return formats
    }

    /// Queries the active system. It never infers decoder or output support from the CPU name.
    public static func probe() -> AppleStreamingCapabilities {
        let metalDevice = MTLCreateSystemDefaultDevice()
        let supportsHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let supportsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        let defaultDevice = defaultAudioOutputDevice()
        let nativeAudioAvailable = defaultDevice != nil
        return AppleStreamingCapabilities(
            hasMetalDevice: metalDevice != nil,
            supportsHardwareH264: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
            supportsHardwareHEVC: supportsHEVC,
            supportsHardwareAV1: supportsAV1,
            hasDefaultAudioOutput: defaultDevice != nil,
            supportsNativeAudioOutput: nativeAudioAvailable,
            // Querying a routed virtual device's stream configuration can activate it.
            // Keep this unknown until the audio backend opens at Moonlight audio init.
            audioOutputChannelCount: 0,
            supportsHardwareHEVCMain10: supportsHEVCMain10(
                codecAvailable: supportsHEVC,
                metalDevice: metalDevice
            ),
            // AV1 Main profile includes both 8-bit and 10-bit decoding.
            supportsHardwareAV1Main10: supportsAV1,
            supportedHardwareYUV444FormatMask: hardwareTupleProofs.yuv444Mask
        )
    }

    static func recordHardwareYUV444Proof(formatMask: Int32) {
        hardwareTupleProofs.record(formatMask & VideoCodecProfile.yuv444Mask)
    }

    private static func supportsHEVCMain10(
        codecAvailable: Bool,
        metalDevice: (any MTLDevice)?
    ) -> Bool {
        guard codecAvailable, let metalDevice else { return false }
#if arch(arm64)
        return metalDevice.supportsFamily(.mac2)
#else
        // VideoToolbox exposes no profile-specific query. Avoid model-name
        // heuristics on Intel/AMD Macs; an exact stream can still be tested at runtime.
        return false
#endif
    }

    private static func defaultAudioOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

}

private final class HardwareVideoTupleProofs: @unchecked Sendable {
    private let lock = NSLock()
    private var storedYUV444Mask: Int32 = 0
    private var performedColdProbe = false

    var yuv444Mask: Int32 {
        let shouldProbe = lock.withLock { () -> Bool in
            guard !performedColdProbe else { return false }
            performedColdProbe = true
            return true
        }
        if shouldProbe {
            let proven = Self.probeExactHardwareTuples()
            lock.withLock { storedYUV444Mask |= proven }
        }
        return lock.withLock { storedYUV444Mask }
    }

    func record(_ formatMask: Int32) {
        guard formatMask != 0 else { return }
        lock.withLock { storedYUV444Mask |= formatMask }
    }

    private struct Probe {
        let formatMask: Int32
        let codecType: CMVideoCodecType
        let initialization: Data
        let payloadFormat: EncodedVideoPayloadFormat
    }

    private static func probeExactHardwareTuples() -> Int32 {
        let probes: [Probe] = [
            Probe(
                formatMask: MoonlightVideoFormat.h264High8YUV444.rawValue,
                codecType: kCMVideoCodecType_H264,
                initialization: Data([
                    0x00, 0x00, 0x00, 0x01, 0x67, 0xf4, 0x00, 0x0a, 0x91, 0x96,
                    0x84, 0x26, 0xc0, 0x44, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00,
                    0x00, 0x03, 0x00, 0x0a, 0x3c, 0x48, 0x9a, 0x80, 0x00, 0x00,
                    0x00, 0x01, 0x68, 0xce, 0x0f, 0x19, 0x20,
                ]),
                payloadFormat: .annexB
            ),
            Probe(
                formatMask: MoonlightVideoFormat.hevcRext8YUV444.rawValue,
                codecType: kCMVideoCodecType_HEVC,
                initialization: Data([
                    0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff,
                    0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0x9e, 0x08, 0x00, 0x00,
                    0x03, 0x00, 0x00, 0x1e, 0x95, 0x94, 0x09, 0x00, 0x00, 0x00,
                    0x01, 0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00,
                    0x9e, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x1e, 0x90, 0x04,
                    0x10, 0x20, 0xb2, 0xca, 0xca, 0x94, 0x98, 0x5e, 0x02, 0xd0,
                    0x10, 0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x00,
                    0x10, 0x80, 0x00, 0x00, 0x00, 0x01, 0x44, 0x01, 0xc0, 0x73,
                    0x18, 0x30, 0x08, 0x90,
                ]),
                payloadFormat: .annexB
            ),
            Probe(
                formatMask: MoonlightVideoFormat.hevcRext10YUV444.rawValue,
                codecType: kCMVideoCodecType_HEVC,
                initialization: Data([
                    0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff,
                    0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0x9c, 0x08, 0x00, 0x00,
                    0x03, 0x00, 0x00, 0x1e, 0x95, 0x94, 0x09, 0x00, 0x00, 0x00,
                    0x01, 0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00,
                    0x9c, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x1e, 0x90, 0x04,
                    0x10, 0x20, 0x9b, 0x2c, 0xac, 0xa9, 0x49, 0x85, 0xe0, 0x2d,
                    0x01, 0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x00,
                    0x10, 0x80, 0x00, 0x00, 0x00, 0x01, 0x44, 0x01, 0xc0, 0x73,
                    0x18, 0x30, 0x08, 0x90,
                ]),
                payloadFormat: .annexB
            ),
            Probe(
                formatMask: MoonlightVideoFormat.av1High8YUV444.rawValue,
                codecType: kCMVideoCodecType_AV1,
                initialization: Data([0x12, 0x00, 0x0a, 0x06, 0x38, 0x15, 0x7f, 0xfd, 0x80, 0x40]),
                payloadFormat: .av1LowOverheadOBU
            ),
            Probe(
                formatMask: MoonlightVideoFormat.av1High10YUV444.rawValue,
                codecType: kCMVideoCodecType_AV1,
                initialization: Data([0x12, 0x00, 0x0a, 0x06, 0x38, 0x15, 0x7f, 0xfd, 0x88, 0x40]),
                payloadFormat: .av1LowOverheadOBU
            ),
        ]

        var mask: Int32 = 0
        for probe in probes where VTIsHardwareDecodeSupported(probe.codecType) {
            let decoder = VideoToolboxDecoder(policy: .hardwareOnly, maximumOutstandingFrames: 1)
            guard decoder.configure(format: VideoStreamFormat(
                codecMask: probe.formatMask,
                width: 64,
                height: 64,
                redrawRate: 60,
                flags: 0
            )), decoder.prepareCodecInitialization(
                probe.initialization,
                payloadFormat: probe.payloadFormat
            ) else {
                decoder.cleanUp()
                continue
            }
            mask |= probe.formatMask
            decoder.cleanUp()
        }
        return mask & VideoCodecProfile.yuv444Mask
    }
}
