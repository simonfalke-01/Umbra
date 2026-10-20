import Foundation
import UmbraCore
import UmbraMedia
import UmbraOpus
import UmbraServices
import UmbraStreaming

struct StreamingAudioBufferingPolicy: Equatable, Sendable {
    let outputBufferDuration: TimeInterval
    let minimumPreRollDuration: TimeInterval

    static func resolve(for mode: StreamOptimizationMode) -> Self {
        switch mode {
        case .latency:
            // Three 5 ms physical blocks retain AudioQueue's stable handoff while
            // a two-block refill barrier prevents single-quantum restart thrash.
            Self(outputBufferDuration: 0.005, minimumPreRollDuration: 0.010)
        case .quality:
            Self(outputBufferDuration: 0.015, minimumPreRollDuration: 0.030)
        }
    }
}

public final class VideoFrameReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var presentationProxyFrame = false

    public init() {}

    public var hasPresentationProxyFrame: Bool { lock.withLock { presentationProxyFrame } }
    public func markPresentationProxyFrame() { lock.withLock { presentationProxyFrame = true } }

    /// Compatibility spelling retained at the session-driver boundary. The evidence is now a
    /// renderer presentation proxy, not merely a VideoToolbox callback.
    public var hasDecodedFrame: Bool { hasPresentationProxyFrame }
    public func markDecodedFrame() { markPresentationProxyFrame() }
}

public struct StreamingMediaPipeline: Sendable {
    public let videoDecoder: any UmbraStreaming.VideoDecoding
    public let audioDecoder: any UmbraStreaming.AudioDecoding
    public let availableVideoFormats: Int32
    public let videoFrameReadiness: VideoFrameReadiness
    private let videoStatisticsProvider: @Sendable () -> MediaPipelineStatistics?
    private let audioStatisticsProvider: @Sendable () -> AudioRendererStatistics?

    public init(
        videoDecoder: any UmbraStreaming.VideoDecoding,
        audioDecoder: any UmbraStreaming.AudioDecoding,
        availableVideoFormats: Int32,
        videoFrameReadiness: VideoFrameReadiness = VideoFrameReadiness(),
        videoStatisticsProvider: @escaping @Sendable () -> MediaPipelineStatistics? = { nil },
        audioStatisticsProvider: @escaping @Sendable () -> AudioRendererStatistics? = { nil }
    ) {
        self.videoDecoder = videoDecoder
        self.audioDecoder = audioDecoder
        self.availableVideoFormats = availableVideoFormats
        self.videoFrameReadiness = videoFrameReadiness
        self.videoStatisticsProvider = videoStatisticsProvider
        self.audioStatisticsProvider = audioStatisticsProvider
    }

    public func videoStatistics() -> MediaPipelineStatistics? {
        videoStatisticsProvider()
    }

    public func audioStatistics() -> AudioRendererStatistics? {
        audioStatisticsProvider()
    }

    /// Releases a pipeline that was prepared locally but never transferred to
    /// the native streaming session.
    public func cleanUp() {
        videoDecoder.cleanUp()
        audioDecoder.cleanUp()
    }
}

public protocol StreamingMediaProviding: Sendable {
    func makePipeline(for bootstrap: StreamBootstrap) throws -> StreamingMediaPipeline
    func makePipeline(
        for bootstrap: StreamBootstrap,
        telemetryClient: StreamingTelemetryClient
    ) throws -> StreamingMediaPipeline
}

public extension StreamingMediaProviding {
    func makePipeline(
        for bootstrap: StreamBootstrap,
        telemetryClient: StreamingTelemetryClient
    ) throws -> StreamingMediaPipeline {
        _ = telemetryClient
        return try makePipeline(for: bootstrap)
    }
}

/// Converts the bridge-owned streaming values into UmbraMedia's richer native
/// VideoToolbox pipeline contract without sharing borrowed C buffers.
public final class NativeVideoDecoderAdapter: UmbraStreaming.VideoDecoding, UmbraStreaming.VideoCodecInitializationPreparing, UmbraStreaming.HDRMetadataReceiving, UmbraStreaming.VideoDecodeOutcomeReporting, @unchecked Sendable {
    private let decoder: any UmbraMedia.VideoDecoding

    public init(decoder: any UmbraMedia.VideoDecoding) {
        self.decoder = decoder
    }

