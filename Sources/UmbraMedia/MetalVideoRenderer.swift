import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ObjectiveC
import OSLog
import QuartzCore
import simd

public struct MetalDisplayConfiguration: Sendable, Equatable {
    public var contentMode: VideoContentMode
    public var verticalSyncEnabled: Bool
    /// Umbra Sync: with vertical sync off, frames still present immediately with no display
    /// link or pacing wait, but display sync stays on so a variable-refresh panel refreshes when
    /// each frame lands instead of tearing mid-scan.
    public var adaptiveSyncEnabled: Bool
    /// The target display shows Display P3. SDR frames are then converted from Rec. 709 in the
    /// shader rather than by WindowServer color matching, which composites every frame.
    public var wideGamutDisplay: Bool
    public var clearColor: SIMD4<Double>

    public init(
        contentMode: VideoContentMode = .aspectFit,
        verticalSyncEnabled: Bool = true,
        adaptiveSyncEnabled: Bool = false,
        wideGamutDisplay: Bool = false,
        clearColor: SIMD4<Double> = SIMD4(0, 0, 0, 1)
    ) {
        self.contentMode = contentMode
        self.verticalSyncEnabled = verticalSyncEnabled
        self.adaptiveSyncEnabled = adaptiveSyncEnabled
        self.wideGamutDisplay = wideGamutDisplay
        self.clearColor = clearColor
    }

    /// Whether the layer synchronizes presentation with the display; only vertical sync drives
    /// the display link.
    var displaySyncEnabled: Bool {
        verticalSyncEnabled || adaptiveSyncEnabled
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
    /// x is 1 when SDR output is converted from Rec. 709 to Display P3 primaries.
    var output: SIMD4<Float>
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
            Self.promoteCurrentThreadToRealTime()
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

    /// A time-shared thread can be descheduled for many milliseconds under load, which shows up as
    /// render-queue spikes. A Mach real-time constraint keeps presentation ahead of ordinary work;
    /// the kernel demotes the thread if it ever overruns its budget.
    private static func promoteCurrentThreadToRealTime() {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer != 0 else { return }
        func ticks(_ nanoseconds: UInt64) -> UInt32 {
            UInt32(nanoseconds * UInt64(timebase.denom) / UInt64(timebase.numer))
        }
        var policy = thread_time_constraint_policy_data_t(
            period: 0,
            computation: ticks(1_000_000),
            constraint: ticks(2_000_000),
            preemptible: 1
        )
        let count = MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size
        _ = withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: count) {
                thread_policy_set(
                    pthread_mach_thread_np(pthread_self()),
                    thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                    $0,
                    mach_msg_type_number_t(count)
                )
            }
        }
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
        let displaySyncEnabled: Bool
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
        var diagnosticEnqueuedFrames = 0
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
    /// Per-second presentation diagnostics; touched only on the render executor.
    private var presentationDiagnostics = PresentationDiagnostics()
    /// Where the video sits inside the drawable, normalized with a top-left origin. The layer
    /// covers the whole screen so it can be scanned out directly; the video may sit in a smaller
    /// safe area below a camera housing, with the rest cleared to black.
    private var videoContentRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Live presentation experiment for Umbra Sync, read once a second from the
    /// `UmbraPresentMode` default (`vrr`, `immediate`, or `scanline`); render executor only.
    private var presentMode = UmbraPresentMode.vrr
    private var scanlineLead: CFTimeInterval = 0.0012
    private var minimumOnGlassDuration: CFTimeInterval = 1.0 / 120
    private var layerExperimentState = ""
    private var gpuPriority: UInt32 = 0
    private var attimeTarget: CFTimeInterval?
    private var genlockReportHandler: @Sendable (GenlockReport) -> Void = { _ in }
    /// Genlock controller state; render executor only.
    private var genlockFlipSamples: [CFTimeInterval] = []
    private var genlockFlipEstimate: CFTimeInterval = 0.0028
    private var genlockSlackSamples: [CFTimeInterval] = []
    private var genlockLastReport: CFTimeInterval = 0
    private var genlockTargetOffset: CFTimeInterval = 0.00005
    private var genlockDesiredSlack: CFTimeInterval = 0.003
    private var genlockWasActive = false
    private var lastSyncedDeadline: CFTimeInterval = 0
    /// UmbraSyncedLeadMs override for the commit lead; nil aims commits at WindowServer's update.
    private var syncedCommitLeadOverride: CFTimeInterval?
    /// Time left for the draw before a hardware-scheduled flip.
    private static let attimeRenderMargin: CFTimeInterval = 0.0015
    private let vblankClock = VBlankClock()
    /// Per-minute rollup of the one-second windows; touched only on the render executor.
    private var presentationSummary = PresentationSummary()
    private var presentationSummaryHandler: @Sendable (String) -> Void = { _ in }
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
        layer.maximumDrawableCount = Self.drawableCount(for: configuration)
        // Live experiment: private presentation-path switches, applied before the first drawable
        // so the render server builds the layer's swap path with them.
        let launchDefaults = UserDefaults.standard
        for (key, defaultsKey) in [("serverSyncEnabled", "UmbraLayerServerSync"), ("lowLatency", "UmbraLayerLowLatency"), ("fenceEnabled", "UmbraLayerFence")] {
            if let requested = launchDefaults.object(forKey: defaultsKey) as? Bool,
               layer.responds(to: NSSelectorFromString(key)) {
                layer.setValue(requested, forKey: key)
            }
        }
        layer.allowsNextDrawableTimeout = true
        layer.presentsWithTransaction = false
        layer.displaySyncEnabled = presentationActive && configuration.displaySyncEnabled
        if configuration.adaptiveSyncEnabled {
            renderDiagnosticsLog.notice("umbra sync active=\(!configuration.verticalSyncEnabled)")
        }
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
        if configuration.adaptiveSyncEnabled != state.configuration.adaptiveSyncEnabled {
            renderDiagnosticsLog.notice("umbra sync active=\(configuration.adaptiveSyncEnabled && !configuration.verticalSyncEnabled)")
        }
        let presentationClockChanged = shouldUseDisplayLink != state.usesDisplayLink
        state.configuration = configuration
        state.usesDisplayLink = shouldUseDisplayLink
        if configurationChanged {
            renderDiagnosticsLog.notice("display configuration changed vsync=\(configuration.verticalSyncEnabled) umbraSync=\(configuration.adaptiveSyncEnabled) displayLink=\(shouldUseDisplayLink)")
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
        renderDiagnosticsLog.notice("pacing fps=\(configuration.nominalFramesPerSecond) refresh=\(configuration.displayRefreshRate) adaptiveWait=\(adaptiveMailboxWaitEnabled)")
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
        renderDiagnosticsLog.notice("presentation active=\(active)")
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
            if active { presentationSummary = PresentationSummary() }
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
        renderDiagnosticsLog.notice(
            "display link installed generation=\(expectedGeneration) fps=\(frameRateRange.minimum)-\(frameRateRange.maximum) preferred=\(String(describing: frameRateRange.preferred))"
        )
        displayLink.delegate = self
        displayLink.add(to: .current, forMode: .common)
        self.displayLink = displayLink
        displayLinkGeneration = expectedGeneration
    }

