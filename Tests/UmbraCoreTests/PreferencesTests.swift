import XCTest
@testable import UmbraCore

final class PreferencesTests: XCTestCase {
    func testDefaultsUseQualityProfileAndReferenceStreamValues() throws {
        let preferences = StreamingPreferences.default

        XCTAssertEqual(preferences.width, 1_280)
        XCTAssertEqual(preferences.height, 720)
        XCTAssertEqual(preferences.fps, 60)
        XCTAssertEqual(preferences.frameRateNumerator, 60)
        XCTAssertEqual(preferences.frameRateDenominator, 1)
        XCTAssertEqual(preferences.bitrateKbps, 10_000)
        XCTAssertEqual(preferences.windowMode, .fullscreenDesktop)
        XCTAssertEqual(preferences.uiDisplayMode, .windowed)
        XCTAssertEqual(preferences.audioConfiguration, .stereo)
        XCTAssertEqual(preferences.hdrTransferPreference, .automatic)
        XCTAssertEqual(preferences.displaySelection, .automatic)
        XCTAssertEqual(preferences.displayResolutionPolicy, .configured)
        XCTAssertEqual(preferences.optimizationMode, .quality)
        XCTAssertTrue(preferences.enableVSync)
        XCTAssertTrue(preferences.framePacing)
        XCTAssertTrue(preferences.keepAwake)
        XCTAssertFalse(preferences.clientMicrophoneEnabled)
        XCTAssertFalse(preferences.clientMicrophoneRequired)
        XCTAssertNoThrow(try preferences.validate())
    }

    func testExactRationalFrameRateRoundTripsAndIntegerUpdatesRemainCompatible() throws {
        var preferences = StreamingPreferences.default
        preferences.setFrameRate(numerator: 60_000, denominator: 1_001)

        XCTAssertEqual(preferences.fps, 60)
        XCTAssertEqual(preferences.frameRateNumerator, 60_000)
        XCTAssertEqual(preferences.frameRateDenominator, 1_001)
        XCTAssertEqual(preferences.exactFrameRate, 60_000.0 / 1_001.0, accuracy: 0.000_001)
        XCTAssertNoThrow(try preferences.validate())

        let data = try JSONEncoder().encode(preferences)
        var decoded = try JSONDecoder().decode(StreamingPreferences.self, from: data)
        XCTAssertEqual(decoded, preferences)

        decoded.fps = 120
        XCTAssertEqual(decoded.frameRateNumerator, 120)
        XCTAssertEqual(decoded.frameRateDenominator, 1)
        XCTAssertEqual(decoded.exactFrameRate, 120)

        decoded.setFrameRate(numerator: 60_000, denominator: 0)
        XCTAssertThrowsError(try decoded.validate())
    }

    func testGate1RationalRefreshAdmissionUsesExactTenThroughFourHundredEightyHertzContract() {
        let accepted: [(numerator: Int, denominator: Int)] = [
            (10, 1),
            (120, 1),
            (60_000, 1_001),
            (480, 1),
            (480_000_000, 1_000_000),
            (60_000_000_000, 1_001_000_000),
        ]
        for fraction in accepted {
            var preferences = StreamingPreferences.default
            preferences.setFrameRate(
                numerator: fraction.numerator,
                denominator: fraction.denominator
            )
            XCTAssertNoThrow(
                try preferences.validate(),
                "expected \(fraction.numerator)/\(fraction.denominator) to be admitted"
            )
        }

        let rejected: [(numerator: Int, denominator: Int)] = [
            (0, 1),
            (1, 1),
            (9, 1),
            (481, 1),
            (60_000, 0),
            (Int.max, 1),
        ]
        for fraction in rejected {
            var preferences = StreamingPreferences.default
            preferences.setFrameRate(
                numerator: fraction.numerator,
                denominator: fraction.denominator
            )
            XCTAssertThrowsError(
                try preferences.validate(),
                "expected \(fraction.numerator)/\(fraction.denominator) to be rejected"
            )
        }
    }

    func testDefaultBitrateMatchesMoonlightReferenceTable() {
        XCTAssertEqual(StreamingPreferences.defaultBitrateKbps(width: 640, height: 360, fps: 30, yuv444: false), 1_000)
        XCTAssertEqual(StreamingPreferences.defaultBitrateKbps(width: 1_920, height: 1_080, fps: 60, yuv444: false), 20_000)
        XCTAssertEqual(StreamingPreferences.defaultBitrateKbps(width: 3_840, height: 2_160, fps: 120, yuv444: false), 113_000)
        XCTAssertEqual(StreamingPreferences.defaultBitrateKbps(width: 1_280, height: 720, fps: 60, yuv444: true), 20_000)
        XCTAssertEqual(StreamingPreferences.defaultBitrateKbps(width: 3_840, height: 2_160, fps: 240, yuv444: false), 160_000)
        XCTAssertEqual(StreamingPreferences.defaultBitrateKbps(width: 3_840, height: 2_160, fps: 120, yuv444: true), 226_000)
        XCTAssertGreaterThan(
            StreamingPreferences.defaultBitrateKbps(
                width: .max,
                height: .max,
                fps: .max,
                yuv444: true
            ),
            150_000
        )
    }

