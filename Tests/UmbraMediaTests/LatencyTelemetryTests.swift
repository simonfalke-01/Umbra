import XCTest
@testable import UmbraMedia

final class LatencyTelemetryTests: XCTestCase {
    func testCorrelationIdentitySurvivesDecodeAndRendererMetadataUpdates() {
        let identity = VideoFrameCorrelationID(decoderGeneration: 9, frameNumber: 42)
        let metadata = VideoFrameLatencyMetadata(
            correlationID: identity,
            receiveClockCalibration: VideoLatencyClockCalibrationEvidence(
                sourceDomain: .gameStreamClientUptime,
                destinationDomain: .clientMediaTime,
                observationCount: 3,
                estimatedOffsetSeconds: 10,
                maximumErrorSeconds: nil
            ),
            videoToolboxSubmitTime: VideoLatencyTimestamp(
                seconds: 1,
                clockDomain: .clientMediaTime
            )
        )

        let completed = metadata.recordingDecodeCompletion(VideoLatencyTimestamp(
            seconds: 1.002,
            clockDomain: .clientMediaTime
        ))
        let queued = completed.recordingRendererEnqueue(VideoLatencyTimestamp(
            seconds: 1.003,
            clockDomain: .clientMediaTime
        ))

        XCTAssertEqual(completed.correlationID, identity)
        XCTAssertEqual(queued.correlationID, identity)
        XCTAssertEqual(queued.receiveClockCalibration?.observationCount, 3)
        XCTAssertNil(queued.receiveClockCalibration?.maximumErrorSeconds)
    }

