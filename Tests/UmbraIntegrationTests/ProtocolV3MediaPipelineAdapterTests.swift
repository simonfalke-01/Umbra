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
        XCTAssertEqual(newest.requestedKeyFrameID, 1)
        XCTAssertTrue(newest.readyFrames.isEmpty)
        XCTAssertTrue(reassembler.requiresKeyFrame)
        XCTAssertTrue(reassembler.pendingFrameIDs.isEmpty)

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

        let dependent = try reassembler.accept(
            fragment(
                frameID: 3,
                frameSize: 2,
                bytes: Data([7, 8]),
                receivedAtNanoseconds: 4
            ),
            framesPerSecond: 120
        )
        XCTAssertTrue(dependent.readyFrames.isEmpty)
        XCTAssertTrue(reassembler.pendingFrameIDs.isEmpty)

        let recovered = try reassembler.accept(
            fragment(
                frameID: 4,
                frameSize: 2,
                flags: 0x01,
                bytes: Data([9, 10]),
                receivedAtNanoseconds: 5
            ),
            framesPerSecond: 120
        )
        XCTAssertEqual(recovered.readyFrames.map(\.frameID), [4])
        XCTAssertFalse(reassembler.requiresKeyFrame)
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

    func testHostAdjustedStartScalarsAreReadmittedAgainstCanonicalBounds() throws {
        let offer = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 28,
            resume: false,
            preferences: .default,
            capabilities: fullyCapableClient,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )

        for dimensions: (UInt64, UInt64) in [(1_920, 1_080), (320, 200)] {
            let response = adjustedStartResponse(offer, dimensions: dimensions)
            XCTAssertNoThrow(try ProtocolV3StartRequestMapper.validateSelectedTuples(
                responseFields: response,
                offered: offer
            ))
        }
        for refresh: (UInt64, UInt64) in [(120, 1), (60_000, 1_001)] {
            let response = adjustedStartResponse(offer, refresh: refresh)
            XCTAssertNoThrow(try ProtocolV3StartRequestMapper.validateSelectedTuples(
                responseFields: response,
                offered: offer
            ))
        }

        let invalidDimensions: [(UInt64, UInt64)] = [
            (318, 1_080),
            (7_682, 4_320),
            (1_921, 1_080),
        ]
        for dimensions in invalidDimensions {
            XCTAssertThrowsError(try ProtocolV3StartRequestMapper.validateSelectedTuples(
                responseFields: adjustedStartResponse(offer, dimensions: dimensions),
                offered: offer
            ), "\(dimensions)")
        }

        let oversizedComponent = UInt64(UInt32.max) + 1
        let invalidRefresh: [(UInt64, UInt64)] = [
            (0, 1),
            (9, 1),
            (481, 1),
            (120, 2),
            (oversizedComponent, 1),
            (60_000, oversizedComponent),
        ]
        for refresh in invalidRefresh {
            XCTAssertThrowsError(try ProtocolV3StartRequestMapper.validateSelectedTuples(
                responseFields: adjustedStartResponse(offer, refresh: refresh),
                offered: offer
            ), "\(refresh)")
        }

        var h264Preferences = StreamingPreferences.default
        h264Preferences.videoCodecPreference = .h264
        let h264Offer = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 30,
            resume: false,
            preferences: h264Preferences,
            capabilities: fullyCapableClient,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        XCTAssertThrowsError(try ProtocolV3StartRequestMapper.validateSelectedTuples(
            responseFields: adjustedStartResponse(h264Offer, dimensions: (4_098, 4_096)),
            offered: h264Offer
        ))
    }

    func testStrictSelectionUsesNormalizedOfferedRefreshInsteadOfRawPreferenceFraction() throws {
        var preferences = StreamingPreferences.default
        preferences.setFrameRate(numerator: 120, denominator: 2)
        preferences.enableYUV444 = true
        let offer = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 29,
            resume: false,
            preferences: preferences,
            capabilities: fullyCapableClient,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        XCTAssertEqual(offer.fields[6]?.unsignedValue, 60)
        XCTAssertEqual(offer.fields[7]?.unsignedValue, 1)
        XCTAssertEqual(offer.fields[17]?.mapValue?[6]?.booleanValue, false)

        let selected = try ProtocolV3StartRequestMapper.selectedMode(
            responseFields: successfulStartResponse(offer),
            offered: offer
        )
        XCTAssertEqual(selected.refreshNumerator, 60)
        XCTAssertEqual(selected.refreshDenominator, 1)
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
            startResponseFields: selection,
            authenticatedVDDCaptureState: .unavailable
        )
        let fields = videoConfigurationFields(selection)
        XCTAssertNil(adapter.statistics().selectedVideo)

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
        let telemetry = try XCTUnwrap(adapter.statistics().selectedVideo)
        XCTAssertEqual(telemetry.width, 1_920)
        XCTAssertEqual(telemetry.height, 1_080)
        XCTAssertEqual(telemetry.refreshNumerator, 60_000)
        XCTAssertEqual(telemetry.refreshDenominator, 1_001)
        XCTAssertEqual(telemetry.videoGeneration, 1)
        XCTAssertEqual(
            telemetry.format,
            try ProtocolV3StartRequestMapper.selectedVideoFormat(
                responseFields: selection,
                offered: offer
            )
        )
        XCTAssertFalse(telemetry.isHDR)
        XCTAssertEqual(telemetry.vddCaptureState, .unavailable)
        XCTAssertTrue(telemetry.vddCaptureState?.isDegraded == true)
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

    func testInputToDecodeProxyUsesTheFrameCausalWatermark() throws {
        let capabilities = fullyCapableClient
        let offer = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 130,
            resume: false,
            preferences: .default,
            capabilities: capabilities,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        let selection = successfulStartResponse(offer)
        let decoder = RationalRefreshVideoDecoder()
        let clock = ProtocolV3DeadlineTestClock(nanoseconds: 1_025_000_000)
        let tracker = ProtocolV3InputLatencyTracker()
        tracker.record(stateSequence: 30, sampleTimeMicroseconds: 900_000, newestEdgeID: 40)
        let adapter = try ProtocolV3MediaPipelineAdapter(
            pipeline: StreamingMediaPipeline(
                videoDecoder: decoder,
                audioDecoder: RationalRefreshAudioDecoder(),
                availableVideoFormats: capabilities.supportedVideoFormatMask
            ),
            mode: .latency,
            startResponseFields: selection,
            inputLatencyTracker: tracker,
            nowNanoseconds: { clock.nanoseconds }
        )
        XCTAssertEqual(try adapter.configureVideo(fields: videoConfigurationFields(selection)), 1)
        let codec = try XCTUnwrap(selection[5]?.mapValue)
        try adapter.handle(videoMessage(
            frameID: 1,
            frameSize: 2,
            fragmentOffset: 0,
            fragmentIndex: 0,
            fragmentCount: 1,
            codecID: UInt8(try XCTUnwrap(codec[1]?.unsignedValue)),
            matrix: UInt8(try XCTUnwrap(codec[7]?.unsignedValue)),
            bitDepth: UInt8(try XCTUnwrap(codec[3]?.unsignedValue)),
            generation: 1,
            bytes: Data([1, 2]),
            receivedAtNanoseconds: 1_000_000_000
        ))
        decoder.emit(.decoded(frameNumber: 1))

        let statistics = adapter.statistics()
        XCTAssertEqual(statistics.latestAppliedInputStateSequence, 30)
        XCTAssertEqual(statistics.latestAppliedInputEdgeID, 40)
        XCTAssertEqual(statistics.latestInputCausalFrameID, 1)
        XCTAssertEqual(
            statistics.inputToDecodeProxy?.p50Milliseconds ?? -1,
            125,
            accuracy: 0.0001
        )
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

    func testOptionalMicrophoneMayDegradeToNullButRequiredMicrophoneFailsClosed() throws {
        var preferences = StreamingPreferences.default
        preferences.clientMicrophoneEnabled = true
        let optional = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 11,
            resume: false,
            preferences: preferences,
            capabilities: fullyCapableClient,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        var selection = successfulStartResponse(optional)
        selection[13] = .null
        XCTAssertNoThrow(try ProtocolV3StartRequestMapper.validateSelectedTuples(
            responseFields: selection,
            offered: optional
        ))

        preferences.clientMicrophoneRequired = true
        let required = try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 11,
            resume: false,
            preferences: preferences,
            capabilities: fullyCapableClient,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
        selection = successfulStartResponse(required)
        selection[13] = .null
        XCTAssertThrowsError(try ProtocolV3StartRequestMapper.validateSelectedTuples(
            responseFields: selection,
            offered: required
        ))
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

    private func adjustedStartResponse(
        _ offer: ProtocolV3StartOffer,
        dimensions: (UInt64, UInt64)? = nil,
        refresh: (UInt64, UInt64)? = nil
    ) -> [UInt64: ProtocolV3CBORValue] {
        var response = successfulStartResponse(offer)
        var adjustments: [ProtocolV3CBORValue] = []
        if let dimensions {
            let requested: ProtocolV3CBORValue = .array([offer.fields[4]!, offer.fields[5]!])
            let selected: ProtocolV3CBORValue = .array([
                .unsigned(dimensions.0),
                .unsigned(dimensions.1),
            ])
            response[6] = .unsigned(dimensions.0)
            response[7] = .unsigned(dimensions.1)
            adjustments.append(.map([
                1: .unsigned(1),
                2: requested,
                3: selected,
                4: .unsigned(1),
            ]))
        }
        if let refresh {
            let requested: ProtocolV3CBORValue = .array([offer.fields[6]!, offer.fields[7]!])
            let selected: ProtocolV3CBORValue = .array([
                .unsigned(refresh.0),
                .unsigned(refresh.1),
            ])
            response[8] = .unsigned(refresh.0)
            response[9] = .unsigned(refresh.1)
            adjustments.append(.map([
                1: .unsigned(2),
                2: requested,
                3: selected,
                4: .unsigned(1),
            ]))
        }
        response[19] = .array(adjustments)
        return response
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

extension ProtocolV3MediaPipelineAdapterTests {
    func testEveryCanonicalStartModeDecisionMatchesUmbraAdmission() throws {
        let fixture = try loadFixture()

        XCTAssertEqual(fixture.schema, "umbra-lumen-start-mode/1")
        XCTAssertEqual(fixture.vectors.count, 27)
        XCTAssertEqual(Set(fixture.vectors.map(\.id)).count, fixture.vectors.count)
        assertContractMatchesUmbra(fixture.contract)

        for vector in fixture.vectors {
            XCTAssertEqual(
                decision(for: vector, contract: fixture.contract),
                vector.expected,
                vector.id
            )
            if vector.expected == "none" {
                let offer = try makeOffer(for: vector)
                assertAcceptedOffer(offer, matches: vector)
            } else {
                XCTAssertFalse(
                    canEmitExactRejectedRequest(vector),
                    "Umbra emitted rejected canonical request \(vector.id)"
                )
            }
        }
    }

    private func loadFixture() throws -> StartModeFixture {
        guard let lumenSourceRoot = ProcessInfo.processInfo.environment["LUMEN_SOURCE_ROOT"] else {
            throw XCTSkip("Set LUMEN_SOURCE_ROOT to run the cross-repository Gate 1 vector check.")
        }
        let url = URL(fileURLWithPath: lumenSourceRoot, isDirectory: true)
            .appendingPathComponent("docs/protocols/vectors/start_mode_vectors.json")
        return try JSONDecoder().decode(StartModeFixture.self, from: Data(contentsOf: url))
    }

    private func assertContractMatchesUmbra(_ contract: StartModeContract) {
        XCTAssertEqual(contract.startKeys, Array(1...18).map(UInt64.init))
        XCTAssertEqual(contract.hostAudioKey, 18)
        XCTAssertEqual(contract.hostAudioType, "bool")
        XCTAssertEqual(contract.minimumWidth, UInt64(StreamingPreferences.minimumStreamWidth))
        XCTAssertEqual(contract.maximumWidth, UInt64(StreamingPreferences.maximumStreamWidth))
        XCTAssertEqual(contract.minimumHeight, UInt64(StreamingPreferences.minimumStreamHeight))
        XCTAssertEqual(contract.maximumHeight, UInt64(StreamingPreferences.maximumStreamHeight))
        XCTAssertEqual(contract.minimumRefreshHz, UInt64(StreamingPreferences.minimumFrameRate))
        XCTAssertEqual(contract.maximumRefreshHz, UInt64(StreamingPreferences.maximumFrameRate))
        XCTAssertEqual(contract.maximumRationalComponent, UInt64(UInt32.max))
        XCTAssertEqual(contract.h264MaximumDimension, 4_096)
        XCTAssertEqual(contract.codec, ["h264": 1, "hevc": 2, "av1": 3])
        XCTAssertEqual(contract.chroma, ["yuv420": 1, "yuv444": 2])
        XCTAssertEqual(contract.dynamicRange, ["sdr": 1, "pq": 2, "hlg": 3])
        XCTAssertEqual(
            contract.fidelity,
            ["lossy": 1, "visually_lossless": 2, "codec_lossless": 3]
        )
        XCTAssertEqual(contract.codecLosslessProofFlag, 2)
    }

    private func decision(for vector: StartModeVector, contract: StartModeContract) -> String {
        guard (contract.minimumWidth...contract.maximumWidth).contains(vector.width),
            (contract.minimumHeight...contract.maximumHeight).contains(vector.height),
            vector.width.isMultiple(of: 2),
            vector.height.isMultiple(of: 2)
        else {
            return "dimensions"
        }
        guard (1...contract.maximumRationalComponent).contains(vector.refreshNumerator),
            (1...contract.maximumRationalComponent).contains(vector.refreshDenominator)
        else {
            return "refresh_component"
        }
        guard greatestCommonDivisor(vector.refreshNumerator, vector.refreshDenominator) == 1 else {
            return "refresh_unreduced"
        }
        guard vector.refreshNumerator >= contract.minimumRefreshHz * vector.refreshDenominator,
            vector.refreshNumerator <= contract.maximumRefreshHz * vector.refreshDenominator
        else {
            return "refresh_range"
        }
        guard (1_000...500_000).contains(vector.bitrateKbps) else {
            return "bitrate"
        }
        guard contract.codec.values.contains(vector.codec) else {
            return "codec"
        }
        let validColorMode =
            contract.chroma.values.contains(vector.chroma)
            && ((vector.dynamicRange == contract.dynamicRange["sdr"] && vector.bitDepth == 8)
                || ([contract.dynamicRange["pq"], contract.dynamicRange["hlg"]]
                    .compactMap { $0 }
                    .contains(vector.dynamicRange) && vector.bitDepth == 10))
        guard validColorMode else {
            return "color_mode"
        }
        if vector.codec == contract.codec["h264"],
            vector.width > contract.h264MaximumDimension
                || vector.height > contract.h264MaximumDimension
                || vector.dynamicRange != contract.dynamicRange["sdr"]
                || vector.bitDepth != 8
        {
            return "h264_limit"
        }
        guard (1...3).contains(vector.fidelity),
            vector.fidelity != contract.fidelity["codec_lossless"]
                || (vector.chroma == contract.chroma["yuv444"]
                    && vector.codecFlags & contract.codecLosslessProofFlag != 0)
        else {
            return "fidelity"
        }
        let compatiblePresentation =
            (vector.profile == 1 && [1, 2].contains(vector.presentation.mode))
            || (vector.profile == 2 && vector.presentation.mode == 3)
        guard compatiblePresentation, (1...2).contains(vector.presentation.queueDepth) else {
            return "presentation"
        }
        guard ["none", "mono"].contains(vector.microphone) else {
            return "microphone"
        }
        guard vector.hostAudio != nil else {
            return "host_audio"
        }
        return "none"
    }

    private func makeOffer(for vector: StartModeVector) throws -> ProtocolV3StartOffer {
        guard let codecPreference = codecPreference(vector.codec),
            let width = Int(exactly: vector.width),
            let height = Int(exactly: vector.height),
            let refreshNumerator = Int(exactly: vector.refreshNumerator),
            let refreshDenominator = Int(exactly: vector.refreshDenominator),
            let bitrateKbps = Int(exactly: vector.bitrateKbps)
        else {
            throw StartModeVectorError.unrepresentable
        }

        var preferences = StreamingPreferences.default
        preferences.width = width
        preferences.height = height
        preferences.setFrameRate(numerator: refreshNumerator, denominator: refreshDenominator)
        preferences.bitrateKbps = bitrateKbps
        preferences.unlockBitrate = bitrateKbps > 150_000
        preferences.autoAdjustBitrate = false
        preferences.optimizationMode = vector.profile == 1 ? .latency : .quality
        preferences.videoCodecPreference = codecPreference
        preferences.enableYUV444 = vector.chroma == 2
        preferences.enableHDR = vector.dynamicRange != 1
        preferences.hdrTransferPreference = vector.dynamicRange == 3 ? .hlg : .pq
        preferences.fidelityPreference =
            vector.fidelity == 3
            ? .codecLosslessRequired
            : .visuallyLossless
        preferences.enableVSync = vector.presentation.mode != 1
        preferences.clientMicrophoneEnabled = vector.microphone == "mono"
        preferences.playAudioOnHost = vector.hostAudio ?? false

        return try ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 1,
            resume: false,
            preferences: preferences,
            capabilities: fullyCapableClient,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        )
    }

    private func assertAcceptedOffer(_ offer: ProtocolV3StartOffer, matches vector: StartModeVector) {
        XCTAssertEqual(Set(offer.fields.keys), Set((1...18).map(UInt64.init)), vector.id)
        XCTAssertEqual(offer.fields[3]?.unsignedValue, vector.profile, vector.id)
        XCTAssertEqual(offer.fields[4]?.unsignedValue, vector.width, vector.id)
        XCTAssertEqual(offer.fields[5]?.unsignedValue, vector.height, vector.id)
        XCTAssertEqual(offer.fields[6]?.unsignedValue, vector.refreshNumerator, vector.id)
        XCTAssertEqual(offer.fields[7]?.unsignedValue, vector.refreshDenominator, vector.id)
        XCTAssertEqual(offer.fields[8]?.unsignedValue, vector.bitrateKbps, vector.id)
        XCTAssertEqual(offer.fields[18]?.booleanValue, vector.hostAudio, vector.id)
        XCTAssertTrue(microphoneMatches(offer.fields[11], vector.microphone), vector.id)
        XCTAssertTrue(presentationMatches(offer.fields[15], vector.presentation), vector.id)

        let tuples = offer.fields[9]?.arrayValue?.compactMap(\.mapValue) ?? []
        let tuple = tuples.first { codecTuple($0, matches: vector, exactFidelity: vector.fidelity == 3) }
        XCTAssertNotNil(tuple, vector.id)
        XCTAssertEqual(tuple.map { Set($0.keys) }, Set((1...10).map(UInt64.init)), vector.id)

        let hdr = offer.fields[14]?.arrayValue ?? []
        if vector.dynamicRange == 1 {
            XCTAssertTrue(hdr.isEmpty, vector.id)
        } else {
            XCTAssertTrue(
                hdr.contains { value in
                    value.mapValue?[1]?.unsignedValue == vector.dynamicRange
                }, vector.id)
        }
    }

    private func canEmitExactRejectedRequest(_ vector: StartModeVector) -> Bool {
        guard let offer = try? makeOffer(for: vector),
            offer.fields[3]?.unsignedValue == vector.profile,
            offer.fields[4]?.unsignedValue == vector.width,
            offer.fields[5]?.unsignedValue == vector.height,
            offer.fields[6]?.unsignedValue == vector.refreshNumerator,
            offer.fields[7]?.unsignedValue == vector.refreshDenominator,
            offer.fields[8]?.unsignedValue == vector.bitrateKbps,
            let hostAudio = vector.hostAudio,
            offer.fields[18]?.booleanValue == hostAudio,
            microphoneMatches(offer.fields[11], vector.microphone),
            presentationMatches(offer.fields[15], vector.presentation)
        else {
            return false
        }
        return offer.fields[9]?.arrayValue?.compactMap(\.mapValue).contains {
            codecTuple($0, matches: vector, exactFidelity: true)
        } == true
    }

    private func codecTuple(
        _ tuple: [UInt64: ProtocolV3CBORValue],
        matches vector: StartModeVector,
        exactFidelity: Bool
    ) -> Bool {
        let transfer: UInt64 =
            switch vector.dynamicRange {
            case 2: 16
            case 3: 18
            default: 1
            }
        return Set(tuple.keys) == Set((1...10).map(UInt64.init))
            && tuple[1]?.unsignedValue == vector.codec
            && tuple[3]?.unsignedValue == vector.bitDepth
            && tuple[4]?.unsignedValue == vector.chroma
            && tuple[6]?.unsignedValue == transfer
            && tuple[9]?.unsignedValue == vector.codecFlags
            && (!exactFidelity || tuple[10]?.unsignedValue == vector.fidelity)
    }

    private func microphoneMatches(_ value: ProtocolV3CBORValue?, _ microphone: String) -> Bool {
        switch microphone {
        case "none":
            value == .null
        case "mono":
            value?.mapValue.map { Set($0.keys) == Set((1...9).map(UInt64.init)) } == true
        default:
            false
        }
    }

    private func presentationMatches(
        _ value: ProtocolV3CBORValue?,
        _ presentation: StartModePresentation
    ) -> Bool {
        value?.arrayValue?.contains { candidate in
            guard let tuple = candidate.mapValue else { return false }
            return Set(tuple.keys) == Set((1...5).map(UInt64.init))
                && tuple[1]?.unsignedValue == presentation.mode
                && tuple[2]?.unsignedValue == presentation.queueDepth
        } == true
    }

    private func codecPreference(_ codec: UInt64) -> VideoCodecPreference? {
        switch codec {
        case 1: .h264
        case 2: .hevc
        case 3: .av1
        default: nil
        }
    }

    private func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var lhs = lhs
        var rhs = rhs
        while rhs != 0 {
            (lhs, rhs) = (rhs, lhs % rhs)
        }
        return lhs
    }

    private var fullyCapableClient: AppleStreamingCapabilities {
        AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2,
            supportsHardwareHEVCMain10: true,
            supportsHardwareAV1Main10: true,
            supportedHardwareYUV444FormatMask: VideoCodecProfile.yuv444Mask
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

private enum StartModeVectorError: Error {
    case unrepresentable
}

private struct StartModeFixture: Decodable {
    let schema: String
    let contract: StartModeContract
    let vectors: [StartModeVector]
}

private struct StartModeContract: Decodable {
    let startKeys: [UInt64]
    let hostAudioKey: UInt64
    let hostAudioType: String
    let minimumWidth: UInt64
    let maximumWidth: UInt64
    let minimumHeight: UInt64
    let maximumHeight: UInt64
    let minimumRefreshHz: UInt64
    let maximumRefreshHz: UInt64
    let maximumRationalComponent: UInt64
    let h264MaximumDimension: UInt64
    let codec: [String: UInt64]
    let chroma: [String: UInt64]
    let dynamicRange: [String: UInt64]
    let fidelity: [String: UInt64]
    let codecLosslessProofFlag: UInt64

    private enum CodingKeys: String, CodingKey {
        case startKeys = "start_keys"
        case hostAudioKey = "host_audio_key"
        case hostAudioType = "host_audio_type"
        case minimumWidth = "minimum_width"
        case maximumWidth = "maximum_width"
        case minimumHeight = "minimum_height"
        case maximumHeight = "maximum_height"
        case minimumRefreshHz = "minimum_refresh_hz"
        case maximumRefreshHz = "maximum_refresh_hz"
        case maximumRationalComponent = "maximum_rational_component"
        case h264MaximumDimension = "h264_maximum_dimension"
        case codec
        case chroma
        case dynamicRange = "dynamic_range"
        case fidelity
        case codecLosslessProofFlag = "codec_lossless_proof_flag"
    }
}

private struct StartModeVector: Decodable {
    let id: String
    let width: UInt64
    let height: UInt64
    let refreshNumerator: UInt64
    let refreshDenominator: UInt64
    let codec: UInt64
    let bitDepth: UInt64
    let chroma: UInt64
    let dynamicRange: UInt64
    let codecFlags: UInt64
    let fidelity: UInt64
    let bitrateKbps: UInt64
    let profile: UInt64
    let presentation: StartModePresentation
    let microphone: String
    let hostAudio: Bool?
    let expected: String

    private enum CodingKeys: String, CodingKey {
        case id
        case width
        case height
        case refreshNumerator = "refresh_numerator"
        case refreshDenominator = "refresh_denominator"
        case codec
        case bitDepth = "bit_depth"
        case chroma
        case dynamicRange = "dynamic_range"
        case codecFlags = "codec_flags"
        case fidelity
        case bitrateKbps = "bitrate_kbps"
        case profile
        case presentation
        case microphone
        case hostAudio = "host_audio"
        case expected
    }
}

private struct StartModePresentation: Decodable {
    let mode: UInt64
    let queueDepth: UInt64

    private enum CodingKeys: String, CodingKey {
        case mode
        case queueDepth = "queue_depth"
    }
}
