import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

public enum VideoDecoderPolicy: Sendable, Equatable {
    case automatic
    case hardwareOnly
    case softwareOnly
}

public enum VideoDecodeCapacityPolicy: Sendable, Equatable {
    /// Preserve every compressed frame while bounding the number of in-flight submissions.
    case waitWhenFull
    /// Keep the streaming callback nonblocking by dropping the newest frame at capacity.
    case dropNewestWhenFull
}

public enum VideoDecodeCapacityOverflowBehavior: Sendable, Equatable {
    case requestRecovery
    case dropWithoutRecovery
}

public enum VideoDecoderError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedCodecMask(Int32)
    case unsupportedHardwareCodec(VideoCodec)
    case invalidDimensions(width: Int, height: Int)
    case invalidAccessUnit
    case encodedStorageAllocationFailed
    case missingParameterSets(VideoCodec)
    case formatDescriptionFailed(OSStatus)
    case sessionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
    case frameDropped
    case notConfigured
    case notRunning
    case queueFull

    public var description: String {
        switch self {
        case let .unsupportedCodecMask(mask): "Unsupported video codec mask: \(mask)"
        case let .unsupportedHardwareCodec(codec): "Hardware decoding is unavailable for \(codec.rawValue)"
        case let .invalidDimensions(width, height): "Invalid video dimensions: \(width)x\(height)"
        case .invalidAccessUnit: "The encoded access unit is empty or malformed"
        case .encodedStorageAllocationFailed: "The encoded access unit storage allocation failed"
        case let .missingParameterSets(codec): "A \(codec.rawValue) key frame with parameter sets is required"
        case let .formatDescriptionFailed(status): "Video format description failed with OSStatus \(status)"
        case let .sessionCreationFailed(status): "VideoToolbox session creation failed with OSStatus \(status)"
        case let .sampleBufferCreationFailed(status): "Compressed sample creation failed with OSStatus \(status)"
        case let .decodeFailed(status): "VideoToolbox decode failed with OSStatus \(status)"
        case .frameDropped: "VideoToolbox produced no decoded image for the submitted frame"
        case .notConfigured: "The decoder is not configured"
        case .notRunning: "The decoder is not running"
        case .queueFull: "The bounded decoder queue is full"
        }
    }
}

private let releaseEncodedVideoPayload: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer,
    Int
) -> Void = { refCon, _, _ in
    guard let refCon else { return }
    Unmanaged<EncodedVideoPayload>.fromOpaque(refCon).release()
}

/// Stable encoded-byte ownership shared with CoreMedia without retaining a
/// pointer obtained from `Data.withUnsafeBytes`. An adopted `NSData` keeps its
/// documented `bytes` address valid for its lifetime; converted Annex-B input
/// is written directly into one malloc-owned final allocation.
final class EncodedVideoPayload: @unchecked Sendable {
    static let maximumByteCount = 64 * 1024 * 1024

    let baseAddress: UnsafeMutableRawPointer
    let count: Int

    private let retainedBytes: NSData?
    private let ownsAllocation: Bool
    private let releaseObserver: (@Sendable () -> Void)?

    init(
        retaining data: Data,
        releaseObserver: (@Sendable () -> Void)? = nil
    ) throws {
        guard Self.isValidByteCount(data.count) else {
            throw VideoDecoderError.invalidAccessUnit
        }
        let bytes = data as NSData
        guard bytes.length == data.count else {
            throw VideoDecoderError.invalidAccessUnit
        }
        baseAddress = UnsafeMutableRawPointer(mutating: bytes.bytes)
        count = bytes.length
        retainedBytes = bytes
        ownsAllocation = false
        self.releaseObserver = releaseObserver
    }

    init(
        allocating count: Int,
        using allocator: (Int) -> UnsafeMutableRawPointer? = { malloc($0) },
        releaseObserver: (@Sendable () -> Void)? = nil
    ) throws {
        guard Self.isValidByteCount(count) else {
            throw VideoDecoderError.invalidAccessUnit
        }
        guard let allocation = allocator(count) else {
            throw VideoDecoderError.encodedStorageAllocationFailed
        }
        baseAddress = allocation
        self.count = count
        retainedBytes = nil
        ownsAllocation = true
        self.releaseObserver = releaseObserver
    }

    deinit {
        if ownsAllocation {
            free(baseAddress)
        }
        releaseObserver?()
    }

    static func isValidByteCount(_ count: Int) -> Bool {
        count > 0 && count <= maximumByteCount
    }

    func makeBlockBuffer() throws -> CMBlockBuffer {
        let retainedSelf = Unmanaged.passRetained(self)
        var source = CMBlockBufferCustomBlockSource()
        source.version = UInt32(kCMBlockBufferCustomBlockSourceVersion)
        source.FreeBlock = releaseEncodedVideoPayload
        source.refCon = retainedSelf.toOpaque()

        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: baseAddress,
            blockLength: count,
            blockAllocator: nil,
            customBlockSource: &source,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            retainedSelf.release()
            throw VideoDecoderError.sampleBufferCreationFailed(status)
        }
        return blockBuffer
    }

    func copiedData() -> Data {
        Data(bytes: baseAddress, count: count)
    }
}

private final class DecodingFrameContext: @unchecked Sendable {
    let frameNumber: Int
    let isKeyFrame: Bool
    let decodeGeneration: UInt64
    let sessionGeneration: UInt64
    let recoveryEpochAtSubmission: UInt64
    let color: VideoColorMetadata
    let submittedAt: TimeInterval
    let latencyMetadata: VideoFrameLatencyMetadata

    init(
        frame: CompressedVideoFrame,
        decodeGeneration: UInt64,
        sessionGeneration: UInt64,
        recoveryEpochAtSubmission: UInt64,
        hdrModeEnabled: Bool,
        hdrStaticMetadata: HDRStaticMetadata?,
        submittedAt: TimeInterval,
        latencyMetadata: VideoFrameLatencyMetadata
    ) {
        let isHDR = frame.isHDR || hdrModeEnabled
        frameNumber = frame.frameNumber
        isKeyFrame = frame.isKeyFrame
        self.decodeGeneration = decodeGeneration
        self.sessionGeneration = sessionGeneration
        self.recoveryEpochAtSubmission = recoveryEpochAtSubmission
        color = VideoColorMetadata(
            colorSpace: isHDR ? .rec2020 : VideoColorSpace(bridgeValue: frame.colorSpace),
            range: frame.isFullRange ? .full : .video,
            transferFunction: isHDR ? (hdrStaticMetadata?.transferFunction ?? .pq) : .sdr,
            hdrStaticMetadata: isHDR ? hdrStaticMetadata : nil
        )
        self.submittedAt = submittedAt
        self.latencyMetadata = latencyMetadata
    }
}

private final class SynchronousDecodeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSucceeded = false

    var succeeded: Bool {
        get { lock.withLock { storedSucceeded } }
        set { lock.withLock { storedSucceeded = newValue } }
    }
}

private let videoToolboxOutputCallback: VTDecompressionOutputCallback = {
    outputReference, sourceFrameReference, status, infoFlags, imageBuffer, presentationTime, duration in
    guard let outputReference, let sourceFrameReference else { return }
    let decoder = Unmanaged<VideoToolboxDecoder>.fromOpaque(outputReference).takeUnretainedValue()
    let frameContext = Unmanaged<DecodingFrameContext>.fromOpaque(sourceFrameReference).takeRetainedValue()
    decoder.didDecode(
        context: frameContext,
        status: status,
        infoFlags: infoFlags,
        imageBuffer: imageBuffer,
        presentationTime: presentationTime,
        duration: duration
    )
}

/// Bounds VideoToolbox work. Quality mode waits for capacity; latency mode can reject the
/// newest submission without putting the streaming callback to sleep.
final class VideoDecodeInFlightLimiter: @unchecked Sendable {
    enum Admission: Sendable, Equatable {
        case admitted(depth: Int)
        case full(depth: Int)
        case stopped
    }

    struct Snapshot: Sendable, Equatable {
        let outstandingCount: Int
        let maximumObservedCount: Int
        let waitingCount: Int

        init(
            outstandingCount: Int,
            maximumObservedCount: Int,
            waitingCount: Int = 0
        ) {
            self.outstandingCount = outstandingCount
            self.maximumObservedCount = maximumObservedCount
            self.waitingCount = waitingCount
        }
    }

