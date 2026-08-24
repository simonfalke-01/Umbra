import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import UmbraMedia
import XCTest
@testable import UmbraApp

@MainActor
final class NativeVideoRendererRouterTests: XCTestCase {
    func testWindowDerivedPixelDimensionsAreEvenBeforeNegotiation() {
        XCTAssertEqual(StreamWindowController.evenPixelDimension(1_291), 1_290)
        XCTAssertEqual(StreamWindowController.evenPixelDimension(1_280), 1_280)
        XCTAssertEqual(StreamWindowController.evenPixelDimension(255), 256)
    }

    func testMetalModeRoutesFrameOnlyToMetalRenderer() throws {
        let metal = RecordingVideoRenderer()
        let sampleBuffer = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: metal,
            sampleBuffer: sampleBuffer,
            setSampleBufferHidden: { _ in }
        )
        prepareAndActivate(router, mode: .metal)

        router.enqueue(try makeFrame())

        XCTAssertEqual(metal.frameCount, 1)
        XCTAssertEqual(sampleBuffer.frameCount, 0)
    }

    func testRouterReportsTheActualDecodedFrameSize() async throws {
        let renderer = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: renderer,
            sampleBuffer: RecordingVideoRenderer(),
            setSampleBufferHidden: { _ in }
        )
        let reported = expectation(description: "Current-session decoded frame size reported")
        let sizes = LockedValues<CGSize>()
        router.setVideoSizeHandler { size in
            sizes.append(size)
            reported.fulfill()
        }

        prepareAndActivate(router, mode: .metal)
        router.enqueue(try makeFrame(width: 1_920, height: 1_080))
        prepareAndActivate(router, mode: .metal)
        router.enqueue(try makeFrame(width: 1_280, height: 720))
        await fulfillment(of: [reported], timeout: 1)

        XCTAssertEqual(sizes.values, [CGSize(width: 1_280, height: 720)])
    }

    func testFlushCannotInterleaveDecodedSizeDelivery() async throws {
        let router = NativeVideoRendererRouter(
            metal: RecordingVideoRenderer(),
            sampleBuffer: RecordingVideoRenderer(),
            setSampleBufferHidden: { _ in }
        )
        let handlerStarted = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        let handlerFinished = LockedValues<Bool>()
        let flushObservedFinishedHandler = LockedValues<Bool>()
        router.setVideoSizeHandler { _ in
            handlerStarted.signal()
            releaseHandler.wait()
            handlerFinished.append(true)
        }
        prepareAndActivate(router, mode: .metal)

        DispatchQueue.global(qos: .userInitiated).async {
            handlerStarted.wait()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                releaseHandler.signal()
            }
            router.flush()
            flushObservedFinishedHandler.append(handlerFinished.values == [true])
        }

        router.enqueue(try makeFrame(width: 1_920, height: 1_080))
        for _ in 0..<100 where flushObservedFinishedHandler.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(flushObservedFinishedHandler.values, [true])
    }

    func testSampleBufferModeRoutesFrameOnlyToSampleBufferRenderer() throws {
        let metal = RecordingVideoRenderer()
        let sampleBuffer = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: metal,
            sampleBuffer: sampleBuffer,
            setSampleBufferHidden: { _ in }
        )

        prepareAndActivate(router, mode: .sampleBuffer)
        router.enqueue(try makeFrame())

        XCTAssertEqual(metal.frameCount, 0)
        XCTAssertEqual(sampleBuffer.frameCount, 1)
    }

    func testMetalModeFallsBackToSampleBufferWhenMetalIsUnavailable() throws {
        let sampleBuffer = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: nil,
            sampleBuffer: sampleBuffer,
            setSampleBufferHidden: { _ in }
        )

        prepareAndActivate(router, mode: .metal)
        router.enqueue(try makeFrame())

        XCTAssertEqual(sampleBuffer.frameCount, 1)
    }

    func testFlushFlushesEveryRenderer() {
        let metal = RecordingVideoRenderer()
        let sampleBuffer = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: metal,
            sampleBuffer: sampleBuffer,
            setSampleBufferHidden: { _ in }
        )

        router.flush()

        XCTAssertEqual(metal.flushCount, 1)
        XCTAssertEqual(sampleBuffer.flushCount, 1)
    }

    func testRouterForwardsPresentationProxyReadinessWithoutTreatingDecodeAsReady() {
        let metal = RecordingVideoRenderer()
        let sampleBuffer = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: metal,
            sampleBuffer: sampleBuffer,
            setSampleBufferHidden: { _ in }
        )
        let reportedFrames = LockedValues<Int>()
        router.installFirstPresentationProxyHandler { reportedFrames.append($0) }

        XCTAssertTrue(reportedFrames.values.isEmpty)
        prepareAndActivate(router, mode: .metal)
        metal.signalPresentationProxy(frameNumber: 41)
        sampleBuffer.signalPresentationProxy(frameNumber: 42)
        prepareAndActivate(router, mode: .sampleBuffer)
        sampleBuffer.signalPresentationProxy(frameNumber: 43)

        XCTAssertEqual(reportedFrames.values, [41, 43])
    }

    func testRouterForwardsTelemetryProfileToEveryBackend() {
        let metal = RecordingVideoRenderer()
        let sampleBuffer = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: metal,
            sampleBuffer: sampleBuffer,
            setSampleBufferHidden: { _ in }
        )

        router.installTelemetryProfile(.quality)
        router.installTelemetryClient(.umbraLegacy)

        XCTAssertEqual(metal.telemetryProfiles, [.quality])
        XCTAssertEqual(sampleBuffer.telemetryProfiles, [.quality])
        XCTAssertEqual(metal.telemetryClients, [.umbraLegacy])
        XCTAssertEqual(sampleBuffer.telemetryClients, [.umbraLegacy])
    }

    @MainActor
    func testSampleBufferVisibilityMatchesEffectiveFallbackMode() async {
        let sampleBuffer = RecordingVideoRenderer()
        let visibilityChanged = expectation(description: "Sample-buffer visibility configured")
        let hiddenValues = LockedValues<Bool>()
        let router = NativeVideoRendererRouter(
            metal: nil,
            sampleBuffer: sampleBuffer,
            setSampleBufferHidden: { hidden in
                hiddenValues.append(hidden)
                visibilityChanged.fulfill()
            }
        )

        prepareAndActivate(router, mode: .metal)
        await fulfillment(of: [visibilityChanged], timeout: 1)

        XCTAssertEqual(hiddenValues.values, [false])
    }

    func testSampleBufferRendererKeepsOnlyLatestFrameUntilLayerIsReady() async throws {
        let driver = ControllableSampleBufferVideoRenderingDriver()
        driver.setReady(false)
        let renderer = SampleBufferVideoRenderer(
            layer: AVSampleBufferDisplayLayer(),
            driver: driver
        )

        renderer.enqueue(try makeFrame(width: 2))
        renderer.enqueue(try makeFrame(width: 4))
        renderer.enqueue(try makeFrame(width: 6))
        try await waitUntil { driver.requestCount == 1 }

        driver.setReady(true)
        driver.signalMediaDataReady()
        try await waitUntil { driver.enqueuedSampleBuffers.count == 1 }

        let imageBuffer = try XCTUnwrap(
            CMSampleBufferGetImageBuffer(driver.enqueuedSampleBuffers[0])
        )
        XCTAssertEqual(CVPixelBufferGetWidth(imageBuffer), 6)
        XCTAssertEqual(driver.requestCount, 1)
    }

    func testLateFramesAfterDeactivationAndFlushNeverReachEitherBackend() throws {
        let metal = RecordingVideoRenderer()
        let sampleBuffer = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: metal,
            sampleBuffer: sampleBuffer,
            setSampleBufferHidden: { _ in }
        )

        prepareAndActivate(router, mode: .metal)
        router.enqueue(try makeFrame(frameNumber: 1))
        router.deactivateSession()
        router.flushDeactivatedBackends()
        router.enqueue(try makeFrame(frameNumber: 2))
        XCTAssertEqual(metal.frameNumbers, [])

        prepareAndActivate(router, mode: .sampleBuffer)
        router.enqueue(try makeFrame(frameNumber: 3))
        router.flush()
        router.enqueue(try makeFrame(frameNumber: 4))
        XCTAssertEqual(sampleBuffer.frameNumbers, [])
        XCTAssertEqual(router.lifecycleSnapshot.rejectedLateFrames, 2)
    }

    func testRejectedLateMetalFrameCannotPolluteFreshRendererStatistics() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let metal = try MetalVideoRenderer(
            layer: CAMetalLayer(),
            device: device,
            configuration: MetalDisplayConfiguration(verticalSyncEnabled: false),
            presentationActive: false
        )
        let router = NativeVideoRendererRouter(
            metal: metal,
            sampleBuffer: RecordingVideoRenderer(),
            setSampleBufferHidden: { _ in }
        )

        let generation = router.prepareSession(mode: .metal)
        router.enqueue(try makeFrame(frameNumber: 76))
        XCTAssertEqual(metal.statistics().droppedFrames, 0)
        metal.setPresentationActive(true)
        await metal.awaitPresentationQuiescence()
        XCTAssertTrue(router.activatePreparedSession(generation: generation))
        router.enqueue(try makeFrame(frameNumber: 77))
        await metal.awaitPresentationQuiescence()

        let statistics = metal.statistics()
        XCTAssertEqual(statistics.queueDepth, 0)
        XCTAssertEqual(statistics.droppedFrames, 0)
        XCTAssertEqual(router.lifecycleSnapshot.rejectedLateFrames, 1)
    }

    func testPreparedGateRejectsIntervalCallbackThenRoutesFirstActiveFrame() throws {
        let metal = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: metal,
            sampleBuffer: RecordingVideoRenderer(),
            setSampleBufferHidden: { _ in }
        )

        let generation = router.prepareSession(mode: .metal)
        router.enqueue(try makeFrame(frameNumber: 40))
        XCTAssertEqual(metal.frameNumbers, [])
        XCTAssertFalse(router.lifecycleSnapshot.isActive)

        XCTAssertTrue(router.activatePreparedSession(generation: generation))
        router.enqueue(try makeFrame(frameNumber: 41))
        XCTAssertEqual(metal.frameNumbers, [41])
        XCTAssertEqual(router.lifecycleSnapshot.rejectedLateFrames, 1)
    }

    func testPresentationCommitCallbacksAreMultiplexedAndGenerationGated() {
        let metal = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: metal,
            sampleBuffer: RecordingVideoRenderer(),
            setSampleBufferHidden: { _ in }
        )
        let mediaCallbacks = LockedValues<Int>()
        let sessionCallbacks = LockedValues<String>()
        router.installFirstPresentationProxyHandler { mediaCallbacks.append($0) }
        router.setSessionPresentationProxyHandler { generation, frameNumber in
            sessionCallbacks.append("\(generation):\(frameNumber)")
        }

        let firstGeneration = prepareAndActivate(router, mode: .metal)
        metal.signalPresentationProxy(frameNumber: 10)
        router.deactivateSession()
        metal.signalPresentationProxy(frameNumber: 11)
        let secondGeneration = prepareAndActivate(router, mode: .metal)
        metal.signalPresentationProxy(frameNumber: 12)

        XCTAssertEqual(mediaCallbacks.values, [10, 12])
        XCTAssertEqual(sessionCallbacks.values, [
            "\(firstGeneration):10",
            "\(secondGeneration):12",
        ])
    }

    func testStopPhaseBackendCallbackIsRejectedWithoutDeadlockOrStatsPollution() throws {
        let routerBox = RouterLockedBox<NativeVideoRendererRouter?>(nil)
        let stopPhaseFrame = try makeFrame(frameNumber: 90)
        let stopPhaseRenderer = FlushCallbackVideoRenderer {
            routerBox.value?.enqueue(stopPhaseFrame)
        }
        let router = NativeVideoRendererRouter(
            metal: stopPhaseRenderer,
            sampleBuffer: RecordingVideoRenderer(),
            setSampleBufferHidden: { _ in }
        )
        routerBox.value = router

        prepareAndActivate(router, mode: .metal)
        router.enqueue(try makeFrame(frameNumber: 1))
        router.flush()

        XCTAssertEqual(stopPhaseRenderer.frameNumbers, [])
        XCTAssertEqual(router.lifecycleSnapshot.rejectedLateFrames, 2)
    }

    func testReopenSameRouterCannotRouteOrReportOldGeneration() async throws {
        let metal = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: metal,
            sampleBuffer: RecordingVideoRenderer(),
            setSampleBufferHidden: { _ in }
        )
        let sizes = LockedValues<CGSize>()
        router.setVideoSizeHandler { sizes.append($0) }

        let firstGeneration = prepareAndActivate(router, mode: .metal)
        router.enqueue(try makeFrame(width: 8, height: 4, frameNumber: 1))
        router.deactivateSession()
        router.flushDeactivatedBackends()
        router.enqueue(try makeFrame(width: 16, height: 9, frameNumber: 2))
        let secondGeneration = prepareAndActivate(router, mode: .metal)
        router.enqueue(try makeFrame(width: 32, height: 18, frameNumber: 3))
        try await waitUntil { sizes.values == [CGSize(width: 32, height: 18)] }

        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        XCTAssertEqual(metal.frameNumbers, [3])
        XCTAssertEqual(router.lifecycleSnapshot.rejectedLateFrames, 1)
    }

    func testPrepareResetsBothBackendsBeforeActivatingGeneration() throws {
        let metal = RecordingVideoRenderer()
        let sampleBuffer = RecordingVideoRenderer()
        let router = NativeVideoRendererRouter(
            metal: metal,
            sampleBuffer: sampleBuffer,
            setSampleBufferHidden: { _ in }
        )

        let firstGeneration = prepareAndActivate(router, mode: .metal)
        router.enqueue(try makeFrame(frameNumber: 1))
        let secondGeneration = prepareAndActivate(router, mode: .sampleBuffer)

        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        XCTAssertEqual(metal.frameNumbers, [])
        XCTAssertEqual(sampleBuffer.frameNumbers, [])
        XCTAssertEqual(metal.flushCount, 2)
        XCTAssertEqual(sampleBuffer.flushCount, 2)
        XCTAssertTrue(router.lifecycleSnapshot.isActive)
    }

    func testSampleBufferFlushCannotRepumpOldPendingFrameAfterReopen() async throws {
        let driver = ControllableSampleBufferVideoRenderingDriver()
        driver.setReady(false)
        let renderer = SampleBufferVideoRenderer(
            layer: AVSampleBufferDisplayLayer(),
            driver: driver
        )

        renderer.enqueue(try makeFrame(width: 2, frameNumber: 1))
        try await waitUntil { driver.requestCount == 1 }
        renderer.flush()
        renderer.enqueue(try makeFrame(width: 4, frameNumber: 2))
        try await waitUntil { driver.flushRemovingImageValues == [true] }
        try await waitUntil { driver.requestCount == 2 }
        driver.setReady(true)
        driver.signalMediaDataReady()
        try await waitUntil { driver.enqueuedSampleBuffers.count == 1 }

        let imageBuffer = try XCTUnwrap(
            CMSampleBufferGetImageBuffer(driver.enqueuedSampleBuffers[0])
        )
        XCTAssertEqual(CVPixelBufferGetWidth(imageBuffer), 4)
    }

    func testSampleBufferRendererReportsAndRecoversFailedLayerBeforeEnqueue() async throws {
        let driver = ControllableSampleBufferVideoRenderingDriver()
        driver.setReady(true)
        driver.setFailure(NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.decoderTemporarilyUnavailable.rawValue
        ))
        let reportedFailures = LockedValues<SampleBufferVideoRenderer.Failure>()
        let renderer = SampleBufferVideoRenderer(
            layer: AVSampleBufferDisplayLayer(),
            driver: driver,
            failureHandler: { reportedFailures.append($0) }
        )

        renderer.enqueue(try makeFrame())
        try await waitUntil { driver.requestCount == 1 }
        driver.signalMediaDataReady()
        try await waitUntil { driver.requestCount == 2 }
        driver.signalMediaDataReady()
        try await waitUntil { driver.enqueuedSampleBuffers.count == 1 }

        XCTAssertEqual(driver.flushRemovingImageValues, [true])
        XCTAssertEqual(reportedFailures.values.count, 1)
        XCTAssertTrue(reportedFailures.values[0].description.contains("failed display layer"))
        XCTAssertEqual(driver.status, .rendering)
    }

    func testSampleBufferRendererReusesMatchingFormatDescription() async throws {
        let driver = ControllableSampleBufferVideoRenderingDriver()
        driver.setReady(true)
        let renderer = SampleBufferVideoRenderer(
            layer: AVSampleBufferDisplayLayer(),
            driver: driver
        )

        renderer.enqueue(try makeFrame(width: 8, height: 4))
        try await waitUntil { driver.requestCount == 1 }
        driver.signalMediaDataReady()
        try await waitUntil { driver.enqueuedSampleBuffers.count == 1 }
        renderer.enqueue(try makeFrame(width: 8, height: 4))
        driver.signalMediaDataReady()
        try await waitUntil { driver.enqueuedSampleBuffers.count == 2 }

        let first = try XCTUnwrap(
            CMSampleBufferGetFormatDescription(driver.enqueuedSampleBuffers[0])
        )
        let second = try XCTUnwrap(
            CMSampleBufferGetFormatDescription(driver.enqueuedSampleBuffers[1])
        )
        XCTAssertTrue(first === second)
    }

    func testSampleBufferFallbackUsesExplicitSystemClockLatestFramePolicy() {
        XCTAssertEqual(
            SampleBufferVideoRenderer.pacingPolicy,
            .systemDisplayClockLatestFrame
        )
    }

    @discardableResult
    private func prepareAndActivate(
        _ router: NativeVideoRendererRouter,
        mode: NativeVideoRendererRouter.Mode
    ) -> UInt64 {
        let generation = router.prepareSession(mode: mode)
        XCTAssertTrue(router.activatePreparedSession(generation: generation))
        return generation
    }

    private func makeFrame(
        width: Int = 2,
        height: Int = 2,
        frameNumber: Int = 0
    ) throws -> DecodedVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return DecodedVideoFrame(
            imageBuffer: try XCTUnwrap(pixelBuffer),
            presentationTime: CMTime(value: 1, timescale: 60),
            frameNumber: frameNumber
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not satisfied before the timeout")
        throw SampleBufferTestTimeout()
    }
}

