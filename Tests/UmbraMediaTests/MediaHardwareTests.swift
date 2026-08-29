import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import VideoToolbox
import XCTest
@testable import UmbraMedia

final class MediaHardwareTests: XCTestCase {
    func testColdYUV444CapabilityProbeIsExactAndStable() {
        let first = AppleStreamingCapabilities.probe().supportedHardwareYUV444FormatMask
        let second = AppleStreamingCapabilities.probe().supportedHardwareYUV444FormatMask
        XCTAssertEqual(first, second)
        XCTAssertEqual(first & ~VideoCodecProfile.yuv444Mask, 0)
    }

    func testQualityDecoderInFlightLimiterBackpressuresDelayed120FPSInput() {
        let limiter = VideoDecodeInFlightLimiter(maximumCount: 5)
        limiter.start()
        for expectedDepth in 1...5 {
            XCTAssertEqual(limiter.acquire(), expectedDepth)
        }

        let sixthFrameAdmitted = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            if limiter.acquire() != nil {
                sixthFrameAdmitted.signal()
            }
        }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.125) {
            limiter.release()
        }

        XCTAssertEqual(
            sixthFrameAdmitted.wait(timeout: .now() + 0.050),
            .timedOut,
            "A sixth frame must wait instead of creating a hidden VideoToolbox backlog"
        )
        XCTAssertEqual(sixthFrameAdmitted.wait(timeout: .now() + 0.500), .success)
        XCTAssertEqual(limiter.snapshot.maximumObservedCount, 5)
        XCTAssertEqual(
            limiter.snapshot.outstandingCount,
            5,
            "This limiter bounds only Swift/VideoToolbox submissions; Moonlight has a separate queue."
        )
        limiter.stop()
    }

    func testLatencyDecoderInFlightLimiterReportsFullWithoutBlockingAtMaximumDepth() {
        let limiter = VideoDecodeInFlightLimiter(maximumCount: 4)
        limiter.start()
        XCTAssertEqual(limiter.admit(using: .dropNewestWhenFull), .admitted(depth: 1))
        XCTAssertEqual(limiter.admit(using: .dropNewestWhenFull), .admitted(depth: 2))
        XCTAssertEqual(limiter.admit(using: .dropNewestWhenFull), .admitted(depth: 3))
        XCTAssertEqual(limiter.admit(using: .dropNewestWhenFull), .admitted(depth: 4))

        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(limiter.admit(using: .dropNewestWhenFull), .full(depth: 4))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.050)
        XCTAssertEqual(
            limiter.snapshot,
            VideoDecodeInFlightLimiter.Snapshot(outstandingCount: 4, maximumObservedCount: 4)
        )
        XCTAssertEqual(limiter.release(), 3)
        XCTAssertEqual(limiter.admit(using: .dropNewestWhenFull), .admitted(depth: 4))
        limiter.stop()
    }

    func testDecoderInFlightLimiterShutdownInterruptsBackpressureWait() {
        let limiter = VideoDecodeInFlightLimiter(maximumCount: 1)
        limiter.start()
        XCTAssertEqual(limiter.acquire(), 1)

        let interrupted = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            if limiter.acquire() == nil {
                interrupted.signal()
            }
        }
        limiter.stop()

        XCTAssertEqual(interrupted.wait(timeout: .now() + 0.500), .success)
    }

    func testQualityDecoderStoppedWaiterIsDiscardedWithoutRequestingKeyframe() throws {
        let limiter = VideoDecodeInFlightLimiter(maximumCount: 1)
        let decoder = VideoToolboxDecoder(
            policy: .softwareOnly,
            capacityPolicy: .waitWhenFull,
            inFlightLimiter: limiter
        )
        XCTAssertTrue(decoder.configure(format: VideoStreamFormat(
            codecMask: 0x0001,
            width: 1_280,
            height: 720,
            redrawRate: 60
        )))
        decoder.start()
        let generation = decoder.currentDecodeGeneration
        XCTAssertEqual(limiter.acquire(generation: generation), 1)

        let disposition = MediaHardwareLockedBox<VideoFrameDisposition?>(nil)
        let submissionFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            disposition.value = decoder.submit(frame: CompressedVideoFrame(
                data: Data([0, 0, 0, 1, 0x65, 0x88]),
                frameNumber: 1,
                isKeyFrame: true,
                presentationTimeMicroseconds: 0
            ))
            submissionFinished.signal()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 0.500
        while limiter.snapshot.waitingCount == 0,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(limiter.snapshot.waitingCount, 1)

        decoder.stop()
        XCTAssertEqual(submissionFinished.wait(timeout: .now() + 0.500), .success)
        XCTAssertEqual(disposition.value, .accepted)
        XCTAssertEqual(decoder.statistics(at: 1).decoderErrors, 0)
    }

    func testStaleLimiterReleaseCannotDecrementReopenedGeneration() {
        let limiter = VideoDecodeInFlightLimiter(maximumCount: 1)
        limiter.start(generation: 11)
        XCTAssertEqual(limiter.acquire(generation: 11), 1)
        limiter.stop(generation: 11)

        limiter.start(generation: 12)
        XCTAssertEqual(limiter.acquire(generation: 12), 1)
        XCTAssertNil(limiter.release(generation: 11))
        XCTAssertEqual(limiter.snapshot.outstandingCount, 1)
        XCTAssertEqual(limiter.release(generation: 12), 0)
    }

    func testStaleDecodeCompletionCannotCorruptReopenedLimiterOrTelemetry() throws {
        let limiter = VideoDecodeInFlightLimiter(maximumCount: 1)
        let decoder = VideoToolboxDecoder(
            policy: .softwareOnly,
            inFlightLimiter: limiter
        )
        XCTAssertTrue(decoder.configure(format: VideoStreamFormat(
            codecMask: 0x0001,
            width: 1_280,
            height: 720,
            redrawRate: 60
        )))
        decoder.start()
        let oldGeneration = decoder.currentDecodeGeneration
        XCTAssertEqual(limiter.acquire(generation: oldGeneration), 1)

        decoder.stop()
        decoder.start()
        let reopenedGeneration = decoder.currentDecodeGeneration
        XCTAssertNotEqual(reopenedGeneration, oldGeneration)
        XCTAssertEqual(limiter.acquire(generation: reopenedGeneration), 1)

        decoder.recordAsynchronousDecodeFailure(
            .decodeFailed(-12_345),
            generation: oldGeneration,
            at: 1
        )
        XCTAssertEqual(limiter.snapshot.outstandingCount, 1)
        XCTAssertNil(decoder.lastError)
        XCTAssertEqual(decoder.statistics(at: 1).decoderErrors, 0)
        XCTAssertEqual(limiter.release(generation: reopenedGeneration), 0)
        decoder.stop()
    }

    func testLatencyCapacityOverflowRecordsRecoveryAndRequestsKeyframe() throws {
        let decoder = VideoToolboxDecoder(
            policy: .softwareOnly,
            capacityPolicy: .dropNewestWhenFull
        )
        XCTAssertTrue(decoder.configure(format: VideoStreamFormat(
            codecMask: 0x0001,
            width: 1_280,
            height: 720,
            redrawRate: 60
        )))
        decoder.start()

        let disposition = decoder.recordCapacityOverflow(
            depth: 2,
            generation: decoder.currentDecodeGeneration,
            at: 1
        )
        let statistics = decoder.statistics(at: 1)

        XCTAssertEqual(disposition, .requestKeyFrame)
        XCTAssertEqual(statistics.submittedFrames, 1)
        XCTAssertEqual(statistics.droppedFrames, 1)
        XCTAssertEqual(statistics.decoderErrors, 1)
        XCTAssertEqual(statistics.queueDepth, 2)
        XCTAssertEqual(decoder.lastError, .queueFull)

        let dependentFrameDisposition = decoder.submit(frame: CompressedVideoFrame(
            data: Data([0, 0, 0, 1, 0x41, 0x88]),
            frameNumber: 2,
            isKeyFrame: false,
            presentationTimeMicroseconds: 16_667
        ))
        XCTAssertEqual(dependentFrameDisposition, .requestKeyFrame)
        XCTAssertEqual(decoder.lastError, .missingParameterSets(.h264))
        decoder.stop()
    }

    func testStopBetweenAdmissionAndEnqueueCancelsOldGenerationBeforeReopen() throws {
        let reachedBoundary = DispatchSemaphore(value: 0)
        let resumeSubmission = DispatchSemaphore(value: 0)
        let limiter = VideoDecodeInFlightLimiter(maximumCount: 1)
        let decoder = VideoToolboxDecoder(
            policy: .softwareOnly,
            capacityPolicy: .dropNewestWhenFull,
            submissionBoundaryHandler: {
                reachedBoundary.signal()
                resumeSubmission.wait()
            },
            inFlightLimiter: limiter
        )
        XCTAssertTrue(decoder.configure(format: VideoStreamFormat(
            codecMask: 0x0001,
            width: 1_280,
            height: 720,
            redrawRate: 60
        )))
        decoder.start()
        let disposition = MediaHardwareLockedBox<VideoFrameDisposition?>(nil)
        let submissionFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            disposition.value = decoder.submit(frame: CompressedVideoFrame(
                data: Data([0, 0, 0, 1, 0x65, 0x88]),
                frameNumber: 1,
                isKeyFrame: true,
                presentationTimeMicroseconds: 0
            ))
            submissionFinished.signal()
        }
        XCTAssertEqual(reachedBoundary.wait(timeout: .now() + 0.500), .success)

        let stopFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            decoder.stop()
            stopFinished.signal()
        }
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 0.500), .success)
        decoder.start()
        XCTAssertEqual(limiter.snapshot.outstandingCount, 0)

        resumeSubmission.signal()
        XCTAssertEqual(submissionFinished.wait(timeout: .now() + 0.500), .success)
        XCTAssertEqual(disposition.value, .accepted)
        XCTAssertEqual(
            limiter.snapshot.outstandingCount,
            0,
            "The stale release must not consume a token from the reopened generation."
        )
        decoder.stop()
    }

    func testInitialKeyframeSetupFailureRequestsRecoverySynchronously() throws {
        let decoder = VideoToolboxDecoder(policy: .softwareOnly)
        XCTAssertTrue(decoder.configure(format: VideoStreamFormat(
            codecMask: 0x0001,
            width: 1_280,
            height: 720,
            redrawRate: 60
        )))
        decoder.start()

        let disposition = decoder.submit(frame: CompressedVideoFrame(
            data: Data([0, 0, 0, 1, 0x65, 0x88]),
            frameNumber: 1,
            isKeyFrame: true,
            presentationTimeMicroseconds: 0
        ))

        XCTAssertEqual(disposition.rawValue, VideoFrameDisposition.requestKeyFrame.rawValue)
        XCTAssertEqual(decoder.lastError, .missingParameterSets(.h264))
    }

    func testAsynchronousDecodeFailureRequiresANewKeyframe() throws {
        let decoder = VideoToolboxDecoder(policy: .softwareOnly)
        XCTAssertTrue(decoder.configure(format: VideoStreamFormat(
            codecMask: 0x0001,
            width: 1_280,
            height: 720,
            redrawRate: 60
        )))
        decoder.start()
        decoder.recordAsynchronousDecodeFailure(.decodeFailed(-12_345), at: 1)

        let disposition = decoder.submit(frame: CompressedVideoFrame(
            data: Data([0, 0, 0, 1, 0x41, 0x88]),
            frameNumber: 2,
            isKeyFrame: false,
            presentationTimeMicroseconds: 16_667
        ))

        XCTAssertEqual(disposition.rawValue, VideoFrameDisposition.requestKeyFrame.rawValue)
        XCTAssertEqual(decoder.lastError, .missingParameterSets(.h264))
    }

    func testOutOfOrderSuccessfulCallbacksCannotPrematurelyClearKeyframeRecovery() {
        var recovery = VideoDecodeRecoveryGate()
        recovery.resetForLifecycle()
        let oldKeyframeEpoch = recovery.submissionEpoch
        let laterPFrameEpoch = recovery.submissionEpoch

        recovery.requireRecovery()
        recovery.recordSuccessfulDecode(
            isKeyFrame: false,
            frameSessionGeneration: 4,
            currentSessionGeneration: 4,
            frameRecoveryEpoch: laterPFrameEpoch
        )
        XCTAssertTrue(
            recovery.isRequired,
            "The later failing P-frame's successful neighbors cannot clear recovery."
        )

        recovery.recordSuccessfulDecode(
            isKeyFrame: true,
            frameSessionGeneration: 4,
            currentSessionGeneration: 4,
            frameRecoveryEpoch: oldKeyframeEpoch
        )
        XCTAssertTrue(
            recovery.isRequired,
            "A keyframe submitted before the later P-frame failure must not clear recovery."
        )

        let postFailureKeyframeEpoch = recovery.submissionEpoch
        recovery.recordSuccessfulDecode(
            isKeyFrame: true,
            frameSessionGeneration: 3,
            currentSessionGeneration: 4,
            frameRecoveryEpoch: postFailureKeyframeEpoch
        )
        XCTAssertTrue(recovery.isRequired, "A keyframe from an obsolete session must not clear recovery.")

        recovery.recordSuccessfulDecode(
            isKeyFrame: true,
            frameSessionGeneration: 4,
            currentSessionGeneration: 4,
            frameRecoveryEpoch: postFailureKeyframeEpoch
        )
        XCTAssertFalse(
            recovery.isRequired,
            "Only a keyframe submitted in the current recovery epoch may clear recovery."
        )
    }

    func testAV1RecoveryRecreatesSessionForUnchangedConfiguration() {
        let configuration = Data([0x81, 0x08, 0x0C, 0x00])

        XCTAssertTrue(VideoToolboxDecoder.shouldRecreateAV1Session(
            hasSession: true,
            requiresRecovery: true,
            priorConfiguration: configuration,
            nextConfiguration: configuration
        ))
        XCTAssertFalse(VideoToolboxDecoder.shouldRecreateAV1Session(
            hasSession: true,
            requiresRecovery: false,
            priorConfiguration: configuration,
            nextConfiguration: configuration
        ))
    }

    func testMetalRendererCompilesShaderLibraryOnAvailableDevice() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 64, height: 64)
        let renderer = try MetalVideoRenderer(layer: layer, device: device)
        XCTAssertNil(renderer.lastError)
        XCTAssertEqual(layer.maximumDrawableCount, 2)
        XCTAssertTrue(layer.allowsNextDrawableTimeout)
        XCTAssertFalse(layer.presentsWithTransaction)
        XCTAssertTrue(layer.displaySyncEnabled)
        #if arch(arm64)
        let timing = try XCTUnwrap(renderer.displayLinkTiming)
        XCTAssertEqual(timing.frameLatency, 1)
        XCTAssertEqual(timing.frameRateRange.minimum, 60)
        XCTAssertEqual(timing.frameRateRange.maximum, 60)
        XCTAssertEqual(timing.frameRateRange.preferred, 60)
        #endif
        renderer.flush()
    }

    func testMetalRendererVSyncToggleFlushAndTeardownKeepOnePresentationClock() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 64, height: 64)
        var renderer: MetalVideoRenderer? = try MetalVideoRenderer(
            layer: layer,
            device: device,
            pacingConfiguration: FramePacingConfiguration(
                nominalFramesPerSecond: 144,
                displayRefreshRate: 120
            )
        )

        #if arch(arm64)
        XCTAssertTrue(try XCTUnwrap(renderer).usesDisplayLinkPresentation)
        var timing = try XCTUnwrap(try XCTUnwrap(renderer).displayLinkTiming)
        XCTAssertEqual(timing.frameLatency, 1)
        XCTAssertEqual(timing.frameRateRange.minimum, 120)
        XCTAssertEqual(timing.frameRateRange.maximum, 120)
        XCTAssertEqual(timing.frameRateRange.preferred, 120)
        #endif

        try XCTUnwrap(renderer).updateDisplayConfiguration(MetalDisplayConfiguration(
            verticalSyncEnabled: false
        ))
        XCTAssertFalse(try XCTUnwrap(renderer).usesDisplayLinkPresentation)
        XCTAssertNil(try XCTUnwrap(renderer).displayLinkTiming)
        try XCTUnwrap(renderer).flush()

        try XCTUnwrap(renderer).updatePacingConfiguration(FramePacingConfiguration(
            nominalFramesPerSecond: 60,
            displayRefreshRate: 120
        ))
        try XCTUnwrap(renderer).updateDisplayConfiguration(MetalDisplayConfiguration(
            verticalSyncEnabled: true
        ))
        #if arch(arm64)
        XCTAssertTrue(try XCTUnwrap(renderer).usesDisplayLinkPresentation)
        timing = try XCTUnwrap(try XCTUnwrap(renderer).displayLinkTiming)
        XCTAssertEqual(timing.frameLatency, 1)
        XCTAssertEqual(timing.frameRateRange.minimum, 60)
        XCTAssertEqual(timing.frameRateRange.maximum, 120)
        XCTAssertEqual(timing.frameRateRange.preferred, 60)
        #endif

        try XCTUnwrap(renderer).flush()
        let flushedRenderer = try XCTUnwrap(renderer)
        await flushedRenderer.awaitPresentationQuiescence()
        #if arch(arm64)
        XCTAssertTrue(try XCTUnwrap(renderer).usesDisplayLinkPresentation)
        #endif
        renderer = nil
    }

    func testBlockedEncodeCannotOverlapOrCommitAcrossFinishAndReopen() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 64, height: 64)
        let renderer = try MetalVideoRenderer(
            layer: layer,
            device: device,
            configuration: MetalDisplayConfiguration(verticalSyncEnabled: false)
        )
        let enteredDrawableBarrier = DispatchSemaphore(value: 0)
        let releaseDrawableBarrier = DispatchSemaphore(value: 0)
        let state = MediaHardwareLockedBox(MetalRendererHookState())
        renderer.setTestingHooks(MetalRendererTestingHooks(
            didBeginEncode: { frameNumber in
                state.withValue {
                    $0.activeEncodes += 1
                    $0.maximumActiveEncodes = max($0.maximumActiveEncodes, $0.activeEncodes)
                    $0.begunFrames.append(frameNumber)
                }
            },
            beforeDrawableAcquisition: { frameNumber in
                guard frameNumber == 1 else { return }
                enteredDrawableBarrier.signal()
                releaseDrawableBarrier.wait()
            },
            didCommit: { frameNumber in
                state.withValue { $0.committedFrames.append(frameNumber) }
            },
            didEndEncode: { _ in
                state.withValue { $0.activeEncodes -= 1 }
            }
        ))

        renderer.enqueue(try makeMetalFrame(frameNumber: 1, color: .rec709SDR))
        XCTAssertEqual(enteredDrawableBarrier.wait(timeout: .now() + 1), .success)

        renderer.setPresentationActive(false)
        renderer.setPresentationActive(true)
        renderer.enqueue(try makeMetalFrame(frameNumber: 2, color: .rec2020HDR10))
        XCTAssertEqual(state.value.begunFrames, [1], "The reopened path must not overlap old CPU encoding.")

        releaseDrawableBarrier.signal()
        await renderer.awaitPresentationQuiescence()

        let snapshot = state.value
        XCTAssertEqual(snapshot.maximumActiveEncodes, 1)
        XCTAssertEqual(snapshot.begunFrames, [1, 2])
        XCTAssertFalse(snapshot.committedFrames.contains(1))
    }

    func testImmediatePresentationRunsOnDedicatedUserInteractiveExecutor() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 64, height: 64)
        let renderer = try MetalVideoRenderer(
            layer: layer,
            device: device,
            configuration: MetalDisplayConfiguration(verticalSyncEnabled: false)
        )
        let executorThread = MediaHardwareLockedBox<(name: String?, isMain: Bool)?>(nil)
        renderer.setTestingHooks(MetalRendererTestingHooks(
            beforeDrawableAcquisition: { _ in
                executorThread.value = (Thread.current.name, Thread.isMainThread)
            }
        ))

        renderer.enqueue(try makeMetalFrame(frameNumber: 3, color: .rec709SDR))
        await renderer.awaitPresentationQuiescence()

        let thread = try XCTUnwrap(executorThread.value)
        XCTAssertEqual(thread.name, "UmbraMetalPresentation")
        XCTAssertFalse(thread.isMain)
    }

    func testBlockedEncodeIsRejectedByFlushAndVSyncToggle() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 64, height: 64)
        let renderer = try MetalVideoRenderer(
            layer: layer,
            device: device,
            configuration: MetalDisplayConfiguration(verticalSyncEnabled: false)
        )
        let enteredDrawableBarrier = DispatchSemaphore(value: 0)
        let releaseDrawableBarrier = DispatchSemaphore(value: 0)
        let committedFrames = MediaHardwareLockedBox<[Int]>([])
        renderer.setTestingHooks(MetalRendererTestingHooks(
            beforeDrawableAcquisition: { frameNumber in
                guard frameNumber == 10 else { return }
                enteredDrawableBarrier.signal()
                releaseDrawableBarrier.wait()
            },
            didCommit: { frameNumber in
                committedFrames.withValue { $0.append(frameNumber) }
            }
        ))

        renderer.enqueue(try makeMetalFrame(frameNumber: 10, color: .rec709SDR))
        XCTAssertEqual(enteredDrawableBarrier.wait(timeout: .now() + 1), .success)
        renderer.flush()
        renderer.updateDisplayConfiguration(MetalDisplayConfiguration(verticalSyncEnabled: true))
        releaseDrawableBarrier.signal()
        await renderer.awaitPresentationQuiescence()

        XCTAssertFalse(committedFrames.value.contains(10))
    }

    func testBlockedDrawableAppliesSDRAndHDRTransitionsBeforeAcquisition() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 64, height: 64)
        let renderer = try MetalVideoRenderer(
            layer: layer,
            device: device,
            configuration: MetalDisplayConfiguration(verticalSyncEnabled: false)
        )
        let enteredSDRBarrier = DispatchSemaphore(value: 0)
        let releaseSDRBarrier = DispatchSemaphore(value: 0)
        let enteredHDRBarrier = DispatchSemaphore(value: 0)
        let releaseHDRBarrier = DispatchSemaphore(value: 0)
        let appliedColors = MediaHardwareLockedBox<[VideoColorMetadata]>([])
        let committedFrames = MediaHardwareLockedBox<[Int]>([])
        renderer.setTestingHooks(MetalRendererTestingHooks(
            beforeDrawableAcquisition: { frameNumber in
                switch frameNumber {
                case 20:
                    enteredSDRBarrier.signal()
                    releaseSDRBarrier.wait()
                case 22:
                    enteredHDRBarrier.signal()
                    releaseHDRBarrier.wait()
                default:
                    break
                }
            },
            didCommit: { frameNumber in
                committedFrames.withValue { $0.append(frameNumber) }
            },
            didApplyLayerConfiguration: { color in
                appliedColors.withValue { $0.append(color) }
            }
        ))

        renderer.enqueue(try makeMetalFrame(frameNumber: 20, color: .rec709SDR))
        XCTAssertEqual(enteredSDRBarrier.wait(timeout: .now() + 1), .success)
        renderer.enqueue(try makeMetalFrame(frameNumber: 21, color: .rec2020HDR10))
        releaseSDRBarrier.signal()
        await renderer.awaitPresentationQuiescence()
        XCTAssertEqual(layer.pixelFormat, .rgba16Float)
        XCTAssertFalse(committedFrames.value.contains(20))

        renderer.enqueue(try makeMetalFrame(frameNumber: 22, color: .rec2020HDR10))
        XCTAssertEqual(enteredHDRBarrier.wait(timeout: .now() + 1), .success)
        renderer.enqueue(try makeMetalFrame(frameNumber: 23, color: .rec709SDR))
        releaseHDRBarrier.signal()
        await renderer.awaitPresentationQuiescence()
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm)
        XCTAssertFalse(committedFrames.value.contains(22))
        XCTAssertEqual(appliedColors.value, [.rec709SDR, .rec2020HDR10, .rec709SDR])
    }

    func testMetalHDRLayerUsesExactStaticMetadataAndSystemFallback() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        let renderer = try MetalVideoRenderer(layer: layer, device: device)
        let metadata = HDRStaticMetadata(
            minimumLuminanceNits: 0.005,
            maximumLuminanceNits: 1_000,
            masteringDisplayColorVolume: Data(repeating: 0x2A, count: 24),
            contentLightLevelInfo: Data([0x03, 0xE8, 0x01, 0x90])
        )
        let color = VideoColorMetadata(
            colorSpace: .rec2020,
            range: .full,
            transferFunction: .pq,
            hdrStaticMetadata: metadata
        )
        await renderer.configureLayerForTesting(
            for: color,
            configuration: MetalDisplayConfiguration()
        )

        XCTAssertTrue(layer.wantsExtendedDynamicRangeContent)
        XCTAssertEqual(layer.pixelFormat, .rgba16Float)
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.extendedLinearITUR_2020)
        XCTAssertNotNil(layer.edrMetadata)

        let firstEDRMetadata = try XCTUnwrap(layer.edrMetadata)
        await renderer.configureLayerForTesting(
            for: color,
            configuration: MetalDisplayConfiguration()
        )
        XCTAssertTrue(
            firstEDRMetadata === layer.edrMetadata,
            "Unchanged HDR frames must reuse the applied layer configuration"
        )

        await renderer.configureLayerForTesting(
            for: VideoColorMetadata(
                colorSpace: .rec2020,
                range: .full,
                transferFunction: .pq
            ),
            configuration: MetalDisplayConfiguration()
        )
        XCTAssertNotNil(
            layer.edrMetadata,
            "Metadata-less HDR must still request the system HDR10 tone-mapping defaults."
        )
    }

    func testAV1ConfigurationRecordCreatesHardwareSessionWhenAvailable() throws {
        try XCTSkipUnless(
            VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            "This Mac does not advertise hardware AV1 decoding"
        )
        let accessUnit = try AV1AccessUnit(
            data: Data([
                0x12, 0x00,
                0x0A, 0x10, 0x00, 0x00, 0x00, 0x43, 0xFC, 0x13,
                0xFC, 0x0B, 0x3C, 0x02, 0x4E, 0x88, 0x30, 0x30, 0x30, 0xA0,
            ]),
            profile: VideoCodecProfile(codecMask: 0x1000)
        )
        let format = VideoStreamFormat(
            codecMask: 0x1000,
            width: 1280,
            height: 720,
            redrawRate: 60
        )
        let description = try makeAV1FormatDescription(
            format: format,
            codecConfigurationRecord: accessUnit.codecConfigurationRecord
        )
        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        XCTAssertEqual(status, noErr)
        let createdSession = try XCTUnwrap(session)
        VTDecompressionSessionInvalidate(createdSession)
    }

    func testLatencyAndQualityDecodersConsumePreparedLengthPrefixedFramesAsynchronously() throws {
        let annexBFrame = try makeRealH264AnnexBKeyFrame(width: 64, height: 64)
        let encodedFrame = try AnnexBAccessUnit(
            data: annexBFrame,
            codec: .h264
        ).lengthPrefixedData
        var decodedImages: [Data] = []

        for capacityPolicy in [
            VideoDecodeCapacityPolicy.dropNewestWhenFull,
            .waitWhenFull,
        ] {
            let renderer = RealDecodeRecordingRenderer()
            let decoder = VideoToolboxDecoder(
                renderer: renderer,
                policy: .automatic,
                capacityPolicy: capacityPolicy
            )
            XCTAssertTrue(decoder.configure(format: VideoStreamFormat(
                codecMask: 0x0001,
                width: 64,
                height: 64,
                redrawRate: 60
            )))
            decoder.start()

            XCTAssertEqual(decoder.submit(frame: CompressedVideoFrame(
                data: encodedFrame,
                payloadFormat: .videoToolboxLengthPrefixed,
                frameNumber: 1,
                isKeyFrame: true,
                presentationTimeMicroseconds: 0
            )), .accepted)
            XCTAssertEqual(renderer.decoded.wait(timeout: .now() + 2), .success)
            let frame = try XCTUnwrap(renderer.frame)
            XCTAssertEqual(CVPixelBufferGetWidth(frame.imageBuffer), 64)
            XCTAssertEqual(CVPixelBufferGetHeight(frame.imageBuffer), 64)
            XCTAssertEqual(frame.frameNumber, 1)
            XCTAssertNil(decoder.lastError)
            decodedImages.append(try activeImageBytes(from: frame.imageBuffer))
            decoder.stop()
        }

        XCTAssertEqual(decodedImages.count, 2)
        XCTAssertEqual(decodedImages[0], decodedImages[1])
    }

    private func makeMetalFrame(
        frameNumber: Int,
        color: VideoColorMetadata
    ) throws -> DecodedVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        ), kCVReturnSuccess)
        return DecodedVideoFrame(
            imageBuffer: try XCTUnwrap(pixelBuffer),
            presentationTime: CMTime(value: CMTimeValue(frameNumber), timescale: 120),
            frameNumber: frameNumber,
            color: color
        )
    }
}

