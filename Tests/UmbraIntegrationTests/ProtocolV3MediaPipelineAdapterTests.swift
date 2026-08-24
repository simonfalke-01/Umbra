import Foundation
import XCTest
import UmbraCore
import UmbraMedia
import UmbraProtocolV3
import UmbraQUICTransport
import UmbraStreaming
@testable import UmbraIntegration

final class ProtocolV3MediaPipelineAdapterTests: XCTestCase {
    func testQualityReassemblyWaitUsesExactRationalRefreshTiming() {
        XCTAssertEqual(
            ProtocolV3VideoReassembler.qualityWaitNanoseconds(
                refreshNumerator: 60_000,
                refreshDenominator: 1_001
            ),
            66_733_333
        )
        XCTAssertEqual(
            ProtocolV3VideoReassembler.qualityWaitNanoseconds(
                refreshNumerator: 60,
                refreshDenominator: 1
            ),
            66_666_666
        )
        XCTAssertEqual(
            ProtocolV3VideoReassembler.qualityWaitNanoseconds(
                refreshNumerator: 120,
                refreshDenominator: 1
            ),
            50_000_000
        )
        XCTAssertEqual(
            ProtocolV3VideoReassembler.qualityWaitNanoseconds(
                refreshNumerator: 10,
                refreshDenominator: 1
            ),
            250_000_000
        )
    }