    /// A third drawable keeps nextDrawable from blocking while one frame is on glass and the
    /// next is in flight; the renderer always draws the newest arrival.
    static func drawableCount(for configuration: MetalDisplayConfiguration) -> Int {
        3
    }

    private func applyPresentationClockOnExecutor(expectedGeneration: UInt64) {
        lock.lock()
        let isCurrent = state.presentationGeneration == expectedGeneration
        let shouldUseDisplayLink = isCurrent && state.usesDisplayLink
        let displaySyncEnabled = isCurrent
            && state.isPresentationActive
            && state.configuration.displaySyncEnabled
        let drawableCount = Self.drawableCount(for: state.configuration)
        let forcesUnsynced = presentModeForcesUnsynced(state.configuration)
        lock.unlock()
        guard isCurrent else { return }
        layer.displaySyncEnabled = displaySyncEnabled && !forcesUnsynced
        if layer.maximumDrawableCount != drawableCount {
            layer.maximumDrawableCount = drawableCount
        }
        if shouldUseDisplayLink {
            installDisplayLinkOnExecutor(expectedGeneration: expectedGeneration)
        } else if let displayLink {
            displayLink.invalidate()
            self.displayLink = nil
            displayLinkGeneration = nil
        }
    }

    public func updateLayerGeometry(
        size: CGSize,
        contentsScale: CGFloat,
        videoContentRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) {
        renderExecutor.perform { [self] in
            layer.contentsScale = contentsScale
            layer.drawableSize = size
            self.videoContentRect = videoContentRect
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
            displaySyncEnabled: state.configuration.displaySyncEnabled
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
        state.diagnosticEnqueuedFrames += 1
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

    /// Receives one presentation summary line per minute of streaming, for the persistent log.
    public func installPresentationSummaryHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { presentationSummaryHandler = handler }
    }

    public func installGenlockReportHandler(_ handler: @escaping @Sendable (GenlockReport) -> Void) {
        lock.withLock { genlockReportHandler = handler }
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
        presentationDiagnostics.recordCallback(at: now)
        presentationDiagnostics.staleFrames += staleFrameCount
        presentationDiagnostics.presentedFrames += 1
        defer {
            presentationDiagnostics.maximumEncode = max(
                presentationDiagnostics.maximumEncode,
                CACurrentMediaTime() - now
            )
            flushPresentationDiagnostics(now: CACurrentMediaTime())
        }

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
        var queuedFrame = queuedFrame
        var frame = queuedFrame.frame
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
              layer.drawableSize.height > 0 else { return }
        let drawableRequestedAt = CACurrentMediaTime()
        let acquiredDrawable = suppliedDrawable ?? layer.nextDrawable()
        if suppliedDrawable == nil {
            let wait = CACurrentMediaTime() - drawableRequestedAt
            presentationDiagnostics.maximumDrawableWait = max(presentationDiagnostics.maximumDrawableWait, wait)
            if wait > 0.004 { presentationDiagnostics.slowDrawableWaits += 1 }
            if acquiredDrawable == nil { presentationDiagnostics.missingDrawables += 1 }
        }
        guard let drawable = acquiredDrawable else { return }
        if suppliedDrawable == nil {
            // nextDrawable can block until the next vblank when two frames land in one refresh.
            // Draw whatever is newest once the drawable is ours instead of the frame dequeued
            // before the wait, which would present a stale frame and push the new one back.
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            if let newest = state.frames.last,
               newest.layerConfigurationGeneration == queuedFrame.layerConfigurationGeneration {
                let superseded = state.frames.count
                state.frames.removeAll(keepingCapacity: true)
                for _ in 0..<superseded {
                    state.statistics.record(.dropped(.queueOverflow), at: now)
                }
                state.statistics.record(.queueDepth(0), at: now)
                queuedFrame = newest
                frame = newest.frame
                presentationDiagnostics.staleFrames += superseded
            }
            lock.unlock()
        }
        guard accepts(queuedFrame),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandQueueUnavailable
        }

        let sourceSize = CGSize(
            width: CVPixelBufferGetWidth(frame.imageBuffer),
            height: CVPixelBufferGetHeight(frame.imageBuffer)
        )
        let content = videoContentRect
        let quad = VideoGeometry.quad(
            source: sourceSize,
            destination: CGSize(
                width: layer.drawableSize.width * content.width,
                height: layer.drawableSize.height * content.height
            ),
            mode: configuration.contentMode
        )
        let vertices = Self.vertices(for: quad, in: content)
        let umbraSync = configuration.adaptiveSyncEnabled && !configuration.verticalSyncEnabled
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
            var uniforms = Self.uniforms(for: frame.color, wideGamutDisplay: configuration.wideGamutDisplay)
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
            var uniforms = Self.uniforms(for: frame.color, wideGamutDisplay: configuration.wideGamutDisplay)
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<MetalFragmentUniforms>.stride,
                index: 0
            )
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
        let gpuCommitTime = CACurrentMediaTime()
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            let gpuEnd = completedBuffer.gpuEndTime
            guard gpuEnd > 0 else { return }
            self?.renderExecutor.perform { [weak self] in
                self?.recordGPUCompletion(commitToGPUEnd: gpuEnd - gpuCommitTime, gpuTime: gpuEnd - completedBuffer.gpuStartTime)
            }
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
        // Presentation timing runs before the state lock: holds and scanline waits must never
        // block enqueue, and the genlock report reads the handler under that lock.
        if umbraSync, suppliedDrawable == nil {
            let wantsDisplaySync = presentMode == .vrr || presentMode == .vrrmin || presentMode == .vrrpaced
            if layer.displaySyncEnabled != wantsDisplaySync {
                layer.displaySyncEnabled = wantsDisplaySync
            }
            if presentMode == .genlock {
                genlockHold(frameNumber: frame.frameNumber)
            }
            if presentMode == .vrrpaced {
                syncedGenlock(frameNumber: frame.frameNumber, latency: frame.latencyMetadata)
            }
            if presentMode == .scanline,
               let scanout = vblankClock.nextScanoutStart(atOrAfter: CACurrentMediaTime() + scanlineLead) {
                // Commit just early enough for the draw to finish and the immediate flip to land
                // in the blanking interval before scanout, never mid-scan.
                Self.wait(until: scanout - scanlineLead)
            }
        }
        lock.lock()
        guard acceptsLocked(queuedFrame) else {
            lock.unlock()
            return
        }
        if case .presentImmediately = pacingDecision {
            let commitTime = CACurrentMediaTime()
            let arrivalTime = frame.latencyMetadata.rendererEnqueueTime?.seconds
            // presentedTime is the real on-glass time; the handler itself runs a few refreshes
            // later, so it measures latency but must never gate presentation.
            attimeTarget = umbraSync ? attimeTargetForHandler() : nil
            drawable.addPresentedHandler { [weak self, flipTarget = attimeTarget] presented in
                let shownAt = presented.presentedTime
                if let flipTarget, shownAt > 0 {
                    self?.renderExecutor.perform { [weak self] in
                        guard let self, self.presentationDiagnostics.flipErrorSamples.count < 512 else { return }
                        self.presentationDiagnostics.flipErrorSamples.append(shownAt - flipTarget)
                    }
                }
                self?.renderExecutor.perform { [weak self] in
                    self?.drawableReachedGlass(shownAt: shownAt, committedAt: commitTime)
                    if let self, let arrivalTime, shownAt > arrivalTime,
                       self.presentationDiagnostics.arrivalToGlassSamples.count < 512 {
                        self.presentationDiagnostics.arrivalToGlassSamples.append(shownAt - arrivalTime)
                    }
                }
            }
        }
        switch pacingDecision {
        case let .schedule(time): commandBuffer.present(drawable, atTime: time)
        case .presentImmediately:
            if umbraSync, suppliedDrawable == nil, presentMode == .attime, let attimeTarget {
                commandBuffer.present(drawable, atTime: attimeTarget)
            } else if umbraSync, suppliedDrawable == nil, presentMode == .vrrmin {
                // Adaptive-Sync scheduling: show this frame as soon as the previous one has been
                // on glass for the panel's minimum refresh interval, instead of at a latched vblank.
                commandBuffer.present(drawable, afterMinimumDuration: minimumOnGlassDuration)
            } else {
                commandBuffer.present(drawable)
            }
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
        presentationDiagnostics.recordCallback(at: now)
        defer { flushPresentationDiagnostics(now: now) }
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
            presentationDiagnostics.layerReconfigurations += 1
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
            presentationDiagnostics.emptyCallbacks += 1
            lock.unlock()
            return
        }
        let staleFrameCount = state.frames.count
        presentationDiagnostics.staleFrames += staleFrameCount
        state.frames.removeAll(keepingCapacity: true)
        for _ in 0..<staleFrameCount {
            state.statistics.record(.dropped(.queueOverflow), at: now)
        }
        state.statistics.record(.queueDepth(0), at: now)
        let configuration = state.configuration
        lock.unlock()
        presentationDiagnostics.presentedFrames += 1
        defer {
            presentationDiagnostics.maximumEncode = max(
                presentationDiagnostics.maximumEncode,
                CACurrentMediaTime() - now
            )
        }

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

