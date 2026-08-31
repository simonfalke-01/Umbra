import AudioToolbox
import COpus
import Foundation

public struct ClientMicrophonePCMFrame: Equatable, Sendable {
    public static let sampleRate = 48_000
    public static let sampleCount = 960
    public let samples: [Float]

    public init(samples: [Float]) {
        precondition(samples.count == Self.sampleCount)
        self.samples = samples
    }
}

public protocol ClientMicrophoneCapturing: AnyObject, Sendable {
    func start(
        frameHandler: @escaping @Sendable (ClientMicrophonePCMFrame) -> Void,
        discontinuityHandler: @escaping @Sendable () -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws
    func stop()
}

public protocol ClientMicrophoneCaptureCreating: Sendable {
    func makeCapture() -> any ClientMicrophoneCapturing
}

public struct AudioQueueMicrophoneCaptureFactory: ClientMicrophoneCaptureCreating, Sendable {
    public init() {}
    public func makeCapture() -> any ClientMicrophoneCapturing {
        AudioQueueMicrophoneCapture()
    }
}

public enum AudioQueueMicrophoneCaptureError: Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyRunning
    case queueCreationFailed(OSStatus)
    case bufferAllocationFailed(OSStatus)
    case bufferEnqueueFailed(OSStatus)
    case propertyListenerFailed(OSStatus)
    case queueStartFailed(OSStatus)
    case startCancelled
    case inputStopped

    public var description: String {
        switch self {
        case .alreadyRunning: "Microphone capture is already running"
        case let .queueCreationFailed(status): "AudioQueue input creation failed (\(status))"
        case let .bufferAllocationFailed(status): "AudioQueue input buffer allocation failed (\(status))"
        case let .bufferEnqueueFailed(status): "AudioQueue input buffer enqueue failed (\(status))"
        case let .propertyListenerFailed(status): "AudioQueue input listener installation failed (\(status))"
        case let .queueStartFailed(status): "AudioQueue input start failed (\(status))"
        case .startCancelled: "Microphone capture was stopped while starting"
        case .inputStopped: "AudioQueue microphone input stopped unexpectedly"
        }
    }
}

/// Input-only AudioQueue capture. The real-time callback only copies into a
/// preallocated ring, signals an existing semaphore, and re-enqueues its buffer.
/// Exact 20 ms frame construction and every downstream operation happen off-callback.
public final class AudioQueueMicrophoneCapture: ClientMicrophoneCapturing, @unchecked Sendable {
    enum LifecycleState: Equatable {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    private let lifecycle = NSCondition()
    private let sampleRing = MicrophoneSampleRing(capacity: ClientMicrophonePCMFrame.sampleCount * 8)
    private let availableSamples = DispatchSemaphore(value: 0)
    private let workerQueue = DispatchQueue(
        label: "io.umbra.microphone.capture",
        qos: .userInteractive
    )
    private let workerQueueKey = DispatchSpecificKey<Void>()
    private let resourceFactory: any AudioQueueInputResourceCreating
    private var lifecycleState: LifecycleState = .idle
    private var stopRequestedWhileStarting = false
    private var resource: (any AudioQueueInputResource)?
    private var frameHandler: (@Sendable (ClientMicrophonePCMFrame) -> Void)?
    private var discontinuityHandler: (@Sendable () -> Void)?
    private var failureHandler: (@Sendable (Error) -> Void)?

    public convenience init() {
        self.init(resourceFactory: SystemAudioQueueInputResourceFactory())
    }

    init(resourceFactory: any AudioQueueInputResourceCreating) {
        self.resourceFactory = resourceFactory
        workerQueue.setSpecific(key: workerQueueKey, value: ())
    }

    deinit {
        stop()
    }

