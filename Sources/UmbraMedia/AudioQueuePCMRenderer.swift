import AudioToolbox
@preconcurrency import AVFAudio
import COpus
import CoreAudio
import Darwin
import Foundation

public enum AudioQueuePCMRendererError: Error, Sendable, Equatable, CustomStringConvertible {
    case createFailed(OSStatus)
    case deviceQueryFailed(OSStatus)
    case deviceAssignmentFailed(OSStatus)
    case channelLayoutFailed(OSStatus)
    case bufferAllocationFailed(OSStatus)
    case enqueueFailed(OSStatus)
    case primeFailed(OSStatus)
    case startFailed(OSStatus)
    case resetFailed(OSStatus)
    case stopFailed(OSStatus)
    case disposeFailed(OSStatus)

    public var description: String {
        switch self {
        case let .createFailed(status): "AudioQueue creation failed: \(status)"
        case let .deviceQueryFailed(status): "Audio output device query failed: \(status)"
        case let .deviceAssignmentFailed(status): "Audio output device assignment failed: \(status)"
        case let .channelLayoutFailed(status): "AudioQueue channel layout failed: \(status)"
        case let .bufferAllocationFailed(status): "AudioQueue buffer allocation failed: \(status)"
        case let .enqueueFailed(status): "AudioQueue enqueue failed: \(status)"
        case let .primeFailed(status): "AudioQueue prime failed: \(status)"
        case let .startFailed(status): "AudioQueue start failed: \(status)"
        case let .resetFailed(status): "AudioQueue reset failed: \(status)"
        case let .stopFailed(status): "AudioQueue stop failed: \(status)"
        case let .disposeFailed(status): "AudioQueue disposal failed: \(status)"
        }
    }
}

struct AudioQueueOperations: @unchecked Sendable {
    typealias CreateOutput = @Sendable (
        AudioStreamBasicDescription,
        AudioQueueOutputCallback,
        UnsafeMutableRawPointer,
        CFRunLoop?
    ) -> (OSStatus, AudioQueueRef?)

    let createOutput: CreateOutput
    let assignCurrentDefaultOutputDevice: @Sendable (AudioQueueRef) throws -> Void
    let applyChannelLayout: @Sendable (AudioOutputLayout, AudioQueueRef) throws -> Void
    let allocateBuffer: @Sendable (AudioQueueRef, UInt32) -> (OSStatus, AudioQueueBufferRef?)
    let enqueueBuffer: @Sendable (AudioQueueRef, AudioQueueBufferRef) -> OSStatus
    let prime: @Sendable (AudioQueueRef, inout UInt32) -> OSStatus
    let start: @Sendable (AudioQueueRef) -> OSStatus
    let isRunning: @Sendable (AudioQueueRef) -> Bool
    let reset: @Sendable (AudioQueueRef) -> OSStatus
    let stop: @Sendable (AudioQueueRef) -> OSStatus
    let dispose: @Sendable (AudioQueueRef) -> OSStatus
    let setVolume: @Sendable (AudioQueueRef, AudioQueueParameterValue) -> OSStatus

    init(
        createOutput: @escaping CreateOutput = { format, callback, userData, runLoop in
            var format = format
            var queue: AudioQueueRef?
            let status = AudioQueueNewOutput(
                &format,
                callback,
                userData,
                runLoop,
                RunLoop.Mode.default.rawValue as CFString,
                0,
                &queue
            )
            return (status, queue)
        },
        assignCurrentDefaultOutputDevice: @escaping @Sendable (AudioQueueRef) throws -> Void = {
            try AudioQueuePCMRenderer.assignCurrentDefaultOutputDevice(to: $0)
        },
        applyChannelLayout: @escaping @Sendable (AudioOutputLayout, AudioQueueRef) throws -> Void = {
            try AudioQueuePCMRenderer.applyChannelLayout($0, to: $1)
        },
        allocateBuffer: @escaping @Sendable (AudioQueueRef, UInt32) -> (OSStatus, AudioQueueBufferRef?) = {
            queue,
            byteCapacity in
            var buffer: AudioQueueBufferRef?
            let status = AudioQueueAllocateBuffer(queue, byteCapacity, &buffer)
            return (status, buffer)
        },
        enqueueBuffer: @escaping @Sendable (AudioQueueRef, AudioQueueBufferRef) -> OSStatus = {
            AudioQueueEnqueueBuffer($0, $1, 0, nil)
        },
        prime: @escaping @Sendable (AudioQueueRef, inout UInt32) -> OSStatus = {
            AudioQueuePrime($0, 0, &$1)
        },
        start: @escaping @Sendable (AudioQueueRef) -> OSStatus = {
            AudioQueueStart($0, nil)
        },
        isRunning: @escaping @Sendable (AudioQueueRef) -> Bool = { audioQueue in
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioQueueGetProperty(
                audioQueue,
                kAudioQueueProperty_IsRunning,
                &running,
                &size
            ) == noErr && running != 0
        },
        reset: @escaping @Sendable (AudioQueueRef) -> OSStatus = {
            AudioQueueReset($0)
        },
        stop: @escaping @Sendable (AudioQueueRef) -> OSStatus = {
            AudioQueueStop($0, true)
        },
        dispose: @escaping @Sendable (AudioQueueRef) -> OSStatus = {
            AudioQueueDispose($0, true)
        },
        setVolume: @escaping @Sendable (AudioQueueRef, AudioQueueParameterValue) -> OSStatus = {
            AudioQueueSetParameter($0, kAudioQueueParam_Volume, $1)
        }
    ) {
        self.createOutput = createOutput
        self.assignCurrentDefaultOutputDevice = assignCurrentDefaultOutputDevice
        self.applyChannelLayout = applyChannelLayout
        self.allocateBuffer = allocateBuffer
        self.enqueueBuffer = enqueueBuffer
        self.prime = prime
        self.start = start
        self.isRunning = isRunning
        self.reset = reset
        self.stop = stop
        self.dispose = dispose
        self.setVolume = setVolume
    }
}

