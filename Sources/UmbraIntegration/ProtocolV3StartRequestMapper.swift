import Foundation
import UmbraCore
import UmbraMedia
import UmbraProtocolV3
import UmbraQUICTransport

public struct ProtocolV3StartOffer: Sendable, Equatable {
    public let fields: [UInt64: ProtocolV3CBORValue]
    public let offeredVideoFormats: [MoonlightVideoFormat]
    public let mode: QUICOptimizationMode
    public let microphoneRequired: Bool

    init(
        fields: [UInt64: ProtocolV3CBORValue],
        offeredVideoFormats: [MoonlightVideoFormat],
        mode: QUICOptimizationMode,
        microphoneRequired: Bool = false
    ) {
        self.fields = fields
        self.offeredVideoFormats = offeredVideoFormats
        self.mode = mode
        self.microphoneRequired = microphoneRequired
    }
}

public struct ProtocolV3SelectedMode: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let refreshNumerator: UInt32
    public let refreshDenominator: UInt32
    public let bitrateKbps: Int
}

public enum ProtocolV3StartRequestMapperError: Error, Equatable, Sendable {
    case noSupportedVideoTuple
    case unsupportedRequestedTuple(String)
    case unsupportedAudioLayout
}

private enum ProtocolV3HDRTransfer {
    case pq
    case hlg

    var codecValue: UInt64 {
        switch self {
        case .pq: 16
        case .hlg: 18
        }
    }

    var capabilityValue: UInt64 {
        switch self {
        case .pq: 2
        case .hlg: 3
        }
    }
}

