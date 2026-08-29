import AppKit
import AVFoundation
import CoreVideo
import Foundation
import UmbraCore
import UmbraIntegration
import UmbraMedia
import UmbraPlatform
import UmbraServices
import XCTest
@testable import UmbraApp

@MainActor
final class StreamWindowControllerControllerTests: XCTestCase {
    func testInstalledInputSinkIsRetainedAndReceivesKeyboardReleaseBeforeUninstall() throws {
        let controller = try StreamWindowController(device: nil)
        weak var weakSink: RecordingPlatformInputSink?

        func installEphemeralSink() {
            let sink = RecordingPlatformInputSink()
            weakSink = sink
            controller.installInputSink(sink)
        }
        installEphemeralSink()
        var sink: RecordingPlatformInputSink? = try XCTUnwrap(weakSink)
        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        XCTAssertTrue(controller.handleKeyboardEventForTesting(keyDown))
        XCTAssertEqual(sink?.packets.count, 1)

        controller.installInputSink(nil)
        XCTAssertEqual(sink?.packets.count, 2)
        XCTAssertEqual(sink?.packets.compactMap { packet -> KeyAction? in
            guard case let .keyboard(keyboard) = packet else { return nil }
            return keyboard.action
        }, [.down, .up])
        sink = nil
        XCTAssertNil(weakSink)
    }

    func testLatencyRendererPolicyRejectsStaleFuturePacingOverride() {
        var preferences = StreamingPreferences.default
        preferences.optimizationMode = .latency
        preferences.enableVSync = false
        preferences.framePacing = true
        let policy = EffectiveStreamingPolicy.resolve(for: preferences)

        let configuration = StreamRendererConfiguration.resolve(
            policy: policy,
            framesPerSecond: 120,
            displayRefreshRate: 120
        )

        XCTAssertEqual(policy.presentationIntent, .immediateTearingAllowed)
        XCTAssertTrue(policy.advancedOverrides.framePacing)
        XCTAssertFalse(configuration.display.verticalSyncEnabled)
        XCTAssertFalse(configuration.pacing.verticalSyncEnabled)
        XCTAssertFalse(configuration.pacing.framePacingEnabled)
    }

    func testQualityRendererPolicyUsesDisplayLinkAsSolePresentationClock() {
        var preferences = StreamingPreferences.default
        preferences.optimizationMode = .quality
        preferences.enableVSync = true
        preferences.framePacing = true
        let policy = EffectiveStreamingPolicy.resolve(for: preferences)

        let configuration = StreamRendererConfiguration.resolve(
            policy: policy,
            framesPerSecond: 60,
            displayRefreshRate: 120
        )

        XCTAssertEqual(policy.presentationIntent, .displayLinkedTearFree)
        XCTAssertTrue(configuration.display.verticalSyncEnabled)
        XCTAssertTrue(configuration.pacing.verticalSyncEnabled)
        XCTAssertTrue(configuration.pacing.framePacingEnabled)
        XCTAssertEqual(configuration.pacing.displayRefreshRate, 120)

        let sampleBufferConfiguration = StreamRendererConfiguration.resolve(
            policy: policy,
            framesPerSecond: 60,
            displayRefreshRate: 120,
            usesMetalRenderer: false
        )
        XCTAssertFalse(sampleBufferConfiguration.display.verticalSyncEnabled)
        XCTAssertFalse(sampleBufferConfiguration.pacing.verticalSyncEnabled)
    }

    func testControllerConsumesSessionPolicyAndTearsDownPresentationClock() async throws {
        _ = NSApplication.shared
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let controller = try StreamWindowController(device: device)
        XCTAssertFalse(try XCTUnwrap(controller.renderer).usesDisplayLinkPresentation)

        var stalePreferences = StreamingPreferences.default
        stalePreferences.optimizationMode = .quality
        stalePreferences.enableVSync = true
        stalePreferences.framePacing = true
        var latencyPreferences = stalePreferences
        latencyPreferences.optimizationMode = .latency
        latencyPreferences.enableVSync = false
        latencyPreferences.framePacing = true
        var latencyBootstrap = try makeBootstrap()
        latencyBootstrap.preferences = stalePreferences
        latencyBootstrap.effectivePolicy = .resolve(for: latencyPreferences)

        try await controller.prepare(for: latencyBootstrap)
        XCTAssertFalse(try XCTUnwrap(controller.renderer).usesDisplayLinkPresentation)
        await controller.finish()
        XCTAssertFalse(try XCTUnwrap(controller.renderer).usesDisplayLinkPresentation)

        var qualityBootstrap = try makeBootstrap()
        qualityBootstrap.preferences = stalePreferences
        qualityBootstrap.effectivePolicy = .resolve(for: stalePreferences)
        try await controller.prepare(for: qualityBootstrap)
        #if arch(arm64)
        XCTAssertTrue(try XCTUnwrap(controller.renderer).usesDisplayLinkPresentation)
        #endif
        await controller.finish()
        XCTAssertFalse(try XCTUnwrap(controller.renderer).usesDisplayLinkPresentation)

        stalePreferences.rendererPreference = .avSampleBufferDisplayLayer
        var sampleBufferBootstrap = try makeBootstrap()
        sampleBufferBootstrap.preferences = stalePreferences
        sampleBufferBootstrap.effectivePolicy = .resolve(for: stalePreferences)
        try await controller.prepare(for: sampleBufferBootstrap)
        XCTAssertFalse(try XCTUnwrap(controller.renderer).usesDisplayLinkPresentation)
        await controller.finish()
    }