private let realH264CompressionOutputCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon, _, status, _, sampleBuffer in
    guard let outputCallbackRefCon else { return }
    let output = Unmanaged<RealH264CompressionOutput>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
    output.record(status: status, sampleBuffer: sampleBuffer)
}

private final class RealH264CompressionOutput: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var storedStatus: OSStatus = noErr
    private var storedSampleBuffer: CMSampleBuffer?

    var status: OSStatus { lock.withLock { storedStatus } }
    var sampleBuffer: CMSampleBuffer? { lock.withLock { storedSampleBuffer } }

    func record(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        lock.withLock {
            storedStatus = status
            storedSampleBuffer = sampleBuffer
        }
        completed.signal()
    }
}

private final class RealDecodeRecordingRenderer: MetalVideoRendering, @unchecked Sendable {
    let decoded = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var storedFrame: DecodedVideoFrame?

    var frame: DecodedVideoFrame? { lock.withLock { storedFrame } }

    func enqueue(_ frame: DecodedVideoFrame) {
        lock.withLock { storedFrame = frame }
        decoded.signal()
    }

    func flush() {}
}

private func makeRealH264AnnexBKeyFrame(width: Int32, height: Int32) throws -> Data {
    let output = RealH264CompressionOutput()
    var compressionSession: VTCompressionSession?
    var status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: width,
        height: height,
        codecType: kCMVideoCodecType_H264,
        encoderSpecification: nil,
        imageBufferAttributes: nil,
        compressedDataAllocator: nil,
        outputCallback: realH264CompressionOutputCallback,
        refcon: Unmanaged.passUnretained(output).toOpaque(),
        compressionSessionOut: &compressionSession
    )
    guard status == noErr, let compressionSession else {
        throw MediaHardwareTestError.compression(status)
    }
    defer { VTCompressionSessionInvalidate(compressionSession) }

    status = VTSessionSetProperty(
        compressionSession,
        key: kVTCompressionPropertyKey_ProfileLevel,
        value: kVTProfileLevel_H264_Baseline_AutoLevel
    )
    guard status == noErr else { throw MediaHardwareTestError.compression(status) }
    status = VTSessionSetProperty(
        compressionSession,
        key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
        value: 1 as CFNumber
    )
    guard status == noErr else { throw MediaHardwareTestError.compression(status) }
    status = VTCompressionSessionPrepareToEncodeFrames(compressionSession)
    guard status == noErr else { throw MediaHardwareTestError.compression(status) }

    var imageBuffer: CVPixelBuffer?
    status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        Int(width),
        Int(height),
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &imageBuffer
    )
    guard status == kCVReturnSuccess, let imageBuffer else {
        throw MediaHardwareTestError.pixelBuffer(status)
    }
    CVPixelBufferLockBaseAddress(imageBuffer, [])
    if let luma = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) {
        memset(luma, 0x40, CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0) * Int(height))
    }
    if let chroma = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1) {
        memset(chroma, 0x80, CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1) * Int(height / 2))
    }
    CVPixelBufferUnlockBaseAddress(imageBuffer, [])

    var infoFlags = VTEncodeInfoFlags()
    status = VTCompressionSessionEncodeFrame(
        compressionSession,
        imageBuffer: imageBuffer,
        presentationTimeStamp: .zero,
        duration: CMTime(value: 1, timescale: 60),
        frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
        sourceFrameRefcon: nil,
        infoFlagsOut: &infoFlags
    )
    guard status == noErr else { throw MediaHardwareTestError.compression(status) }
    status = VTCompressionSessionCompleteFrames(
        compressionSession,
        untilPresentationTimeStamp: .invalid
    )
    guard status == noErr else { throw MediaHardwareTestError.compression(status) }
    guard output.completed.wait(timeout: .now() + 2) == .success else {
        throw MediaHardwareTestError.compressionTimedOut
    }
    guard output.status == noErr, let sampleBuffer = output.sampleBuffer else {
        throw MediaHardwareTestError.compression(output.status)
    }
    return try makeAnnexBKeyFrame(from: sampleBuffer)
}

