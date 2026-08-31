import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import simd

public struct MetalDisplayConfiguration: Sendable, Equatable {
    public var contentMode: VideoContentMode
    public var verticalSyncEnabled: Bool
    public var clearColor: SIMD4<Double>

    public init(
        contentMode: VideoContentMode = .aspectFit,
        verticalSyncEnabled: Bool = true,
        clearColor: SIMD4<Double> = SIMD4(0, 0, 0, 1)
    ) {
        self.contentMode = contentMode
        self.verticalSyncEnabled = verticalSyncEnabled
        self.clearColor = clearColor
    }
}

public enum MetalRendererError: Error, Sendable, Equatable {
    case metalUnavailable
    case commandQueueUnavailable
    case textureCacheCreationFailed(CVReturn)
    case shaderCompilationFailed(String)
    case pipelineCreationFailed(String)
    case commandBufferFailed(String)
    case unsupportedPixelFormat(OSType)
    case textureCreationFailed(CVReturn)
}

private struct MetalVideoVertex {
    var position: SIMD2<Float>
    var textureCoordinate: SIMD2<Float>
}

private struct MetalFragmentUniforms {
    var matrix: simd_float3x3
    /// xyz is the YCbCr offset; w is 0 for SDR, 1 for PQ, and 2 for HLG.
    var offsetAndTransfer: SIMD4<Float>
}

private final class MetalRenderRunLoopExecutor: @unchecked Sendable {
    private final class Context: @unchecked Sendable {
        let lock = NSLock()
        let ready = DispatchSemaphore(value: 0)
        var runLoop: CFRunLoop?
    }

    private let context = Context()
    private let thread: Thread

    init() {
        let context = context
        thread = Thread {
            let runLoop = RunLoop.current
            let keepAlivePort = Port()
            runLoop.add(keepAlivePort, forMode: .common)
            context.lock.withLock {
                context.runLoop = CFRunLoopGetCurrent()
            }
            context.ready.signal()
            CFRunLoopRun()
            withExtendedLifetime(keepAlivePort) {}
        }
        thread.name = "UmbraMetalPresentation"
        thread.qualityOfService = .userInteractive
        thread.start()
        context.ready.wait()
    }

    func perform(_ work: @escaping @Sendable () -> Void) {
        guard let runLoop = context.lock.withLock({ context.runLoop }) else { return }
        CFRunLoopPerformBlock(runLoop, RunLoop.Mode.common.rawValue as CFString, work)
        CFRunLoopWakeUp(runLoop)
    }

    func barrier() async {
        await withCheckedContinuation { continuation in
            perform { continuation.resume() }
        }
    }

    func shutDown(after finalWork: @escaping @Sendable () -> Void) {
        guard let runLoop = context.lock.withLock({ context.runLoop }) else { return }
        CFRunLoopPerformBlock(
            runLoop,
            RunLoop.Mode.common.rawValue as CFString
        ) { [context] in
            finalWork()
            context.lock.withLock { context.runLoop = nil }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }
}

private final class MetalDisplayLinkReference: @unchecked Sendable {
    let value: CAMetalDisplayLink?

    init(_ value: CAMetalDisplayLink?) {
        self.value = value
    }
}

#if DEBUG
struct MetalRendererTestingHooks: Sendable {
    var didBeginEncode: @Sendable (Int) -> Void = { _ in }
    var beforeDrawableAcquisition: @Sendable (Int) -> Void = { _ in }
    var beforeCommit: @Sendable (Int) -> Void = { _ in }
    var didCommit: @Sendable (Int) -> Void = { _ in }
    var didEndEncode: @Sendable (Int) -> Void = { _ in }
    var didApplyLayerConfiguration: @Sendable (VideoColorMetadata) -> Void = { _ in }
}
#endif

struct MetalLatencyGenerationGate: Sendable, Equatable {
    private(set) var current: UInt64 = 0

    var stamp: UInt64 { current }

    mutating func advance() {
        current &+= 1
    }

    func accepts(_ stamp: UInt64) -> Bool {
        stamp == current
    }
}

private struct QueuedMetalFrame: @unchecked Sendable {
    let frame: DecodedVideoFrame
    let latencyGeneration: UInt64
    let presentationGeneration: UInt64
    let layerConfigurationGeneration: UInt64
}

private final class MetalFrameLease: @unchecked Sendable {
    let frame: DecodedVideoFrame
    let textures: [CVMetalTexture]
    let latencyGeneration: UInt64
    let presentationGeneration: UInt64
    private(set) var commandCommitTime: VideoLatencyTimestamp?

    init(
        frame: DecodedVideoFrame,
        textures: [CVMetalTexture],
        latencyGeneration: UInt64,
        presentationGeneration: UInt64
    ) {
        self.frame = frame
        self.textures = textures
        self.latencyGeneration = latencyGeneration
        self.presentationGeneration = presentationGeneration
    }

    @inline(__always)
    func stampCommandCommit() -> VideoLatencyTimestamp {
        let timestamp = VideoLatencyTimestamp(
            seconds: CACurrentMediaTime(),
            clockDomain: .clientMediaTime
        )
        commandCommitTime = timestamp
        return timestamp
    }
}

public final class MetalVideoRenderer: NSObject, MetalVideoRendering, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private struct LayerConfiguration: Equatable {
        let color: VideoColorMetadata
        let verticalSyncEnabled: Bool
    }