    func testExactRationalFrameRateCanCrossAutomaticBitrateRoundingThreshold() {
        XCTAssertEqual(
            StreamingPreferences.defaultBitrateKbps(
                width: 1_360,
                height: 720,
                fps: 60,
                yuv444: false
            ),
            11_000
        )
        XCTAssertEqual(
            StreamingPreferences.defaultBitrateKbps(
                width: 1_360,
                height: 720,
                fps: 60_000.0 / 1_001.0,
                yuv444: false
            ),
            10_000
        )
    }

    func testLockedBitrateAndPacketSizeValidation() {
        var preferences = StreamingPreferences.default
        preferences.bitrateKbps = 150_500
        XCTAssertThrowsError(try preferences.validate())

        preferences.unlockBitrate = true
        XCTAssertNoThrow(try preferences.validate())

        preferences.packetSize = 1_000
        XCTAssertThrowsError(try preferences.validate())
        preferences.packetSize = 1_392
        XCTAssertNoThrow(try preferences.validate())
    }

    func testReferenceAutomaticBitrateCanExceedManualSliderLimit() {
        var preferences = StreamingPreferences(
            width: 3_840,
            height: 2_160,
            fps: 240
        )

        XCTAssertEqual(preferences.bitrateKbps, 160_000)
        XCTAssertTrue(preferences.autoAdjustBitrate)
        XCTAssertFalse(preferences.unlockBitrate)
        XCTAssertNoThrow(try preferences.validate())

        preferences.bitrateKbps += 500
        XCTAssertThrowsError(
            try preferences.validate(),
            "A locked manual value must not borrow the automatic-bitrate exception."
        )

        preferences.enableYUV444 = true
        preferences.fps = 120
        preferences.bitrateKbps = StreamingPreferences.defaultBitrateKbps(
            width: preferences.width,
            height: preferences.height,
            fps: preferences.fps,
            yuv444: true
        )
        XCTAssertEqual(preferences.bitrateKbps, 226_000)
        XCTAssertNoThrow(try preferences.validate())
    }