    /// Probes creation of the real mono 48-kHz AudioQueue input without starting capture.
    public static func isAvailable() -> Bool {
        var format = AudioStreamBasicDescription(
            mSampleRate: Double(ClientMicrophonePCMFrame.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var queue: AudioQueueRef?
        let result = AudioQueueNewInput(
            &format,
            microphoneAvailabilityProbeCallback,
            nil,
            nil,
            nil,
            0,
            &queue
        )
        if let queue {
            AudioQueueDispose(queue, true)
        }
        return result == noErr && queue != nil
    }

    public func start(
        frameHandler: @escaping @Sendable (ClientMicrophonePCMFrame) -> Void,
        discontinuityHandler: @escaping @Sendable () -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        lifecycle.lock()
        guard lifecycleState == .idle || lifecycleState == .stopped else {
            lifecycle.unlock()
            throw AudioQueueMicrophoneCaptureError.alreadyRunning
        }
        lifecycleState = .starting
        stopRequestedWhileStarting = false
        self.frameHandler = frameHandler
        self.discontinuityHandler = discontinuityHandler
        self.failureHandler = failureHandler
        lifecycle.unlock()

        sampleRing.reset(accepting: true)
        workerQueue.async { [self] in consumeSamples() }
        var createdResource: (any AudioQueueInputResource)?
        do {
            let newResource = try resourceFactory.makeResource(owner: self)
            createdResource = newResource
            try throwIfStartWasStopped()
            try newResource.start()
            try throwIfStartWasStopped()

            lifecycle.lock()
            if stopRequestedWhileStarting {
                lifecycleState = .stopping
                lifecycle.unlock()
                throw AudioQueueMicrophoneCaptureError.startCancelled
            }
            resource = newResource
            lifecycleState = .running
            lifecycle.broadcast()
            lifecycle.unlock()
        } catch {
            finishStartFailure(resource: createdResource)
            throw error
        }
    }

    public func stop() {
        lifecycle.lock()
        switch lifecycleState {
        case .starting:
            stopRequestedWhileStarting = true
            if DispatchQueue.getSpecific(key: workerQueueKey) != nil {
                lifecycle.unlock()
                return
            }
            while lifecycleState == .starting || lifecycleState == .stopping {
                lifecycle.wait()
            }
            lifecycle.unlock()
            return
        case .running:
            lifecycleState = .stopping
            let resource = self.resource
            self.resource = nil
            lifecycle.unlock()
            finishStop(resource: resource)
        case .stopping:
            while lifecycleState == .stopping { lifecycle.wait() }
            lifecycle.unlock()
        case .idle, .stopped:
            lifecycleState = .stopped
            clearHandlersLocked()
            lifecycle.broadcast()
            lifecycle.unlock()
            sampleRing.reset(accepting: false)
        }
    }

    fileprivate func receive(_ buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        if byteCount > 0, byteCount.isMultiple(of: MemoryLayout<Float>.size) {
            let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
            sampleRing.write(samples, count: byteCount / MemoryLayout<Float>.size)
            availableSamples.signal()
        }
        if sampleRing.isAccepting {
            let result = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            if result != noErr {
                sampleRing.markTerminalFailure()
                availableSamples.signal()
            }
        }
    }

    private func consumeSamples() {
        while true {
            availableSamples.wait()
            drain: while true {
                switch sampleRing.take() {
                case .discontinuity:
                    handlerSnapshot().discontinuity?()
                case .failure:
                    handlerSnapshot().failure?(
                        AudioQueueMicrophoneCaptureError.inputStopped
                    )
                    return
                case let .frame(samples):
                    handlerSnapshot().frame?(ClientMicrophonePCMFrame(samples: samples))
                case .empty:
                    break drain
                }
            }
            if !sampleRing.isAccepting { return }
        }
    }

    fileprivate func audioQueueRunningStateChanged(_ queue: AudioQueueRef) {
        guard sampleRing.isAccepting else { return }
        var isRunning: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        if AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &isRunning, &byteCount) != noErr
            || isRunning == 0 {
            sampleRing.markTerminalFailure()
            availableSamples.signal()
        }
    }

    private func waitForWorkerExit() {
        guard DispatchQueue.getSpecific(key: workerQueueKey) == nil else { return }
        workerQueue.sync {}
    }

    var lifecycleStateForTesting: LifecycleState {
        lifecycle.withLock { lifecycleState }
    }

    private func throwIfStartWasStopped() throws {
        let cancelled = lifecycle.withLock { stopRequestedWhileStarting }
        if cancelled { throw AudioQueueMicrophoneCaptureError.startCancelled }
    }

    private func finishStartFailure(resource: (any AudioQueueInputResource)?) {
        lifecycle.withLock { lifecycleState = .stopping }
        sampleRing.setAccepting(false)
        resource?.stopAndDispose()
        availableSamples.signal()
        waitForWorkerExit()
        sampleRing.reset(accepting: false)
        lifecycle.lock()
        self.resource = nil
        clearHandlersLocked()
        lifecycleState = .stopped
        lifecycle.broadcast()
        lifecycle.unlock()
    }

    private func finishStop(resource: (any AudioQueueInputResource)?) {
        sampleRing.setAccepting(false)
        resource?.stopAndDispose()
        availableSamples.signal()
        waitForWorkerExit()
        sampleRing.reset(accepting: false)
        lifecycle.lock()
        clearHandlersLocked()
        lifecycleState = .stopped
        lifecycle.broadcast()
        lifecycle.unlock()
    }

    private func handlerSnapshot() -> (
        frame: (@Sendable (ClientMicrophonePCMFrame) -> Void)?,
        discontinuity: (@Sendable () -> Void)?,
        failure: (@Sendable (Error) -> Void)?
    ) {
        lifecycle.withLock { (frameHandler, discontinuityHandler, failureHandler) }
    }

    private func clearHandlersLocked() {
        frameHandler = nil
        discontinuityHandler = nil
        failureHandler = nil
    }
}

private let microphoneAvailabilityProbeCallback: AudioQueueInputCallback = { _, _, _, _, _, _ in }

protocol AudioQueueInputResource: AnyObject, Sendable {
    func start() throws
    func stopAndDispose()
}

protocol AudioQueueInputResourceCreating: Sendable {
    func makeResource(owner: AudioQueueMicrophoneCapture) throws -> any AudioQueueInputResource
}

private struct SystemAudioQueueInputResourceFactory: AudioQueueInputResourceCreating, Sendable {
    func makeResource(owner: AudioQueueMicrophoneCapture) throws -> any AudioQueueInputResource {
        try SystemAudioQueueInputResource(owner: owner)
    }
}

private final class SystemAudioQueueInputResource: AudioQueueInputResource, @unchecked Sendable {
    private static let inputBufferCount = 4
    private static let inputBufferByteCount = ClientMicrophonePCMFrame.sampleCount * MemoryLayout<Float>.size
    private let lock = NSLock()
    private let ownerContext: UnsafeMutableRawPointer
    private var queue: AudioQueueRef?
    private var listenerInstalled = false