    private struct State {
        var frames: [QueuedMetalFrame] = []
        var isDrainScheduled = false
        var isPresentationActive = true
        var usesDisplayLink = false
        var adaptiveMailboxWaitEnabled = true
        var configuration: MetalDisplayConfiguration
        var presentationGeneration: UInt64 = 0
        var layerConfigurationGeneration: UInt64 = 0
        var desiredLayerConfiguration: LayerConfiguration?
        var adaptiveRenderLead = AdaptiveRenderLeadPolicy()
        var statistics = MediaStatisticsAccumulator()
        var latencyStatistics = VideoLatencyStatisticsAccumulator()
        var latencyGeneration = MetalLatencyGenerationGate()
        var reportedFirstMetalCommit = false
        var lastError: MetalRendererError?
        var dropsNewestWhenMailboxFull = false
    }

    private let layer: CAMetalLayer
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private var textureCache: CVMetalTextureCache
    private let maximumQueuedFrames: Int
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private let extendedRec2020ColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
    private let renderExecutor = MetalRenderRunLoopExecutor()
    private let lock = NSCondition()
    private var state: State
    private var yuvPipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
    private var rgbPipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
    private var appliedLayerConfiguration: LayerConfiguration?
    private var displayLink: CAMetalDisplayLink?
    private var displayLinkGeneration: UInt64?
    private var firstMetalCommitHandler: @Sendable (Int) -> Void = { _ in }
    private var commandCommitHandler: @Sendable (Int) -> Void = { _ in }
    private var frameDropHandler: @Sendable (Int, MetalFrameDropReason) -> Void = { _, _ in }
    private var nominalFramesPerSecond: Double
    private var displayRefreshRate: Double
    #if DEBUG
    private var testingHooks = MetalRendererTestingHooks()
    #endif

