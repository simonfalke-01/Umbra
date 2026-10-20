import CGameStreamProtocol
import Foundation

public enum StreamingError: Error, Sendable, Equatable {
    case bridge(Int32)
    case closed
}

public enum StreamingConnectionState: Int32, Sendable {
    case idle = 0
    case starting = 1
    case connected = 2
    case stopping = 3
    case terminated = 4
}

public enum StreamingOptimizationMode: Int32, Sendable {
    case legacy = 0
    case latency = 1
    case quality = 2
}

public enum StreamingFidelityMode: Int32, Sendable {
    case unspecified = 0
    case visuallyLosslessAllowed = 1
    case codecLosslessRequired = 2
}

public enum StreamingHDRTransfer: UInt8, Sendable, Equatable {
    case pq = 2
    case hlg = 3
}

public struct StreamingHDRMetadata: Sendable, Equatable {
    public let redX: UInt16
    public let redY: UInt16
    public let greenX: UInt16
    public let greenY: UInt16
    public let blueX: UInt16
    public let blueY: UInt16
    public let whiteX: UInt16
    public let whiteY: UInt16
    public let maximumDisplayLuminanceNits: UInt16
    public let minimumDisplayLuminanceTenThousandthsOfNit: UInt16
    public let maximumContentLightLevelNits: UInt16
    public let maximumFrameAverageLightLevelNits: UInt16
    public let maximumFullFrameLuminanceNits: UInt16
    public let transfer: StreamingHDRTransfer

    public init(
        redX: UInt16,
        redY: UInt16,
        greenX: UInt16,
        greenY: UInt16,
        blueX: UInt16,
        blueY: UInt16,
        whiteX: UInt16,
        whiteY: UInt16,
        maximumDisplayLuminanceNits: UInt16,
        minimumDisplayLuminanceTenThousandthsOfNit: UInt16,
        maximumContentLightLevelNits: UInt16,
        maximumFrameAverageLightLevelNits: UInt16,
        maximumFullFrameLuminanceNits: UInt16,
        transfer: StreamingHDRTransfer = .pq
    ) {
        self.redX = redX
        self.redY = redY
        self.greenX = greenX
        self.greenY = greenY
        self.blueX = blueX
        self.blueY = blueY
        self.whiteX = whiteX
        self.whiteY = whiteY
        self.maximumDisplayLuminanceNits = maximumDisplayLuminanceNits
        self.minimumDisplayLuminanceTenThousandthsOfNit = minimumDisplayLuminanceTenThousandthsOfNit
        self.maximumContentLightLevelNits = maximumContentLightLevelNits
        self.maximumFrameAverageLightLevelNits = maximumFrameAverageLightLevelNits
        self.maximumFullFrameLuminanceNits = maximumFullFrameLuminanceNits
        self.transfer = transfer
    }
}

public struct StreamingClientMicrophoneGeneration: Sendable, Equatable {
    public let sessionID: Data
    public let salt: Data
    public let serverPort: UInt16
    public let clientPort: UInt16
    public let remoteAddress: String

    public init(
        sessionID: Data,
        salt: Data,
        serverPort: UInt16,
        clientPort: UInt16,
        remoteAddress: String
    ) {
        self.sessionID = sessionID
        self.salt = salt
        self.serverPort = serverPort
        self.clientPort = clientPort
        self.remoteAddress = remoteAddress
    }
}

public enum StreamingEvent: Sendable, Equatable {
    case stageStarting(stage: Int, name: String)
    case stageComplete(stage: Int, name: String)
    case stageFailed(stage: Int, name: String, code: Int32)
    case connectionStarted
    case connectionTerminated(code: Int32)
    case log(String)
    case rumble(controller: UInt16, lowFrequency: UInt16, highFrequency: UInt16)
    case connectionStatus(Int32)
    case hdrMode(enabled: Bool, metadata: StreamingHDRMetadata?)
    case triggerRumble(controller: UInt16, left: UInt16, right: UInt16)
    case motionState(controller: UInt16, type: UInt8, reportRateHz: UInt16)
    case controllerLED(controller: UInt16, red: UInt8, green: UInt8, blue: UInt8)
    case adaptiveTriggers(controller: UInt16, flags: UInt8, leftType: UInt8, rightType: UInt8, left: Data, right: Data)
    case clientMicrophoneGeneration(StreamingClientMicrophoneGeneration)
    case statistics(StreamingStatistics)
}

public struct StreamingConfiguration: Sendable, Equatable {
    public static let minimumVideoDecodeQueueCapacity: Int32 = 1
    public static let maximumVideoDecodeQueueCapacity: Int32 = 15
    public static let defaultVideoDecodeQueueCapacity: Int32 = 15

    public var address: String
    public var serverAppVersion: String
    public var serverGFEVersion: String?
    public var rtspSessionURL: String?
    public var serverCodecModeSupport: Int32
    public var width: Int32
    public var height: Int32
    public var framesPerSecond: Int32
    public var bitrateKbps: Int32
    public var packetSize: Int32
    public var remoteMode: Int32
    public var audioConfiguration: Int32
    public var selectedVideoFormat: Int32
    public var clientRefreshRateTimes100: Int32
    public var colorSpace: Int32
    public var fullColorRange: Bool
    public var encryptionFlags: Int32
    public var remoteInputAESKey: Data
    public var remoteInputAESIV: Data
    public var videoDecodeQueueCapacity: Int32
    public var clientMicrophoneRequested: Bool
    public var clientMicrophoneClientPort: UInt16
    public var videoCapabilities: Int32
    public var audioCapabilities: Int32
    public var videoRendererFlags: Int32
    public var audioRendererFlags: Int32
    /// Host-advertised Lumen RTSP policy; `.legacy` emits no extension.
    public var rtspOptimizationMode: StreamingOptimizationMode