    init(owner: AudioQueueMicrophoneCapture) throws {
        ownerContext = Unmanaged.passUnretained(owner).toOpaque()
        var format = AudioStreamBasicDescription(
            mSampleRate: Double(ClientMicrophonePCMFrame.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var queue: AudioQueueRef?
        let createResult = AudioQueueNewInput(
            &format,
            clientMicrophoneAudioQueueCallback,
            Unmanaged.passUnretained(owner).toOpaque(),
            nil,
            nil,
            0,
            &queue
        )
        guard createResult == noErr, let queue else {
            throw AudioQueueMicrophoneCaptureError.queueCreationFailed(createResult)
        }
        self.queue = queue
        do {
            for _ in 0..<Self.inputBufferCount {
                var buffer: AudioQueueBufferRef?
                let allocationResult = AudioQueueAllocateBuffer(
                    queue,
                    UInt32(Self.inputBufferByteCount),
                    &buffer
                )
                guard allocationResult == noErr, let buffer else {
                    throw AudioQueueMicrophoneCaptureError.bufferAllocationFailed(allocationResult)
                }
                let enqueueResult = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
                guard enqueueResult == noErr else {
                    throw AudioQueueMicrophoneCaptureError.bufferEnqueueFailed(enqueueResult)
                }
            }
            let listenerResult = AudioQueueAddPropertyListener(
                queue,
                kAudioQueueProperty_IsRunning,
                clientMicrophoneAudioQueuePropertyCallback,
                Unmanaged.passUnretained(owner).toOpaque()
            )
            guard listenerResult == noErr else {
                throw AudioQueueMicrophoneCaptureError.propertyListenerFailed(listenerResult)
            }
            listenerInstalled = true
        } catch {
            stopAndDispose()
            throw error
        }
    }

    deinit { stopAndDispose() }

    func start() throws {
        let queue = try lock.withLock { () throws -> AudioQueueRef in
            guard let queue = self.queue else {
                throw AudioQueueMicrophoneCaptureError.startCancelled
            }
            return queue
        }
        let result = AudioQueueStart(queue, nil)
        guard result == noErr else { throw AudioQueueMicrophoneCaptureError.queueStartFailed(result) }
    }

    func stopAndDispose() {
        let owned = lock.withLock { () -> (AudioQueueRef, Bool)? in
            guard let queue = self.queue else { return nil }
            self.queue = nil
            let installed = listenerInstalled
            listenerInstalled = false
            return (queue, installed)
        }
        guard let (queue, listenerInstalled) = owned else { return }
        AudioQueueStop(queue, true)
        if listenerInstalled {
            AudioQueueRemovePropertyListener(
                queue,
                kAudioQueueProperty_IsRunning,
                clientMicrophoneAudioQueuePropertyCallback,
                ownerContext
            )
        }
        AudioQueueDispose(queue, true)
    }
}

private extension NSCondition {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

private let clientMicrophoneAudioQueueCallback: AudioQueueInputCallback = {
    userData,
    queue,
    buffer,
    _,
    _,
    _ in
    guard let userData else { return }
    Unmanaged<AudioQueueMicrophoneCapture>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .receive(buffer, queue: queue)
}

private let clientMicrophoneAudioQueuePropertyCallback: AudioQueuePropertyListenerProc = {
    userData,
    queue,
    property in
    guard property == kAudioQueueProperty_IsRunning, let userData else { return }
    Unmanaged<AudioQueueMicrophoneCapture>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .audioQueueRunningStateChanged(queue)
}

enum MicrophoneSampleRingRead: Equatable {
    case failure
    case discontinuity
    case frame([Float])
    case empty
}

/// Fixed-capacity PCM ring used by the AudioQueue callback. Overflow discards
/// the incomplete timeline and reports one RESET barrier before later samples.
final class MicrophoneSampleRing: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let ring: UnsafeMutablePointer<UmbraMicrophoneSampleRing>
    private let capacity: Int

    init(capacity: Int) {
        precondition(capacity >= ClientMicrophonePCMFrame.sampleCount)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        ring = .allocate(capacity: 1)
        umbra_microphone_sample_ring_init(ring, storage, UInt32(capacity))
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        ring.deallocate()
    }

    var isAccepting: Bool {
        umbra_microphone_sample_ring_is_accepting(ring)
    }

    func reset(accepting: Bool = false) {
        umbra_microphone_sample_ring_reset(ring)
        umbra_microphone_sample_ring_set_accepting(ring, accepting)
    }

    func setAccepting(_ accepting: Bool) {
        umbra_microphone_sample_ring_set_accepting(ring, accepting)
    }

    func markDiscontinuity() {
        umbra_microphone_sample_ring_mark_discontinuity(ring)
    }

    func markTerminalFailure() {
        umbra_microphone_sample_ring_mark_terminal_failure(ring)
    }

    func write(_ samples: UnsafePointer<Float>, count sampleCount: Int) {
        _ = writeForTesting(samples, count: sampleCount)
    }

    @discardableResult
    func writeForTesting(_ samples: UnsafePointer<Float>, count sampleCount: Int) -> Bool {
        umbra_microphone_sample_ring_write(ring, samples, UInt32(clamping: sampleCount))
    }

    func take() -> MicrophoneSampleRingRead {
        var frame = [Float](repeating: 0, count: ClientMicrophonePCMFrame.sampleCount)
        let result = frame.withUnsafeMutableBufferPointer {
            umbra_microphone_sample_ring_take_960(ring, $0.baseAddress!)
        }
        switch result {
        case -2: return .failure
        case -1: return .discontinuity
        case 1: return .frame(frame)
        default: return .empty
        }
    }
}
