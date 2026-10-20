import Foundation
import UmbraCore
import UmbraMedia
import UmbraServices
import UmbraStreaming
import XCTest
@testable import UmbraIntegration

final class RuntimePreferenceEffectsTests: XCTestCase {
    func testLegacyStreamingConfigurationDefaultsToFifteenAndInvalidCapacitiesClamp() {
        let configuration = StreamingConfiguration(
            address: "127.0.0.1",
            serverAppVersion: "7.1.431.0"
        )

        XCTAssertEqual(configuration.videoDecodeQueueCapacity, 15)
        XCTAssertEqual(configuration.rtspOptimizationMode, .legacy)
        XCTAssertEqual(configuration.inputOptimizationMode, .legacy)
        XCTAssertEqual(StreamingConfiguration.clampedVideoDecodeQueueCapacity(-1), 1)
        XCTAssertEqual(StreamingConfiguration.clampedVideoDecodeQueueCapacity(0), 1)
        XCTAssertEqual(StreamingConfiguration.clampedVideoDecodeQueueCapacity(16), 15)
    }

    func testLatencyPolicyMapsToHardwareOnlyNonblockingFourFrameDecoder() {
        var preferences = StreamingPreferences.default
        preferences.optimizationMode = .latency

        let configuration = AppleStreamingMediaProvider.videoDecoderConfiguration(
            for: .resolve(for: preferences)
        )

        XCTAssertEqual(configuration.policy, .hardwareOnly)
        XCTAssertEqual(configuration.upstreamGameStreamQueueCapacity, 1)
        XCTAssertEqual(configuration.maximumOutstandingFrames, 4)
        XCTAssertEqual(configuration.capacityPolicy, .dropNewestWhenFull)
        XCTAssertEqual(configuration.rendererQueueDepth, 1)
        XCTAssertTrue(configuration.backlogDiagnostic.contains("compressed GameStream=1"))
        XCTAssertTrue(configuration.backlogDiagnostic.contains("in-flight capacity=4"))
    }

    func testQualityPolicyMapsToAutomaticBoundedFiveFrameDecoder() {
        let configuration = AppleStreamingMediaProvider.videoDecoderConfiguration(
            for: .resolve(for: .default)
        )

        XCTAssertEqual(configuration.policy, .automatic)
        XCTAssertEqual(configuration.upstreamGameStreamQueueCapacity, 2)
        XCTAssertLessThanOrEqual(configuration.upstreamGameStreamQueueCapacity, 5)
        XCTAssertEqual(configuration.maximumOutstandingFrames, 5)
        XCTAssertEqual(configuration.capacityPolicy, .waitWhenFull)
        XCTAssertEqual(configuration.rendererQueueDepth, 1)
        XCTAssertTrue(configuration.backlogDiagnostic.contains("compressed GameStream=2"))
        XCTAssertTrue(configuration.backlogDiagnostic.contains("in-flight capacity=5"))
    }

    func testExplicitSoftwareOverrideRemainsHonoredInLatencyMode() {
        var preferences = StreamingPreferences.default
        preferences.optimizationMode = .latency
        preferences.videoDecoderPreference = .software

        let configuration = AppleStreamingMediaProvider.videoDecoderConfiguration(
            for: .resolve(for: preferences)
        )

        XCTAssertEqual(configuration.policy, .softwareOnly)
        XCTAssertEqual(configuration.maximumOutstandingFrames, 4)
        XCTAssertEqual(configuration.capacityPolicy, .dropNewestWhenFull)
    }

    func testAvailableFormatsPreserveProvenTenBitProfilesForNegotiation() throws {
        var preferences = StreamingPreferences.default
        preferences.enableHDR = false
        preferences.enableYUV444 = true
        preferences.videoCodecPreference = .automatic

        let formats = try AppleStreamingMediaProvider.availableVideoFormats(
            preferences: preferences,
            capabilities: fullyCapableVideoHardware
        )

        XCTAssertNotEqual(formats & VideoCodecProfile.tenBitMask, 0)
    }

    func testYUV444IsNeverSynthesizedFromCodecFamilyAvailability() throws {
        var preferences = StreamingPreferences.default
        preferences.enableYUV444 = true

        let formats = try AppleStreamingMediaProvider.availableVideoFormats(
            preferences: preferences,
            capabilities: fullyCapableVideoHardware
        )

        XCTAssertEqual(formats & VideoCodecProfile.yuv444Mask, 0)
    }

    func testConfigurationWarningsExplainUnprovenClientYUV444Fallback() {
        var preferences = StreamingPreferences.default
        preferences.enableYUV444 = true
        let host = StreamHost(
            uuid: "host-yuv444",
            name: "YUV 4:4:4 Host",
            applications: [unsupportedApplication],
            codecSupport: [.h264, .h264High8YUV444]
        )

        let warnings = StreamingConfigurationWarningEvaluator(
            capabilities: fullyCapableVideoHardware
        ).warnings(
            host: host,
            application: unsupportedApplication,
            preferences: preferences
        )

        XCTAssertEqual(warnings.first(where: { $0.kind == .yuv444Support })?.message,
                       "This Mac has no proven decoder for the selected YUV 4:4:4 format. Umbra will use YUV 4:2:0 for this stream.")
    }