    func testStatisticsPresenterMapsDecoderRendererAndTransportMetrics() {
        let renderer = MediaPipelineStatistics(
            submittedFrames: 120,
            decodedFrames: 120,
            presentedFrames: 116,
            droppedFrames: 3,
            decoderErrors: 0,
            queueDepth: 2,
            decodeFramesPerSecond: 0,
            presentationFramesPerSecond: 115.5,
            averageDecodeLatencyMilliseconds: nil
        )
        let decoder = MediaPipelineStatistics(
            submittedFrames: 120,
            decodedFrames: 118,
            presentedFrames: 0,
            droppedFrames: 2,
            decoderErrors: 1,
            queueDepth: 1,
            decodeFramesPerSecond: 117.5,
            presentationFramesPerSecond: 0,
            averageDecodeLatencyMilliseconds: 1.75
        )
        let transport = StreamTransportStatistics(
            estimatedRTTMilliseconds: 4,
            estimatedRTTVarianceMilliseconds: 1,
            pendingVideoFrames: 1,
            pendingAudioFrames: 2,
            pendingAudioDurationMilliseconds: 10,
            audioPackets: 100,
            audioFECRecovered: 0,
            audioFECFailed: 0,
            videoPackets: 200,
            videoFECRecovered: 0,
            videoFECFailed: 0
        )

        let presentation = StreamStatisticsPresenter.make(
            renderer: renderer,
            decoder: decoder,
            transport: transport
        )

        XCTAssertEqual(presentation[.videoRate], "115.5 FPS")
        XCTAssertEqual(presentation[.decodeTime], "1.8 ms")
        XCTAssertEqual(presentation[.droppedFrames], "5")
        XCTAssertEqual(presentation[.renderQueue], "2 frames")
        XCTAssertEqual(presentation[.networkRTT], "4 ± 1 ms")
        XCTAssertEqual(presentation[.videoQueue], "1 frame")
        XCTAssertEqual(presentation[.audioQueue], "10 ms")
        XCTAssertEqual(presentation[.videoPackets], "200")
        XCTAssertEqual(presentation[.audioPackets], "100")
    }

    func testStatisticsPresenterDistinguishesUnavailableMetricsFromValidZero() {
        let unavailable = StreamStatisticsPresenter.make(
            renderer: nil,
            decoder: nil,
            transport: nil
        )
        for metric in StreamPerformanceMetric.allCases {
            XCTAssertEqual(unavailable[metric], "Unavailable")
        }

        let zero = MediaPipelineStatistics(
            submittedFrames: 1,
            decodedFrames: 1,
            presentedFrames: 1,
            droppedFrames: 0,
            decoderErrors: 0,
            queueDepth: 0,
            decodeFramesPerSecond: 0,
            presentationFramesPerSecond: 0,
            averageDecodeLatencyMilliseconds: 0
        )
        let transport = StreamTransportStatistics(
            estimatedRTTMilliseconds: 0,
            estimatedRTTVarianceMilliseconds: 0,
            pendingVideoFrames: 0,
            pendingAudioFrames: 0,
            pendingAudioDurationMilliseconds: 0,
            audioPackets: 0,
            audioFECRecovered: 0,
            audioFECFailed: 0,
            videoPackets: 0,
            videoFECRecovered: 0,
            videoFECFailed: 0
        )
        let presentation = StreamStatisticsPresenter.make(
            renderer: zero,
            decoder: zero,
            transport: transport
        )

        XCTAssertEqual(presentation[.videoRate], "0.0 FPS")
        XCTAssertEqual(presentation[.decodeTime], "0.0 ms")
        XCTAssertEqual(presentation[.droppedFrames], "0")
        XCTAssertEqual(presentation[.renderQueue], "0 frames")
        XCTAssertEqual(presentation[.networkRTT], "0 ± 0 ms")
        XCTAssertEqual(presentation[.videoQueue], "0 frames")
        XCTAssertEqual(presentation[.audioQueue], "0 ms")
        XCTAssertEqual(presentation[.videoPackets], "0")
        XCTAssertEqual(presentation[.audioPackets], "0")
    }

    func testProtocolV3StatisticsFormatsLiveSmoothedVariationAndMinimumRTT() {
        XCTAssertEqual(
            StreamStatisticsPresenter.protocolV3RTT(
                smoothed: 4_120,
                minimum: 3_000,
                variation: 875
            ),
            "4.12 ms, variation 0.88 ms, min 3.00 ms"
        )
    }

    func testStatisticsOverlayUsesNoBulletOrCenterDotSeparators() {
        let presentation = StreamStatisticsPresenter.make(
            renderer: nil,
            decoder: nil,
            transport: nil
        )

        for separator in ["\u{2022}", "\u{00B7}", "\u{2219}", "\u{22C5}"] {
            XCTAssertFalse(presentation.accessibilityValue.contains(separator))
            XCTAssertFalse(presentation.values.values.contains { $0.contains(separator) })
        }
    }

