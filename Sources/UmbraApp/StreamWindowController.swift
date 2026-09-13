import AppKit
import AVFoundation
import CoreMedia
import Metal
import QuartzCore
import UmbraCore
import UmbraIntegration
import UmbraLSP
import UmbraLSPTransport
import UmbraMedia
import UmbraPlatform
import UmbraServices

enum StreamPerformanceMetric: CaseIterable, Sendable {
    case videoRate
    case decodeTime
    case hostProcessingLatency
    case inputToDecodeProxyLatency
    case receiveToSubmitLatency
    case reassemblyToSubmitLatency
    case videoToolboxLatency
    case receiveToDecodeLatency
    case decodeToMetalCommitLatency
    case presentationProxyLatency
    case droppedFrames
    case renderQueue
    case networkRTT
    case videoQueue
    case audioQueue
    case videoPackets
    case audioPackets
    case lspLifecycle
    case lspDatagrams
    case lspDrops
    case lspAuthenticationFailures
    case lspPathMTU
    case lspReconnect
    case lspInputDevices
    case lspFrameToDecoder
    case lspDecodeCompletion
    case lspMetalCommit
    case lspAudioDecode
    case lspReconnectDuration
    case lspNativeStages
    case lspMetalCompletion
    case lspAudioHealth
    case lspFrameToMetal
    case lspAudioReceive

    var title: String {
        switch self {
        case .videoRate: "Frame rate"
        case .decodeTime: "Decode"
        case .hostProcessingLatency: "Host processing"
        case .inputToDecodeProxyLatency: "Input to decode proxy"
        case .receiveToSubmitLatency: "Receive to decoder"
        case .reassemblyToSubmitLatency: "Reassembly to decoder"
        case .videoToolboxLatency: "VideoToolbox decode"
        case .receiveToDecodeLatency: "Receive to decode"
        case .decodeToMetalCommitLatency: "Decode to Metal"
        case .presentationProxyLatency: "Presentation proxy"
        case .droppedFrames: "Dropped frames"
        case .renderQueue: "Render queue"
        case .networkRTT: "Network RTT"
        case .videoQueue: "Video queue"
        case .audioQueue: "Audio queue"
        case .videoPackets: "Video packets"
        case .audioPackets: "Audio packets"
        case .lspLifecycle: "LSP lifecycle"
        case .lspDatagrams: "LSP datagrams"
        case .lspDrops: "LSP drops"
        case .lspAuthenticationFailures: "LSP auth failures"
        case .lspPathMTU: "LSP UDP payload"
        case .lspReconnect: "LSP reconnect"
        case .lspInputDevices: "LSP input devices"
        case .lspFrameToDecoder: "LSP frame to decoder"
        case .lspDecodeCompletion: "LSP decode completion"
        case .lspMetalCommit: "LSP Metal commit"
        case .lspAudioDecode: "LSP audio decode"
        case .lspReconnectDuration: "LSP reconnect duration"
        case .lspNativeStages: "LSP native stages"
        case .lspMetalCompletion: "LSP Metal completion"
        case .lspAudioHealth: "LSP audio health"
        case .lspFrameToMetal: "LSP frame to Metal enqueue"
        case .lspAudioReceive: "LSP audio receive to decode"
        }
    }
}

struct StreamStatisticsPresentation: Equatable, Sendable {
    let values: [StreamPerformanceMetric: String]
    var compactText: String? = nil

    subscript(_ metric: StreamPerformanceMetric) -> String {
        values[metric] ?? "Unavailable"
    }

    var accessibilityValue: String {
        overlayText
    }

    /// Only shows measurements relevant to this transport, not an internal telemetry dump.
    var overlayText: String {
        if let compactText { return compactText }
        let metrics: [StreamPerformanceMetric] = [
            .videoRate, .networkRTT, .decodeTime, .hostProcessingLatency,
            .receiveToDecodeLatency, .droppedFrames, .renderQueue,
        ]
        return metrics.map { metric in
            Self.line(metric.title, self[metric])
        }.joined(separator: "\n")
    }

    static func line(_ label: String, _ value: String) -> String {
        let display = value == "Unavailable" ? "—" : value
        return label.padding(toLength: 20, withPad: " ", startingAt: 0) + " " + display
    }
}

enum StreamStatisticsPresenter {
    static func make(
        renderer: MediaPipelineStatistics?,
        decoder: MediaPipelineStatistics?,
        transport: StreamTransportStatistics?,
        lsp: LSPTelemetrySnapshot? = nil,
        reconnect: LSPReconnectSnapshot? = nil,
        devices: [LSPDeviceRateTelemetry] = [],
        product: LSPProductTelemetrySnapshot? = nil,
        nativeTiming: LSPNativeTimingSnapshot? = nil
    ) -> StreamStatisticsPresentation {
        let videoRate: String
        if let renderer, renderer.presentedFrames > 0 {
            videoRate = String(format: "%.1f FPS", renderer.presentationFramesPerSecond)
        } else if let decoder, decoder.decodedFrames > 0 {
            videoRate = String(format: "%.1f FPS", decoder.decodeFramesPerSecond)
        } else {
            videoRate = "Unavailable"
        }

        let droppedFrames = [renderer?.droppedFrames, decoder?.droppedFrames]
            .compactMap { $0 }
            .reduce(0, +)
        let rtt: String
        if let milliseconds = transport?.estimatedRTTMilliseconds {
            if let variance = transport?.estimatedRTTVarianceMilliseconds {
                rtt = "\(milliseconds) ± \(variance) ms"
            } else {
                rtt = "\(milliseconds) ms"
            }
        } else {
            rtt = "Unavailable"
        }

        var presentation = StreamStatisticsPresentation(values: [
            .videoRate: videoRate,
            .decodeTime: decoder?.averageDecodeLatencyMilliseconds.map {
                String(format: "%.1f ms", $0)
            } ?? "Unavailable",
            .hostProcessingLatency: percentiles(
                decoder?.latencyStatistics?.hostProcessing
            ),
            .inputToDecodeProxyLatency: "Unavailable",
            .receiveToSubmitLatency: percentiles(
                decoder?.latencyStatistics?.receiveToVideoToolboxSubmit
            ),
            .reassemblyToSubmitLatency: percentiles(
                decoder?.latencyStatistics?.reassemblyEnqueueToVideoToolboxSubmit
            ),
            .videoToolboxLatency: percentiles(
                decoder?.latencyStatistics?.videoToolboxDecode
            ),
            .receiveToDecodeLatency: percentiles(
                decoder?.latencyStatistics?.receiveToDecode
            ),
            .decodeToMetalCommitLatency: percentiles(
                renderer?.latencyStatistics?.decodeToMetalCommit
            ),
            .presentationProxyLatency: presentationProxy(
                renderer?.latencyStatistics
            ),
            .droppedFrames: renderer == nil && decoder == nil ? "Unavailable" : String(droppedFrames),
            .renderQueue: renderer.map { frameCount($0.queueDepth) } ?? "Unavailable",
            .networkRTT: rtt,
            .videoQueue: transport.map { frameCount(Int($0.pendingVideoFrames)) }
                ?? "Unavailable",
            .audioQueue: transport.map { $0.pendingAudioDurationMilliseconds >= 0
                ? "\($0.pendingAudioDurationMilliseconds) ms"
                : "Unavailable"
            } ?? "Unavailable",
            .videoPackets: transport.map { String($0.videoPackets) }
                ?? "Unavailable",
            .audioPackets: transport.map { String($0.audioPackets) }
                ?? "Unavailable",
            .lspLifecycle: lsp.map { String(describing: $0.lifecycle) } ?? "Unavailable",
            .lspDatagrams: lsp.map { "RX \($0.receivedDatagrams) / TX \($0.transmittedDatagrams)" }
                ?? "Unavailable",
            .lspDrops: lsp.map { String($0.droppedDatagrams) } ?? "Unavailable",
            .lspAuthenticationFailures: lsp.map { String($0.authenticationFailures) } ?? "Unavailable",
            .lspPathMTU: lsp.map {
                "TX \($0.currentUDPPayloadSize) / RX \($0.currentReceiveUDPPayloadSize) bytes"
            } ?? "Unavailable",
            .lspReconnect: reconnect.map { String(describing: $0.phase) } ?? "Unavailable",
            .lspInputDevices: devices.isEmpty ? "Unavailable" : devices.map {
                "\($0.deviceType) \($0.deviceID).\($0.instanceGeneration): " +
                    "capture \($0.observedCaptureRate) Hz, state \($0.selectedStateRate) Hz" +
                    ($0.selectedSensorRate == 0 ? "" : ", sensor \($0.selectedSensorRate) Hz") +
                    ", drops \($0.droppedSamples), wire \($0.effectiveWireBitsPerSecond) bps" +
                    ($0.stateSpacing.map { ", spacing p99 \($0.p99Microseconds)µs" } ?? "")
            }.joined(separator: " | "),
            .lspFrameToDecoder: distribution(product?.completeFrameReceiveToVideoToolboxSubmit),
            .lspDecodeCompletion: distribution(product?.videoToolboxSubmitToDecodeCompletion),
            .lspMetalCommit: distribution(product?.metalEnqueueToCommit),
            .lspAudioDecode: distribution(product?.audioDecodeAndRenderEnqueue),
            .lspReconnectDuration: distribution(product?.reconnectDuration),
            .lspNativeStages: nativeTiming.map { snapshot in
                zip(LSPNativeTimingStage.allCases, snapshot.stages).compactMap { stage, value in
                    guard value.flags.contains(.available), value.count > 0 else { return nil }
                    let domain = value.flags.contains(.clientMonotonic)
                        ? (value.flags.contains(.kernelTimestamped)
                            ? "client-monotonic/kernel-timestamped" : "client-monotonic")
                        : "unknown"
                    return "\(stage): n=\(value.count) p99=\(value.p99Microseconds)µs " +
                        "max=\(value.maximumMicroseconds)µs drops=\(value.drops) [\(domain)]"
                }.joined(separator: " | ")
            }.flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable",
            .lspMetalCompletion: distribution(product?.metalCommitToCompletion),
            .lspAudioHealth: {
                guard let product,
                      product.audioUnderruns != nil || product.audioRebuffers != nil else {
                    return "Unavailable"
                }
                return "underruns=\(product.audioUnderruns.map(String.init) ?? "Unavailable") " +
                    "rebuffers=\(product.audioRebuffers.map(String.init) ?? "Unavailable")"
            }(),
            .lspFrameToMetal: distribution(product?.completeFrameReceiveToMetalEnqueue),
            .lspAudioReceive: distribution(product?.audioReceiveToDecode),
        ])
        if lsp != nil || product != nil {
            var rows: [(String, String)] = [
                ("Frame rate", videoRate),
                ("Host encode", compactDistribution(product?.hostEncoderDuration)),
                ("Client decode", compactDistribution(product?.videoToolboxSubmitToDecodeCompletion)),
                ("Render queue", compactDistribution(product?.metalEnqueueToCommit)),
                ("Frame drops", presentation[.droppedFrames]),
                ("Packets", presentation[.lspDatagrams]),
                ("Packet drops", presentation[.lspDrops]),
            ]
            if product?.audioReceiveToDecode != nil {
                rows.insert(("Audio buffer", compactDistribution(product?.audioReceiveToDecode)), at: 4)
            }
            if let failures = lsp?.authenticationFailures, failures > 0 {
                rows.append(("Auth failures", String(failures)))
            }
            presentation.compactText = rows.map { StreamStatisticsPresentation.line($0.0, $0.1) }
                .joined(separator: "\n")
        }
        return presentation
    }