    /// Exact Lumen fidelity request; `.unspecified` preserves legacy ANNOUNCE bytes.
    public var rtspFidelityMode: StreamingFidelityMode

    /// Local GameStream input pacing policy.
    public var inputOptimizationMode: StreamingOptimizationMode

    public init(
        address: String,
        serverAppVersion: String,
        width: Int32 = 1920,
        height: Int32 = 1080,
        framesPerSecond: Int32 = 60,
        bitrateKbps: Int32 = 20_000,
        selectedVideoFormat: Int32 = 0x0001
    ) {
        self.address = address
        self.serverAppVersion = serverAppVersion
        self.serverGFEVersion = nil
        self.rtspSessionURL = nil
        self.serverCodecModeSupport = 0
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitrateKbps = bitrateKbps
        self.packetSize = 1392
        self.remoteMode = 2
        self.audioConfiguration = (0x3 << 16) | (2 << 8) | 0xCA
        self.selectedVideoFormat = selectedVideoFormat
        self.clientRefreshRateTimes100 = 0
        self.colorSpace = 0
        self.fullColorRange = false
        self.encryptionFlags = -1
        self.remoteInputAESKey = Data(repeating: 0, count: 16)
        self.remoteInputAESIV = Data(repeating: 0, count: 16)
        self.videoDecodeQueueCapacity = Self.defaultVideoDecodeQueueCapacity
        self.clientMicrophoneRequested = false
        self.clientMicrophoneClientPort = 0
        self.videoCapabilities = 0
        self.audioCapabilities = 0x10
        self.videoRendererFlags = 0
        self.audioRendererFlags = 0
        self.rtspOptimizationMode = .legacy
        self.rtspFidelityMode = .unspecified
        self.inputOptimizationMode = .legacy
    }

    public static func clampedVideoDecodeQueueCapacity(_ requestedCapacity: Int) -> Int32 {
        Int32(min(
            max(requestedCapacity, Int(minimumVideoDecodeQueueCapacity)),
            Int(maximumVideoDecodeQueueCapacity)
        ))
    }
}

public struct StreamingStatistics: Sendable, Equatable {
    public let estimatedRTTMilliseconds: UInt32?
    public let estimatedRTTVarianceMilliseconds: UInt32?
    public let pendingVideoFrames: Int32
    public let videoDecodeQueueCapacity: Int32
    public let pendingAudioFrames: Int32
    public let pendingAudioDurationMilliseconds: Int32
    public let audioPackets: UInt32
    public let audioFECRecovered: UInt32
    public let audioFECFailed: UInt32
    public let videoPackets: UInt32
    public let videoFECRecovered: UInt32
    public let videoFECFailed: UInt32

    public init(
        estimatedRTTMilliseconds: UInt32?,
        estimatedRTTVarianceMilliseconds: UInt32?,
        pendingVideoFrames: Int32,
        videoDecodeQueueCapacity: Int32 = StreamingConfiguration.defaultVideoDecodeQueueCapacity,
        pendingAudioFrames: Int32,
        pendingAudioDurationMilliseconds: Int32,
        audioPackets: UInt32,
        audioFECRecovered: UInt32,
        audioFECFailed: UInt32,
        videoPackets: UInt32,
        videoFECRecovered: UInt32,
        videoFECFailed: UInt32
    ) {
        self.estimatedRTTMilliseconds = estimatedRTTMilliseconds
        self.estimatedRTTVarianceMilliseconds = estimatedRTTVarianceMilliseconds
        self.pendingVideoFrames = pendingVideoFrames
        self.videoDecodeQueueCapacity = videoDecodeQueueCapacity
        self.pendingAudioFrames = pendingAudioFrames
        self.pendingAudioDurationMilliseconds = pendingAudioDurationMilliseconds
        self.audioPackets = audioPackets
        self.audioFECRecovered = audioFECRecovered
        self.audioFECFailed = audioFECFailed
        self.videoPackets = videoPackets
        self.videoFECRecovered = videoFECRecovered
        self.videoFECFailed = videoFECFailed
    }
}

private final class CallbackContext: @unchecked Sendable {
    let videoDecoder: any VideoDecoding
    let audioDecoder: any AudioDecoding
    let eventHandler: @Sendable (StreamingEvent) -> Void
    let termination = StreamingTerminationSignal()

    init(
        videoDecoder: any VideoDecoding,
        audioDecoder: any AudioDecoding,
        eventHandler: @escaping @Sendable (StreamingEvent) -> Void
    ) {
        self.videoDecoder = videoDecoder
        self.audioDecoder = audioDecoder
        self.eventHandler = eventHandler
    }

}

private final class StreamingTerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish(_ code: Int32) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = code
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.resume(returning: code) }
    }
}

private struct BridgeHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

private struct RetainedContextHandle: @unchecked Sendable {
    let value: Unmanaged<CallbackContext>
}

/// Serializes synchronous input submission and closes the native handle before
/// teardown. `detach()` acquires the same lock as submission, so it waits for a
/// send already inside the C facade and prevents every later send from entering.
final class SynchronousStreamingInputChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var pointer: OpaquePointer?

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    func submit(_ body: (OpaquePointer) throws -> Int32) throws {
        try lock.withLock {
            guard let pointer else { throw StreamingError.closed }
            let result = try body(pointer)
            guard result == 0 else { throw StreamingError.bridge(result) }
        }
    }

    func detach() {
        lock.withLock { pointer = nil }
    }
}

