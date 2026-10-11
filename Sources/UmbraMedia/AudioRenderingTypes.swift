import Foundation

public struct PCMRendererConfiguration: Sendable, Equatable {
    public var sampleRate: Double
    public var layout: AudioOutputLayout
    public var maximumQueuedBuffers: Int
    public var maximumQueuedDuration: TimeInterval
    public var outputBufferDuration: TimeInterval
    public var minimumPreRollDuration: TimeInterval
    public var rebufferPreRollDuration: TimeInterval
    public var muteWhileInactive: Bool

    public init(
        sampleRate: Double = 48_000,
        layout: AudioOutputLayout = .stereo,
        maximumQueuedBuffers: Int = 64,
        maximumQueuedDuration: TimeInterval = 0.120,
        outputBufferDuration: TimeInterval = 0.015,
        minimumPreRollDuration: TimeInterval = 0.015,
        rebufferPreRollDuration: TimeInterval? = nil,
        muteWhileInactive: Bool = true
    ) {
        self.sampleRate = sampleRate
        self.layout = layout
        self.maximumQueuedBuffers = max(1, maximumQueuedBuffers)
        self.maximumQueuedDuration = max(0.001, maximumQueuedDuration)
        self.outputBufferDuration = min(
            max(0.001, outputBufferDuration),
            self.maximumQueuedDuration
        )
        self.minimumPreRollDuration = min(
            max(self.outputBufferDuration, minimumPreRollDuration),
            self.maximumQueuedDuration
        )
        self.rebufferPreRollDuration = min(
            max(self.minimumPreRollDuration, rebufferPreRollDuration ?? self.minimumPreRollDuration),
            self.maximumQueuedDuration
        )
        self.muteWhileInactive = muteWhileInactive
    }
}

public struct AudioRendererStatistics: Sendable, Equatable {
    public let enqueuedBuffers: UInt64
    public let playedBuffers: UInt64
    public let droppedBuffers: UInt64
    public let rejectedBuffers: UInt64
    public let queuedBuffers: Int
    public let scheduledBuffers: Int
    public let playbackStarted: Bool
    public let queuedDurationMilliseconds: Double
    public let underrunCount: UInt64
    public let rebufferCount: UInt64
    public let nonSilentAcceptedPackets: UInt64
    public let callbackCount: UInt64
    public let callbackError: Int32

    public init(
        enqueuedBuffers: UInt64,
        playedBuffers: UInt64,
        droppedBuffers: UInt64,
        rejectedBuffers: UInt64,
        queuedBuffers: Int,
        scheduledBuffers: Int,
        playbackStarted: Bool,
        queuedDurationMilliseconds: Double,
        underrunCount: UInt64 = 0,
        rebufferCount: UInt64 = 0,
        nonSilentAcceptedPackets: UInt64 = 0,
        callbackCount: UInt64 = 0,
        callbackError: Int32 = 0
    ) {
        self.enqueuedBuffers = enqueuedBuffers
        self.playedBuffers = playedBuffers
        self.droppedBuffers = droppedBuffers
        self.rejectedBuffers = rejectedBuffers
        self.queuedBuffers = queuedBuffers
        self.scheduledBuffers = scheduledBuffers
        self.playbackStarted = playbackStarted
        self.queuedDurationMilliseconds = queuedDurationMilliseconds
        self.underrunCount = underrunCount
        self.rebufferCount = rebufferCount
        self.nonSilentAcceptedPackets = nonSilentAcceptedPackets
        self.callbackCount = callbackCount
        self.callbackError = callbackError
    }
}

final class AudioDiagnosticReporter: @unchecked Sendable {
    private let handler: @Sendable (String) -> Void

    init(handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }

    func report(_ message: String) {
        handler(message)
    }
}