    private let condition = NSCondition()
    private let maximumCount: Int
    private var activeGeneration: UInt64 = 0
    private var running = false
    private var outstandingCount = 0
    private var maximumObservedCount = 0
    private var waitingCount = 0

    init(maximumCount: Int) {
        self.maximumCount = max(1, maximumCount)
    }

    func start(generation: UInt64 = 0) {
        condition.lock()
        activeGeneration = generation
        running = true
        outstandingCount = 0
        maximumObservedCount = 0
        condition.broadcast()
        condition.unlock()
    }

    func stop(generation: UInt64 = 0) {
        condition.lock()
        if activeGeneration == generation {
            running = false
        }
        condition.broadcast()
        condition.unlock()
    }

    func reset(generation: UInt64 = 0) {
        condition.lock()
        activeGeneration = generation
        running = false
        outstandingCount = 0
        maximumObservedCount = 0
        condition.broadcast()
        condition.unlock()
    }

    /// Returns the new depth, or nil when shutdown interrupted the wait.
    func acquire(generation: UInt64 = 0) -> Int? {
        guard case let .admitted(depth) = admit(
            generation: generation,
            using: .waitWhenFull
        ) else { return nil }
        return depth
    }

    func admit(
        generation: UInt64 = 0,
        using policy: VideoDecodeCapacityPolicy
    ) -> Admission {
        condition.lock()
        defer { condition.unlock() }
        switch policy {
        case .waitWhenFull:
            while running,
                  activeGeneration == generation,
                  outstandingCount >= maximumCount {
                waitingCount += 1
                condition.wait()
                waitingCount -= 1
            }
        case .dropNewestWhenFull:
            guard running, activeGeneration == generation else { return .stopped }
            guard outstandingCount < maximumCount else {
                return .full(depth: outstandingCount)
            }
        }
        guard running, activeGeneration == generation else { return .stopped }
        outstandingCount += 1
        maximumObservedCount = max(maximumObservedCount, outstandingCount)
        return .admitted(depth: outstandingCount)
    }

    /// Returns the remaining depth after a decode completion.
    @discardableResult
    func release(generation: UInt64 = 0) -> Int? {
        condition.lock()
        guard activeGeneration == generation else {
            condition.unlock()
            return nil
        }
        outstandingCount = max(0, outstandingCount - 1)
        let remaining = outstandingCount
        condition.signal()
        condition.unlock()
        return remaining
    }

    var snapshot: Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return Snapshot(
            outstandingCount: outstandingCount,
            maximumObservedCount: maximumObservedCount,
            waitingCount: waitingCount
        )
    }
}

struct VideoDecodeRecoveryGate: Sendable, Equatable {
    private(set) var epoch: UInt64 = 0
    private(set) var isRequired = false

    var submissionEpoch: UInt64 { epoch }

    mutating func resetForLifecycle() {
        epoch &+= 1
        isRequired = false
    }

    mutating func requireRecovery() {
        epoch &+= 1
        isRequired = true
    }

    mutating func recordSuccessfulDecode(
        isKeyFrame: Bool,
        frameSessionGeneration: UInt64,
        currentSessionGeneration: UInt64,
        frameRecoveryEpoch: UInt64
    ) {
        guard isRequired else { return }
        if isKeyFrame,
           frameSessionGeneration == currentSessionGeneration,
           frameRecoveryEpoch == epoch {
            isRequired = false
        }
    }
}

public final class VideoToolboxDecoder: VideoDecoding, VideoCodecInitializationPreparing, HDRMetadataReceiving, VideoDecodeOutcomeReporting, @unchecked Sendable {
    private struct State {
        var format: VideoStreamFormat?
        var profile: VideoCodecProfile?
        var session: VTDecompressionSession?
        var formatDescription: CMVideoFormatDescription?
        var parameterSets: [Data] = []
        var running = false
        var reportedFirstDecodedFrame = false
        var recovery = VideoDecodeRecoveryGate()
        var decodeGeneration: UInt64 = 0
        var sessionGeneration: UInt64 = 0
        var hdrModeEnabled = false
        var hdrStaticMetadata: HDRStaticMetadata?
        var lastError: VideoDecoderError?
        var statistics = MediaStatisticsAccumulator()
        var latencyStatistics = VideoLatencyStatisticsAccumulator()
        var moonlightClockMapping = VideoLatencyClockMapping(
            sourceDomain: .moonlightClientUptime,
            destinationDomain: .clientMediaTime
        )
    }

    private let renderer: (any MetalVideoRendering)?
    private let policy: VideoDecoderPolicy
    private let capacityPolicy: VideoDecodeCapacityPolicy
    private let capacityOverflowBehavior: VideoDecodeCapacityOverflowBehavior
    private let inFlightLimiter: VideoDecodeInFlightLimiter
    private let errorHandler: @Sendable (VideoDecoderError) -> Void
    private let firstFrameHandler: @Sendable (Int) -> Void
    private let firstFrameMetadataHandler: @Sendable (VideoColorMetadata, OSType) -> Void
    private let submissionBoundaryHandler: (@Sendable () -> Void)?
    private let decodeQueue = DispatchQueue(label: "app.umbra.media.videotoolbox", qos: .userInteractive)
    private let lifecycleLock = NSLock()
    private let lock = NSLock()
    private var state = State()
    private var decodeOutcomeHandler: (@Sendable (VideoDecodeOutcome) -> Void)?

    public init(
        renderer: (any MetalVideoRendering)? = nil,
        policy: VideoDecoderPolicy = .automatic,
        maximumOutstandingFrames: Int = 5,
        capacityPolicy: VideoDecodeCapacityPolicy = .waitWhenFull,
        capacityOverflowBehavior: VideoDecodeCapacityOverflowBehavior = .requestRecovery,
        telemetryProfile: StreamingTelemetryProfile = .unspecified,
        telemetryClient: StreamingTelemetryClient = .unspecified,
        errorHandler: @escaping @Sendable (VideoDecoderError) -> Void = { _ in },
        firstFrameHandler: @escaping @Sendable (Int) -> Void = { _ in },
        firstFrameMetadataHandler: @escaping @Sendable (VideoColorMetadata, OSType) -> Void = { _, _ in }
    ) {
        self.renderer = renderer
        self.policy = policy
        self.capacityPolicy = capacityPolicy
        self.capacityOverflowBehavior = capacityOverflowBehavior
        self.inFlightLimiter = VideoDecodeInFlightLimiter(maximumCount: maximumOutstandingFrames)
        self.errorHandler = errorHandler
        self.firstFrameHandler = firstFrameHandler
        self.firstFrameMetadataHandler = firstFrameMetadataHandler
        self.submissionBoundaryHandler = nil
        state.latencyStatistics = VideoLatencyStatisticsAccumulator(
            profile: telemetryProfile,
            client: telemetryClient
        )
    }

    public func installDecodeOutcomeHandler(
        _ handler: @escaping @Sendable (VideoDecodeOutcome) -> Void
    ) {
        lock.withLock { decodeOutcomeHandler = handler }
    }

    init(
        renderer: (any MetalVideoRendering)? = nil,
        policy: VideoDecoderPolicy = .automatic,
        capacityPolicy: VideoDecodeCapacityPolicy = .waitWhenFull,
        capacityOverflowBehavior: VideoDecodeCapacityOverflowBehavior = .requestRecovery,
        telemetryProfile: StreamingTelemetryProfile = .unspecified,
        telemetryClient: StreamingTelemetryClient = .unspecified,
        errorHandler: @escaping @Sendable (VideoDecoderError) -> Void = { _ in },
        firstFrameHandler: @escaping @Sendable (Int) -> Void = { _ in },
        firstFrameMetadataHandler: @escaping @Sendable (VideoColorMetadata, OSType) -> Void = { _, _ in },
        submissionBoundaryHandler: (@Sendable () -> Void)? = nil,
        inFlightLimiter: VideoDecodeInFlightLimiter
    ) {
        self.renderer = renderer
        self.policy = policy
        self.capacityPolicy = capacityPolicy
        self.capacityOverflowBehavior = capacityOverflowBehavior
        self.inFlightLimiter = inFlightLimiter
        self.errorHandler = errorHandler
        self.firstFrameHandler = firstFrameHandler
        self.firstFrameMetadataHandler = firstFrameMetadataHandler
        self.submissionBoundaryHandler = submissionBoundaryHandler
        state.latencyStatistics = VideoLatencyStatisticsAccumulator(
            profile: telemetryProfile,
            client: telemetryClient
        )
    }