    /// Keeps the on-video readout short; the full distribution remains in telemetry.
    private static func compactDistribution(_ value: LSPDistributionSnapshot?) -> String {
        guard let value, value.count > 0 else { return "Unavailable" }
        return String(format: "%.2f ms (p99 %.2f)",
                      Double(value.p50Microseconds) / 1_000,
                      Double(value.p99Microseconds) / 1_000)
    }

    private static func frameCount(_ count: Int) -> String {
        guard count >= 0 else { return "Unavailable" }
        return "\(count) \(count == 1 ? "frame" : "frames")"
    }

    private static func distribution(_ value: LSPDistributionSnapshot?) -> String {
        guard let value else { return "Unavailable" }
        return "n=\(value.count) p50=\(value.p50Microseconds)µs " +
            "p95=\(value.p95Microseconds)µs p99=\(value.p99Microseconds)µs " +
            "max=\(value.maximumMicroseconds)µs drops=\(value.drops) [\(value.clockDomain)]"
    }

    private static func percentiles(_ summary: LatencyPercentileSummary?) -> String {
        guard let summary else { return "Unavailable" }
        return String(
            format: "%.1f / %.1f / %.1f ms (n=%d)",
            summary.p50Milliseconds,
            summary.p95Milliseconds,
            summary.p99Milliseconds,
            summary.sampleCount
        )
    }

    private static func presentationProxy(_ statistics: VideoLatencyStatistics?) -> String {
        guard let statistics else { return "Unavailable" }
        guard let summary = statistics.metalCommitToPresentationProxy,
              let evidence = statistics.presentationProxyEvidence else {
            let missedCount = statistics.missedPresentationDeadlines
            let unavailableCount = statistics.unavailablePresentationProxySamples
            guard missedCount > 0 || unavailableCount > 0 else { return "Unavailable" }
            let missed = missedCount > 0
                ? "\(missedCount) missed presentation \(missedCount == 1 ? "target" : "targets")"
                : nil
            let unavailable = unavailableCount > 0
                ? "\(unavailableCount) unavailable \(unavailableCount == 1 ? "sample" : "samples")"
                : nil
            return "No valid proxy samples, " + [missed, unavailable].compactMap { $0 }.joined(separator: ", ")
        }
        let label = switch evidence {
        case .displayLinkPresentationTarget: "display target"
        case .scheduledPresentationTime: "scheduled target"
        case .commandBufferCompletion: "GPU completion, not scanout"
        case .mixed: "mixed proxies"
        }
        let missedCount = statistics.missedPresentationDeadlines
        let unavailableCount = statistics.unavailablePresentationProxySamples
        var qualifiers: [String] = []
        if missedCount > 0 {
            qualifiers.append("\(missedCount) missed presentation \(missedCount == 1 ? "target" : "targets")")
        }
        if unavailableCount > 0 {
            qualifiers.append("\(unavailableCount) unavailable \(unavailableCount == 1 ? "sample" : "samples")")
        }
        let suffix = qualifiers.isEmpty ? "" : " (\(qualifiers.joined(separator: ", ")))"
        return "\(label)\(suffix): \(percentiles(summary))"
    }
}

@MainActor
struct StreamRendererConfiguration: Equatable {
    let display: MetalDisplayConfiguration
    let pacing: FramePacingConfiguration

    static func resolve(
        policy: EffectiveStreamingPolicy,
        framesPerSecond: Double,
        displayRefreshRate: Double,
        usesMetalRenderer: Bool = true
    ) -> Self {
        let usesDisplayLink = usesMetalRenderer
            && policy.presentationIntent == .displayLinkedTearFree
            && policy.vsyncEnabled
        return Self(
            display: MetalDisplayConfiguration(
                contentMode: StreamVideoPresentationPolicy.contentMode,
                verticalSyncEnabled: usesDisplayLink
            ),
            pacing: FramePacingConfiguration(
                nominalFramesPerSecond: framesPerSecond,
                framePacingEnabled: usesDisplayLink
                    && policy.frameSchedulingIntent == .adaptiveDisplayDeadline,
                verticalSyncEnabled: usesDisplayLink,
                displayRefreshRate: displayRefreshRate
            )
        )
    }
}

@MainActor
final class StreamWindowController: NSObject, PlatformInputSinkInstalling, NSWindowDelegate {
    let controllers = AppleGameControllerService()
    let renderer: MetalVideoRenderer?
    let videoRenderer: NativeVideoRendererRouter
    let windowModeCoordinator: WindowModeCoordinator

    var onStopRequested: ((Bool) async -> Void)?
    var onStatisticsToggle: (() -> Void)?
    var onControllerMouseModeChanged: ((Bool) -> Void)?
    var onTextCommit: ((String) -> Void)?
    var isStreamWindowVisible: Bool { window.isVisible }
    /// Exact stream window used for coarse native input-capture focus ownership.
    var inputCaptureWindow: NSWindow { window }
    var nativeLSPControllerOwnershipForTesting: Bool { nativeLSPControllerOwnership }

    private let window: NSWindow
    private let streamContainerView: StreamContainerView
    private let contentView: StreamMetalView
    private let diagnosticHandler: @Sendable (String) -> Void
    private let startupTelemetry: SessionStartupTelemetryRecorder
    private let keyboard = AppKitKeyboardInputAdapter()
    private let pointer: AppKitPointerInputAdapter
    private let pointerCapture = PointerCaptureCoordinator()
    private let keepAwake = KeepAwakeActivity()
    private let clipboard = AppKitClipboardTextReader()
    private lazy var systemShortcutCapture = SystemShortcutCaptureCoordinator(
        state: SystemShortcutCaptureState(
            permissions: SystemShortcutCapturePermissionReader.snapshot()
        ),
        driver: CGEventTapSystemShortcutCaptureDriver { [weak self] event in
            self?.keyboard.handle(event) ?? false
        }
    )
    private var isSessionActive = false
    private var isStopRequested = false
    private var quitHostApplication = false
    private var hiddenApplicationWindows: [NSWindow] = []
    private var statisticsTimer: Timer?
    private var showsStatistics = false
    private var streamStatistics: StreamTransportStatistics?
    private var videoPipelineStatistics: MediaPipelineStatistics?
    private var lspTelemetry: LSPTelemetrySnapshot?
    private var lspReconnectTelemetry: LSPReconnectSnapshot?
    private var lspDeviceRateTelemetry: [LSPDeviceRateTelemetry] = []
    private var lspProductTelemetry: LSPProductTelemetrySnapshot?
    private var lspNativeTimingTelemetry: LSPNativeTimingSnapshot?
    private var nativeLSPControllerOwnership = false
    private var activePreferences: StreamingPreferences?
    private var activeEffectivePolicy: EffectiveStreamingPolicy?
    private var activeSystemShortcutCaptureMode: SystemShortcutCaptureMode = .off
    private var fullscreenTeardown = StreamWindowTeardownStateMachine()
    private var presentationFinishTask: Task<Void, Never>?
    private var stopRequestTask: Task<Void, Never>?
    private var streamWindowRequiresReopen = false
    private var activeRendererGeneration: UInt64?
    private var presentationRevealed = false
    private var activeSessionID: UUID?
    private var installedInputSink: (any PlatformInputPacketSink)?
    private weak var returnApplicationWindow: NSWindow?
    nonisolated(unsafe) private var screenObservers: [NSObjectProtocol] = []