struct AudioQueueThreadSchedulingPolicy: @unchecked Sendable {
    static let sdlHighRealtimePriority: Int32 = 45

    let realtimePolicy: Int32
    let realtimePriority: Int32
    private let applyCurrentThread: @Sendable (Int32, Int32) -> Int32

    init(
        realtimePolicy: Int32 = SCHED_RR,
        realtimePriority: Int32 = Self.sdlHighRealtimePriority,
        applyCurrentThread: @escaping @Sendable (Int32, Int32) -> Int32 = {
            realtimePolicy,
            realtimePriority in
            var scheduling = sched_param()
            scheduling.sched_priority = realtimePriority
            return pthread_setschedparam(pthread_self(), realtimePolicy, &scheduling)
        }
    ) {
        self.realtimePolicy = realtimePolicy
        self.realtimePriority = realtimePriority
        self.applyCurrentThread = applyCurrentThread
    }

    func promoteCurrentThread() -> Int32 {
        applyCurrentThread(realtimePolicy, realtimePriority)
    }
}

struct OutputSampleRingSnapshot: Equatable {
    let acceptedPackets: UInt64
    let playedPackets: UInt64
    let droppedPackets: UInt64
    let rejectedPackets: UInt64
    let queuedPackets: UInt64
    let scheduledPackets: UInt64
    let queuedSamples: UInt64
    let renderedRealSamples: UInt64
    let renderedSilenceSamples: UInt64
    let callbackCount: UInt64
    let underrunCount: UInt64
    let rebufferCount: UInt64
    let callbackError: OSStatus
}

struct AudioQueueBufferingPolicy: Equatable, Sendable {
    static let bufferPoolCount = 3

    let bufferPoolCount: Int
    let queueBufferFrames: Int
    let minimumPreRollFrames: Int
    let rebufferPreRollFrames: Int

    init(configuration: PCMRendererConfiguration) {
        bufferPoolCount = Self.bufferPoolCount
        queueBufferFrames = max(
            1,
            Int((configuration.outputBufferDuration * configuration.sampleRate).rounded(.up))
        )
        minimumPreRollFrames = max(
            queueBufferFrames,
            Int((configuration.minimumPreRollDuration * configuration.sampleRate).rounded(.up))
        )
        rebufferPreRollFrames = max(
            queueBufferFrames,
            Int((configuration.rebufferPreRollDuration * configuration.sampleRate).rounded(.up))
        )
    }
}

/// Fixed-capacity C11-atomic PCM ring. `write` is the sole producer and the
/// AudioQueue callback is the sole consumer.
final class OutputSampleRing: @unchecked Sendable {
    private let sampleStorage: UnsafeMutablePointer<Float>
    private let packetEndStorage: UnsafeMutablePointer<UInt64>
    private let metadataStorage: UnsafeMutablePointer<UmbraOutputBufferMetadata>
    private let ring: UnsafeMutablePointer<UmbraOutputSampleRing>
    let sampleCapacity: Int
    let packetCapacity: Int
    let channelCount: Int
    let metadataCount: Int

    init(
        frameCapacity: Int,
        packetCapacity: Int,
        channelCount: Int,
        metadataCount: Int,
        minimumPreRollFrames: Int = 0,
        rebufferPreRollFrames: Int? = nil
    ) {
        precondition(frameCapacity > 0)
        precondition(packetCapacity > 0)
        precondition(channelCount > 0)
        precondition(metadataCount > 0)
        precondition(minimumPreRollFrames >= 0)
        precondition(minimumPreRollFrames <= frameCapacity)
        let rebufferPreRollFrames = rebufferPreRollFrames ?? minimumPreRollFrames
        precondition(rebufferPreRollFrames >= minimumPreRollFrames)
        precondition(rebufferPreRollFrames <= frameCapacity)
        self.sampleCapacity = frameCapacity * channelCount
        self.packetCapacity = packetCapacity
        self.channelCount = channelCount
        self.metadataCount = metadataCount
        sampleStorage = .allocate(capacity: sampleCapacity)
        sampleStorage.initialize(repeating: 0, count: sampleCapacity)
        packetEndStorage = .allocate(capacity: packetCapacity)
        packetEndStorage.initialize(repeating: 0, count: packetCapacity)
        metadataStorage = .allocate(capacity: metadataCount)
        metadataStorage.initialize(
            repeating: UmbraOutputBufferMetadata(packet_count: 0, real_sample_count: 0),
            count: metadataCount
        )
        ring = .allocate(capacity: 1)
        umbra_output_sample_ring_init(
            ring,
            sampleStorage,
            UInt32(sampleCapacity),
            packetEndStorage,
            UInt32(packetCapacity),
            UInt32(channelCount),
            UInt32(minimumPreRollFrames * channelCount),
            UInt32(rebufferPreRollFrames * channelCount)
        )
    }

