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

    func testGate1StartOfferWireRoundTripPreservesExactSchemaAndRational() throws {
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2
        )
        let codec = ProtocolV3CBORCodec()

        for playAudioOnHost in [false, true] {
            var preferences = StreamingPreferences.default
            preferences.setFrameRate(numerator: 60_000, denominator: 1_001)
            preferences.playAudioOnHost = playAudioOnHost
            let offer = try ProtocolV3StartRequestMapper.makeOffer(
                applicationID: playAudioOnHost ? 26 : 25,
                resume: false,
                preferences: preferences,
                capabilities: capabilities,
                startIntentID: Data(1...16),
                traceID: Data(17...32)
            )

            let encoded = try codec.encode(.map(offer.fields))
            let decoded = try XCTUnwrap(try codec.decode(encoded).mapValue)
            XCTAssertEqual(Set(decoded.keys), Set(1...18))
            XCTAssertEqual(decoded[6]?.unsignedValue, 60_000)
            XCTAssertEqual(decoded[7]?.unsignedValue, 1_001)
            XCTAssertEqual(decoded[18]?.booleanValue, playAudioOnHost)
            XCTAssertEqual(try codec.encode(.map(decoded)), encoded)
        }
    }

    func testGate1ConsumesCanonicalLumenStartRequestVectorByteForByte() throws {
        guard let lumenSourceRoot = ProcessInfo.processInfo.environment["LUMEN_SOURCE_ROOT"] else {
            throw XCTSkip("Set LUMEN_SOURCE_ROOT to run the cross-repository Gate 1 vector check.")
        }
        let vectorURL = URL(fileURLWithPath: lumenSourceRoot, isDirectory: true)
            .appendingPathComponent("docs/protocols/vectors/quic_v3_vectors.json")
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL)) as? [String: Any]
        )
        let artifacts = try XCTUnwrap(document["artifacts"] as? [String: Any])
        let startRequest = try XCTUnwrap(artifacts["start_request"] as? [String: Any])
        let frame = try XCTUnwrap(
            Data(gate1Hexadecimal: try XCTUnwrap(startRequest["hex"] as? String))
        )

        XCTAssertEqual(frame.prefix(8), Data([0x55, 0x4c, 0x43, 0x33, 0x03, 0x00, 0x01, 0x00]))
        XCTAssertEqual(frame[8..<16], Data([0, 0, 0, 0, 0, 0, 0, 5]))
        XCTAssertEqual(frame[20..<24], Data(repeating: 0, count: 4))
        let payloadLength = frame[16..<20].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        XCTAssertEqual(Int(payloadLength), frame.count - 24)

        let payload = Data(frame.dropFirst(24))
        let fields = try XCTUnwrap(try ProtocolV3CBORCodec().decode(payload).mapValue)
        XCTAssertEqual(Set(fields.keys), Set(1...18))
        XCTAssertNotNil(fields[18]?.booleanValue)
        let numerator = try XCTUnwrap(fields[6]?.unsignedValue)
        let denominator = try XCTUnwrap(fields[7]?.unsignedValue)
        XCTAssertGreaterThan(denominator, 0)
        XCTAssertGreaterThanOrEqual(Double(numerator) / Double(denominator), 10)
        XCTAssertLessThanOrEqual(Double(numerator) / Double(denominator), 480)
        XCTAssertEqual(try ProtocolV3CBORCodec().encode(.map(fields)), payload)
    }

    func testStartOfferCarriesExplicitHostAudioPreferenceAndSelectionRequiresIt() throws {
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2
        )

        for playAudioOnHost in [false, true] {
            var preferences = StreamingPreferences.default
            preferences.playAudioOnHost = playAudioOnHost
            let offer = try ProtocolV3StartRequestMapper.makeOffer(
                applicationID: playAudioOnHost ? 19 : 18,
                resume: false,
                preferences: preferences,
                capabilities: capabilities,
                startIntentID: Data(1...16),
                traceID: Data(17...32)
            )

            XCTAssertEqual(offer.fields[18]?.booleanValue, playAudioOnHost)
            XCTAssertNoThrow(try ProtocolV3StartRequestMapper.validateSelectedTuples(
                responseFields: successfulStartResponse(offer),
                offered: offer
            ))

            var missingKey = offer.fields
            missingKey.removeValue(forKey: 18)
            var extraKey = offer.fields
            extraKey[19] = .boolean(false)
            var nullSubstitute = offer.fields
            nullSubstitute[18] = .null
            var integerSubstitute = offer.fields
            integerSubstitute[18] = .unsigned(0)
            var stringSubstitute = offer.fields
            stringSubstitute[18] = .text("false")

            for (name, fields) in [
                ("missing key 18", missingKey),
                ("extra key 19", extraKey),
                ("null key 18", nullSubstitute),
                ("integer key 18", integerSubstitute),
                ("string key 18", stringSubstitute),
            ] {
                let hostile = ProtocolV3StartOffer(
                    fields: fields,
                    offeredVideoFormats: offer.offeredVideoFormats,
                    mode: offer.mode
                )
                XCTAssertThrowsError(
                    try ProtocolV3StartRequestMapper.validateSelectedTuples(
                        responseFields: successfulStartResponse(offer),
                        offered: hostile
                    ),
                    name
                )
            }
        }
    }

    func testGate1H264AdmissionEnforcesThe4096By4096CeilingBeforeStart() throws {
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2
        )

        var boundary = StreamingPreferences.default
        boundary.videoCodecPreference = .h264
        boundary.width = 4_096
        boundary.height = 4_096
        let accepted = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 20,
            resume: false,
            preferences: boundary,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        XCTAssertTrue(
            accepted.fields[9]?.arrayValue?.allSatisfy {
                $0.mapValue?[1]?.unsignedValue == 1
            } == true
        )

        var oversizedH264 = boundary
        oversizedH264.width = 4_098
        XCTAssertThrowsError(try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 21,
            resume: false,
            preferences: oversizedH264,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        ))

        var automatic = oversizedH264
        automatic.videoCodecPreference = .automatic
        let fallback = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 22,
            resume: false,
            preferences: automatic,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        XCTAssertFalse(
            fallback.fields[9]?.arrayValue?.contains {
                $0.mapValue?[1]?.unsignedValue == 1
            } == true,
            "automatic negotiation must not offer an oversized H.264 tuple"
        )

        var oddDimension = automatic
        oddDimension.width = 4_097
        XCTAssertThrowsError(try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 27,
            resume: false,
            preferences: oddDimension,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        ))
    }

    func testGate1SDRAndHDROffersNeverProduceAnSDRTenBitTuple() throws {
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2,
            supportsHardwareHEVCMain10: true,
            supportsHardwareAV1Main10: true
        )

        var sdr = StreamingPreferences.default
        sdr.enableHDR = false
        let sdrOffer = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 23,
            resume: false,
            preferences: sdr,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        XCTAssertTrue(
            sdrOffer.fields[9]?.arrayValue?.allSatisfy {
                $0.mapValue?[3]?.unsignedValue == 8
                    && $0.mapValue?[6]?.unsignedValue == 1
            } == true
        )
        XCTAssertEqual(sdrOffer.fields[14], .array([]))

        var hdrH264 = sdr
        hdrH264.videoCodecPreference = .h264
        hdrH264.enableHDR = true
        XCTAssertThrowsError(try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 24,
            resume: false,
            preferences: hdrH264,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
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

    func testVideoFeedbackReportsExactBoundedClientLocalDeadlineMiss() throws {
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
            applicationID: 13,
            resume: false,
            preferences: preferences,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        let selection = successfulStartResponse(offer)
        let decoder = RationalRefreshVideoDecoder()
        let clock = ProtocolV3DeadlineTestClock(nanoseconds: 1_025_123_001)
        let feedback = ProtocolV3FeedbackRecorder()
        let adapter = try ProtocolV3MediaPipelineAdapter(
            pipeline: StreamingMediaPipeline(
                videoDecoder: decoder,
                audioDecoder: RationalRefreshAudioDecoder(),
                availableVideoFormats: capabilities.supportedVideoFormatMask
            ),
            mode: .quality,
            startResponseFields: selection,
            nowNanoseconds: { clock.nanoseconds }
        )
        adapter.installVideoFeedbackHandler { feedback.append($0) }
        XCTAssertEqual(try adapter.configureVideo(fields: videoConfigurationFields(selection)), 2)

        let codec = try XCTUnwrap(selection[5]?.mapValue)
        try adapter.handle(videoMessage(
            frameID: 1,
            frameSize: 4,
            fragmentOffset: 0,
            fragmentIndex: 0,
            fragmentCount: 2,
            codecID: UInt8(try XCTUnwrap(codec[1]?.unsignedValue)),
            matrix: UInt8(try XCTUnwrap(codec[7]?.unsignedValue)),
            bitDepth: UInt8(try XCTUnwrap(codec[3]?.unsignedValue)),
            generation: 1,
            bytes: Data([1, 2]),
            receivedAtNanoseconds: 1_000_000_000
        ))
        try adapter.handle(videoMessage(
            frameID: 1,
            frameSize: 4,
            fragmentOffset: 2,
            fragmentIndex: 1,
            fragmentCount: 2,
            codecID: UInt8(try XCTUnwrap(codec[1]?.unsignedValue)),
            matrix: UInt8(try XCTUnwrap(codec[7]?.unsignedValue)),
            bitDepth: UInt8(try XCTUnwrap(codec[3]?.unsignedValue)),
            generation: 1,
            bytes: Data([3, 4]),
            receivedAtNanoseconds: 1_024_900_000
        ))
        decoder.emit(.decoded(frameNumber: 1))

        let decoded = try XCTUnwrap(feedback.values.only)
        XCTAssertEqual(decoded.action, 1)
        XCTAssertEqual(decoded.affectedFrameID, 1)
        XCTAssertEqual(decoded.deadlineMissMicroseconds, 124)

        clock.nanoseconds = UInt64.max
        try adapter.handle(videoMessage(
            frameID: 2,
            frameSize: 2,
            fragmentOffset: 0,
            fragmentIndex: 0,
            fragmentCount: 1,
            codecID: UInt8(try XCTUnwrap(codec[1]?.unsignedValue)),
            matrix: UInt8(try XCTUnwrap(codec[7]?.unsignedValue)),
            bitDepth: UInt8(try XCTUnwrap(codec[3]?.unsignedValue)),
            generation: 1,
            bytes: Data([5, 6]),
            receivedAtNanoseconds: 1_100_000_000
        ))
        decoder.emit(.decoded(frameNumber: 2))
        XCTAssertEqual(
            feedback.values.last?.deadlineMissMicroseconds,
            ProtocolV3MediaPipelineAdapter.maximumDeadlineMissMicroseconds
        )

        clock.nanoseconds = 1_225_001_000
        try adapter.handle(videoMessage(
            frameID: 3,
            frameSize: 2,
            fragmentOffset: 0,
            fragmentIndex: 0,
            fragmentCount: 1,
            codecID: UInt8(try XCTUnwrap(codec[1]?.unsignedValue)),
            matrix: UInt8(try XCTUnwrap(codec[7]?.unsignedValue)),
            bitDepth: UInt8(try XCTUnwrap(codec[3]?.unsignedValue)),
            generation: 1,
            bytes: Data([7, 8]),
            receivedAtNanoseconds: 1_200_000_000
        ))
        decoder.emit(.failed(frameNumber: 3))
        XCTAssertEqual(feedback.values.last?.action, 3)
        XCTAssertEqual(feedback.values.last?.deadlineMissMicroseconds, 1)
    }

    func testMediaAdapterRejectsUnboundedPresentationAge() throws {
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
            applicationID: 14,
            resume: false,
            preferences: .default,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        var selection = successfulStartResponse(offer)
        var presentation = try XCTUnwrap(selection[18]?.mapValue)
        presentation[5] = .unsigned(1_000_001)
        selection[18] = .map(presentation)

        XCTAssertThrowsError(try ProtocolV3MediaPipelineAdapter(
            pipeline: StreamingMediaPipeline(
                videoDecoder: RationalRefreshVideoDecoder(),
                audioDecoder: RationalRefreshAudioDecoder(),
                availableVideoFormats: capabilities.supportedVideoFormatMask
            ),
            mode: .quality,
            startResponseFields: selection
        ))
    }

    func testSessionCoordinatorPublishesNewestValidatedRTTTelemetry() throws {
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
            applicationID: 15,
            resume: false,
            preferences: .default,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        let selection = successfulStartResponse(offer)
        let adapter = try ProtocolV3MediaPipelineAdapter(
            pipeline: StreamingMediaPipeline(
                videoDecoder: RationalRefreshVideoDecoder(),
                audioDecoder: RationalRefreshAudioDecoder(),
                availableVideoFormats: capabilities.supportedVideoFormatMask
            ),
            mode: .quality,
            startResponseFields: selection
        )
        let coordinator = ProtocolV3SessionMediaCoordinator(
            control: ProtocolV3MediaControlStub(),
            media: adapter
        )
        let sessionID = Data(33...48)
        coordinator.handle(.startAccepted(sessionID: sessionID, fields: selection))
        coordinator.handle(.transport(.inbound(rttMessage(
            generation: 2,
            smoothed: 4_000,
            minimum: 3_000,
            variation: 1_000
        ))))
        coordinator.handle(.transport(.inbound(rttMessage(
            generation: 1,
            smoothed: 9_000,
            minimum: 8_000,
            variation: 7_000
        ))))

        let transport = coordinator.statistics().transport
        XCTAssertEqual(transport.smoothedRTTMicroseconds, 4_000)
        XCTAssertEqual(transport.minimumRTTMicroseconds, 3_000)
        XCTAssertEqual(transport.rttVariationMicroseconds, 1_000)
    }

    func testHDRTransferPreferenceControlsTheExactStartOffer() throws {
        var preferences = StreamingPreferences.default
        preferences.optimizationMode = .quality
        preferences.enableHDR = true
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2,
            supportsHardwareHEVCMain10: true,
            supportsHardwareAV1Main10: true
        )

        let automatic = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 12,
            resume: false,
            preferences: preferences,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        XCTAssertEqual(
            automatic.fields[9]?.arrayValue?.prefix(2).compactMap {
                $0.mapValue?[6]?.unsignedValue
            },
            [16, 18],
            "Auto must preserve the existing PQ-first preference."
        )
        XCTAssertEqual(
            automatic.fields[14]?.arrayValue?.compactMap {
                $0.mapValue?[1]?.unsignedValue
            },
            [2, 3]
        )

        preferences.hdrTransferPreference = .pq
        let pq = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 12,
            resume: false,
            preferences: preferences,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        XCTAssertTrue(
            pq.fields[9]?.arrayValue?.allSatisfy {
                $0.mapValue?[6]?.unsignedValue == 16
            } == true
        )
        XCTAssertEqual(
            pq.fields[14]?.arrayValue?.compactMap {
                $0.mapValue?[1]?.unsignedValue
            },
            [2]
        )
        let pqCapability = try XCTUnwrap(pq.fields[14]?.arrayValue?.first?.mapValue)
        XCTAssertEqual(pqCapability[6]?.mapValue?[1]?.booleanValue, true)

        preferences.enableHDR = false
        preferences.hdrTransferPreference = .hlg
        let sdr = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 12,
            resume: false,
            preferences: preferences,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        XCTAssertTrue(
            sdr.fields[9]?.arrayValue?.allSatisfy {
                $0.mapValue?[6]?.unsignedValue == 1
            } == true
        )
        XCTAssertEqual(sdr.fields[14], .array([]))
    }

    func testHLGStartAndVideoConfigPreserveTransferWithoutStaticMetadata() throws {
        var preferences = StreamingPreferences.default
        preferences.optimizationMode = .quality
        preferences.enableHDR = true
        preferences.hdrTransferPreference = .hlg
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2,
            supportsHardwareHEVCMain10: true,
            supportsHardwareAV1Main10: true
        )
        let offer = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 12,
            resume: false,
            preferences: preferences,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        XCTAssertTrue(
            offer.fields[9]?.arrayValue?.allSatisfy {
                $0.mapValue?[6]?.unsignedValue == 18
            } == true
        )
        XCTAssertEqual(
            offer.fields[14]?.arrayValue?.compactMap {
                $0.mapValue?[1]?.unsignedValue
            },
            [3]
        )
        let hlgCodec = try XCTUnwrap(
            offer.fields[9]?.arrayValue?.first(where: { $0.mapValue?[6]?.unsignedValue == 18 })
        )
        let hlgCapability = try XCTUnwrap(
            offer.fields[14]?.arrayValue?.first(where: { $0.mapValue?[1]?.unsignedValue == 3 })?.mapValue
        )
        XCTAssertEqual(hlgCapability[6]?.mapValue?[1]?.booleanValue, false)
        let hlgSelection: ProtocolV3CBORValue = .map([
            1: .unsigned(3),
            2: hlgCapability[2]!,
            3: hlgCapability[3]!,
            4: hlgCapability[4]!,
            5: hlgCapability[5]!,
            6: .null,
            7: .array([]),
        ])
        var response = successfulStartResponse(offer)
        response[5] = hlgCodec
        response[23] = hlgSelection

        XCTAssertNoThrow(try ProtocolV3StartRequestMapper.validateSelectedTuples(
            responseFields: response,
            offered: offer
        ))

        let hostileStaticMetadata: ProtocolV3CBORValue = .map([
            1: .array(Array(repeating: .unsigned(1), count: 6)),
            2: .array(Array(repeating: .unsigned(1), count: 2)),
            3: .unsigned(10_000),
            4: .unsigned(1),
            5: .unsigned(100),
            6: .unsigned(50),
        ])
        var hostileHLGSelection = try XCTUnwrap(hlgSelection.mapValue)
        hostileHLGSelection[6] = hostileStaticMetadata
        var hostileStartResponse = response
        hostileStartResponse[23] = .map(hostileHLGSelection)
        XCTAssertThrowsError(try ProtocolV3StartRequestMapper.validateSelectedTuples(
            responseFields: hostileStartResponse,
            offered: offer
        ))

        var unofferedPQResponse = response
        var unofferedPQCodec = try XCTUnwrap(hlgCodec.mapValue)
        unofferedPQCodec[6] = .unsigned(16)
        unofferedPQResponse[5] = .map(unofferedPQCodec)
        XCTAssertThrowsError(try ProtocolV3StartRequestMapper.validateSelectedTuples(
            responseFields: unofferedPQResponse,
            offered: offer
        ))

        let videoDecoder = RationalRefreshVideoDecoder()
        let adapter = try ProtocolV3MediaPipelineAdapter(
            pipeline: StreamingMediaPipeline(
                videoDecoder: videoDecoder,
                audioDecoder: RationalRefreshAudioDecoder(),
                availableVideoFormats: capabilities.supportedVideoFormatMask
            ),
            mode: .quality,
            startResponseFields: response
        )
        var hostileVideoConfiguration = videoConfigurationFields(response)
        hostileVideoConfiguration[5] = .map(hostileHLGSelection)
        XCTAssertThrowsError(try adapter.configureVideo(fields: hostileVideoConfiguration))
        XCTAssertTrue(videoDecoder.configuredFormats.isEmpty)
        XCTAssertNil(videoDecoder.hdrMode)

        XCTAssertEqual(try adapter.configureVideo(fields: videoConfigurationFields(response)), 2)
        let hdrMode = try XCTUnwrap(videoDecoder.hdrMode)
        XCTAssertTrue(hdrMode.enabled)
        let metadata = try XCTUnwrap(hdrMode.metadata)
        XCTAssertEqual(metadata.transfer, .hlg)
        XCTAssertEqual(metadata.maximumDisplayLuminanceNits, 0)
        XCTAssertEqual(metadata.maximumContentLightLevelNits, 0)
        XCTAssertEqual(metadata.maximumFrameAverageLightLevelNits, 0)
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

    private func videoMessage(
        frameID: UInt64,
        frameSize: Int,
        fragmentOffset: Int,
        fragmentIndex: Int,
        fragmentCount: Int,
        codecID: UInt8,
        matrix: UInt8,
        bitDepth: UInt8,
        generation: UInt32,
        bytes: Data,
        receivedAtNanoseconds: UInt64
    ) -> QUICInboundMessage {
        var payload = Data(capacity: 64 + bytes.count)
        appendBigEndian(UInt64(10), to: &payload)
        appendBigEndian(UInt32(15), to: &payload)
        appendBigEndian(UInt32(20), to: &payload)
        appendBigEndian(UInt64(30), to: &payload)
        appendBigEndian(UInt64(40), to: &payload)
        appendBigEndian(UInt32(frameSize), to: &payload)
        appendBigEndian(UInt32(fragmentOffset), to: &payload)
        appendBigEndian(UInt16(fragmentIndex), to: &payload)
        appendBigEndian(UInt16(fragmentCount), to: &payload)
        payload.append(Data(repeating: 0, count: 9))
        payload.append(codecID)
        payload.append(matrix)
        payload.append(bitDepth)
        appendBigEndian(generation, to: &payload)
        appendBigEndian(UInt32(0), to: &payload)
        payload.append(bytes)
        return QUICInboundMessage(
            lane: .video,
            payload: payload,
            receivedAtNanoseconds: receivedAtNanoseconds,
            semanticSequence: UInt64(fragmentIndex + 1),
            objectID: frameID,
            controlFlags: nil,
            controlType: nil,
            requestID: nil,
            datagramChannel: 2,
            datagramKind: 1,
            datagramFlags: 0
        )
    }

    private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private func rttMessage(
        generation: UInt64,
        smoothed: UInt32,
        minimum: UInt32,
        variation: UInt32
    ) -> QUICInboundMessage {
        var payload = Data()
        appendBigEndian(generation, to: &payload)
        appendBigEndian(smoothed, to: &payload)
        appendBigEndian(minimum, to: &payload)
        appendBigEndian(variation, to: &payload)
        appendBigEndian(UInt32(0), to: &payload)
        return QUICInboundMessage(
            lane: .hostEvents,
            payload: payload,
            receivedAtNanoseconds: 1,
            semanticSequence: generation,
            objectID: generation,
            controlFlags: nil,
            controlType: nil,
            requestID: nil,
            datagramChannel: 5,
            datagramKind: 1,
            datagramFlags: 0
        )
    }
}