    init(
        device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
        windowModeDriverFactory: @MainActor (NSWindow) -> any WindowModeDriving = {
            AppKitWindowModeDriver(window: $0)
        },
        startupTelemetry: SessionStartupTelemetryRecorder = SessionStartupTelemetryRecorder(),
        diagnosticHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        let frame = NSRect(x: 0, y: 0, width: 1_280, height: 720)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Umbra Stream"
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true

        let contentView = StreamMetalView(frame: frame)
        let streamContainerView = StreamContainerView(frame: frame, streamView: contentView)
        let pointer = AppKitPointerInputAdapter(
            geometry: VideoGeometry(
                contentSize: frame.size,
                videoSize: frame.size,
                scalingMode: StreamVideoPresentationPolicy.pointerScalingMode
            )
        )
        let metalLayer = CAMetalLayer()
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.drawableSize = frame.size.scaled(by: metalLayer.contentsScale)
        contentView.wantsLayer = true
        contentView.layer = metalLayer
        let sampleBufferLayer = AVSampleBufferDisplayLayer()
        sampleBufferLayer.videoGravity = StreamVideoPresentationPolicy.sampleBufferGravity
        sampleBufferLayer.isHidden = true
        metalLayer.addSublayer(sampleBufferLayer)
        contentView.sampleBufferLayer = sampleBufferLayer
        window.contentView = streamContainerView

        if let device {
            renderer = try MetalVideoRenderer(
                layer: metalLayer,
                device: device,
                configuration: MetalDisplayConfiguration(verticalSyncEnabled: false),
                pacingConfiguration: FramePacingConfiguration(
                    nominalFramesPerSecond: 60,
                    framePacingEnabled: false,
                    verticalSyncEnabled: false
                ),
                presentationActive: false
            )
        } else {
            renderer = nil
        }
        videoRenderer = NativeVideoRendererRouter(
            metal: renderer,
            sampleBuffer: SampleBufferVideoRenderer(
                layer: sampleBufferLayer,
                failureHandler: { failure in
                    diagnosticHandler(
                        "System video renderer detected \(failure.description); resetting it."
                    )
                }
            )
        )
        self.window = window
        self.streamContainerView = streamContainerView
        self.contentView = contentView
        self.pointer = pointer
        self.diagnosticHandler = diagnosticHandler
        self.startupTelemetry = startupTelemetry
        windowModeCoordinator = WindowModeCoordinator(driver: windowModeDriverFactory(window))
        super.init()

        videoRenderer.setVideoSizeHandler { [weak contentView] size in
            contentView?.videoSize = size
        }
        window.delegate = self
        contentView.keyboard = keyboard
        contentView.pointer = pointer
        contentView.onRequestTextInput = { [weak self] in self?.requestTextInput() }
        contentView.onLayout = { [weak self] size, scale in
            guard let self else { return }
            let drawableSize = size.scaled(by: scale)
            if let renderer = self.renderer {
                renderer.updateLayerGeometry(size: drawableSize, contentsScale: scale)
            } else {
                self.contentView.metalLayer.contentsScale = scale
                self.contentView.metalLayer.drawableSize = drawableSize
            }
            self.pointer.geometry.contentSize = size
            self.updatePointerCaptureRegion()
        }
        keyboard.onShortcut = { [weak self] action in self?.handle(action) }
        pointer.onCaptureRequested = { [weak self] active in self?.setPointerCapture(active) }
        onStatisticsToggle = { [weak self] in self?.toggleStatistics() }
        windowModeCoordinator.onPresentationChanged = { [weak self] presentation in
            self?.recordPresentationRequest(presentation)
            self?.applyInputPresentation(presentation)
        }
        pointerCapture.onStateChanged = { [weak self] state in
            self?.pointer.isCaptureActive = state.isCaptured
        }
        controllers.navigationHandler = { [weak self] event in
            guard let self, !self.isSessionActive else { return }
            self.handleControllerNavigation(event)
        }
        controllers.localActionHandler = { [weak self] action in
            self?.handleControllerLocalAction(action)
        }
        controllers.start()
        let center = NotificationCenter.default
        screenObservers = [
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScreenEnvironmentChange() }
            },
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScreenEnvironmentChange() }
            },
            center.addObserver(
                forName: NSWindow.didChangeBackingPropertiesNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScreenEnvironmentChange() }
            },
        ]
    }

    deinit {
        for observer in screenObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func resolveStreamingPreferences(
        _ preferences: StreamingPreferences,
        uiScreen: NSScreen? = nil
    ) -> StreamingPreferences {
        guard preferences.displayResolutionPolicy != .configured,
              let screen = resolvedScreen(for: preferences, currentScreen: nil, uiScreen: uiScreen),
              let displayID = AppKitDisplaySelection.displayID(for: screen)
        else {
            return preferences
        }

        let fallbackPhysicalSize = DisplayGeometry.nativePixelSize(
            fullPixelSize: CGSize(
                width: CGDisplayPixelsWide(displayID),
                height: CGDisplayPixelsHigh(displayID)
            ),
            pointSize: screen.frame.size,
            safeAreaInsets: DisplayEdgeInsets(screen.safeAreaInsets),
            excludingDisplayCutouts: preferences.displayResolutionPolicy == .nativeExcludingNotch
        )
        let physicalSize = StreamDisplayGeometryPolicy.resolvedPixelSize(
            policy: preferences.displayResolutionPolicy,
            nativeGeometry: DisplayGeometry.nativeGeometry(for: displayID),
            fallback: fallbackPhysicalSize
        )
        let scale = max(screen.backingScaleFactor, 1)
        let logicalSize = CGSize(
            width: physicalSize.width / scale,
            height: physicalSize.height / scale
        )

        var resolved = preferences
        resolved.width = Self.evenPixelDimension(logicalSize.width)
        resolved.height = Self.evenPixelDimension(logicalSize.height)
        if resolved.autoAdjustBitrate {
            resolved.bitrateKbps = StreamingPreferences.defaultBitrateKbps(
                width: resolved.width,
                height: resolved.height,
                fps: resolved.exactFrameRate,
                yuv444: resolved.enableYUV444
            )
        }
        return resolved
    }

    static func evenPixelDimension(_ value: CGFloat) -> Int {
        let clamped = max(256, Int(value.rounded()))
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }

    func installInputSink(_ sink: (any PlatformInputPacketSink)?) {
        let previousSink = installedInputSink
        if sink == nil {
            keyboard.releaseAllKeys()
            contentView.resetVirtualTrackpad()
        }
        installedInputSink = sink
        keyboard.sink = sink
        pointer.sink = sink
        controllers.sink = sink
        contentView.inputSink = sink
        withExtendedLifetime(previousSink) {}
    }

    @discardableResult
    func handleKeyboardEventForTesting(_ event: NSEvent) -> Bool {
        keyboard.handle(event)
    }

    func prepare(for bootstrap: StreamBootstrap) async throws {
        if let stopRequestTask {
            await stopRequestTask.value
            self.stopRequestTask = nil
        }
        presentationFinishTask = nil
        windowModeCoordinator.setWindowActivationSuppressed(true)
        fullscreenTeardown = StreamWindowTeardownStateMachine()
        isSessionActive = true
        isStopRequested = false
        quitHostApplication = false
        presentationRevealed = false
        activeSessionID = bootstrap.sessionID
        activePreferences = bootstrap.preferences
        activeEffectivePolicy = bootstrap.effectivePolicy
        window.title = bootstrap.application.name
        let targetScreen = resolvedScreen(
            for: bootstrap.preferences,
            currentScreen: nil,
            uiScreen: NSApp.keyWindow?.screen
        )

        contentView.videoSize = CGSize(
            width: bootstrap.preferences.width,
            height: bootstrap.preferences.height
        )
        contentView.directTouchMode = bootstrap.preferences.absoluteTouchMode
        let pointerMode = StreamPresentationInputPolicy.pointerMode(
            absoluteMouseMode: bootstrap.preferences.absoluteMouseMode
        )
        pointer.preferences = PointerPreferences(
            mode: pointerMode,
            swapPrimaryAndSecondaryButtons: bootstrap.preferences.swapMouseButtons,
            reverseScrollDirection: bootstrap.preferences.reverseScrollDirection
        )
        pointerCapture.handle(.pointerModeChanged(pointerMode))
        activeSystemShortcutCaptureMode = StreamPresentationInputPolicy.shortcutCaptureMode(
            for: bootstrap.preferences.captureSystemKeysMode
        )
        controllers.multiControllerEnabled = bootstrap.preferences.multiController
        controllers.swapFaceButtons = bootstrap.preferences.swapFaceButtons
        controllers.gamepadMouseEnabled = bootstrap.preferences.gamepadMouse
        controllers.allowsBackgroundInput = bootstrap.preferences.backgroundGamepad
        setStatisticsVisible(bootstrap.preferences.showPerformanceOverlay)

        let rendererMode: NativeVideoRendererRouter.Mode =
            bootstrap.preferences.rendererPreference == .avSampleBufferDisplayLayer
                ? .sampleBuffer
                : .metal
        let rendererGeneration = videoRenderer.prepareSession(mode: rendererMode)
        activeRendererGeneration = rendererGeneration
        videoRenderer.setSessionPresentationProxyHandler { [startupTelemetry, weak self] generation, frameNumber in
            startupTelemetry.record(
                sessionID: bootstrap.sessionID,
                stage: .presentationCommit
            )
            Task { @MainActor [weak self] in
                self?.revealPreparedPresentation(
                    rendererGeneration: generation,
                    frameNumber: frameNumber
                )
            }
        }
        updateDisplayConfiguration(
            for: targetScreen,
            preferences: bootstrap.preferences,
            policy: bootstrap.effectivePolicy
        )
        await renderer?.awaitPresentationQuiescence()
        await videoRenderer.awaitPreparedBackendReset()
        guard videoRenderer.activatePreparedSession(generation: rendererGeneration) else {
            throw UmbraIntegrationError.mediaConfigurationFailed(
                "Renderer session activation was superseded during preparation."
            )
        }

        keepAwake.setActive(
            bootstrap.preferences.keepAwake,
            reason: "Umbra is streaming \(bootstrap.application.name)"
        )
        controllers.start()
        positionWindow(on: targetScreen, videoSize: contentView.videoSize)
        diagnosticHandler(
            "Prepared hidden stream surface for session \(bootstrap.sessionID.uuidString); awaiting the first renderer commit proxy."
        )
    }

    /// Prepares the existing Metal window/router for native LSP without manufacturing legacy state.
    func prepareLSPVideo(applicationName: String, preferences: StreamingPreferences) async throws {
        if let stopRequestTask { await stopRequestTask.value; self.stopRequestTask = nil }
        presentationFinishTask = nil
        windowModeCoordinator.setWindowActivationSuppressed(true)
        fullscreenTeardown = StreamWindowTeardownStateMachine()
        isSessionActive = true
        isStopRequested = false
        quitHostApplication = false
        presentationRevealed = false
        activeSessionID = UUID()
        activePreferences = preferences
        activeEffectivePolicy = .resolve(for: preferences)
        window.title = applicationName
        contentView.videoSize = CGSize(width: preferences.width, height: preferences.height)
        contentView.directTouchMode = preferences.absoluteTouchMode
        let targetScreen = resolvedScreen(for: preferences, currentScreen: nil, uiScreen: NSApp.keyWindow?.screen)
        let generation = videoRenderer.prepareSession(mode: .metal)
        activeRendererGeneration = generation
        videoRenderer.setSessionPresentationProxyHandler { [weak self] generation, frameNumber in
            Task { @MainActor [weak self] in
                self?.revealPreparedPresentation(rendererGeneration: generation, frameNumber: frameNumber)
            }
        }
        updateDisplayConfiguration(for: targetScreen, preferences: preferences, policy: .resolve(for: preferences))
        await renderer?.awaitPresentationQuiescence()
        await videoRenderer.awaitPreparedBackendReset()
        guard videoRenderer.activatePreparedSession(generation: generation) else {
            throw UmbraIntegrationError.mediaConfigurationFailed("LSP renderer activation was superseded.")
        }
        keepAwake.setActive(preferences.keepAwake, reason: "Umbra is streaming \(applicationName)")
        controllers.stop()
        nativeLSPControllerOwnership = true
        positionWindow(on: targetScreen, videoSize: contentView.videoSize)
    }

    func updatePreparedSession(for bootstrap: StreamBootstrap) {
        guard isSessionActive, activeSessionID == bootstrap.sessionID else { return }
        activePreferences = bootstrap.preferences
        activeEffectivePolicy = bootstrap.effectivePolicy
        contentView.directTouchMode = bootstrap.preferences.absoluteTouchMode
        let pointerMode = StreamPresentationInputPolicy.pointerMode(
            absoluteMouseMode: bootstrap.preferences.absoluteMouseMode
        )
        pointer.preferences.mode = pointerMode
        pointerCapture.handle(.pointerModeChanged(pointerMode))
        let targetScreen = resolvedScreen(
            for: bootstrap.preferences,
            currentScreen: window.screen,
            uiScreen: NSApp.keyWindow?.screen
        )
        updateDisplayConfiguration(
            for: targetScreen,
            preferences: bootstrap.preferences,
            policy: bootstrap.effectivePolicy
        )
    }

    private func revealPreparedPresentation(
        rendererGeneration: UInt64,
        frameNumber: Int
    ) {
        guard isSessionActive,
              !isStopRequested,
              !presentationRevealed,
              activeRendererGeneration == rendererGeneration else { return }
        presentationRevealed = true
        windowModeCoordinator.setWindowActivationSuppressed(false)
        hiddenApplicationWindows = NSApp.windows.filter { $0 !== window && $0.isVisible }
        returnApplicationWindow = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? hiddenApplicationWindows.first(where: { $0.canBecomeKey })
        for applicationWindow in hiddenApplicationWindows { applicationWindow.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        streamWindowRequiresReopen = false
        NSRunningApplication.current.activate(options: [])
        focusStreamContent()
        guard let preferences = activePreferences else { return }
        let targetScreen = resolvedScreen(
            for: preferences,
            currentScreen: nil,
            uiScreen: window.screen ?? NSScreen.main
        )
        let initialPresentation = Self.presentation(for: preferences.windowMode)
        if initialPresentation == .nativeFullscreen {
            _ = fullscreenTeardown.handle(.requestEnter)
        }
        windowModeCoordinator.request(
            initialPresentation,
            screen: targetScreen,
            borderlessGeometry: borderlessGeometry(
                for: preferences,
                screen: targetScreen
            )
        )
        diagnosticHandler(
            "Revealed stream surface after renderer commit proxy for frame \(frameNumber); requested presentation: \(initialPresentation)."
        )
        systemShortcutCapture.update(windowFocused: true)
        pointerCapture.handle(.focusChanged(true))
        applyInputPresentation(initialPresentation)
        setPointerCapture(!preferences.absoluteMouseMode)
    }

    #if DEBUG
    func handleFirstRendererCommitForTesting(frameNumber: Int = 1) {
        guard let activeRendererGeneration else { return }
        revealPreparedPresentation(
            rendererGeneration: activeRendererGeneration,
            frameNumber: frameNumber
        )
    }
    #endif

    func finish() async {
        if let presentationFinishTask {
            await presentationFinishTask.value
            return
        }
        startPresentationFinish()
        await presentationFinishTask?.value
    }

    /// Reuses an already active stream, or waits for its existing close operation to finish.
    /// A pending first frame is left hidden until normal renderer publication reveals it.
    func focusExistingSession() async -> Bool {
        if let stopRequestTask {
            await stopRequestTask.value
            return false
        }
        if let presentationFinishTask {
            await presentationFinishTask.value
            return false
        }
        guard isSessionActive, !isStopRequested else { return false }
        if presentationRevealed {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: [])
            focusStreamContent()
        }
        return true
    }

    private func performPresentationFinish() async {
        guard isSessionActive else { return }
        controllers.releaseAllInputs()
        isSessionActive = false
        isStopRequested = false
        controllers.gamepadMouseEnabled = false
        activeSystemShortcutCaptureMode = .off
        keyboard.releaseAllKeys()
        contentView.resetVirtualTrackpad()
        statisticsTimer?.invalidate()
        statisticsTimer = nil
        streamStatistics = nil
        videoPipelineStatistics = nil
        lspTelemetry = nil
        lspReconnectTelemetry = nil
        lspDeviceRateTelemetry.removeAll(keepingCapacity: true)
        lspProductTelemetry = nil
        lspNativeTimingTelemetry = nil
        setStatisticsVisible(false)
        setPointerCapture(false)
        pointerCapture.handle(.focusChanged(false))
        systemShortcutCapture.update(windowFocused: false)
        keepAwake.setActive(false)
        windowModeCoordinator.setWindowActivationSuppressed(true)
        dismissStreamSurfaceAndRestoreApplicationWindows(forcePresentationReset: true)
        await renderer?.awaitPresentationQuiescence()
        if nativeLSPControllerOwnership {
            nativeLSPControllerOwnership = false
            controllers.start()
        }
    }

    private func dismissStreamSurfaceAndRestoreApplicationWindows(
        forcePresentationReset: Bool = false
    ) {
        activePreferences = nil
        activeEffectivePolicy = nil
        activeRendererGeneration = nil
        presentationRevealed = false
        activeSessionID = nil
        streamContainerView.usesSafeArea = false
        videoRenderer.deactivateSession()
        renderer?.setPresentationActive(false)
        videoRenderer.flushDeactivatedBackends()
        if !streamWindowRequiresReopen || forcePresentationReset {
            if !streamWindowRequiresReopen {
                diagnosticHandler("Stream surface dismissed immediately.")
            }
            window.orderOut(nil)
            windowModeCoordinator.resetWindowedAfterDismissal()
            streamWindowRequiresReopen = true
            fullscreenTeardown = StreamWindowTeardownStateMachine()
        }
        let returnWindow = returnApplicationWindow
        for applicationWindow in hiddenApplicationWindows where applicationWindow !== returnWindow {
            applicationWindow.orderFront(nil)
        }
        returnWindow?.makeKeyAndOrderFront(nil)
        returnApplicationWindow = nil
        hiddenApplicationWindows.removeAll()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        focusStreamContent()
        pointerCapture.handle(.focusChanged(true))
        systemShortcutCapture.update(
            windowFocused: true,
            permissions: SystemShortcutCapturePermissionReader.snapshot()
        )
    }

    func windowDidResignKey(_ notification: Notification) {
        keyboard.releaseAllKeys()
        pointerCapture.handle(.focusChanged(false))
        systemShortcutCapture.update(windowFocused: false)
    }

    func setApplicationActive(_ active: Bool) {
        controllers.setApplicationActive(active)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        handleScreenEnvironmentChange()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        handleScreenEnvironmentChange()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard acceptsFullscreenCallback(.willEnter) else { return }
        perform(fullscreenTeardown.handle(.willEnter))
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard acceptsFullscreenCallback(.didEnter) else { return }
        if isSessionActive { focusStreamContent() }
        windowModeCoordinator.synchronizePresentation(.nativeFullscreen)
        diagnosticHandler("Stream window entered native fullscreen.")
        updateStreamViewport(for: .nativeFullscreen)
        perform(fullscreenTeardown.handle(.didEnter))
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard acceptsFullscreenCallback(.didFailEnter) else { return }
        windowModeCoordinator.synchronizePresentation(.windowed)
        perform(fullscreenTeardown.handle(.didFailEnter))
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        guard acceptsFullscreenCallback(.willExit) else { return }
        perform(fullscreenTeardown.handle(.willExit))
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard acceptsFullscreenCallback(.didExit) else { return }
        if isSessionActive { focusStreamContent() }
        let targetPresentation = windowModeCoordinator.machine.presentation == .nativeFullscreen
            ? WindowPresentation.windowed
            : windowModeCoordinator.machine.presentation
        windowModeCoordinator.synchronizePresentation(targetPresentation)
        updateStreamViewport(for: targetPresentation)
        perform(fullscreenTeardown.handle(.didExit))
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard acceptsFullscreenCallback(.didFailExit) else { return }
        windowModeCoordinator.nativeFullscreenExitDidFail()
        perform(fullscreenTeardown.handle(.didFailExit))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isSessionActive else { return true }
        requestStop(quitHostApplication: quitHostApplication)
        return false
    }

    private func handle(_ action: StreamingShortcutAction) {
        switch action {
        case .quitStream:
            requestStop(quitHostApplication: false)
        case .quitStreamAndApplication:
            requestStop(quitHostApplication: true)
        case .toggleInputCapture:
            setPointerCapture(!pointerCapture.machine.state.captureRequested)
        case .toggleFullscreen:
            let configuredMode = activePreferences?.windowMode ?? .fullscreenDesktop
            windowModeCoordinator.toggleFullscreen(
                preferredFullscreenMode: StreamPresentationInputPolicy.preferredFullscreenPresentation(
                    for: configuredMode
                )
            )
        case .toggleStatistics:
            onStatisticsToggle?()
        case .togglePointerMode:
            let next: PointerMode = pointer.preferences.mode == .relative ? .absolute : .relative
            pointer.preferences.mode = next
            pointerCapture.handle(.pointerModeChanged(next))
        case .toggleCursorVisibility:
            pointerCapture.handle(.toggleCursorVisibility)
        case .minimize:
            window.miniaturize(nil)
        case .pasteClipboardText:
            if let text = clipboard.readNormalizedText() {
                keyboard.sink?.platformInputDidProduce(.text(text))
            }
        case .togglePointerRegionLock:
            pointerCapture.handle(.toggleRegionLock)
        case .toggleSystemShortcutCapture:
            let nextMode: SystemShortcutCaptureMode = activeSystemShortcutCaptureMode == .off
                ? .always
                : .off
            activeSystemShortcutCaptureMode = nextMode
            applyInputPresentation(windowModeCoordinator.machine.presentation)
        }
    }

    private func focusStreamContent(makeKey: Bool = false) {
        if makeKey { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(contentView)
        diagnosticHandler(
            window.firstResponder === contentView
                ? "Keyboard focus is active on the stream view."
                : "Keyboard focus could not be assigned to the stream view."
        )
    }

    private func handleControllerNavigation(_ event: ControllerNavigationEvent) {
        guard NSApp.isActive else { return }
        switch event {
        case .move(.up): sendNavigationKey(code: 126, characters: "\u{F700}")
        case .move(.down): sendNavigationKey(code: 125, characters: "\u{F701}")
        case .move(.left): sendNavigationKey(code: 123, characters: "\u{F702}")
        case .move(.right): sendNavigationKey(code: 124, characters: "\u{F703}")
        case .focusPrevious:
            NSApp.keyWindow?.selectPreviousKeyView(nil)
        case .focusNext:
            NSApp.keyWindow?.selectNextKeyView(nil)
        case .activate:
            sendNavigationKey(code: 36, characters: "\r")
        case .cancel:
            sendNavigationKey(code: 53, characters: "\u{1B}")
        case .showContextMenu:
            sendNavigationKey(code: 36, characters: "\r", modifiers: .control)
        case .showSettings:
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    func handleControllerLocalAction(_ action: ControllerLocalAction) {
        guard isSessionActive else { return }
        switch action {
        case .disconnect:
            requestStop(quitHostApplication: false)
        case .toggleStatistics:
            onStatisticsToggle?()
        case .mouseModeChanged(let active):
            onControllerMouseModeChanged?(active)
            let message = active ? "Controller mouse mode enabled." : "Controller mouse mode disabled."
            diagnosticHandler(message)
            contentView.showControllerModeNotification(message)
        }
    }

    private func sendNavigationKey(
        code: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        guard let window = NSApp.keyWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    private func requestStop(quitHostApplication: Bool) {
        guard isSessionActive, !isStopRequested else { return }
        isStopRequested = true
        self.quitHostApplication = quitHostApplication
        windowModeCoordinator.setWindowActivationSuppressed(true)
        let stopHandler = onStopRequested
        stopRequestTask = Task { @MainActor [weak self] in
            if let stopHandler {
                await stopHandler(quitHostApplication)
            }
            guard let self else { return }
            dismissStreamSurfaceAndRestoreApplicationWindows()
            startPresentationFinish()
            stopRequestTask = nil
        }
    }

    private func startPresentationFinish() {
        guard presentationFinishTask == nil else { return }
        presentationFinishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await performPresentationFinish()
        }
    }

    private func recordPresentationRequest(_ presentation: WindowPresentation) {
        if presentation == .nativeFullscreen {
            _ = fullscreenTeardown.handle(.requestEnter)
        } else if fullscreenTeardown.phase == .fullscreen {
            _ = fullscreenTeardown.handle(.requestExit)
        }
    }

    private func acceptsFullscreenCallback(_ event: StreamFullscreenCallbackEvent) -> Bool {
        StreamFullscreenCallbackPolicy.shouldAccept(
            event: event,
            phase: fullscreenTeardown.phase,
            isSessionActive: isSessionActive,
            isStopRequested: isStopRequested,
            hasPendingTeardown: false,
            isWindowFullscreen: window.styleMask.contains(.fullScreen),
            observedWillEnter: fullscreenTeardown.hasObservedWillEnter,
            observedWillExit: fullscreenTeardown.hasObservedWillExit
        )
    }

    private func perform(_ command: StreamWindowTeardownCommand) {
        switch command {
        case .none:
            break
        case .requestFullscreenExit:
            _ = fullscreenTeardown.handle(.requestExit)
            windowModeCoordinator.request(.windowed)
        case .completeTeardown:
            break
        case .forceTeardown:
            diagnosticHandler(
                "Native fullscreen exit did not complete; resetting the dismissed stream window."
            )
            windowModeCoordinator.resetWindowedAfterDismissal()
            streamWindowRequiresReopen = true
            fullscreenTeardown = StreamWindowTeardownStateMachine()
        }
    }

    private func toggleStatistics() {
        setStatisticsVisible(!showsStatistics)
    }

    private func requestTextInput() {
        guard isSessionActive, onTextCommit != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Send Text to Host"
        alert.informativeText = "Enter text or use your current macOS input method. Text is committed once after preceding input edges."
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Text"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue
        guard !value.isEmpty else { return }
        onTextCommit?(value)
    }

    private func setStatisticsVisible(_ visible: Bool) {
        showsStatistics = visible
        if visible {
            refreshStatistics()
        } else {
            contentView.setStatisticsPresentation(nil)
        }
        statisticsTimer?.invalidate()
        statisticsTimer = nil
        guard visible else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatistics() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statisticsTimer = timer
    }

    private func refreshStatistics() {
        guard showsStatistics else { return }
        contentView.setStatisticsPresentation(StreamStatisticsPresenter.make(
            renderer: renderer?.statistics(),
            decoder: videoPipelineStatistics,
            transport: streamStatistics,
            lsp: lspTelemetry,
            reconnect: lspReconnectTelemetry,
            devices: lspDeviceRateTelemetry,
            product: lspProductTelemetry,
            nativeTiming: lspNativeTimingTelemetry
        ))
    }

    func updateStreamingStatistics(_ statistics: StreamTransportStatistics) {
        streamStatistics = statistics
    }

    func updateVideoPipelineStatistics(_ statistics: MediaPipelineStatistics) {
        videoPipelineStatistics = statistics
    }

    func updateLSPStatistics(
        _ telemetry: LSPTelemetrySnapshot,
        reconnect: LSPReconnectSnapshot?,
        devices: [LSPDeviceRateTelemetry] = [],
        product: LSPProductTelemetrySnapshot? = nil,
        nativeTiming: LSPNativeTimingSnapshot? = nil
    ) {
        lspTelemetry = telemetry
        lspReconnectTelemetry = reconnect
        lspDeviceRateTelemetry = devices
        lspProductTelemetry = product
        lspNativeTimingTelemetry = nativeTiming
    }

    private func setPointerCapture(_ active: Bool) {
        pointerCapture.handle(.requestCapture(active))
        pointer.isCaptureActive = pointerCapture.machine.state.isCaptured
        updatePointerCaptureRegion()
    }

    private func applyInputPresentation(_ presentation: WindowPresentation) {
        guard activePreferences != nil else { return }
        updateStreamViewport(for: presentation)
        keyboard.capturesCommandKey = StreamPresentationInputPolicy.capturesCommandKey(
            mode: activeSystemShortcutCaptureMode,
            presentation: presentation
        )
        systemShortcutCapture.update(
            mode: activeSystemShortcutCaptureMode,
            presentation: presentation,
            permissions: SystemShortcutCapturePermissionReader.snapshot()
        )
        pointerCapture.handle(.presentationChanged(
            presentation,
            displayCount: NSScreen.screens.count
        ))
    }

    private func updateStreamViewport(for presentation: WindowPresentation) {
        guard let preferences = activePreferences else {
            streamContainerView.usesSafeArea = false
            return
        }
        let nativeGeometry = AppKitDisplaySelection.displayID(for: window.screen)
            .flatMap(DisplayGeometry.nativeGeometry(for:))
        streamContainerView.usesSafeArea = presentation == .nativeFullscreen
            && StreamDisplayGeometryPolicy.usesNativeFullscreenSafeArea(
                requestedSize: CGSize(width: preferences.width, height: preferences.height),
                nativeGeometry: nativeGeometry
            )
    }

    private func updatePointerCaptureRegion() {
        guard let screen = window.screen else {
            pointerCapture.videoRegionInScreen = nil
            return
        }
        let videoRect = pointer.geometry.videoRect
        let windowRect = contentView.convert(videoRect, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        pointerCapture.videoRegionInScreen = screen.frame.intersection(screenRect)
    }

    private func resolvedScreen(
        for preferences: StreamingPreferences,
        currentScreen: NSScreen?,
        uiScreen: NSScreen?
    ) -> NSScreen? {
        let preferredDisplayID: CGDirectDisplayID? = switch preferences.displaySelection {
        case .automatic: nil
        case let .specific(displayID): displayID
        }
        return AppKitDisplaySelection.resolveScreen(
            preferredDisplayID: preferredDisplayID,
            currentScreen: currentScreen,
            uiScreen: uiScreen
        )
    }

    private func positionWindow(on screen: NSScreen?, videoSize: CGSize) {
        guard let screen else { return }
        let available = screen.visibleFrame.insetBy(dx: UmbraLayout.space6, dy: UmbraLayout.space6)
        let scale = min(
            1,
            available.width / max(videoSize.width, 1),
            available.height / max(videoSize.height, 1)
        )
        window.setContentSize(CGSize(
            width: min(available.width, max(320, videoSize.width * scale)),
            height: min(available.height, max(180, videoSize.height * scale))
        ))
        let frame = window.frame
        window.setFrameOrigin(CGPoint(
            x: screen.visibleFrame.midX - frame.width / 2,
            y: screen.visibleFrame.midY - frame.height / 2
        ))
    }

    private func handleScreenEnvironmentChange() {
        guard isSessionActive,
              let preferences = activePreferences,
              let policy = activeEffectivePolicy else { return }
        let targetScreen = resolvedScreen(
            for: preferences,
            currentScreen: window.screen,
            uiScreen: nil
        )
        updateDisplayConfiguration(for: targetScreen, preferences: preferences, policy: policy)
        applyInputPresentation(windowModeCoordinator.machine.presentation)
        if windowModeCoordinator.machine.presentation == .borderlessFullscreen {
            windowModeCoordinator.request(
                .borderlessFullscreen,
                screen: targetScreen,
                borderlessGeometry: borderlessGeometry(for: preferences, screen: targetScreen)
            )
        } else if windowModeCoordinator.machine.presentation == .windowed,
                  case .specific = preferences.displaySelection,
                  let targetScreen,
                  targetScreen !== window.screen {
            positionWindow(on: targetScreen, videoSize: contentView.videoSize)
        }
        contentView.needsLayout = true
        updatePointerCaptureRegion()
    }

    private func updateDisplayConfiguration(
        for screen: NSScreen?,
        preferences: StreamingPreferences,
        policy: EffectiveStreamingPolicy
    ) {
        let screen = screen ?? window.screen ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let drawableSize = contentView.bounds.size.scaled(by: scale)
        if let renderer {
            renderer.updateLayerGeometry(size: drawableSize, contentsScale: scale)
        } else {
            contentView.metalLayer.contentsScale = scale
            contentView.metalLayer.drawableSize = drawableSize
        }
        let rendererConfiguration = StreamRendererConfiguration.resolve(
            policy: policy,
            framesPerSecond: preferences.exactFrameRate,
            displayRefreshRate: displayRefreshRate(for: screen),
            usesMetalRenderer: preferences.rendererPreference != .avSampleBufferDisplayLayer
        )
        renderer?.updateDisplayConfiguration(rendererConfiguration.display)
        renderer?.updatePacingConfiguration(rendererConfiguration.pacing)
        renderer?.setPresentationActive(
            preferences.rendererPreference != .avSampleBufferDisplayLayer
        )
    }

    private func borderlessGeometry(
        for preferences: StreamingPreferences,
        screen: NSScreen?
    ) -> BorderlessFullscreenGeometry {
        let nativeGeometry = AppKitDisplaySelection.displayID(for: screen)
            .flatMap(DisplayGeometry.nativeGeometry(for:))
        return StreamDisplayGeometryPolicy.borderlessGeometry(
            requestedSize: CGSize(width: preferences.width, height: preferences.height),
            policy: preferences.displayResolutionPolicy,
            nativeGeometry: nativeGeometry
        )
    }

    private func displayRefreshRate(for screen: NSScreen?) -> Double {
        let currentModeRefreshRate = screen
            .flatMap(AppKitDisplaySelection.displayID(for:))
            .flatMap(CGDisplayCopyDisplayMode)?
            .refreshRate ?? 0
        return DisplayGeometry.effectiveRefreshRate(
            currentModeRefreshRate: currentModeRefreshRate,
            maximumFramesPerSecond: screen?.maximumFramesPerSecond ?? 60
        )
    }

    private static func presentation(for mode: UmbraCore.WindowMode) -> WindowPresentation {
        switch mode {
        case .windowed: .windowed
        case .fullscreenDesktop: .borderlessFullscreen
        case .fullscreen: .nativeFullscreen
        }
    }
}

final class StreamContainerView: NSView {
    let streamView: StreamMetalView
    var usesSafeArea = false {
        didSet {
            guard usesSafeArea != oldValue else { return }
            needsLayout = true
        }
    }

    init(frame frameRect: NSRect, streamView: StreamMetalView) {
        self.streamView = streamView
        super.init(frame: frameRect)
        addSubview(streamView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        streamView.frame = StreamViewportPolicy.frame(
            bounds: bounds,
            safeAreaRect: safeAreaRect,
            usesSafeArea: usesSafeArea
        )
    }
}

/// Small click-through text over video, with no material, background, or container border.
final class StreamStatisticsOverlayView: NSView {
    private let readout = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        readout.font = .monospacedSystemFont(ofSize: UmbraLayout.streamOverlayFontSize, weight: .regular)
        readout.textColor = StreamOverlayStyle.text
        readout.drawsBackground = false
        readout.isBordered = false
        readout.maximumNumberOfLines = 0
        readout.lineBreakMode = .byClipping
        readout.setAccessibilityElement(false)
        readout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(readout)
        NSLayoutConstraint.activate([
            readout.leadingAnchor.constraint(equalTo: leadingAnchor),
            readout.trailingAnchor.constraint(equalTo: trailingAnchor),
            readout.topAnchor.constraint(equalTo: topAnchor),
            readout.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Stream performance")
        setAccessibilityHelp("LSP latency values show the median and 99th percentile in milliseconds. A dash means no measurement yet.")
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setPresentation(_ presentation: StreamStatisticsPresentation?) {
        guard let presentation else {
            isHidden = true
            setAccessibilityValue(nil)
            return
        }
        readout.attributedStringValue = NSAttributedString(string: presentation.overlayText, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: UmbraLayout.streamOverlayFontSize, weight: .regular),
            .foregroundColor: StreamOverlayStyle.text,
            .shadow: StreamOverlayStyle.textShadow,
        ])
        setAccessibilityValue(presentation.accessibilityValue)
        isHidden = false
    }
}

final class StreamMetalView: NSView {
    weak var keyboard: AppKitKeyboardInputAdapter?
    weak var pointer: AppKitPointerInputAdapter?
    weak var inputSink: (any PlatformInputPacketSink)?
    var directTouchMode = true {
        didSet {
            if directTouchMode {
                emitVirtualTrackpadPackets(
                    virtualTrackpad.cancelAllContacts(at: ProcessInfo.processInfo.systemUptime)
                )
                scheduleVirtualTrackpadAdvance()
            }
        }
    }
    private var virtualTrackpad = VirtualTrackpadStateMachine(configuration: .init(
        referenceSize: CGSize(width: 1_280, height: 720)
    ))
    private var virtualTrackpadTimer: Timer?
    private let statisticsOverlay = StreamStatisticsOverlayView()
    private let controllerModeLabel = NSTextField(labelWithString: "")
    private var controllerModeTimer: Timer?
    private var statisticsPresentation: StreamStatisticsPresentation?
    private var lastLayoutSize: CGSize?
    private var lastLayoutScale: CGFloat?
    weak var sampleBufferLayer: AVSampleBufferDisplayLayer?
    var videoSize: CGSize = .init(width: 1_280, height: 720) {
        didSet {
            pointer?.geometry.videoSize = videoSize
            virtualTrackpad.configuration.referenceSize = videoSize
            needsLayout = true
        }
    }
    var onLayout: ((CGSize, CGFloat) -> Void)?
    var onRequestTextInput: (() -> Void)?

    var metalLayer: CAMetalLayer {
        guard let layer = layer as? CAMetalLayer else {
            preconditionFailure("StreamMetalView requires a CAMetalLayer")
        }
        return layer
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // AppKit already translates an indirect trackpad or Magic Mouse surface
        // into relative mouse motion, scrolling, and button events. Listening to
        // those same contacts as raw touches creates a second absolute pointer
        // stream, which makes the remote cursor jump and moves clicks elsewhere.
        allowedTouchTypes = [.direct]
        addSubview(statisticsOverlay)

        controllerModeLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        controllerModeLabel.textColor = .white
        controllerModeLabel.alignment = .center
        controllerModeLabel.isBezeled = false
        controllerModeLabel.drawsBackground = false
        controllerModeLabel.wantsLayer = true
        controllerModeLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        controllerModeLabel.layer?.cornerRadius = 8
        controllerModeLabel.isHidden = true
        addSubview(controllerModeLabel)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layoutStatisticsOverlay()
        controllerModeLabel.sizeToFit()
        controllerModeLabel.frame.size.width += 24
        controllerModeLabel.frame.size.height += 12
        controllerModeLabel.frame.origin = CGPoint(
            x: max(12, (bounds.width - controllerModeLabel.frame.width) / 2),
            y: 20
        )
        let scale = window?.backingScaleFactor ?? 2
        guard lastLayoutSize != bounds.size || lastLayoutScale != scale else { return }
        lastLayoutSize = bounds.size
        lastLayoutScale = scale
        sampleBufferLayer?.frame = bounds
        onLayout?(bounds.size, scale)
    }

    private func layoutStatisticsOverlay() {
        let overlayFittingSize = statisticsOverlay.fittingSize
        statisticsOverlay.frame.size = CGSize(
            width: min(
                overlayFittingSize.width,
                UmbraLayout.streamOverlayMaximumWidth,
                max(bounds.width - (UmbraLayout.space3 * 2), 0)
            ),
            height: overlayFittingSize.height
        )
        statisticsOverlay.frame.origin = CGPoint(x: UmbraLayout.space3, y: UmbraLayout.space3)
    }

    override func keyDown(with event: NSEvent) { keyboard?.consumeInStreamView(event) }
    override func keyUp(with event: NSEvent) { keyboard?.consumeInStreamView(event) }
    override func flagsChanged(with event: NSEvent) { keyboard?.consumeInStreamView(event) }
    override func mouseMoved(with event: NSEvent) { if pointer?.handle(event, in: self) != true { super.mouseMoved(with: event) } }
    override func mouseDragged(with event: NSEvent) { if pointer?.handle(event, in: self) != true { super.mouseDragged(with: event) } }
    override func rightMouseDragged(with event: NSEvent) { if pointer?.handle(event, in: self) != true { super.rightMouseDragged(with: event) } }
    override func otherMouseDragged(with event: NSEvent) { if pointer?.handle(event, in: self) != true { super.otherMouseDragged(with: event) } }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if pointer?.handle(event, in: self) != true { super.mouseDown(with: event) }
    }
    override func mouseUp(with event: NSEvent) { if pointer?.handle(event, in: self) != true { super.mouseUp(with: event) } }
    override func rightMouseDown(with event: NSEvent) { if pointer?.handle(event, in: self) != true { super.rightMouseDown(with: event) } }
    override func rightMouseUp(with event: NSEvent) { if pointer?.handle(event, in: self) != true { super.rightMouseUp(with: event) } }
    override func otherMouseDown(with event: NSEvent) { if pointer?.handle(event, in: self) != true { super.otherMouseDown(with: event) } }
    override func otherMouseUp(with event: NSEvent) { if pointer?.handle(event, in: self) != true { super.otherMouseUp(with: event) } }
    override func scrollWheel(with event: NSEvent) { if pointer?.handle(event, in: self) != true { super.scrollWheel(with: event) } }
    override func touchesBegan(with event: NSEvent) { handleTouches(event, matching: .began, phase: .began) }
    override func touchesMoved(with event: NSEvent) { handleTouches(event, matching: .moved, phase: .moved) }
    override func touchesEnded(with event: NSEvent) { handleTouches(event, matching: .ended, phase: .ended) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Stream")
        let item = NSMenuItem(
            title: "Send Text to Host…",
            action: #selector(requestTextInputFromMenu),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = onRequestTextInput != nil
        menu.addItem(item)
        return menu
    }

    @objc private func requestTextInputFromMenu() {
        onRequestTextInput?()
    }
    override func touchesCancelled(with event: NSEvent) { handleTouches(event, matching: .cancelled, phase: .cancelled) }

    private func handleTouches(
        _ event: NSEvent,
        matching touchPhase: NSTouch.Phase,
        phase: UmbraPlatform.TouchPhase
    ) {
        for touch in event.touches(matching: touchPhase, in: self) {
            guard StreamTouchInputPolicy.shouldForwardRawTouch(touch.type) else { continue }
            let location = touch.location(in: self)
            let pointerID = UInt32(truncatingIfNeeded: ObjectIdentifier(touch.identity as AnyObject).hashValue)
            if directTouchMode {
                guard let pointer else { continue }
                let position = pointer.geometry.normalizedVideoPosition(
                    for: location,
                    flippedCoordinates: isFlipped
                )
                inputSink?.platformInputDidProduce(.touch(TouchPacket(
                    pointerID: pointerID,
                    phase: phase,
                    x: Float(position.x),
                    y: Float(position.y),
                    pressure: phase == .ended || phase == .cancelled ? 0 : 1
                )))
            } else {
                guard let position = StreamTouchInputPolicy.virtualTrackpadPosition(
                    for: location,
                    viewBounds: bounds,
                    flippedCoordinates: isFlipped
                ) else { continue }
                handleVirtualTrackpadTouch(
                    pointerID: pointerID,
                    position: position,
                    phase: phase
                )
            }
        }
    }

    private func handleVirtualTrackpadTouch(
        pointerID: UInt32,
        position: CGPoint,
        phase: UmbraPlatform.TouchPhase
    ) {
        emitVirtualTrackpadPackets(virtualTrackpad.handle(VirtualTrackpadTouchEvent(
            pointerID: pointerID,
            phase: phase,
            normalizedPosition: position,
            timestamp: ProcessInfo.processInfo.systemUptime
        )))
        scheduleVirtualTrackpadAdvance()
    }

    private func emitVirtualTrackpadPackets(_ packets: [PlatformInputPacket]) {
        for packet in packets { inputSink?.platformInputDidProduce(packet) }
    }

    private func scheduleVirtualTrackpadAdvance() {
        virtualTrackpadTimer?.invalidate()
        virtualTrackpadTimer = nil
        guard let deadline = virtualTrackpad.nextScheduledEventTime else { return }
        virtualTrackpadTimer = Timer.scheduledTimer(
            withTimeInterval: max(deadline - ProcessInfo.processInfo.systemUptime, 0.001),
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emitVirtualTrackpadPackets(
                    self.virtualTrackpad.advance(to: ProcessInfo.processInfo.systemUptime)
                )
                self.scheduleVirtualTrackpadAdvance()
            }
        }
    }

    func resetVirtualTrackpad() {
        virtualTrackpadTimer?.invalidate()
        virtualTrackpadTimer = nil
        emitVirtualTrackpadPackets(
            virtualTrackpad.cancelAllContacts(at: ProcessInfo.processInfo.systemUptime)
        )
    }

    func setStatisticsPresentation(_ presentation: StreamStatisticsPresentation?) {
        guard presentation != statisticsPresentation else { return }
        statisticsPresentation = presentation
        statisticsOverlay.setPresentation(presentation)
        layoutStatisticsOverlay()
    }

    func showControllerModeNotification(_ message: String) {
        controllerModeTimer?.invalidate()
        controllerModeLabel.stringValue = message
        controllerModeLabel.setAccessibilityLabel(message)
        controllerModeLabel.isHidden = false
        needsLayout = true
        NSAccessibility.post(
            element: controllerModeLabel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controllerModeLabel.isHidden = true
                self?.controllerModeTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        controllerModeTimer = timer
    }
}

enum StreamTouchInputPolicy {
    static func shouldForwardRawTouch(_ type: NSTouch.TouchType) -> Bool {
        type == .direct
    }

    static func virtualTrackpadPosition(
        for point: CGPoint,
        viewBounds: CGRect,
        flippedCoordinates: Bool
    ) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              viewBounds.width > 0, viewBounds.height > 0 else { return nil }
        let x = (point.x - viewBounds.minX) / viewBounds.width
        let y = flippedCoordinates
            ? (point.y - viewBounds.minY) / viewBounds.height
            : (viewBounds.maxY - point.y) / viewBounds.height
        return CGPoint(x: x, y: y)
    }
}

enum StreamPresentationInputPolicy {
    static func pointerMode(absoluteMouseMode: Bool) -> PointerMode {
        absoluteMouseMode ? .absolute : .relative
    }

    static func shortcutCaptureMode(
        for mode: CaptureSystemKeysMode
    ) -> SystemShortcutCaptureMode {
        switch mode {
        case .off: .off
        case .fullscreen: .fullscreenOnly
        case .always: .always
        }
    }

    static func capturesCommandKey(
        mode: SystemShortcutCaptureMode,
        presentation: WindowPresentation
    ) -> Bool {
        switch mode {
        case .off: false
        case .fullscreenOnly: presentation != .windowed
        case .always: true
        }
    }

    static func preferredFullscreenPresentation(
        for mode: UmbraCore.WindowMode
    ) -> WindowPresentation {
        mode == .fullscreen ? .nativeFullscreen : .borderlessFullscreen
    }
}

enum StreamWindowFullscreenPhase: Equatable {
    case windowed
    case entering
    case fullscreen
    case exiting
}

enum StreamFullscreenCallbackPolicy {
    static func shouldAccept(
        event: StreamFullscreenCallbackEvent,
        phase: StreamWindowFullscreenPhase,
        isSessionActive: Bool,
        isStopRequested: Bool = false,
        hasPendingTeardown: Bool,
        isWindowFullscreen: Bool,
        observedWillEnter: Bool,
        observedWillExit: Bool
    ) -> Bool {
        guard !isStopRequested, isSessionActive || hasPendingTeardown else { return false }
        return switch event {
        case .willEnter: phase == .windowed || phase == .entering
        case .didEnter: phase == .entering && observedWillEnter && isWindowFullscreen
        case .didFailEnter: phase == .entering && observedWillEnter && !isWindowFullscreen
        case .willExit: phase == .fullscreen || phase == .exiting
        case .didExit: phase == .exiting && (observedWillExit || !isWindowFullscreen)
        case .didFailExit: phase == .exiting && observedWillExit && isWindowFullscreen
        }
    }
}

enum StreamFullscreenCallbackEvent {
    case willEnter
    case didEnter
    case didFailEnter
    case willExit
    case didExit
    case didFailExit
}

enum StreamWindowTeardownEvent {
    case requestEnter
    case willEnter
    case didEnter
    case didFailEnter
    case requestExit
    case willExit
    case didExit
    case didFailExit
    case beginTeardown
}

enum StreamWindowTeardownCommand: Equatable {
    case none
    case requestFullscreenExit
    case completeTeardown
    case forceTeardown
}

struct StreamWindowTeardownStateMachine {
    private(set) var phase: StreamWindowFullscreenPhase = .windowed
    private(set) var hasObservedWillEnter = false
    private(set) var hasObservedWillExit = false
    private var teardownRequested = false
    private var failedExitAttempts = 0

    mutating func handle(_ event: StreamWindowTeardownEvent) -> StreamWindowTeardownCommand {
        switch event {
        case .requestEnter:
            let observedMatchingWillEnter = phase == .entering && hasObservedWillEnter
            phase = .entering
            hasObservedWillEnter = observedMatchingWillEnter
            hasObservedWillExit = false
        case .willEnter:
            phase = .entering
            hasObservedWillEnter = true
            hasObservedWillExit = false
        case .didEnter:
            phase = .fullscreen
            hasObservedWillEnter = false
            return teardownRequested ? .requestFullscreenExit : .none
        case .didFailEnter:
            phase = .windowed
            hasObservedWillEnter = false
            return teardownRequested ? .completeTeardown : .none
        case .requestExit:
            let observedMatchingWillExit = phase == .exiting && hasObservedWillExit
            if phase != .windowed {
                phase = .exiting
            }
            hasObservedWillExit = observedMatchingWillExit
        case .willExit:
            if phase != .windowed { phase = .exiting }
            hasObservedWillEnter = false
            hasObservedWillExit = true
        case .didExit:
            phase = .windowed
            hasObservedWillEnter = false
            hasObservedWillExit = false
            failedExitAttempts = 0
            return teardownRequested ? .completeTeardown : .none
        case .didFailExit:
            phase = .fullscreen
            hasObservedWillExit = false
            guard teardownRequested else { return .none }
            failedExitAttempts += 1
            if failedExitAttempts >= 3 {
                phase = .windowed
                return .forceTeardown
            }
            return .requestFullscreenExit
        case .beginTeardown:
            teardownRequested = true
            switch phase {
            case .windowed: return .completeTeardown
            case .entering, .exiting: return .none
            case .fullscreen: return .requestFullscreenExit
            }
        }
        return .none
    }

    mutating func reconcile(isWindowFullscreen: Bool) -> StreamWindowTeardownCommand {
        switch (phase, isWindowFullscreen) {
        case (.windowed, true), (.entering, true):
            handle(.didEnter)
        case (.fullscreen, false), (.exiting, false):
            handle(.didExit)
        default:
            .none
        }
    }
}

enum StreamVideoPresentationPolicy {
    static let contentMode: VideoContentMode = .aspectFill
    static let sampleBufferGravity: AVLayerVideoGravity = .resizeAspectFill
    static let pointerScalingMode: VideoScalingMode = .aspectFill
}

enum StreamViewportPolicy {
    static func frame(
        bounds: CGRect,
        safeAreaRect: CGRect,
        usesSafeArea: Bool
    ) -> CGRect {
        usesSafeArea ? safeAreaRect : bounds
    }
}

enum StreamDisplayGeometryPolicy {
    static func resolvedPixelSize(
        policy: DisplayResolutionPolicy,
        nativeGeometry: NativeDisplayGeometry?,
        fallback: CGSize
    ) -> CGSize {
        guard let nativeGeometry else { return fallback }
        return policy == .nativeExcludingNotch
            ? nativeGeometry.safePixelSize
            : nativeGeometry.fullPixelSize
    }

    static func borderlessGeometry(
        requestedSize: CGSize,
        policy: DisplayResolutionPolicy,
        nativeGeometry: NativeDisplayGeometry?
    ) -> BorderlessFullscreenGeometry {
        guard let nativeGeometry, nativeGeometry.hasDisplayCutout else {
            return policy == .nativeExcludingNotch ? .safeArea : .fullDisplay
        }
        if requestedSize == nativeGeometry.safePixelSize { return .safeArea }
        if requestedSize == nativeGeometry.fullPixelSize { return .fullDisplay }
        return policy == .nativeExcludingNotch ? .safeArea : .fullDisplay
    }

    static func usesNativeFullscreenSafeArea(
        requestedSize: CGSize,
        nativeGeometry: NativeDisplayGeometry?
    ) -> Bool {
        guard let nativeGeometry, nativeGeometry.hasDisplayCutout else { return false }
        return requestedSize == nativeGeometry.safePixelSize
    }
}

final class NativeVideoRendererRouter: UmbraMedia.MetalVideoRendering, @unchecked Sendable {
    enum Mode: Sendable, Equatable { case metal, sampleBuffer }

    private let metal: (any UmbraMedia.MetalVideoRendering)?
    private let sampleBuffer: any UmbraMedia.MetalVideoRendering
    private let setSampleBufferHidden: @MainActor @Sendable (Bool) -> Void
    private let awaitBackendReset: @Sendable () async -> Void
    private let lock = NSLock()
    private var mode: Mode = .metal
    private var isSessionActive = false
    private var sessionGeneration: UInt64 = 0
    private var rejectedLateFrameCount: UInt64 = 0
    private var lastVideoSize: CGSize = .zero
    private var videoSizeGeneration: UInt64 = 0
    private var videoSizeHandler: (@MainActor @Sendable (CGSize) -> Void)?
    private var firstPresentationProxyHandler: @Sendable (Int) -> Void = { _ in }
    private var sessionPresentationProxyHandler: @Sendable (UInt64, Int) -> Void = { _, _ in }
    private var commandCommitHandler: @Sendable (Int) -> Void = { _ in }

    init(metal: MetalVideoRenderer?, sampleBuffer: SampleBufferVideoRenderer) {
        self.metal = metal
        self.sampleBuffer = sampleBuffer
        setSampleBufferHidden = { [sampleBuffer] hidden in
            sampleBuffer.layer.isHidden = hidden
        }
        awaitBackendReset = { [sampleBuffer] in
            await sampleBuffer.awaitFlushQuiescence()
        }
        installBackendPresentationProxyDispatchers()
    }

    init(
        metal: (any UmbraMedia.MetalVideoRendering)?,
        sampleBuffer: any UmbraMedia.MetalVideoRendering,
        setSampleBufferHidden: @escaping @MainActor @Sendable (Bool) -> Void,
        awaitBackendReset: @escaping @Sendable () async -> Void = {}
    ) {
        self.metal = metal
        self.sampleBuffer = sampleBuffer
        self.setSampleBufferHidden = setSampleBufferHidden
        self.awaitBackendReset = awaitBackendReset
        installBackendPresentationProxyDispatchers()
    }

    @discardableResult
    func prepareSession(mode: Mode) -> UInt64 {
        let effectiveMode: Mode = mode == .metal && metal == nil ? .sampleBuffer : mode
        let generation = lock.withLock { () -> UInt64 in
            isSessionActive = false
            sessionGeneration &+= 1
            lastVideoSize = .zero
            videoSizeGeneration &+= 1
            self.mode = effectiveMode
            return sessionGeneration
        }
        flushBackends()
        return generation
    }

    func awaitPreparedBackendReset() async {
        let selectedMode = lock.withLock { mode }
        if selectedMode == .sampleBuffer {
            await awaitBackendReset()
        }
    }

    @discardableResult
    func activatePreparedSession(generation: UInt64) -> Bool {
        let effectiveMode = lock.withLock { () -> Mode? in
            guard sessionGeneration == generation, !isSessionActive else { return nil }
            isSessionActive = true
            return mode
        }
        guard let effectiveMode else { return false }
        updateSampleBufferVisibility(for: effectiveMode)
        return true
    }

    func deactivateSession() {
        lock.withLock {
            guard isSessionActive else { return }
            isSessionActive = false
            sessionGeneration &+= 1
            lastVideoSize = .zero
            videoSizeGeneration &+= 1
        }
    }

    func flushDeactivatedBackends() {
        flushBackends()
    }

    var lifecycleSnapshot: (isActive: Bool, generation: UInt64, rejectedLateFrames: UInt64) {
        lock.withLock { (isSessionActive, sessionGeneration, rejectedLateFrameCount) }
    }

    private func updateSampleBufferVisibility(for effectiveMode: Mode) {
        Task { @MainActor [setSampleBufferHidden] in
            setSampleBufferHidden(effectiveMode != .sampleBuffer)
        }
    }

    func setVideoSizeHandler(
        _ handler: @escaping @MainActor @Sendable (CGSize) -> Void
    ) {
        lock.withLock { videoSizeHandler = handler }
    }

    func installFirstPresentationProxyHandler(
        _ handler: @escaping @Sendable (Int) -> Void
    ) {
        lock.withLock { firstPresentationProxyHandler = handler }
    }

    func installCommandCommitHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        lock.withLock { commandCommitHandler = handler }
    }

    func installFrameDropHandler(
        _ handler: @escaping @Sendable (Int, MetalFrameDropReason) -> Void
    ) {
        metal?.installFrameDropHandler(handler)
    }

    func setMailboxDropNewest(_ enabled: Bool) {
        metal?.setMailboxDropNewest(enabled)
    }

    func setSessionPresentationProxyHandler(
        _ handler: @escaping @Sendable (UInt64, Int) -> Void
    ) {
        lock.withLock { sessionPresentationProxyHandler = handler }
    }

    func installTelemetryProfile(_ profile: StreamingTelemetryProfile) {
        metal?.installTelemetryProfile(profile)
        sampleBuffer.installTelemetryProfile(profile)
    }

    func installTelemetryClient(_ client: StreamingTelemetryClient) {
        metal?.installTelemetryClient(client)
        sampleBuffer.installTelemetryClient(client)
    }

    func enqueue(_ frame: UmbraMedia.DecodedVideoFrame) {
        let size = CGSize(
            width: CVPixelBufferGetWidth(frame.imageBuffer),
            height: CVPixelBufferGetHeight(frame.imageBuffer)
        )
        let ticket = lock.withLock { () -> (
            sessionGeneration: UInt64,
            mode: Mode,
            report: (
                handler: @MainActor @Sendable (CGSize) -> Void,
                generation: UInt64
            )?
        )? in
            guard isSessionActive else {
                rejectedLateFrameCount &+= 1
                return nil
            }
            let report: (
                handler: @MainActor @Sendable (CGSize) -> Void,
                generation: UInt64
            )? = if size != lastVideoSize, let videoSizeHandler {
                (videoSizeHandler, videoSizeGeneration)
            } else {
                nil
            }
            lastVideoSize = size
            return (sessionGeneration, mode, report)
        }
        guard let ticket else { return }
        let routed = lock.withLock { () -> Bool in
            guard isSessionActive,
                  sessionGeneration == ticket.sessionGeneration else {
                rejectedLateFrameCount &+= 1
                return false
            }
            switch ticket.mode {
            case .metal: metal?.enqueue(frame)
            case .sampleBuffer: sampleBuffer.enqueue(frame)
            }
            return true
        }
        guard routed, let report = ticket.report else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            lock.withLock {
                guard isSessionActive,
                      videoSizeGeneration == report.generation else { return }
                report.handler(size)
            }
        }
    }

    func flush() {
        deactivateSession()
        flushBackends()
    }

    private func flushBackends() {
        lock.withLock {
            lastVideoSize = .zero
            videoSizeGeneration &+= 1
        }
        metal?.flush()
        sampleBuffer.flush()
    }

    private func installBackendPresentationProxyDispatchers() {
        metal?.installFirstPresentationProxyHandler { [weak self] frameNumber in
            self?.handlePresentationProxy(frameNumber: frameNumber, source: .metal)
        }
        metal?.installCommandCommitHandler { [weak self] frameNumber in
            guard let self else { return }
            let handler = lock.withLock { commandCommitHandler }
            handler(frameNumber)
        }
        sampleBuffer.installFirstPresentationProxyHandler { [weak self] frameNumber in
            self?.handlePresentationProxy(frameNumber: frameNumber, source: .sampleBuffer)
        }
    }

    private func handlePresentationProxy(frameNumber: Int, source: Mode) {
        let handlers = lock.withLock { () -> (
            first: @Sendable (Int) -> Void,
            session: @Sendable (UInt64, Int) -> Void,
            generation: UInt64
        )? in
            guard isSessionActive, mode == source else { return nil }
            return (
                firstPresentationProxyHandler,
                sessionPresentationProxyHandler,
                sessionGeneration
            )
        }
        guard let handlers else { return }
        handlers.first(frameNumber)
        handlers.session(handlers.generation, frameNumber)
    }
}

protocol SampleBufferVideoRenderingDriver: AnyObject, Sendable {
    var status: AVQueuedSampleBufferRenderingStatus { get }
    var error: (any Error)? { get }
    var isReadyForMoreMediaData: Bool { get }

    func requestMediaDataWhenReady(
        on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void
    )
    func stopRequestingMediaData()
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush(
        removingDisplayedImage: Bool,
        completionHandler: @escaping @Sendable () -> Void
    )
}

private final class SystemSampleBufferVideoRenderingDriver:
    SampleBufferVideoRenderingDriver,
    @unchecked Sendable
{
    private let renderer: AVSampleBufferVideoRenderer

    init(layer: AVSampleBufferDisplayLayer) {
        renderer = layer.sampleBufferRenderer
    }

    var status: AVQueuedSampleBufferRenderingStatus { renderer.status }
    var error: (any Error)? { renderer.error }
    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }

    func requestMediaDataWhenReady(
        on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void
    ) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingMediaData() {
        renderer.stopRequestingMediaData()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        renderer.enqueue(sampleBuffer)
    }

    func flush(
        removingDisplayedImage: Bool,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        renderer.flush(
            removingDisplayedImage: removingDisplayedImage,
            completionHandler: completionHandler
        )
    }
}

final class SampleBufferVideoRenderer: UmbraMedia.MetalVideoRendering, @unchecked Sendable {
    enum PacingPolicy: Sendable, Equatable {
        /// Keep only the newest decoded frame and timestamp it on the system display clock.
        /// AVSampleBufferDisplayLayer owns compositor/VSync scheduling in this fallback path.
        case systemDisplayClockLatestFrame
    }

    struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        let description: String
    }

    static let pacingPolicy: PacingPolicy = .systemDisplayClockLatestFrame

    private struct PendingFrame: @unchecked Sendable {
        let frame: UmbraMedia.DecodedVideoFrame
        let generation: UInt64
    }

    let layer: AVSampleBufferDisplayLayer
    private let driver: any SampleBufferVideoRenderingDriver
    private let failureHandler: @Sendable (Failure) -> Void
    private let queue = DispatchQueue(label: "app.umbra.media.sample-buffer", qos: .userInteractive)
    private let lock = NSLock()
    private var latestFrame: PendingFrame?
    private var generation: UInt64 = 0
    private var isRequestingMediaData = false
    private var requestGeneration: UInt64?
    private var flushGenerationPending: UInt64?
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private var reportedFirstPresentationProxy = false
    private var firstPresentationProxyHandler: @Sendable (Int) -> Void = { _ in }
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var pumpSource: DispatchSourceUserDataAdd?

    convenience init(
        layer: AVSampleBufferDisplayLayer,
        failureHandler: @escaping @Sendable (Failure) -> Void = { _ in }
    ) {
        self.init(
            layer: layer,
            driver: SystemSampleBufferVideoRenderingDriver(layer: layer),
            failureHandler: failureHandler
        )
    }

    init(
        layer: AVSampleBufferDisplayLayer,
        driver: any SampleBufferVideoRenderingDriver,
        failureHandler: @escaping @Sendable (Failure) -> Void = { _ in }
    ) {
        self.layer = layer
        self.driver = driver
        self.failureHandler = failureHandler

        let source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler { [weak self] in self?.beginPumpIfNeeded() }
        source.resume()
        pumpSource = source
    }

    func enqueue(_ frame: UmbraMedia.DecodedVideoFrame) {
        lock.withLock {
            latestFrame = PendingFrame(frame: frame, generation: generation)
        }
        pumpSource?.add(data: 1)
    }

    func flush() {
        let flushGeneration = lock.withLock { () -> UInt64 in
            generation &+= 1
            reportedFirstPresentationProxy = false
            latestFrame = nil
            flushGenerationPending = generation
            return generation
        }
        queue.async { [self] in
            stopPump(upTo: flushGeneration)
            cachedFormatDescription = nil
            driver.flush(removingDisplayedImage: true) { [weak self] in
                self?.resumeCurrentFrameAfterFlush(generation: flushGeneration)
            }
        }
    }

    func installFirstPresentationProxyHandler(
        _ handler: @escaping @Sendable (Int) -> Void
    ) {
        lock.withLock { firstPresentationProxyHandler = handler }
    }

    func awaitFlushQuiescence() async {
        await withCheckedContinuation { continuation in
            let isAlreadyReady = lock.withLock { () -> Bool in
                guard flushGenerationPending != nil else { return true }
                flushWaiters.append(continuation)
                return false
            }
            if isAlreadyReady { continuation.resume() }
        }
    }

    private func beginPumpIfNeeded() {
        let generation = lock.withLock { () -> UInt64? in
            guard flushGenerationPending == nil,
                  let latestFrame,
                  !isRequestingMediaData else { return nil }
            isRequestingMediaData = true
            requestGeneration = latestFrame.generation
            return latestFrame.generation
        }
        guard let generation else { return }
        driver.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.drainLatestFrameWhenReady(generation: generation)
        }
    }

    private func drainLatestFrameWhenReady(generation: UInt64) {
        guard lock.withLock({ self.generation == generation && requestGeneration == generation }) else {
            return
        }
        if driver.status == .failed {
            recoverFailedRenderer(generation: generation)
            return
        }
        guard driver.isReadyForMoreMediaData else { return }

        guard let frame = lock.withLock({ () -> UmbraMedia.DecodedVideoFrame? in
            guard self.generation == generation,
                  latestFrame?.generation == generation else { return nil }
            defer { latestFrame = nil }
            return latestFrame?.frame
        }) else {
            stopPump(upTo: generation)
            return
        }
        guard let sampleBuffer = makeSampleBuffer(for: frame) else { return }
        driver.enqueue(sampleBuffer)
        let firstPresentationProxyHandler = lock.withLock { () -> (@Sendable (Int) -> Void)? in
            guard self.generation == generation,
                  !reportedFirstPresentationProxy else { return nil }
            reportedFirstPresentationProxy = true
            return self.firstPresentationProxyHandler
        }
        firstPresentationProxyHandler?(frame.frameNumber)
    }

    private func recoverFailedRenderer(generation: UInt64) {
        guard lock.withLock({ self.generation == generation }) else { return }
        let detail = driver.error.map { ": \($0.localizedDescription)" } ?? ""
        failureHandler(Failure(description: "a failed display layer\(detail)"))
        cachedFormatDescription = nil
        lock.withLock { flushGenerationPending = generation }
        stopPump(upTo: generation)
        driver.flush(removingDisplayedImage: true) { [weak self] in
            self?.resumeCurrentFrameAfterFlush(generation: generation)
        }
    }

    private func stopPump(upTo generation: UInt64) {
        let shouldStop = lock.withLock { () -> Bool in
            if let requestGeneration, requestGeneration > generation { return false }
            isRequestingMediaData = false
            requestGeneration = nil
            return true
        }
        if shouldStop { driver.stopRequestingMediaData() }
    }

    private func resumeCurrentFrameAfterFlush(generation: UInt64) {
        let completion = lock.withLock { () -> (
            hasCurrentFrame: Bool,
            waiters: [CheckedContinuation<Void, Never>]
        )? in
            guard self.generation == generation,
                  flushGenerationPending == generation else { return nil }
            flushGenerationPending = nil
            let waiters = flushWaiters
            flushWaiters.removeAll(keepingCapacity: true)
            return (latestFrame?.generation == generation, waiters)
        }
        guard let completion else { return }
        for waiter in completion.waiters { waiter.resume() }
        if completion.hasCurrentFrame { pumpSource?.add(data: 1) }
    }

    private func makeSampleBuffer(
        for frame: UmbraMedia.DecodedVideoFrame
    ) -> CMSampleBuffer? {
        let formatDescription: CMVideoFormatDescription
        if let cachedFormatDescription,
           CMVideoFormatDescriptionMatchesImageBuffer(
               cachedFormatDescription,
               imageBuffer: frame.imageBuffer
           ) {
            formatDescription = cachedFormatDescription
        } else {
            var createdDescription: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.imageBuffer,
                formatDescriptionOut: &createdDescription
            )
            guard status == noErr, let createdDescription else {
                failureHandler(Failure(
                    description: "format-description creation failure (status \(status))"
                ))
                return nil
            }
            cachedFormatDescription = createdDescription
            formatDescription = createdDescription
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.imageBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            failureHandler(Failure(
                description: "sample-buffer creation failure (status \(status))"
            ))
            return nil
        }
        return sampleBuffer
    }
}