    deinit {
        lock.lock()
        let generation = state.decodeGeneration
        state.running = false
        inFlightLimiter.stop(generation: generation)
        let session = state.session
        state.session = nil
        lock.unlock()
        if let session {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    public var lastError: VideoDecoderError? {
        lock.lock()
        defer { lock.unlock() }
        return state.lastError
    }

    var currentDecodeGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return state.decodeGeneration
    }

    public func statistics(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> MediaPipelineStatistics {
        lock.lock()
        defer { lock.unlock() }
        return state.statistics.snapshot(at: time).including(
            latencyStatistics: state.latencyStatistics.snapshot()
        )
    }

    public func configure(format: VideoStreamFormat) -> Bool {
        do {
            try configureThrowing(format: format)
            return true
        } catch let error as VideoDecoderError {
            setError(error)
            return false
        } catch {
            setError(.formatDescriptionFailed(kCMFormatDescriptionError_InvalidParameter))
            return false
        }
    }

    public func configureThrowing(format: VideoStreamFormat) throws {
        guard format.width > 0, format.height > 0 else {
            throw VideoDecoderError.invalidDimensions(width: format.width, height: format.height)
        }
        let profile = try VideoCodecProfile(codecMask: format.codecMask)
        if policy == .hardwareOnly,
           !VTIsHardwareDecodeSupported(profile.codec.cmCodecType) {
            throw VideoDecoderError.unsupportedHardwareCodec(profile.codec)
        }

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        let priorGeneration = state.decodeGeneration
        state.running = false
        inFlightLimiter.stop(generation: priorGeneration)
        lock.unlock()
        decodeQueue.sync {
            invalidateCurrentSession(waitForFrames: true)
            lock.lock()
            state.decodeGeneration &+= 1
            let resetGeneration = state.decodeGeneration
            state.format = format
            state.profile = profile
            state.parameterSets.removeAll(keepingCapacity: true)
            state.running = false
            state.reportedFirstDecodedFrame = false
            state.recovery.resetForLifecycle()
            state.lastError = nil
            state.statistics.reset()
            state.latencyStatistics.reset()
            state.moonlightClockMapping.reset()
            inFlightLimiter.reset(generation: resetGeneration)
            lock.unlock()
        }
    }

    public func prepareCodecInitialization(
        _ data: Data,
        payloadFormat: EncodedVideoPayloadFormat
    ) -> Bool {
        do {
            try prepareCodecInitializationThrowing(data, payloadFormat: payloadFormat)
            return true
        } catch let error as VideoDecoderError {
            setError(error)
            return false
        } catch {
            setError(.formatDescriptionFailed(kCMFormatDescriptionError_InvalidParameter))
            return false
        }
    }

    public func prepareCodecInitializationThrowing(
        _ data: Data,
        payloadFormat: EncodedVideoPayloadFormat
    ) throws {
        guard EncodedVideoPayload.isValidByteCount(data.count) else {
            throw VideoDecoderError.invalidAccessUnit
        }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        guard !state.running, let format = state.format, let profile = state.profile else {
            lock.unlock()
            throw VideoDecoderError.notConfigured
        }
        lock.unlock()

        let preparation: Result<Void, Error> = decodeQueue.sync {
            Result {
                let description: CMVideoFormatDescription
                let storedParameterSets: [Data]
                switch profile.codec {
                case .h264, .hevc:
                    let parameterSets: [Data]
                    switch payloadFormat {
                    case .annexB:
                        parameterSets = try AnnexBAccessUnit(data: data, codec: profile.codec).parameterSets
                    case .videoToolboxLengthPrefixed:
                        parameterSets = try LengthPrefixedAccessUnit(data: data, codec: profile.codec).parameterSets
                    case .av1LowOverheadOBU:
                        throw VideoDecoderError.invalidAccessUnit
                    }
                    guard !parameterSets.isEmpty else {
                        throw VideoDecoderError.missingParameterSets(profile.codec)
                    }
                    description = try makeFormatDescription(
                        codec: profile.codec,
                        parameterSets: parameterSets
                    )
                    storedParameterSets = parameterSets
                case .av1:
                    guard payloadFormat == .av1LowOverheadOBU else {
                        throw VideoDecoderError.invalidAccessUnit
                    }
                    let accessUnit = try AV1AccessUnit(data: data, profile: profile)
                    description = try makeAV1FormatDescription(
                        format: format,
                        codecConfigurationRecord: accessUnit.codecConfigurationRecord
                    )
                    storedParameterSets = [accessUnit.codecConfigurationRecord]
                }
                invalidateCurrentSession(waitForFrames: true)
                try installSession(formatDescription: description, format: format, profile: profile)
                lock.withLock { state.parameterSets = storedParameterSets }
            }
        }
        try preparation.get()
    }

    public func start() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        guard state.format != nil, state.profile != nil else {
            state.lastError = .notConfigured
            lock.unlock()
            return
        }
        guard !state.running else {
            lock.unlock()
            return
        }
        state.decodeGeneration &+= 1
        state.recovery.resetForLifecycle()
        state.running = true
        state.lastError = nil
        let generation = state.decodeGeneration
        inFlightLimiter.start(generation: generation)
        lock.unlock()
    }

    public func setHDRMode(enabled: Bool, metadata: HDRStaticMetadata?) {
        lock.lock()
        state.hdrModeEnabled = enabled
        state.hdrStaticMetadata = enabled ? metadata : nil
        lock.unlock()
    }

    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopUnderLifecycleLock()
    }

    private func stopUnderLifecycleLock() {
        lock.lock()
        let stoppingGeneration = state.decodeGeneration
        state.running = false
        inFlightLimiter.stop(generation: stoppingGeneration)
        lock.unlock()
        decodeQueue.sync {
            invalidateCurrentSession(waitForFrames: true)
        }
        lock.lock()
        if state.decodeGeneration == stoppingGeneration {
            state.decodeGeneration &+= 1
            inFlightLimiter.reset(generation: state.decodeGeneration)
        }
        lock.unlock()
        renderer?.flush()
    }

