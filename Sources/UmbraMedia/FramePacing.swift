import Foundation

public struct FramePacingConfiguration: Sendable, Equatable {
    public var nominalFramesPerSecond: Double
    public var framePacingEnabled: Bool
    public var verticalSyncEnabled: Bool
    public var displayRefreshRate: Double
    public var maximumLateness: TimeInterval
    public var maximumSchedulingLead: TimeInterval

    public init(
        nominalFramesPerSecond: Double,
        framePacingEnabled: Bool = true,
        verticalSyncEnabled: Bool = true,
        displayRefreshRate: Double = 60,
        maximumLateness: TimeInterval = 0.050,
        maximumSchedulingLead: TimeInterval = 0.100
    ) {
        self.nominalFramesPerSecond = nominalFramesPerSecond
        self.framePacingEnabled = framePacingEnabled
        self.verticalSyncEnabled = verticalSyncEnabled
        self.displayRefreshRate = displayRefreshRate
        self.maximumLateness = maximumLateness
        self.maximumSchedulingLead = maximumSchedulingLead
    }
}

/// Learns how much CPU time Metal submission recently required and reserves only
/// that bounded lead before a display-link deadline. This replaces a fixed
/// fraction-of-a-frame wait, which grew unnecessarily at lower refresh rates.
public struct AdaptiveRenderLeadPolicy: Sendable, Equatable {
    public let minimumLead: TimeInterval
    public let maximumLead: TimeInterval
    public let safetyMultiplier: Double
    public let smoothingFactor: Double
    public private(set) var estimatedCommitCost: TimeInterval?

    public init(
        minimumLead: TimeInterval = 0.000_5,
        maximumLead: TimeInterval = 0.004,
        safetyMultiplier: Double = 1.5,
        smoothingFactor: Double = 0.2
    ) {
        self.minimumLead = max(0, minimumLead)
        self.maximumLead = max(self.minimumLead, maximumLead)
        self.safetyMultiplier = max(1, safetyMultiplier)
        self.smoothingFactor = min(1, max(0.01, smoothingFactor))
    }

    public var renderLead: TimeInterval {
        let measuredLead = (estimatedCommitCost ?? minimumLead) * safetyMultiplier
        return min(maximumLead, max(minimumLead, measuredLead))
    }

    public mutating func record(commitCost: TimeInterval) {
        guard commitCost.isFinite, commitCost >= 0 else { return }
        let boundedCost = min(maximumLead, commitCost)
        if let estimatedCommitCost {
            self.estimatedCommitCost = estimatedCommitCost
                + (boundedCost - estimatedCommitCost) * smoothingFactor
        } else {
            estimatedCommitCost = boundedCost
        }
    }

    public func waitDuration(now: TimeInterval, targetTimestamp: TimeInterval) -> TimeInterval {
        guard now.isFinite, targetTimestamp.isFinite else { return 0 }
        return max(0, targetTimestamp - now - renderLead)
    }

    public mutating func reset() {
        estimatedCommitCost = nil
    }
}

public enum FrameDropReason: Sendable, Equatable {
    case queueOverflow
    case late
    case decoder
    case rendererUnavailable
    case unsupportedPixelFormat
}

public enum FramePacingDecision: Sendable, Equatable {
    case presentImmediately
    case schedule(at: TimeInterval)
    case drop(FrameDropReason)
}

/// Presentation routing decision used before Metal submission.
///
/// Umbra deliberately has no second presentation clock: quality mode is paced
/// exclusively by `CAMetalDisplayLink`, while the non-display-link latency path
/// submits immediately. Source PTS scheduling is deferred until it can be tied
/// to the real display deadline without adding a competing clock.
public struct FramePacingStateMachine: Sendable {
    public private(set) var configuration: FramePacingConfiguration

    public init(configuration: FramePacingConfiguration) {
        self.configuration = configuration
    }

    public mutating func updateConfiguration(_ configuration: FramePacingConfiguration) {
        self.configuration = configuration
    }

    public mutating func reset() {}

    public mutating func decision(
        presentationTime sourceTime: TimeInterval,
        now: TimeInterval
    ) -> FramePacingDecision {
        _ = sourceTime
        _ = now
        return .presentImmediately
    }
}

public struct MediaPipelineStatistics: Sendable, Equatable {
    public let submittedFrames: UInt64
    public let decodedFrames: UInt64
    public let presentedFrames: UInt64
    public let droppedFrames: UInt64
    public let decoderErrors: UInt64
    public let queueDepth: Int
    public let decodeFramesPerSecond: Double
    public let presentationFramesPerSecond: Double
    public let averageDecodeLatencyMilliseconds: Double?
    public let latencyStatistics: VideoLatencyStatistics?