    func testStatisticsPresenterLabelsLatencyPercentilesAndPresentationProxyHonestly() {
        let summary = LatencyPercentileSummary(
            sampleCount: 10,
            p50Milliseconds: 1.25,
            p95Milliseconds: 2.5,
            p99Milliseconds: 3.75
        )
        let decoder = MediaPipelineStatistics(
            submittedFrames: 10,
            decodedFrames: 10,
            presentedFrames: 0,
            droppedFrames: 0,
            decoderErrors: 0,
            queueDepth: 0,
            decodeFramesPerSecond: 10,
            presentationFramesPerSecond: 0,
            averageDecodeLatencyMilliseconds: 1,
            latencyStatistics: VideoLatencyStatistics(
                hostProcessing: summary,
                receiveToVideoToolboxSubmit: summary,
                reassemblyEnqueueToVideoToolboxSubmit: summary,
                videoToolboxDecode: summary,
                receiveToDecode: summary
            )
        )
        let renderer = MediaPipelineStatistics(
            submittedFrames: 0,
            decodedFrames: 0,
            presentedFrames: 10,
            droppedFrames: 0,
            decoderErrors: 0,
            queueDepth: 0,
            decodeFramesPerSecond: 0,
            presentationFramesPerSecond: 10,
            averageDecodeLatencyMilliseconds: nil,
            latencyStatistics: VideoLatencyStatistics(
                decodeToMetalCommit: summary,
                metalCommitToPresentationProxy: summary,
                presentationProxyEvidence: .commandBufferCompletion
            )
        )

        let presentation = StreamStatisticsPresenter.make(
            renderer: renderer,
            decoder: decoder,
            transport: nil
        )

        XCTAssertEqual(presentation[.hostProcessingLatency], "1.2 / 2.5 / 3.8 ms (n=10)")
        XCTAssertEqual(presentation[.receiveToSubmitLatency], "1.2 / 2.5 / 3.8 ms (n=10)")
        XCTAssertEqual(presentation[.reassemblyToSubmitLatency], "1.2 / 2.5 / 3.8 ms (n=10)")
        XCTAssertEqual(presentation[.videoToolboxLatency], "1.2 / 2.5 / 3.8 ms (n=10)")
        XCTAssertEqual(presentation[.receiveToDecodeLatency], "1.2 / 2.5 / 3.8 ms (n=10)")
        XCTAssertEqual(presentation[.decodeToMetalCommitLatency], "1.2 / 2.5 / 3.8 ms (n=10)")
        XCTAssertEqual(
            presentation[.presentationProxyLatency],
            "GPU completion, not scanout: 1.2 / 2.5 / 3.8 ms (n=10)"
        )
    }

    func testStatisticsPresenterSurfacesAllMissedPresentationTargets() {
        let renderer = MediaPipelineStatistics(
            submittedFrames: 0,
            decodedFrames: 0,
            presentedFrames: 0,
            droppedFrames: 0,
            decoderErrors: 0,
            queueDepth: 0,
            decodeFramesPerSecond: 0,
            presentationFramesPerSecond: 0,
            averageDecodeLatencyMilliseconds: nil,
            latencyStatistics: VideoLatencyStatistics(missedPresentationDeadlines: 3)
        )

        let presentation = StreamStatisticsPresenter.make(
            renderer: renderer,
            decoder: nil,
            transport: nil
        )

        XCTAssertEqual(
            presentation[.presentationProxyLatency],
            "No valid proxy samples, 3 missed presentation targets"
        )
    }

    func testStatisticsPresenterLabelsMissesAlongsideValidProxySamples() {
        let summary = LatencyPercentileSummary(
            sampleCount: 2,
            p50Milliseconds: 0.5,
            p95Milliseconds: 1,
            p99Milliseconds: 1
        )
        let renderer = MediaPipelineStatistics(
            submittedFrames: 0,
            decodedFrames: 0,
            presentedFrames: 2,
            droppedFrames: 0,
            decoderErrors: 0,
            queueDepth: 0,
            decodeFramesPerSecond: 0,
            presentationFramesPerSecond: 2,
            averageDecodeLatencyMilliseconds: nil,
            latencyStatistics: VideoLatencyStatistics(
                metalCommitToPresentationProxy: summary,
                presentationProxyEvidence: .mixed,
                missedPresentationDeadlines: 1
            )
        )

        let presentation = StreamStatisticsPresenter.make(
            renderer: renderer,
            decoder: nil,
            transport: nil
        )

        XCTAssertEqual(
            presentation[.presentationProxyLatency],
            "mixed proxies (1 missed presentation target): 0.5 / 1.0 / 1.0 ms (n=2)"
        )
    }