    public func cleanUp() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopUnderLifecycleLock()
        lock.lock()
        state.format = nil
        state.profile = nil
        state.parameterSets.removeAll()
        state.hdrModeEnabled = false
        state.hdrStaticMetadata = nil
        lock.unlock()
    }

    public func submit(frame: CompressedVideoFrame) -> VideoFrameDisposition {
        let decoderIngressTime = VideoLatencyTimestamp(
            seconds: CACurrentMediaTime(),
            clockDomain: .clientMediaTime
        )
        guard EncodedVideoPayload.isValidByteCount(frame.data.count) else {
            setError(.invalidAccessUnit)
            return .requestKeyFrame
        }

        lock.lock()
        guard state.format != nil, let profile = state.profile else {
            state.lastError = .notConfigured
            lock.unlock()
            return .requestKeyFrame
        }
        guard state.running else {
            state.lastError = .notRunning
            lock.unlock()
            return .accepted
        }
        if let enqueueTime = Self.moonlightTimestamp(frame.enqueueTimeMicroseconds) {
            state.moonlightClockMapping.observe(
                source: enqueueTime,
                destination: decoderIngressTime
            )
        }
        let decodeGeneration = state.decodeGeneration
        let recoveryEpochAtSubmission = state.recovery.submissionEpoch
        let requiresSynchronousInitialization = state.session == nil || state.recovery.isRequired
        if requiresSynchronousInitialization, !frame.isKeyFrame {
            state.lastError = .missingParameterSets(profile.codec)
            lock.unlock()
            errorHandler(.missingParameterSets(profile.codec))
            return .requestKeyFrame
        }
        lock.unlock()

        let admission = inFlightLimiter.admit(
            generation: decodeGeneration,
            using: capacityPolicy
        )
        let outstandingDepth: Int
        switch admission {
        case let .admitted(depth):
            outstandingDepth = depth
        case let .full(depth):
            return recordCapacityOverflow(
                depth: depth,
                generation: decodeGeneration,
                at: ProcessInfo.processInfo.systemUptime
            )
        case .stopped:
            return .accepted
        }

        submissionBoundaryHandler?()

        // This lock is the enqueue boundary shared with stop/configure. Once the
        // generation check succeeds, the task is placed on decodeQueue before a
        // lifecycle transition can begin draining it.
        lock.lock()
        guard state.running,
              state.decodeGeneration == decodeGeneration,
              let currentProfile = state.profile else {
            lock.unlock()
            inFlightLimiter.release(generation: decodeGeneration)
            return .accepted
        }
        let nowRequiresSynchronousInitialization = state.session == nil || state.recovery.isRequired
        if nowRequiresSynchronousInitialization, !frame.isKeyFrame {
            state.lastError = .missingParameterSets(currentProfile.codec)
            lock.unlock()
            inFlightLimiter.release(generation: decodeGeneration)
            errorHandler(.missingParameterSets(currentProfile.codec))
            return .requestKeyFrame
        }
        state.statistics.record(.submitted, at: ProcessInfo.processInfo.systemUptime)
        state.statistics.record(.queueDepth(outstandingDepth), at: ProcessInfo.processInfo.systemUptime)

        if nowRequiresSynchronousInitialization {
            let completed = DispatchSemaphore(value: 0)
            let result = SynchronousDecodeResult()
            decodeQueue.async { [self] in
                result.succeeded = decode(
                    frame,
                    generation: decodeGeneration,
                    recoveryEpochAtSubmission: recoveryEpochAtSubmission
                )
                completed.signal()
            }
            lock.unlock()
            completed.wait()
            lock.lock()
            let lifecycleIsCurrent = state.running
                && state.decodeGeneration == decodeGeneration
            let recoverySubmissionIsCurrent = !state.recovery.isRequired
                || recoveryEpochAtSubmission == state.recovery.submissionEpoch
            let initialized = result.succeeded
                && lifecycleIsCurrent
                && state.session != nil
                && recoverySubmissionIsCurrent
            lock.unlock()
            return initialized || !lifecycleIsCurrent ? .accepted : .requestKeyFrame
        } else {
            decodeQueue.async { [self] in
                _ = decode(
                    frame,
                    generation: decodeGeneration,
                    recoveryEpochAtSubmission: recoveryEpochAtSubmission
                )
            }
            lock.unlock()
            return .accepted
        }
    }

    @discardableResult
    func recordCapacityOverflow(
        depth: Int,
        generation: UInt64,
        at time: TimeInterval
    ) -> VideoFrameDisposition {
        lock.lock()
        guard state.running, state.decodeGeneration == generation else {
            lock.unlock()
            return .accepted
        }
        state.lastError = .queueFull
        if capacityOverflowBehavior == .requestRecovery {
            state.recovery.requireRecovery()
        }
        state.statistics.record(.submitted, at: time)
        state.statistics.record(.dropped(.queueOverflow), at: time)
        state.statistics.record(.decoderError, at: time)
        state.statistics.record(.queueDepth(depth), at: time)
        lock.unlock()
        errorHandler(.queueFull)
        return capacityOverflowBehavior == .requestRecovery ? .requestKeyFrame : .capacityDropped
    }

    private func decode(
        _ frame: CompressedVideoFrame,
        generation: UInt64,
        recoveryEpochAtSubmission: UInt64
    ) -> Bool {
        lock.lock()
        guard state.running,
              state.decodeGeneration == generation,
              let format = state.format,
              let profile = state.profile else {
            lock.unlock()
            completeOutstandingFrame(error: .notRunning, generation: generation)
            return false
        }
        lock.unlock()

        do {
            let payload: EncodedVideoPayload
            switch profile.codec {
            case .h264, .hevc:
                let inlineParameterSets: [Data]
                switch frame.payloadFormat {
                case .annexB:
                    let units = try AnnexBAccessUnit(data: frame.data, codec: profile.codec)
                    inlineParameterSets = units.parameterSets
                    payload = units.lengthPrefixedPayload
                case .videoToolboxLengthPrefixed:
                    let units = try LengthPrefixedAccessUnit(data: frame.data, codec: profile.codec)
                    inlineParameterSets = units.parameterSets
                    payload = units.payload
                case .av1LowOverheadOBU:
                    throw VideoDecoderError.invalidAccessUnit
                }
                lock.lock()
                let hasSession = state.session != nil
                let requiresRecovery = state.recovery.isRequired
                let retainedParameterSets = state.parameterSets
                lock.unlock()
                if let parameterSets = Self.parameterSetsForSessionRecreation(
                    inline: inlineParameterSets,
                    retained: retainedParameterSets,
                    isKeyFrame: frame.isKeyFrame,
                    hasSession: hasSession,
                    requiresRecovery: requiresRecovery
                ) {
                    let description = try makeFormatDescription(
                        codec: profile.codec,
                        parameterSets: parameterSets
                    )
                    invalidateCurrentSession(waitForFrames: true)
                    try installSession(formatDescription: description, format: format, profile: profile)
                    lock.lock()
                    state.parameterSets = parameterSets
                    lock.unlock()
                } else if frame.isKeyFrame,
                          (requiresRecovery || !hasSession),
                          inlineParameterSets.isEmpty,
                          retainedParameterSets.isEmpty {
                    throw VideoDecoderError.missingParameterSets(profile.codec)
                }
                lock.lock()
                let hasUsableSession = state.session != nil
                lock.unlock()
                guard hasUsableSession else {
                    throw VideoDecoderError.missingParameterSets(profile.codec)
                }
            case .av1:
                guard frame.payloadFormat != .videoToolboxLengthPrefixed else {
                    throw VideoDecoderError.invalidAccessUnit
                }
                // Moonlight's AV1 depacketizer produces low-overhead OBU access units.
                // VideoToolbox also requires an av1C record derived from the sequence-header OBU.
                lock.lock()
                let hasSession = state.session != nil
                let priorConfiguration = state.parameterSets.first
                let requiresRecovery = state.recovery.isRequired
                lock.unlock()
                let accessUnit: AV1AccessUnit?
                if !hasSession || frame.isKeyFrame {
                    do {
                        accessUnit = try AV1AccessUnit(data: frame.data, profile: profile)
                    } catch VideoDecoderError.missingParameterSets where hasSession {
                        // A key frame may reuse the active sequence header. Malformed
                        // headers still propagate as errors instead of using stale state.
                        accessUnit = nil
                    }
                } else {
                    accessUnit = nil
                }
                if !hasSession, accessUnit == nil {
                    throw VideoDecoderError.missingParameterSets(.av1)
                }
                if let accessUnit, Self.shouldRecreateAV1Session(
                    hasSession: hasSession,
                    requiresRecovery: requiresRecovery,
                    priorConfiguration: priorConfiguration,
                    nextConfiguration: accessUnit.codecConfigurationRecord
                ) {
                    let description = try makeAV1FormatDescription(
                        format: format,
                        codecConfigurationRecord: accessUnit.codecConfigurationRecord
                    )
                    invalidateCurrentSession(waitForFrames: true)
                    try installSession(formatDescription: description, format: format, profile: profile)
                    lock.lock()
                    state.parameterSets = [accessUnit.codecConfigurationRecord]
                    lock.unlock()
                }
                payload = try EncodedVideoPayload(retaining: frame.data)
            }

            try submit(
                payload: payload,
                frame: frame,
                format: format,
                generation: generation,
                recoveryEpochAtSubmission: recoveryEpochAtSubmission
            )
            return true
        } catch let error as VideoDecoderError {
            completeOutstandingFrame(error: error, generation: generation)
            return false
        } catch {
            completeOutstandingFrame(error: .invalidAccessUnit, generation: generation)
            return false
        }
    }

    static func shouldRecreateAV1Session(
        hasSession: Bool,
        requiresRecovery: Bool,
        priorConfiguration: Data?,
        nextConfiguration: Data
    ) -> Bool {
        !hasSession || requiresRecovery || priorConfiguration != nextConfiguration
    }

    static func parameterSetsForSessionRecreation(
        inline: [Data],
        retained: [Data],
        isKeyFrame: Bool,
        hasSession: Bool,
        requiresRecovery: Bool
    ) -> [Data]? {
        let next = inline.isEmpty && isKeyFrame && (requiresRecovery || !hasSession)
            ? retained
            : inline
        guard !next.isEmpty,
              !hasSession || requiresRecovery || retained != next else {
            return nil
        }
        return next
    }

    private func submit(
        payload: EncodedVideoPayload,
        frame: CompressedVideoFrame,
        format: VideoStreamFormat,
        generation: UInt64,
        recoveryEpochAtSubmission: UInt64
    ) throws {
        let blockBuffer = try payload.makeBlockBuffer()

        lock.lock()
        guard state.running,
              state.decodeGeneration == generation,
              let session = state.session,
              let formatDescription = state.formatDescription else {
            lock.unlock()
            throw VideoDecoderError.notRunning
        }
        let sessionGeneration = state.sessionGeneration
        let hdrStaticMetadata = state.hdrStaticMetadata
        let hdrModeEnabled = state.hdrModeEnabled
        let receiveTime = Self.moonlightTimestamp(frame.receiveTimeMicroseconds)
            .flatMap(state.moonlightClockMapping.map)
        let reassemblyEnqueueTime = Self.moonlightTimestamp(frame.enqueueTimeMicroseconds)
            .flatMap(state.moonlightClockMapping.map)
        let receiveClockCalibration = state.moonlightClockMapping.evidence
        lock.unlock()

        let duration = format.redrawRate > 0
            ? CMTime(value: 1, timescale: CMTimeScale(format.redrawRate))
            : .invalid
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(frame.presentationTimeMicroseconds),
                timescale: 1_000_000
            ),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = payload.count
        var status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw VideoDecoderError.sampleBufferCreationFailed(status)
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(frame.isKeyFrame ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
            )
        }

        let submittedAt = ProcessInfo.processInfo.systemUptime
        let videoToolboxSubmitTime = VideoLatencyTimestamp(
            seconds: CACurrentMediaTime(),
            clockDomain: .clientMediaTime
        )
        let latencyMetadata = VideoFrameLatencyMetadata(
            correlationID: VideoFrameCorrelationID(
                decoderGeneration: generation,
                frameNumber: frame.frameNumber
            ),
            receiveClockCalibration: receiveClockCalibration,
            hostProcessingDuration: frame.hostProcessingLatencyTenthsOfMillisecond > 0
                ? Double(frame.hostProcessingLatencyTenthsOfMillisecond) / 10_000
                : nil,
            streamPresentationTime: VideoLatencyTimestamp(
                seconds: Double(frame.presentationTimeMicroseconds) / 1_000_000,
                clockDomain: .streamPresentationTimeline
            ),
            receiveTime: receiveTime,
            reassemblyEnqueueTime: reassemblyEnqueueTime,
            videoToolboxSubmitTime: videoToolboxSubmitTime,
            hostCaptureTimeMicroseconds: frame.hostCaptureTimeMicroseconds == 0
                ? nil
                : frame.hostCaptureTimeMicroseconds,
            appliedInputStateSequence: frame.appliedInputStateSequence,
            appliedInputEdgeID: frame.appliedInputEdgeID,
            videoConfigurationGeneration: frame.videoConfigurationGeneration
        )
        let context = Unmanaged.passRetained(DecodingFrameContext(
            frame: frame,
            decodeGeneration: generation,
            sessionGeneration: sessionGeneration,
            recoveryEpochAtSubmission: recoveryEpochAtSubmission,
            hdrModeEnabled: hdrModeEnabled,
            hdrStaticMetadata: hdrStaticMetadata,
            submittedAt: submittedAt,
            latencyMetadata: latencyMetadata
        ))
        var flagsOut = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: VTDecodeFrameFlags(rawValue: 1 << 0),
            frameRefcon: context.toOpaque(),
            infoFlagsOut: &flagsOut
        )
        if status != noErr {
            context.release()
            throw VideoDecoderError.decodeFailed(status)
        }
    }

    private func installSession(
        formatDescription: CMVideoFormatDescription,
        format: VideoStreamFormat,
        profile: VideoCodecProfile
    ) throws {
        let decoderSpecification: [CFString: Any]
        if profile.isYUV444 {
            // A family-level VTIsHardwareDecodeSupported() result is not proof
            // for a 4:4:4 profile. Require hardware for the exact format
            // description and requested 4:4:4 output tuple.
            decoderSpecification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        } else {
            switch policy {
            case .automatic:
                decoderSpecification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
            case .hardwareOnly:
                decoderSpecification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
            case .softwareOnly:
                decoderSpecification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false]
            }
        }
        let pixelFormat: OSType
        switch (profile.isTenBit, profile.isYUV444) {
        case (false, false): pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case (true, false): pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case (false, true): pixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
        case (true, true): pixelFormat = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        }
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferWidthKey: format.width,
            kCVPixelBufferHeightKey: format.height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: videoToolboxOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw VideoDecoderError.sessionCreationFailed(status)
        }
        if profile.isYUV444 {
            let property = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
            property.initialize(to: nil)
            defer {
                property.deinitialize(count: 1)
                property.deallocate()
            }
            let hardwareStatus = VTSessionCopyProperty(
                session,
                key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: kCFAllocatorDefault,
                valueOut: property
            )
            guard hardwareStatus == noErr,
                  (property.pointee as? Bool) == true else {
                VTDecompressionSessionInvalidate(session)
                throw VideoDecoderError.unsupportedHardwareCodec(profile.codec)
            }
            AppleStreamingCapabilities.recordHardwareYUV444Proof(formatMask: profile.rawValue)
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        lock.lock()
        state.sessionGeneration &+= 1
        state.session = session
        state.formatDescription = formatDescription
        lock.unlock()
    }

    private func invalidateCurrentSession(waitForFrames: Bool) {
        lock.lock()
        let session = state.session
        state.session = nil
        state.formatDescription = nil
        lock.unlock()
        guard let session else { return }
        if waitForFrames {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        VTDecompressionSessionInvalidate(session)
    }

    fileprivate func didDecode(
        context: DecodingFrameContext,
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTime: CMTime,
        duration: CMTime
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let decodeCompletionTime = VideoLatencyTimestamp(
            seconds: CACurrentMediaTime(),
            clockDomain: .clientMediaTime
        )
        if status != noErr {
            recordAsynchronousDecodeFailure(
                .decodeFailed(status),
                generation: context.decodeGeneration,
                frameNumber: context.frameNumber,
                at: now
            )
            return
        }
        if infoFlags.contains(.frameDropped) || imageBuffer == nil {
            recordAsynchronousDecodeFailure(
                .frameDropped,
                generation: context.decodeGeneration,
                frameNumber: context.frameNumber,
                at: now
            )
            return
        }
        guard let outstandingDepth = inFlightLimiter.release(
            generation: context.decodeGeneration
        ) else { return }
        lock.lock()
        guard state.running, state.decodeGeneration == context.decodeGeneration else {
            lock.unlock()
            return
        }
        state.statistics.record(.queueDepth(outstandingDepth), at: now)
        state.statistics.record(.decoded(latency: now - context.submittedAt), at: now)
        let completedLatencyMetadata = context.latencyMetadata.recordingDecodeCompletion(
            decodeCompletionTime
        )
        if let hostProcessingDuration = completedLatencyMetadata.hostProcessingDuration {
            state.latencyStatistics.record(.hostProcessing, duration: hostProcessingDuration)
        }
        state.latencyStatistics.record(
            from: completedLatencyMetadata.receiveTime,
            to: completedLatencyMetadata.videoToolboxSubmitTime,
            stage: .receiveToVideoToolboxSubmit
        )
        state.latencyStatistics.record(
            from: completedLatencyMetadata.reassemblyEnqueueTime,
            to: completedLatencyMetadata.videoToolboxSubmitTime,
            stage: .reassemblyEnqueueToVideoToolboxSubmit
        )
        state.latencyStatistics.record(
            from: completedLatencyMetadata.videoToolboxSubmitTime,
            to: completedLatencyMetadata.videoToolboxDecodeCompletionTime,
            stage: .videoToolboxDecode
        )
        state.latencyStatistics.record(
            from: completedLatencyMetadata.receiveTime,
            to: completedLatencyMetadata.videoToolboxDecodeCompletionTime,
            stage: .receiveToDecode
        )
        let requiredRecoveryBeforeDecode = state.recovery.isRequired
        state.recovery.recordSuccessfulDecode(
            isKeyFrame: context.isKeyFrame,
            frameSessionGeneration: context.sessionGeneration,
            currentSessionGeneration: state.sessionGeneration,
            frameRecoveryEpoch: context.recoveryEpochAtSubmission
        )
        if !requiredRecoveryBeforeDecode || !state.recovery.isRequired {
            state.lastError = nil
        }
        let shouldReportFirstFrame = !state.reportedFirstDecodedFrame
        state.reportedFirstDecodedFrame = true
        lock.unlock()

        guard let imageBuffer else { return }
        let resolvedColor = resolvedColorMetadata(
            fallback: context.color,
            imageBuffer: imageBuffer
        )
        applyColorAttachments(resolvedColor, to: imageBuffer, overwriteExisting: false)
        if shouldReportFirstFrame {
            firstFrameHandler(context.frameNumber)
            firstFrameMetadataHandler(
                resolvedColor,
                CVPixelBufferGetPixelFormatType(imageBuffer)
            )
        }
        renderer?.enqueue(
            DecodedVideoFrame(
                imageBuffer: imageBuffer,
                presentationTime: presentationTime,
                duration: duration,
                frameNumber: context.frameNumber,
                color: resolvedColor,
                latencyMetadata: completedLatencyMetadata
            )
        )
        lock.withLock { decodeOutcomeHandler }?(.decoded(frameNumber: context.frameNumber))
    }

    private static func moonlightTimestamp(_ microseconds: UInt64) -> VideoLatencyTimestamp? {
        guard microseconds > 0 else { return nil }
        return VideoLatencyTimestamp(
            seconds: Double(microseconds) / 1_000_000,
            clockDomain: .moonlightClientUptime
        )
    }

    func recordAsynchronousDecodeFailure(
        _ error: VideoDecoderError,
        generation: UInt64? = nil,
        frameNumber: Int? = nil,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        let failureGeneration = generation ?? state.decodeGeneration
        lock.unlock()
        guard let outstandingDepth = inFlightLimiter.release(
            generation: failureGeneration
        ) else { return }
        lock.lock()
        guard state.running, state.decodeGeneration == failureGeneration else {
            lock.unlock()
            return
        }
        state.lastError = error
        state.recovery.requireRecovery()
        state.statistics.record(.decoderError, at: time)
        state.statistics.record(.dropped(.decoder), at: time)
        state.statistics.record(.queueDepth(outstandingDepth), at: time)
        lock.unlock()
        errorHandler(error)
        if let frameNumber {
            lock.withLock { decodeOutcomeHandler }?(.failed(frameNumber: frameNumber))
        }
    }

    private func completeOutstandingFrame(
        error: VideoDecoderError,
        generation: UInt64
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let outstandingDepth = inFlightLimiter.release(
            generation: generation
        ) else { return }
        lock.lock()
        guard state.running, state.decodeGeneration == generation else {
            lock.unlock()
            return
        }
        state.lastError = error
        if error != .notRunning {
            state.recovery.requireRecovery()
        }
        state.statistics.record(.decoderError, at: now)
        state.statistics.record(.dropped(.decoder), at: now)
        state.statistics.record(.queueDepth(outstandingDepth), at: now)
        lock.unlock()
        errorHandler(error)
    }

    private func setError(_ error: VideoDecoderError) {
        lock.lock()
        state.lastError = error
        lock.unlock()
        errorHandler(error)
    }
}