    public init(
        submittedFrames: UInt64,
        decodedFrames: UInt64,
        presentedFrames: UInt64,
        droppedFrames: UInt64,
        decoderErrors: UInt64,
        queueDepth: Int,
        decodeFramesPerSecond: Double,
        presentationFramesPerSecond: Double,
        averageDecodeLatencyMilliseconds: Double?,
        latencyStatistics: VideoLatencyStatistics? = nil
    ) {
        self.submittedFrames = submittedFrames
        self.decodedFrames = decodedFrames
        self.presentedFrames = presentedFrames
        self.droppedFrames = droppedFrames
        self.decoderErrors = decoderErrors
        self.queueDepth = queueDepth
        self.decodeFramesPerSecond = decodeFramesPerSecond
        self.presentationFramesPerSecond = presentationFramesPerSecond
        self.averageDecodeLatencyMilliseconds = averageDecodeLatencyMilliseconds
        self.latencyStatistics = latencyStatistics
    }

    public func including(latencyStatistics: VideoLatencyStatistics?) -> MediaPipelineStatistics {
        MediaPipelineStatistics(
            submittedFrames: submittedFrames,
            decodedFrames: decodedFrames,
            presentedFrames: presentedFrames,
            droppedFrames: droppedFrames,
            decoderErrors: decoderErrors,
            queueDepth: queueDepth,
            decodeFramesPerSecond: decodeFramesPerSecond,
            presentationFramesPerSecond: presentationFramesPerSecond,
            averageDecodeLatencyMilliseconds: averageDecodeLatencyMilliseconds,
            latencyStatistics: latencyStatistics
        )
    }
}

public enum MediaPipelineEvent: Sendable, Equatable {
    case submitted
    case decoded(latency: TimeInterval)
    case presented
    case dropped(FrameDropReason)
    case decoderError
    case queueDepth(Int)
}

/// Pure accumulator used by decoder and renderer locks. It does not read a system clock.
public struct MediaStatisticsAccumulator: Sendable {
    private var submittedFrames: UInt64 = 0
    private var decodedFrames: UInt64 = 0
    private var presentedFrames: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var decoderErrors: UInt64 = 0
    private var queueDepth = 0
    private var decodeLatencyTotal: TimeInterval = 0
    private var decodeLatencySamples: UInt64 = 0
    private var recentDecodeTimes: [TimeInterval] = []
    private var recentPresentationTimes: [TimeInterval] = []
    private let rollingWindow: TimeInterval

    public init(rollingWindow: TimeInterval = 1) {
        self.rollingWindow = max(0.1, rollingWindow)
    }

    public mutating func record(_ event: MediaPipelineEvent, at time: TimeInterval) {
        switch event {
        case .submitted:
            submittedFrames += 1
        case let .decoded(latency):
            decodedFrames += 1
            recentDecodeTimes.append(time)
            if latency >= 0, latency.isFinite {
                decodeLatencyTotal += latency
                decodeLatencySamples += 1
            }
        case .presented:
            presentedFrames += 1
            recentPresentationTimes.append(time)
        case .dropped:
            droppedFrames += 1
        case .decoderError:
            decoderErrors += 1
        case let .queueDepth(depth):
            queueDepth = max(0, depth)
        }
        prune(now: time)
    }

    public mutating func snapshot(at time: TimeInterval) -> MediaPipelineStatistics {
        prune(now: time)
        return MediaPipelineStatistics(
            submittedFrames: submittedFrames,
            decodedFrames: decodedFrames,
            presentedFrames: presentedFrames,
            droppedFrames: droppedFrames,
            decoderErrors: decoderErrors,
            queueDepth: queueDepth,
            decodeFramesPerSecond: rate(for: recentDecodeTimes),
            presentationFramesPerSecond: rate(for: recentPresentationTimes),
            averageDecodeLatencyMilliseconds: decodeLatencySamples == 0
                ? nil
                : decodeLatencyTotal / Double(decodeLatencySamples) * 1_000
        )
    }

    public mutating func reset() {
        self = MediaStatisticsAccumulator(rollingWindow: rollingWindow)
    }

    private mutating func prune(now: TimeInterval) {
        let cutoff = now - rollingWindow
        recentDecodeTimes.removeAll { $0 < cutoff }
        recentPresentationTimes.removeAll { $0 < cutoff }
    }

    private func rate(for times: [TimeInterval]) -> Double {
        guard let first = times.first, let last = times.last else { return 0 }
        let observedDuration = max(last - first, rollingWindow)
        return Double(times.count) / observedDuration
    }
}