    func testStatisticsOverlayUsesNativeHUDMaterialHierarchyAndDoesNotCaptureInput() throws {
        let overlay = StreamStatisticsOverlayView()
        let grid = try XCTUnwrap(
            descendants(of: overlay, type: NSGridView.self).first
        )
        let fields = descendants(of: overlay, type: NSTextField.self)

        XCTAssertFalse(fields.isEmpty)
        XCTAssertEqual(grid.numberOfRows, 10)
        XCTAssertEqual(overlay.material, .hudWindow)
        XCTAssertEqual(overlay.blendingMode, .withinWindow)
        XCTAssertEqual(overlay.state, .active)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 1, y: 1)))
        XCTAssertTrue(fields.contains { $0.stringValue == "Stream Performance" })
        XCTAssertTrue(fields.contains { $0.stringValue == "Latency: p50 / p95 / p99" })
        XCTAssertTrue(fields.allSatisfy { !$0.isAccessibilityElement() })
        for field in fields where field.stringValue != "Stream Performance" {
            let font = try XCTUnwrap(field.font)
            XCTAssertEqual(font.pointSize, NSFont.smallSystemFontSize)
            XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        }
    }

    func testStatisticsOverlayRendersInsideTheStreamInDarkAndIncreasedContrast() throws {
        let latency = "1.2 / 2.1 / 3.4 ms (n=240)"
        let presentation = StreamStatisticsPresentation(values: Dictionary(
            uniqueKeysWithValues: StreamPerformanceMetric.allCases.map { metric in
                let value = switch metric {
                case .videoRate: "59.9 FPS"
                case .decodeTime: "3.2 ms"
                case .networkRTT: "18 ± 3 ms"
                case .droppedFrames: "0"
                case .renderQueue, .videoQueue: "1 frame"
                case .audioQueue: "12 ms"
                case .videoPackets: "48,219"
                case .audioPackets: "72,441"
                case .presentationProxyLatency:
                    "Display target: \(latency)"
                default: latency
                }
                return (metric, value)
            }
        ))
        let appearances: [(name: String, value: NSAppearance.Name)] = [
            ("dark", .darkAqua),
            ("dark-increased-contrast", .accessibilityHighContrastDarkAqua),
        ]

        for appearance in appearances {
            let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 320))
            canvas.wantsLayer = true
            canvas.layer?.backgroundColor = NSColor.darkGray.cgColor
            let overlay = StreamStatisticsOverlayView()
            overlay.appearance = NSAppearance(named: appearance.value)
            overlay.setIncreasedContrastOverride(
                appearance.value == .accessibilityHighContrastDarkAqua
            )
            overlay.setPresentation(presentation)
            canvas.addSubview(overlay)
            overlay.frame = NSRect(
                x: UmbraLayout.space3,
                y: UmbraLayout.space3,
                width: min(overlay.fittingSize.width, UmbraLayout.streamOverlayMaximumWidth),
                height: overlay.fittingSize.height
            )

            let window = NSWindow(
                contentRect: canvas.bounds,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: appearance.value)
            window.contentView = canvas
            window.orderBack(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            canvas.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()

            XCTAssertTrue(canvas.bounds.contains(overlay.frame))
            XCTAssertFalse(overlay.isHidden)
            XCTAssertEqual(overlay.accessibilityLabel(), "Stream performance")
            XCTAssertTrue(
                (overlay.accessibilityValue() as? String)?.contains("Frame rate 59.9 FPS") == true
            )
            if appearance.value == .accessibilityHighContrastDarkAqua {
                XCTAssertEqual(
                    overlay.layer?.borderWidth,
                    UmbraLayout.accessibilityBorderWidth
                )
            } else {
                XCTAssertEqual(overlay.layer?.borderWidth, 0)
            }

            guard let outputDirectory = ProcessInfo.processInfo.environment["UMBRA_UI_SNAPSHOT_DIR"] else {
                continue
            }
            let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let representation = try XCTUnwrap(
                canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)
            )
            representation.size = canvas.bounds.size
            canvas.cacheDisplay(in: canvas.bounds, to: representation)
            let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(
                "stream-performance-\(appearance.name).png"
            ))
        }

        let streamView = StreamMetalView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        streamView.setStatisticsPresentation(presentation)
        streamView.layoutSubtreeIfNeeded()
        let hostedOverlay = try XCTUnwrap(
            descendants(of: streamView, type: StreamStatisticsOverlayView.self).first
        )
        XCTAssertTrue(streamView.bounds.contains(hostedOverlay.frame))
        XCTAssertLessThanOrEqual(
            hostedOverlay.frame.width,
            streamView.bounds.width - (UmbraLayout.space3 * 2)
        )
    }

    func testRepeatedStatisticsUpdatesDoNotRelayoutStreamOrRendererGeometry() throws {
        let streamView = StreamMetalView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        streamView.wantsLayer = true
        streamView.layer = CAMetalLayer()
        var streamLayoutCount = 0
        streamView.onLayout = { _, _ in streamLayoutCount += 1 }
        streamView.needsLayout = true
        streamView.layoutSubtreeIfNeeded()
        let baselineLayoutCount = streamLayoutCount
        let baselineDrawableSize = streamView.metalLayer.drawableSize

        for update in 0..<20 {
            let presentation = StreamStatisticsPresentation(values: Dictionary(
                uniqueKeysWithValues: StreamPerformanceMetric.allCases.map {
                    ($0, "cached value \(update)")
                }
            ))
            streamView.setStatisticsPresentation(presentation)
            streamView.layoutSubtreeIfNeeded()
        }

        let overlay = try XCTUnwrap(
            descendants(of: streamView, type: StreamStatisticsOverlayView.self).first
        )
        XCTAssertEqual(streamLayoutCount, baselineLayoutCount)
        XCTAssertEqual(streamView.metalLayer.drawableSize, baselineDrawableSize)
        XCTAssertFalse(streamView.needsLayout)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(streamView.bounds.contains(overlay.frame))
    }

    func testOnlyDirectTouchscreensEnterTheRawTouchPipeline() {
        XCTAssertTrue(StreamTouchInputPolicy.shouldForwardRawTouch(.direct))
        XCTAssertFalse(
            StreamTouchInputPolicy.shouldForwardRawTouch(.indirect),
            "Trackpads and touch-sensitive mice must remain on AppKit's relative mouse path."
        )
    }

    func testDirectTouchCoordinatesUseTheDisplayedVideoRegion() throws {
        let geometry = VideoGeometry(
            contentSize: CGSize(width: 1_000, height: 1_000),
            videoSize: CGSize(width: 1_920, height: 1_080)
        )
        let videoRect = geometry.videoRect
        let centered = geometry.normalizedVideoPosition(
            for: CGPoint(x: videoRect.midX, y: videoRect.midY),
            flippedCoordinates: true
        )
        XCTAssertEqual(centered.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(centered.y, 0.5, accuracy: 0.0001)

        XCTAssertEqual(
            geometry.normalizedVideoPosition(
                for: CGPoint(x: videoRect.minX, y: videoRect.minY),
                flippedCoordinates: true
            ),
            CGPoint(x: 0, y: 0)
        )
        let flippedBottomRight = geometry.normalizedVideoPosition(
            for: CGPoint(x: videoRect.maxX, y: videoRect.maxY),
            flippedCoordinates: true
        )
        XCTAssertEqual(flippedBottomRight.x, 1, accuracy: 0.0001)
        XCTAssertEqual(flippedBottomRight.y, 1, accuracy: 0.0001)
        XCTAssertEqual(
            geometry.normalizedVideoPosition(
                for: CGPoint(x: videoRect.minX, y: videoRect.maxY),
                flippedCoordinates: false
            ),
            CGPoint(x: 0, y: 0)
        )
        let unflippedBottomRight = geometry.normalizedVideoPosition(
            for: CGPoint(x: videoRect.maxX, y: videoRect.minY),
            flippedCoordinates: false
        )
        XCTAssertEqual(unflippedBottomRight.x, 1, accuracy: 0.0001)
        XCTAssertEqual(unflippedBottomRight.y, 1, accuracy: 0.0001)

        XCTAssertEqual(
            geometry.normalizedVideoPosition(
                for: CGPoint(x: -100, y: 1_000),
                flippedCoordinates: true
            ),
            CGPoint(x: 0, y: 1)
        )
    }

    func testExactNativeSafeStreamFillsWithoutCropAcrossRendererPaths() {
        XCTAssertEqual(StreamVideoPresentationPolicy.contentMode, .aspectFill)
        XCTAssertEqual(StreamVideoPresentationPolicy.sampleBufferGravity, .resizeAspectFill)
        XCTAssertEqual(StreamVideoPresentationPolicy.pointerScalingMode, .aspectFill)

        let quad = VideoGeometry.quad(
            source: CGSize(width: 3_456, height: 2_160),
            destination: CGSize(width: 3_456, height: 2_160),
            mode: StreamVideoPresentationPolicy.contentMode
        )
        XCTAssertEqual(quad.clipScale, CGPoint(x: 1, y: 1))
        XCTAssertEqual(quad.textureRect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testNativeSafeResolutionSelectionIsIndependentOfPreferenceOrigin() {
        let native = NativeDisplayGeometry(
            fullPixelSize: CGSize(width: 3_456, height: 2_234),
            safePixelSize: CGSize(width: 3_456, height: 2_160)
        )
        XCTAssertEqual(
            StreamDisplayGeometryPolicy.resolvedPixelSize(
                policy: .nativeExcludingNotch,
                nativeGeometry: native,
                fallback: CGSize(width: 2_056, height: 1_290)
            ),
            CGSize(width: 3_456, height: 2_160)
        )
        XCTAssertEqual(
            StreamDisplayGeometryPolicy.borderlessGeometry(
                requestedSize: CGSize(width: 3_456, height: 2_160),
                policy: .configured,
                nativeGeometry: native
            ),
            .safeArea
        )
        XCTAssertEqual(
            StreamDisplayGeometryPolicy.borderlessGeometry(
                requestedSize: CGSize(width: 3_456, height: 2_234),
                policy: .configured,
                nativeGeometry: native
            ),
            .fullDisplay
        )
        XCTAssertTrue(StreamDisplayGeometryPolicy.usesNativeFullscreenSafeArea(
            requestedSize: CGSize(width: 3_456, height: 2_160),
            nativeGeometry: native
        ))
        XCTAssertEqual(
            StreamViewportPolicy.frame(
                bounds: CGRect(x: 0, y: 0, width: 3_456, height: 2_234),
                safeAreaRect: CGRect(x: 0, y: 0, width: 3_456, height: 2_160),
                usesSafeArea: true
            ),
            CGRect(x: 0, y: 0, width: 3_456, height: 2_160)
        )
    }

    func testCurrentBuiltInDisplayResolvesLogicalSafeResolution() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(AppKitDisplaySelection.displayID(for: screen))
        let native = try XCTUnwrap(DisplayGeometry.nativeGeometry(for: displayID))
        guard native.hasDisplayCutout else {
            throw XCTSkip("The current display does not expose a notch-safe native mode.")
        }
        var preferences = StreamingPreferences.default
        preferences.displayResolutionPolicy = .nativeExcludingNotch
        let controller = try StreamWindowController(device: nil)

        let resolved = controller.resolveStreamingPreferences(preferences, uiScreen: screen)
        let expected = CGSize(
            width: native.safePixelSize.width / max(screen.backingScaleFactor, 1),
            height: native.safePixelSize.height / max(screen.backingScaleFactor, 1)
        )

        XCTAssertEqual(resolved.width, StreamWindowController.evenPixelDimension(expected.width))
        XCTAssertEqual(resolved.height, StreamWindowController.evenPixelDimension(expected.height))
        XCTAssertLessThan(resolved.width, Int(native.safePixelSize.width))
        XCTAssertLessThan(resolved.height, Int(native.safePixelSize.height))
    }

    func testVirtualTrackpadCoordinatesUseTheWholeViewWithoutClamping() throws {
        let viewBounds = CGRect(x: 0, y: 0, width: 1_000, height: 500)

        XCTAssertEqual(
            StreamTouchInputPolicy.virtualTrackpadPosition(
                for: CGPoint(x: 50, y: 100),
                viewBounds: viewBounds,
                flippedCoordinates: true
            ),
            CGPoint(x: 0.05, y: 0.2)
        )
        XCTAssertEqual(
            StreamTouchInputPolicy.virtualTrackpadPosition(
                for: CGPoint(x: -50, y: 550),
                viewBounds: viewBounds,
                flippedCoordinates: true
            ),
            CGPoint(x: -0.05, y: 1.1)
        )
        XCTAssertEqual(
            StreamTouchInputPolicy.virtualTrackpadPosition(
                for: CGPoint(x: 50, y: 400),
                viewBounds: viewBounds,
                flippedCoordinates: false
            ),
            CGPoint(x: 0.05, y: 0.2)
        )
    }

    func testPresentationInputPolicyTracksRuntimeFullscreenState() {
        let fullscreenOnly = StreamPresentationInputPolicy.shortcutCaptureMode(for: .fullscreen)
        XCTAssertFalse(StreamPresentationInputPolicy.capturesCommandKey(
            mode: fullscreenOnly,
            presentation: .windowed
        ))
        XCTAssertTrue(StreamPresentationInputPolicy.capturesCommandKey(
            mode: fullscreenOnly,
            presentation: .borderlessFullscreen
        ))
        XCTAssertTrue(StreamPresentationInputPolicy.capturesCommandKey(
            mode: fullscreenOnly,
            presentation: .nativeFullscreen
        ))
        XCTAssertTrue(StreamPresentationInputPolicy.capturesCommandKey(
            mode: .always,
            presentation: .windowed
        ))
        XCTAssertFalse(StreamPresentationInputPolicy.capturesCommandKey(
            mode: .off,
            presentation: .nativeFullscreen
        ))
        XCTAssertEqual(
            StreamPresentationInputPolicy.pointerMode(absoluteMouseMode: true),
            .absolute
        )
        XCTAssertEqual(
            StreamPresentationInputPolicy.pointerMode(absoluteMouseMode: false),
            .relative
        )
    }

    func testFullscreenShortcutRespectsConfiguredPresentation() {
        XCTAssertEqual(
            StreamPresentationInputPolicy.preferredFullscreenPresentation(for: .fullscreen),
            .nativeFullscreen
        )
        XCTAssertEqual(
            StreamPresentationInputPolicy.preferredFullscreenPresentation(for: .fullscreenDesktop),
            .borderlessFullscreen
        )
        XCTAssertEqual(
            StreamPresentationInputPolicy.preferredFullscreenPresentation(for: .windowed),
            .borderlessFullscreen
        )
    }

    func testControllerLocalActionsRouteOnlyDuringActiveStream() async throws {
        _ = NSApplication.shared
        let controller = try StreamWindowController(device: nil)
        var stopRequests: [Bool] = []
        let stopRequested = expectation(description: "active disconnect requested STOP")
        var statisticsToggles = 0
        var mouseModes: [Bool] = []
        controller.onStopRequested = {
            stopRequests.append($0)
            stopRequested.fulfill()
        }
        controller.onStatisticsToggle = { statisticsToggles += 1 }
        controller.onControllerMouseModeChanged = { mouseModes.append($0) }

        controller.handleControllerLocalAction(.disconnect)
        controller.handleControllerLocalAction(.toggleStatistics)
        controller.handleControllerLocalAction(.mouseModeChanged(true))
        XCTAssertEqual(stopRequests, [])
        XCTAssertEqual(statisticsToggles, 0)
        XCTAssertEqual(mouseModes, [])

        try await controller.prepare(for: makeBootstrap())
        controller.handleControllerLocalAction(.toggleStatistics)
        controller.handleControllerLocalAction(.mouseModeChanged(true))
        controller.handleControllerLocalAction(.mouseModeChanged(false))
        controller.handleControllerLocalAction(.disconnect)
        controller.handleControllerLocalAction(.disconnect)
        await fulfillment(of: [stopRequested], timeout: 1)

        XCTAssertEqual(statisticsToggles, 1)
        XCTAssertEqual(mouseModes, [true, false])
        XCTAssertEqual(stopRequests, [false], "disconnect requests must be idempotent")
        await controller.finish()
    }

    func testFullscreenLaunchAndImmediateQuitResetAcrossRepeatedSessions() async throws {
        _ = NSApplication.shared
        var installedDriver: RecordingStreamWindowModeDriver?
        let controller = try StreamWindowController(
            device: nil,
            windowModeDriverFactory: { window in
                let driver = RecordingStreamWindowModeDriver(window: window)
                installedDriver = driver
                return driver
            }
        )
        let driver = try XCTUnwrap(installedDriver)
        var stopRequests: [Bool] = []
        var stopStarted: XCTestExpectation?
        var stopContinuation: CheckedContinuation<Void, Never>?
        controller.onStopRequested = {
            stopRequests.append($0)
            stopStarted?.fulfill()
            await withCheckedContinuation { stopContinuation = $0 }
        }

        for expectedSessionCount in 1 ... 2 {
            try await controller.prepare(for: makeBootstrap(windowMode: .fullscreen))

            XCTAssertEqual(driver.nativeFullscreenEntryCount, expectedSessionCount - 1)
            XCTAssertFalse(
                controller.isStreamWindowVisible,
                "Renderer warmup must not expose a black stream window."
            )

            controller.handleFirstRendererCommitForTesting(frameNumber: expectedSessionCount)

            XCTAssertEqual(driver.nativeFullscreenEntryCount, expectedSessionCount)
            XCTAssertEqual(driver.windowWasVisibleAtNativeEntry.last, true)
            XCTAssertTrue(controller.isStreamWindowVisible)

            let currentStopStarted = expectation(
                description: "STOP handler started for session \(expectedSessionCount)"
            )
            stopStarted = currentStopStarted
            controller.handleControllerLocalAction(.disconnect)
            await fulfillment(of: [currentStopStarted], timeout: 1)

            XCTAssertTrue(
                controller.isStreamWindowVisible,
                "The stream surface must remain until the retained STOP task completes."
            )
            stopContinuation?.resume()
            stopContinuation = nil
            stopStarted = nil
            await controller.finish()
            XCTAssertFalse(controller.isStreamWindowVisible)
            XCTAssertEqual(driver.dismissalResetCount, expectedSessionCount)
        }

        XCTAssertEqual(stopRequests, [false, false])
    }

    func testApplicationSelectorRemainsVisibleUntilFirstRendererCommitAndReturnsOnFinish() async throws {
        _ = NSApplication.shared
        let selector = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        selector.isReleasedWhenClosed = false
        selector.makeKeyAndOrderFront(nil)
        defer { selector.orderOut(nil) }

        let controller = try StreamWindowController(device: nil)
        try await controller.prepare(for: makeBootstrap(windowMode: .windowed))

        XCTAssertTrue(selector.isVisible)
        XCTAssertFalse(controller.isStreamWindowVisible)

        controller.handleFirstRendererCommitForTesting()

        XCTAssertFalse(selector.isVisible)
        XCTAssertTrue(controller.isStreamWindowVisible)

        await controller.finish()

        XCTAssertTrue(selector.isVisible)
        XCTAssertFalse(controller.isStreamWindowVisible)
    }

    func testHiddenMetalSurfaceRevealsOnItsFirstRealCommandCommit() async throws {
        _ = NSApplication.shared
        let controller = try StreamWindowController(
            device: try XCTUnwrap(MTLCreateSystemDefaultDevice())
        )
        try await controller.prepare(for: makeBootstrap(windowMode: .windowed))
        XCTAssertFalse(controller.isStreamWindowVisible)

        controller.videoRenderer.enqueue(try makeDecodedFrame(frameNumber: 91))
        for _ in 0..<100 where !controller.isStreamWindowVisible {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(
            controller.isStreamWindowVisible,
            "A hidden CAMetalLayer must be drawable so the first command commit can reveal the prepared window."
        )
        await controller.finish()
    }

    func testFullscreenTeardownWaitsForExitAndHandlesEntryRace() {
        XCTAssertFalse(StreamFullscreenCallbackPolicy.shouldAccept(
            event: .didExit,
            phase: .entering,
            isSessionActive: false,
            hasPendingTeardown: false,
            isWindowFullscreen: false,
            observedWillEnter: false,
            observedWillExit: false
        ))
        XCTAssertTrue(StreamFullscreenCallbackPolicy.shouldAccept(
            event: .didExit,
            phase: .exiting,
            isSessionActive: false,
            hasPendingTeardown: true,
            isWindowFullscreen: false,
            observedWillEnter: false,
            observedWillExit: true
        ))
        XCTAssertFalse(StreamFullscreenCallbackPolicy.shouldAccept(
            event: .didExit,
            phase: .entering,
            isSessionActive: true,
            hasPendingTeardown: false,
            isWindowFullscreen: false,
            observedWillEnter: true,
            observedWillExit: false
        ))
        XCTAssertFalse(StreamFullscreenCallbackPolicy.shouldAccept(
            event: .didFailExit,
            phase: .entering,
            isSessionActive: true,
            hasPendingTeardown: false,
            isWindowFullscreen: true,
            observedWillEnter: true,
            observedWillExit: false
        ))
        var entered = StreamWindowTeardownStateMachine()
        XCTAssertEqual(entered.handle(.requestEnter), .none)
        XCTAssertEqual(entered.handle(.willEnter), .none)
        XCTAssertEqual(entered.handle(.didEnter), .none)
        XCTAssertEqual(entered.handle(.beginTeardown), .requestFullscreenExit)
        XCTAssertEqual(entered.handle(.willExit), .none)
        XCTAssertEqual(entered.handle(.didFailExit), .requestFullscreenExit)
        XCTAssertEqual(entered.handle(.willExit), .none)
        XCTAssertEqual(entered.handle(.didFailExit), .requestFullscreenExit)
        XCTAssertEqual(entered.handle(.willExit), .none)
        XCTAssertEqual(entered.handle(.didFailExit), .forceTeardown)

        var successfulExit = StreamWindowTeardownStateMachine()
        XCTAssertEqual(successfulExit.handle(.requestEnter), .none)
        XCTAssertEqual(successfulExit.handle(.willEnter), .none)
        XCTAssertEqual(successfulExit.handle(.didEnter), .none)
        XCTAssertEqual(successfulExit.handle(.beginTeardown), .requestFullscreenExit)
        XCTAssertEqual(successfulExit.handle(.willExit), .none)
        XCTAssertEqual(successfulExit.handle(.didExit), .completeTeardown)
        XCTAssertEqual(successfulExit.phase, .windowed)

        var entering = StreamWindowTeardownStateMachine()
        XCTAssertEqual(entering.handle(.requestEnter), .none)
        XCTAssertEqual(entering.handle(.beginTeardown), .none)
        XCTAssertEqual(entering.handle(.willEnter), .none)
        XCTAssertEqual(entering.handle(.didEnter), .requestFullscreenExit)
        XCTAssertEqual(entering.handle(.didExit), .completeTeardown)

        var failedEntry = StreamWindowTeardownStateMachine()
        XCTAssertEqual(failedEntry.handle(.requestEnter), .none)
        XCTAssertEqual(failedEntry.handle(.beginTeardown), .none)
        XCTAssertEqual(failedEntry.handle(.willEnter), .none)
        XCTAssertEqual(failedEntry.handle(.didFailEnter), .completeTeardown)

        var missedEntryCompletion = StreamWindowTeardownStateMachine()
        XCTAssertEqual(missedEntryCompletion.handle(.requestEnter), .none)
        XCTAssertEqual(missedEntryCompletion.handle(.beginTeardown), .none)
        XCTAssertEqual(
            missedEntryCompletion.reconcile(isWindowFullscreen: true),
            .requestFullscreenExit
        )

        var missedExitCompletion = StreamWindowTeardownStateMachine()
        XCTAssertEqual(missedExitCompletion.handle(.requestEnter), .none)
        XCTAssertEqual(missedExitCompletion.handle(.didEnter), .none)
        XCTAssertEqual(missedExitCompletion.handle(.beginTeardown), .requestFullscreenExit)
        XCTAssertEqual(missedExitCompletion.handle(.requestExit), .none)
        XCTAssertEqual(
            missedExitCompletion.reconcile(isWindowFullscreen: false),
            .completeTeardown
        )
    }

    func testFullscreenCallbackStateSurvivesSynchronousAppKitNotificationOrdering() {
        var transition = StreamWindowTeardownStateMachine()

        XCTAssertEqual(transition.handle(.willEnter), .none)
        XCTAssertTrue(transition.hasObservedWillEnter)
        XCTAssertEqual(transition.handle(.requestEnter), .none)
        XCTAssertTrue(
            transition.hasObservedWillEnter,
            "A request callback delivered after AppKit's synchronous will-enter notification must not erase it."
        )
        XCTAssertTrue(StreamFullscreenCallbackPolicy.shouldAccept(
            event: .didEnter,
            phase: transition.phase,
            isSessionActive: true,
            hasPendingTeardown: false,
            isWindowFullscreen: true,
            observedWillEnter: transition.hasObservedWillEnter,
            observedWillExit: transition.hasObservedWillExit
        ))
        XCTAssertEqual(transition.handle(.didEnter), .none)

        XCTAssertEqual(transition.handle(.willExit), .none)
        XCTAssertTrue(transition.hasObservedWillExit)
        XCTAssertEqual(transition.handle(.requestExit), .none)
        XCTAssertTrue(
            transition.hasObservedWillExit,
            "A request callback delivered after AppKit's synchronous will-exit notification must not erase it."
        )
        XCTAssertTrue(StreamFullscreenCallbackPolicy.shouldAccept(
            event: .didExit,
            phase: transition.phase,
            isSessionActive: false,
            hasPendingTeardown: true,
            isWindowFullscreen: true,
            observedWillEnter: transition.hasObservedWillEnter,
            observedWillExit: transition.hasObservedWillExit
        ))
    }

    func testPendingTeardownAcceptsExitCompletionWhenWillExitWasMissed() {
        XCTAssertTrue(StreamFullscreenCallbackPolicy.shouldAccept(
            event: .didExit,
            phase: .exiting,
            isSessionActive: false,
            hasPendingTeardown: true,
            isWindowFullscreen: false,
            observedWillEnter: false,
            observedWillExit: false
        ))
    }

    func testQuitSynchronouslyRejectsStaleFullscreenCallbacks() {
        XCTAssertFalse(StreamFullscreenCallbackPolicy.shouldAccept(
            event: .willEnter,
            phase: .entering,
            isSessionActive: true,
            isStopRequested: true,
            hasPendingTeardown: false,
            isWindowFullscreen: false,
            observedWillEnter: false,
            observedWillExit: false
        ))
        XCTAssertFalse(StreamFullscreenCallbackPolicy.shouldAccept(
            event: .didEnter,
            phase: .entering,
            isSessionActive: true,
            isStopRequested: true,
            hasPendingTeardown: false,
            isWindowFullscreen: true,
            observedWillEnter: true,
            observedWillExit: false
        ))
    }


    private func descendants<View: NSView>(
        of root: NSView,
        type: View.Type
    ) -> [View] {
        var matches = (root as? View).map { [$0] } ?? []
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: subview, type: type))
        }
        return matches
    }

    private func makeBootstrap(
        windowMode: UmbraCore.WindowMode = .windowed
    ) throws -> StreamBootstrap {
        StreamBootstrap(
            sessionID: UUID(),
            host: StreamHost(uuid: "host", name: "Host"),
            application: StreamApplication(id: 1, name: "Game"),
            preferences: StreamingPreferences(
                keepAwake: false,
                windowMode: windowMode
            ),
            rtspSessionURL: nil,
            remoteInputCredentials: try RemoteInputCredentials(
                key: Data(repeating: 1, count: 16),
                initializationVector: Data(repeating: 2, count: 16)
            )
        )
    }

    private func makeDecodedFrame(frameNumber: Int) throws -> DecodedVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return DecodedVideoFrame(
            imageBuffer: try XCTUnwrap(pixelBuffer),
            presentationTime: CMTime(value: 1, timescale: 60),
            frameNumber: frameNumber
        )
    }
}

