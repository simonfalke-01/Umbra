import AVFAudio
import CoreMedia
import CoreVideo
import Foundation

/// Immutable codec negotiation passed from moonlight-common-c to the native decoder.
public struct VideoStreamFormat: Sendable, Equatable {
    public let codecMask: Int32
    public let width: Int
    public let height: Int
    public let redrawRate: Int
    public let flags: Int32
    public let colorRange: VideoColorRange
    public let requiresExactDecodedFormat: Bool
    public let colorPrimariesCode: UInt8?
    public let transferCharacteristicsCode: UInt8?
    public let matrixCoefficientsCode: UInt8?

    public init(
        codecMask: Int32,
        width: Int,
        height: Int,
        redrawRate: Int,
        flags: Int32 = 0,
        colorRange: VideoColorRange = .full,
        requiresExactDecodedFormat: Bool = false,
        colorPrimariesCode: UInt8? = nil,
        transferCharacteristicsCode: UInt8? = nil,
        matrixCoefficientsCode: UInt8? = nil
    ) {
        self.codecMask = codecMask
        self.width = width
        self.height = height
        self.redrawRate = redrawRate
        self.flags = flags
        self.colorRange = colorRange
        self.requiresExactDecodedFormat = requiresExactDecodedFormat
        self.colorPrimariesCode = colorPrimariesCode
        self.transferCharacteristicsCode = transferCharacteristicsCode
        self.matrixCoefficientsCode = matrixCoefficientsCode
    }
}

public enum EncodedVideoPayloadFormat: Sendable, Equatable {
    case annexB
    case videoToolboxLengthPrefixed
    case av1LowOverheadOBU
}

/// An owned encoded access unit in the explicitly declared payload format.
public struct CompressedVideoFrame: Sendable, Equatable {
    public let data: Data
    public let payloadFormat: EncodedVideoPayloadFormat
    public let frameNumber: Int
    public let isKeyFrame: Bool
    public let requiresIndependentDecode: Bool
    public let hostProcessingLatencyTenthsOfMillisecond: UInt16
    public let receiveTimeMicroseconds: UInt64
    public let enqueueTimeMicroseconds: UInt64
    public let presentationTimeMicroseconds: UInt64
    public let rtpTimestamp: UInt32
    public let isHDR: Bool
    public let colorSpace: UInt8
    public let isFullRange: Bool
    public let hostCaptureTimeMicroseconds: UInt64
    public let appliedInputStateSequence: UInt64
    public let appliedInputEdgeID: UInt64
    public let videoConfigurationGeneration: UInt32

    public init(
        data: Data,
        payloadFormat: EncodedVideoPayloadFormat = .annexB,
        frameNumber: Int,
        isKeyFrame: Bool,
        requiresIndependentDecode: Bool = false,
        hostProcessingLatencyTenthsOfMillisecond: UInt16 = 0,
        receiveTimeMicroseconds: UInt64 = 0,
        enqueueTimeMicroseconds: UInt64 = 0,
        presentationTimeMicroseconds: UInt64,
        rtpTimestamp: UInt32 = 0,
        isHDR: Bool = false,
        colorSpace: UInt8 = 1,
        isFullRange: Bool = true,
        hostCaptureTimeMicroseconds: UInt64 = 0,
        appliedInputStateSequence: UInt64 = 0,
        appliedInputEdgeID: UInt64 = 0,
        videoConfigurationGeneration: UInt32 = 0
    ) {
        self.data = data
        self.payloadFormat = payloadFormat
        self.frameNumber = frameNumber
        self.isKeyFrame = isKeyFrame
        self.requiresIndependentDecode = requiresIndependentDecode
        self.hostProcessingLatencyTenthsOfMillisecond = hostProcessingLatencyTenthsOfMillisecond
        self.receiveTimeMicroseconds = receiveTimeMicroseconds
        self.enqueueTimeMicroseconds = enqueueTimeMicroseconds
        self.presentationTimeMicroseconds = presentationTimeMicroseconds
        self.rtpTimestamp = rtpTimestamp
        self.isHDR = isHDR
        self.colorSpace = colorSpace
        self.isFullRange = isFullRange
        self.hostCaptureTimeMicroseconds = hostCaptureTimeMicroseconds
        self.appliedInputStateSequence = appliedInputStateSequence
        self.appliedInputEdgeID = appliedInputEdgeID
        self.videoConfigurationGeneration = videoConfigurationGeneration
    }
}