    public func configure(format: UmbraStreaming.VideoStreamFormat) -> Bool {
        decoder.configure(format: UmbraMedia.VideoStreamFormat(
            codecMask: format.codecMask,
            width: format.width,
            height: format.height,
            redrawRate: format.redrawRate,
            flags: format.flags
        ))
    }

    public func start() { decoder.start() }
    public func stop() { decoder.stop() }
    public func cleanUp() { decoder.cleanUp() }

    public func prepareCodecInitialization(
        _ data: Data,
        payloadFormat: UmbraStreaming.EncodedVideoPayloadFormat
    ) -> Bool {
        guard let decoder = decoder as? any UmbraMedia.VideoCodecInitializationPreparing else {
            return false
        }
        let nativePayloadFormat: UmbraMedia.EncodedVideoPayloadFormat = switch payloadFormat {
        case .annexB: .annexB
        case .videoToolboxLengthPrefixed: .videoToolboxLengthPrefixed
        case .av1LowOverheadOBU: .av1LowOverheadOBU
        }
        return decoder.prepareCodecInitialization(data, payloadFormat: nativePayloadFormat)
    }

    public func setHDRMode(
        enabled: Bool,
        metadata: UmbraStreaming.StreamingHDRMetadata?
    ) {
        (decoder as? any UmbraMedia.HDRMetadataReceiving)?.setHDRMode(
            enabled: enabled,
            metadata: enabled ? metadata.map(HDRStaticMetadata.init(streaming:)) : nil
        )
    }

    public func submit(frame: UmbraStreaming.CompressedVideoFrame) -> UmbraStreaming.VideoFrameDisposition {
        let payloadFormat: UmbraMedia.EncodedVideoPayloadFormat = switch frame.payloadFormat {
        case .annexB: .annexB
        case .videoToolboxLengthPrefixed: .videoToolboxLengthPrefixed
        case .av1LowOverheadOBU: .av1LowOverheadOBU
        }
        let disposition = decoder.submit(frame: UmbraMedia.CompressedVideoFrame(
            data: frame.data,
            payloadFormat: payloadFormat,
            frameNumber: frame.frameNumber,
            isKeyFrame: frame.isKeyFrame,
            requiresIndependentDecode: frame.requiresIndependentDecode,
            hostProcessingLatencyTenthsOfMillisecond: frame.hostProcessingLatencyTenthsOfMillisecond,
            receiveTimeMicroseconds: frame.receiveTimeMicroseconds,
            enqueueTimeMicroseconds: frame.enqueueTimeMicroseconds,
            presentationTimeMicroseconds: frame.presentationTimeMicroseconds,
            rtpTimestamp: frame.rtpTimestamp,
            isHDR: frame.isHDR,
            colorSpace: frame.colorSpace,
            hostCaptureTimeMicroseconds: frame.hostCaptureTimeMicroseconds,
            appliedInputStateSequence: frame.appliedInputStateSequence,
            appliedInputEdgeID: frame.appliedInputEdgeID,
            videoConfigurationGeneration: frame.videoConfigurationGeneration
        ))
        return Self.streamingDisposition(for: disposition)
    }

    public func installDecodeOutcomeHandler(
        _ handler: @escaping @Sendable (UmbraStreaming.VideoDecodeOutcome) -> Void
    ) {
        (decoder as? any UmbraMedia.VideoDecodeOutcomeReporting)?.installDecodeOutcomeHandler { outcome in
            switch outcome {
            case let .decoded(frameNumber): handler(.decoded(frameNumber: frameNumber))
            case let .failed(frameNumber): handler(.failed(frameNumber: frameNumber))
            }
        }
    }

    static func streamingDisposition(
        for disposition: UmbraMedia.VideoFrameDisposition
    ) -> UmbraStreaming.VideoFrameDisposition {
        disposition == .accepted ? .accepted : .requestKeyFrame
    }
}

extension HDRStaticMetadata {
    init(streaming metadata: UmbraStreaming.StreamingHDRMetadata) {
        self.init(
            minimumLuminanceNits: metadata.minimumDisplayLuminanceTenThousandthsOfNit > 0
                ? Float(metadata.minimumDisplayLuminanceTenThousandthsOfNit) / 10_000
                : nil,
            maximumLuminanceNits: metadata.maximumDisplayLuminanceNits > 0
                ? Float(metadata.maximumDisplayLuminanceNits)
                : nil,
            maximumContentLightLevelNits: metadata.maximumContentLightLevelNits > 0
                ? Float(metadata.maximumContentLightLevelNits)
                : nil,
            maximumFrameAverageLightLevelNits: metadata.maximumFrameAverageLightLevelNits > 0
                ? Float(metadata.maximumFrameAverageLightLevelNits)
                : nil,
            masteringDisplayColorVolume: Self.masteringDisplayData(metadata),
            contentLightLevelInfo: Self.contentLightData(metadata),
            transferFunction: metadata.transfer == .hlg ? .hlg : .pq
        )
    }