    func testConfigurationWarningsAreSuppressedByPreference() {
        var preferences = StreamingPreferences.default
        preferences.configurationWarnings = false
        preferences.enableHDR = true
        preferences.enableYUV444 = true
        preferences.videoCodecPreference = .h264
        preferences.videoDecoderPreference = .software
        preferences.packetSize = 1_024

        let evaluator = StreamingConfigurationWarningEvaluator(capabilities: limitedCapabilities)
        XCTAssertEqual(
            evaluator.warnings(host: limitedHost, application: unsupportedApplication, preferences: preferences),
            []
        )
    }

    func testConfigurationWarningsExplainUnsupportedHDRAndCodecSettings() {
        var preferences = StreamingPreferences.default
        preferences.enableHDR = true
        preferences.videoCodecPreference = .h264

        let warnings = StreamingConfigurationWarningEvaluator(capabilities: limitedCapabilities).warnings(
            host: limitedHost,
            application: unsupportedApplication,
            preferences: preferences
        )

        XCTAssertEqual(warnings.map(\.kind), [.hdrCodecSupport])
        XCTAssertTrue(warnings.allSatisfy { warning in
            warning.message.contains("Disable") || warning.message.contains("Change")
        })
    }

    func testConfigurationWarningsCoverRiskyPerformanceAudioAndNetworkSettings() {
        var preferences = StreamingPreferences.default
        preferences.width = 3_840
        preferences.height = 2_160
        preferences.fps = 120
        preferences.videoDecoderPreference = .software
        preferences.audioConfiguration = .surround71
        preferences.framePacing = true
        preferences.enableVSync = false
        preferences.packetSize = 1_024
        preferences.unlockBitrate = true
        preferences.bitrateKbps = 200_000

        let warnings = StreamingConfigurationWarningEvaluator(capabilities: limitedCapabilities).warnings(
            host: limitedHost,
            application: unsupportedApplication,
            preferences: preferences
        )

        XCTAssertEqual(Set(warnings.map(\.kind)), Set([
            .softwareDecoderPerformance,
            .surroundOutput,
            .framePacing,
            .customPacketSize,
            .extremeBitrate,
        ]))
        XCTAssertTrue(warnings.allSatisfy { !$0.message.isEmpty })
    }

    func testConfigurationWarningsAcceptCompatibleDefaults() {
        let warnings = StreamingConfigurationWarningEvaluator(capabilities: limitedCapabilities).warnings(
            host: limitedHost,
            application: unsupportedApplication,
            preferences: .default
        )
        XCTAssertTrue(warnings.isEmpty)
    }

    func testConfigurationWarningsDetectNoCommonAutomaticCodec() {
        let av1OnlyHost = StreamHost(
            uuid: "host-av1",
            name: "AV1 Host",
            applications: [unsupportedApplication],
            codecSupport: [.av1Main8]
        )

        let warnings = StreamingConfigurationWarningEvaluator(capabilities: limitedCapabilities).warnings(
            host: av1OnlyHost,
            application: unsupportedApplication,
            preferences: .default
        )

        XCTAssertEqual(warnings.map(\.kind), [.clientCodecSupport])
        XCTAssertTrue(warnings[0].message.contains("mutually supported codec"))
    }

    func testForcedAV1WarningEvaluationAcceptsPinnedHEVCFallback() {
        var preferences = StreamingPreferences.default
        preferences.videoCodecPreference = .av1
        let hevcHost = StreamHost(
            uuid: "host-hevc",
            name: "HEVC Host",
            applications: [unsupportedApplication],
            codecSupport: [.hevc]
        )

        let warnings = StreamingConfigurationWarningEvaluator(
            capabilities: fullyCapableVideoHardware
        ).warnings(
            host: hevcHost,
            application: unsupportedApplication,
            preferences: preferences
        )

        XCTAssertFalse(warnings.contains { warning in
            warning.kind == .hostCodecSupport || warning.kind == .clientCodecSupport
        })
    }

    func testDiscordServiceSendsHandshakeAndActiveApplicationOverIPC() throws {
        let transport = RecordingDiscordIPCTransport()
        let service = DiscordRichPresenceService(clientID: "client-123", transport: transport)

        service.update(
            applicationName: "  Desktop  ",
            startedAt: Date(timeIntervalSince1970: 1_234)
        )
        service.waitForPendingOperations()

        let batches = transport.recordedBatches()
        let batch = try XCTUnwrap(batches.first)
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(opcode(in: batch[0]), DiscordIPCOpcode.handshake.rawValue)
        XCTAssertEqual(opcode(in: batch[1]), DiscordIPCOpcode.frame.rawValue)

        let handshake = try payload(in: batch[0])
        XCTAssertEqual(handshake["v"] as? Int, 1)
        XCTAssertEqual(handshake["client_id"] as? String, "client-123")

        let command = try payload(in: batch[1])
        XCTAssertEqual(command["cmd"] as? String, "SET_ACTIVITY")
        let arguments = try XCTUnwrap(command["args"] as? [String: Any])
        let activity = try XCTUnwrap(arguments["activity"] as? [String: Any])
        XCTAssertEqual(activity["details"] as? String, "Streaming Desktop")
        XCTAssertEqual(activity["state"] as? String, "Remote game stream")
        let timestamps = try XCTUnwrap(activity["timestamps"] as? [String: Any])
        XCTAssertEqual(timestamps["start"] as? Int, 1_234)
    }