    deinit {
        metadataStorage.deinitialize(count: metadataCount)
        metadataStorage.deallocate()
        packetEndStorage.deinitialize(count: packetCapacity)
        packetEndStorage.deallocate()
        sampleStorage.deinitialize(count: sampleCapacity)
        sampleStorage.deallocate()
        ring.deallocate()
    }

    func reset(resetCounters: Bool) {
        umbra_output_sample_ring_reset(ring, resetCounters)
        for index in 0..<metadataCount {
            metadataStorage[index].packet_count = 0
            metadataStorage[index].real_sample_count = 0
        }
    }

    func setAccepting(_ accepting: Bool) {
        umbra_output_sample_ring_set_accepting(ring, accepting)
    }

    func setCallback(queue: AudioQueueRef?, enabled: Bool) {
        umbra_output_sample_ring_set_callback(
            ring,
            queue.map { UInt(bitPattern: $0) } ?? 0,
            enabled
        )
    }

    func waitUntilQuiescent() {
        while umbra_output_sample_ring_active_writers(ring) != 0
            || umbra_output_sample_ring_active_callbacks(ring) != 0 {
            sched_yield()
        }
    }

    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) -> Int32 {
        guard let channels = buffer.floatChannelData else {
            umbra_output_sample_ring_note_rejected(ring)
            return -3
        }
        return Int32(umbra_output_sample_ring_write_planar(
            ring,
            channels,
            UInt32(buffer.frameLength),
            buffer.format.channelCount
        ))
    }

    func noteRejected() {
        umbra_output_sample_ring_note_rejected(ring)
    }

    func requestFlush() {
        umbra_output_sample_ring_request_flush(ring)
    }

    func metadata(at index: Int) -> UnsafeMutablePointer<UmbraOutputBufferMetadata> {
        metadataStorage.advanced(by: index)
    }

    func beginCallback(queue: AudioQueueRef) -> Bool {
        umbra_output_sample_ring_begin_callback(ring, UInt(bitPattern: queue))
    }

    func endCallback() {
        umbra_output_sample_ring_end_callback(ring)
    }

    func fill(
        _ output: UnsafeMutablePointer<Float>,
        sampleCount: Int,
        metadata: UnsafeMutablePointer<UmbraOutputBufferMetadata>
    ) {
        umbra_output_sample_ring_fill(ring, output, UInt32(sampleCount), metadata)
    }

    func noteCallbackEnqueueFailure(
        _ status: OSStatus,
        metadata: UnsafeMutablePointer<UmbraOutputBufferMetadata>
    ) {
        umbra_output_sample_ring_callback_enqueue_failed(ring, metadata, status)
    }

    var snapshot: OutputSampleRingSnapshot {
        OutputSampleRingSnapshot(
            acceptedPackets: umbra_output_sample_ring_accepted_packets(ring),
            playedPackets: umbra_output_sample_ring_played_packets(ring),
            droppedPackets: umbra_output_sample_ring_dropped_packets(ring),
            rejectedPackets: umbra_output_sample_ring_rejected_packets(ring),
            queuedPackets: umbra_output_sample_ring_queued_packets(ring),
            scheduledPackets: umbra_output_sample_ring_scheduled_packets(ring),
            queuedSamples: umbra_output_sample_ring_queued_samples(ring),
            renderedRealSamples: umbra_output_sample_ring_rendered_real_samples(ring),
            renderedSilenceSamples: umbra_output_sample_ring_rendered_silence_samples(ring),
            callbackCount: umbra_output_sample_ring_callback_count(ring),
            underrunCount: umbra_output_sample_ring_underrun_count(ring),
            rebufferCount: umbra_output_sample_ring_rebuffer_count(ring),
            callbackError: umbra_output_sample_ring_callback_error(ring)
        )
    }

#if DEBUG
    func activateForTesting() {
        reset(resetCounters: true)
        setAccepting(true)
    }

    func fillForTesting(sampleCount: Int, metadataIndex: Int = 0) -> [Float] {
        var output = [Float](repeating: -1, count: sampleCount)
        output.withUnsafeMutableBufferPointer {
            fill($0.baseAddress!, sampleCount: sampleCount, metadata: metadata(at: metadataIndex))
        }
        return output
    }

    func completeForTesting(metadataIndex: Int = 0) {
        var scratch: Float = 0
        fill(&scratch, sampleCount: 0, metadata: metadata(at: metadataIndex))
    }
#endif
}

/// Independently retained by AudioQueue. It deliberately owns no renderer
/// state, so a failed queue disposal can retain this tiny context and its ring
/// without leaving a callback pointer to a deallocated Swift renderer.
private final class AudioQueueOutputCallbackContext: @unchecked Sendable {
    let outputRing: OutputSampleRing
    let sampleCount: Int
    let enqueueBuffer: @Sendable (AudioQueueRef, AudioQueueBufferRef) -> OSStatus

    init(
        outputRing: OutputSampleRing,
        sampleCount: Int,
        enqueueBuffer: @escaping @Sendable (AudioQueueRef, AudioQueueBufferRef) -> OSStatus
    ) {
        self.outputRing = outputRing
        self.sampleCount = sampleCount
        self.enqueueBuffer = enqueueBuffer
    }

    func callback(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        guard outputRing.beginCallback(queue: queue) else { return }
        defer { outputRing.endCallback() }
        guard let metadataAddress = buffer.pointee.mUserData else { return }
        let metadata = metadataAddress.assumingMemoryBound(to: UmbraOutputBufferMetadata.self)
        let output = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        outputRing.fill(output, sampleCount: sampleCount, metadata: metadata)
        buffer.pointee.mAudioDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
        let status = enqueueBuffer(queue, buffer)
        if status != noErr {
            outputRing.noteCallbackEnqueueFailure(status, metadata: metadata)
        }
    }
}