/// Actor-isolated control plane for the global GameStream connection.
/// Media callbacks never hop through the actor; supplied decoders must be thread-safe.
public actor StreamingSession {
    private var handle: BridgeHandle?
    private nonisolated let inputChannel: SynchronousStreamingInputChannel
    private var retainedContext: RetainedContextHandle?
    private var startTask: Task<Int32, Never>?
    private var closeInProgress = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configuration: StreamingConfiguration,
        videoDecoder: any VideoDecoding,
        audioDecoder: any AudioDecoding,
        eventHandler: @escaping @Sendable (StreamingEvent) -> Void = { _ in }
    ) throws {
        guard configuration.remoteInputAESKey.count == 16, configuration.remoteInputAESIV.count == 16 else {
            throw StreamingError.bridge(-7001)
        }

        let context = Unmanaged.passRetained(
            CallbackContext(videoDecoder: videoDecoder, audioDecoder: audioDecoder, eventHandler: eventHandler)
        )
        var callbacks = UmbraStreamCallbacks()
        callbacks.context = context.toOpaque()
        callbacks.event = bridgeEventCallback
        callbacks.video_setup = bridgeVideoSetupCallback
        callbacks.video_start = bridgeVideoStartCallback
        callbacks.video_stop = bridgeVideoStopCallback
        callbacks.video_cleanup = bridgeVideoCleanupCallback
        callbacks.video_frame = bridgeVideoFrameCallback
        callbacks.audio_init = bridgeAudioInitCallback
        callbacks.audio_start = bridgeAudioStartCallback
        callbacks.audio_stop = bridgeAudioStopCallback
        callbacks.audio_cleanup = bridgeAudioCleanupCallback
        callbacks.audio_packet = bridgeAudioPacketCallback

        var cConfiguration = UmbraStreamConfiguration()
        umbra_stream_configuration_init(&cConfiguration)
        cConfiguration.server_codec_mode_support = configuration.serverCodecModeSupport
        cConfiguration.width = configuration.width
        cConfiguration.height = configuration.height
        cConfiguration.fps = configuration.framesPerSecond
        cConfiguration.bitrate = configuration.bitrateKbps
        cConfiguration.packet_size = configuration.packetSize
        cConfiguration.remote_mode = UmbraStreamRemoteMode(rawValue: UInt32(configuration.remoteMode))
        cConfiguration.audio_configuration = configuration.audioConfiguration
        cConfiguration.supported_video_formats = configuration.selectedVideoFormat
        cConfiguration.client_refresh_rate_x100 = configuration.clientRefreshRateTimes100
        cConfiguration.color_space = UmbraStreamColorSpace(rawValue: UInt32(configuration.colorSpace))
        cConfiguration.color_range = UmbraStreamColorRange(rawValue: configuration.fullColorRange ? 1 : 0)
        cConfiguration.encryption_flags = configuration.encryptionFlags
        cConfiguration.video_decode_queue_capacity = configuration.videoDecodeQueueCapacity
        cConfiguration.client_microphone_requested = configuration.clientMicrophoneRequested
        cConfiguration.client_microphone_client_port = configuration.clientMicrophoneClientPort
        cConfiguration.video_capabilities = configuration.videoCapabilities
        cConfiguration.audio_capabilities = configuration.audioCapabilities
        cConfiguration.video_renderer_flags = configuration.videoRendererFlags
        cConfiguration.audio_renderer_flags = configuration.audioRendererFlags
        cConfiguration.rtsp_optimization_mode = UmbraStreamOptimizationMode(
            rawValue: UInt32(configuration.rtspOptimizationMode.rawValue)
        )
        cConfiguration.rtsp_fidelity_mode = UmbraStreamFidelityMode(
            rawValue: UInt32(configuration.rtspFidelityMode.rawValue)
        )
        cConfiguration.input_optimization_mode = UmbraStreamOptimizationMode(
            rawValue: UInt32(configuration.inputOptimizationMode.rawValue)
        )
        _ = withUnsafeMutableBytes(of: &cConfiguration.remote_input_aes_key) {
            configuration.remoteInputAESKey.copyBytes(to: $0)
        }
        _ = withUnsafeMutableBytes(of: &cConfiguration.remote_input_aes_iv) {
            configuration.remoteInputAESIV.copyBytes(to: $0)
        }

        var result: Int32 = 0
        let session = configuration.address.withCString { address in
            configuration.serverAppVersion.withCString { appVersion in
                withOptionalCString(configuration.serverGFEVersion) { gfeVersion in
                    withOptionalCString(configuration.rtspSessionURL) { sessionURL in
                        cConfiguration.address = address
                        cConfiguration.server_app_version = appVersion
                        cConfiguration.server_gfe_version = gfeVersion
                        cConfiguration.rtsp_session_url = sessionURL
                        return umbra_stream_session_create(&cConfiguration, &callbacks, &result)
                    }
                }
            }
        }
        guard let session else {
            context.release()
            throw StreamingError.bridge(result)
        }
        let preparedCallbackResult = umbra_stream_session_set_prepared_video_callback(
            session,
            bridgePreparedVideoFrameCallback
        )
        guard preparedCallbackResult == 0 else {
            _ = umbra_stream_session_destroy(session)
            context.release()
            throw StreamingError.bridge(preparedCallbackResult)
        }
        self.handle = BridgeHandle(pointer: session)
        self.inputChannel = SynchronousStreamingInputChannel(pointer: session)
        self.retainedContext = RetainedContextHandle(value: context)
    }

    deinit {
        inputChannel.detach()
        guard let handle, let retainedContext else {
            retainedContext?.value.release()
            return
        }
        retainedContext.value.takeUnretainedValue().termination.finish(0)
        let pendingStart = startTask
        Task.detached {
            _ = umbra_stream_session_cancel(handle.pointer)
            if let pendingStart {
                _ = await pendingStart.value
            }
            _ = umbra_stream_session_stop(handle.pointer)
            if umbra_stream_session_destroy(handle.pointer) == 0 {
                retainedContext.value.release()
            }
        }
    }

    public var state: StreamingConnectionState {
        guard let handle else { return .idle }
        return StreamingConnectionState(rawValue: Int32(umbra_stream_session_state(handle.pointer).rawValue)) ?? .idle
    }

    public func start() async throws {
        guard let handle else { throw StreamingError.closed }
        guard startTask == nil else { throw StreamingError.bridge(-7002) }
        let task = Task.detached(priority: .userInitiated) {
            umbra_stream_session_start(handle.pointer)
        }
        startTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            _ = umbra_stream_session_cancel(handle.pointer)
        }
        startTask = nil
        if Task.isCancelled {
            throw CancellationError()
        }
        guard result == 0 else { throw StreamingError.bridge(result) }
    }

    public func waitUntilTerminated() async -> Int32 {
        guard let retainedContext else { return 0 }
        let termination = retainedContext.value.takeUnretainedValue().termination
        return await termination.wait()
    }

    public func close() async {
        if closeInProgress {
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        guard let handle else { return }
        closeInProgress = true
        inputChannel.detach()
        retainedContext?.value.takeUnretainedValue().termination.finish(0)
        _ = umbra_stream_session_cancel(handle.pointer)
        if let startTask {
            _ = await startTask.value
            self.startTask = nil
        }
        _ = umbra_stream_session_stop(handle.pointer)
        if umbra_stream_session_destroy(handle.pointer) == 0 {
            self.handle = nil
            retainedContext?.value.release()
            retainedContext = nil
        }
        closeInProgress = false
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    public func statistics() throws -> StreamingStatistics {
        guard let handle else { throw StreamingError.closed }
        var value = UmbraStreamStatistics()
        let result = umbra_stream_session_get_statistics(handle.pointer, &value)
        guard result == 0 else { throw StreamingError.bridge(result) }
        return StreamingStatistics(
            estimatedRTTMilliseconds: value.has_estimated_rtt ? value.estimated_rtt_ms : nil,
            estimatedRTTVarianceMilliseconds: value.has_estimated_rtt ? value.estimated_rtt_variance_ms : nil,
            pendingVideoFrames: value.pending_video_frames,
            videoDecodeQueueCapacity: value.video_decode_queue_capacity,
            pendingAudioFrames: value.pending_audio_frames,
            pendingAudioDurationMilliseconds: value.pending_audio_duration_ms,
            audioPackets: value.audio_packets,
            audioFECRecovered: value.audio_fec_recovered,
            audioFECFailed: value.audio_fec_failed,
            videoPackets: value.video_packets,
            videoFECRecovered: value.video_fec_recovered,
            videoFECFailed: value.video_fec_failed
        )
    }

    public func requestKeyFrame() throws {
        try check(umbra_stream_session_request_idr(requiredHandle().pointer))
    }

    public nonisolated func sendMouseMove(deltaX: Int16, deltaY: Int16) throws {
        try inputChannel.submit { umbra_stream_session_send_mouse_move($0, deltaX, deltaY) }
    }

    public nonisolated func sendMousePosition(
        x: Int16,
        y: Int16,
        referenceWidth: Int16,
        referenceHeight: Int16
    ) throws {
        try inputChannel.submit {
            umbra_stream_session_send_mouse_position($0, x, y, referenceWidth, referenceHeight)
        }
    }

    public nonisolated func sendMouseMoveAsPosition(
        deltaX: Int16,
        deltaY: Int16,
        referenceWidth: Int16,
        referenceHeight: Int16
    ) throws {
        try inputChannel.submit {
            umbra_stream_session_send_mouse_move_as_position(
                $0,
                deltaX,
                deltaY,
                referenceWidth,
                referenceHeight
            )
        }
    }

    public nonisolated func sendMouseButton(action: Int8, button: Int32) throws {
        try inputChannel.submit { umbra_stream_session_send_mouse_button($0, action, button) }
    }

    public nonisolated func sendScroll(vertical: Int16, horizontal: Int16 = 0) throws {
        try inputChannel.submit { umbra_stream_session_send_scroll($0, vertical, horizontal) }
    }

    public nonisolated func sendKeyboard(
        keyCode: Int16,
        action: Int8,
        modifiers: Int8,
        flags: Int8 = 0
    ) throws {
        try inputChannel.submit { umbra_stream_session_send_keyboard($0, keyCode, action, modifiers, flags) }
    }

    public nonisolated func send(text: String) throws {
        let bytes = Data(text.utf8)
        try inputChannel.submit { pointer in
            bytes.withUnsafeBytes { storage in
                umbra_stream_session_send_utf8_text(
                    pointer,
                    storage.baseAddress?.assumingMemoryBound(to: CChar.self),
                    storage.count
                )
            }
        }
    }

    public nonisolated func sendTouch(
        eventType: UInt8,
        pointerID: UInt32,
        x: Float,
        y: Float,
        pressureOrDistance: Float,
        contactAreaMajor: Float = 0,
        contactAreaMinor: Float = 0,
        rotation: UInt16 = .max
    ) throws {
        try inputChannel.submit {
            umbra_stream_session_send_touch(
                $0,
                eventType,
                pointerID,
                x,
                y,
                pressureOrDistance,
                contactAreaMajor,
                contactAreaMinor,
                rotation
            )
        }
    }

    public nonisolated func sendPen(
        eventType: UInt8,
        toolType: UInt8,
        buttons: UInt8,
        x: Float,
        y: Float,
        pressureOrDistance: Float,
        contactAreaMajor: Float = 0,
        contactAreaMinor: Float = 0,
        rotation: UInt16 = .max,
        tilt: UInt8 = .max
    ) throws {
        try inputChannel.submit {
            umbra_stream_session_send_pen(
                $0,
                eventType,
                toolType,
                buttons,
                x,
                y,
                pressureOrDistance,
                contactAreaMajor,
                contactAreaMinor,
                rotation,
                tilt
            )
        }
    }

    public nonisolated func sendController(
        number: Int16,
        activeMask: Int16,
        buttons: Int32,
        leftTrigger: UInt8,
        rightTrigger: UInt8,
        leftStickX: Int16,
        leftStickY: Int16,
        rightStickX: Int16,
        rightStickY: Int16
    ) throws {
        try inputChannel.submit {
            umbra_stream_session_send_controller(
                $0,
                number,
                activeMask,
                buttons,
                leftTrigger,
                rightTrigger,
                leftStickX,
                leftStickY,
                rightStickX,
                rightStickY
            )
        }
    }

    public nonisolated func sendControllerArrival(
        number: UInt8,
        activeMask: UInt16,
        type: UInt8,
        supportedButtons: UInt32,
        capabilities: UInt16
    ) throws {
        try inputChannel.submit {
            umbra_stream_session_send_controller_arrival(
                $0,
                number,
                activeMask,
                type,
                supportedButtons,
                capabilities
            )
        }
    }

    public nonisolated func sendControllerTouch(
        number: UInt8,
        eventType: UInt8,
        touchpadIndex: UInt8,
        pointerID: UInt32,
        x: Float,
        y: Float,
        pressure: Float
    ) throws {
        try inputChannel.submit {
            umbra_stream_session_send_controller_touch(
                $0,
                number,
                eventType,
                touchpadIndex,
                pointerID,
                x,
                y,
                pressure
            )
        }
    }

    public nonisolated func sendControllerMotion(
        number: UInt8,
        type: UInt8,
        x: Float,
        y: Float,
        z: Float
    ) throws {
        try inputChannel.submit { umbra_stream_session_send_controller_motion($0, number, type, x, y, z) }
    }

    public nonisolated func sendControllerBattery(number: UInt8, state: UInt8, percentage: UInt8) throws {
        try inputChannel.submit { umbra_stream_session_send_controller_battery($0, number, state, percentage) }
    }

    public func hostFeatureFlags() throws -> UInt32 {
        var flags: UInt32 = 0
        try check(umbra_stream_session_get_host_feature_flags(requiredHandle().pointer, &flags))
        return flags
    }

    private func requiredHandle() throws -> BridgeHandle {
        guard let handle else { throw StreamingError.closed }
        return handle
    }

    private func check(_ result: Int32) throws {
        guard result == 0 else { throw StreamingError.bridge(result) }
    }
}

private func withOptionalCString<Result>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) throws -> Result
) rethrows -> Result {
    guard let value else { return try body(nil) }
    return try value.withCString(body)
}