private final class RationalRefreshVideoDecoder: UmbraStreaming.VideoDecoding,
    UmbraStreaming.VideoCodecInitializationPreparing,
    UmbraStreaming.VideoDecodeOutcomeReporting,
    UmbraStreaming.HDRMetadataReceiving,
    @unchecked Sendable {
    private let lock = NSLock()
    private var formats: [UmbraStreaming.VideoStreamFormat] = []
    private var storedHDRMode: (enabled: Bool, metadata: UmbraStreaming.StreamingHDRMetadata?)?
    private var decodeOutcomeHandler: (@Sendable (UmbraStreaming.VideoDecodeOutcome) -> Void)?

    var configuredFormats: [UmbraStreaming.VideoStreamFormat] { lock.withLock { formats } }
    var hdrMode: (enabled: Bool, metadata: UmbraStreaming.StreamingHDRMetadata?)? {
        lock.withLock { storedHDRMode }
    }

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
    ) {
        lock.withLock { decodeOutcomeHandler = handler }
    }

    func emit(_ outcome: UmbraStreaming.VideoDecodeOutcome) {
        lock.withLock { decodeOutcomeHandler }?(outcome)
    }

    func setHDRMode(enabled: Bool, metadata: UmbraStreaming.StreamingHDRMetadata?) {
        lock.withLock { storedHDRMode = (enabled, metadata) }
    }
}