    /// Runs on the render executor when Core Animation shows (or discards) a drawable.
    private func drawableReachedGlass(shownAt: CFTimeInterval, committedAt: CFTimeInterval) {
        if shownAt > 0 {
            let latency = max(0, shownAt - committedAt)
            presentationDiagnostics.glassLatencySum += latency
            if presentationDiagnostics.glassLatencySamples.count < 512 {
                presentationDiagnostics.glassLatencySamples.append(latency)
            }
            if presentMode == .genlock {
                genlockFlipSamples.append(latency)
                if genlockFlipSamples.count >= 32 {
                    // Immediate flips land 1.5 to 5 ms after commit; anything outside that is a
                    // mis-measured or synced flip and must not move the target.
                    genlockFlipEstimate = min(0.005, max(0.0015, genlockFlipSamples.sorted()[genlockFlipSamples.count / 2]))
                    genlockFlipSamples.removeAll(keepingCapacity: true)
                }
            }
            if let phase = vblankClock.scanPhase(at: shownAt) {
                presentationDiagnostics.flipPhaseBins[min(15, max(0, Int(phase * 16)))] += 1
            }
            presentationDiagnostics.glassLatencyCount += 1
            presentationDiagnostics.maximumGlassLatency = max(presentationDiagnostics.maximumGlassLatency, latency)
        } else {
            presentationDiagnostics.unshownPresents += 1
        }
    }