private func callbackContext(_ pointer: UnsafeMutableRawPointer?) -> CallbackContext? {
    pointer.map { Unmanaged<CallbackContext>.fromOpaque($0).takeUnretainedValue() }
}

private func bridgeEventCallback(_ context: UnsafeMutableRawPointer?, _ eventPointer: UnsafePointer<UmbraStreamEvent>?) {
    guard let context = callbackContext(context), let eventPointer else { return }
    let event = eventPointer.pointee
    let stageName = event.stage_name.map(String.init(cString:)) ?? ""
    let mapped: StreamingEvent
    switch event.type.rawValue {
    case 0: mapped = .stageStarting(stage: Int(event.stage), name: stageName)
    case 1: mapped = .stageComplete(stage: Int(event.stage), name: stageName)
    case 2: mapped = .stageFailed(stage: Int(event.stage), name: stageName, code: event.error_code)
    case 3: mapped = .connectionStarted
    case 4: mapped = .connectionTerminated(code: event.error_code)
    case 5: mapped = .log(event.message.map(String.init(cString:)) ?? "")
    case 6: mapped = .rumble(controller: event.controller_number, lowFrequency: event.low_frequency_motor, highFrequency: event.high_frequency_motor)
    case 7: mapped = .connectionStatus(event.status)
    case 8:
        let value = event.hdr_metadata
        let metadata = value.valid ? StreamingHDRMetadata(
            redX: value.red_x,
            redY: value.red_y,
            greenX: value.green_x,
            greenY: value.green_y,
            blueX: value.blue_x,
            blueY: value.blue_y,
            whiteX: value.white_x,
            whiteY: value.white_y,
            maximumDisplayLuminanceNits: value.max_display_luminance,
            minimumDisplayLuminanceTenThousandthsOfNit: value.min_display_luminance,
            maximumContentLightLevelNits: value.max_content_light_level,
            maximumFrameAverageLightLevelNits: value.max_frame_average_light_level,
            maximumFullFrameLuminanceNits: value.max_full_frame_luminance
        ) : nil
        if let receiver = context.videoDecoder as? any HDRMetadataReceiving {
            receiver.setHDRMode(enabled: event.enabled, metadata: metadata)
        }
        mapped = .hdrMode(enabled: event.enabled, metadata: metadata)
    case 9: mapped = .triggerRumble(controller: event.controller_number, left: event.low_frequency_motor, right: event.high_frequency_motor)
    case 10: mapped = .motionState(controller: event.controller_number, type: event.motion_type, reportRateHz: event.report_rate_hz)
    case 11: mapped = .controllerLED(controller: event.controller_number, red: event.red, green: event.green, blue: event.blue)
    case 12:
        mapped = .adaptiveTriggers(
            controller: event.controller_number,
            flags: event.adaptive_event_flags,
            leftType: event.adaptive_left_type,
            rightType: event.adaptive_right_type,
            left: withUnsafeBytes(of: event.adaptive_left) { Data($0) },
            right: withUnsafeBytes(of: event.adaptive_right) { Data($0) }
        )
    case 13:
        let value = event.client_microphone_generation
        mapped = .clientMicrophoneGeneration(StreamingClientMicrophoneGeneration(
            sessionID: withUnsafeBytes(of: value.session_id) { Data($0) },
            salt: withUnsafeBytes(of: value.salt) { Data($0) },
            serverPort: value.server_port,
            clientPort: value.client_port,
            remoteAddress: withUnsafeBytes(of: value.remote_address) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        ))
    default: return
    }
    context.eventHandler(mapped)
    if case let .connectionTerminated(code) = mapped {
        context.termination.finish(code)
    }
}

