import UmbraCore
import UmbraMedia
import UmbraServices

/// Selects one exact GameStream client video format from independently reported
/// client and host capabilities. Lumen SCM bits must never be intersected
/// directly with GameStream client-format bits because their positions differ.
public struct VideoFormatNegotiator: Sendable {
    public init() {}

    public func select(
        availableVideoFormats: Int32,
        host: StreamHost,
        application: StreamApplication,
        preferences: StreamingPreferences
    ) throws -> StreamPreparationResult {
        let clientFormats = availableVideoFormats & GameStreamVideoFormat.knownMask
        let commonFormats = clientFormats & Self.clientFormatMask(
            for: host.codecSupport,
            maxLumaPixelsHEVC: host.maxLumaPixelsHEVC
        )
        // Modern Lumen hosts can enable HDR for applications that don't carry
        // NVIDIA's legacy per-app certification flag. Treat that flag as advisory.
        let wantsHDR = preferences.enableHDR
        let wantsYUV444 = preferences.enableYUV444

        var candidates = basePriority(preferences: preferences)
        if preferences.fidelityPreference == .codecLosslessRequired {
            guard preferences.optimizationMode == .quality else {
                throw UmbraIntegrationError.codecLosslessUnavailable(
                    "the lossless encoder path is intentionally excluded from Latency mode"
                )
            }
            candidates = candidates.filter { format in
                commonFormats & format.rawValue != 0
                    && hostProvesLossless(format, support: host.codecSupport)
                    && format.isTenBit == wantsHDR
            }
            candidates = (0...3).flatMap { rank in
                candidates.filter { fidelityRank($0) == rank }
            }
            guard let format = candidates.first else {
                throw UmbraIntegrationError.codecLosslessUnavailable(
                    "the host and this Mac did not prove a common exact decoder tuple and codec-specific NVENC lossless capability"
                )
            }
            return StreamPreparationResult(
                selectedVideoFormat: format.rawValue,
                isHDR: wantsHDR && format.isTenBit,
                isYUV444: format.isYUV444,
                fidelity: fidelityClass(format)
            )
        }
        if wantsYUV444 {
            candidates = preferred(candidates, where: \.isYUV444)
        } else {
            candidates.removeAll(where: \.isYUV444)
        }
        if wantsHDR {
            // HDR is the stronger requirement, so this stable partition is
            // intentionally applied after the 4:4:4 preference.
            candidates = preferred(candidates, where: \.isTenBit)
        } else {
            candidates.removeAll(where: \.isTenBit)
        }

        if let format = candidates.first(where: { commonFormats & $0.rawValue != 0 }) {
            return StreamPreparationResult(
                selectedVideoFormat: format.rawValue,
                isHDR: wantsHDR && format.isTenBit,
                isYUV444: format.isYUV444,
                fidelity: preferences.optimizationMode == .latency
                    ? .latencyRateControlled
                    : .visuallyLosslessRateControlled
            )
        }

        throw UmbraIntegrationError.unsupportedVideoConfiguration(
            preferences.videoCodecPreference
        )
    }

    /// Explicit Lumen SCM to GameStream client-format mapping.
    public static func clientFormatMask(
        for hostSupport: HostCodecSupport,
        maxLumaPixelsHEVC: Int = 0
    ) -> Int32 {
        var formats: Int32 = 0
        if hostSupport.contains(.h264) { formats |= GameStreamVideoFormat.h264.rawValue }
        if hostSupport.contains(.h264High8YUV444) {
            formats |= GameStreamVideoFormat.h264High8YUV444.rawValue
        }
        if hostSupport.contains(.hevc) || maxLumaPixelsHEVC > 0 {
            formats |= GameStreamVideoFormat.hevc.rawValue
        }
        if hostSupport.contains(.hevcMain10) {
            formats |= GameStreamVideoFormat.hevcMain10.rawValue
        }
        if hostSupport.contains(.hevcRext8YUV444) {
            formats |= GameStreamVideoFormat.hevcRext8YUV444.rawValue
        }
        if hostSupport.contains(.hevcRext10YUV444) {
            formats |= GameStreamVideoFormat.hevcRext10YUV444.rawValue
        }
        if hostSupport.contains(.av1Main8) {
            formats |= GameStreamVideoFormat.av1Main8.rawValue
        }
        if hostSupport.contains(.av1Main10) {
            formats |= GameStreamVideoFormat.av1Main10.rawValue
        }
        if hostSupport.contains(.av1High8YUV444) {
            formats |= GameStreamVideoFormat.av1High8YUV444.rawValue
        }
        if hostSupport.contains(.av1High10YUV444) {
            formats |= GameStreamVideoFormat.av1High10YUV444.rawValue
        }
        return formats
    }

    private enum CodecFamily {
        case h264
        case hevc
        case av1
    }

    private func hostProvesLossless(
        _ format: GameStreamVideoFormat,
        support: HostCodecSupport
    ) -> Bool {
        switch format {
        case .h264:
            false
        case .h264High8YUV444:
            support.contains(.h264Lossless)
        case .hevc, .hevcMain10, .hevcRext8YUV444, .hevcRext10YUV444:
            support.contains(.hevcLossless)
        case .av1Main8, .av1Main10, .av1High8YUV444, .av1High10YUV444:
            support.contains(.av1Lossless)
        }
    }

    private func fidelityRank(_ format: GameStreamVideoFormat) -> Int {
        switch (format.isYUV444, format.isTenBit) {
        case (true, true): 0
        case (true, false): 1
        case (false, true): 2
        case (false, false): 3
        }
    }

    private func fidelityClass(_ format: GameStreamVideoFormat) -> StreamVideoFidelityClass {
        switch (format.isYUV444, format.isTenBit) {
        case (true, true): .codecLosslessYUV44410Bit
        case (true, false): .codecLosslessYUV4448Bit
        case (false, true): .codecLosslessYUV42010Bit
        case (false, false): .codecLosslessYUV4208Bit
        }
    }

    private func basePriority(preferences: StreamingPreferences) -> [GameStreamVideoFormat] {
        switch preferences.videoCodecPreference {
        case .automatic:
            if preferences.videoDecoderPreference == .software {
                return [CodecFamily.h264, .hevc].flatMap(allFormats(for:))
            }
            return [CodecFamily.hevc, .h264, .av1].flatMap(allFormats(for:))
        case .h264:
            return allFormats(for: .h264)
        case .hevc, .hevcHDRDeprecated:
            return allFormats(for: .hevc) + [.h264]
        case .av1:
            return allFormats(for: .av1) + allFormats(for: .hevc) + [.h264]
        }
    }

    private func allFormats(for family: CodecFamily) -> [GameStreamVideoFormat] {
        switch family {
        case .h264:
            [.h264High8YUV444, .h264]
        case .hevc:
            [.hevcRext10YUV444, .hevcMain10, .hevcRext8YUV444, .hevc]
        case .av1:
            [.av1High10YUV444, .av1Main10, .av1High8YUV444, .av1Main8]
        }
    }

    private func preferred(
        _ formats: [GameStreamVideoFormat],
        where predicate: KeyPath<GameStreamVideoFormat, Bool>
    ) -> [GameStreamVideoFormat] {
        formats.filter { $0[keyPath: predicate] }
            + formats.filter { !$0[keyPath: predicate] }
    }
}