public enum VideoFrameDisposition: Int32, Sendable {
    case accepted = 0
    case requestKeyFrame = -1
    case capacityDropped = 1
}

/// Synchronous, thread-safe boundary used by the streaming callback bridge.
public protocol VideoDecoding: AnyObject, Sendable {
    func configure(format: VideoStreamFormat) -> Bool
    func start()
    func stop()
    func cleanUp()
    func submit(frame: CompressedVideoFrame) -> VideoFrameDisposition
}

/// Installs exact codec initialization and creates the VideoToolbox session
/// before a protocol configuration acknowledgement is emitted.
public protocol VideoCodecInitializationPreparing: AnyObject, Sendable {
    func prepareCodecInitialization(
        _ data: Data,
        payloadFormat: EncodedVideoPayloadFormat
    ) -> Bool
}

public enum VideoDecodeOutcome: Sendable, Equatable {
    case decoded(frameNumber: Int)
    case failed(frameNumber: Int)
}

public protocol VideoDecodeOutcomeReporting: AnyObject, Sendable {
    func installDecodeOutcomeHandler(
        _ handler: @escaping @Sendable (VideoDecodeOutcome) -> Void
    )
}

public protocol HDRMetadataReceiving: AnyObject, Sendable {
    func setHDRMode(enabled: Bool, metadata: HDRStaticMetadata?)
}

public enum VideoLatencyClockDomain: Sendable, Equatable {
    /// Core Animation's monotonic media-time clock used by VideoToolbox and Metal telemetry.
    case clientMediaTime
    /// Moonlight's client-local monotonic clock, whose epoch begins when its timing layer starts.
    case moonlightClientUptime
    /// The RTP presentation timeline. It may be synthesized from client receive time and is not
    /// evidence of host capture time or synchronized to either client monotonic clock.
    case streamPresentationTimeline
}

public struct VideoLatencyTimestamp: Sendable, Equatable {
    public let seconds: TimeInterval
    public let clockDomain: VideoLatencyClockDomain

    public init(seconds: TimeInterval, clockDomain: VideoLatencyClockDomain) {
        self.seconds = seconds
        self.clockDomain = clockDomain
    }

    /// Returns a duration only when both timestamps share a clock and move forwards.
    public func duration(to later: VideoLatencyTimestamp) -> TimeInterval? {
        guard clockDomain == later.clockDomain,
              seconds.isFinite,
              later.seconds.isFinite,
              later.seconds >= seconds else { return nil }
        return later.seconds - seconds
    }
}

/// Stable identity carried with one frame through a single decoder lifecycle.
/// Frame numbers may restart between streams, so the decoder generation is part of the identity.
public struct VideoFrameCorrelationID: Sendable, Equatable, Hashable {
    public let decoderGeneration: UInt64
    public let frameNumber: Int

    public init(decoderGeneration: UInt64, frameNumber: Int) {
        self.decoderGeneration = decoderGeneration
        self.frameNumber = frameNumber
    }
}

/// Calibrates two monotonic clocks with different epochs using the smallest observed offset.
///
/// Moonlight records receive/reassembly time on `PltGetMicroseconds()`, while the native media
/// pipeline uses `CACurrentMediaTime()`. Sampling at the Swift decoder boundary introduces a
/// non-negative delivery delay, so the smallest observed offset is the least-biased available
/// mapping. The resulting receive-to-decode measurement remains a calibrated client-side proxy.
public struct VideoLatencyClockMapping: Sendable, Equatable {
    public let sourceDomain: VideoLatencyClockDomain
    public let destinationDomain: VideoLatencyClockDomain
    public private(set) var minimumOffsetSeconds: TimeInterval?
    public private(set) var observationCount = 0

    public init(
        sourceDomain: VideoLatencyClockDomain,
        destinationDomain: VideoLatencyClockDomain
    ) {
        self.sourceDomain = sourceDomain
        self.destinationDomain = destinationDomain
    }

    public mutating func observe(
        source: VideoLatencyTimestamp,
        destination: VideoLatencyTimestamp
    ) {
        guard source.clockDomain == sourceDomain,
              destination.clockDomain == destinationDomain,
              source.seconds.isFinite,
              destination.seconds.isFinite else { return }
        let offset = destination.seconds - source.seconds
        minimumOffsetSeconds = min(minimumOffsetSeconds ?? offset, offset)
        observationCount += 1
    }