private func bridgeVideoSetupCallback(_ pointer: UnsafeMutableRawPointer?, _ formatPointer: UnsafePointer<UmbraVideoFormat>?) -> Int32 {
    guard let context = callbackContext(pointer), let value = formatPointer?.pointee else { return -1 }
    return context.videoDecoder.configure(format: VideoStreamFormat(
        codecMask: value.format,
        width: Int(value.width),
        height: Int(value.height),
        redrawRate: Int(value.redraw_rate),
        flags: value.flags
    )) ? 0 : -1
}

private func bridgeVideoStartCallback(_ pointer: UnsafeMutableRawPointer?) { callbackContext(pointer)?.videoDecoder.start() }
private func bridgeVideoStopCallback(_ pointer: UnsafeMutableRawPointer?) { callbackContext(pointer)?.videoDecoder.stop() }
private func bridgeVideoCleanupCallback(_ pointer: UnsafeMutableRawPointer?) { callbackContext(pointer)?.videoDecoder.cleanUp() }

private func bridgeVideoFrameCallback(_ pointer: UnsafeMutableRawPointer?, _ framePointer: UnsafeMutablePointer<UmbraVideoFrame>?) -> Int32 {
    guard let context = callbackContext(pointer), let framePointer else { return -1 }
    let value = framePointer.pointee
    let length = value.length
    guard length > 0, let data = umbra_video_frame_take_data(framePointer) else { return -1 }
    let ownedData = Data(
        bytesNoCopy: data,
        count: length,
        deallocator: .custom { pointer, _ in
            umbra_video_frame_release_data(pointer.assumingMemoryBound(to: UInt8.self))
        }
    )
    let frame = CompressedVideoFrame(
        data: ownedData,
        frameNumber: Int(value.frame_number),
        isKeyFrame: value.frame_type == 1,
        hostProcessingLatencyTenthsOfMillisecond: value.host_processing_latency_tenths_ms,
        receiveTimeMicroseconds: value.receive_time_us,
        enqueueTimeMicroseconds: value.enqueue_time_us,
        presentationTimeMicroseconds: value.presentation_time_us,
        rtpTimestamp: value.rtp_timestamp,
        isHDR: value.hdr_active,
        colorSpace: value.color_space
    )
    let disposition = context.videoDecoder.submit(frame: frame)
    return disposition.rawValue
}