    /// Holds an early frame until the commit moment that lands its immediate flip at the target
    /// scan position, and reports how early frames arrive so the host can shift its release.
    private func genlockHold(frameNumber: Int) {
        let now = CACurrentMediaTime()
        guard let period = vblankClock.refreshPeriod,
              let scanout = vblankClock.nextScanoutStart(atOrAfter: now + genlockFlipEstimate - genlockTargetOffset) else { return }
        let commitTarget = scanout + genlockTargetOffset - genlockFlipEstimate
        // Time until the next commit moment, always in (0, period]: every frame waits for it, so
        // no flip ever lands mid-scan. The loop steers that wait toward the desired cushion.
        let wait = commitTarget - now
        var error = wait - genlockDesiredSlack
        error -= (error / period).rounded() * period
        genlockSlackSamples.append(error)
        presentationDiagnostics.genlockSlackSamples.append(wait)
        if wait > 0 {
            Self.wait(until: commitTarget)
            presentationDiagnostics.genlockHolds += 1
        }
        if error < -0.001 {
            presentationDiagnostics.genlockLate += 1
        }
        if now - genlockLastReport >= 0.05, !genlockSlackSamples.isEmpty {
            // Positive error: frames arrive earlier than the cushion needs, so release later.
            let correction = genlockSlackSamples.sorted()[genlockSlackSamples.count / 2]
            genlockSlackSamples.removeAll(keepingCapacity: true)
            genlockLastReport = now
            presentationDiagnostics.genlockReports += 1
            presentationDiagnostics.genlockLastCorrection = correction
            let handler = lock.withLock { genlockReportHandler }
            handler(GenlockReport(
                refreshPeriodNanoseconds: UInt64(period * 1_000_000_000),
                phaseCorrectionNanoseconds: Int64(max(-0.049, min(0.049, correction)) * 1_000_000_000),
                frameNumber: frameNumber,
                active: true
            ))
            genlockWasActive = true
        }
    }