/// Owns the callback CFRunLoop exactly like SDL's macOS CoreAudio backend.
/// SoundSource and other HAL clients then observe a stable, dedicated audio
/// callback thread instead of AudioQueue's implicit private-thread fallback.
enum AudioQueueOutputThreadPromotionResult {
    case applied
    case failed(Int32)
    case unavailable
    case timedOut
}

protocol AudioQueueOutputThread: AnyObject, Sendable {
    func createOutput(
        format: AudioStreamBasicDescription,
        userData: UnsafeMutableRawPointer,
        createOutput: @escaping AudioQueueOperations.CreateOutput
    ) -> (OSStatus, AudioQueueRef?)
    func promoteThreadAfterSuccessfulStart() -> AudioQueueOutputThreadPromotionResult
    func stop()
}

private final class AudioQueueCallbackRunLoop: AudioQueueOutputThread, @unchecked Sendable {

    private final class PromotionRequest: @unchecked Sendable {
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private var status: Int32?

        func complete(status: Int32) {
            lock.withLock {
                self.status = status
            }
            finished.signal()
        }

        func wait() -> Int32? {
            guard finished.wait(timeout: .now() + 1) == .success else { return nil }
            return lock.withLock { status }
        }
    }

    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let schedulingPolicy: AudioQueueThreadSchedulingPolicy
    private var runLoop: CFRunLoop?
    private var status: OSStatus = OSStatus(paramErr)
    private var audioQueue: AudioQueueRef?

    init(schedulingPolicy: AudioQueueThreadSchedulingPolicy) {
        self.schedulingPolicy = schedulingPolicy
    }

    func createOutput(
        format: AudioStreamBasicDescription,
        userData: UnsafeMutableRawPointer,
        createOutput: @escaping AudioQueueOperations.CreateOutput
    ) -> (OSStatus, AudioQueueRef?) {
        let userDataAddress = UInt(bitPattern: userData)
        let thread = Thread { [self] in
            autoreleasepool {
                let callbackRunLoop = CFRunLoopGetCurrent()
                let (createStatus, createdQueue) = createOutput(
                    format,
                    umbraAudioQueueOutputCallback,
                    UnsafeMutableRawPointer(bitPattern: userDataAddress)!,
                    callbackRunLoop
                )
                lock.withLock {
                    runLoop = callbackRunLoop
                    status = createStatus
                    audioQueue = createdQueue
                }
                ready.signal()
                if createStatus == noErr, createdQueue != nil {
                    CFRunLoopRun()
                }
                finished.signal()
            }
        }
        thread.name = "UmbraAudioOutput"
        thread.start()
        ready.wait()
        return lock.withLock { (status, audioQueue) }
    }

    func promoteThreadAfterSuccessfulStart() -> AudioQueueOutputThreadPromotionResult {
        guard let callbackRunLoop = lock.withLock({ runLoop }) else {
            return .unavailable
        }
        let request = PromotionRequest()
        let schedulingPolicy = self.schedulingPolicy
        CFRunLoopPerformBlock(
            callbackRunLoop,
            RunLoop.Mode.default.rawValue as CFString
        ) {
            request.complete(status: schedulingPolicy.promoteCurrentThread())
        }
        CFRunLoopWakeUp(callbackRunLoop)
        guard let status = request.wait() else { return .timedOut }
        return status == 0 ? .applied : .failed(status)
    }

    func stop() {
        let callbackRunLoop = lock.withLock { runLoop }
        if let callbackRunLoop {
            CFRunLoopStop(callbackRunLoop)
            CFRunLoopWakeUp(callbackRunLoop)
        }
        _ = finished.wait(timeout: .now() + 1)
    }
}

/// SDL-style pull output: three mode-sized AudioQueue buffers are refilled
/// synchronously from a bounded SPSC ring. Playback consumes only complete
/// physical blocks; every underrun is padded with silence and every completed
/// buffer is immediately re-enqueued. Initial playout and post-underrun refill
/// can use separate bounded thresholds, while three buffers preserve the stable
/// AudioQueue handoff as latency mode shortens each physical block.
public final class AudioQueuePCMRenderer: PCMRendering, AudioRendererStatisticsProviding, @unchecked Sendable {
    static let maximumStartRetryCount = 5
    static let startRetryDelay: TimeInterval = 0.020
    static let maximumSlowStartRecoveryCount = 1
    static let slowStartRecoveryDelay: TimeInterval = 1.0
    static let maximumTeardownRetryCount = 5
    static let teardownRetryDelay: TimeInterval = 0.020

    public let configuration: PCMRendererConfiguration

    private let backendQueue = DispatchQueue(
        label: "app.umbra.media.audio-queue",
        qos: .userInitiated
    )
    private let backendQueueKey = DispatchSpecificKey<UInt8>()
    private let diagnostics: AudioDiagnosticReporter
    private let operations: AudioQueueOperations
    private let threadSchedulingPolicy: AudioQueueThreadSchedulingPolicy
    private let outputThreadFactory: @Sendable (AudioQueueThreadSchedulingPolicy) -> any AudioQueueOutputThread
    private let bufferingPolicy: AudioQueueBufferingPolicy
    private let outputRing: OutputSampleRing