private func bridgePreparedVideoFrameCallback(
    _ pointer: UnsafeMutableRawPointer?,
    _ framePointer: UnsafeMutablePointer<UmbraPreparedVideoFrame>?
) -> Int32 {
    guard let context = callbackContext(pointer), let framePointer else { return -1 }
    let value = framePointer.pointee
    guard value.abi_version == UMBRA_PREPARED_VIDEO_FRAME_ABI_VERSION else { return -1 }
    let payloadFormat: EncodedVideoPayloadFormat
    switch value.payload_format {
    case UMBRA_PREPARED_VIDEO_PAYLOAD_VIDEO_TOOLBOX_LENGTH_PREFIXED:
        payloadFormat = .videoToolboxLengthPrefixed
    case UMBRA_PREPARED_VIDEO_PAYLOAD_AV1_LOW_OVERHEAD_OBU:
        payloadFormat = .av1LowOverheadOBU
    default:
        return -1
    }
    let length = value.length
    guard length > 0, let data = umbra_prepared_video_frame_take_data(framePointer) else { return -1 }
    let ownedData = Data(
        bytesNoCopy: data,
        count: length,
        deallocator: .custom { pointer, _ in
            umbra_prepared_video_frame_release_data(pointer.assumingMemoryBound(to: UInt8.self))
        }
    )
    let frame = CompressedVideoFrame(
        data: ownedData,
        payloadFormat: payloadFormat,
        frameNumber: Int(value.frame_number),
        isKeyFrame: value.frame_type == 1,
        hostProcessingLatencyTenthsOfMillisecond: value.host_processing_latency_tenths_ms,
        receiveTimeMicroseconds: value.receive_time_us,
        enqueueTimeMicroseconds: value.enqueue_time_us,
        presentationTimeMicroseconds: value.presentation_time_us,
        rtpTimestamp: value.rtp_timestamp,
        isHDR: value.hdr_active,
        colorSpace: value.color_space
    )
    return context.videoDecoder.submit(frame: frame).rawValue
}