final class AppStreamLifecycleCoordinator: StreamSessionLifecycleCoordinating, @unchecked Sendable {
    private let windowController: StreamWindowController
    private let audio: NativeAudioSessionController
    private let observers: [NSObjectProtocol]

    init(windowController: StreamWindowController, audio: NativeAudioSessionController) {
        self.windowController = windowController
        self.audio = audio
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [audio, weak windowController] _ in
                audio.setApplicationActive(true)
                MainActor.assumeIsolated { windowController?.setApplicationActive(true) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [audio, weak windowController] _ in
                audio.setApplicationActive(false)
                MainActor.assumeIsolated { windowController?.setApplicationActive(false) }
            },
        ]
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func prepare(for bootstrap: StreamBootstrap) async throws {
        try await windowController.prepare(for: bootstrap)
        audio.setApplicationActive(true)
    }

    func finishPresentation() async {
        await windowController.finish()
    }

    func updatePreparation(for bootstrap: StreamBootstrap) async throws {
        await windowController.updatePreparedSession(for: bootstrap)
    }

    func finish() async {}
}

private extension Int {
    var doubleValue: Double { Double(self) }
}

private extension CGSize {
    func scaled(by scale: CGFloat) -> CGSize {
        CGSize(width: width * scale, height: height * scale)
    }
}