    /// Synced genlock: frames stay vsync-synced (no tearing) and the host is steered so each one
    /// arrives `genlockDesiredSlack` before WindowServer's next display update, the latest moment
    /// a frame still reaches the following refresh. Frames are never held; `holds` counts frames
    /// that shared a refresh window.
    private func syncedGenlock(frameNumber: Int, latency: VideoFrameLatencyMetadata) {
        let now = CACurrentMediaTime()
        recordStagePhases(latency: latency, commit: now)
        guard let period = vblankClock.refreshPeriod else { return }
        // WindowServer runs its display update about 0.5 ms after each vsync, and the frames it
        // picks up then reach the display controller in time for the next refresh. The deadline
        // is just after a vsync: one period minus 0.3 ms ahead of the following scanout.
        let commitLead = syncedCommitLeadOverride ?? (period - 0.0003)
        guard let scanout = vblankClock.nextScanoutStart(atOrAfter: now + commitLead) else { return }
        let deadline = scanout - commitLead
        // Steer from the arrival margin before any hold: a held frame's extra refresh says
        // nothing about the host's phase and would bias every correction late.
        let lead = deadline - now
        if deadline <= lastSyncedDeadline + period * 0.5 {
            // Two frames in one refresh window. Holding this one would push every later frame
            // a refresh back too, so it commits now and only the count is kept.
            presentationDiagnostics.genlockHolds += 1
        }
        lastSyncedDeadline = deadline
        var error = lead - genlockDesiredSlack
        error -= (error / period).rounded() * period
        genlockSlackSamples.append(error)
        presentationDiagnostics.genlockSlackSamples.append(lead)
        if error < -0.001 {
            presentationDiagnostics.genlockLate += 1
        }
        guard now - genlockLastReport >= 0.05, !genlockSlackSamples.isEmpty else { return }
        // Positive error: frames arrive earlier than the slack needs, so the host releases later.
        let correction = genlockSlackSamples.sorted()[genlockSlackSamples.count / 2]
        genlockSlackSamples.removeAll(keepingCapacity: true)
        genlockLastReport = now
        presentationDiagnostics.genlockReports += 1
        presentationDiagnostics.genlockLastCorrection = correction
        let handler = lock.withLock { genlockReportHandler }
        handler(GenlockReport(
            refreshPeriodNanoseconds: UInt64(period * 1_000_000_000),
            phaseCorrectionNanoseconds: Int64(max(-0.049, min(0.049, correction)) * 1_000_000_000),
            frameNumber: frameNumber,
            active: true
        ))
        genlockWasActive = true
    }

    /// Where each pipeline stage of this frame fell within the refresh, in sixteenths after
    /// scanout start, and how long decode took: shows whether arrival jitter comes from the
    /// network or from the Mac.
    private func recordStagePhases(latency: VideoFrameLatencyMetadata, commit: CFTimeInterval) {
        func bin(_ time: CFTimeInterval?) -> Int? {
            guard let time, let phase = vblankClock.scanPhase(at: time) else { return nil }
            return min(15, max(0, Int(phase * 16)))
        }
        if let b = bin(latency.receiveTime?.seconds) { presentationDiagnostics.receivePhaseBins[b] += 1 }
        if let b = bin(latency.videoToolboxDecodeCompletionTime?.seconds) { presentationDiagnostics.decodedPhaseBins[b] += 1 }
        if let b = bin(commit) { presentationDiagnostics.commitPhaseBins[b] += 1 }
        if let submit = latency.videoToolboxSubmitTime, let done = latency.videoToolboxDecodeCompletionTime,
           let decode = submit.duration(to: done), presentationDiagnostics.decodeSamples.count < 512 {
            presentationDiagnostics.decodeSamples.append(decode)
        }
        if let receive = latency.receiveTime?.seconds, presentationDiagnostics.receiveToCommitSamples.count < 512,
           commit >= receive {
            presentationDiagnostics.receiveToCommitSamples.append(commit - receive)
        }
    }

    /// The scheduled flip time for the drawable being presented; computed before the presented
    /// handler is registered, so it reflects this frame.
    private func attimeTargetForHandler() -> CFTimeInterval? {
        guard presentMode == .attime,
              let scanout = vblankClock.nextScanoutStart(atOrAfter: CACurrentMediaTime() + Self.attimeRenderMargin + scanlineLead) else { return nil }
        return scanout - scanlineLead
    }

    private func recordGPUCompletion(commitToGPUEnd: CFTimeInterval, gpuTime: CFTimeInterval) {
        guard presentationDiagnostics.gpuDoneSamples.count < 512 else { return }
        presentationDiagnostics.gpuDoneSamples.append(commitToGPUEnd)
        presentationDiagnostics.gpuTimeSamples.append(gpuTime)
    }