    func testClientHotPathStagesHaveIndependentCountsAndPercentiles() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 8)
        accumulator.record(.receiveToVideoToolboxSubmit, duration: 0.001)
        accumulator.record(.reassemblyEnqueueToVideoToolboxSubmit, duration: 0.002)
        accumulator.record(.videoToolboxDecode, duration: 0.003)
        accumulator.record(.decodeToMetalCommit, duration: 0.004)

        let snapshot = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(snapshot.receiveToVideoToolboxSubmit?.sampleCount, 1)
        XCTAssertEqual(snapshot.receiveToVideoToolboxSubmit?.p99Milliseconds ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(snapshot.reassemblyEnqueueToVideoToolboxSubmit?.sampleCount, 1)
        XCTAssertEqual(snapshot.reassemblyEnqueueToVideoToolboxSubmit?.p99Milliseconds ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(snapshot.videoToolboxDecode?.sampleCount, 1)
        XCTAssertEqual(snapshot.videoToolboxDecode?.p99Milliseconds ?? -1, 3, accuracy: 0.0001)
        XCTAssertEqual(snapshot.decodeToMetalCommit?.sampleCount, 1)
        XCTAssertEqual(snapshot.decodeToMetalCommit?.p99Milliseconds ?? -1, 4, accuracy: 0.0001)
    }

    func testTelemetryProfileSwitchClearsPriorModeSamples() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(
            sampleCapacity: 4,
            profile: .latency,
            client: .umbraLegacy
        )
        accumulator.record(.videoToolboxDecode, duration: 0.001)
        XCTAssertEqual(accumulator.snapshot()?.profile, .latency)
        XCTAssertEqual(accumulator.snapshot()?.client, .umbraLegacy)

        accumulator.setProfile(.quality)
        XCTAssertNil(accumulator.snapshot())
        accumulator.record(.videoToolboxDecode, duration: 0.002)
        let quality = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(quality.profile, .quality)
        XCTAssertEqual(quality.client, .umbraLegacy)
        XCTAssertEqual(quality.videoToolboxDecode?.sampleCount, 1)
        XCTAssertEqual(quality.videoToolboxDecode?.p50Milliseconds ?? -1, 2, accuracy: 0.0001)

        accumulator.setClient(.umbraV2)
        XCTAssertNil(accumulator.snapshot())
        accumulator.record(.videoToolboxDecode, duration: 0.003)
        XCTAssertEqual(accumulator.snapshot()?.client, .umbraV2)
        XCTAssertEqual(accumulator.snapshot()?.profile, .quality)
    }

    func testNearestRankPercentilesAreComputedFromBoundedSamples() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 100)
        for milliseconds in 1 ... 100 {
            accumulator.record(.receiveToDecode, duration: Double(milliseconds) / 1_000)
        }

        let summary = try XCTUnwrap(accumulator.snapshot()?.receiveToDecode)
        XCTAssertEqual(summary.sampleCount, 100)
        XCTAssertEqual(summary.p50Milliseconds, 50, accuracy: 0.0001)
        XCTAssertEqual(summary.p95Milliseconds, 95, accuracy: 0.0001)
        XCTAssertEqual(summary.p99Milliseconds, 99, accuracy: 0.0001)
    }

    func testSampleWindowKeepsOnlyNewestValues() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 4)
        for milliseconds in 1 ... 5 {
            accumulator.record(.decodeToMetalCommit, duration: Double(milliseconds) / 1_000)
        }

        let summary = try XCTUnwrap(accumulator.snapshot()?.decodeToMetalCommit)
        XCTAssertEqual(summary.sampleCount, 4)
        XCTAssertEqual(summary.p50Milliseconds, 3, accuracy: 0.0001)
        XCTAssertEqual(summary.p95Milliseconds, 5, accuracy: 0.0001)
        XCTAssertEqual(summary.p99Milliseconds, 5, accuracy: 0.0001)
    }

    func testClockDomainsMustMatchForDurations() {
        let stream = VideoLatencyTimestamp(seconds: 1, clockDomain: .streamPresentationTimeline)
        let client = VideoLatencyTimestamp(seconds: 2, clockDomain: .clientMediaTime)
        let backwards = VideoLatencyTimestamp(seconds: 0.5, clockDomain: .streamPresentationTimeline)

        XCTAssertNil(stream.duration(to: client))
        XCTAssertNil(stream.duration(to: backwards))
        XCTAssertEqual(
            stream.duration(to: VideoLatencyTimestamp(
                seconds: 1.004,
                clockDomain: .streamPresentationTimeline
            )) ?? -1,
            0.004,
            accuracy: 0.000_001
        )
    }

    func testClockMappingUsesMinimumObservedOffsetAndRejectsWrongDomain() throws {
        var mapping = VideoLatencyClockMapping(
            sourceDomain: .gameStreamClientUptime,
            destinationDomain: .clientMediaTime
        )
        mapping.observe(
            source: VideoLatencyTimestamp(seconds: 1, clockDomain: .gameStreamClientUptime),
            destination: VideoLatencyTimestamp(seconds: 101.004, clockDomain: .clientMediaTime)
        )
        mapping.observe(
            source: VideoLatencyTimestamp(seconds: 2, clockDomain: .gameStreamClientUptime),
            destination: VideoLatencyTimestamp(seconds: 102.001, clockDomain: .clientMediaTime)
        )
        mapping.observe(
            source: VideoLatencyTimestamp(seconds: 3, clockDomain: .streamPresentationTimeline),
            destination: VideoLatencyTimestamp(seconds: 103, clockDomain: .clientMediaTime)
        )

        XCTAssertEqual(mapping.observationCount, 2)
        XCTAssertEqual(mapping.minimumOffsetSeconds ?? -1, 100.001, accuracy: 0.000_001)
        let mapped = try XCTUnwrap(mapping.map(VideoLatencyTimestamp(
            seconds: 1.5,
            clockDomain: .gameStreamClientUptime
        )))
        XCTAssertEqual(mapped.clockDomain, .clientMediaTime)
        XCTAssertEqual(mapped.seconds, 101.501, accuracy: 0.000_001)
        XCTAssertNil(mapping.map(VideoLatencyTimestamp(
            seconds: 1.5,
            clockDomain: .streamPresentationTimeline
        )))
        XCTAssertEqual(mapping.evidence?.observationCount, 2)
        XCTAssertEqual(mapping.evidence?.estimatedOffsetSeconds ?? -1, 100.001, accuracy: 0.000_001)
        XCTAssertNil(mapping.evidence?.maximumErrorSeconds)
    }

    func testMissingAndCrossClockSamplesRemainUnavailable() {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 4)
        XCTAssertNil(accumulator.snapshot())

        accumulator.record(
            from: VideoLatencyTimestamp(seconds: 1, clockDomain: .streamPresentationTimeline),
            to: VideoLatencyTimestamp(seconds: 2, clockDomain: .clientMediaTime),
            stage: .receiveToDecode
        )
        accumulator.record(.receiveToDecode, duration: -0.001)

        XCTAssertNil(accumulator.snapshot())
    }

    func testPresentationEvidenceAndReset() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 4)
        accumulator.recordPresentationProxy(
            from: VideoLatencyTimestamp(seconds: 5, clockDomain: .clientMediaTime),
            to: VideoLatencyTimestamp(seconds: 5.002, clockDomain: .clientMediaTime),
            evidence: .displayLinkPresentationTarget,
            gpuCompletion: VideoLatencyTimestamp(seconds: 5.001, clockDomain: .clientMediaTime)
        )

        let snapshot = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(snapshot.presentationProxyEvidence, .displayLinkPresentationTarget)
        XCTAssertEqual(
            snapshot.metalCommitToPresentationProxy?.p50Milliseconds ?? -1,
            2,
            accuracy: 0.0001
        )

        accumulator.reset()
        XCTAssertNil(accumulator.snapshot())
    }

    func testPreferredTargetCannotBeRecordedWithoutValidatedGPUCompletion() {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 2)
        XCTAssertFalse(accumulator.recordPresentationProxy(
            from: VideoLatencyTimestamp(seconds: 5, clockDomain: .clientMediaTime),
            to: VideoLatencyTimestamp(seconds: 5.002, clockDomain: .clientMediaTime),
            evidence: .displayLinkPresentationTarget
        ))
        XCTAssertNil(accumulator.snapshot())
    }

    func testPresentationEvidenceRollsWithLatencyWindow() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 2)
        let commit = VideoLatencyTimestamp(seconds: 5, clockDomain: .clientMediaTime)
        accumulator.recordPresentationProxy(
            from: commit,
            to: VideoLatencyTimestamp(seconds: 5.001, clockDomain: .clientMediaTime),
            evidence: .commandBufferCompletion
        )
        accumulator.recordPresentationProxy(
            from: commit,
            to: VideoLatencyTimestamp(seconds: 5.002, clockDomain: .clientMediaTime),
            evidence: .displayLinkPresentationTarget,
            gpuCompletion: VideoLatencyTimestamp(seconds: 5.001_5, clockDomain: .clientMediaTime)
        )
        XCTAssertEqual(accumulator.snapshot()?.presentationProxyEvidence, .mixed)

        accumulator.recordPresentationProxy(
            from: commit,
            to: VideoLatencyTimestamp(seconds: 5.003, clockDomain: .clientMediaTime),
            evidence: .displayLinkPresentationTarget,
            gpuCompletion: VideoLatencyTimestamp(seconds: 5.002_5, clockDomain: .clientMediaTime)
        )

        let snapshot = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(snapshot.presentationProxyEvidence, .displayLinkPresentationTarget)
        XCTAssertEqual(snapshot.metalCommitToPresentationProxy?.sampleCount, 2)
    }

    func testDisplayLinkProxySelectsTargetPresentationTimestamp() {
        XCTAssertEqual(
            MetalVideoRenderer.displayLinkPresentationProxyTimestamp(
                targetTimestamp: 10,
                targetPresentationTimestamp: 10.008
            ),
            10.008
        )
    }

    func testLateDisplayTargetFallsBackToCompletionAndRecordsMiss() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 4)
        let commit = VideoLatencyTimestamp(seconds: 5, clockDomain: .clientMediaTime)
        accumulator.recordBestAvailablePresentationProxy(
            from: commit,
            preferredProxy: VideoLatencyTimestamp(
                seconds: 4.999,
                clockDomain: .clientMediaTime
            ),
            preferredEvidence: .displayLinkPresentationTarget,
            commandCompletion: VideoLatencyTimestamp(
                seconds: 5.002,
                clockDomain: .clientMediaTime
            )
        )

        let snapshot = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(snapshot.missedPresentationDeadlines, 1)
        XCTAssertEqual(snapshot.presentationProxyEvidence, .commandBufferCompletion)
        XCTAssertEqual(
            snapshot.metalCommitToPresentationProxy?.p50Milliseconds ?? -1,
            2,
            accuracy: 0.0001
        )
    }

    func testLateScheduledPresentationTargetAlsoRecordsMiss() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 4)
        let commit = VideoLatencyTimestamp(seconds: 5, clockDomain: .clientMediaTime)
        accumulator.recordBestAvailablePresentationProxy(
            from: commit,
            preferredProxy: VideoLatencyTimestamp(seconds: 4.999, clockDomain: .clientMediaTime),
            preferredEvidence: .scheduledPresentationTime,
            commandCompletion: VideoLatencyTimestamp(seconds: 5.001, clockDomain: .clientMediaTime)
        )

        let snapshot = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(snapshot.missedPresentationDeadlines, 1)
        XCTAssertEqual(snapshot.presentationProxyEvidence, .commandBufferCompletion)
    }

    func testCompletionAfterEqualDisplayTargetIsClassifiedAsMissed() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 4)
        let commit = VideoLatencyTimestamp(seconds: 5, clockDomain: .clientMediaTime)
        accumulator.recordBestAvailablePresentationProxy(
            from: commit,
            preferredProxy: VideoLatencyTimestamp(seconds: 5, clockDomain: .clientMediaTime),
            preferredEvidence: .displayLinkPresentationTarget,
            commandCompletion: VideoLatencyTimestamp(seconds: 5.002, clockDomain: .clientMediaTime)
        )
        accumulator.recordBestAvailablePresentationProxy(
            from: commit,
            preferredProxy: nil,
            preferredEvidence: .displayLinkPresentationTarget,
            commandCompletion: VideoLatencyTimestamp(seconds: 5.003, clockDomain: .clientMediaTime)
        )

        let snapshot = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(snapshot.missedPresentationDeadlines, 1)
        XCTAssertEqual(snapshot.presentationProxyEvidence, .commandBufferCompletion)
        XCTAssertEqual(
            snapshot.metalCommitToPresentationProxy?.p50Milliseconds ?? -1,
            2,
            accuracy: 0.0001
        )
    }

    func testPreferredTargetBetweenCommitAndCompletionIsAMiss() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 4)
        let commit = VideoLatencyTimestamp(seconds: 5, clockDomain: .clientMediaTime)
        accumulator.recordBestAvailablePresentationProxy(
            from: commit,
            preferredProxy: VideoLatencyTimestamp(seconds: 5.001, clockDomain: .clientMediaTime),
            preferredEvidence: .displayLinkPresentationTarget,
            commandCompletion: VideoLatencyTimestamp(seconds: 5.002, clockDomain: .clientMediaTime)
        )

        let snapshot = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(snapshot.missedPresentationDeadlines, 1)
        XCTAssertEqual(snapshot.presentationProxyEvidence, .commandBufferCompletion)
        XCTAssertEqual(snapshot.metalCommitToPresentationProxy?.p50Milliseconds ?? -1, 2, accuracy: 0.0001)
    }

    func testMissingOrCrossClockCompletionRecordsUnavailableOutcome() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 2)
        let commit = VideoLatencyTimestamp(seconds: 5, clockDomain: .clientMediaTime)
        let target = VideoLatencyTimestamp(seconds: 5.002, clockDomain: .clientMediaTime)
        accumulator.recordBestAvailablePresentationProxy(
            from: commit,
            preferredProxy: target,
            preferredEvidence: .displayLinkPresentationTarget,
            commandCompletion: nil
        )
        accumulator.recordBestAvailablePresentationProxy(
            from: commit,
            preferredProxy: target,
            preferredEvidence: .displayLinkPresentationTarget,
            commandCompletion: VideoLatencyTimestamp(seconds: 5.001, clockDomain: .gameStreamClientUptime)
        )

        let snapshot = try XCTUnwrap(accumulator.snapshot())
        XCTAssertNil(snapshot.metalCommitToPresentationProxy)
        XCTAssertNil(snapshot.presentationProxyEvidence)
        XCTAssertEqual(snapshot.missedPresentationDeadlines, 0)
        XCTAssertEqual(snapshot.unavailablePresentationProxySamples, 2)
    }

    func testMissedPresentationCountEvictsWithRollingOutcomeWindow() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 2)
        let commit = VideoLatencyTimestamp(seconds: 5, clockDomain: .clientMediaTime)
        accumulator.recordBestAvailablePresentationProxy(
            from: commit,
            preferredProxy: VideoLatencyTimestamp(seconds: 4.9, clockDomain: .clientMediaTime),
            preferredEvidence: .displayLinkPresentationTarget,
            commandCompletion: VideoLatencyTimestamp(seconds: 4.9, clockDomain: .clientMediaTime)
        )
        let allMissed = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(allMissed.missedPresentationDeadlines, 1)
        XCTAssertNil(allMissed.metalCommitToPresentationProxy)
        XCTAssertNil(allMissed.presentationProxyEvidence)

        for offset in [0.001, 0.002] {
            accumulator.recordBestAvailablePresentationProxy(
                from: commit,
                preferredProxy: VideoLatencyTimestamp(
                    seconds: 5 + offset,
                    clockDomain: .clientMediaTime
                ),
                preferredEvidence: .displayLinkPresentationTarget,
                commandCompletion: VideoLatencyTimestamp(
                    seconds: 5 + offset - 0.000_5,
                    clockDomain: .clientMediaTime
                )
            )
        }

        let snapshot = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(snapshot.missedPresentationDeadlines, 0)
        XCTAssertEqual(snapshot.presentationProxyEvidence, .displayLinkPresentationTarget)
    }

    func testPresentationLatencyEvidenceAndMissStayAlignedAcrossNilDurationEviction() throws {
        var accumulator = VideoLatencyStatisticsAccumulator(sampleCapacity: 2)
        let commit = VideoLatencyTimestamp(seconds: 5, clockDomain: .clientMediaTime)
        accumulator.recordBestAvailablePresentationProxy(
            from: commit,
            preferredProxy: VideoLatencyTimestamp(seconds: 4.9, clockDomain: .clientMediaTime),
            preferredEvidence: .displayLinkPresentationTarget,
            commandCompletion: VideoLatencyTimestamp(seconds: 4.9, clockDomain: .clientMediaTime)
        )
        accumulator.recordPresentationProxy(
            from: commit,
            to: VideoLatencyTimestamp(seconds: 5.001, clockDomain: .clientMediaTime),
            evidence: .commandBufferCompletion
        )
        var snapshot = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(snapshot.missedPresentationDeadlines, 1)
        XCTAssertEqual(snapshot.metalCommitToPresentationProxy?.sampleCount, 1)
        XCTAssertEqual(snapshot.presentationProxyEvidence, .commandBufferCompletion)

        accumulator.recordPresentationProxy(
            from: commit,
            to: VideoLatencyTimestamp(seconds: 5.002, clockDomain: .clientMediaTime),
            evidence: .displayLinkPresentationTarget,
            gpuCompletion: VideoLatencyTimestamp(seconds: 5.001_5, clockDomain: .clientMediaTime)
        )
        snapshot = try XCTUnwrap(accumulator.snapshot())
        XCTAssertEqual(snapshot.missedPresentationDeadlines, 0)
        XCTAssertEqual(snapshot.metalCommitToPresentationProxy?.sampleCount, 2)
        XCTAssertEqual(snapshot.presentationProxyEvidence, .mixed)
    }

    func testClockMappingResetRemovesCalibration() {
        var mapping = VideoLatencyClockMapping(
            sourceDomain: .gameStreamClientUptime,
            destinationDomain: .clientMediaTime
        )
        let source = VideoLatencyTimestamp(seconds: 1, clockDomain: .gameStreamClientUptime)
        mapping.observe(
            source: source,
            destination: VideoLatencyTimestamp(seconds: 10, clockDomain: .clientMediaTime)
        )
        XCTAssertNotNil(mapping.map(source))

        mapping.reset()

        XCTAssertEqual(mapping.observationCount, 0)
        XCTAssertNil(mapping.minimumOffsetSeconds)
        XCTAssertNil(mapping.map(source))
    }

    func testFrameDequeuedBeforeFlushCannotPopulatePostFlushLatencyWindow() {
        var generation = MetalLatencyGenerationGate()
        var postFlushStatistics = VideoLatencyStatisticsAccumulator(sampleCapacity: 4)
        let dequeuedFrameGeneration = generation.stamp

        generation.advance()
        if generation.accepts(dequeuedFrameGeneration) {
            postFlushStatistics.record(.decodeToMetalCommit, duration: 0.001)
        }

        XCTAssertNil(postFlushStatistics.snapshot())
        XCTAssertFalse(generation.accepts(dequeuedFrameGeneration))

        let postFlushFrameGeneration = generation.stamp
        XCTAssertTrue(generation.accepts(postFlushFrameGeneration))
    }

    func testReconnectResetRejectsPriorGenerationBaseStatistics() {
        var generation = MetalLatencyGenerationGate()
        var statistics = MediaStatisticsAccumulator()
        let previousSessionFrame = generation.stamp
        statistics.record(.presented, at: 1)

        generation.advance()
        statistics.reset()
        if generation.accepts(previousSessionFrame) {
            statistics.record(.presented, at: 2)
        }

        let snapshot = statistics.snapshot(at: 2)
        XCTAssertEqual(snapshot.presentedFrames, 0)
        XCTAssertEqual(snapshot.presentationFramesPerSecond, 0)
    }
}