    private static var supportsMetalDisplayLinkPacing: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    public init(
        layer: CAMetalLayer,
        device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
        configuration: MetalDisplayConfiguration = MetalDisplayConfiguration(),
        pacingConfiguration: FramePacingConfiguration = FramePacingConfiguration(nominalFramesPerSecond: 60),
        maximumQueuedFrames: Int = 1,
        presentationActive: Bool = true
    ) throws {
        guard let device else { throw MetalRendererError.metalUnavailable }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueUnavailable
        }
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalRendererError.shaderCompilationFailed(error.localizedDescription)
        }
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw MetalRendererError.textureCacheCreationFailed(cacheStatus)
        }

        self.layer = layer
        self.device = device
        self.commandQueue = commandQueue
        self.library = library
        self.textureCache = cache
        self.maximumQueuedFrames = max(1, maximumQueuedFrames)
        self.nominalFramesPerSecond = pacingConfiguration.nominalFramesPerSecond
        self.displayRefreshRate = pacingConfiguration.displayRefreshRate
        self.state = State(
            isPresentationActive: presentationActive,
            usesDisplayLink: presentationActive
                && configuration.verticalSyncEnabled
                && Self.supportsMetalDisplayLinkPacing,
            adaptiveMailboxWaitEnabled: pacingConfiguration.framePacingEnabled
                && pacingConfiguration.verticalSyncEnabled,
            configuration: configuration
        )
        super.init()
        layer.device = device
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        layer.presentsWithTransaction = false
        layer.displaySyncEnabled = presentationActive && configuration.verticalSyncEnabled
        if presentationActive,
           Self.supportsMetalDisplayLinkPacing,
           configuration.verticalSyncEnabled {
            let generation = state.presentationGeneration
            renderExecutor.perform { [self] in
                installDisplayLinkOnExecutor(expectedGeneration: generation)
            }
        }
    }

    deinit {
        let displayLink = MetalDisplayLinkReference(displayLink)
        renderExecutor.shutDown {
            displayLink.value?.invalidate()
        }
    }

    var displayLinkTiming: (frameLatency: Float, frameRateRange: CAFrameRateRange)? {
        lock.lock()
        defer { lock.unlock() }
        guard state.usesDisplayLink else { return nil }
        return (
            1,
            Self.frameRateRange(
                framesPerSecond: nominalFramesPerSecond,
                displayRefreshRate: displayRefreshRate
            )
        )
    }

    public var usesDisplayLinkPresentation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.usesDisplayLink
    }

    #if DEBUG
    func setTestingHooks(_ hooks: MetalRendererTestingHooks) {
        lock.lock()
        testingHooks = hooks
        lock.unlock()
    }
    #endif

    public var lastError: MetalRendererError? {
        lock.lock()
        defer { lock.unlock() }
        return state.lastError
    }

    public func statistics(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> MediaPipelineStatistics {
        lock.lock()
        defer { lock.unlock() }
        return state.statistics.snapshot(at: time).including(
            latencyStatistics: state.latencyStatistics.snapshot()
        )
    }

    public func updateDisplayConfiguration(_ configuration: MetalDisplayConfiguration) {
        lock.lock()
        let shouldUseDisplayLink = state.isPresentationActive
            && configuration.verticalSyncEnabled
            && Self.supportsMetalDisplayLinkPacing
        let configurationChanged = configuration != state.configuration
        let presentationClockChanged = shouldUseDisplayLink != state.usesDisplayLink
        state.configuration = configuration
        state.usesDisplayLink = shouldUseDisplayLink
        if configurationChanged {
            advancePresentationGenerationLocked()
            updateDesiredLayerConfigurationLocked()
        }
        if presentationClockChanged || configurationChanged {
            state.adaptiveRenderLead.reset()
        }
        let generation = state.presentationGeneration
        let shouldDrain = armDrainIfNeededLocked()
        lock.signal()
        lock.unlock()
        renderExecutor.perform { [self] in
            applyPresentationClockOnExecutor(expectedGeneration: generation)
        }
        if shouldDrain { scheduleDrain() }
    }

    public func updatePacingConfiguration(_ configuration: FramePacingConfiguration) {
        lock.lock()
        nominalFramesPerSecond = configuration.nominalFramesPerSecond
        displayRefreshRate = configuration.displayRefreshRate
        let adaptiveMailboxWaitEnabled = configuration.framePacingEnabled
            && configuration.verticalSyncEnabled
        if adaptiveMailboxWaitEnabled != state.adaptiveMailboxWaitEnabled {
            state.adaptiveRenderLead.reset()
        }
        state.adaptiveMailboxWaitEnabled = adaptiveMailboxWaitEnabled
        let frameRateRange = Self.frameRateRange(
            framesPerSecond: configuration.nominalFramesPerSecond,
            displayRefreshRate: configuration.displayRefreshRate
        )
        lock.signal()
        lock.unlock()
        renderExecutor.perform { [weak self] in
            self?.displayLink?.preferredFrameRateRange = frameRateRange
        }
    }

    public func setPresentationActive(_ active: Bool) {
        lock.lock()
        guard active != state.isPresentationActive else {
            lock.unlock()
            return
        }
        state.isPresentationActive = active
        state.usesDisplayLink = active
            && state.configuration.verticalSyncEnabled
            && Self.supportsMetalDisplayLinkPacing
        advancePresentationGenerationLocked()
        if !active {
            state.desiredLayerConfiguration = nil
            state.layerConfigurationGeneration &+= 1
        }
        state.adaptiveRenderLead.reset()
        let generation = state.presentationGeneration
        let shouldDrain = armDrainIfNeededLocked()
        lock.broadcast()
        lock.unlock()
        renderExecutor.perform { [self] in
            applyPresentationClockOnExecutor(expectedGeneration: generation)
        }
        if shouldDrain { scheduleDrain() }
    }

    public func awaitPresentationQuiescence() async {
        await renderExecutor.barrier()
    }

    private func installDisplayLinkOnExecutor(expectedGeneration: UInt64) {
        guard Self.supportsMetalDisplayLinkPacing else { return }
        if displayLinkGeneration == expectedGeneration, displayLink != nil { return }
        displayLink?.invalidate()
        displayLink = nil
        displayLinkGeneration = nil
        let displayLink = CAMetalDisplayLink(metalLayer: layer)
        displayLink.preferredFrameLatency = 1
        lock.lock()
        let frameRateRange = Self.frameRateRange(
            framesPerSecond: nominalFramesPerSecond,
            displayRefreshRate: displayRefreshRate
        )
        lock.unlock()
        displayLink.preferredFrameRateRange = frameRateRange
        displayLink.delegate = self
        displayLink.add(to: .current, forMode: .common)
        self.displayLink = displayLink
        displayLinkGeneration = expectedGeneration
    }

    private func applyPresentationClockOnExecutor(expectedGeneration: UInt64) {
        lock.lock()
        let isCurrent = state.presentationGeneration == expectedGeneration
        let shouldUseDisplayLink = isCurrent && state.usesDisplayLink
        let displaySyncEnabled = isCurrent
            && state.isPresentationActive
            && state.configuration.verticalSyncEnabled
        lock.unlock()
        guard isCurrent else { return }
        layer.displaySyncEnabled = displaySyncEnabled
        if shouldUseDisplayLink {
            installDisplayLinkOnExecutor(expectedGeneration: expectedGeneration)
        } else if let displayLink {
            displayLink.invalidate()
            self.displayLink = nil
            displayLinkGeneration = nil
        }
    }

    public func updateLayerGeometry(size: CGSize, contentsScale: CGFloat) {
        renderExecutor.perform { [self] in
            layer.contentsScale = contentsScale
            layer.drawableSize = size
        }
    }

    public func enqueue(_ frame: DecodedVideoFrame) {
        let now = ProcessInfo.processInfo.systemUptime
        let timedFrame = frame.recordingRendererEnqueue(VideoLatencyTimestamp(
            seconds: CACurrentMediaTime(),
            clockDomain: .clientMediaTime
        ))
        var evictedFrameNumber: Int?
        lock.lock()
        guard state.isPresentationActive else {
            state.statistics.record(.dropped(.rendererUnavailable), at: now)
            let handler = frameDropHandler
            lock.unlock()
            handler(timedFrame.frameNumber, .rendererUnavailable)
            return
        }
        let desiredLayerConfiguration = LayerConfiguration(
            color: timedFrame.color,
            verticalSyncEnabled: state.configuration.verticalSyncEnabled
        )
        if desiredLayerConfiguration != state.desiredLayerConfiguration {
            state.desiredLayerConfiguration = desiredLayerConfiguration
            state.layerConfigurationGeneration &+= 1
        }
        if state.frames.count == maximumQueuedFrames {
            if state.dropsNewestWhenMailboxFull {
                state.statistics.record(.dropped(.queueOverflow), at: now)
                let handler = frameDropHandler
                lock.unlock()
                handler(timedFrame.frameNumber, .mailboxRejectedNewest)
                return
            }
            evictedFrameNumber = state.frames.removeFirst().frame.frameNumber
            state.statistics.record(.dropped(.queueOverflow), at: now)
        }
        state.frames.append(QueuedMetalFrame(
            frame: timedFrame,
            latencyGeneration: state.latencyGeneration.stamp,
            presentationGeneration: state.presentationGeneration,
            layerConfigurationGeneration: state.layerConfigurationGeneration
        ))
        state.statistics.record(.queueDepth(state.frames.count), at: now)
        let shouldDrain = armDrainIfNeededLocked()
        let dropHandler = frameDropHandler
        lock.signal()
        lock.unlock()
        if let evictedFrameNumber { dropHandler(evictedFrameNumber, .mailboxEviction) }
        if shouldDrain {
            scheduleDrain()
        }
    }

    public func installFirstPresentationProxyHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        lock.lock()
        firstMetalCommitHandler = handler
        lock.unlock()
    }

    public func installCommandCommitHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        lock.withLock { commandCommitHandler = handler }
    }

    public func installFrameDropHandler(
        _ handler: @escaping @Sendable (Int, MetalFrameDropReason) -> Void
    ) {
        lock.withLock { frameDropHandler = handler }
    }

    public func setMailboxDropNewest(_ enabled: Bool) {
        lock.withLock { state.dropsNewestWhenMailboxFull = enabled }
    }

    public func installTelemetryProfile(_ profile: StreamingTelemetryProfile) {
        lock.lock()
        state.latencyStatistics.setProfile(profile)
        lock.unlock()
    }

    public func installTelemetryClient(_ client: StreamingTelemetryClient) {
        lock.lock()
        state.latencyStatistics.setClient(client)
        lock.unlock()
    }

    public func flush() {
        lock.lock()
        state.frames.removeAll()
        state.presentationGeneration &+= 1
        state.layerConfigurationGeneration &+= 1
        state.desiredLayerConfiguration = nil
        state.adaptiveRenderLead.reset()
        state.latencyStatistics.reset()
        state.latencyGeneration.advance()
        state.reportedFirstMetalCommit = false
        state.statistics.reset()
        state.statistics.record(.queueDepth(0), at: ProcessInfo.processInfo.systemUptime)
        let generation = state.presentationGeneration
        lock.signal()
        lock.unlock()
        renderExecutor.perform { [self] in
            applyPresentationClockOnExecutor(expectedGeneration: generation)
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }

    private func renderNextFrame() {
        let now = CACurrentMediaTime()
        lock.lock()
        state.isDrainScheduled = false
        guard state.isPresentationActive,
              !state.usesDisplayLink,
              !state.frames.isEmpty else {
            lock.unlock()
            return
        }
        let queuedFrame = state.frames.removeLast()
        let staleFrameCount = state.frames.count
        state.frames.removeAll(keepingCapacity: true)
        for _ in 0..<staleFrameCount {
            state.statistics.record(.dropped(.queueOverflow), at: now)
        }
        state.statistics.record(.queueDepth(0), at: now)
        let shouldDrain = armDrainIfNeededLocked()
        let configuration = state.configuration
        lock.unlock()

        do {
            guard prepareImmediateLayerConfiguration(for: queuedFrame) else {
                if shouldDrain { scheduleDrain() }
                return
            }
            try encode(
                queuedFrame: queuedFrame,
                drawable: nil,
                pacingDecision: .presentImmediately,
                configuration: configuration
            )
        } catch let error as MetalRendererError {
            lock.lock()
            if acceptsLocked(queuedFrame) {
                state.lastError = error
                let reason: FrameDropReason = if case .unsupportedPixelFormat = error {
                    .unsupportedPixelFormat
                } else {
                    .rendererUnavailable
                }
                state.statistics.record(.dropped(reason), at: now)
            }
            lock.unlock()
        } catch {
            lock.lock()
            if acceptsLocked(queuedFrame) {
                state.statistics.record(.dropped(.rendererUnavailable), at: now)
            }
            lock.unlock()
        }
        if shouldDrain { scheduleDrain() }
    }

    private func armDrainIfNeededLocked() -> Bool {
        guard state.isPresentationActive,
              !state.frames.isEmpty,
              !state.usesDisplayLink,
              !state.isDrainScheduled else { return false }
        state.isDrainScheduled = true
        return true
    }

    private func scheduleDrain() {
        renderExecutor.perform { [self] in renderNextFrame() }
    }

    private func encode(
        queuedFrame: QueuedMetalFrame,
        drawable suppliedDrawable: (any CAMetalDrawable)?,
        pacingDecision: FramePacingDecision,
        configuration: MetalDisplayConfiguration,
        displayLinkPresentationTimestamp: TimeInterval? = nil
    ) throws {
        let frame = queuedFrame.frame
        let encodeStartedAt = CACurrentMediaTime()
        #if DEBUG
        let hooks = currentTestingHooks()
        hooks.didBeginEncode(frame.frameNumber)
        defer { hooks.didEndEncode(frame.frameNumber) }
        #endif
        guard accepts(queuedFrame) else { return }
        #if DEBUG
        hooks.beforeDrawableAcquisition(frame.frameNumber)
        #endif
        guard accepts(queuedFrame),
              layer.drawableSize.width > 0,
              layer.drawableSize.height > 0,
              let drawable = suppliedDrawable ?? layer.nextDrawable() else { return }
        guard accepts(queuedFrame),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandQueueUnavailable
        }

        let sourceSize = CGSize(
            width: CVPixelBufferGetWidth(frame.imageBuffer),
            height: CVPixelBufferGetHeight(frame.imageBuffer)
        )
        let quad = VideoGeometry.quad(
            source: sourceSize,
            destination: layer.drawableSize,
            mode: configuration.contentMode
        )
        let vertices = Self.vertices(for: quad)
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(
            red: configuration.clearColor.x,
            green: configuration.clearColor.y,
            blue: configuration.clearColor.z,
            alpha: configuration.clearColor.w
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw MetalRendererError.commandQueueUnavailable
        }
        vertices.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }

        let lease: MetalFrameLease
        let pixelFormat = CVPixelBufferGetPixelFormatType(frame.imageBuffer)
        if Self.isBiPlanar(pixelFormat) {
            let metalPlaneFormats: (MTLPixelFormat, MTLPixelFormat) = Self.isTenBit(pixelFormat)
                ? (.r16Unorm, .rg16Unorm)
                : (.r8Unorm, .rg8Unorm)
            let luma = try makeTexture(
                imageBuffer: frame.imageBuffer,
                pixelFormat: metalPlaneFormats.0,
                plane: 0
            )
            let chroma = try makeTexture(
                imageBuffer: frame.imageBuffer,
                pixelFormat: metalPlaneFormats.1,
                plane: 1
            )
            guard let lumaTexture = CVMetalTextureGetTexture(luma),
                  let chromaTexture = CVMetalTextureGetTexture(chroma) else {
                throw MetalRendererError.textureCreationFailed(kCVReturnInvalidArgument)
            }
            let pipeline = try pipeline(pixelFormat: drawable.texture.pixelFormat, yuv: true)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(lumaTexture, index: 0)
            encoder.setFragmentTexture(chromaTexture, index: 1)
            var uniforms = Self.uniforms(for: frame.color)
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<MetalFragmentUniforms>.stride,
                index: 0
            )
            lease = MetalFrameLease(
                frame: frame,
                textures: [luma, chroma],
                latencyGeneration: queuedFrame.latencyGeneration,
                presentationGeneration: queuedFrame.presentationGeneration
            )
        } else if pixelFormat == kCVPixelFormatType_32BGRA {
            let textureReference = try makeTexture(
                imageBuffer: frame.imageBuffer,
                pixelFormat: .bgra8Unorm,
                plane: 0
            )
            guard let texture = CVMetalTextureGetTexture(textureReference) else {
                throw MetalRendererError.textureCreationFailed(kCVReturnInvalidArgument)
            }
            let pipeline = try pipeline(pixelFormat: drawable.texture.pixelFormat, yuv: false)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            lease = MetalFrameLease(
                frame: frame,
                textures: [textureReference],
                latencyGeneration: queuedFrame.latencyGeneration,
                presentationGeneration: queuedFrame.presentationGeneration
            )
        } else {
            throw MetalRendererError.unsupportedPixelFormat(pixelFormat)
        }

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        let presentationProxy: (VideoLatencyTimestamp, VideoPresentationProxyEvidence)?
        switch pacingDecision {
        case let .schedule(time):
            presentationProxy = (
                VideoLatencyTimestamp(seconds: time, clockDomain: .clientMediaTime),
                .scheduledPresentationTime
            )
        case .presentImmediately:
            presentationProxy = displayLinkPresentationTimestamp.map {
                (
                    VideoLatencyTimestamp(seconds: $0, clockDomain: .clientMediaTime),
                    .displayLinkPresentationTarget
                )
            }
        case .drop:
            presentationProxy = nil
        }
        commandBuffer.addCompletedHandler { [self, lease] completedBuffer in
            guard let committedAt = lease.commandCommitTime else { return }
            let completedAt = ProcessInfo.processInfo.systemUptime
            let completedMediaTime = VideoLatencyTimestamp(
                seconds: CACurrentMediaTime(),
                clockDomain: .clientMediaTime
            )
            lock.lock()
            guard state.latencyGeneration.accepts(lease.latencyGeneration),
                  state.presentationGeneration == lease.presentationGeneration else {
                lock.unlock()
                return
            }
            if completedBuffer.status == .completed {
                state.statistics.record(.presented, at: completedAt)
                state.latencyStatistics.recordBestAvailablePresentationProxy(
                    from: committedAt,
                    preferredProxy: presentationProxy?.0,
                    preferredEvidence: presentationProxy?.1,
                    commandCompletion: completedMediaTime
                )
            } else {
                state.lastError = .commandBufferFailed(
                    completedBuffer.error?.localizedDescription ?? "Metal command buffer did not complete"
                )
                state.statistics.record(.dropped(.rendererUnavailable), at: completedAt)
            }
            lock.unlock()
        }
        #if DEBUG
        hooks.beforeCommit(frame.frameNumber)
        #endif
        lock.lock()
        guard acceptsLocked(queuedFrame) else {
            lock.unlock()
            return
        }
        switch pacingDecision {
        case let .schedule(time): commandBuffer.present(drawable, atTime: time)
        case .presentImmediately: commandBuffer.present(drawable)
        case .drop: break
        }
        let committedAt = lease.stampCommandCommit()
        commandBuffer.commit()
        state.adaptiveRenderLead.record(commitCost: CACurrentMediaTime() - encodeStartedAt)
        state.latencyStatistics.record(
            from: frame.latencyMetadata.videoToolboxDecodeCompletionTime,
            to: committedAt,
            stage: .decodeToMetalCommit
        )
        let shouldReportFirstMetalCommit = !state.reportedFirstMetalCommit
        state.reportedFirstMetalCommit = true
        let firstMetalCommitHandler = self.firstMetalCommitHandler
        let commandCommitHandler = self.commandCommitHandler
        lock.unlock()
        commandCommitHandler(frame.frameNumber)
        if shouldReportFirstMetalCommit {
            firstMetalCommitHandler(frame.frameNumber)
        }
        #if DEBUG
        hooks.didCommit(frame.frameNumber)
        #endif
    }

    public func metalDisplayLink(
        _ link: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard state.isPresentationActive,
              state.usesDisplayLink,
              displayLink === link,
              displayLinkGeneration == state.presentationGeneration else {
            lock.unlock()
            return
        }
        if let desiredLayerConfiguration = state.desiredLayerConfiguration,
           desiredLayerConfiguration != appliedLayerConfiguration {
            lock.unlock()
            configureLayerOnExecutor(desiredLayerConfiguration)
            return
        }
        let waitDuration = state.adaptiveRenderLead.waitDuration(
            now: now,
            targetTimestamp: update.targetTimestamp
        )
        if state.usesDisplayLink,
           state.adaptiveMailboxWaitEnabled,
           state.frames.isEmpty,
           waitDuration > 0 {
            _ = lock.wait(until: Date(timeIntervalSinceNow: waitDuration))
        }
        guard state.isPresentationActive,
              state.usesDisplayLink,
              displayLink === link,
              displayLinkGeneration == state.presentationGeneration else {
            lock.unlock()
            return
        }
        if let desiredLayerConfiguration = state.desiredLayerConfiguration,
           desiredLayerConfiguration != appliedLayerConfiguration {
            lock.unlock()
            configureLayerOnExecutor(desiredLayerConfiguration)
            return
        }
        guard let queuedFrame = state.frames.popLast() else {
            lock.unlock()
            return
        }
        let staleFrameCount = state.frames.count
        state.frames.removeAll(keepingCapacity: true)
        for _ in 0..<staleFrameCount {
            state.statistics.record(.dropped(.queueOverflow), at: now)
        }
        state.statistics.record(.queueDepth(0), at: now)
        let configuration = state.configuration
        lock.unlock()

        do {
            let presentationTimestamp = Self.displayLinkPresentationProxyTimestamp(
                targetTimestamp: update.targetTimestamp,
                targetPresentationTimestamp: update.targetPresentationTimestamp
            )
            try encode(
                queuedFrame: queuedFrame,
                drawable: update.drawable,
                pacingDecision: .presentImmediately,
                configuration: configuration,
                displayLinkPresentationTimestamp: presentationTimestamp
            )
        } catch let error as MetalRendererError {
            lock.lock()
            if acceptsLocked(queuedFrame) {
                state.lastError = error
                let reason: FrameDropReason = if case .unsupportedPixelFormat = error {
                    .unsupportedPixelFormat
                } else {
                    .rendererUnavailable
                }
                state.statistics.record(.dropped(reason), at: now)
            }
            lock.unlock()
        } catch {
            lock.lock()
            if acceptsLocked(queuedFrame) {
                state.statistics.record(.dropped(.rendererUnavailable), at: now)
            }
            lock.unlock()
        }
    }

    private func prepareImmediateLayerConfiguration(for queuedFrame: QueuedMetalFrame) -> Bool {
        lock.lock()
        guard acceptsLocked(queuedFrame) else {
            lock.unlock()
            return false
        }
        let layerConfiguration = LayerConfiguration(
            color: queuedFrame.frame.color,
            verticalSyncEnabled: state.configuration.verticalSyncEnabled
        )
        lock.unlock()
        configureLayerOnExecutor(layerConfiguration)
        return accepts(queuedFrame)
    }

    private func accepts(_ queuedFrame: QueuedMetalFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptsLocked(queuedFrame)
    }

    private func acceptsLocked(_ queuedFrame: QueuedMetalFrame) -> Bool {
        state.isPresentationActive
            && state.presentationGeneration == queuedFrame.presentationGeneration
            && state.layerConfigurationGeneration == queuedFrame.layerConfigurationGeneration
            && state.latencyGeneration.accepts(queuedFrame.latencyGeneration)
    }

    private func advancePresentationGenerationLocked() {
        state.presentationGeneration &+= 1
        state.frames.removeAll(keepingCapacity: true)
        state.statistics.record(.queueDepth(0), at: ProcessInfo.processInfo.systemUptime)
    }

    private func updateDesiredLayerConfigurationLocked() {
        guard let desiredLayerConfiguration = state.desiredLayerConfiguration else { return }
        let updated = LayerConfiguration(
            color: desiredLayerConfiguration.color,
            verticalSyncEnabled: state.configuration.verticalSyncEnabled
        )
        guard updated != desiredLayerConfiguration else { return }
        state.desiredLayerConfiguration = updated
        state.layerConfigurationGeneration &+= 1
    }

    #if DEBUG
    private func currentTestingHooks() -> MetalRendererTestingHooks {
        lock.lock()
        defer { lock.unlock() }
        return testingHooks
    }
    #endif

    static func displayLinkPresentationProxyTimestamp(
        targetTimestamp: TimeInterval,
        targetPresentationTimestamp: TimeInterval
    ) -> TimeInterval {
        _ = targetTimestamp
        return targetPresentationTimestamp
    }

    static func frameRateRange(
        framesPerSecond: Double,
        displayRefreshRate: Double = 60
    ) -> CAFrameRateRange {
        let sanitizedRefreshRate = displayRefreshRate.isFinite && displayRefreshRate > 0
            ? Float(displayRefreshRate)
            : 60
        let sanitizedFramesPerSecond = framesPerSecond.isFinite && framesPerSecond > 0
            ? Float(framesPerSecond)
            : min(60, sanitizedRefreshRate)
        let preferred = min(sanitizedFramesPerSecond, sanitizedRefreshRate)
        return CAFrameRateRange(
            minimum: preferred,
            maximum: sanitizedRefreshRate,
            preferred: preferred
        )
    }

    func configureLayerForTesting(
        for color: VideoColorMetadata,
        configuration: MetalDisplayConfiguration
    ) async {
        let layerConfiguration = LayerConfiguration(
            color: color,
            verticalSyncEnabled: configuration.verticalSyncEnabled
        )
        await withCheckedContinuation { continuation in
            renderExecutor.perform { [self] in
                configureLayerOnExecutor(layerConfiguration)
                continuation.resume()
            }
        }
    }

    private func configureLayerOnExecutor(_ layerConfiguration: LayerConfiguration) {
        guard layerConfiguration != appliedLayerConfiguration else { return }

        let color = layerConfiguration.color
        let useEDR = color.isHDR
        layer.displaySyncEnabled = layerConfiguration.verticalSyncEnabled
        layer.wantsExtendedDynamicRangeContent = useEDR
        if useEDR {
            layer.pixelFormat = .rgba16Float
            layer.colorspace = extendedRec2020ColorSpace
            if color.transferFunction == .hlg {
                layer.edrMetadata = .hlg
            } else {
                let metadata = color.hdrStaticMetadata
                if metadata?.masteringDisplayColorVolume != nil
                    || metadata?.contentLightLevelInfo != nil {
                    layer.edrMetadata = .hdr10(
                        displayInfo: metadata?.masteringDisplayColorVolume,
                        contentInfo: metadata?.contentLightLevelInfo,
                        opticalOutputScale: 100
                    )
                } else if let minimum = metadata?.minimumLuminanceNits,
                          let maximum = metadata?.maximumLuminanceNits {
                    layer.edrMetadata = .hdr10(
                        minLuminance: minimum,
                        maxLuminance: maximum,
                        opticalOutputScale: 100
                    )
                } else {
                    // A non-nil descriptor asks Core Animation to tone-map the
                    // extended-linear surface for the current display. Nil
                    // display/content blobs deliberately select Apple's system
                    // HDR10 defaults without inventing mastering values.
                    layer.edrMetadata = .hdr10(
                        displayInfo: nil,
                        contentInfo: nil,
                        opticalOutputScale: 100
                    )
                }
            }
        } else {
            layer.pixelFormat = .bgra8Unorm
            layer.colorspace = sRGBColorSpace
            layer.edrMetadata = nil
        }
        appliedLayerConfiguration = layerConfiguration
        #if DEBUG
        currentTestingHooks().didApplyLayerConfiguration(color)
        #endif
    }

    private func makeTexture(
        imageBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        plane: Int
    ) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        let planeCount = CVPixelBufferGetPlaneCount(imageBuffer)
        let width = planeCount == 0
            ? CVPixelBufferGetWidth(imageBuffer)
            : CVPixelBufferGetWidthOfPlane(imageBuffer, plane)
        let height = planeCount == 0
            ? CVPixelBufferGetHeight(imageBuffer)
            : CVPixelBufferGetHeightOfPlane(imageBuffer, plane)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            imageBuffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &texture
        )
        guard status == kCVReturnSuccess, let texture else {
            throw MetalRendererError.textureCreationFailed(status)
        }
        return texture
    }

    private func pipeline(
        pixelFormat: MTLPixelFormat,
        yuv: Bool
    ) throws -> any MTLRenderPipelineState {
        if let existing = yuv ? yuvPipelines[pixelFormat] : rgbPipelines[pixelFormat] {
            return existing
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "videoVertex")
        descriptor.fragmentFunction = library.makeFunction(name: yuv ? "yuvFragment" : "rgbFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            if yuv { yuvPipelines[pixelFormat] = pipeline } else { rgbPipelines[pixelFormat] = pipeline }
            return pipeline
        } catch {
            throw MetalRendererError.pipelineCreationFailed(error.localizedDescription)
        }
    }

    private static func vertices(for quad: VideoQuad) -> [MetalVideoVertex] {
        let sx = Float(quad.clipScale.x)
        let sy = Float(quad.clipScale.y)
        let minX = Float(quad.textureRect.minX)
        let maxX = Float(quad.textureRect.maxX)
        let minY = Float(quad.textureRect.minY)
        let maxY = Float(quad.textureRect.maxY)
        return [
            MetalVideoVertex(position: SIMD2(-sx, -sy), textureCoordinate: SIMD2(minX, maxY)),
            MetalVideoVertex(position: SIMD2(sx, -sy), textureCoordinate: SIMD2(maxX, maxY)),
            MetalVideoVertex(position: SIMD2(-sx, sy), textureCoordinate: SIMD2(minX, minY)),
            MetalVideoVertex(position: SIMD2(sx, sy), textureCoordinate: SIMD2(maxX, minY)),
        ]
    }

    private static func uniforms(for metadata: VideoColorMetadata) -> MetalFragmentUniforms {
        let conversion = YUVConversion(metadata: metadata)
        let matrix = simd_float3x3(rows: [
            SIMD3(conversion.matrix[0], conversion.matrix[1], conversion.matrix[2]),
            SIMD3(conversion.matrix[3], conversion.matrix[4], conversion.matrix[5]),
            SIMD3(conversion.matrix[6], conversion.matrix[7], conversion.matrix[8]),
        ])
        let transfer: Float = switch metadata.transferFunction {
        case .sdr: 0
        case .pq: 1
        case .hlg: 2
        }
        return MetalFragmentUniforms(
            matrix: matrix,
            offsetAndTransfer: SIMD4(
                conversion.offset[0],
                conversion.offset[1],
                conversion.offset[2],
                transfer
            )
        )
    }

    private static func isBiPlanar(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            true
        default:
            false
        }
    }

    private static func isTenBit(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            true
        default:
            false
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position;
        float2 textureCoordinate;
    };
    struct VertexOut {
        float4 position [[position]];
        float2 textureCoordinate;
    };
    struct FragmentUniforms {
        float3x3 matrix;
        float4 offsetAndTransfer;
    };

    vertex VertexOut videoVertex(
        uint vertexID [[vertex_id]],
        constant VertexIn *vertices [[buffer(0)]]) {
        VertexOut out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.textureCoordinate = vertices[vertexID].textureCoordinate;
        return out;
    }

    float3 pqToLinear(float3 value) {
        constexpr float m1 = 2610.0 / 16384.0;
        constexpr float m2 = 2523.0 / 32.0;
        constexpr float c1 = 3424.0 / 4096.0;
        constexpr float c2 = 2413.0 / 128.0;
        constexpr float c3 = 2392.0 / 128.0;
        float3 p = pow(max(value, 0.0), 1.0 / m2);
        // Result is normalized to 10,000 nits. Multiplying by 100 maps 1.0 to 100 nits.
        return pow(max(p - c1, 0.0) / max(c2 - c3 * p, 0.00001), 1.0 / m1) * 100.0;
    }

    float3 hlgToLinear(float3 value) {
        constexpr float a = 0.17883277;
        constexpr float b = 0.28466892;
        constexpr float c = 0.55991073;
        float3 low = (value * value) / 3.0;
        float3 high = (exp((value - c) / a) + b) / 12.0;
        return select(low, high, value > 0.5) * 10.0;
    }

    fragment float4 yuvFragment(
        VertexOut in [[stage_in]],
        texture2d<float> lumaTexture [[texture(0)]],
        texture2d<float> chromaTexture [[texture(1)]],
        constant FragmentUniforms &uniforms [[buffer(0)]]) {
        constexpr sampler sampleFilter(coord::normalized, address::clamp_to_edge, filter::linear);
        float y = lumaTexture.sample(sampleFilter, in.textureCoordinate).r;
        float2 cbcr = chromaTexture.sample(sampleFilter, in.textureCoordinate).rg;
        float3 rgb = max(uniforms.matrix * (float3(y, cbcr) + uniforms.offsetAndTransfer.xyz), 0.0);
        if (uniforms.offsetAndTransfer.w == 1.0) rgb = pqToLinear(rgb);
        if (uniforms.offsetAndTransfer.w == 2.0) rgb = hlgToLinear(rgb);
        return float4(rgb, 1.0);
    }

    fragment float4 rgbFragment(
        VertexOut in [[stage_in]],
        texture2d<float> colorTexture [[texture(0)]]) {
        constexpr sampler sampleFilter(coord::normalized, address::clamp_to_edge, filter::linear);
        return colorTexture.sample(sampleFilter, in.textureCoordinate);
    }
    """
}