private final class RecordingVideoRenderer: MetalVideoRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [DecodedVideoFrame] = []
    private var flushes = 0
    private var presentationProxyHandler: @Sendable (Int) -> Void = { _ in }
    private var installedTelemetryProfiles: [StreamingTelemetryProfile] = []
    private var installedTelemetryClients: [StreamingTelemetryClient] = []

    var frameCount: Int { lock.withLock { frames.count } }
    var frameNumbers: [Int] { lock.withLock { frames.map(\.frameNumber) } }
    var flushCount: Int { lock.withLock { flushes } }
    var telemetryProfiles: [StreamingTelemetryProfile] { lock.withLock { installedTelemetryProfiles } }
    var telemetryClients: [StreamingTelemetryClient] { lock.withLock { installedTelemetryClients } }

    func enqueue(_ frame: DecodedVideoFrame) {
        lock.withLock { frames.append(frame) }
    }

    func flush() {
        lock.withLock {
            flushes += 1
            frames.removeAll()
        }
    }

    func installFirstPresentationProxyHandler(
        _ handler: @escaping @Sendable (Int) -> Void
    ) {
        lock.withLock { presentationProxyHandler = handler }
    }

    func signalPresentationProxy(frameNumber: Int) {
        let handler = lock.withLock { presentationProxyHandler }
        handler(frameNumber)
    }

    func installTelemetryProfile(_ profile: StreamingTelemetryProfile) {
        lock.withLock { installedTelemetryProfiles.append(profile) }
    }

    func installTelemetryClient(_ client: StreamingTelemetryClient) {
        lock.withLock { installedTelemetryClients.append(client) }
    }
}