private func bridgeAudioInitCallback(_ pointer: UnsafeMutableRawPointer?, _ formatPointer: UnsafePointer<UmbraAudioFormat>?) -> Int32 {
    guard let context = callbackContext(pointer), let value = formatPointer?.pointee else { return -1 }
    let mapping = withUnsafeBytes(of: value.mapping) { Array($0.prefix(8)) }
    return context.audioDecoder.configure(format: OpusStreamFormat(
        audioConfiguration: value.audio_configuration,
        sampleRate: Int(value.sample_rate),
        channelCount: Int(value.channel_count),
        streamCount: Int(value.streams),
        coupledStreamCount: Int(value.coupled_streams),
        samplesPerFrame: Int(value.samples_per_frame),
        mapping: mapping,
        flags: value.flags
    )) ? 0 : -1
}

private func bridgeAudioStartCallback(_ pointer: UnsafeMutableRawPointer?) { callbackContext(pointer)?.audioDecoder.start() }
private func bridgeAudioStopCallback(_ pointer: UnsafeMutableRawPointer?) { callbackContext(pointer)?.audioDecoder.stop() }
private func bridgeAudioCleanupCallback(_ pointer: UnsafeMutableRawPointer?) { callbackContext(pointer)?.audioDecoder.cleanUp() }

private func bridgeAudioPacketCallback(_ pointer: UnsafeMutableRawPointer?, _ packetPointer: UnsafePointer<UmbraAudioPacket>?) {
    guard let context = callbackContext(pointer), let value = packetPointer?.pointee else { return }
    if value.length == 0 {
        context.audioDecoder.submit(packet: CompressedAudioPacket(data: Data()))
    } else if let data = value.data {
        context.audioDecoder.submit(packet: CompressedAudioPacket(data: Data(bytes: data, count: value.length)))
    }
}

#if DEBUG
/// Test-only driver for the synchronous C callback boundary. It exercises the
/// same callback functions used by the GameStream protocol library without opening a socket.
final class StreamingCallbackTestHarness: @unchecked Sendable {
    private let retainedContext: Unmanaged<CallbackContext>
    private(set) var lastVideoFrameAllocationAddress: UInt?

    init(
        videoDecoder: any VideoDecoding,
        audioDecoder: any AudioDecoding,
        eventHandler: @escaping @Sendable (StreamingEvent) -> Void = { _ in }
    ) {
        retainedContext = .passRetained(CallbackContext(
            videoDecoder: videoDecoder,
            audioDecoder: audioDecoder,
            eventHandler: eventHandler
        ))
    }

    deinit {
        retainedContext.release()
    }

    func videoSetup(
        codecMask: Int32,
        width: Int32,
        height: Int32,
        redrawRate: Int32,
        flags: Int32
    ) -> Int32 {
        var format = UmbraVideoFormat()
        format.format = codecMask
        format.width = width
        format.height = height
        format.redraw_rate = redrawRate
        format.flags = flags
        return withUnsafePointer(to: &format) {
            bridgeVideoSetupCallback(retainedContext.toOpaque(), $0)
        }
    }

    func videoStart() {
        bridgeVideoStartCallback(retainedContext.toOpaque())
    }

    func videoStop() {
        bridgeVideoStopCallback(retainedContext.toOpaque())
    }

    func videoCleanup() {
        bridgeVideoCleanupCallback(retainedContext.toOpaque())
    }

    func hdrMode(enabled: Bool, metadata: StreamingHDRMetadata?) {
        var event = UmbraStreamEvent()
        event.type = UmbraStreamEventType(rawValue: 8)
        event.enabled = enabled
        if let metadata {
            event.hdr_metadata.valid = true
            event.hdr_metadata.red_x = metadata.redX
            event.hdr_metadata.red_y = metadata.redY
            event.hdr_metadata.green_x = metadata.greenX
            event.hdr_metadata.green_y = metadata.greenY
            event.hdr_metadata.blue_x = metadata.blueX
            event.hdr_metadata.blue_y = metadata.blueY
            event.hdr_metadata.white_x = metadata.whiteX
            event.hdr_metadata.white_y = metadata.whiteY
            event.hdr_metadata.max_display_luminance = metadata.maximumDisplayLuminanceNits
            event.hdr_metadata.min_display_luminance = metadata.minimumDisplayLuminanceTenThousandthsOfNit
            event.hdr_metadata.max_content_light_level = metadata.maximumContentLightLevelNits
            event.hdr_metadata.max_frame_average_light_level = metadata.maximumFrameAverageLightLevelNits
            event.hdr_metadata.max_full_frame_luminance = metadata.maximumFullFrameLuminanceNits
        }
        withUnsafePointer(to: &event) {
            bridgeEventCallback(retainedContext.toOpaque(), $0)
        }
    }