private func activeImageBytes(from imageBuffer: CVPixelBuffer) throws -> Data {
    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
    guard CVPixelBufferGetPlaneCount(imageBuffer) == 2 else {
        throw MediaHardwareTestError.unexpectedPixelFormat
    }
    var result = Data()
    for plane in 0..<2 {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, plane) else {
            throw MediaHardwareTestError.unexpectedPixelFormat
        }
        let activeByteCount = CVPixelBufferGetWidthOfPlane(imageBuffer, plane)
            * (plane == 0 ? 1 : 2)
        let rowCount = CVPixelBufferGetHeightOfPlane(imageBuffer, plane)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, plane)
        for row in 0..<rowCount {
            result.append(
                baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self),
                count: activeByteCount
            )
        }
    }
    return result
}

private func makeAnnexBKeyFrame(from sampleBuffer: CMSampleBuffer) throws -> Data {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        throw MediaHardwareTestError.missingCompressedSample
    }
    var annexB = Data()
    var parameterSetCount = 0
    var nalUnitHeaderLength: Int32 = 0
    for index in 0..<2 {
        var parameterSet: UnsafePointer<UInt8>?
        var parameterSetSize = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: index,
            parameterSetPointerOut: &parameterSet,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard status == noErr, let parameterSet else {
            throw MediaHardwareTestError.parameterSet(status)
        }
        annexB.append(contentsOf: [0, 0, 0, 1])
        annexB.append(parameterSet, count: parameterSetSize)
    }
    guard parameterSetCount >= 2, nalUnitHeaderLength == 4 else {
        throw MediaHardwareTestError.missingCompressedSample
    }

    let compressedLength = CMBlockBufferGetDataLength(dataBuffer)
    var compressed = Data(count: compressedLength)
    let copyStatus = compressed.withUnsafeMutableBytes { bytes in
        CMBlockBufferCopyDataBytes(
            dataBuffer,
            atOffset: 0,
            dataLength: compressedLength,
            destination: bytes.baseAddress!
        )
    }
    guard copyStatus == noErr else { throw MediaHardwareTestError.compression(copyStatus) }

    try compressed.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            guard offset <= bytes.count - 4 else {
                throw MediaHardwareTestError.missingCompressedSample
            }
            let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian)
            offset += 4
            guard length > 0, length <= bytes.count - offset else {
                throw MediaHardwareTestError.missingCompressedSample
            }
            annexB.append(contentsOf: [0, 0, 0, 1])
            annexB.append(contentsOf: bytes.bindMemory(to: UInt8.self)[offset..<(offset + length)])
            offset += length
        }
    }
    return annexB
}

private enum MediaHardwareTestError: Error {
    case compression(OSStatus)
    case compressionTimedOut
    case missingCompressedSample
    case parameterSet(OSStatus)
    case pixelBuffer(CVReturn)
    case unexpectedPixelFormat
}

private struct MetalRendererHookState {
    var activeEncodes = 0
    var maximumActiveEncodes = 0
    var begunFrames: [Int] = []
    var committedFrames: [Int] = []
}

private final class MediaHardwareLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&storedValue) }
    }
}