private func copyParameterSets(
    from data: Data,
    ranges: [Range<Int>?]
) throws -> [Data] {
    try data.withUnsafeBytes { bytes in
        try ranges.compactMap { range in
            guard let range else { return nil }
            guard range.lowerBound >= 0,
                  range.upperBound <= bytes.count,
                  let baseAddress = bytes.baseAddress else {
                throw VideoDecoderError.invalidAccessUnit
            }
            return Data(
                bytes: baseAddress.advanced(by: range.lowerBound),
                count: range.count
            )
        }
    }
}

struct LengthPrefixedAccessUnit {
    private struct ParameterSetRanges {
        var first: Range<Int>?
        var second: Range<Int>?
        var third: Range<Int>?

        mutating func capture(codec: VideoCodec, header: UInt8, range: Range<Int>) {
            switch codec {
            case .h264:
                switch header & 0x1F {
                case 7 where first == nil: first = range
                case 8 where second == nil: second = range
                default: break
                }
            case .hevc:
                switch (header >> 1) & 0x3F {
                case 32 where first == nil: first = range
                case 33 where second == nil: second = range
                case 34 where third == nil: third = range
                default: break
                }
            case .av1:
                break
            }
        }

        func copiedData(from data: Data, codec: VideoCodec) throws -> [Data] {
            let ranges: [Range<Int>?] = codec == .h264
                ? [first, second]
                : codec == .hevc ? [first, second, third] : []
            return try copyParameterSets(from: data, ranges: ranges)
        }
    }