    func clientMicrophoneGeneration(_ generation: StreamingClientMicrophoneGeneration) {
        precondition(generation.sessionID.count == 16)
        precondition(generation.salt.count == 16)
        var event = UmbraStreamEvent()
        event.type = UmbraStreamEventType(rawValue: 13)
        _ = withUnsafeMutableBytes(of: &event.client_microphone_generation.session_id) {
            generation.sessionID.copyBytes(to: $0)
        }
        _ = withUnsafeMutableBytes(of: &event.client_microphone_generation.salt) {
            generation.salt.copyBytes(to: $0)
        }
        event.client_microphone_generation.server_port = generation.serverPort
        event.client_microphone_generation.client_port = generation.clientPort
        precondition(generation.remoteAddress.utf8.count < UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY)
        withUnsafeMutableBytes(of: &event.client_microphone_generation.remote_address) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            generation.remoteAddress.utf8CString.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        withUnsafePointer(to: &event) {
            bridgeEventCallback(retainedContext.toOpaque(), $0)
        }
    }

    func videoFrame(
        data: inout [UInt8],
        frameNumber: Int32,
        frameType: Int32,
        hostProcessingLatencyTenthsOfMillisecond: UInt16,
        receiveTimeMicroseconds: UInt64,
        enqueueTimeMicroseconds: UInt64,
        presentationTimeMicroseconds: UInt64,
        rtpTimestamp: UInt32,
        isHDR: Bool,
        colorSpace: UInt8
    ) -> Int32 {
        data.withUnsafeBytes { bytes in
            guard let allocation = malloc(bytes.count) else { return -1 }
            allocation.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            lastVideoFrameAllocationAddress = UInt(bitPattern: allocation)
            var frame = UmbraVideoFrame()
            frame.data = allocation.assumingMemoryBound(to: UInt8.self)
            frame.length = bytes.count
            frame.frame_number = frameNumber
            frame.frame_type = frameType
            frame.host_processing_latency_tenths_ms = hostProcessingLatencyTenthsOfMillisecond
            frame.receive_time_us = receiveTimeMicroseconds
            frame.enqueue_time_us = enqueueTimeMicroseconds
            frame.presentation_time_us = presentationTimeMicroseconds
            frame.rtp_timestamp = rtpTimestamp
            frame.hdr_active = isHDR
            frame.color_space = colorSpace
            return withUnsafeMutablePointer(to: &frame) {
                let result = bridgeVideoFrameCallback(retainedContext.toOpaque(), $0)
                umbra_video_frame_release_data($0.pointee.data)
                return result
            }
        }
    }

    func preparedVideoFrame(
        data: inout [UInt8],
        payloadFormat: EncodedVideoPayloadFormat,
        frameNumber: Int32,
        frameType: Int32
    ) -> Int32 {
        data.withUnsafeBytes { bytes in
            guard let allocation = malloc(bytes.count) else { return -1 }
            allocation.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            lastVideoFrameAllocationAddress = UInt(bitPattern: allocation)
            var frame = UmbraPreparedVideoFrame()
            frame.abi_version = UMBRA_PREPARED_VIDEO_FRAME_ABI_VERSION
            switch payloadFormat {
            case .videoToolboxLengthPrefixed:
                frame.payload_format = UMBRA_PREPARED_VIDEO_PAYLOAD_VIDEO_TOOLBOX_LENGTH_PREFIXED
            case .av1LowOverheadOBU:
                frame.payload_format = UMBRA_PREPARED_VIDEO_PAYLOAD_AV1_LOW_OVERHEAD_OBU
            case .annexB:
                free(allocation)
                return -1
            }
            frame.data = allocation.assumingMemoryBound(to: UInt8.self)
            frame.length = bytes.count
            frame.frame_number = frameNumber
            frame.frame_type = frameType
            return withUnsafeMutablePointer(to: &frame) {
                let result = bridgePreparedVideoFrameCallback(retainedContext.toOpaque(), $0)
                umbra_prepared_video_frame_release_data($0.pointee.data)
                return result
            }
        }
    }

    func audioInit(
        audioConfiguration: Int32,
        sampleRate: Int32,
        channelCount: Int32,
        streamCount: Int32,
        coupledStreamCount: Int32,
        samplesPerFrame: Int32,
        mapping: [UInt8],
        flags: Int32
    ) -> Int32 {
        var format = UmbraAudioFormat()
        format.audio_configuration = audioConfiguration
        format.sample_rate = sampleRate
        format.channel_count = channelCount
        format.streams = streamCount
        format.coupled_streams = coupledStreamCount
        format.samples_per_frame = samplesPerFrame
        format.flags = flags
        withUnsafeMutableBytes(of: &format.mapping) { destination in
            destination.copyBytes(from: mapping.prefix(destination.count))
        }
        return withUnsafePointer(to: &format) {
            bridgeAudioInitCallback(retainedContext.toOpaque(), $0)
        }
    }

    func audioStart() {
        bridgeAudioStartCallback(retainedContext.toOpaque())
    }

    func audioStop() {
        bridgeAudioStopCallback(retainedContext.toOpaque())
    }

    func audioCleanup() {
        bridgeAudioCleanupCallback(retainedContext.toOpaque())
    }

    func audioPacket(data: inout [UInt8]) {
        data.withUnsafeBufferPointer { bytes in
            var packet = UmbraAudioPacket()
            packet.data = bytes.baseAddress
            packet.length = bytes.count
            withUnsafePointer(to: &packet) {
                bridgeAudioPacketCallback(retainedContext.toOpaque(), $0)
            }
        }
    }

    func connectionTerminated(code: Int32) {
        var event = UmbraStreamEvent()
        event.type = UmbraStreamEventType(rawValue: 4)
        event.error_code = code
        withUnsafePointer(to: &event) {
            bridgeEventCallback(retainedContext.toOpaque(), $0)
        }
    }

    func waitForTermination() async -> Int32 {
        await retainedContext.takeUnretainedValue().termination.wait()
    }
}
#endif