    public func map(_ timestamp: VideoLatencyTimestamp) -> VideoLatencyTimestamp? {
        guard timestamp.clockDomain == sourceDomain,
              timestamp.seconds.isFinite,
              let minimumOffsetSeconds else { return nil }
        return VideoLatencyTimestamp(
            seconds: timestamp.seconds + minimumOffsetSeconds,
            clockDomain: destinationDomain
        )
    }

    public mutating func reset() {
        minimumOffsetSeconds = nil
        observationCount = 0
    }

    public var evidence: VideoLatencyClockCalibrationEvidence? {
        guard let minimumOffsetSeconds else { return nil }
        return VideoLatencyClockCalibrationEvidence(
            sourceDomain: sourceDomain,
            destinationDomain: destinationDomain,
            observationCount: observationCount,
            estimatedOffsetSeconds: minimumOffsetSeconds,
            maximumErrorSeconds: nil
        )
    }
}

/// Per-frame clock-calibration evidence retained for future matched-event WAN accounting.
/// `maximumErrorSeconds` stays unavailable until a protocol exchange measures a defensible bound;
/// RTT and percentile summaries are never substituted for a per-event clock error bound.
public struct VideoLatencyClockCalibrationEvidence: Sendable, Equatable {
    public let sourceDomain: VideoLatencyClockDomain
    public let destinationDomain: VideoLatencyClockDomain
    public let observationCount: Int
    public let estimatedOffsetSeconds: TimeInterval
    public let maximumErrorSeconds: TimeInterval?

    public init(
        sourceDomain: VideoLatencyClockDomain,
        destinationDomain: VideoLatencyClockDomain,
        observationCount: Int,
        estimatedOffsetSeconds: TimeInterval,
        maximumErrorSeconds: TimeInterval?
    ) {
        self.sourceDomain = sourceDomain
        self.destinationDomain = destinationDomain
        self.observationCount = observationCount
        self.estimatedOffsetSeconds = estimatedOffsetSeconds
        self.maximumErrorSeconds = maximumErrorSeconds
    }
}

public struct VideoFrameLatencyMetadata: Sendable, Equatable {
    public let correlationID: VideoFrameCorrelationID?
    public let receiveClockCalibration: VideoLatencyClockCalibrationEvidence?
    public let hostProcessingDuration: TimeInterval?
    public let streamPresentationTime: VideoLatencyTimestamp?
    public let receiveTime: VideoLatencyTimestamp?
    public let reassemblyEnqueueTime: VideoLatencyTimestamp?
    public let videoToolboxSubmitTime: VideoLatencyTimestamp?
    public let videoToolboxDecodeCompletionTime: VideoLatencyTimestamp?
    public let rendererEnqueueTime: VideoLatencyTimestamp?
    public let hostCaptureTimeMicroseconds: UInt64?
    public let appliedInputStateSequence: UInt64
    public let appliedInputEdgeID: UInt64
    public let videoConfigurationGeneration: UInt32

    public init(
        correlationID: VideoFrameCorrelationID? = nil,
        receiveClockCalibration: VideoLatencyClockCalibrationEvidence? = nil,
        hostProcessingDuration: TimeInterval? = nil,
        streamPresentationTime: VideoLatencyTimestamp? = nil,
        receiveTime: VideoLatencyTimestamp? = nil,
        reassemblyEnqueueTime: VideoLatencyTimestamp? = nil,
        videoToolboxSubmitTime: VideoLatencyTimestamp? = nil,
        videoToolboxDecodeCompletionTime: VideoLatencyTimestamp? = nil,
        rendererEnqueueTime: VideoLatencyTimestamp? = nil,
        hostCaptureTimeMicroseconds: UInt64? = nil,
        appliedInputStateSequence: UInt64 = 0,
        appliedInputEdgeID: UInt64 = 0,
        videoConfigurationGeneration: UInt32 = 0
    ) {
        self.correlationID = correlationID
        self.receiveClockCalibration = receiveClockCalibration
        self.hostProcessingDuration = hostProcessingDuration
        self.streamPresentationTime = streamPresentationTime
        self.receiveTime = receiveTime
        self.reassemblyEnqueueTime = reassemblyEnqueueTime
        self.videoToolboxSubmitTime = videoToolboxSubmitTime
        self.videoToolboxDecodeCompletionTime = videoToolboxDecodeCompletionTime
        self.rendererEnqueueTime = rendererEnqueueTime
        self.hostCaptureTimeMicroseconds = hostCaptureTimeMicroseconds
        self.appliedInputStateSequence = appliedInputStateSequence
        self.appliedInputEdgeID = appliedInputEdgeID
        self.videoConfigurationGeneration = videoConfigurationGeneration
    }