    let unitCount: Int
    let parameterSets: [Data]
    let payload: EncodedVideoPayload

    init(data: Data, codec: VideoCodec) throws {
        guard EncodedVideoPayload.isValidByteCount(data.count) else {
            throw VideoDecoderError.invalidAccessUnit
        }
        var ranges = ParameterSetRanges()
        var count = 0
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                guard bytes.count - offset >= MemoryLayout<UInt32>.size else {
                    throw VideoDecoderError.invalidAccessUnit
                }
                let length = Int(UInt32(bytes[offset]) << 24
                    | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8
                    | UInt32(bytes[offset + 3]))
                offset += MemoryLayout<UInt32>.size
                guard length > 0, length <= bytes.count - offset else {
                    throw VideoDecoderError.invalidAccessUnit
                }
                let range = offset..<(offset + length)
                ranges.capture(codec: codec, header: bytes[offset], range: range)
                offset += length
                count += 1
            }
        }
        guard count > 0, offset == data.count else {
            throw VideoDecoderError.invalidAccessUnit
        }
        unitCount = count
        parameterSets = try ranges.copiedData(from: data, codec: codec)
        payload = try EncodedVideoPayload(retaining: data)
    }
}

struct AnnexBAccessUnit {
    private struct ParameterSetRanges {
        var first: Range<Int>?
        var second: Range<Int>?
        var third: Range<Int>?

        mutating func capture(codec: VideoCodec, header: UInt8, range: Range<Int>) {
            switch codec {
            case .h264:
                switch header & 0x1F {
                case 7 where first == nil: first = range
                case 8 where second == nil: second = range
                default: break
                }
            case .hevc:
                switch (header >> 1) & 0x3F {
                case 32 where first == nil: first = range
                case 33 where second == nil: second = range
                case 34 where third == nil: third = range
                default: break
                }
            case .av1:
                break
            }
        }

        func copiedData(from data: Data, codec: VideoCodec) throws -> [Data] {
            let ranges: [Range<Int>?] = codec == .h264
                ? [first, second]
                : codec == .hevc ? [first, second, third] : []
            return try copyParameterSets(from: data, ranges: ranges)
        }
    }

    private struct ScanResult {
        let unitCount: Int
        let payloadByteCount: Int
        let parameterSetRanges: ParameterSetRanges
    }

    let unitCount: Int
    let parameterSets: [Data]
    let lengthPrefixedPayload: EncodedVideoPayload

    var lengthPrefixedData: Data { lengthPrefixedPayload.copiedData() }

    init(
        data: Data,
        codec: VideoCodec,
        allocator: (Int) -> UnsafeMutableRawPointer? = { malloc($0) },
        releaseObserver: (@Sendable () -> Void)? = nil
    ) throws {
        guard data.count <= EncodedVideoPayload.maximumByteCount else {
            throw VideoDecoderError.invalidAccessUnit
        }
        let scan = try data.withUnsafeBytes { bytes in
            try Self.scan(bytes, codec: codec)
        }
        unitCount = scan.unitCount
        parameterSets = try scan.parameterSetRanges.copiedData(from: data, codec: codec)

        let payload = try EncodedVideoPayload(
            allocating: scan.payloadByteCount,
            using: allocator,
            releaseObserver: releaseObserver
        )
        let wroteAllBytes = data.withUnsafeBytes { source -> Bool in
            guard let sourceBaseAddress = source.baseAddress else { return false }
            var destinationOffset = 0
            do {
                let writtenUnitCount = try Self.forEachUnit(in: source) { range in
                    var length = UInt32(range.count).bigEndian
                    withUnsafeBytes(of: &length) { lengthBytes in
                        payload.baseAddress
                            .advanced(by: destinationOffset)
                            .copyMemory(from: lengthBytes.baseAddress!, byteCount: lengthBytes.count)
                    }
                    destinationOffset += MemoryLayout<UInt32>.size
                    payload.baseAddress
                        .advanced(by: destinationOffset)
                        .copyMemory(
                            from: sourceBaseAddress.advanced(by: range.lowerBound),
                            byteCount: range.count
                        )
                    destinationOffset += range.count
                }
                return writtenUnitCount == scan.unitCount && destinationOffset == payload.count
            } catch {
                return false
            }
        }
        guard wroteAllBytes else { throw VideoDecoderError.invalidAccessUnit }
        lengthPrefixedPayload = payload
    }