    func testReassemblyUsesOneStableAllocationAndTransfersItWithoutCopying() throws {
        let reassembler = ProtocolV3VideoReassembler(mode: .latency)
        let bytes = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })

        let first = try reassembler.accept(
            fragment(
                frameID: 1,
                frameSize: bytes.count,
                offset: 0,
                index: 0,
                count: 3,
                bytes: bytes[0..<1_024],
                receivedAtNanoseconds: 1
            ),
            framesPerSecond: 120
        )
        XCTAssertTrue(first.readyFrames.isEmpty)
        let allocationAddress = try XCTUnwrap(reassembler.storageAddress(frameID: 1))
        XCTAssertNotEqual(allocationAddress, 0)

        let second = try reassembler.accept(
            fragment(
                frameID: 1,
                frameSize: bytes.count,
                offset: 1_024,
                index: 1,
                count: 3,
                bytes: bytes[1_024..<3_072],
                receivedAtNanoseconds: 2
            ),
            framesPerSecond: 120
        )
        XCTAssertTrue(second.readyFrames.isEmpty)
        XCTAssertEqual(reassembler.storageAddress(frameID: 1), allocationAddress)

        let completed = try reassembler.accept(
            fragment(
                frameID: 1,
                frameSize: bytes.count,
                offset: 3_072,
                index: 2,
                count: 3,
                bytes: bytes[3_072..<4_096],
                receivedAtNanoseconds: 3
            ),
            framesPerSecond: 120
        )
        let frame = try XCTUnwrap(completed.readyFrames.only)
        let handedOffAddress = frame.data.withUnsafeBytes { buffer in
            buffer.baseAddress.map(UInt.init(bitPattern:))
        }
        XCTAssertEqual(handedOffAddress, allocationAddress)
        XCTAssertEqual(frame.data, bytes)
        XCTAssertTrue(reassembler.pendingFrameIDs.isEmpty)
    }

    func testQualityWaitsForOlderIncompleteDependentFrameBeforeRelease() throws {
        let reassembler = ProtocolV3VideoReassembler(mode: .quality)

        _ = try reassembler.accept(
            fragment(
                frameID: 1,
                frameSize: 4,
                offset: 0,
                index: 0,
                count: 2,
                flags: 0x01,
                bytes: Data([1, 2]),
                receivedAtNanoseconds: 1_000_000
            ),
            framesPerSecond: 120
        )
        let newer = try reassembler.accept(
            fragment(
                frameID: 2,
                frameSize: 2,
                flags: 0,
                bytes: Data([5, 6]),
                receivedAtNanoseconds: 2_000_000
            ),
            framesPerSecond: 120
        )
        XCTAssertTrue(newer.readyFrames.isEmpty)
        XCTAssertEqual(reassembler.pendingFrameIDs, [1, 2])

        let ordered = try reassembler.accept(
            fragment(
                frameID: 1,
                frameSize: 4,
                offset: 2,
                index: 1,
                count: 2,
                flags: 0x01,
                bytes: Data([3, 4]),
                receivedAtNanoseconds: 3_000_000
            ),
            framesPerSecond: 120
        )
        XCTAssertEqual(ordered.readyFrames.map(\.frameID), [1, 2])
        XCTAssertEqual(ordered.readyFrames.map(\.data), [Data([1, 2, 3, 4]), Data([5, 6])])
    }

    func testQualityExpiredDependencyRequestsKeyFrameAndRejectsDependentsUntilRecovery() throws {
        let reassembler = ProtocolV3VideoReassembler(mode: .quality)

        _ = try reassembler.accept(
            fragment(
                frameID: 1,
                frameSize: 4,
                offset: 0,
                index: 0,
                count: 2,
                flags: 0x01,
                bytes: Data([1, 2]),
                receivedAtNanoseconds: 1_000_000
            ),
            framesPerSecond: 120
        )
        _ = try reassembler.accept(
            fragment(
                frameID: 2,
                frameSize: 2,
                bytes: Data([5, 6]),
                receivedAtNanoseconds: 2_000_000
            ),
            framesPerSecond: 120
        )
        let expired = try reassembler.accept(
            fragment(
                frameID: 3,
                frameSize: 2,
                bytes: Data([7, 8]),
                receivedAtNanoseconds: 60_000_000
            ),
            framesPerSecond: 120
        )
        XCTAssertEqual(expired.lostFrameIDs.sorted(), [1, 2])
        XCTAssertEqual(expired.requestedKeyFrameID, 1)
        XCTAssertTrue(expired.readyFrames.isEmpty)
        XCTAssertTrue(reassembler.requiresKeyFrame)
        XCTAssertTrue(reassembler.pendingFrameIDs.isEmpty)

        let ignoredDependent = try reassembler.accept(
            fragment(
                frameID: 4,
                frameSize: 2,
                bytes: Data([9, 10]),
                receivedAtNanoseconds: 61_000_000
            ),
            framesPerSecond: 120
        )
        XCTAssertTrue(ignoredDependent.readyFrames.isEmpty)
        XCTAssertTrue(reassembler.pendingFrameIDs.isEmpty)

        let recovered = try reassembler.accept(
            fragment(
                frameID: 5,
                frameSize: 2,
                flags: 0x01,
                bytes: Data([11, 12]),
                receivedAtNanoseconds: 62_000_000
            ),
            framesPerSecond: 120
        )
        XCTAssertEqual(recovered.readyFrames.map(\.frameID), [5])
        XCTAssertFalse(reassembler.requiresKeyFrame)
    }

    func testQualityCompletedKeyFrameSupersedesOlderIncompleteFrame() throws {
        let reassembler = ProtocolV3VideoReassembler(mode: .quality)
        _ = try reassembler.accept(
            fragment(
                frameID: 1,
                frameSize: 4,
                offset: 0,
                index: 0,
                count: 2,
                bytes: Data([1, 2]),
                receivedAtNanoseconds: 1
            ),
            framesPerSecond: 120
        )
        let keyFrame = try reassembler.accept(
            fragment(
                frameID: 2,
                frameSize: 2,
                flags: 0x01,
                bytes: Data([3, 4]),
                receivedAtNanoseconds: 2
            ),
            framesPerSecond: 120
        )
        XCTAssertEqual(keyFrame.lostFrameIDs, [1])
        XCTAssertEqual(keyFrame.readyFrames.map(\.frameID), [2])
        XCTAssertEqual(keyFrame.readyFrames.first?.data, Data([3, 4]))
    }

    func testLatencyStillDropsOlderAssemblyForNewestFrame() throws {
        let reassembler = ProtocolV3VideoReassembler(mode: .latency)
        _ = try reassembler.accept(
            fragment(
                frameID: 1,
                frameSize: 4,
                offset: 0,
                index: 0,
                count: 2,
                bytes: Data([1, 2]),
                receivedAtNanoseconds: 1
            ),
            framesPerSecond: 120
        )
        let newest = try reassembler.accept(
            fragment(
                frameID: 2,
                frameSize: 2,
                bytes: Data([3, 4]),
                receivedAtNanoseconds: 2
            ),
            framesPerSecond: 120
        )
        XCTAssertEqual(newest.lostFrameIDs, [1])
        XCTAssertEqual(newest.readyFrames.map(\.frameID), [2])

        let stale = try reassembler.accept(
            fragment(
                frameID: 1,
                frameSize: 4,
                offset: 2,
                index: 1,
                count: 2,
                bytes: Data([5, 6]),
                receivedAtNanoseconds: 3
            ),
            framesPerSecond: 120
        )
        XCTAssertTrue(stale.readyFrames.isEmpty)
        XCTAssertTrue(reassembler.pendingFrameIDs.isEmpty)
    }

    /// Pure negotiation-vector coverage supplements production runtime and
    /// kernel-loopback verification. It does not substitute a fake media sink.
    func testQualityStartOfferPreservesResolvedNativeTupleWithoutAutoEnablingHDR() throws {
        var preferences = StreamingPreferences.default
        preferences.width = 3_840
        preferences.height = 2_160
        preferences.fps = 120
        preferences.bitrateKbps = 150_000
        preferences.optimizationMode = .quality
        preferences.enableYUV444 = true
        preferences.enableHDR = false
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2,
            supportsHardwareHEVCMain10: true,
            supportsHardwareAV1Main10: true,
            supportedHardwareYUV444FormatMask: 0xCC04
        )

        let offer = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 7,
            resume: false,
            preferences: preferences,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )

        XCTAssertEqual(offer.fields[4]?.unsignedValue, 3_840)
        XCTAssertEqual(offer.fields[5]?.unsignedValue, 2_160)
        XCTAssertEqual(offer.fields[6]?.unsignedValue, 120)
        XCTAssertEqual(offer.fields[14]?.arrayValue, [])
        XCTAssertEqual(offer.offeredVideoFormats.first, .av1High8YUV444)
        let requirements = try XCTUnwrap(offer.fields[17]?.mapValue)
        XCTAssertEqual(requirements[5]?.booleanValue, false)
        XCTAssertEqual(requirements[3]?.booleanValue, true)
    }

    func testStartOfferPreservesExactRationalVDDRefreshRate() throws {
        var preferences = StreamingPreferences.default
        preferences.setFrameRate(numerator: 60_000, denominator: 1_001)
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2
        )

        let offer = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 8,
            resume: false,
            preferences: preferences,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )

        XCTAssertEqual(offer.fields[6]?.unsignedValue, 60_000)
        XCTAssertEqual(offer.fields[7]?.unsignedValue, 1_001)
        XCTAssertNoThrow(try ProtocolV3StartRequestMapper.validateSelectedTuples(
            responseFields: successfulStartResponse(offer),
            offered: offer
        ))
    }

    func testVideoConfigMustMatchExactRationalStartSelection() throws {
        var preferences = StreamingPreferences.default
        preferences.width = 1_920
        preferences.height = 1_080
        preferences.setFrameRate(numerator: 60_000, denominator: 1_001)
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2
        )
        let offer = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 10,
            resume: false,
            preferences: preferences,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        let selection = successfulStartResponse(offer)
        let videoDecoder = RationalRefreshVideoDecoder()
        let adapter = try ProtocolV3MediaPipelineAdapter(
            pipeline: StreamingMediaPipeline(
                videoDecoder: videoDecoder,
                audioDecoder: RationalRefreshAudioDecoder(),
                availableVideoFormats: capabilities.supportedVideoFormatMask
            ),
            mode: .quality,
            startResponseFields: selection
        )
        let fields = videoConfigurationFields(selection)

        var changedRefresh = fields
        changedRefresh[8] = .unsigned(60)
        changedRefresh[9] = .unsigned(1)
        XCTAssertThrowsError(try adapter.configureVideo(fields: changedRefresh))

        var changedWidth = fields
        changedWidth[6] = .unsigned(1_918)
        XCTAssertThrowsError(try adapter.configureVideo(fields: changedWidth))
        XCTAssertTrue(videoDecoder.configuredFormats.isEmpty)

        XCTAssertEqual(try adapter.configureVideo(fields: fields), 2)
        XCTAssertEqual(videoDecoder.configuredFormats.only?.width, 1_920)
        XCTAssertEqual(videoDecoder.configuredFormats.only?.height, 1_080)
        XCTAssertEqual(videoDecoder.configuredFormats.only?.redrawRate, 60)
    }

    func testStartSelectionRejectsAnyExactTupleMutation() throws {
        var preferences = StreamingPreferences.default
        preferences.optimizationMode = .quality
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2
        )
        let offer = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 9,
            resume: false,
            preferences: preferences,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        var response = successfulStartResponse(offer)
        XCTAssertNoThrow(try ProtocolV3StartRequestMapper.validateSelectedTuples(
            responseFields: response,
            offered: offer
        ))

        var changedCodec = try XCTUnwrap(response[5]?.mapValue)
        changedCodec[7] = .unsigned(9)
        response[5] = .map(changedCodec)
        XCTAssertThrowsError(try ProtocolV3StartRequestMapper.validateSelectedTuples(
            responseFields: response,
            offered: offer
        ))
    }

    func testQualitySurround71TupleFitsTheSemanticDatagramBudget() throws {
        var preferences = StreamingPreferences.default
        preferences.optimizationMode = .quality
        preferences.audioConfiguration = .surround71
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: false,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 8
        )
        let offer = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 11,
            resume: false,
            preferences: preferences,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        let tuple = try XCTUnwrap(offer.fields[10]?.arrayValue?.first?.mapValue)
        XCTAssertEqual(tuple[3]?.unsignedValue, 8)
        XCTAssertEqual(tuple[4]?.unsignedValue, 240)
        XCTAssertEqual(tuple[6]?.unsignedValue, 8)
        XCTAssertEqual(tuple[7]?.unsignedValue, 0)
        XCTAssertEqual(tuple[8]?.bytesValue, Data(0..<8))
        let bitrate = try XCTUnwrap(tuple[9]?.unsignedValue)
        let nominalPacketBytes = bitrate * 240 / 48_000 / 8
        XCTAssertLessThanOrEqual(nominalPacketBytes + 48, 1_108)
    }

    private func successfulStartResponse(
        _ offer: ProtocolV3StartOffer
    ) -> [UInt64: ProtocolV3CBORValue] {
        let codec = offer.fields[9]!.arrayValue!.first!
        let audio = offer.fields[10]!.arrayValue!.first!
        let presentation = offer.fields[15]!.arrayValue!.first!
        let hdr = offer.fields[14]!.arrayValue!.first ?? .null
        return [
            1: .unsigned(0), 2: offer.fields[1]!, 3: .bytes(Data(33...48)),
            4: offer.fields[3]!, 5: codec, 6: offer.fields[4]!, 7: offer.fields[5]!,
            8: offer.fields[6]!, 9: offer.fields[7]!, 10: offer.fields[8]!,
            11: offer.fields[12]!, 12: audio, 13: offer.fields[11]!,
            14: .unsigned(1), 15: .unsigned(1), 16: .unsigned(1), 17: .unsigned(1),
            18: presentation, 19: .array([]), 20: offer.fields[13]!,
            21: .bytes(Data(49...80)), 22: .unsigned(1), 23: hdr,
        ]
    }

    private func videoConfigurationFields(
        _ selection: [UInt64: ProtocolV3CBORValue]
    ) -> [UInt64: ProtocolV3CBORValue] {
        [
            1: selection[3]!,
            2: selection[14]!,
            3: selection[5]!,
            4: .bytes(Data([1, 2, 3, 4])),
            5: selection[23]!,
            6: selection[6]!,
            7: selection[7]!,
            8: selection[8]!,
            9: selection[9]!,
        ]
    }

    private func fragment(
        frameID: UInt64,
        frameSize: Int,
        offset: Int = 0,
        index: Int = 0,
        count: Int = 1,
        flags: UInt8 = 0,
        bytes: Data,
        receivedAtNanoseconds: UInt64
    ) -> ProtocolV3VideoFragment {
        ProtocolV3VideoFragment(
            frameID: frameID,
            frameSize: frameSize,
            fragmentOffset: offset,
            fragmentIndex: index,
            fragmentCount: count,
            captureTimeMicroseconds: 10,
            encoderCompleteDeltaMicroseconds: 20,
            appliedInputStateSequence: 30,
            appliedInputEdgeID: 40,
            videoGeneration: 1,
            codecID: 2,
            matrix: 1,
            bitDepth: 8,
            flags: flags,
            bytes: bytes,
            receivedAtNanoseconds: receivedAtNanoseconds
        )
    }
}