    public func recordingDecodeCompletion(
        _ timestamp: VideoLatencyTimestamp
    ) -> VideoFrameLatencyMetadata {
        VideoFrameLatencyMetadata(
            correlationID: correlationID,
            receiveClockCalibration: receiveClockCalibration,
            hostProcessingDuration: hostProcessingDuration,
            streamPresentationTime: streamPresentationTime,
            receiveTime: receiveTime,
            reassemblyEnqueueTime: reassemblyEnqueueTime,
            videoToolboxSubmitTime: videoToolboxSubmitTime,
            videoToolboxDecodeCompletionTime: timestamp,
            rendererEnqueueTime: rendererEnqueueTime,
            hostCaptureTimeMicroseconds: hostCaptureTimeMicroseconds,
            appliedInputStateSequence: appliedInputStateSequence,
            appliedInputEdgeID: appliedInputEdgeID,
            videoConfigurationGeneration: videoConfigurationGeneration
        )
    }

    public func recordingRendererEnqueue(
        _ timestamp: VideoLatencyTimestamp
    ) -> VideoFrameLatencyMetadata {
        VideoFrameLatencyMetadata(
            correlationID: correlationID,
            receiveClockCalibration: receiveClockCalibration,
            hostProcessingDuration: hostProcessingDuration,
            streamPresentationTime: streamPresentationTime,
            receiveTime: receiveTime,
            reassemblyEnqueueTime: reassemblyEnqueueTime,
            videoToolboxSubmitTime: videoToolboxSubmitTime,
            videoToolboxDecodeCompletionTime: videoToolboxDecodeCompletionTime,
            rendererEnqueueTime: timestamp,
            hostCaptureTimeMicroseconds: hostCaptureTimeMicroseconds,
            appliedInputStateSequence: appliedInputStateSequence,
            appliedInputEdgeID: appliedInputEdgeID,
            videoConfigurationGeneration: videoConfigurationGeneration
        )
    }
}

public struct LatencyPercentileSummary: Sendable, Equatable {
    public let sampleCount: Int
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let p99Milliseconds: Double

    public init(
        sampleCount: Int,
        p50Milliseconds: Double,
        p95Milliseconds: Double,
        p99Milliseconds: Double
    ) {
        self.sampleCount = sampleCount
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.p99Milliseconds = p99Milliseconds
    }
}

public enum VideoPresentationProxyEvidence: Sendable, Equatable {
    /// CAMetalDisplayLink.Update.targetPresentationTimestamp. This is a compositor target,
    /// not evidence of physical display scanout.
    case displayLinkPresentationTarget
    /// The explicit Core Animation presentation time passed to Metal.
    case scheduledPresentationTime
    /// GPU command completion only. This is not physical display scanout evidence.
    case commandBufferCompletion
    /// The rolling window contains more than one kind of presentation proxy.
    case mixed
}

/// Streaming objective attached to one isolated telemetry window.
public enum StreamingTelemetryProfile: Sendable, Equatable {
    case unspecified
    case latency
    case quality
}

/// Client protocol matrix attached to one isolated telemetry window.
public enum StreamingTelemetryClient: Sendable, Equatable {
    case unspecified
    case umbraLegacy
    case umbraV2
    case umbraV3
}

public struct VideoLatencyStatistics: Sendable, Equatable {
    public let profile: StreamingTelemetryProfile
    public let client: StreamingTelemetryClient
    public let hostProcessing: LatencyPercentileSummary?
    public let receiveToVideoToolboxSubmit: LatencyPercentileSummary?
    public let reassemblyEnqueueToVideoToolboxSubmit: LatencyPercentileSummary?
    public let videoToolboxDecode: LatencyPercentileSummary?
    public let receiveToDecode: LatencyPercentileSummary?
    public let decodeToMetalCommit: LatencyPercentileSummary?
    public let metalCommitToPresentationProxy: LatencyPercentileSummary?
    public let presentationProxyEvidence: VideoPresentationProxyEvidence?
    public let missedPresentationDeadlines: UInt64
    public let unavailablePresentationProxySamples: UInt64