    private static func masteringDisplayData(
        _ metadata: UmbraStreaming.StreamingHDRMetadata
    ) -> Data? {
        guard metadata.redX != 0, metadata.maximumDisplayLuminanceNits != 0 else { return nil }
        var bytes: [UInt8] = []
        // HEVC MDCV is GBR order; Lumen exposes RGB order.
        for value in [
            metadata.greenX, metadata.greenY,
            metadata.blueX, metadata.blueY,
            metadata.redX, metadata.redY,
            metadata.whiteX, metadata.whiteY,
        ] {
            bytes.append(UInt8(value >> 8))
            bytes.append(UInt8(value & 0xFF))
        }
        let maximum = UInt32(metadata.maximumDisplayLuminanceNits) * 10_000
        let minimum = UInt32(metadata.minimumDisplayLuminanceTenThousandthsOfNit)
        for value in [maximum, minimum] {
            bytes.append(UInt8((value >> 24) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        }
        return Data(bytes)
    }

    private static func contentLightData(
        _ metadata: UmbraStreaming.StreamingHDRMetadata
    ) -> Data? {
        guard metadata.maximumContentLightLevelNits != 0,
              metadata.maximumFrameAverageLightLevelNits != 0 else { return nil }
        var bytes: [UInt8] = []
        for value in [
            metadata.maximumContentLightLevelNits,
            metadata.maximumFrameAverageLightLevelNits,
        ] {
            bytes.append(UInt8(value >> 8))
            bytes.append(UInt8(value & 0xFF))
        }
        return Data(bytes)
    }
}

/// Converts owned Opus packets from the C bridge into the native audio decoder
/// contract. A concrete Opus decoder must be supplied; the adapter never drops
/// packets while reporting successful configuration.
public final class NativeAudioDecoderAdapter: UmbraStreaming.AudioDecoding, UmbraStreaming.AudioDiscontinuityHandling, @unchecked Sendable {
    private let decoder: any UmbraMedia.AudioDecoding

    public init(decoder: any UmbraMedia.AudioDecoding) {
        self.decoder = decoder
    }

    public func configure(format: UmbraStreaming.OpusStreamFormat) -> Bool {
        decoder.configure(format: UmbraMedia.OpusStreamFormat(
            audioConfiguration: format.audioConfiguration,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            streamCount: format.streamCount,
            coupledStreamCount: format.coupledStreamCount,
            samplesPerFrame: format.samplesPerFrame,
            mapping: format.mapping,
            flags: format.flags
        ))
    }

    public func start() { decoder.start() }
    public func stop() { decoder.stop() }
    public func cleanUp() { decoder.cleanUp() }

    public func submit(packet: UmbraStreaming.CompressedAudioPacket) {
        decoder.submit(packet: UmbraMedia.CompressedAudioPacket(data: packet.data))
    }

    public func handleAudioDiscontinuity() -> Bool {
        guard let handler = decoder as? any UmbraMedia.AudioDiscontinuityHandling else {
            return false
        }
        do {
            try handler.resetForDiscontinuity()
            return true
        } catch {
            return false
        }
    }
}

/// Builds the native VideoToolbox side of a media pipeline and requires a real
/// Opus decoder and output capability before streaming can begin.
public struct AppleStreamingMediaProvider: StreamingMediaProviding, Sendable {
    struct VideoDecoderConfiguration: Equatable {
        /// the client's separate decode-unit queue in VideoDepacketizer.c.
        let upstreamGameStreamQueueCapacity: Int
        let policy: VideoDecoderPolicy
        let maximumOutstandingFrames: Int
        let capacityPolicy: VideoDecodeCapacityPolicy
        let rendererQueueDepth: Int

        var backlogDiagnostic: String {
            "Video backlog capacities: compressed GameStream=\(upstreamGameStreamQueueCapacity), "
                + "Swift/VideoToolbox in-flight capacity=\(maximumOutstandingFrames), "
                + "renderer capacity=\(rendererQueueDepth)."
        }
    }

    public let capabilities: UmbraMedia.AppleStreamingCapabilities
    public let audioSessionController: NativeAudioSessionController
    private let renderer: (any UmbraMedia.MetalVideoRendering)?
    private let audioRenderer: (any PCMRendering)?
    private let audioRendererFactory: (@Sendable (PCMRendererConfiguration) throws -> any PCMRendering)?
    private let audioDecoder: (any UmbraMedia.AudioDecoding)?
    private let diagnosticHandler: @Sendable (String) -> Void

    public init(
        capabilities: UmbraMedia.AppleStreamingCapabilities = .probe(),
        renderer: (any UmbraMedia.MetalVideoRendering)?,
        audioRenderer: (any PCMRendering)? = nil,
        audioRendererFactory: (@Sendable (PCMRendererConfiguration) throws -> any PCMRendering)? = nil,
        audioDecoder: (any UmbraMedia.AudioDecoding)? = nil,
        audioSessionController: NativeAudioSessionController = NativeAudioSessionController(),
        diagnosticHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.capabilities = capabilities
        self.audioSessionController = audioSessionController
        self.renderer = renderer
        self.audioRenderer = audioRenderer
        self.audioRendererFactory = audioRendererFactory
        self.audioDecoder = audioDecoder
        self.diagnosticHandler = diagnosticHandler
    }

    public func makePipeline(for bootstrap: StreamBootstrap) throws -> StreamingMediaPipeline {
        try makePipeline(for: bootstrap, telemetryClient: .umbraLegacy)
    }

    public func makePipeline(
        for bootstrap: StreamBootstrap,
        telemetryClient: StreamingTelemetryClient
    ) throws -> StreamingMediaPipeline {
        try bootstrap.preferences.validate()
        switch bootstrap.preferences.rendererPreference {
        case .automatic, .metal, .avSampleBufferDisplayLayer:
            break
        case .probeOnly, .vulkan:
            throw UmbraIntegrationError.unsupportedRendererConfiguration(
                bootstrap.preferences.rendererPreference
            )
        }
        guard let renderer else {
            throw UmbraIntegrationError.videoRendererUnavailable
        }
        let availableFormats = try Self.availableVideoFormats(
            preferences: bootstrap.preferences,
            capabilities: capabilities
        )
        guard capabilities.hasDefaultAudioOutput, capabilities.supportsNativeAudioOutput else {
            throw UmbraIntegrationError.audioOutputUnavailable
        }

        let decoderConfiguration = Self.videoDecoderConfiguration(for: bootstrap.effectivePolicy)
        diagnosticHandler(decoderConfiguration.backlogDiagnostic)
        let videoFrameReadiness = VideoFrameReadiness()
        let telemetryProfile: StreamingTelemetryProfile = switch bootstrap.effectivePolicy.mode {
        case .latency: .latency
        case .quality: .quality
        }
        renderer.installTelemetryProfile(telemetryProfile)
        renderer.installTelemetryClient(telemetryClient)
        renderer.installFirstPresentationProxyHandler { [diagnosticHandler, videoFrameReadiness] frameNumber in
            videoFrameReadiness.markPresentationProxyFrame()
            diagnosticHandler("Renderer reached a presentation proxy for frame \(frameNumber); this is not scanout evidence.")
        }
        let videoDecoder = VideoToolboxDecoder(
            renderer: renderer,
            policy: decoderConfiguration.policy,
            maximumOutstandingFrames: decoderConfiguration.maximumOutstandingFrames,
            capacityPolicy: decoderConfiguration.capacityPolicy,
            telemetryProfile: telemetryProfile,
            telemetryClient: telemetryClient,
            errorHandler: { [diagnosticHandler] error in
                diagnosticHandler("Video decoder: \(error.description)")
            },
            firstFrameHandler: { [diagnosticHandler] frameNumber in
                diagnosticHandler("Video decoder produced frame \(frameNumber).")
            },
            firstFrameMetadataHandler: { [diagnosticHandler] color, pixelFormat in
                diagnosticHandler(
                    "First frame color: space=\(color.colorSpace), range=\(color.range), "
                        + "transfer=\(color.transferFunction), hdr=\(color.isHDR), "
                        + "pixelFormat=0x\(String(pixelFormat, radix: 16)), "
                        + "masteringMetadata=\(color.hdrStaticMetadata?.masteringDisplayColorVolume != nil), "
                        + "contentLightMetadata=\(color.hdrStaticMetadata?.contentLightLevelInfo != nil)."
                )
            }
        )
        let audioDecoder: any UmbraMedia.AudioDecoding
        var audioStatisticsProvider: @Sendable () -> AudioRendererStatistics? = { nil }
        if let configuredDecoder = self.audioDecoder {
            audioDecoder = configuredDecoder
        } else {
            let layout = Self.audioLayout(bootstrap.preferences.audioConfiguration)
            let audioBuffering = StreamingAudioBufferingPolicy.resolve(
                for: bootstrap.effectivePolicy.mode
            )
            let configuration = PCMRendererConfiguration(
                sampleRate: 48_000,
                layout: layout,
                outputBufferDuration: audioBuffering.outputBufferDuration,
                minimumPreRollDuration: audioBuffering.minimumPreRollDuration,
                muteWhileInactive: bootstrap.preferences.muteOnFocusLoss
            )
            let configuredRenderer: any PCMRendering
            do {
                if let audioRenderer = self.audioRenderer {
                    configuredRenderer = audioRenderer
                } else if let audioRendererFactory {
                    configuredRenderer = try audioRendererFactory(configuration)
                } else {
                    configuredRenderer = AudioQueuePCMRenderer(
                        configuration: configuration,
                        diagnosticHandler: { [diagnosticHandler] message in
                            diagnosticHandler(message)
                        }
                    )
                }
            } catch {
                throw UmbraIntegrationError.mediaConfigurationFailed(
                    "The audio renderer could not be created: \(error)"
                )
            }
            guard configuredRenderer.configuration.sampleRate == configuration.sampleRate,
                  configuredRenderer.configuration.layout == configuration.layout else {
                throw UmbraIntegrationError.mediaConfigurationFailed(
                    "The supplied audio renderer does not match the selected channel layout."
                )
            }
            audioSessionController.attach(configuredRenderer)
            do {
                // AudioQueue's initial buffers contain only zero-filled PCM. Starting the
                // real output during preparation lets virtual-device middleware finish its
                // graph transition before the first decoded Opus packet reaches the queue.
                try configuredRenderer.start()
            } catch {
                audioSessionController.detach(configuredRenderer)
                throw UmbraIntegrationError.mediaConfigurationFailed(
                    "The audio renderer could not start: \(error)"
                )
            }
            audioDecoder = ManagedOpusAudioDecoder(
                configuration: configuration,
                renderer: configuredRenderer,
                onCleanup: { [audioSessionController] renderer in
                    audioSessionController.detach(renderer)
                }
            )
            if let provider = configuredRenderer as? any AudioRendererStatisticsProviding {
                audioStatisticsProvider = { [provider] in provider.statistics }
            }
        }
        return StreamingMediaPipeline(
            videoDecoder: NativeVideoDecoderAdapter(decoder: videoDecoder),
            audioDecoder: NativeAudioDecoderAdapter(decoder: audioDecoder),
            availableVideoFormats: availableFormats,
            videoFrameReadiness: videoFrameReadiness,
            videoStatisticsProvider: { [videoDecoder] in videoDecoder.statistics() },
            audioStatisticsProvider: audioStatisticsProvider
        )
    }

    static func videoDecoderConfiguration(
        for policy: EffectiveStreamingPolicy
    ) -> VideoDecoderConfiguration {
        let decoderPolicy: VideoDecoderPolicy = switch policy.decoderIntent {
        case .automaticHardwarePreferred: .automatic
        case .hardwareOnly: .hardwareOnly
        case .softwareOnly: .softwareOnly
        }
        let capacityPolicy: VideoDecodeCapacityPolicy = switch policy.mode {
        case .latency: .dropNewestWhenFull
        case .quality: .waitWhenFull
        }
        return VideoDecoderConfiguration(
            upstreamGameStreamQueueCapacity: Int(
                StreamingConfiguration.clampedVideoDecodeQueueCapacity(
                    policy.maximumCompressedDecodeQueueFrames
                )
            ),
            policy: decoderPolicy,
            maximumOutstandingFrames: policy.maximumDecodeSubmissions,
            capacityPolicy: capacityPolicy,
            rendererQueueDepth: policy.rendererQueueDepth
        )
    }

    public static func availableVideoFormats(
        preferences: StreamingPreferences,
        capabilities: UmbraMedia.AppleStreamingCapabilities
    ) throws -> Int32 {
        var formats = capabilities.supportedVideoFormatMask
        if preferences.videoDecoderPreference == .software {
            // VideoToolbox provides system software fallbacks for AVC and HEVC on macOS.
            formats = 0x0101
        }
        guard formats != 0 else {
            throw UmbraIntegrationError.unsupportedVideoConfiguration(preferences.videoCodecPreference)
        }
        return formats
    }

    private static func audioLayout(_ configuration: AudioConfiguration) -> AudioOutputLayout {
        switch configuration {
        case .stereo: .stereo
        case .surround51: .surround51
        case .surround71: .surround71
        }
    }
}

private final class ManagedOpusAudioDecoder: UmbraMedia.AudioDecoding, UmbraMedia.AudioDiscontinuityHandling, @unchecked Sendable {
    private struct Resources {
        let renderer: any PCMRendering
        let decoder: OpusMultistreamDecoder
    }

    private enum State {
        case pending(any PCMRendering)
        case configuring(any PCMRendering)
        case active(Resources)
        case cleanedUp
    }

    private let configuration: PCMRendererConfiguration
    private let onCleanup: @Sendable (any PCMRendering) -> Void
    private let lock = NSLock()
    private var state: State

    init(
        configuration: PCMRendererConfiguration,
        renderer: any PCMRendering,
        onCleanup: @escaping @Sendable (any PCMRendering) -> Void
    ) {
        self.configuration = configuration
        self.onCleanup = onCleanup
        self.state = .pending(renderer)
    }

    deinit { finishCleanup() }

    func configure(format: UmbraMedia.OpusStreamFormat) -> Bool {
        let preparation: (renderer: (any PCMRendering)?, shouldConfigure: Bool) = lock.withLock {
            guard case let .pending(renderer) = state else { return (nil, false) }
            let formatMatchesConfiguration = format.sampleRate == Int(configuration.sampleRate)
                && AudioOutputLayout(audioConfiguration: format.audioConfiguration) == configuration.layout
                && format.channelCount == Int(configuration.layout.channelCount)
            guard formatMatchesConfiguration else {
                state = .cleanedUp
                return (renderer, false)
            }
            state = .configuring(renderer)
            return (renderer, true)
        }
        guard let renderer = preparation.renderer else { return false }
        guard preparation.shouldConfigure else {
            onCleanup(renderer)
            return false
        }

        let decoder = OpusMultistreamDecoder(renderer: renderer)
        guard decoder.configure(format: format) else {
            finishFailedConfiguration(decoder: decoder, renderer: renderer)
            return false
        }

        let activated = lock.withLock { () -> Bool in
            guard case let .configuring(candidate) = state, candidate === renderer else {
                return false
            }
            state = .active(Resources(renderer: renderer, decoder: decoder))
            return true
        }
        guard activated else {
            decoder.cleanUp()
            return false
        }
        return true
    }

    func start() { withResources { $0.decoder.start() } }

    func stop() {
        withResources { $0.decoder.stop() }
    }

    func cleanUp() {
        finishCleanup()
    }

    func submit(packet: UmbraMedia.CompressedAudioPacket) {
        withResources { $0.decoder.submit(packet: packet) }
    }

    func resetForDiscontinuity() throws {
        let resources = lock.withLock { () -> Resources? in
            guard case let .active(resources) = state else { return nil }
            return resources
        }
        guard let resources else { throw OpusDecoderError.notConfigured }
        try resources.decoder.resetForDiscontinuity()
    }

    private func finishCleanup() {
        let cleanup = lock.withLock { () -> (Resources?, (any PCMRendering)?) in
            switch state {
            case let .pending(renderer), let .configuring(renderer):
                state = .cleanedUp
                return (nil, renderer)
            case let .active(resources):
                state = .cleanedUp
                return (resources, resources.renderer)
            case .cleanedUp:
                return (nil, nil)
            }
        }
        cleanup.0?.decoder.cleanUp()
        if let renderer = cleanup.1 { onCleanup(renderer) }
    }

    private func withResources(_ operation: (Resources) -> Void) {
        lock.lock()
        guard case let .active(resources) = state else {
            lock.unlock()
            return
        }
        operation(resources)
        lock.unlock()
    }

    private func finishFailedConfiguration(
        decoder: OpusMultistreamDecoder,
        renderer: any PCMRendering
    ) {
        decoder.cleanUp()
        let shouldCleanUp = lock.withLock { () -> Bool in
            guard case let .configuring(candidate) = state, candidate === renderer else {
                return false
            }
            state = .cleanedUp
            return true
        }
        if shouldCleanUp { onCleanup(renderer) }
    }
}