private final class FlushCallbackVideoRenderer: MetalVideoRendering, @unchecked Sendable {
    private let lock = NSLock()
    private let onFlush: @Sendable () -> Void
    private var frames: [DecodedVideoFrame] = []

    init(onFlush: @escaping @Sendable () -> Void) {
        self.onFlush = onFlush
    }

    var frameNumbers: [Int] { lock.withLock { frames.map(\.frameNumber) } }

    func enqueue(_ frame: DecodedVideoFrame) {
        lock.withLock { frames.append(frame) }
    }

    func flush() {
        lock.withLock { frames.removeAll() }
        onFlush()
    }
}

private final class RouterLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] { lock.withLock { storage } }
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
}

private struct SampleBufferTestTimeout: Error {}

private final class ControllableSampleBufferVideoRenderingDriver:
    SampleBufferVideoRenderingDriver,
    @unchecked Sendable
{
    private struct State {
        var status: AVQueuedSampleBufferRenderingStatus = .unknown
        var error: (any Error)?
        var isReady = false
        var requestQueue: DispatchQueue?
        var requestBlock: (@Sendable () -> Void)?
        var requests = 0
        var enqueuedSampleBuffers: [CMSampleBuffer] = []
        var flushRemovingImageValues: [Bool] = []
    }

    private let lock = NSLock()
    private var state = State()

    var status: AVQueuedSampleBufferRenderingStatus {
        lock.withLock { state.status }
    }

    var error: (any Error)? {
        lock.withLock { state.error }
    }

    var isReadyForMoreMediaData: Bool {
        lock.withLock { state.isReady }
    }

    var requestCount: Int {
        lock.withLock { state.requests }
    }

    var enqueuedSampleBuffers: [CMSampleBuffer] {
        lock.withLock { state.enqueuedSampleBuffers }
    }

    var flushRemovingImageValues: [Bool] {
        lock.withLock { state.flushRemovingImageValues }
    }

    func setReady(_ isReady: Bool) {
        lock.withLock { state.isReady = isReady }
    }

    func setFailure(_ error: any Error) {
        lock.withLock {
            state.status = .failed
            state.error = error
        }
    }

    func signalMediaDataReady() {
        let callback = lock.withLock { (state.requestQueue, state.requestBlock) }
        guard let queue = callback.0, let block = callback.1 else { return }
        queue.async(execute: block)
    }

    func requestMediaDataWhenReady(
        on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            state.requestQueue = queue
            state.requestBlock = block
            state.requests += 1
        }
    }

    func stopRequestingMediaData() {
        lock.withLock {
            state.requestQueue = nil
            state.requestBlock = nil
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            state.status = .rendering
            state.enqueuedSampleBuffers.append(sampleBuffer)
        }
    }

    func flush(
        removingDisplayedImage: Bool,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            state.status = .unknown
            state.error = nil
            state.flushRemovingImageValues.append(removingDisplayedImage)
        }
        completionHandler()
    }
}