    func testPreferencesRoundTripIncludesEveryOption() throws {
        let preferences = StreamingPreferences(
            width: 3_840,
            height: 2_160,
            fps: 120,
            bitrateKbps: 200_000,
            unlockBitrate: true,
            autoAdjustBitrate: false,
            optimizationMode: .latency,
            enableVSync: false,
            gameOptimizations: false,
            playAudioOnHost: true,
            clientMicrophoneEnabled: true,
            clientMicrophoneRequired: true,
            multiController: false,
            enableMDNS: false,
            quitAppAfter: true,
            absoluteMouseMode: true,
            absoluteTouchMode: false,
            framePacing: true,
            connectionWarnings: false,
            configurationWarnings: false,
            richPresence: false,
            gamepadMouse: false,
            detectNetworkBlocking: false,
            showPerformanceOverlay: true,
            swapMouseButtons: true,
            muteOnFocusLoss: true,
            backgroundGamepad: true,
            reverseScrollDirection: true,
            swapFaceButtons: true,
            keepAwake: false,
            packetSize: 1_392,
            audioConfiguration: .surround71,
            videoCodecPreference: .av1,
            enableHDR: true,
            hdrTransferPreference: .hlg,
            enableYUV444: true,
            videoDecoderPreference: .hardware,
            rendererPreference: .metal,
            windowMode: .windowed,
            uiDisplayMode: .fullscreen,
            language: .japanese,
            captureSystemKeysMode: .always,
            displaySelection: .specific(0xAABBCCDD),
            displayResolutionPolicy: .nativeExcludingNotch
        )

        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(StreamingPreferences.self, from: data), preferences)
        XCTAssertNoThrow(try preferences.validate())
    }

    func testLegacyPreferencesDecodeWithDisplayDefaults() throws {
        let encoded = try JSONEncoder().encode(StreamingPreferences.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "displaySelection")
        object.removeValue(forKey: "displayResolutionPolicy")
        object.removeValue(forKey: "clientMicrophoneEnabled")
        object.removeValue(forKey: "clientMicrophoneRequired")
        object.removeValue(forKey: "optimizationMode")
        object.removeValue(forKey: "hdrTransferPreference")
        object.removeValue(forKey: "frameRateNumerator")
        object.removeValue(forKey: "frameRateDenominator")
        object["fps"] = 75
        object["enableVSync"] = false
        object["framePacing"] = false

        let decoded = try JSONDecoder().decode(
            StreamingPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.displaySelection, .automatic)
        XCTAssertEqual(decoded.displayResolutionPolicy, .configured)
        XCTAssertFalse(decoded.clientMicrophoneEnabled)
        XCTAssertFalse(decoded.clientMicrophoneRequired)
        XCTAssertEqual(decoded.optimizationMode, .latency)
        XCTAssertEqual(decoded.hdrTransferPreference, .automatic)
        XCTAssertFalse(decoded.enableVSync)
        XCTAssertFalse(decoded.framePacing)
        XCTAssertEqual(decoded.frameRateNumerator, 75)
        XCTAssertEqual(decoded.frameRateDenominator, 1)
    }

    func testRequiredMicrophoneCannotBeEnabledWithoutRequestingMicrophoneForwarding() {
        var preferences = StreamingPreferences.default
        preferences.clientMicrophoneRequired = true

        XCTAssertThrowsError(try preferences.validate())

        preferences.clientMicrophoneEnabled = true
        XCTAssertNoThrow(try preferences.validate())
    }

    func testOptimizationModeDecodesDocumentedLegacyAliasesAndIntegers() throws {
        let encoded = try JSONEncoder().encode(StreamingPreferences.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        object.removeValue(forKey: "optimizationMode")
        object["streamOptimizationMode"] = "competitive"
        let legacy = try JSONDecoder().decode(
            StreamingPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(legacy.optimizationMode, .latency)

        object.removeValue(forKey: "streamOptimizationMode")
        object["optimizationMode"] = 1
        let legacyInteger = try JSONDecoder().decode(
            StreamingPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(legacyInteger.optimizationMode, .quality)
    }

    func testOptimizationModeRejectsUnknownFutureValuesAndInvalidTypes() throws {
        let encoded = try JSONEncoder().encode(StreamingPreferences.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        object["optimizationMode"] = "future-ultra"
        XCTAssertThrowsError(try JSONDecoder().decode(
            StreamingPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )) { error in
            XCTAssertTrue(error is DecodingError)
        }

        object["optimizationMode"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(
            StreamingPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )) { error in
            XCTAssertTrue(error is DecodingError)
        }

        object["optimizationMode"] = ["profile": "quality-v2"]
        XCTAssertThrowsError(try JSONDecoder().decode(
            StreamingPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )) { error in
            XCTAssertTrue(error is DecodingError)
        }

        object["optimizationMode"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(
            StreamingPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testOptimizationPoliciesUseAuditedDeterministicDefaults() {
        var latencyPreferences = StreamingPreferences.default
        latencyPreferences.optimizationMode = .latency
        latencyPreferences.enableVSync = false
        latencyPreferences.framePacing = false
        let latency = EffectiveStreamingPolicy.resolve(for: latencyPreferences)

        XCTAssertEqual(latency.inputCoalescingWindow, .microseconds(250))
        XCTAssertEqual(latency.inputDeliveryIntent, .stateBasedUnreliableSequenced)
        XCTAssertEqual(latency.maximumDecodeSubmissions, 4)
        XCTAssertEqual(latency.maximumCompressedDecodeQueueFrames, 1)
        XCTAssertEqual(latency.rendererQueueDepth, 1)
        XCTAssertEqual(latency.presentationIntent, .immediateTearingAllowed)
        XCTAssertFalse(latency.vsyncDefault)
        XCTAssertEqual(latency.frameSchedulingIntent, .immediate)
        XCTAssertEqual(latency.decoderIntent, .hardwareOnly)
        XCTAssertEqual(latency.codecIntent, .lowestMeasuredP99)
        XCTAssertEqual(latency.chromaIntent, .bandwidthAdaptive420)
        XCTAssertEqual(latency.fecIntent, .adaptiveLANLow)
        XCTAssertEqual(latency.fecIntent.protectionPercentRange, 0...10)
        XCTAssertTrue(latency.measurementEnabled)

        let quality = EffectiveStreamingPolicy.resolve(for: .default)
        XCTAssertEqual(quality.inputCoalescingWindow, .milliseconds(1))
        XCTAssertEqual(quality.inputDeliveryIntent, .reliableEdges)
        XCTAssertEqual(quality.maximumDecodeSubmissions, 5)
        XCTAssertEqual(quality.maximumCompressedDecodeQueueFrames, 2)
        XCTAssertEqual(quality.rendererQueueDepth, 1)
        XCTAssertEqual(quality.presentationIntent, .displayLinkedTearFree)
        XCTAssertTrue(quality.vsyncDefault)
        XCTAssertEqual(quality.frameSchedulingIntent, .adaptiveDisplayDeadline)
        XCTAssertEqual(quality.decoderIntent, .automaticHardwarePreferred)
        XCTAssertEqual(quality.codecIntent, .highestFidelity10Bit)
        XCTAssertEqual(quality.chromaIntent, .bandwidthAdaptive444)
        XCTAssertEqual(quality.fecIntent, .adaptiveResilient)
        XCTAssertEqual(quality.fecIntent.protectionPercentRange, 10...20)
        XCTAssertTrue(quality.measurementEnabled)
    }

    func testSpecificDisplaySelectionHasStableCodableRepresentation() throws {
        let encoded = try JSONEncoder().encode(DisplaySelection.specific(4_294_967_000))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(object["kind"] as? String, "specific")
        XCTAssertEqual((object["displayID"] as? NSNumber)?.uint32Value, 4_294_967_000)
        XCTAssertEqual(try JSONDecoder().decode(DisplaySelection.self, from: encoded), .specific(4_294_967_000))
    }
}