    private var audioQueue: AudioQueueRef?
    private var callbackContext: AudioQueueOutputCallbackContext?
    private var outputThread: (any AudioQueueOutputThread)?
    private var allocatedBuffers: [AudioQueueBufferRef] = []
    private var generation: UInt64 = 0
    private var startRetryToken: UInt64 = 0
    private var scheduledStartRetryCount = 0
    private var startRetryScheduled = false
    private var startRetryExhausted = false
    private var scheduledSlowStartRecoveryCount = 0
    private var slowStartRecoveryScheduled = false
    private var promotedGeneration: UInt64?
    private var isRunning = false
    private var playbackStarted = false
    private var mute = InactiveMuteState(muteWhileInactive: true)
    private var storedError: AudioQueuePCMRendererError?

    public convenience init(
        configuration: PCMRendererConfiguration,
        diagnosticHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            configuration: configuration,
            operations: AudioQueueOperations(),
            threadSchedulingPolicy: AudioQueueThreadSchedulingPolicy(),
            diagnosticHandler: diagnosticHandler
        )
    }

    init(
        configuration: PCMRendererConfiguration,
        operations: AudioQueueOperations,
        threadSchedulingPolicy: AudioQueueThreadSchedulingPolicy = AudioQueueThreadSchedulingPolicy(),
        outputThreadFactory: @escaping @Sendable (AudioQueueThreadSchedulingPolicy) -> any AudioQueueOutputThread = {
            AudioQueueCallbackRunLoop(schedulingPolicy: $0)
        },
        diagnosticHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.operations = operations
        self.threadSchedulingPolicy = threadSchedulingPolicy
        self.outputThreadFactory = outputThreadFactory
        diagnostics = AudioDiagnosticReporter(handler: diagnosticHandler)
        let bufferingPolicy = AudioQueueBufferingPolicy(configuration: configuration)
        self.bufferingPolicy = bufferingPolicy
        let capacityFrames = max(
            bufferingPolicy.queueBufferFrames,
            Int((configuration.maximumQueuedDuration * configuration.sampleRate).rounded(.up))
        )
        outputRing = OutputSampleRing(
            frameCapacity: capacityFrames,
            packetCapacity: configuration.maximumQueuedBuffers,
            channelCount: Int(configuration.layout.channelCount),
            metadataCount: bufferingPolicy.bufferPoolCount,
            minimumPreRollFrames: bufferingPolicy.minimumPreRollFrames,
            rebufferPreRollFrames: bufferingPolicy.rebufferPreRollFrames
        )
        mute = InactiveMuteState(muteWhileInactive: configuration.muteWhileInactive)
        backendQueue.setSpecific(key: backendQueueKey, value: 1)
    }

    deinit {
        stop()
    }

    public var lastError: AudioQueuePCMRendererError? {
        backendQueue.sync {
            let callbackError = outputRing.snapshot.callbackError
            return callbackError == noErr ? storedError : .enqueueFailed(callbackError)
        }
    }

    public var isMuted: Bool {
        backendQueue.sync { mute.isMuted }
    }

    public var statistics: AudioRendererStatistics {
        backendQueue.sync {
            let snapshot = outputRing.snapshot
            let queuedPackets = snapshot.queuedPackets + snapshot.scheduledPackets
            return AudioRendererStatistics(
                enqueuedBuffers: snapshot.acceptedPackets,
                playedBuffers: snapshot.playedPackets,
                droppedBuffers: snapshot.droppedPackets,
                rejectedBuffers: snapshot.rejectedPackets,
                queuedBuffers: Int(clamping: queuedPackets),
                scheduledBuffers: Int(clamping: snapshot.scheduledPackets),
                playbackStarted: playbackStarted,
                queuedDurationMilliseconds: Double(snapshot.queuedSamples)
                    / Double(configuration.layout.channelCount)
                    / configuration.sampleRate
                    * 1_000,
                underrunCount: snapshot.underrunCount,
                rebufferCount: snapshot.rebufferCount
            )
        }
    }

    public func start() throws {
        try backendQueue.sync {
            guard !isRunning else { return }
            guard audioQueue == nil else {
                throw storedError ?? AudioQueuePCMRendererError.disposeFailed(OSStatus(paramErr))
            }
            generation &+= 1
            resetStartRetryState()
            let currentGeneration = generation
            outputRing.setAccepting(false)
            outputRing.setCallback(queue: nil, enabled: false)
            outputRing.waitUntilQuiescent()
            outputRing.reset(resetCounters: true)

            let streamDescription = Self.streamDescription(for: configuration)
            let callbackContext = AudioQueueOutputCallbackContext(
                outputRing: outputRing,
                sampleCount: bufferingPolicy.queueBufferFrames
                    * Int(configuration.layout.channelCount),
                enqueueBuffer: operations.enqueueBuffer
            )
            let callbackUserData = Unmanaged.passRetained(callbackContext).toOpaque()
            let outputThread = outputThreadFactory(threadSchedulingPolicy)
            let (createStatus, createdQueue) = outputThread.createOutput(
                format: streamDescription,
                userData: callbackUserData,
                createOutput: operations.createOutput
            )
            guard createStatus == noErr, let createdQueue else {
                outputThread.stop()
                Unmanaged<AudioQueueOutputCallbackContext>
                    .fromOpaque(callbackUserData)
                    .release()
                throw AudioQueuePCMRendererError.createFailed(createStatus)
            }
            self.callbackContext = callbackContext
            self.outputThread = outputThread

            var buffers: [AudioQueueBufferRef] = []
            do {
                try operations.assignCurrentDefaultOutputDevice(createdQueue)
                try operations.applyChannelLayout(configuration.layout, createdQueue)
                let bufferByteCapacity = UInt32(bufferingPolicy.queueBufferFrames)
                    * UInt32(configuration.layout.channelCount)
                    * UInt32(MemoryLayout<Float>.size)
                buffers.reserveCapacity(bufferingPolicy.bufferPoolCount)
                for index in 0..<bufferingPolicy.bufferPoolCount {
                    let (status, buffer) = operations.allocateBuffer(createdQueue, bufferByteCapacity)
                    guard status == noErr, let buffer else {
                        throw AudioQueuePCMRendererError.bufferAllocationFailed(status)
                    }
                    buffer.pointee.mUserData = UnsafeMutableRawPointer(outputRing.metadata(at: index))
                    buffers.append(buffer)
                }

                audioQueue = createdQueue
                allocatedBuffers = buffers
                isRunning = true
                playbackStarted = false
                storedError = nil
                outputRing.setCallback(queue: createdQueue, enabled: true)
                outputRing.setAccepting(true)
                applyMuteState(to: createdQueue)
                try enqueueInitialSilence(on: createdQueue)
                if let error = attemptHardwareStart(
                    createdQueue,
                    generation: currentGeneration,
                    shouldPrime: true
                ) {
                    throw error
                }
            } catch {
                isRunning = false
                playbackStarted = false
                generation &+= 1
                resetStartRetryState()
                outputRing.setAccepting(false)
                outputRing.setCallback(queue: nil, enabled: false)
                var teardownRetryCount = 0
                let disposeStatus = performTeardownOperation(
                    { operations.dispose(createdQueue) },
                    scheduledRetryCount: &teardownRetryCount
                )
                outputRing.waitUntilQuiescent()
                if disposeStatus == noErr {
                    releaseCallbackContextAfterDispose()
                    self.outputThread?.stop()
                    self.outputThread = nil
                    audioQueue = nil
                    allocatedBuffers.removeAll()
                } else {
                    audioQueue = createdQueue
                    allocatedBuffers = buffers
                    let disposeError = AudioQueuePCMRendererError.disposeFailed(disposeStatus)
                    storedError = disposeError
                    diagnostics.report(disposeError.description)
                }
                if storedError == nil {
                    storedError = error as? AudioQueuePCMRendererError
                }
                throw error
            }
        }
    }

    @discardableResult
    public func stop() -> PCMRendererTeardownStatus {
        if DispatchQueue.getSpecific(key: backendQueueKey) != nil {
            return stopOnBackend()
        }
        return backendQueue.sync { stopOnBackend() }
    }

    private func stopOnBackend() -> PCMRendererTeardownStatus {
        guard isRunning || audioQueue != nil else { return .complete }
        isRunning = false
        playbackStarted = false
        generation &+= 1
        resetStartRetryState()
        outputRing.setAccepting(false)
        outputRing.setCallback(queue: nil, enabled: false)
        guard let audioQueue else {
            outputRing.waitUntilQuiescent()
            return .complete
        }
        _ = operations.setVolume(audioQueue, 0)
        var teardownRetryCount = 0
        let stopStatus = performTeardownOperation(
            { operations.stop(audioQueue) },
            scheduledRetryCount: &teardownRetryCount
        )
        if stopStatus != noErr {
            let error = AudioQueuePCMRendererError.stopFailed(stopStatus)
            storedError = error
            diagnostics.report(error.description)
        }
        let disposeStatus = performTeardownOperation(
            { operations.dispose(audioQueue) },
            scheduledRetryCount: &teardownRetryCount
        )
        outputRing.waitUntilQuiescent()
        guard disposeStatus == noErr else {
            let error = AudioQueuePCMRendererError.disposeFailed(disposeStatus)
            storedError = error
            diagnostics.report(error.description)
            return .retryRequired
        }
        releaseCallbackContextAfterDispose()
        outputThread?.stop()
        outputThread = nil
        self.audioQueue = nil
        allocatedBuffers.removeAll()
        reportTeardownSummary()
        if stopStatus == noErr {
            storedError = nil
        }
        return .complete
    }

    private func reportTeardownSummary() {
        let snapshot = outputRing.snapshot
        let channelCount = UInt64(configuration.layout.channelCount)
        diagnostics.report(
            "Audio output summary: packets accepted=\(snapshot.acceptedPackets) "
                + "played=\(snapshot.playedPackets) dropped=\(snapshot.droppedPackets) "
                + "rejected=\(snapshot.rejectedPackets); callbacks=\(snapshot.callbackCount) "
                + "rebuffers=\(snapshot.rebufferCount); "
                + "frames real=\(snapshot.renderedRealSamples / channelCount) "
                + "silence=\(snapshot.renderedSilenceSamples / channelCount)."
        )
    }

    public func enqueue(_ decoded: DecodedAudioBuffer) {
        let buffer = decoded.buffer
        guard Self.formatsMatch(buffer.format, configuration: configuration) else {
            outputRing.noteRejected()
            return
        }
        _ = outputRing.write(buffer)
    }

