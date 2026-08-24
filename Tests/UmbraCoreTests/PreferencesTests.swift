import XCTest
@testable import UmbraCore

final class PreferencesTests: XCTestCase {
    func testDefaultsUseQualityProfileAndReferenceStreamValues() throws {
        let preferences = StreamingPreferences.default

        XCTAssertEqual(preferences.width, 1_280)
        XCTAssertEqual(preferences.height, 720)
        XCTAssertEqual(preferences.fps, 60)
        XCTAssertEqual(preferences.bitrateKbps, 10_000)
        XCTAssertEqual(preferences.windowMode, .fullscreenDesktop)
        XCTAssertEqual(preferences.uiDisplayMode, .windowed)
        XCTAssertEqual(preferences.audioConfiguration, .stereo)
        XCTAssertEqual(preferences.displaySelection, .automatic)
        XCTAssertEqual(preferences.displayResolutionPolicy, .configured)
        XCTAssertEqual(preferences.optimizationMode, .quality)
        XCTAssertTrue(preferences.enableVSync)
        XCTAssertTrue(preferences.framePacing)
        XCTAssertTrue(preferences.keepAwake)
        XCTAssertFalse(preferences.clientMicrophoneEnabled)
        XCTAssertNoThrow(try preferences.validate())
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
        object.removeValue(forKey: "optimizationMode")
        object["enableVSync"] = false
        object["framePacing"] = false

        let decoded = try JSONDecoder().decode(
            StreamingPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.displaySelection, .automatic)
        XCTAssertEqual(decoded.displayResolutionPolicy, .configured)
        XCTAssertFalse(decoded.clientMicrophoneEnabled)
        XCTAssertEqual(decoded.optimizationMode, .latency)
        XCTAssertFalse(decoded.enableVSync)
        XCTAssertFalse(decoded.framePacing)
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
        XCTAssertEqual(latency.maximumDecodeSubmissions, 2)
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