    public init(
        profile: StreamingTelemetryProfile = .unspecified,
        client: StreamingTelemetryClient = .unspecified,
        hostProcessing: LatencyPercentileSummary? = nil,
        receiveToVideoToolboxSubmit: LatencyPercentileSummary? = nil,
        reassemblyEnqueueToVideoToolboxSubmit: LatencyPercentileSummary? = nil,
        videoToolboxDecode: LatencyPercentileSummary? = nil,
        receiveToDecode: LatencyPercentileSummary? = nil,
        decodeToMetalCommit: LatencyPercentileSummary? = nil,
        metalCommitToPresentationProxy: LatencyPercentileSummary? = nil,
        presentationProxyEvidence: VideoPresentationProxyEvidence? = nil,
        missedPresentationDeadlines: UInt64 = 0,
        unavailablePresentationProxySamples: UInt64 = 0
    ) {
        self.profile = profile
        self.client = client
        self.hostProcessing = hostProcessing
        self.receiveToVideoToolboxSubmit = receiveToVideoToolboxSubmit
        self.reassemblyEnqueueToVideoToolboxSubmit = reassemblyEnqueueToVideoToolboxSubmit
        self.videoToolboxDecode = videoToolboxDecode
        self.receiveToDecode = receiveToDecode
        self.decodeToMetalCommit = decodeToMetalCommit
        self.metalCommitToPresentationProxy = metalCommitToPresentationProxy
        self.presentationProxyEvidence = presentationProxyEvidence
        self.missedPresentationDeadlines = missedPresentationDeadlines
        self.unavailablePresentationProxySamples = unavailablePresentationProxySamples
    }
}

public enum VideoLatencyStage: Sendable, Equatable {
    case hostProcessing
    case receiveToVideoToolboxSubmit
    case reassemblyEnqueueToVideoToolboxSubmit
    case videoToolboxDecode
    case receiveToDecode
    case decodeToMetalCommit
}

private struct BoundedLatencySampleWindow: Sendable {
    private var storage: [TimeInterval]
    private var count = 0
    private var nextIndex = 0

    init(capacity: Int) {
        storage = Array(repeating: 0, count: max(1, capacity))
    }

    mutating func record(_ duration: TimeInterval) {
        guard duration >= 0, duration.isFinite else { return }
        storage[nextIndex] = duration
        nextIndex = (nextIndex + 1) % storage.count
        count = min(count + 1, storage.count)
    }

    func snapshot() -> LatencyPercentileSummary? {
        guard count > 0 else { return nil }
        let sorted = Array(storage.prefix(count)).sorted()
        return LatencyPercentileSummary(
            sampleCount: count,
            p50Milliseconds: percentile(0.50, in: sorted) * 1_000,
            p95Milliseconds: percentile(0.95, in: sorted) * 1_000,
            p99Milliseconds: percentile(0.99, in: sorted) * 1_000
        )
    }