/// Maps resolved user preferences and probed Apple capabilities into explicit
/// v3 START tuples. HDR and 4:4:4 are offered only when the user requested them
/// and this Mac proved the corresponding exact decoder format.
public enum ProtocolV3StartRequestMapper {
    public static func makeOffer(
        applicationID: Int,
        resume: Bool,
        preferences: StreamingPreferences,
        capabilities: AppleStreamingCapabilities,
        startIntentID: Data,
        traceID: Data
    ) throws -> ProtocolV3StartOffer {
        try preferences.validate()
        guard applicationID > 0,
              let applicationID = UInt64(exactly: applicationID),
              let frameRate = preferences.normalizedFrameRate,
              startIntentID.count == 16,
              startIntentID.contains(where: { $0 != 0 }),
              traceID.count == 16,
              traceID.contains(where: { $0 != 0 }) else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple("identity")
        }
        let formats = try orderedFormats(preferences: preferences, capabilities: capabilities)
        let mode: QUICOptimizationMode = preferences.optimizationMode == .latency ? .latency : .quality
        let hdrTransfers = preferences.enableHDR
            ? hdrTransferOffers(for: preferences.hdrTransferPreference)
            : []
        let codecOffers = formats.flatMap { format -> [[UInt64: ProtocolV3CBORValue]] in
            guard !hdrTransfers.isEmpty else {
                return [codecTuple(format, preferences: preferences, hdrTransfer: nil)]
            }
            return hdrTransfers.map {
                codecTuple(format, preferences: preferences, hdrTransfer: $0.codecValue)
            }
        }
        let audioOffers = try audioTuples(preferences: preferences, capabilities: capabilities)
        let microphone: ProtocolV3CBORValue = preferences.clientMicrophoneEnabled
            ? .map(microphoneTuple())
            : .null
        let hdrOffers = hdrTransfers.map {
            ProtocolV3CBORValue.map(hdrCapabilityTuple(transfer: $0.capabilityValue))
        }
        let presentationOffers = presentationTuples(preferences: preferences)
        let strictFidelity = preferences.fidelityPreference == .codecLosslessRequired
        let fields: [UInt64: ProtocolV3CBORValue] = [
            1: .bytes(startIntentID),
            2: .unsigned(applicationID),
            3: .unsigned(mode == .latency ? 1 : 2),
            4: .unsigned(UInt64(preferences.width)),
            5: .unsigned(UInt64(preferences.height)),
            6: .unsigned(UInt64(frameRate.numerator)),
            7: .unsigned(UInt64(frameRate.denominator)),
            8: .unsigned(UInt64(preferences.bitrateKbps)),
            9: .array(codecOffers.map(ProtocolV3CBORValue.map)),
            10: .array(audioOffers.map(ProtocolV3CBORValue.map)),
            11: microphone,
            12: .unsigned(UInt64(QUICTransportProfile.semanticDatagramByteCount)),
            13: .bytes(traceID),
            14: .array(hdrOffers),
            15: .array(presentationOffers.map(ProtocolV3CBORValue.map)),
            16: .boolean(resume),
            17: .map([
                1: .unsigned(strictFidelity ? 3 : (mode == .quality ? 2 : 1)),
                2: .boolean(false),
                3: .boolean(preferences.enableYUV444),
                4: .boolean(preferences.enableHDR),
                5: .boolean(preferences.enableHDR),
                6: .boolean(!strictFidelity && !preferences.enableHDR && !preferences.enableYUV444),
            ]),
            18: .boolean(preferences.playAudioOnHost),
        ]
        return ProtocolV3StartOffer(
            fields: fields,
            offeredVideoFormats: formats,
            mode: mode,
            microphoneRequired: preferences.clientMicrophoneRequired
        )
    }

    private static func hdrTransferOffers(
        for preference: HDRTransferPreference
    ) -> [ProtocolV3HDRTransfer] {
        switch preference {
        case .automatic: [.pq, .hlg]
        case .pq: [.pq]
        case .hlg: [.hlg]
        }
    }

    public static func selectedVideoFormat(
        responseFields: [UInt64: ProtocolV3CBORValue],
        offered: ProtocolV3StartOffer
    ) throws -> MoonlightVideoFormat {
        guard let tuple = responseFields[5]?.mapValue else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple("selected codec")
        }
        guard offered.fields[9]?.arrayValue?.contains(.map(tuple)) == true else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "host selected a codec tuple that was not offered exactly"
            )
        }
        let format = try format(for: tuple)
        guard offered.offeredVideoFormats.contains(format) else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple("host selected an unoffered codec")
        }
        return format
    }

    public static func validateSelectedTuples(
        responseFields: [UInt64: ProtocolV3CBORValue],
        offered: ProtocolV3StartOffer
    ) throws {
        guard Set(offered.fields.keys) == Set(1...18),
              offered.fields[18]?.booleanValue != nil,
              Set(responseFields.keys) == Set(1...23),
              responseFields[1]?.unsignedValue == 0,
              responseFields[2] == offered.fields[1],
              responseFields[4] == offered.fields[3],
              responseFields[11] == offered.fields[12],
              responseFields[20] == offered.fields[13],
              let selectedCodec = responseFields[5],
              offered.fields[9]?.arrayValue?.contains(selectedCodec) == true,
              let selectedAudio = responseFields[12],
              offered.fields[10]?.arrayValue?.contains(selectedAudio) == true,
              isValidMicrophoneSelection(responseFields[13], offered: offered),
              let selectedPresentation = responseFields[18],
              offered.fields[15]?.arrayValue?.contains(selectedPresentation) == true else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "START selected an unoffered exact tuple"
            )
        }
        let selectedMode = try selectedModeScalars(responseFields)
        let selectedHDR = responseFields[23]
        try validateHDRSelection(
            selectedHDR,
            selectedCodec: selectedCodec,
            offeredHDR: offered.fields[14]?.arrayValue ?? []
        )
        try validateSelectedColorMode(
            selectedCodec,
            selectedHDR: selectedHDR,
            selectedMode: selectedMode
        )
        guard let requirements = offered.fields[17]?.mapValue,
              let selectedCodecMap = selectedCodec.mapValue,
              let fidelity = selectedCodecMap[10]?.unsignedValue,
              let minimumFidelity = requirements[1]?.unsignedValue,
              fidelity >= minimumFidelity,
              requirements[2]?.booleanValue != true || selectedCodecMap[4]?.unsignedValue == 3,
              requirements[3]?.booleanValue != true || selectedCodecMap[4]?.unsignedValue == 2,
              requirements[4]?.booleanValue != true || selectedCodecMap[3]?.unsignedValue == 10,
              requirements[5]?.booleanValue != true || selectedHDR != .null else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "START violated the requested fidelity or HDR requirements"
            )
        }
        if minimumFidelity == 3 {
            guard let flags = selectedCodecMap[9]?.unsignedValue,
                  flags & 0x02 != 0,
                  fidelity == 3 else {
                throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                    "codec-lossless selection lacks exact host proof"
                )
            }
        }
        try validateAdjustments(responseFields: responseFields, offered: offered)
    }

    public static func selectedMode(
        responseFields: [UInt64: ProtocolV3CBORValue],
        offered: ProtocolV3StartOffer
    ) throws -> ProtocolV3SelectedMode {
        try validateSelectedTuples(responseFields: responseFields, offered: offered)
        return try selectedModeScalars(responseFields)
    }

    private static func selectedModeScalars(
        _ responseFields: [UInt64: ProtocolV3CBORValue]
    ) throws -> ProtocolV3SelectedMode {
        guard let width = responseFields[6]?.unsignedValue.flatMap(Int.init(exactly:)),
              let height = responseFields[7]?.unsignedValue.flatMap(Int.init(exactly:)),
              (StreamingPreferences.minimumStreamWidth...StreamingPreferences.maximumStreamWidth)
                  .contains(width),
              (StreamingPreferences.minimumStreamHeight...StreamingPreferences.maximumStreamHeight)
                  .contains(height),
              width.isMultiple(of: 2),
              height.isMultiple(of: 2),
              let refreshNumerator = responseFields[8]?.unsignedValue.flatMap(UInt32.init(exactly:)),
              let refreshDenominator = responseFields[9]?.unsignedValue.flatMap(UInt32.init(exactly:)),
              refreshNumerator > 0,
              refreshDenominator > 0,
              greatestCommonDivisor(refreshNumerator, refreshDenominator) == 1,
              StreamingPreferences.isSupportedFrameRate(
                  numerator: Int(refreshNumerator),
                  denominator: Int(refreshDenominator)
              ),
              let bitrateKbps = responseFields[10]?.unsignedValue.flatMap(Int.init(exactly:)),
              (StreamingPreferences.minimumBitrateKbps...StreamingPreferences.maximumBitrateKbps)
                  .contains(bitrateKbps) else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "START selected scalar outside the canonical mode contract"
            )
        }
        return ProtocolV3SelectedMode(
            width: width,
            height: height,
            refreshNumerator: refreshNumerator,
            refreshDenominator: refreshDenominator,
            bitrateKbps: bitrateKbps
        )
    }

    private static func validateSelectedColorMode(
        _ selectedCodec: ProtocolV3CBORValue,
        selectedHDR: ProtocolV3CBORValue?,
        selectedMode: ProtocolV3SelectedMode
    ) throws {
        guard let codec = selectedCodec.mapValue,
              let codecFamily = codec[1]?.unsignedValue,
              let depth = codec[3]?.unsignedValue,
              let transfer = codec[6]?.unsignedValue else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "START selected color mode"
            )
        }
        let valid = if selectedHDR == .null {
            depth == 8 && transfer == 1
        } else {
            depth == 10 && (transfer == 16 || transfer == 18)
        }
        guard valid else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "START selected SDR/HDR depth mismatch"
            )
        }
        guard codecFamily != 1
                || (selectedMode.width <= 4_096 && selectedMode.height <= 4_096) else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "H.264 requires dimensions at or below 4096x4096"
            )
        }
    }

    private static func greatestCommonDivisor(_ lhs: UInt32, _ rhs: UInt32) -> UInt32 {
        var lhs = lhs
        var rhs = rhs
        while rhs != 0 {
            (lhs, rhs) = (rhs, lhs % rhs)
        }
        return lhs
    }

    private static func isValidMicrophoneSelection(
        _ selected: ProtocolV3CBORValue?,
        offered: ProtocolV3StartOffer
    ) -> Bool {
        guard let selected else { return false }
        if selected == offered.fields[11] { return true }
        return !offered.microphoneRequired
            && offered.fields[11]?.mapValue != nil
            && selected == .null
    }

    private static func validateHDRSelection(
        _ selected: ProtocolV3CBORValue?,
        selectedCodec: ProtocolV3CBORValue,
        offeredHDR: [ProtocolV3CBORValue]
    ) throws {
        if selected == .null {
            guard offeredHDR.isEmpty else {
                throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                    "host omitted required HDR selection"
                )
            }
            return
        }
        guard let selectedMap = selected?.mapValue,
              Set(selectedMap.keys) == Set(1...7),
              let transfer = selectedMap[1]?.unsignedValue,
              let primaries = selectedMap[2]?.unsignedValue,
              let matrix = selectedMap[3]?.unsignedValue,
              let range = selectedMap[4]?.unsignedValue,
              let depth = selectedMap[5]?.unsignedValue,
              let codec = selectedCodec.mapValue,
              codec[3]?.unsignedValue == depth,
              codec[5]?.unsignedValue == primaries,
              codec[6]?.unsignedValue == (transfer == 2 ? 16 : transfer == 3 ? 18 : 0),
              codec[7]?.unsignedValue == matrix,
              codec[8]?.unsignedValue == range,
              let capabilityOffer = offeredHDR.compactMap(\.mapValue).first(where: {
                  $0[1]?.unsignedValue == transfer
                      && $0[2]?.unsignedValue == primaries
                      && $0[3]?.unsignedValue == matrix
                      && $0[4]?.unsignedValue == range
                      && $0[5]?.unsignedValue == depth
              }),
              let capability = capabilityOffer[6]?.mapValue,
              Set(capability.keys) == Set(1...4),
              let supportsStatic = capability[1]?.booleanValue,
              let maximumMastering = capability[2]?.unsignedValue,
              let maximumCLL = capability[3]?.unsignedValue,
              let maximumFALL = capability[4]?.unsignedValue,
              let offeredDynamic = capabilityOffer[7]?.arrayValue,
              let selectedDynamic = selectedMap[7]?.arrayValue,
              selectedDynamic.allSatisfy({ selectedValue in
                  offeredDynamic.contains(selectedValue)
              }) else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "host selected unsupported HDR capability"
            )
        }
        switch (transfer, selectedMap[6]) {
        case (_, .null):
            break
        case (2, let .map(mastering)):
            guard supportsStatic,
                  Set(mastering.keys) == Set(1...6),
                  let primaryValues = mastering[1]?.arrayValue,
                  primaryValues.count == 6,
                  primaryValues.allSatisfy({ value in
                      value.unsignedValue.map { $0 <= UInt64(UInt16.max) } == true
                  }),
                  let whiteValues = mastering[2]?.arrayValue,
                  whiteValues.count == 2,
                  whiteValues.allSatisfy({ value in
                      value.unsignedValue.map { $0 <= UInt64(UInt16.max) } == true
                  }),
                  let selectedMaximum = mastering[3]?.unsignedValue,
                  selectedMaximum <= maximumMastering,
                  let selectedMinimum = mastering[4]?.unsignedValue,
                  selectedMinimum <= selectedMaximum,
                  let selectedCLL = mastering[5]?.unsignedValue,
                  selectedCLL <= maximumCLL,
                  let selectedFALL = mastering[6]?.unsignedValue,
                  selectedFALL <= maximumFALL else {
                throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                    "host HDR mastering metadata exceeds client bounds"
                )
            }
        case (3, _):
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "host selected static metadata for HLG"
            )
        default:
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "host HDR mastering metadata is malformed"
            )
        }
    }

    private static func validateAdjustments(
        responseFields: [UInt64: ProtocolV3CBORValue],
        offered: ProtocolV3StartOffer
    ) throws {
        var expected: [UInt64: (ProtocolV3CBORValue, ProtocolV3CBORValue)] = [:]
        let requestedDimensions: ProtocolV3CBORValue = .array([offered.fields[4]!, offered.fields[5]!])
        let selectedDimensions: ProtocolV3CBORValue = .array([responseFields[6]!, responseFields[7]!])
        if requestedDimensions != selectedDimensions { expected[1] = (requestedDimensions, selectedDimensions) }
        let requestedRefresh: ProtocolV3CBORValue = .array([offered.fields[6]!, offered.fields[7]!])
        let selectedRefresh: ProtocolV3CBORValue = .array([responseFields[8]!, responseFields[9]!])
        if requestedRefresh != selectedRefresh { expected[2] = (requestedRefresh, selectedRefresh) }
        if offered.fields[8] != responseFields[10] {
            expected[3] = (offered.fields[8]!, responseFields[10]!)
        }
        guard let rawAdjustments = responseFields[19]?.arrayValue else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple("START adjustment list")
        }
        var observed = Set<UInt64>()
        for value in rawAdjustments {
            guard let adjustment = value.mapValue,
                  Set(adjustment.keys) == Set(1...4),
                  let fieldID = adjustment[1]?.unsignedValue,
                  let values = expected[fieldID],
                  adjustment[2] == values.0,
                  adjustment[3] == values.1,
                  let reason = adjustment[4]?.unsignedValue,
                  (1...5).contains(reason),
                  observed.insert(fieldID).inserted else {
                throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                    "START adjustment was missing, duplicated, or did not match the exact selection"
                )
            }
        }
        guard observed == Set(expected.keys) else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "START changed a scalar without an explicit adjustment"
            )
        }
        if offered.fields[17]?.mapValue?[6]?.booleanValue == false, !expected.isEmpty {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "START adjusted a strict request"
            )
        }
    }

    private static func orderedFormats(
        preferences: StreamingPreferences,
        capabilities: AppleStreamingCapabilities
    ) throws -> [MoonlightVideoFormat] {
        if preferences.fidelityPreference == .codecLosslessRequired,
            !preferences.enableYUV444
        {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "codec-lossless delivery requires a proven 4:4:4 decoder tuple"
            )
        }
        let h264DimensionsSupported = preferences.width <= 4_096 && preferences.height <= 4_096
        if preferences.videoCodecPreference == .h264, !h264DimensionsSupported {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                "H.264 requires dimensions at or below 4096x4096"
            )
        }
        let supported = MoonlightVideoFormat.allCases.filter {
            capabilities.supportedVideoFormatMask & $0.rawValue != 0
        }
        let families: [[MoonlightVideoFormat]]
        switch preferences.videoCodecPreference {
        case .automatic:
            families = preferences.optimizationMode == .quality
                ? [av1Formats, hevcFormats, h264Formats]
                : [hevcFormats, h264Formats, av1Formats]
        case .h264:
            families = [h264Formats]
        case .hevc, .hevcHDRDeprecated:
            families = [hevcFormats]
        case .av1:
            families = [av1Formats]
        }
        var ordered = families.flatMap { family in
            family.filter(supported.contains)
        }
        if !h264DimensionsSupported {
            ordered.removeAll { h264Formats.contains($0) }
        }
        if preferences.enableYUV444 {
            ordered.removeAll { !$0.isYUV444 }
        } else {
            ordered.removeAll { $0.isYUV444 }
        }
        if preferences.enableHDR {
            ordered.removeAll { !$0.isTenBit }
        } else {
            ordered.removeAll { $0.isTenBit }
        }
        guard !ordered.isEmpty else {
            if preferences.enableHDR {
                throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                    "HDR requires a proven ten-bit decoder tuple"
                )
            }
            if preferences.enableYUV444 {
                throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple(
                    "4:4:4 requires a proven hardware decoder tuple"
                )
            }
            throw ProtocolV3StartRequestMapperError.noSupportedVideoTuple
        }
        return ordered
    }

    private static func codecTuple(
        _ format: MoonlightVideoFormat,
        preferences: StreamingPreferences,
        hdrTransfer: UInt64?
    ) -> [UInt64: ProtocolV3CBORValue] {
        let codec: UInt64
        switch format {
        case .h264, .h264High8YUV444: codec = 1
        case .hevc, .hevcMain10, .hevcRext8YUV444, .hevcRext10YUV444: codec = 2
        case .av1Main8, .av1Main10, .av1High8YUV444, .av1High10YUV444: codec = 3
        }
        let hdr = hdrTransfer != nil
        let lossless = preferences.fidelityPreference == .codecLosslessRequired
        return [
            1: .unsigned(codec),
            2: .unsigned(1),
            3: .unsigned(format.isTenBit ? 10 : 8),
            4: .unsigned(format.isYUV444 ? 2 : 1),
            5: .unsigned(hdr ? 9 : 1),
            6: .unsigned(hdrTransfer ?? 1),
            7: .unsigned(hdr ? 9 : 1),
            8: .unsigned(0),
            9: .unsigned(lossless ? 0x02 : 0),
            10: .unsigned(lossless ? 3 : (preferences.optimizationMode == .quality ? 2 : 1)),
        ]
    }

    private static func format(
        for tuple: [UInt64: ProtocolV3CBORValue]
    ) throws -> MoonlightVideoFormat {
        guard let codec = tuple[1]?.unsignedValue,
              let depth = tuple[3]?.unsignedValue,
              let layout = tuple[4]?.unsignedValue else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple("codec tuple")
        }
        let format: MoonlightVideoFormat? = switch (codec, depth, layout) {
        case (1, 8, 1): .h264
        case (1, 8, 2): .h264High8YUV444
        case (2, 8, 1): .hevc
        case (2, 10, 1): .hevcMain10
        case (2, 8, 2): .hevcRext8YUV444
        case (2, 10, 2): .hevcRext10YUV444
        case (3, 8, 1): .av1Main8
        case (3, 10, 1): .av1Main10
        case (3, 8, 2): .av1High8YUV444
        case (3, 10, 2): .av1High10YUV444
        default: nil
        }
        guard let format else {
            throw ProtocolV3StartRequestMapperError.unsupportedRequestedTuple("codec tuple")
        }
        return format
    }

    private static func audioTuples(
        preferences: StreamingPreferences,
        capabilities: AppleStreamingCapabilities
    ) throws -> [[UInt64: ProtocolV3CBORValue]] {
        guard capabilities.hasDefaultAudioOutput, capabilities.supportsNativeAudioOutput else {
            throw ProtocolV3StartRequestMapperError.unsupportedAudioLayout
        }
        let channels: Int = switch preferences.audioConfiguration {
        case .stereo: 2
        case .surround51: 6
        case .surround71: 8
        }
        if capabilities.audioOutputChannelCount != 0,
           capabilities.audioOutputChannelCount < channels {
            throw ProtocolV3StartRequestMapperError.unsupportedAudioLayout
        }
        let mode = preferences.optimizationMode
        let streams: Int
        let coupled: Int
        let bitrate: Int
        switch (mode, channels) {
        case (.latency, 2): (streams, coupled, bitrate) = (1, 1, 96_000)
        case (.quality, 2): (streams, coupled, bitrate) = (1, 1, 512_000)
        case (.latency, 6): (streams, coupled, bitrate) = (4, 2, 256_000)
        case (.quality, 6): (streams, coupled, bitrate) = (6, 0, 1_536_000)
        case (.latency, 8): (streams, coupled, bitrate) = (5, 3, 450_000)
        case (.quality, 8):
            // Five-millisecond frames at 1.536 Mbps have a 960-byte nominal
            // budget, leaving room inside the immutable 1,108-byte ULM3
            // semantic payload. Eight uncoupled streams preserve the exact
            // WAVE 7.1 channel mapping without an implicit remap.
            (streams, coupled, bitrate) = (8, 0, 1_536_000)
        default: throw ProtocolV3StartRequestMapperError.unsupportedAudioLayout
        }
        return [[
            1: .unsigned(1), 2: .unsigned(48_000), 3: .unsigned(UInt64(channels)),
            4: .unsigned(240), 5: .unsigned(UInt64(channels == 2 ? 1 : channels == 6 ? 2 : 3)),
            6: .unsigned(UInt64(streams)), 7: .unsigned(UInt64(coupled)),
            8: .bytes(Data((0..<channels).map(UInt8.init))), 9: .unsigned(UInt64(bitrate)),
        ]]
    }

    private static func microphoneTuple() -> [UInt64: ProtocolV3CBORValue] {
        [
            1: .unsigned(1), 2: .unsigned(48_000), 3: .unsigned(1),
            4: .unsigned(960), 5: .unsigned(0), 6: .unsigned(1),
            7: .unsigned(0), 8: .bytes(Data([0])), 9: .unsigned(32_000),
        ]
    }

    private static func hdrCapabilityTuple(
        transfer: UInt64
    ) -> [UInt64: ProtocolV3CBORValue] {
        [
            1: .unsigned(transfer), 2: .unsigned(9), 3: .unsigned(9),
            4: .unsigned(0), 5: .unsigned(10),
            6: .map([
                1: .boolean(transfer == 2),
                2: .unsigned(UInt64(UInt32.max)),
                3: .unsigned(UInt64(UInt16.max)),
                4: .unsigned(UInt64(UInt16.max)),
            ]),
            7: .array([]),
        ]
    }

    private static func presentationTuples(
        preferences: StreamingPreferences
    ) -> [[UInt64: ProtocolV3CBORValue]] {
        if preferences.optimizationMode == .latency {
            return [[
                1: .unsigned(preferences.enableVSync ? 2 : 1),
                2: .unsigned(1), 3: .boolean(false),
                4: .boolean(preferences.enableVSync), 5: .unsigned(8_000),
            ]]
        }
        return [[
            1: .unsigned(3), 2: .unsigned(2), 3: .boolean(false),
            4: .boolean(true), 5: .unsigned(25_000),
        ]]
    }

    private static let h264Formats: [MoonlightVideoFormat] = [.h264High8YUV444, .h264]
    private static let hevcFormats: [MoonlightVideoFormat] = [
        .hevcRext10YUV444, .hevcMain10, .hevcRext8YUV444, .hevc,
    ]
    private static let av1Formats: [MoonlightVideoFormat] = [
        .av1High10YUV444, .av1Main10, .av1High8YUV444, .av1Main8,
    ]
}