private final class RecordingPlatformInputSink: PlatformInputPacketSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPackets: [PlatformInputPacket] = []
    var packets: [PlatformInputPacket] { lock.withLock { storedPackets } }

    func platformInputDidProduce(_ packet: PlatformInputPacket) {
        lock.withLock { storedPackets.append(packet) }
    }
}

@MainActor
private final class RecordingStreamWindowModeDriver: WindowModeDriving {
    weak var window: NSWindow?
    var presentation: WindowPresentation = .windowed
    private(set) var nativeFullscreenEntryCount = 0
    private(set) var dismissalResetCount = 0
    private(set) var windowWasVisibleAtNativeEntry: [Bool] = []

    init(window: NSWindow) {
        self.window = window
    }

    func resetWindowedAfterDismissal() {
        dismissalResetCount += 1
        presentation = .windowed
        window?.orderOut(nil)
    }

    func enterWindowed() {
        presentation = .windowed
    }

    func enterBorderlessFullscreen(
        on screen: NSScreen?,
        geometry: BorderlessFullscreenGeometry
    ) {
        presentation = .borderlessFullscreen
    }

    func enterNativeFullscreen() {
        nativeFullscreenEntryCount += 1
        windowWasVisibleAtNativeEntry.append(window?.isVisible == true)
        presentation = .nativeFullscreen
    }
}
