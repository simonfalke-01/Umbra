import Foundation

public enum AudioConfiguration: Int, Codable, CaseIterable, Sendable {
    case stereo
    case surround51
    case surround71
}

public enum VideoCodecPreference: Int, Codable, CaseIterable, Sendable {
    case automatic
    case h264
    case hevc
    @available(*, deprecated, message: "HDR is now controlled separately by enableHDR")
    case hevcHDRDeprecated
    case av1

    public static let allCases: [VideoCodecPreference] = [.automatic, .h264, .hevc, .av1]
}

public enum VideoDecoderPreference: Int, Codable, CaseIterable, Sendable {
    case automatic
    case hardware
    case software
}

public enum RendererPreference: Int, Codable, CaseIterable, Sendable {
    case probeOnly = -1
    case automatic
    case vulkan
    case metal
    case avSampleBufferDisplayLayer
}

public enum WindowMode: Int, Codable, CaseIterable, Sendable {
    case fullscreen
    case fullscreenDesktop
    case windowed
}

public enum UIDisplayMode: Int, Codable, CaseIterable, Sendable {
    case windowed
    case maximized
    case fullscreen
}

/// Legacy Moonlight-compatible values retained only to migrate existing preferences.
/// New app-language preferences use BCP-47 tags outside the streaming model.
public enum AppLanguage: Int, Codable, CaseIterable, Sendable {
    case automatic
    case english
    case french
    case simplifiedChinese
    case german
    case norwegianBokmal
    case russian
    case spanish
    case japanese
    case vietnamese
    case thai
    case korean
    case hungarian
    case dutch
    case swedish
    case turkish
    case ukrainian
    case traditionalChinese
    case portuguese
    case brazilianPortuguese
    case greek
    case italian
    case hindi
    case polish
    case czech
    case hebrew
    case centralKurdish
    case lithuanian
    case estonian
    case bulgarian
    case esperanto
    case tamil
}

public enum CaptureSystemKeysMode: Int, Codable, CaseIterable, Sendable {
    case off
    case fullscreen
    case always
}

/// A stable Core Graphics display identifier persisted without importing AppKit into UmbraCore.
public typealias DisplayID = UInt32

public enum DisplaySelection: Hashable, Sendable {
    case automatic
    case specific(DisplayID)
}

extension DisplaySelection: Codable {
    private enum Kind: String, Codable {
        case automatic
        case specific
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case displayID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .automatic:
            self = .automatic
        case .specific:
            self = .specific(try container.decode(DisplayID.self, forKey: .displayID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Kind.automatic, forKey: .kind)
        case let .specific(displayID):
            try container.encode(Kind.specific, forKey: .kind)
            try container.encode(displayID, forKey: .displayID)
        }
    }
}

public enum DisplayResolutionPolicy: String, Codable, CaseIterable, Sendable {
    /// Use the explicitly configured width and height.
    case configured
    /// Use the selected display's logical dimensions, including the camera housing area.
    case native
    /// Use the selected display's logical dimensions below any camera housing.
    case nativeExcludingNotch
}

public enum StreamOptimizationMode: String, CaseIterable, Hashable, Sendable {
    case latency
    case quality

    public var recommendedVSync: Bool {
        switch self {
        case .latency: false
        case .quality: true
        }
    }

    public var recommendedFramePacing: Bool {
        switch self {
        case .latency: false
        case .quality: true
        }
    }
}

/// Encoded-sample fidelity is separate from the latency/quality scheduling profile.
/// Codec lossless preserves the negotiated YUV samples; it does not claim that RGB-to-YUV,
/// chroma subsampling, bit-depth conversion, or display color management is lossless.
public enum StreamingFidelityPreference: String, Codable, CaseIterable, Hashable, Sendable {
    case visuallyLossless
    case codecLosslessRequired
}

public enum HDRTransferPreference: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case pq
    case hlg
}