    private static func scan(
        _ bytes: UnsafeRawBufferPointer,
        codec: VideoCodec
    ) throws -> ScanResult {
        var payloadByteCount = 0
        var parameterSetRanges = ParameterSetRanges()
        let unitCount = try forEachUnit(in: bytes) { range in
            guard range.count <= Int(UInt32.max),
                  payloadByteCount <= EncodedVideoPayload.maximumByteCount - MemoryLayout<UInt32>.size,
                  range.count <= EncodedVideoPayload.maximumByteCount
                    - payloadByteCount
                    - MemoryLayout<UInt32>.size else {
                throw VideoDecoderError.invalidAccessUnit
            }
            payloadByteCount += MemoryLayout<UInt32>.size + range.count
            parameterSetRanges.capture(
                codec: codec,
                header: bytes[range.lowerBound],
                range: range
            )
        }
        guard unitCount > 0, EncodedVideoPayload.isValidByteCount(payloadByteCount) else {
            throw VideoDecoderError.invalidAccessUnit
        }
        return ScanResult(
            unitCount: unitCount,
            payloadByteCount: payloadByteCount,
            parameterSetRanges: parameterSetRanges
        )
    }

    @discardableResult
    private static func forEachUnit(
        in bytes: UnsafeRawBufferPointer,
        _ body: (Range<Int>) throws -> Void
    ) throws -> Int {
        guard let firstStartCode = nextStartCode(in: bytes, startingAt: 0) else {
            throw VideoDecoderError.invalidAccessUnit
        }
        for index in 0..<firstStartCode.offset where bytes[index] != 0 {
            throw VideoDecoderError.invalidAccessUnit
        }

        var payloadStart = firstStartCode.offset + firstStartCode.length
        var unitCount = 0
        while true {
            let next = nextStartCode(in: bytes, startingAt: payloadStart)
            let payloadEnd = next?.offset ?? bytes.count
            guard payloadStart < payloadEnd else {
                throw VideoDecoderError.invalidAccessUnit
            }
            try body(payloadStart..<payloadEnd)
            unitCount += 1
            guard let next else { return unitCount }
            payloadStart = next.offset + next.length
        }
    }

    private static func nextStartCode(
        in bytes: UnsafeRawBufferPointer,
        startingAt start: Int
    ) -> (offset: Int, length: Int)? {
        var index = start
        while index <= bytes.count - 3 {
            if index <= bytes.count - 4,
               bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 0,
               bytes[index + 3] == 1 {
                return (index, 4)
            }
            if bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 1 {
                return (index, 3)
            }
            index += 1
        }
        return nil
    }
}

private func makeFormatDescription(
    codec: VideoCodec,
    parameterSets: [Data]
) throws -> CMVideoFormatDescription {
    let expectedCount = codec == .h264 ? 2 : 3
    guard parameterSets.count == expectedCount else {
        throw VideoDecoderError.missingParameterSets(codec)
    }
    return try withParameterSetPointers(parameterSets) { pointers, sizes in
        var description: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                switch codec {
                case .h264:
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSets.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &description
                    )
                case .hevc:
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSets.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )
                case .av1:
                    kCMFormatDescriptionError_InvalidParameter
                }
            }
        }
        guard status == noErr, let description else {
            throw VideoDecoderError.formatDescriptionFailed(status)
        }
        return description
    }
}

func makeAV1FormatDescription(
    format: VideoStreamFormat,
    codecConfigurationRecord: Data
) throws -> CMVideoFormatDescription {
    var description: CMVideoFormatDescription?
    let atoms: [CFString: Any] = ["av1C" as CFString: codecConfigurationRecord as CFData]
    let extensions: [CFString: Any] = [
        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms as CFDictionary,
    ]
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: kCMVideoCodecType_AV1,
        width: Int32(format.width),
        height: Int32(format.height),
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &description
    )
    guard status == noErr, let description else {
        throw VideoDecoderError.formatDescriptionFailed(status)
    }
    return description
}

struct AV1AccessUnit {
    let sequenceHeaderOBU: Data
    let codecConfigurationRecord: Data

    init(data: Data, profile: VideoCodecProfile) throws {
        let parsed = try data.withUnsafeBytes { bytes in
            try Self.parse(bytes: bytes, profile: profile)
        }
        sequenceHeaderOBU = parsed.sequenceHeaderOBU
        codecConfigurationRecord = parsed.codecConfigurationRecord
    }

    private static func parse(
        bytes: UnsafeRawBufferPointer,
        profile: VideoCodecProfile
    ) throws -> (sequenceHeaderOBU: Data, codecConfigurationRecord: Data) {
        var index = 0
        var sequenceHeaderRange: Range<Int>?
        var sequencePayloadRange: Range<Int>?
        while index < bytes.count {
            let obuStart = index
            let header = bytes[index]
            index += 1
            guard header & 0x81 == 0 else { throw VideoDecoderError.invalidAccessUnit }
            let type = (header >> 3) & 0x0F
            let hasExtension = header & 0x04 != 0
            let hasSize = header & 0x02 != 0
            if hasExtension {
                guard index < bytes.count else { throw VideoDecoderError.invalidAccessUnit }
                index += 1
            }
            guard hasSize else { throw VideoDecoderError.invalidAccessUnit }
            let payloadSize = try Self.readLEB128(bytes, index: &index)
            guard payloadSize >= 0, index <= bytes.count,
                  payloadSize <= bytes.count - index else {
                throw VideoDecoderError.invalidAccessUnit
            }
            let payloadStart = index
            let payloadEnd = index + payloadSize
            if type == 1 {
                sequenceHeaderRange = obuStart..<payloadEnd
                sequencePayloadRange = payloadStart..<payloadEnd
                break
            }
            index = payloadEnd
        }
        guard let sequenceHeaderRange, let sequencePayloadRange else {
            throw VideoDecoderError.missingParameterSets(.av1)
        }

        let sequencePayload = Array(bytes[sequencePayloadRange])
        var bits = BitReader(bytes: sequencePayload)
        let parsedProfile = try bits.readBits(3)
        guard parsedProfile == (profile.isYUV444 ? 1 : 0) else {
            throw VideoDecoderError.invalidAccessUnit
        }
        _ = try bits.readBit() // still_picture
        let reducedStillPictureHeader = try bits.readBit()
        let level: UInt8
        let tier: UInt8
        if reducedStillPictureHeader {
            level = UInt8(try bits.readBits(5))
            tier = 0
        } else {
            let timingInfoPresent = try bits.readBit()
            var decoderModelInfoPresent = false
            var bufferDelayLength = 0
            if timingInfoPresent {
                try bits.skip(64) // num_units_in_display_tick, time_scale
                let equalPictureInterval = try bits.readBit()
                if equalPictureInterval { try bits.skipUVLC() }
                decoderModelInfoPresent = try bits.readBit()
                if decoderModelInfoPresent {
                    bufferDelayLength = Int(try bits.readBits(5)) + 1
                    try bits.skip(32 + 5 + 5)
                }
            }
            let initialDisplayDelayPresent = try bits.readBit()
            let operatingPointsCount = Int(try bits.readBits(5)) + 1
            var firstLevel: UInt8 = 0
            var firstTier: UInt8 = 0
            for operatingPoint in 0..<operatingPointsCount {
                try bits.skip(12)
                let candidateLevel = UInt8(try bits.readBits(5))
                let candidateTier: UInt8 = candidateLevel > 7 ? UInt8(try bits.readBit() ? 1 : 0) : 0
                if operatingPoint == 0 {
                    firstLevel = candidateLevel
                    firstTier = candidateTier
                }
                if decoderModelInfoPresent {
                    let decoderModelPresent = try bits.readBit()
                    if decoderModelPresent {
                        try bits.skip(bufferDelayLength * 2 + 1)
                    }
                }
                if initialDisplayDelayPresent {
                    let delayPresent = try bits.readBit()
                    if delayPresent { try bits.skip(4) }
                }
            }
            level = firstLevel
            tier = firstTier
        }

        let profileAndLevel = UInt8(parsedProfile << 5) | level
        let chromaAndDepth = (tier << 7) |
            (profile.isTenBit ? 1 << 6 : 0) |
            (profile.isYUV444 ? 0 : (1 << 3) | (1 << 2))
        var record = Data([0x81, profileAndLevel, chromaAndDepth, 0])
        let sequenceHeader = Data(bytes[sequenceHeaderRange])
        record.append(sequenceHeader)
        return (sequenceHeader, record)
    }