private final class RationalRefreshVideoDecoder: UmbraStreaming.VideoDecoding,
    UmbraStreaming.VideoCodecInitializationPreparing,
    UmbraStreaming.VideoDecodeOutcomeReporting,
    @unchecked Sendable {
    private let lock = NSLock()
    private var formats: [UmbraStreaming.VideoStreamFormat] = []

    var configuredFormats: [UmbraStreaming.VideoStreamFormat] { lock.withLock { formats } }

    func configure(format: UmbraStreaming.VideoStreamFormat) -> Bool {
        lock.withLock { formats.append(format) }
        return true
    }

    func start() {}
    func stop() {}
    func cleanUp() {}
    func submit(
        frame: UmbraStreaming.CompressedVideoFrame
    ) -> UmbraStreaming.VideoFrameDisposition { .accepted }

    func prepareCodecInitialization(
        _ data: Data,
        payloadFormat: UmbraStreaming.EncodedVideoPayloadFormat
    ) -> Bool {
        !data.isEmpty
    }

    func installDecodeOutcomeHandler(
        _ handler: @escaping @Sendable (UmbraStreaming.VideoDecodeOutcome) -> Void
    ) {}
}

private final class RationalRefreshAudioDecoder: UmbraStreaming.AudioDecoding, @unchecked Sendable {
    func configure(format: UmbraStreaming.OpusStreamFormat) -> Bool { true }
    func start() {}
    func stop() {}
    func cleanUp() {}
    func submit(packet: UmbraStreaming.CompressedAudioPacket) {}
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