#if DEBUG
    var outputRingSnapshotForTesting: OutputSampleRingSnapshot {
        backendQueue.sync { outputRing.snapshot }
    }

    @discardableResult
    func invokeOutputCallbackForTesting(bufferIndex: Int = 0) -> Bool {
        backendQueue.sync {
            guard let audioQueue,
                  let callbackContext,
                  allocatedBuffers.indices.contains(bufferIndex) else {
                return false
            }
            callbackContext.callback(queue: audioQueue, buffer: allocatedBuffers[bufferIndex])
            return true
        }
    }
#endif

    public func flush() {
        backendQueue.sync {
            guard isRunning else { return }
            outputRing.setAccepting(false)
            outputRing.waitUntilQuiescent()
            outputRing.requestFlush()
            outputRing.setAccepting(true)
        }
    }

    public func setApplicationActive(_ active: Bool) {
        backendQueue.async { [self] in
            mute.setApplicationActive(active)
            if let audioQueue { applyMuteState(to: audioQueue) }
        }
    }

    public func setMuteWhileInactive(_ enabled: Bool) {
        backendQueue.async { [self] in
            mute.muteWhileInactive = enabled
            if let audioQueue { applyMuteState(to: audioQueue) }
        }
    }

    public func setManuallyMuted(_ muted: Bool) {
        backendQueue.async { [self] in
            mute.manuallyMuted = muted
            if let audioQueue { applyMuteState(to: audioQueue) }
        }
    }

    static func streamDescription(
        for configuration: PCMRendererConfiguration
    ) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(configuration.layout.channelCount)
            * UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: configuration.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(configuration.layout.channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    fileprivate static func applyChannelLayout(
        _ outputLayout: AudioOutputLayout,
        to audioQueue: AudioQueueRef
    ) throws {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = outputLayout.coreAudioLayoutTag
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        layout.mNumberChannelDescriptions = 0
        let status = AudioQueueSetProperty(
            audioQueue,
            kAudioQueueProperty_ChannelLayout,
            &layout,
            UInt32(MemoryLayout<AudioChannelLayout>.size)
        )
        guard status == noErr else {
            throw AudioQueuePCMRendererError.channelLayoutFailed(status)
        }
    }

    fileprivate static func assignCurrentDefaultOutputDevice(
        to audioQueue: AudioQueueRef
    ) throws {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            0,
            nil,
            &deviceSize,
            &device
        )
        guard deviceStatus == noErr, device != kAudioObjectUnknown else {
            throw AudioQueuePCMRendererError.deviceQueryFailed(deviceStatus)
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedDeviceUID: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = AudioObjectGetPropertyData(
            device,
            &uidAddress,
            0,
            nil,
            &uidSize,
            &unmanagedDeviceUID
        )
        guard uidStatus == noErr, let unmanagedDeviceUID else {
            throw AudioQueuePCMRendererError.deviceQueryFailed(uidStatus)
        }
        let deviceUID = unmanagedDeviceUID.takeRetainedValue()
        var queueDeviceUID = Unmanaged.passUnretained(deviceUID)
        let assignmentStatus = withUnsafePointer(to: &queueDeviceUID) { pointer in
            AudioQueueSetProperty(
                audioQueue,
                kAudioQueueProperty_CurrentDevice,
                pointer,
                UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            )
        }
        guard assignmentStatus == noErr else {
            throw AudioQueuePCMRendererError.deviceAssignmentFailed(assignmentStatus)
        }
    }

    private static func formatsMatch(
        _ format: AVAudioFormat,
        configuration: PCMRendererConfiguration
    ) -> Bool {
        format.commonFormat == .pcmFormatFloat32
            && !format.isInterleaved
            && abs(format.sampleRate - configuration.sampleRate) < 0.5
            && format.channelCount == configuration.layout.channelCount
    }

    private func enqueueInitialSilence(on audioQueue: AudioQueueRef) throws {
        let sampleCount = bufferingPolicy.queueBufferFrames
            * Int(configuration.layout.channelCount)
        let byteCount = sampleCount * MemoryLayout<Float>.size
        for (index, buffer) in allocatedBuffers.enumerated() {
            let metadata = outputRing.metadata(at: index)
            metadata.pointee.packet_count = 0
            metadata.pointee.real_sample_count = 0
            memset(buffer.pointee.mAudioData, 0, byteCount)
            buffer.pointee.mAudioDataByteSize = UInt32(byteCount)
            let status = operations.enqueueBuffer(audioQueue, buffer)
            guard status == noErr else {
                throw AudioQueuePCMRendererError.enqueueFailed(status)
            }
        }
    }

    private func applyMuteState(to audioQueue: AudioQueueRef) {
        _ = operations.setVolume(audioQueue, mute.isMuted ? 0 : 1)
    }

    private func releaseCallbackContextAfterDispose() {
        guard let callbackContext else { return }
        Unmanaged.passUnretained(callbackContext).release()
        self.callbackContext = nil
    }

    @discardableResult
    private func attemptHardwareStart(
        _ audioQueue: AudioQueueRef,
        generation: UInt64,
        shouldPrime: Bool
    ) -> AudioQueuePCMRendererError? {
        guard isRunning, self.generation == generation else { return nil }
        if shouldPrime {
            var primedFrames: UInt32 = 0
            let primeStatus = operations.prime(audioQueue, &primedFrames)
            guard primeStatus == noErr else {
                return handleStartPreparationFailure(
                    .primeFailed(primeStatus),
                    status: primeStatus,
                    generation: generation
                )
            }
        }
        let startStatus = operations.start(audioQueue)
        guard startStatus == noErr else {
            return handleStartPreparationFailure(
                .startFailed(startStatus),
                status: startStatus,
                generation: generation
            )
        }
        storedError = nil
        playbackStarted = true
        resetStartRetryState()
        applyMuteState(to: audioQueue)
        promoteCallbackThreadAfterSuccessfulStart(generation: generation)
        diagnostics.report(
            "Audio output started with \(bufferingPolicy.bufferPoolCount) direct-pull buffers "
                + "(\(bufferingPolicy.queueBufferFrames) frames each; "
                + "preroll \(bufferingPolicy.minimumPreRollFrames) frames)."
        )
        return nil
    }

    private func promoteCallbackThreadAfterSuccessfulStart(generation: UInt64) {
        guard promotedGeneration != generation else { return }
        promotedGeneration = generation
        guard let outputThread else {
            diagnostics.report(
                "Audio callback thread scheduling promotion was unavailable; playback continues."
            )
            return
        }
        switch outputThread.promoteThreadAfterSuccessfulStart() {
        case .applied:
            break
        case let .failed(status):
            diagnostics.report(
                "Audio callback thread SCHED_RR priority "
                    + "\(threadSchedulingPolicy.realtimePriority) promotion failed: \(status); "
                    + "playback continues."
            )
        case .unavailable:
            diagnostics.report(
                "Audio callback thread scheduling promotion was unavailable; playback continues."
            )
        case .timedOut:
            diagnostics.report(
                "Audio callback thread scheduling promotion timed out; playback continues."
            )
        }
    }

    private func handleStartPreparationFailure(
        _ error: AudioQueuePCMRendererError,
        status: OSStatus,
        generation: UInt64
    ) -> AudioQueuePCMRendererError? {
        if Self.shouldRetryStart(
            status: status,
            scheduledRetryCount: scheduledStartRetryCount
        ) {
            scheduleStartRetry(generation: generation)
            return nil
        }
        storedError = error
        if status == kAudioQueueErr_CannotStartYet {
            if !startRetryExhausted {
                diagnostics.report(
                    "\(error.description) after \(scheduledStartRetryCount) bounded retries."
                )
            }
            startRetryExhausted = true
            scheduleSlowStartRecovery(generation: generation)
        } else {
            diagnostics.report(error.description)
        }
        return error
    }

    private func scheduleStartRetry(generation: UInt64) {
        guard !startRetryScheduled else { return }
        scheduledStartRetryCount += 1
        startRetryScheduled = true
        let retryToken = startRetryToken
        backendQueue.asyncAfter(deadline: .now() + Self.startRetryDelay) { [weak self] in
            guard let self,
                  self.isRunning,
                  self.generation == generation,
                  self.startRetryToken == retryToken,
                  let audioQueue = self.audioQueue else { return }
            self.startRetryScheduled = false
            if self.operations.isRunning(audioQueue) {
                self.storedError = nil
                self.playbackStarted = true
                self.resetStartRetryState()
                self.applyMuteState(to: audioQueue)
                self.promoteCallbackThreadAfterSuccessfulStart(generation: generation)
                return
            }
            _ = self.attemptHardwareStart(
                audioQueue,
                generation: generation,
                shouldPrime: false
            )
        }
    }

    private func resetStartRetryState() {
        startRetryToken &+= 1
        rearmFastStartRetries()
        scheduledSlowStartRecoveryCount = 0
        slowStartRecoveryScheduled = false
    }

    private func rearmFastStartRetries() {
        scheduledStartRetryCount = 0
        startRetryScheduled = false
        startRetryExhausted = false
    }

    private func scheduleSlowStartRecovery(generation: UInt64) {
        guard !slowStartRecoveryScheduled,
              scheduledSlowStartRecoveryCount < Self.maximumSlowStartRecoveryCount else { return }
        scheduledSlowStartRecoveryCount += 1
        slowStartRecoveryScheduled = true
        let retryToken = startRetryToken
        backendQueue.asyncAfter(deadline: .now() + Self.slowStartRecoveryDelay) { [weak self] in
            guard let self,
                  self.isRunning,
                  self.generation == generation,
                  self.startRetryToken == retryToken,
                  let audioQueue = self.audioQueue else { return }
            self.slowStartRecoveryScheduled = false
            if self.operations.isRunning(audioQueue) {
                self.storedError = nil
                self.playbackStarted = true
                self.resetStartRetryState()
                self.applyMuteState(to: audioQueue)
                self.promoteCallbackThreadAfterSuccessfulStart(generation: generation)
                return
            }
            self.rearmFastStartRetries()
            _ = self.attemptHardwareStart(
                audioQueue,
                generation: generation,
                shouldPrime: false
            )
        }
    }

    static func shouldRetryStart(status: OSStatus, scheduledRetryCount: Int) -> Bool {
        status == kAudioQueueErr_CannotStartYet
            && scheduledRetryCount < maximumStartRetryCount
    }

    private func performTeardownOperation(
        _ operation: () -> OSStatus,
        scheduledRetryCount: inout Int
    ) -> OSStatus {
        var status = operation()
        while Self.shouldRetryTeardown(
            status: status,
            scheduledRetryCount: scheduledRetryCount
        ) {
            scheduledRetryCount += 1
            Thread.sleep(forTimeInterval: Self.teardownRetryDelay)
            status = operation()
        }
        return status
    }

    static func shouldRetryTeardown(status: OSStatus, scheduledRetryCount: Int) -> Bool {
        status == kAudioQueueErr_DisposalPending
            && scheduledRetryCount < maximumTeardownRetryCount
    }
}

private let umbraAudioQueueOutputCallback: AudioQueueOutputCallback = {
    userData,
    queue,
    buffer in
    guard let userData else { return }
    Unmanaged<AudioQueueOutputCallbackContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .callback(queue: queue, buffer: buffer)
}
