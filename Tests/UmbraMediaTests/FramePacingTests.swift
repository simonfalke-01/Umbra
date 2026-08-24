import XCTest
@testable import UmbraMedia

final class FramePacingTests: XCTestCase {
    func testImmediatePathNeverFutureSchedulesEvenWithStalePacingOverride() {
        var pacer = FramePacingStateMachine(
            configuration: FramePacingConfiguration(
                nominalFramesPerSecond: 60,
                framePacingEnabled: true,
                verticalSyncEnabled: false,
                maximumLateness: 0.050,
                maximumSchedulingLead: 0.100
            )
        )

        XCTAssertEqual(pacer.decision(presentationTime: 0, now: 10), .presentImmediately)
        XCTAssertEqual(
            pacer.decision(presentationTime: 1.0 / 60.0, now: 10.005),
            .presentImmediately
        )
        XCTAssertEqual(pacer.decision(presentationTime: 1, now: 20), .presentImmediately)
    }

    func testDisplayLinkPathDoesNotCreateASecondPresentationClock() {
        var pacer = FramePacingStateMachine(
            configuration: FramePacingConfiguration(
                nominalFramesPerSecond: 120,
                framePacingEnabled: true,
                verticalSyncEnabled: true,
                displayRefreshRate: 120
            )
        )

        XCTAssertEqual(pacer.decision(presentationTime: 0, now: 10), .presentImmediately)
        XCTAssertEqual(
            pacer.decision(presentationTime: 1.0 / 120.0, now: 10.001),
            .presentImmediately
        )
    }

    func testPacingToggleAndResetDoNotChangeImmediateRouting() {
        var pacer = FramePacingStateMachine(
            configuration: FramePacingConfiguration(
                nominalFramesPerSecond: 60,
                framePacingEnabled: true,
                verticalSyncEnabled: false
            )
        )
        pacer.updateConfiguration(FramePacingConfiguration(
            nominalFramesPerSecond: 60,
            framePacingEnabled: false,
            verticalSyncEnabled: false
        ))
        pacer.reset()
        XCTAssertEqual(pacer.decision(presentationTime: 10, now: 100), .presentImmediately)
    }

    func testMetalDisplayLinkUsesExactRangeAt120On120() {
        let range = MetalVideoRenderer.frameRateRange(
            framesPerSecond: 120,
            displayRefreshRate: 120
        )

        XCTAssertEqual(range.minimum, 120)
        XCTAssertEqual(range.maximum, 120)
        XCTAssertEqual(range.preferred, 120)
    }

    func testMetalDisplayLinkClamps144StreamTo120Display() {
        let range = MetalVideoRenderer.frameRateRange(
            framesPerSecond: 144,
            displayRefreshRate: 120
        )

        XCTAssertEqual(range.minimum, 120)
        XCTAssertEqual(range.maximum, 120)
        XCTAssertEqual(range.preferred, 120)
    }

    func testMetalDisplayLinkAllowsPromotionRangeFor60StreamOn120Display() {
        let range = MetalVideoRenderer.frameRateRange(
            framesPerSecond: 60,
            displayRefreshRate: 120
        )

        XCTAssertEqual(range.minimum, 60)
        XCTAssertEqual(range.maximum, 120)
        XCTAssertEqual(range.preferred, 60)
    }

    func testAdaptiveRenderLeadLearnsCommitCostWithinBounds() {
        var policy = AdaptiveRenderLeadPolicy(
            minimumLead: 0.000_5,
            maximumLead: 0.004,
            safetyMultiplier: 1.5,
            smoothingFactor: 0.5
        )

        XCTAssertEqual(policy.renderLead, 0.000_75, accuracy: 0.000_001)
        XCTAssertEqual(
            policy.waitDuration(now: 10, targetTimestamp: 10.008),
            0.007_25,
            accuracy: 0.000_001
        )
        policy.record(commitCost: 0.002)
        XCTAssertEqual(policy.renderLead, 0.003, accuracy: 0.000_001)
        policy.record(commitCost: 1)
        XCTAssertLessThanOrEqual(policy.renderLead, 0.004)
        policy.reset()
        XCTAssertNil(policy.estimatedCommitCost)
    }

    func testStatisticsAccumulateCountersRatesAndLatency() {
        var statistics = MediaStatisticsAccumulator(rollingWindow: 1)
        statistics.record(.submitted, at: 0)
        statistics.record(.decoded(latency: 0.004), at: 0.1)
        statistics.record(.presented, at: 0.1)
        statistics.record(.dropped(.late), at: 0.2)
        statistics.record(.decoderError, at: 0.3)
        statistics.record(.queueDepth(2), at: 0.3)

        let current = statistics.snapshot(at: 0.3)
        XCTAssertEqual(current.submittedFrames, 1)
        XCTAssertEqual(current.decodedFrames, 1)
        XCTAssertEqual(current.presentedFrames, 1)
        XCTAssertEqual(current.droppedFrames, 1)
        XCTAssertEqual(current.decoderErrors, 1)
        XCTAssertEqual(current.queueDepth, 2)
        XCTAssertEqual(current.decodeFramesPerSecond, 1, accuracy: 0.0001)
        XCTAssertEqual(current.presentationFramesPerSecond, 1, accuracy: 0.0001)
        XCTAssertEqual(current.averageDecodeLatencyMilliseconds ?? -1, 4, accuracy: 0.0001)

        let expired = statistics.snapshot(at: 2)
        XCTAssertEqual(expired.decodeFramesPerSecond, 0)
        XCTAssertEqual(expired.presentationFramesPerSecond, 0)
        XCTAssertEqual(expired.decodedFrames, 1)
    }
}