    private static func readLEB128(_ bytes: UnsafeRawBufferPointer, index: inout Int) throws -> Int {
        var value = 0
        var shift = 0
        for _ in 0..<8 {
            guard index < bytes.count else { throw VideoDecoderError.invalidAccessUnit }
            let byte = bytes[index]
            index += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw VideoDecoderError.invalidAccessUnit
    }
}

private struct BitReader {
    let bytes: [UInt8]
    var bitOffset = 0

    mutating func readBit() throws -> Bool {
        try readBits(1) != 0
    }

    mutating func readBits(_ count: Int) throws -> UInt32 {
        guard count >= 0, count <= 32, bitOffset + count <= bytes.count * 8 else {
            throw VideoDecoderError.invalidAccessUnit
        }
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = bytes[bitOffset / 8]
            let shift = 7 - (bitOffset % 8)
            value = (value << 1) | UInt32((byte >> shift) & 1)
            bitOffset += 1
        }
        return value
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, bitOffset + count <= bytes.count * 8 else {
            throw VideoDecoderError.invalidAccessUnit
        }
        bitOffset += count
    }

    mutating func skipUVLC() throws {
        var leadingZeros = 0
        while !(try readBit()) {
            leadingZeros += 1
            guard leadingZeros < 32 else { throw VideoDecoderError.invalidAccessUnit }
        }
        try skip(leadingZeros)
    }
}

private func withParameterSetPointers<Result>(
    _ data: [Data],
    _ body: ([UnsafePointer<UInt8>], [Int]) throws -> Result
) rethrows -> Result {
    var pointers: [UnsafePointer<UInt8>] = []
    var sizes: [Int] = []
    func descend(_ index: Int) throws -> Result {
        if index == data.count {
            return try body(pointers, sizes)
        }
        return try data[index].withUnsafeBytes { bytes in
            let pointer = bytes.bindMemory(to: UInt8.self).baseAddress!
            pointers.append(pointer)
            sizes.append(bytes.count)
            defer {
                pointers.removeLast()
                sizes.removeLast()
            }
            return try descend(index + 1)
        }
    }
    return try descend(0)
}

func resolvedColorMetadata(
    fallback: VideoColorMetadata,
    imageBuffer: CVImageBuffer
) -> VideoColorMetadata {
    let colorSpace: VideoColorSpace
    if attachment(imageBuffer, kCVImageBufferColorPrimariesKey, equals: kCVImageBufferColorPrimaries_ITU_R_2020) {
        colorSpace = .rec2020
    } else if attachment(imageBuffer, kCVImageBufferColorPrimariesKey, equals: kCVImageBufferColorPrimaries_ITU_R_709_2) {
        colorSpace = .rec709
    } else if CVBufferCopyAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, nil) != nil {
        colorSpace = .rec601
    } else {
        colorSpace = fallback.colorSpace
    }

    let transferFunction: VideoTransferFunction
    if attachment(imageBuffer, kCVImageBufferTransferFunctionKey, equals: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) {
        transferFunction = .pq
    } else if attachment(imageBuffer, kCVImageBufferTransferFunctionKey, equals: kCVImageBufferTransferFunction_ITU_R_2100_HLG) {
        transferFunction = .hlg
    } else if CVBufferCopyAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, nil) != nil {
        transferFunction = .sdr
    } else {
        transferFunction = fallback.transferFunction
    }

    let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
    let range: VideoColorRange = switch pixelFormat {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        .full
    default:
        .video
    }

    var hdrMetadata = transferFunction == .sdr ? nil : fallback.hdrStaticMetadata
    let mastering = CVBufferCopyAttachment(
        imageBuffer,
        kCVImageBufferMasteringDisplayColorVolumeKey,
        nil
    ) as? Data
    let contentLight = CVBufferCopyAttachment(
        imageBuffer,
        kCVImageBufferContentLightLevelInfoKey,
        nil
    ) as? Data
    if mastering != nil || contentLight != nil {
        hdrMetadata = HDRStaticMetadata(
            minimumLuminanceNits: hdrMetadata?.minimumLuminanceNits,
            maximumLuminanceNits: hdrMetadata?.maximumLuminanceNits,
            maximumContentLightLevelNits: hdrMetadata?.maximumContentLightLevelNits,
            maximumFrameAverageLightLevelNits: hdrMetadata?.maximumFrameAverageLightLevelNits,
            masteringDisplayColorVolume: mastering ?? hdrMetadata?.masteringDisplayColorVolume,
            contentLightLevelInfo: contentLight ?? hdrMetadata?.contentLightLevelInfo
        )
    }
    return VideoColorMetadata(
        colorSpace: colorSpace,
        range: range,
        transferFunction: transferFunction,
        hdrStaticMetadata: hdrMetadata
    )
}

private func attachment(
    _ imageBuffer: CVImageBuffer,
    _ key: CFString,
    equals expected: CFString
) -> Bool {
    guard let value = CVBufferCopyAttachment(imageBuffer, key, nil) else { return false }
    return CFEqual(value, expected)
}

func applyColorAttachments(
    _ metadata: VideoColorMetadata,
    to imageBuffer: CVImageBuffer,
    overwriteExisting: Bool
) {
    let primaries: CFString
    let matrix: CFString
    switch metadata.colorSpace {
    case .rec601:
        primaries = kCVImageBufferColorPrimaries_SMPTE_C
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
    case .rec709:
        primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    case .rec2020:
        primaries = kCVImageBufferColorPrimaries_ITU_R_2020
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
    }
    let transfer: CFString = switch metadata.transferFunction {
    case .sdr: kCVImageBufferTransferFunction_ITU_R_709_2
    case .pq: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
    }
    setColorAttachment(
        imageBuffer,
        key: kCVImageBufferColorPrimariesKey,
        value: primaries,
        overwriteExisting: overwriteExisting
    )
    setColorAttachment(
        imageBuffer,
        key: kCVImageBufferYCbCrMatrixKey,
        value: matrix,
        overwriteExisting: overwriteExisting
    )
    setColorAttachment(
        imageBuffer,
        key: kCVImageBufferTransferFunctionKey,
        value: transfer,
        overwriteExisting: overwriteExisting
    )
    if metadata.colorSpace == .rec2020,
       metadata.transferFunction == .pq,
       let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) {
        setColorAttachment(
            imageBuffer,
            key: kCVImageBufferCGColorSpaceKey,
            value: colorSpace,
            overwriteExisting: true
        )
    }
    if let mastering = metadata.hdrStaticMetadata?.masteringDisplayColorVolume {
        setColorAttachment(
            imageBuffer,
            key: kCVImageBufferMasteringDisplayColorVolumeKey,
            value: mastering as NSData,
            overwriteExisting: overwriteExisting
        )
    }
    if let contentLight = metadata.hdrStaticMetadata?.contentLightLevelInfo {
        setColorAttachment(
            imageBuffer,
            key: kCVImageBufferContentLightLevelInfoKey,
            value: contentLight as NSData,
            overwriteExisting: overwriteExisting
        )
    }
}

private func setColorAttachment(
    _ imageBuffer: CVImageBuffer,
    key: CFString,
    value: CFTypeRef,
    overwriteExisting: Bool
) {
    guard overwriteExisting || CVBufferCopyAttachment(imageBuffer, key, nil) == nil else { return }
    CVBufferSetAttachment(imageBuffer, key, value, .shouldPropagate)
}