    func testDiscordServiceClearsPresenceAndSilentlyIgnoresTransportFailure() throws {
        let transport = RecordingDiscordIPCTransport(error: POSIXError(.ECONNREFUSED))
        let service = DiscordRichPresenceService(clientID: "client-123", transport: transport)

        service.clear()
        service.waitForPendingOperations()

        let batch = try XCTUnwrap(transport.recordedBatches().first)
        let command = try payload(in: batch[1])
        let arguments = try XCTUnwrap(command["args"] as? [String: Any])
        XCTAssertTrue(arguments["activity"] is NSNull)
    }

    func testDiscordSocketSearchIncludesMacOSTemporaryAndApplicationSupportLocations() {
        let transport = UnixDiscordIPCTransport(
            environment: ["TMPDIR": "/private/tmp/user"],
            temporaryDirectory: "/private/tmp/fallback",
            homeDirectory: "/Users/tester"
        )

        let paths = transport.candidateSocketPaths()
        XCTAssertTrue(paths.contains("/private/tmp/user/discord-ipc-0"))
        XCTAssertTrue(paths.contains("/private/tmp/fallback/discord-ipc-9"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/discord/discord-ipc-0"))
    }

    func testRichPresenceLifecycleOnlyUsesDiscordWhenEnabledAndClearsWithPresentation() async throws {
        let presence = RecordingRichPresenceManager()
        let lifecycle = DiscordRichPresenceLifecycleCoordinator(presence: presence)
        var disabled = StreamingPreferences.default
        disabled.richPresence = false

        try await lifecycle.prepare(for: try makeBootstrap(preferences: disabled))
        await lifecycle.finishPresentation()
        XCTAssertEqual(presence.recordedEvents(), [])

        var enabled = disabled
        enabled.richPresence = true
        let enabledBootstrap = try makeBootstrap(preferences: enabled)
        try await lifecycle.prepare(for: enabledBootstrap)
        XCTAssertEqual(presence.recordedEvents(), [])
        await lifecycle.commitStreaming(for: enabledBootstrap)
        await lifecycle.finishPresentation()
        XCTAssertEqual(presence.recordedEvents(), [.updated("Desktop"), .cleared])
    }

    private var limitedCapabilities: AppleStreamingCapabilities {
        AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: false,
            supportsHardwareAV1: false,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2
        )
    }

    private var fullyCapableVideoHardware: AppleStreamingCapabilities {
        AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 8,
            supportsHardwareHEVCMain10: true,
            supportsHardwareAV1Main10: true
        )
    }

    private var limitedHost: StreamHost {
        StreamHost(
            uuid: "host-1",
            name: "Host",
            applications: [unsupportedApplication],
            codecSupport: [.h264]
        )
    }

    private var unsupportedApplication: StreamApplication {
        StreamApplication(id: 1, name: "Desktop", hdrSupported: false)
    }

    private func makeBootstrap(preferences: StreamingPreferences) throws -> StreamBootstrap {
        StreamBootstrap(
            sessionID: UUID(),
            host: limitedHost,
            application: unsupportedApplication,
            preferences: preferences,
            rtspSessionURL: URL(string: "rtsp://127.0.0.1/session"),
            remoteInputCredentials: try RemoteInputCredentials(
                key: Data(repeating: 1, count: 16),
                initializationVector: Data(repeating: 2, count: 16)
            )
        )
    }

    private func opcode(in frame: Data) -> UInt32 {
        frame.prefix(4).enumerated().reduce(UInt32.zero) { result, pair in
            result | (UInt32(pair.element) << UInt32(pair.offset * 8))
        }
    }

    private func payload(in frame: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: frame.dropFirst(8)) as? [String: Any]
        )
    }
}

private final class RecordingDiscordIPCTransport: DiscordIPCTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error?
    private var batches: [[Data]] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func send(frames: [Data]) throws {
        lock.withLock { batches.append(frames) }
        if let error { throw error }
    }

    func recordedBatches() -> [[Data]] {
        lock.withLock { batches }
    }
}

private final class RecordingRichPresenceManager: RichPresenceManaging, @unchecked Sendable {
    enum Event: Equatable {
        case updated(String)
        case cleared
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func update(applicationName: String, startedAt: Date) {
        lock.withLock { events.append(.updated(applicationName)) }
    }

    func clear() {
        lock.withLock { events.append(.cleared) }
    }

    func recordedEvents() -> [Event] {
        lock.withLock { events }
    }
}