extension StreamOptimizationMode: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            // Legacy aliases emitted by pre-release optimization-mode builds.
            case "latency", "lowlatency", "low-latency", "performance", "competitive":
                self = .latency
            case "quality", "bestquality", "best-quality", "balanced", "fidelity":
                self = .quality
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported stream optimization mode."
                )
            }
            return
        }
        if let value = try? container.decode(Int.self) {
            switch value {
            case 0:
                self = .latency
                return
            case 1:
                self = .quality
                return
            default:
                break
            }
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Stream optimization mode must be a supported name or legacy integer."
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum StreamingInputDeliveryIntent: Equatable, Sendable {
    case stateBasedUnreliableSequenced
    case reliableEdges
}

public enum StreamingPresentationIntent: Equatable, Sendable {
    case immediateTearingAllowed
    case displayLinkedTearFree
}

public enum StreamingFrameSchedulingIntent: Equatable, Sendable {
    case immediate
    case adaptiveDisplayDeadline
}

public enum StreamingDecoderIntent: Equatable, Sendable {
    case automaticHardwarePreferred
    case hardwareOnly
    case softwareOnly
}

public enum StreamingCodecIntent: Equatable, Sendable {
    case lowestMeasuredP99
    case highestFidelity10Bit
}

public enum StreamingChromaIntent: Equatable, Sendable {
    case bandwidthAdaptive420
    case bandwidthAdaptive444
}

public enum StreamingFECIntent: Equatable, Sendable {
    case adaptiveLANLow
    case adaptiveResilient

    public var protectionPercentRange: ClosedRange<Int> {
        switch self {
        case .adaptiveLANLow: 0...10
        case .adaptiveResilient: 10...20
        }
    }
}

/// User-selected low-level settings retained alongside the optimization profile.
/// Consumers can distinguish an explicit compatibility choice from a profile intent.
public struct EffectiveStreamingOverrides: Equatable, Sendable {
    public let enableVSync: Bool
    public let framePacing: Bool
    public let videoDecoderPreference: VideoDecoderPreference
    public let videoCodecPreference: VideoCodecPreference
    public let rendererPreference: RendererPreference
    public let enableYUV444: Bool

    public init(
        enableVSync: Bool,
        framePacing: Bool,
        videoDecoderPreference: VideoDecoderPreference,
        videoCodecPreference: VideoCodecPreference,
        rendererPreference: RendererPreference,
        enableYUV444: Bool
    ) {
        self.enableVSync = enableVSync
        self.framePacing = framePacing
        self.videoDecoderPreference = videoDecoderPreference
        self.videoCodecPreference = videoCodecPreference
        self.rendererPreference = rendererPreference
        self.enableYUV444 = enableYUV444
    }
}

/// An immutable, session-scoped contract resolved once before a stream starts.
/// It describes intent only; unsupported transports and decoder paths must not be enabled implicitly.
public struct EffectiveStreamingPolicy: Equatable, Sendable {
    public let mode: StreamOptimizationMode
    public let inputCoalescingWindow: Duration
    public let inputDeliveryIntent: StreamingInputDeliveryIntent
    public let maximumDecodeSubmissions: Int
    public let maximumCompressedDecodeQueueFrames: Int
    public let rendererQueueDepth: Int
    public let presentationIntent: StreamingPresentationIntent
    public let vsyncDefault: Bool
    public let vsyncEnabled: Bool
    public let frameSchedulingIntent: StreamingFrameSchedulingIntent
    public let decoderIntent: StreamingDecoderIntent
    public let codecIntent: StreamingCodecIntent
    public let chromaIntent: StreamingChromaIntent
    public let fecIntent: StreamingFECIntent
    public let measurementEnabled: Bool
    public let fidelityPreference: StreamingFidelityPreference
    public let advancedOverrides: EffectiveStreamingOverrides

    public static func resolve(for preferences: StreamingPreferences) -> Self {
        let defaults = defaults(for: preferences.optimizationMode)
        let decoderIntent: StreamingDecoderIntent = switch preferences.videoDecoderPreference {
        case .automatic: defaults.decoderIntent
        case .hardware: .hardwareOnly
        case .software: .softwareOnly
        }
        let vsyncEnabled = preferences.enableVSync
        let frameSchedulingIntent: StreamingFrameSchedulingIntent =
            vsyncEnabled && preferences.framePacing
                ? .adaptiveDisplayDeadline
                : .immediate

        return Self(
            mode: preferences.optimizationMode,
            inputCoalescingWindow: defaults.inputCoalescingWindow,
            inputDeliveryIntent: defaults.inputDeliveryIntent,
            maximumDecodeSubmissions: defaults.maximumDecodeSubmissions,
            maximumCompressedDecodeQueueFrames: defaults.maximumCompressedDecodeQueueFrames,
            rendererQueueDepth: 1,
            presentationIntent: vsyncEnabled
                ? .displayLinkedTearFree
                : .immediateTearingAllowed,
            vsyncDefault: preferences.optimizationMode.recommendedVSync,
            vsyncEnabled: vsyncEnabled,
            frameSchedulingIntent: frameSchedulingIntent,
            decoderIntent: decoderIntent,
            codecIntent: defaults.codecIntent,
            chromaIntent: defaults.chromaIntent,
            fecIntent: defaults.fecIntent,
            measurementEnabled: true,
            fidelityPreference: preferences.fidelityPreference,
            advancedOverrides: EffectiveStreamingOverrides(
                enableVSync: preferences.enableVSync,
                framePacing: preferences.framePacing,
                videoDecoderPreference: preferences.videoDecoderPreference,
                videoCodecPreference: preferences.videoCodecPreference,
                rendererPreference: preferences.rendererPreference,
                enableYUV444: preferences.enableYUV444
            )
        )
    }

    private struct ModeDefaults {
        let inputCoalescingWindow: Duration
        let inputDeliveryIntent: StreamingInputDeliveryIntent
        let maximumDecodeSubmissions: Int
        let maximumCompressedDecodeQueueFrames: Int
        let decoderIntent: StreamingDecoderIntent
        let codecIntent: StreamingCodecIntent
        let chromaIntent: StreamingChromaIntent
        let fecIntent: StreamingFECIntent
    }

    private static func defaults(for mode: StreamOptimizationMode) -> ModeDefaults {
        switch mode {
        case .latency:
            ModeDefaults(
                inputCoalescingWindow: .microseconds(250),
                inputDeliveryIntent: .stateBasedUnreliableSequenced,
                maximumDecodeSubmissions: 4,
                maximumCompressedDecodeQueueFrames: 1,
                decoderIntent: .hardwareOnly,
                codecIntent: .lowestMeasuredP99,
                chromaIntent: .bandwidthAdaptive420,
                fecIntent: .adaptiveLANLow
            )
        case .quality:
            ModeDefaults(
                inputCoalescingWindow: .milliseconds(1),
                inputDeliveryIntent: .reliableEdges,
                maximumDecodeSubmissions: 5,
                maximumCompressedDecodeQueueFrames: 2,
                decoderIntent: .automaticHardwarePreferred,
                codecIntent: .highestFidelity10Bit,
                chromaIntent: .bandwidthAdaptive444,
                fecIntent: .adaptiveResilient
            )
        }
    }
}

public enum LSPNetworkProfilePreference: String, Codable, CaseIterable, Sendable {
    case adaptiveLowLatency = "adaptive-low-latency"
    case competitionLAN = "competition-lan"
}

public struct StreamingPreferences: Codable, Hashable, Sendable {
    public static let `default` = StreamingPreferences()
    public static let minimumStreamWidth = 320
    public static let maximumStreamWidth = 7_680
    public static let minimumStreamHeight = 200
    public static let maximumStreamHeight = 4_320
    public static let minimumFrameRate = 10
    public static let maximumFrameRate = 480
    public static let minimumBitrateKbps = 1_000
    public static let maximumBitrateKbps = 500_000

    public var width: Int
    public var height: Int
    public var fps: Int {
        didSet {
            frameRateNumerator = fps
            frameRateDenominator = 1
        }
    }
    public private(set) var frameRateNumerator: Int
    public private(set) var frameRateDenominator: Int
    public var bitrateKbps: Int
    public var unlockBitrate: Bool
    public var autoAdjustBitrate: Bool
    public var optimizationMode: StreamOptimizationMode
    public var fidelityPreference: StreamingFidelityPreference
    public var enableVSync: Bool
    public var gameOptimizations: Bool
    public var playAudioOnHost: Bool
    public var clientMicrophoneEnabled: Bool
    public var clientMicrophoneRequired: Bool
    public var lspNetworkProfile: LSPNetworkProfilePreference
    public var lspCompetitionCapacityMbps: Int
    public var lspPointerRate: Int
    public var lspControllerRate: Int
    public var lspSensorRate: Int
    public var lspReconciliationRate: Int
    public var lspPairMicrophonePermission: Bool
    public var lspPairQuitPermission: Bool
    public var multiController: Bool
    public var enableMDNS: Bool
    public var quitAppAfter: Bool
    public var absoluteMouseMode: Bool
    public var absoluteTouchMode: Bool
    public var framePacing: Bool
    public var connectionWarnings: Bool
    public var configurationWarnings: Bool
    public var richPresence: Bool
    public var gamepadMouse: Bool
    public var detectNetworkBlocking: Bool
    public var showPerformanceOverlay: Bool
    public var swapMouseButtons: Bool
    public var muteOnFocusLoss: Bool
    public var backgroundGamepad: Bool
    public var reverseScrollDirection: Bool
    public var swapFaceButtons: Bool
    public var keepAwake: Bool
    public var packetSize: Int
    public var audioConfiguration: AudioConfiguration
    public var videoCodecPreference: VideoCodecPreference
    public var enableHDR: Bool
    public var hdrTransferPreference: HDRTransferPreference
    public var enableYUV444: Bool
    public var videoDecoderPreference: VideoDecoderPreference
    public var rendererPreference: RendererPreference
    public var windowMode: WindowMode
    public var uiDisplayMode: UIDisplayMode
    /// Legacy persisted language migrated by the application layer; streaming ignores this value.
    public var language: AppLanguage
    public var captureSystemKeysMode: CaptureSystemKeysMode
    public var displaySelection: DisplaySelection
    public var displayResolutionPolicy: DisplayResolutionPolicy

    public init(
        width: Int = 1_280,
        height: Int = 720,
        fps: Int = 60,
        frameRateNumerator: Int? = nil,
        frameRateDenominator: Int = 1,
        bitrateKbps: Int? = nil,
        unlockBitrate: Bool = false,
        autoAdjustBitrate: Bool = true,
        optimizationMode: StreamOptimizationMode = .quality,
        fidelityPreference: StreamingFidelityPreference = .visuallyLossless,
        enableVSync: Bool = true,
        gameOptimizations: Bool = true,
        playAudioOnHost: Bool = false,
        clientMicrophoneEnabled: Bool = false,
        clientMicrophoneRequired: Bool = false,
        lspNetworkProfile: LSPNetworkProfilePreference = .adaptiveLowLatency,
        lspCompetitionCapacityMbps: Int = 0,
        lspPointerRate: Int = 1_000,
        lspControllerRate: Int = 250,
        lspSensorRate: Int = 250,
        lspReconciliationRate: Int = 250,
        lspPairMicrophonePermission: Bool = false,
        lspPairQuitPermission: Bool = false,
        multiController: Bool = true,
        enableMDNS: Bool = true,
        quitAppAfter: Bool = false,
        absoluteMouseMode: Bool = false,
        absoluteTouchMode: Bool = true,
        framePacing: Bool = true,
        connectionWarnings: Bool = true,
        configurationWarnings: Bool = true,
        richPresence: Bool = true,
        gamepadMouse: Bool = true,
        detectNetworkBlocking: Bool = true,
        showPerformanceOverlay: Bool = false,
        swapMouseButtons: Bool = false,
        muteOnFocusLoss: Bool = false,
        backgroundGamepad: Bool = false,
        reverseScrollDirection: Bool = false,
        swapFaceButtons: Bool = false,
        keepAwake: Bool = true,
        packetSize: Int = 0,
        audioConfiguration: AudioConfiguration = .stereo,
        videoCodecPreference: VideoCodecPreference = .automatic,
        enableHDR: Bool = false,
        hdrTransferPreference: HDRTransferPreference = .automatic,
        enableYUV444: Bool = false,
        videoDecoderPreference: VideoDecoderPreference = .automatic,
        rendererPreference: RendererPreference = .automatic,
        windowMode: WindowMode = .fullscreenDesktop,
        uiDisplayMode: UIDisplayMode = .windowed,
        language: AppLanguage = .automatic,
        captureSystemKeysMode: CaptureSystemKeysMode = .off,
        displaySelection: DisplaySelection = .automatic,
        displayResolutionPolicy: DisplayResolutionPolicy = .configured
    ) {
        self.width = width
        self.height = height
        let exactFrameRateNumerator = frameRateNumerator ?? fps
        self.fps = Self.roundedFramesPerSecond(
            numerator: exactFrameRateNumerator,
            denominator: frameRateDenominator,
            fallback: fps
        )
        self.frameRateNumerator = exactFrameRateNumerator
        self.frameRateDenominator = frameRateDenominator
        let exactFrameRate = frameRateDenominator > 0
            ? Double(exactFrameRateNumerator) / Double(frameRateDenominator)
            : Double(self.fps)
        self.bitrateKbps = bitrateKbps ?? Self.defaultBitrateKbps(
            width: width,
            height: height,
            fps: exactFrameRate,
            yuv444: enableYUV444
        )
        self.unlockBitrate = unlockBitrate
        self.autoAdjustBitrate = autoAdjustBitrate
        self.optimizationMode = optimizationMode
        self.fidelityPreference = fidelityPreference
        self.enableVSync = enableVSync
        self.gameOptimizations = gameOptimizations
        self.playAudioOnHost = playAudioOnHost
        self.clientMicrophoneEnabled = clientMicrophoneEnabled
        self.clientMicrophoneRequired = clientMicrophoneRequired
        self.lspNetworkProfile = lspNetworkProfile
        self.lspCompetitionCapacityMbps = lspCompetitionCapacityMbps
        self.lspPointerRate = lspPointerRate
        self.lspControllerRate = lspControllerRate
        self.lspSensorRate = lspSensorRate
        self.lspReconciliationRate = lspReconciliationRate
        self.lspPairMicrophonePermission = lspPairMicrophonePermission
        self.lspPairQuitPermission = lspPairQuitPermission
        self.multiController = multiController
        self.enableMDNS = enableMDNS
        self.quitAppAfter = quitAppAfter
        self.absoluteMouseMode = absoluteMouseMode
        self.absoluteTouchMode = absoluteTouchMode
        self.framePacing = framePacing
        self.connectionWarnings = connectionWarnings
        self.configurationWarnings = configurationWarnings
        self.richPresence = richPresence
        self.gamepadMouse = gamepadMouse
        self.detectNetworkBlocking = detectNetworkBlocking
        self.showPerformanceOverlay = showPerformanceOverlay
        self.swapMouseButtons = swapMouseButtons
        self.muteOnFocusLoss = muteOnFocusLoss
        self.backgroundGamepad = backgroundGamepad
        self.reverseScrollDirection = reverseScrollDirection
        self.swapFaceButtons = swapFaceButtons
        self.keepAwake = keepAwake
        self.packetSize = packetSize
        self.audioConfiguration = audioConfiguration
        self.videoCodecPreference = videoCodecPreference
        self.enableHDR = enableHDR
        self.hdrTransferPreference = hdrTransferPreference
        self.enableYUV444 = enableYUV444
        self.videoDecoderPreference = videoDecoderPreference
        self.rendererPreference = rendererPreference
        self.windowMode = windowMode
        self.uiDisplayMode = uiDisplayMode
        self.language = language
        self.captureSystemKeysMode = captureSystemKeysMode
        self.displaySelection = displaySelection
        self.displayResolutionPolicy = displayResolutionPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case fps
        case frameRateNumerator
        case frameRateDenominator
        case bitrateKbps
        case unlockBitrate
        case autoAdjustBitrate
        case optimizationMode
        case fidelityPreference
        case enableVSync
        case gameOptimizations
        case playAudioOnHost
        case clientMicrophoneEnabled
        case clientMicrophoneRequired
        case lspNetworkProfile
        case lspCompetitionCapacityMbps
        case lspPointerRate
        case lspControllerRate
        case lspSensorRate
        case lspReconciliationRate
        case lspPairMicrophonePermission
        case lspPairQuitPermission
        case multiController
        case enableMDNS
        case quitAppAfter
        case absoluteMouseMode
        case absoluteTouchMode
        case framePacing
        case connectionWarnings
        case configurationWarnings
        case richPresence
        case gamepadMouse
        case detectNetworkBlocking
        case showPerformanceOverlay
        case swapMouseButtons
        case muteOnFocusLoss
        case backgroundGamepad
        case reverseScrollDirection
        case swapFaceButtons
        case keepAwake
        case packetSize
        case audioConfiguration
        case videoCodecPreference
        case enableHDR
        case hdrTransferPreference
        case enableYUV444
        case videoDecoderPreference
        case rendererPreference
        case windowMode
        case uiDisplayMode
        case language
        case captureSystemKeysMode
        case displaySelection
        case displayResolutionPolicy
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case optimizationMode = "streamOptimizationMode"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let defaults = Self.default
        let width = try container.decodeIfPresent(Int.self, forKey: .width) ?? defaults.width
        let height = try container.decodeIfPresent(Int.self, forKey: .height) ?? defaults.height
        let fps = try container.decodeIfPresent(Int.self, forKey: .fps) ?? defaults.fps
        let frameRateNumerator = try container.decodeIfPresent(
            Int.self,
            forKey: .frameRateNumerator
        )
        let frameRateDenominator = try container.decodeIfPresent(
            Int.self,
            forKey: .frameRateDenominator
        ) ?? defaults.frameRateDenominator
        let enableYUV444 = try container.decodeIfPresent(Bool.self, forKey: .enableYUV444) ?? defaults.enableYUV444
        let enableVSync = try container.decodeIfPresent(Bool.self, forKey: .enableVSync) ?? defaults.enableVSync
        let framePacing = try container.decodeIfPresent(Bool.self, forKey: .framePacing) ?? false
        let decodedOptimizationMode: StreamOptimizationMode?
        if container.contains(.optimizationMode) {
            decodedOptimizationMode = try container.decode(
                StreamOptimizationMode.self,
                forKey: .optimizationMode
            )
        } else if legacyContainer.contains(.optimizationMode) {
            decodedOptimizationMode = try legacyContainer.decode(
                StreamOptimizationMode.self,
                forKey: .optimizationMode
            )
        } else {
            decodedOptimizationMode = nil
        }
        let optimizationMode = decodedOptimizationMode
            ?? (enableVSync ? .quality : .latency)

        self.init(
            width: width,
            height: height,
            fps: fps,
            frameRateNumerator: frameRateNumerator,
            frameRateDenominator: frameRateDenominator,
            bitrateKbps: try container.decodeIfPresent(Int.self, forKey: .bitrateKbps),
            unlockBitrate: try container.decodeIfPresent(Bool.self, forKey: .unlockBitrate) ?? defaults.unlockBitrate,
            autoAdjustBitrate: try container.decodeIfPresent(Bool.self, forKey: .autoAdjustBitrate) ?? defaults.autoAdjustBitrate,
            optimizationMode: optimizationMode,
            fidelityPreference: try container.decodeIfPresent(
                StreamingFidelityPreference.self,
                forKey: .fidelityPreference
            ) ?? defaults.fidelityPreference,
            enableVSync: enableVSync,
            gameOptimizations: try container.decodeIfPresent(Bool.self, forKey: .gameOptimizations) ?? defaults.gameOptimizations,
            playAudioOnHost: try container.decodeIfPresent(Bool.self, forKey: .playAudioOnHost) ?? defaults.playAudioOnHost,
            clientMicrophoneEnabled: try container.decodeIfPresent(Bool.self, forKey: .clientMicrophoneEnabled) ?? defaults.clientMicrophoneEnabled,
            clientMicrophoneRequired: try container.decodeIfPresent(Bool.self, forKey: .clientMicrophoneRequired) ?? defaults.clientMicrophoneRequired,
            lspNetworkProfile: try container.decodeIfPresent(
                LSPNetworkProfilePreference.self,
                forKey: .lspNetworkProfile
            ) ?? defaults.lspNetworkProfile,
            lspCompetitionCapacityMbps: try container.decodeIfPresent(
                Int.self,
                forKey: .lspCompetitionCapacityMbps
            ) ?? defaults.lspCompetitionCapacityMbps,
            lspPointerRate: try container.decodeIfPresent(Int.self, forKey: .lspPointerRate) ?? defaults.lspPointerRate,
            lspControllerRate: try container.decodeIfPresent(Int.self, forKey: .lspControllerRate) ?? defaults.lspControllerRate,
            lspSensorRate: try container.decodeIfPresent(Int.self, forKey: .lspSensorRate) ?? defaults.lspSensorRate,
            lspReconciliationRate: try container.decodeIfPresent(Int.self, forKey: .lspReconciliationRate) ?? defaults.lspReconciliationRate,
            lspPairMicrophonePermission: try container.decodeIfPresent(
                Bool.self,
                forKey: .lspPairMicrophonePermission
            ) ?? defaults.lspPairMicrophonePermission,
            lspPairQuitPermission: try container.decodeIfPresent(
                Bool.self,
                forKey: .lspPairQuitPermission
            ) ?? defaults.lspPairQuitPermission,
            multiController: try container.decodeIfPresent(Bool.self, forKey: .multiController) ?? defaults.multiController,
            enableMDNS: try container.decodeIfPresent(Bool.self, forKey: .enableMDNS) ?? defaults.enableMDNS,
            quitAppAfter: try container.decodeIfPresent(Bool.self, forKey: .quitAppAfter) ?? defaults.quitAppAfter,
            absoluteMouseMode: try container.decodeIfPresent(Bool.self, forKey: .absoluteMouseMode) ?? defaults.absoluteMouseMode,
            absoluteTouchMode: try container.decodeIfPresent(Bool.self, forKey: .absoluteTouchMode) ?? defaults.absoluteTouchMode,
            framePacing: framePacing,
            connectionWarnings: try container.decodeIfPresent(Bool.self, forKey: .connectionWarnings) ?? defaults.connectionWarnings,
            configurationWarnings: try container.decodeIfPresent(Bool.self, forKey: .configurationWarnings) ?? defaults.configurationWarnings,
            richPresence: try container.decodeIfPresent(Bool.self, forKey: .richPresence) ?? defaults.richPresence,
            gamepadMouse: try container.decodeIfPresent(Bool.self, forKey: .gamepadMouse) ?? defaults.gamepadMouse,
            detectNetworkBlocking: try container.decodeIfPresent(Bool.self, forKey: .detectNetworkBlocking) ?? defaults.detectNetworkBlocking,
            showPerformanceOverlay: try container.decodeIfPresent(Bool.self, forKey: .showPerformanceOverlay) ?? defaults.showPerformanceOverlay,
            swapMouseButtons: try container.decodeIfPresent(Bool.self, forKey: .swapMouseButtons) ?? defaults.swapMouseButtons,
            muteOnFocusLoss: try container.decodeIfPresent(Bool.self, forKey: .muteOnFocusLoss) ?? defaults.muteOnFocusLoss,
            backgroundGamepad: try container.decodeIfPresent(Bool.self, forKey: .backgroundGamepad) ?? defaults.backgroundGamepad,
            reverseScrollDirection: try container.decodeIfPresent(Bool.self, forKey: .reverseScrollDirection) ?? defaults.reverseScrollDirection,
            swapFaceButtons: try container.decodeIfPresent(Bool.self, forKey: .swapFaceButtons) ?? defaults.swapFaceButtons,
            keepAwake: try container.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? defaults.keepAwake,
            packetSize: try container.decodeIfPresent(Int.self, forKey: .packetSize) ?? defaults.packetSize,
            audioConfiguration: try container.decodeIfPresent(AudioConfiguration.self, forKey: .audioConfiguration) ?? defaults.audioConfiguration,
            videoCodecPreference: try container.decodeIfPresent(VideoCodecPreference.self, forKey: .videoCodecPreference) ?? defaults.videoCodecPreference,
            enableHDR: try container.decodeIfPresent(Bool.self, forKey: .enableHDR) ?? defaults.enableHDR,
            hdrTransferPreference: try container.decodeIfPresent(
                HDRTransferPreference.self,
                forKey: .hdrTransferPreference
            ) ?? defaults.hdrTransferPreference,
            enableYUV444: enableYUV444,
            videoDecoderPreference: try container.decodeIfPresent(VideoDecoderPreference.self, forKey: .videoDecoderPreference) ?? defaults.videoDecoderPreference,
            rendererPreference: try container.decodeIfPresent(RendererPreference.self, forKey: .rendererPreference) ?? defaults.rendererPreference,
            windowMode: try container.decodeIfPresent(WindowMode.self, forKey: .windowMode) ?? defaults.windowMode,
            uiDisplayMode: try container.decodeIfPresent(UIDisplayMode.self, forKey: .uiDisplayMode) ?? defaults.uiDisplayMode,
            language: try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? defaults.language,
            captureSystemKeysMode: try container.decodeIfPresent(CaptureSystemKeysMode.self, forKey: .captureSystemKeysMode) ?? defaults.captureSystemKeysMode,
            displaySelection: try container.decodeIfPresent(DisplaySelection.self, forKey: .displaySelection) ?? defaults.displaySelection,
            displayResolutionPolicy: try container.decodeIfPresent(DisplayResolutionPolicy.self, forKey: .displayResolutionPolicy) ?? defaults.displayResolutionPolicy
        )
    }

    public static func defaultBitrateKbps(width: Int, height: Int, fps: Int, yuv444: Bool) -> Int {
        defaultBitrateKbps(
            width: width,
            height: height,
            fps: Double(fps),
            yuv444: yuv444
        )
    }

    public static func defaultBitrateKbps(
        width: Int,
        height: Int,
        fps: Double,
        yuv444: Bool
    ) -> Int {
        let safeFPS = fps.isFinite ? max(fps, 1) : 1
        let frameRateFactor = (safeFPS <= 60
            ? safeFPS
            : sqrt(safeFPS / 60) * 60) / 30
        let table: [(pixels: Double, factor: Double)] = [
            (Double(640 * 360), 1),
            (Double(854 * 480), 2),
            (Double(1_280 * 720), 5),
            (Double(1_920 * 1_080), 10),
            (Double(2_560 * 1_440), 20),
            (Double(3_840 * 2_160), 40),
        ]
        let pixels = Double(max(width, 0)) * Double(max(height, 0))
        let baseFactor: Double
        if pixels <= table[0].pixels {
            baseFactor = table[0].factor
        } else if pixels >= table[table.count - 1].pixels {
            baseFactor = table[table.count - 1].factor
        } else {
            let upperIndex = table.firstIndex { pixels <= $0.pixels }!
            let lower = table[upperIndex - 1]
            let upper = table[upperIndex]
            let position = (pixels - lower.pixels) / (upper.pixels - lower.pixels)
            baseFactor = lower.factor + position * (upper.factor - lower.factor)
        }
        let resolutionFactor = yuv444 ? baseFactor * 2 : baseFactor
        let megabits = max((resolutionFactor * frameRateFactor).rounded(), 1)
        guard megabits < Double(Int.max / 1_000) else { return Int.max }
        return Int(megabits) * 1_000
    }

    public var exactFrameRate: Double {
        guard frameRateDenominator > 0 else { return Double(fps) }
        return Double(frameRateNumerator) / Double(frameRateDenominator)
    }

    /// The reduced refresh fraction used by streaming transports.
    public var normalizedFrameRate: (numerator: UInt32, denominator: UInt32)? {
        guard let numerator = UInt64(exactly: frameRateNumerator),
              let denominator = UInt64(exactly: frameRateDenominator),
              numerator > 0,
              denominator > 0 else {
            return nil
        }
        let divisor = Self.greatestCommonDivisor(numerator, denominator)
        guard let normalizedNumerator = UInt32(exactly: numerator / divisor),
              let normalizedDenominator = UInt32(exactly: denominator / divisor) else {
            return nil
        }
        return (normalizedNumerator, normalizedDenominator)
    }

    /// Checks the canonical 10...480 Hz contract without multiplication or floating point.
    public static func isSupportedFrameRate(numerator: Int, denominator: Int) -> Bool {
        guard let numerator = UInt64(exactly: numerator),
              let denominator = UInt64(exactly: denominator),
              numerator > 0,
              denominator > 0 else {
            return false
        }
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        let withinLowerBound = quotient >= UInt64(minimumFrameRate)
        let withinUpperBound = quotient < UInt64(maximumFrameRate)
            || (quotient == UInt64(maximumFrameRate) && remainder == 0)
        let divisor = greatestCommonDivisor(numerator, denominator)
        return withinLowerBound
            && withinUpperBound
            && UInt32(exactly: numerator / divisor) != nil
            && UInt32(exactly: denominator / divisor) != nil
    }

    public mutating func setFrameRate(numerator: Int, denominator: Int) {
        fps = Self.roundedFramesPerSecond(
            numerator: numerator,
            denominator: denominator,
            fallback: fps
        )
        frameRateNumerator = numerator
        frameRateDenominator = denominator
    }

    private static func roundedFramesPerSecond(
        numerator: Int,
        denominator: Int,
        fallback: Int
    ) -> Int {
        guard let numerator = UInt64(exactly: numerator),
              let denominator = UInt64(exactly: denominator),
              numerator > 0,
              denominator > 0 else {
            return fallback
        }
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        let roundsUp = remainder != 0 && remainder >= denominator - remainder
        return Int(exactly: quotient + (roundsUp ? 1 : 0)) ?? fallback
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var lhs = lhs
        var rhs = rhs
        while rhs != 0 {
            (lhs, rhs) = (rhs, lhs % rhs)
        }
        return lhs
    }

    public func validate() throws {
        guard !clientMicrophoneRequired || clientMicrophoneEnabled else {
            throw ModelValidationError(
                field: "preferences.clientMicrophoneRequired",
                reason: "requires client microphone forwarding to be enabled"
            )
        }
        guard (0...100_000).contains(lspCompetitionCapacityMbps),
              lspNetworkProfile != .competitionLAN || lspCompetitionCapacityMbps > 0 else {
            throw ModelValidationError(
                field: "preferences.lspCompetitionCapacityMbps",
                reason: "competition mode requires an explicit positive capacity ceiling"
            )
        }
        guard (125...16_000).contains(lspPointerRate) else {
            throw ModelValidationError(field: "preferences.lspPointerRate", reason: "must be between 125 and 16000")
        }
        guard (125...2_000).contains(lspControllerRate) else {
            throw ModelValidationError(field: "preferences.lspControllerRate", reason: "must be between 125 and 2000")
        }
        guard (125...4_000).contains(lspSensorRate) else {
            throw ModelValidationError(field: "preferences.lspSensorRate", reason: "must be between 125 and 4000")
        }
        guard (50...1_000).contains(lspReconciliationRate) else {
            throw ModelValidationError(field: "preferences.lspReconciliationRate", reason: "must be between 50 and 1000")
        }
        guard (Self.minimumStreamWidth...Self.maximumStreamWidth).contains(width),
              width.isMultiple(of: 2) else {
            throw ModelValidationError(
                field: "preferences.width",
                reason: "must be an even value between 320 and 7680"
            )
        }
        guard (Self.minimumStreamHeight...Self.maximumStreamHeight).contains(height),
              height.isMultiple(of: 2) else {
            throw ModelValidationError(
                field: "preferences.height",
                reason: "must be an even value between 200 and 4320"
            )
        }
        guard (Self.minimumFrameRate...Self.maximumFrameRate).contains(fps) else {
            throw ModelValidationError(field: "preferences.fps", reason: "must be between 10 and 480")
        }
        guard Self.isSupportedFrameRate(
                  numerator: frameRateNumerator,
                  denominator: frameRateDenominator
              ),
              normalizedFrameRate != nil,
              fps == Self.roundedFramesPerSecond(
                  numerator: frameRateNumerator,
                  denominator: frameRateDenominator,
                  fallback: fps
              ) else {
            throw ModelValidationError(
                field: "preferences.frameRate",
                reason: "must be an exact positive fraction between 10 and 480 FPS"
            )
        }
        let isReferenceAutomaticBitrate = autoAdjustBitrate
            && bitrateKbps == Self.defaultBitrateKbps(
                width: width,
                height: height,
                fps: exactFrameRate,
                yuv444: enableYUV444
            )
        let isWithinManualLimit = bitrateKbps <= (unlockBitrate ? Self.maximumBitrateKbps : 150_000)
        guard bitrateKbps >= Self.minimumBitrateKbps,
              bitrateKbps <= Self.maximumBitrateKbps,
              isWithinManualLimit || isReferenceAutomaticBitrate else {
            throw ModelValidationError(
                field: "preferences.bitrateKbps",
                reason: "must be between 1000 and \(unlockBitrate ? Self.maximumBitrateKbps : 150_000), or the automatic reference bitrate"
            )
        }
        guard packetSize == 0 || (1_024...65_507).contains(packetSize) else {
            throw ModelValidationError(field: "preferences.packetSize", reason: "must be zero (automatic) or between 1024 and 65507")
        }
        guard rendererPreference != .probeOnly else {
            throw ModelValidationError(field: "preferences.rendererPreference", reason: "probeOnly cannot be saved as a user preference")
        }
        guard fidelityPreference != .codecLosslessRequired || optimizationMode == .quality else {
            throw ModelValidationError(
                field: "preferences.fidelityPreference",
                reason: "codecLosslessRequired is available only in Quality mode"
            )
        }
    }

    public func validated() throws -> Self {
        try validate()
        return self
    }
}
