import Foundation
import UmbraCore
import UmbraMedia

public enum StreamingConfigurationWarningKind: String, Sendable {
    case hdrCodecSupport
    case hostCodecSupport
    case clientCodecSupport
    case yuv444Support
    case softwareDecoderPerformance
    case surroundOutput
    case framePacing
    case customPacketSize
    case extremeBitrate
}

public struct StreamingConfigurationWarning: Equatable, Sendable {
    public let kind: StreamingConfigurationWarningKind
    public let message: String

    public init(kind: StreamingConfigurationWarningKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public protocol StreamingConfigurationWarningEvaluating: Sendable {
    func warnings(
        host: StreamHost,
        application: StreamApplication,
        preferences: StreamingPreferences
    ) -> [StreamingConfigurationWarning]
}

/// Produces high-signal warnings before the host application is launched. These
/// checks are advisory because automatic codec negotiation may still find a
/// compatible fallback at runtime.
public struct StreamingConfigurationWarningEvaluator: StreamingConfigurationWarningEvaluating, Sendable {
    public let capabilities: AppleStreamingCapabilities

    public init(capabilities: AppleStreamingCapabilities = .probe()) {
        self.capabilities = capabilities
    }

    public func warnings(
        host: StreamHost,
        application: StreamApplication,
        preferences: StreamingPreferences
    ) -> [StreamingConfigurationWarning] {
        guard preferences.configurationWarnings else { return [] }

        var warnings: [StreamingConfigurationWarning] = []

        if !hostSupportsSelectedCodec(host.codecSupport, codec: preferences.videoCodecPreference) {
            warnings.append(.init(
                kind: .hostCodecSupport,
                message: "The host does not advertise the selected video codec. Choose Automatic codec selection or select a codec supported by the host."
            ))
        } else if !clientAndHostShareSelectedCodec(host.codecSupport, preferences: preferences) {
            warnings.append(.init(
                kind: .clientCodecSupport,
                message: "This Mac and the host do not share a codec compatible with the current video and decoder settings. Choose Automatic codec/decoder selection or select a mutually supported codec."
            ))
        }

        if preferences.enableHDR {
            if preferences.videoCodecPreference == .h264 {
                warnings.append(.init(
                    kind: .hdrCodecSupport,
                    message: "HDR cannot use H.264. Change Video codec to Automatic, HEVC, or AV1 before starting the stream."
                ))
            } else if !hostSupportsHDR(host.codecSupport, codec: preferences.videoCodecPreference) {
                warnings.append(.init(
                    kind: .hostCodecSupport,
                    message: "The host does not advertise a 10-bit codec compatible with the selected HDR settings. Choose Automatic codec selection or disable HDR."
                ))
            } else if !clientAndHostShareHDRCodec(
                host.codecSupport,
                preferences: preferences
            ) {
                warnings.append(.init(
                    kind: .clientCodecSupport,
                    message: "This Mac and the host do not share a 10-bit codec for HDR with the current decoder setting. Choose Automatic decoding or disable HDR."
                ))
            }
        }

        if preferences.enableYUV444 {
            if !hostSupportsYUV444(
                host.codecSupport,
                codec: preferences.videoCodecPreference,
                hdr: preferences.enableHDR
            ) {
                warnings.append(.init(
                    kind: .yuv444Support,
                    message: "The host does not advertise YUV 4:4:4 support for the selected codec and color depth. Disable YUV 4:4:4 or choose Automatic codec selection."
                ))
            } else if !clientSupportsYUV444(preferences: preferences) {
                warnings.append(.init(
                    kind: .yuv444Support,
                    message: "This Mac has no proven decoder for the selected YUV 4:4:4 format. Umbra will use YUV 4:2:0 for this stream."
                ))
            }
        }

        let pixelRate = Int64(preferences.width) * Int64(preferences.height) * Int64(preferences.fps)
        if preferences.videoDecoderPreference == .software,
           pixelRate > Int64(1_920 * 1_080 * 60) || preferences.enableHDR || preferences.enableYUV444 {
            warnings.append(.init(
                kind: .softwareDecoderPerformance,
                message: "Forced software decoding may not sustain this resolution, frame rate, or color format. Select Automatic decoding unless hardware decoding is known to be unavailable."
            ))
        }

        let requestedChannels = Self.requestedChannelCount(preferences.audioConfiguration)
        if requestedChannels > capabilities.audioOutputChannelCount,
           capabilities.audioOutputChannelCount > 0 {
            warnings.append(.init(
                kind: .surroundOutput,
                message: "The selected \(requestedChannels)-channel audio layout exceeds the active output device's \(capabilities.audioOutputChannelCount)-channel layout. Select Stereo or connect a compatible surround output."
            ))
        }

        if preferences.framePacing, !preferences.enableVSync {
            warnings.append(.init(
                kind: .framePacing,
                message: "Frame pacing requires V-Sync to control presentation timing. Enable V-Sync or turn frame pacing off."
            ))
        }

        if preferences.packetSize != 0 {
            warnings.append(.init(
                kind: .customPacketSize,
                message: "A custom packet size can cause fragmentation or packet loss on some networks. Use Automatic packet size unless the network MTU has been measured."
            ))
        }

        if preferences.bitrateKbps > 150_000 {
            warnings.append(.init(
                kind: .extremeBitrate,
                message: "The selected bitrate exceeds 150 Mbps and may overwhelm the host encoder or network. Reduce the bitrate if the stream stutters or drops frames."
            ))
        }

        var kinds = Set<StreamingConfigurationWarningKind>()
        return warnings.filter { kinds.insert($0.kind).inserted }
    }

    private func hostSupportsSelectedCodec(
        _ support: HostCodecSupport,
        codec: VideoCodecPreference
    ) -> Bool {
        switch codec {
        case .automatic:
            return !support.intersection([.h264, .hevc, .hevcMain10, .av1Main8, .av1Main10]).isEmpty
        case .h264:
            return !support.intersection(.allH264).isEmpty
        case .hevc, .hevcHDRDeprecated, .bc1:
            return !support.intersection(.allHEVC.union(.h264)).isEmpty
        case .av1:
            return !support.intersection(.allAV1.union(.allHEVC).union(.h264)).isEmpty
        }
    }

    private func clientAndHostShareSelectedCodec(
        _ hostSupport: HostCodecSupport,
        preferences: StreamingPreferences
    ) -> Bool {
        let software = preferences.videoDecoderPreference == .software
        switch preferences.videoCodecPreference {
        case .automatic:
            return ((software || capabilities.supportsHardwareH264)
                && !hostSupport.intersection(.allH264).isEmpty)
                || ((software || capabilities.supportsHardwareHEVC)
                    && !hostSupport.intersection(.allHEVC).isEmpty)
                || ((!software && capabilities.supportsHardwareAV1)
                    && !hostSupport.intersection(.allAV1).isEmpty)
        case .h264:
            return software || capabilities.supportsHardwareH264
        case .hevc, .hevcHDRDeprecated, .bc1:
            return ((software || capabilities.supportsHardwareHEVC)
                && !hostSupport.intersection(.allHEVC).isEmpty)
                || ((software || capabilities.supportsHardwareH264)
                    && hostSupport.contains(.h264))
        case .av1:
            return ((!software && capabilities.supportsHardwareAV1)
                && !hostSupport.intersection(.allAV1).isEmpty)
                || ((software || capabilities.supportsHardwareHEVC)
                    && !hostSupport.intersection(.allHEVC).isEmpty)
                || ((software || capabilities.supportsHardwareH264)
                    && hostSupport.contains(.h264))
        }
    }

    private func clientAndHostShareHDRCodec(
        _ hostSupport: HostCodecSupport,
        preferences: StreamingPreferences
    ) -> Bool {
        guard preferences.videoDecoderPreference != .software else { return false }
        switch preferences.videoCodecPreference {
        case .automatic:
            return (capabilities.supportsHardwareHEVCMain10
                && !hostSupport.intersection([.hevcMain10, .hevcRext10YUV444]).isEmpty)
                || (capabilities.supportsHardwareAV1Main10
                    && !hostSupport.intersection([.av1Main10, .av1High10YUV444]).isEmpty)
        case .h264:
            return false
        case .hevc, .hevcHDRDeprecated, .bc1:
            return capabilities.supportsHardwareHEVCMain10
        case .av1:
            return (capabilities.supportsHardwareAV1Main10
                && !hostSupport.intersection([.av1Main10, .av1High10YUV444]).isEmpty)
                || (capabilities.supportsHardwareHEVCMain10
                    && !hostSupport.intersection([.hevcMain10, .hevcRext10YUV444]).isEmpty)
        }
    }

    private func clientSupportsYUV444(preferences: StreamingPreferences) -> Bool {
        guard preferences.videoDecoderPreference != .software else { return false }
        let requiredMask: Int32
        switch (preferences.videoCodecPreference, preferences.enableHDR) {
        case (.automatic, false):
            requiredMask = VideoCodecProfile.yuv444Mask
        case (.automatic, true):
            requiredMask = 0x8800
        case (.h264, false):
            requiredMask = 0x0004
        case (.h264, true):
            return false
        case (.hevc, false), (.hevcHDRDeprecated, false), (.bc1, false):
            requiredMask = 0x0C00
        case (.hevc, true), (.hevcHDRDeprecated, true), (.bc1, true):
            requiredMask = 0x0800
        case (.av1, false):
            requiredMask = 0xCC00
        case (.av1, true):
            requiredMask = 0x8800
        }
        return capabilities.supportedVideoFormatMask & requiredMask != 0
    }

    private func hostSupportsHDR(_ support: HostCodecSupport, codec: VideoCodecPreference) -> Bool {
        switch codec {
        case .automatic:
            return !support.intersection(.all10Bit).isEmpty
        case .h264:
            return false
        case .hevc, .hevcHDRDeprecated, .bc1:
            return !support.intersection([.hevcMain10, .hevcRext10YUV444]).isEmpty
        case .av1:
            return !support.intersection([
                .av1Main10, .av1High10YUV444, .hevcMain10, .hevcRext10YUV444,
            ]).isEmpty
        }
    }

    private func hostSupportsYUV444(
        _ support: HostCodecSupport,
        codec: VideoCodecPreference,
        hdr: Bool
    ) -> Bool {
        let required: HostCodecSupport
        switch (codec, hdr) {
        case (.automatic, false):
            required = .allYUV444
        case (.automatic, true):
            required = [.hevcRext10YUV444, .av1High10YUV444]
        case (.h264, false):
            required = .h264High8YUV444
        case (.h264, true):
            return false
        case (.hevc, false), (.hevcHDRDeprecated, false), (.bc1, false):
            required = [.hevcRext8YUV444, .hevcRext10YUV444]
        case (.hevc, true), (.hevcHDRDeprecated, true), (.bc1, true):
            required = .hevcRext10YUV444
        case (.av1, false):
            required = [
                .av1High8YUV444, .av1High10YUV444,
                .hevcRext8YUV444, .hevcRext10YUV444,
            ]
        case (.av1, true):
            required = [.av1High10YUV444, .hevcRext10YUV444]
        }
        return !support.intersection(required).isEmpty
    }

    private static func requestedChannelCount(_ configuration: AudioConfiguration) -> UInt32 {
        switch configuration {
        case .stereo: 2
        case .surround51: 6
        case .surround71: 8
        }
    }
}