    private func percentile(_ quantile: Double, in sorted: [TimeInterval]) -> TimeInterval {
        let rank = max(1, Int(ceil(quantile * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}

private struct BoundedPresentationOutcomeWindow: Sendable {
    private struct Outcome: Sendable {
        let duration: TimeInterval?
        let evidence: VideoPresentationProxyEvidence?
        let missedPreferredTarget: Bool
    }

    private var storage: [Outcome?]
    private var count = 0
    private var nextIndex = 0

    init(capacity: Int) {
        storage = Array(repeating: nil, count: max(1, capacity))
    }

    mutating func record(
        duration: TimeInterval?,
        _ evidence: VideoPresentationProxyEvidence?,
        missedPreferredTarget: Bool = false
    ) {
        guard evidence != .mixed else { return }
        if let duration, (!duration.isFinite || duration < 0) { return }
        storage[nextIndex] = Outcome(
            duration: duration,
            evidence: evidence,
            missedPreferredTarget: missedPreferredTarget
        )
        nextIndex = (nextIndex + 1) % storage.count
        count = min(count + 1, storage.count)
    }

    var evidenceSummary: VideoPresentationProxyEvidence? {
        guard count > 0 else { return nil }
        var first: VideoPresentationProxyEvidence?
        for evidence in storage.prefix(count).compactMap({ $0?.evidence }) {
            if let first, first != evidence { return .mixed }
            first = evidence
        }
        return first
    }

    var latencySummary: LatencyPercentileSummary? {
        let sorted = storage.prefix(count)
            .compactMap { $0?.duration }
            .sorted()
        guard !sorted.isEmpty else { return nil }
        func percentile(_ quantile: Double) -> TimeInterval {
            let rank = max(1, Int(ceil(quantile * Double(sorted.count))))
            return sorted[min(rank - 1, sorted.count - 1)]
        }
        return LatencyPercentileSummary(
            sampleCount: sorted.count,
            p50Milliseconds: percentile(0.50) * 1_000,
            p95Milliseconds: percentile(0.95) * 1_000,
            p99Milliseconds: percentile(0.99) * 1_000
        )
    }

    var missedPreferredTargetCount: UInt64 {
        UInt64(storage.prefix(count).compactMap({ $0 }).reduce(into: 0) { total, outcome in
            if outcome.missedPreferredTarget { total += 1 }
        })
    }

    var unavailableCount: UInt64 {
        UInt64(storage.prefix(count).compactMap({ $0 }).reduce(into: 0) { total, outcome in
            if outcome.duration == nil { total += 1 }
        })
    }
}

/// Fixed-capacity latency accumulator. Recording performs no allocation after initialization;
/// sorting and temporary allocation happen only when the once-per-second statistics snapshot runs.
public struct VideoLatencyStatisticsAccumulator: Sendable {
    private let sampleCapacity: Int
    private var profile: StreamingTelemetryProfile
    private var client: StreamingTelemetryClient
    private var hostProcessing: BoundedLatencySampleWindow
    private var receiveToVideoToolboxSubmit: BoundedLatencySampleWindow
    private var reassemblyEnqueueToVideoToolboxSubmit: BoundedLatencySampleWindow
    private var videoToolboxDecode: BoundedLatencySampleWindow
    private var receiveToDecode: BoundedLatencySampleWindow
    private var decodeToMetalCommit: BoundedLatencySampleWindow
    private var presentationOutcomes: BoundedPresentationOutcomeWindow

    public init(
        sampleCapacity: Int = 240,
        profile: StreamingTelemetryProfile = .unspecified,
        client: StreamingTelemetryClient = .unspecified
    ) {
        let capacity = max(1, sampleCapacity)
        self.sampleCapacity = capacity
        self.profile = profile
        self.client = client
        hostProcessing = BoundedLatencySampleWindow(capacity: capacity)
        receiveToVideoToolboxSubmit = BoundedLatencySampleWindow(capacity: capacity)
        reassemblyEnqueueToVideoToolboxSubmit = BoundedLatencySampleWindow(capacity: capacity)
        videoToolboxDecode = BoundedLatencySampleWindow(capacity: capacity)
        receiveToDecode = BoundedLatencySampleWindow(capacity: capacity)
        decodeToMetalCommit = BoundedLatencySampleWindow(capacity: capacity)
        presentationOutcomes = BoundedPresentationOutcomeWindow(capacity: capacity)
    }

    public mutating func record(_ stage: VideoLatencyStage, duration: TimeInterval) {
        switch stage {
        case .hostProcessing: hostProcessing.record(duration)
        case .receiveToVideoToolboxSubmit: receiveToVideoToolboxSubmit.record(duration)
        case .reassemblyEnqueueToVideoToolboxSubmit: reassemblyEnqueueToVideoToolboxSubmit.record(duration)
        case .videoToolboxDecode: videoToolboxDecode.record(duration)
        case .receiveToDecode: receiveToDecode.record(duration)
        case .decodeToMetalCommit: decodeToMetalCommit.record(duration)
        }
    }

    public mutating func record(
        from earlier: VideoLatencyTimestamp?,
        to later: VideoLatencyTimestamp?,
        stage: VideoLatencyStage
    ) {
        guard let earlier, let later, let duration = earlier.duration(to: later) else { return }
        record(stage, duration: duration)
    }

    @discardableResult
    public mutating func recordPresentationProxy(
        from commit: VideoLatencyTimestamp,
        to proxy: VideoLatencyTimestamp,
        evidence: VideoPresentationProxyEvidence,
        gpuCompletion: VideoLatencyTimestamp? = nil
    ) -> Bool {
        guard evidence != .mixed,
              let duration = commit.duration(to: proxy) else { return false }
        if evidence == .displayLinkPresentationTarget || evidence == .scheduledPresentationTime {
            guard let gpuCompletion,
                  commit.duration(to: gpuCompletion) != nil,
                  gpuCompletion.seconds <= proxy.seconds else { return false }
        }
        presentationOutcomes.record(duration: duration, evidence)
        return true
    }

    public mutating func recordBestAvailablePresentationProxy(
        from commit: VideoLatencyTimestamp,
        preferredProxy: VideoLatencyTimestamp?,
        preferredEvidence: VideoPresentationProxyEvidence?,
        commandCompletion: VideoLatencyTimestamp?
    ) {
        let hasPreferredPresentationDeadline = preferredEvidence == .displayLinkPresentationTarget
            || preferredEvidence == .scheduledPresentationTime
        guard let commandCompletion,
              let completionDuration = commit.duration(to: commandCompletion) else {
            let knownMiss = hasPreferredPresentationDeadline
                && preferredProxy.map { proxy in
                    proxy.clockDomain == commit.clockDomain
                        && proxy.seconds.isFinite
                        && commit.seconds.isFinite
                        && proxy.seconds < commit.seconds
                } == true
            presentationOutcomes.record(
                duration: nil,
                nil,
                missedPreferredTarget: knownMiss
            )
            return
        }

        if hasPreferredPresentationDeadline,
           let preferredProxy,
           let preferredEvidence,
           preferredEvidence != .mixed,
           preferredProxy.clockDomain == commit.clockDomain,
           preferredProxy.seconds.isFinite,
           commit.seconds.isFinite {
            let targetPrecedesCommit = preferredProxy.seconds < commit.seconds
            let missedPresentationTarget = targetPrecedesCommit
                || commandCompletion.seconds > preferredProxy.seconds
            if !missedPresentationTarget,
               let preferredDuration = commit.duration(to: preferredProxy) {
                presentationOutcomes.record(
                    duration: preferredDuration,
                    preferredEvidence
                )
                return
            }
            presentationOutcomes.record(
                duration: completionDuration,
                .commandBufferCompletion,
                missedPreferredTarget: true
            )
            return
        }

        presentationOutcomes.record(
            duration: completionDuration,
            .commandBufferCompletion
        )
    }

    public func snapshot() -> VideoLatencyStatistics? {
        let snapshot = VideoLatencyStatistics(
            profile: profile,
            client: client,
            hostProcessing: hostProcessing.snapshot(),
            receiveToVideoToolboxSubmit: receiveToVideoToolboxSubmit.snapshot(),
            reassemblyEnqueueToVideoToolboxSubmit: reassemblyEnqueueToVideoToolboxSubmit.snapshot(),
            videoToolboxDecode: videoToolboxDecode.snapshot(),
            receiveToDecode: receiveToDecode.snapshot(),
            decodeToMetalCommit: decodeToMetalCommit.snapshot(),
            metalCommitToPresentationProxy: presentationOutcomes.latencySummary,
            presentationProxyEvidence: presentationOutcomes.evidenceSummary,
            missedPresentationDeadlines: presentationOutcomes.missedPreferredTargetCount,
            unavailablePresentationProxySamples: presentationOutcomes.unavailableCount
        )
        guard snapshot.hostProcessing != nil
                || snapshot.receiveToVideoToolboxSubmit != nil
                || snapshot.reassemblyEnqueueToVideoToolboxSubmit != nil
                || snapshot.videoToolboxDecode != nil
                || snapshot.receiveToDecode != nil
                || snapshot.decodeToMetalCommit != nil
                || snapshot.metalCommitToPresentationProxy != nil
                || snapshot.missedPresentationDeadlines > 0
                || snapshot.unavailablePresentationProxySamples > 0 else { return nil }
        return snapshot
    }

    public mutating func reset() {
        self = VideoLatencyStatisticsAccumulator(
            sampleCapacity: sampleCapacity,
            profile: profile,
            client: client
        )
    }

    public mutating func setProfile(_ profile: StreamingTelemetryProfile) {
        guard self.profile != profile else { return }
        self = VideoLatencyStatisticsAccumulator(
            sampleCapacity: sampleCapacity,
            profile: profile,
            client: client
        )
    }

    public mutating func setClient(_ client: StreamingTelemetryClient) {
        guard self.client != client else { return }
        self = VideoLatencyStatisticsAccumulator(
            sampleCapacity: sampleCapacity,
            profile: profile,
            client: client
        )
    }
}

/// A decoded pixel buffer whose reference remains owned for the lifetime of this value.
public struct DecodedVideoFrame: @unchecked Sendable {
    public let imageBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let duration: CMTime
    public let frameNumber: Int
    public let color: VideoColorMetadata
    public let latencyMetadata: VideoFrameLatencyMetadata

    public var isHDR: Bool { color.isHDR }

    public init(
        imageBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime = .invalid,
        frameNumber: Int = 0,
        color: VideoColorMetadata = .rec709SDR,
        latencyMetadata: VideoFrameLatencyMetadata = VideoFrameLatencyMetadata()
    ) {
        self.imageBuffer = imageBuffer
        self.presentationTime = presentationTime
        self.duration = duration
        self.frameNumber = frameNumber
        self.color = color
        self.latencyMetadata = latencyMetadata
    }

    /// Compatibility initializer for the first UmbraStreaming bridge contract.
    public init(imageBuffer: CVPixelBuffer, presentationTime: CMTime, isHDR: Bool) {
        self.init(
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            color: isHDR ? .rec2020HDR10 : .rec709SDR
        )
    }

    public func recordingRendererEnqueue(
        _ timestamp: VideoLatencyTimestamp
    ) -> DecodedVideoFrame {
        DecodedVideoFrame(
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            duration: duration,
            frameNumber: frameNumber,
            color: color,
            latencyMetadata: latencyMetadata.recordingRendererEnqueue(timestamp)
        )
    }
}

public protocol MetalVideoRendering: AnyObject, Sendable {
    func enqueue(_ frame: DecodedVideoFrame)
    func flush()
    /// Installs a lifecycle-scoped signal fired after the first Metal command-buffer commit.
    /// This is a software presentation proxy, not physical scanout evidence.
    func installFirstPresentationProxyHandler(_ handler: @escaping @Sendable (Int) -> Void)
    func installCommandCommitHandler(_ handler: @escaping @Sendable (Int) -> Void)
    func installFrameDropHandler(_ handler: @escaping @Sendable (Int, MetalFrameDropReason) -> Void)
    func setMailboxDropNewest(_ enabled: Bool)
    func installTelemetryProfile(_ profile: StreamingTelemetryProfile)
    func installTelemetryClient(_ client: StreamingTelemetryClient)
}

public extension MetalVideoRendering {
    func installFirstPresentationProxyHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        _ = handler
    }

    func installCommandCommitHandler(_ handler: @escaping @Sendable (Int) -> Void) { _ = handler }
    func installFrameDropHandler(_ handler: @escaping @Sendable (Int, MetalFrameDropReason) -> Void) { _ = handler }
    func setMailboxDropNewest(_ enabled: Bool) { _ = enabled }

    func installTelemetryProfile(_ profile: StreamingTelemetryProfile) {
        _ = profile
    }

    func installTelemetryClient(_ client: StreamingTelemetryClient) {
        _ = client
    }
}

/// Renderer disposition for a decoded frame that will not reach Metal commit.
public enum MetalFrameDropReason: Sendable, Equatable {
    case mailboxEviction
    case rendererUnavailable
    case mailboxRejectedNewest
}

public struct OpusStreamFormat: Sendable, Equatable {
    public let audioConfiguration: Int32
    public let sampleRate: Int
    public let channelCount: Int
    public let streamCount: Int
    public let coupledStreamCount: Int
    public let samplesPerFrame: Int
    public let mapping: [UInt8]
    public let flags: Int32

    public init(
        audioConfiguration: Int32,
        sampleRate: Int,
        channelCount: Int,
        streamCount: Int,
        coupledStreamCount: Int,
        samplesPerFrame: Int,
        mapping: [UInt8],
        flags: Int32 = 0
    ) {
        self.audioConfiguration = audioConfiguration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.streamCount = streamCount
        self.coupledStreamCount = coupledStreamCount
        self.samplesPerFrame = samplesPerFrame
        self.mapping = mapping
        self.flags = flags
    }
}

public struct CompressedAudioPacket: Sendable, Equatable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

public protocol AudioDecoding: AnyObject, Sendable {
    func configure(format: OpusStreamFormat) -> Bool
    func start()
    func stop()
    func cleanUp()
    func submit(packet: CompressedAudioPacket)
}

public protocol AudioDiscontinuityHandling: AnyObject, Sendable {
    func resetForDiscontinuity() throws
}

/// AVAudioPCMBuffer is reference-backed; callers transfer an immutable buffer reference.
public struct DecodedAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

public protocol AudioEngineRendering: AnyObject, Sendable {
    func enqueue(_ buffer: DecodedAudioBuffer)
    func flush()
}

public enum PCMRendererTeardownStatus: Sendable, Equatable {
    case complete
    case retryRequired
}

public protocol PCMRendering: AudioEngineRendering {
    var configuration: PCMRendererConfiguration { get }
    func start() throws
    @discardableResult func stop() -> PCMRendererTeardownStatus
    func setApplicationActive(_ active: Bool)
}

public protocol AudioRendererStatisticsProviding: AnyObject, Sendable {
    var statistics: AudioRendererStatistics { get }
}