private final class ProtocolV3DeadlineTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedNanoseconds: UInt64

    init(nanoseconds: UInt64) {
        storedNanoseconds = nanoseconds
    }

    var nanoseconds: UInt64 {
        get { lock.withLock { storedNanoseconds } }
        set { lock.withLock { storedNanoseconds = newValue } }
    }
}

private final class ProtocolV3FeedbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [ProtocolV3VideoFeedback] = []

    var values: [ProtocolV3VideoFeedback] { lock.withLock { storedValues } }

    func append(_ feedback: ProtocolV3VideoFeedback) {
        lock.withLock { storedValues.append(feedback) }
    }
}

private final class ProtocolV3MediaControlStub: ProtocolV3SessionMediaControlling, @unchecked Sendable {
    func sendControlRequest(
        type: UInt16,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws -> UInt64 {
        1
    }

    func sendControlResponse(
        type: UInt16,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue],
        isError: Bool
    ) throws {}

    func sendDatagram(
        lane: QUICSemanticLane,
        sessionID: Data,
        channel: UInt8,
        kind: UInt8,
        flags: UInt8,
        objectID: UInt64,
        payload: Data,
        deadlineNanoseconds: UInt64?,
        supersessionKey: UInt64?
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

private extension Data {
    init?(gate1Hexadecimal text: String) {
        guard text.count.isMultiple(of: 2) else { return nil }
        self.init()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }
}