    private static func percentiles(_ samples: [CFTimeInterval], label: String = "glass") -> String {
        guard !samples.isEmpty else { return "\(label)P50=- \(label)P90=- \(label)P99=-" }
        let sorted = samples.sorted()
        func at(_ q: Double) -> String { String(format: "%.2f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] * 1000) }
        return "\(label)P50=\(at(0.5)) \(label)P90=\(at(0.9)) \(label)P99=\(at(0.99))"
    }

    private static func wait(until time: CFTimeInterval) {
        let remaining = time - CACurrentMediaTime()
        guard remaining > 0, remaining < 0.02 else { return }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = UInt64(remaining * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
        mach_wait_until(mach_absolute_time() + ticks)
    }

    /// Private CAMetalLayer switches under live test; applied only when the layer responds.
    private func applyLayerExperiment(_ key: String, defaultsKey: String, defaults: UserDefaults) -> String {
        let selector = NSSelectorFromString(key)
        guard layer.responds(to: selector) else { return "n/a" }
        if let requested = defaults.object(forKey: defaultsKey) as? Bool {
            let current = (layer.value(forKey: key) as? Bool) ?? !requested
            if current != requested { layer.setValue(requested, forKey: key) }
        }
        return String(describing: layer.value(forKey: key) ?? "nil")
    }

    /// Apple GPU queue priority through IOGPUMetalCommandQueue; the driver asserts on any
    /// foreground value other than 1, 2, or 4, so only those are ever passed.
    private func applyGPUPriority(_ requested: Int) {
        let queue = commandQueue as AnyObject
        let getSelector = NSSelectorFromString("getGPUPriority")
        let setSelector = NSSelectorFromString("setGPUPriority:")
        guard queue.responds(to: getSelector), queue.responds(to: setSelector),
              let queueClass = object_getClass(queue) else { return }
        typealias Get = @convention(c) (AnyObject, Selector) -> UInt32
        typealias Set = @convention(c) (AnyObject, Selector, UInt32) -> Void
        let get = unsafeBitCast(class_getMethodImplementation(queueClass, getSelector), to: Get.self)
        if [1, 2, 4].contains(requested), get(queue, getSelector) != UInt32(requested) {
            let set = unsafeBitCast(class_getMethodImplementation(queueClass, setSelector), to: Set.self)
            set(queue, setSelector, UInt32(requested))
        }
        gpuPriority = get(queue, getSelector)
    }

    /// Umbra Sync's unsynced present modes flip immediately; no layer reconfiguration may turn
    /// display sync back on underneath them, or those frames take the two-refresh synced path.
    private func presentModeForcesUnsynced(_ configuration: MetalDisplayConfiguration) -> Bool {
        configuration.adaptiveSyncEnabled && !configuration.verticalSyncEnabled
            && presentMode != .vrr && presentMode != .vrrmin && presentMode != .vrrpaced
    }

    private func refreshPresentMode() {
        let defaults = UserDefaults.standard
        applyGPUPriority(defaults.integer(forKey: "UmbraGPUPriority"))
        layerExperimentState = [
            "lowLatency=" + applyLayerExperiment("lowLatency", defaultsKey: "UmbraLayerLowLatency", defaults: defaults),
            "serverSync=" + applyLayerExperiment("serverSyncEnabled", defaultsKey: "UmbraLayerServerSync", defaults: defaults),
            "fence=" + applyLayerExperiment("fenceEnabled", defaultsKey: "UmbraLayerFence", defaults: defaults),
            "compositing=" + String(describing: layer.responds(to: NSSelectorFromString("displayCompositingInternalStatus"))
                ? (layer.value(forKey: "displayCompositingInternalStatus") ?? "nil") : "n/a"),
        ].joined(separator: " ")
        let mode = defaults.string(forKey: "UmbraPresentMode").flatMap(UmbraPresentMode.init(rawValue:)) ?? .vrr
        let leadMilliseconds = defaults.double(forKey: "UmbraScanlineLeadMs")
        scanlineLead = leadMilliseconds > 0 ? leadMilliseconds / 1000 : 0.0012
        let targetMilliseconds = defaults.object(forKey: "UmbraGenlockTargetMs") as? Double
        genlockTargetOffset = (targetMilliseconds ?? 0.05) / 1000
        let slackMilliseconds = defaults.object(forKey: "UmbraGenlockSlackMs") as? Double
        // Half a refresh at most: beyond that the wrapped error can no longer tell early from late.
        genlockDesiredSlack = min(0.004, max(0.0003, (slackMilliseconds ?? 1.5) / 1000))
        if presentMode != .genlock, presentMode != .vrrpaced, genlockWasActive, let period = vblankClock.refreshPeriod ?? Optional(1.0 / 120) {
            genlockWasActive = false
            let handler = lock.withLock { genlockReportHandler }
            handler(GenlockReport(
                refreshPeriodNanoseconds: UInt64(period * 1_000_000_000),
                phaseCorrectionNanoseconds: 0,
                frameNumber: 0,
                active: false
            ))
        }
        syncedCommitLeadOverride = (defaults.object(forKey: "UmbraSyncedLeadMs") as? Double)
            .map { min(0.05, max(0.0005, $0 / 1000)) }
        let minimumMilliseconds = defaults.double(forKey: "UmbraMinDurationMs")
        minimumOnGlassDuration = minimumMilliseconds > 0 ? minimumMilliseconds / 1000 : 1.0 / 120
        guard mode != presentMode else { return }
        presentMode = mode
        if mode != .vrr {
            vblankClock.start(displayID: CGMainDisplayID())
        } else {
            vblankClock.stop()
        }
        renderDiagnosticsLog.notice("present mode=\(mode.rawValue, privacy: .public) leadMs=\(leadMilliseconds)")
    }

    private func flushPresentationDiagnostics(now: CFTimeInterval) {
        guard now - presentationDiagnostics.windowStart >= 1 else { return }
        refreshPresentMode()
        lock.lock()
        let arrived = state.diagnosticEnqueuedFrames
        state.diagnosticEnqueuedFrames = 0
        let generation = state.presentationGeneration
        lock.unlock()
        let d = presentationDiagnostics
        let mode = presentMode.rawValue + " " + layerExperimentState + " gpuPriority=\(gpuPriority) "
            + Self.percentiles(d.glassLatencySamples) + " "
            + Self.percentiles(d.gpuDoneSamples, label: "gpuDone") + " "
            + Self.percentiles(d.gpuTimeSamples, label: "gpuTime") + " "
            + Self.percentiles(d.flipErrorSamples, label: "flipErr")
            + " flipPhase16=" + d.flipPhaseBins.map(String.init).joined(separator: ",")
            + " recvPhase16=" + d.receivePhaseBins.map(String.init).joined(separator: ",")
            + " decodedPhase16=" + d.decodedPhaseBins.map(String.init).joined(separator: ",")
            + " commitPhase16=" + d.commitPhaseBins.map(String.init).joined(separator: ",")
            + " " + Self.percentiles(d.decodeSamples, label: "decode")
            + " " + Self.percentiles(d.receiveToCommitSamples, label: "recvToCommit")
            + " " + Self.percentiles(d.arrivalToGlassSamples, label: "arrival")
            + " " + Self.percentiles(d.genlockSlackSamples, label: "slack")
            + " holds=\(d.genlockHolds) late=\(d.genlockLate) reports=\(d.genlockReports)"
            + String(format: " correctionMs=%.2f flipEstMs=%.2f", d.genlockLastCorrection * 1000, genlockFlipEstimate * 1000)
        renderDiagnosticsLog.notice(
            "present window=\(Int((now - d.windowStart) * 1000))ms arrived=\(arrived) callbacks=\(d.callbacks) presented=\(d.presentedFrames) empty=\(d.emptyCallbacks) stale=\(d.staleFrames) drawableWaitMaxMs=\(Int(d.maximumDrawableWait * 1000)) slowDrawableWaits=\(d.slowDrawableWaits) missingDrawables=\(d.missingDrawables) layerReconfig=\(d.layerReconfigurations) maxGapMs=\(Int(d.maximumGap * 1000)) maxEncodeMs=\(Int(d.maximumEncode * 1000)) glassAvgMs=\(String(format: "%.1f", d.glassLatencyCount > 0 ? d.glassLatencySum / Double(d.glassLatencyCount) * 1000 : 0), privacy: .public) glassMaxMs=\(String(format: "%.1f", d.maximumGlassLatency * 1000), privacy: .public) unshown=\(d.unshownPresents) mode=\(mode, privacy: .public) generation=\(generation)"
        )
        presentationDiagnostics = PresentationDiagnostics(windowStart: now, lastCallback: now)
        presentationSummary.add(arrived: arrived, window: d)
        guard now - presentationSummary.windowStart >= 60 else { return }
        let summary = presentationSummary
        presentationSummary = PresentationSummary(windowStart: now)
        let handler = lock.withLock { presentationSummaryHandler }
        handler(
            "present summary window=\(Int(now - summary.windowStart))s arrived=\(summary.arrived) presented=\(summary.presented) stale=\(summary.stale) secondsGapOver25ms=\(summary.secondsOver25Milliseconds) secondsGapOver40ms=\(summary.secondsOver40Milliseconds) worstGapMs=\(Int(summary.worstGap * 1000))"
        )
    }

    private func prepareImmediateLayerConfiguration(for queuedFrame: QueuedMetalFrame) -> Bool {
        lock.lock()
        guard acceptsLocked(queuedFrame) else {
            lock.unlock()
            return false
        }
        let layerConfiguration = LayerConfiguration(
            color: queuedFrame.frame.color,
            displaySyncEnabled: state.configuration.displaySyncEnabled
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
            displaySyncEnabled: state.configuration.displaySyncEnabled
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
            displaySyncEnabled: configuration.displaySyncEnabled
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
        layer.displaySyncEnabled = layerConfiguration.displaySyncEnabled
            && !presentModeForcesUnsynced(lock.withLock { state.configuration })
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
            // No color matching: the shader already wrote display-native values. A tagged color
            // space makes WindowServer convert, and so composite, every frame, which costs about
            // two refreshes of latency and rules out direct scanout and variable refresh.
            layer.colorspace = nil
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

    /// Places the quad inside `content`, a normalized top-left-origin rect of the drawable.
    private static func vertices(for quad: VideoQuad, in content: CGRect) -> [MetalVideoVertex] {
        let cx = Float(content.midX * 2 - 1)
        let cy = Float(1 - content.midY * 2)
        let sx = Float(quad.clipScale.x * content.width)
        let sy = Float(quad.clipScale.y * content.height)
        let minX = Float(quad.textureRect.minX)
        let maxX = Float(quad.textureRect.maxX)
        let minY = Float(quad.textureRect.minY)
        let maxY = Float(quad.textureRect.maxY)
        return [
            MetalVideoVertex(position: SIMD2(cx - sx, cy - sy), textureCoordinate: SIMD2(minX, maxY)),
            MetalVideoVertex(position: SIMD2(cx + sx, cy - sy), textureCoordinate: SIMD2(maxX, maxY)),
            MetalVideoVertex(position: SIMD2(cx - sx, cy + sy), textureCoordinate: SIMD2(minX, minY)),
            MetalVideoVertex(position: SIMD2(cx + sx, cy + sy), textureCoordinate: SIMD2(maxX, minY)),
        ]
    }

    private static func uniforms(for metadata: VideoColorMetadata, wideGamutDisplay: Bool) -> MetalFragmentUniforms {
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
            ),
            output: SIMD4(transfer == 0 && wideGamutDisplay ? 1 : 0, 0, 0, 0)
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
        float4 output;
    };

    // Rec. 709 to Display P3 for gamma-encoded SDR: decode the sRGB curve, convert the
    // linear primaries, and re-encode with the same curve Display P3 uses.
    float3 srgbToLinear(float3 value) {
        return select(pow((value + 0.055) / 1.055, 2.4), value / 12.92, value <= 0.04045);
    }

    float3 linearToSrgb(float3 value) {
        return select(1.055 * pow(value, 1.0 / 2.4) - 0.055, value * 12.92, value <= 0.0031308);
    }

    float3 rec709ToDisplayP3(float3 value) {
        const float3x3 primaries = float3x3(
            float3(0.8225, 0.0332, 0.0171),
            float3(0.1774, 0.9669, 0.0724),
            float3(0.0000, 0.0000, 0.9108));
        return linearToSrgb(saturate(primaries * srgbToLinear(saturate(value))));
    }

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
        if (uniforms.output.x == 1.0) rgb = rec709ToDisplayP3(rgb);
        return float4(rgb, 1.0);
    }

    fragment float4 rgbFragment(
        VertexOut in [[stage_in]],
        texture2d<float> colorTexture [[texture(0)]],
        constant FragmentUniforms &uniforms [[buffer(0)]]) {
        constexpr sampler sampleFilter(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 color = colorTexture.sample(sampleFilter, in.textureCoordinate);
        if (uniforms.output.x == 1.0) color.rgb = rec709ToDisplayP3(color.rgb);
        return color;
    }
    """
}

private let renderDiagnosticsLog = Logger(subsystem: "app.umbra.Umbra", category: "render-diagnostics")

/// One minute of one-second presentation windows, reduced to the stutter evidence worth keeping.
private struct PresentationSummary {
    var windowStart: CFTimeInterval = CACurrentMediaTime()
    var arrived = 0
    var presented = 0
    var stale = 0
    var secondsOver25Milliseconds = 0
    var secondsOver40Milliseconds = 0
    var worstGap: CFTimeInterval = 0

    mutating func add(arrived: Int, window: PresentationDiagnostics) {
        self.arrived += arrived
        presented += window.presentedFrames
        stale += window.staleFrames
        if window.maximumGap >= 0.025 { secondsOver25Milliseconds += 1 }
        if window.maximumGap >= 0.040 { secondsOver40Milliseconds += 1 }
        worstGap = max(worstGap, window.maximumGap)
    }
}

/// Rolling one-second presentation counters used to diagnose stream stutter.
enum UmbraPresentMode: String {
    case vrr
    case immediate
    case scanline
    case vrrmin
    case attime
    case genlock
    case vrrpaced
}

private struct PresentationDiagnostics {
    var windowStart: CFTimeInterval = CACurrentMediaTime()
    var lastCallback: CFTimeInterval?
    var callbacks = 0
    var presentedFrames = 0
    var emptyCallbacks = 0
    var staleFrames = 0
    var layerReconfigurations = 0
    var maximumGap: CFTimeInterval = 0
    var maximumEncode: CFTimeInterval = 0
    var maximumDrawableWait: CFTimeInterval = 0
    var slowDrawableWaits = 0
    var missingDrawables = 0
    /// Commit-to-glass time of shown drawables, from each drawable's presentedTime.
    var glassLatencySamples: [CFTimeInterval] = []
    var gpuDoneSamples: [CFTimeInterval] = []
    var gpuTimeSamples: [CFTimeInterval] = []
    var flipErrorSamples: [CFTimeInterval] = []
    /// Where shown flips landed in the scan, as sixteenths of the refresh period after scanout start.
    var flipPhaseBins = [Int](repeating: 0, count: 16)
    var receivePhaseBins = [Int](repeating: 0, count: 16)
    var decodedPhaseBins = [Int](repeating: 0, count: 16)
    var commitPhaseBins = [Int](repeating: 0, count: 16)
    var decodeSamples: [CFTimeInterval] = []
    var receiveToCommitSamples: [CFTimeInterval] = []
    var genlockSlackSamples: [CFTimeInterval] = []
    var arrivalToGlassSamples: [CFTimeInterval] = []
    var genlockHolds = 0
    var genlockLate = 0
    var genlockReports = 0
    var genlockLastCorrection: CFTimeInterval = 0
    var glassLatencySum: CFTimeInterval = 0
    var glassLatencyCount = 0
    var maximumGlassLatency: CFTimeInterval = 0
    var unshownPresents = 0

    mutating func recordCallback(at now: CFTimeInterval) {
        callbacks += 1
        if let lastCallback { maximumGap = max(maximumGap, now - lastCallback) }
        lastCallback = now
    }
}
