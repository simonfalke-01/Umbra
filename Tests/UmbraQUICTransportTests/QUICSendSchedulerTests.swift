import Foundation
import Testing
@testable import UmbraQUICTransport

@Suite("QUIC send scheduler")
struct QUICSendSchedulerTests {
    @Test("higher-priority input edges dequeue before media while preserving lane order")
    func strictPriorityAndLaneOrder() throws {
        let scheduler = try QUICSendScheduler(mode: .latency)
        let video = scheduler.enqueue(
            .init(lane: .video, payload: Data([0x10])),
            nowNanoseconds: 1
        )
        let edgeOne = scheduler.enqueue(
            .init(lane: .inputEdge, payload: Data([0x20])),
            nowNanoseconds: 2
        )
        let edgeTwo = scheduler.enqueue(
            .init(lane: .inputEdge, payload: Data([0x21])),
            nowNanoseconds: 3
        )

        #expect(scheduler.dequeue(nowNanoseconds: 4).send?.id == edgeOne.acceptedID)
        #expect(scheduler.dequeue(nowNanoseconds: 4).send?.id == edgeTwo.acceptedID)
        #expect(scheduler.dequeue(nowNanoseconds: 4).send?.id == video.acceptedID)
    }

    @Test("latest-state messages explicitly supersede only their matching key")
    func latestStateSupersession() throws {
        let scheduler = try QUICSendScheduler(mode: .latency)
        let first = scheduler.enqueue(
            .init(lane: .inputState, payload: Data([1]), supersessionKey: 7),
            nowNanoseconds: 1
        )
        let unrelated = scheduler.enqueue(
            .init(lane: .inputState, payload: Data([2]), supersessionKey: 8),
            nowNanoseconds: 2
        )
        let replacement = scheduler.enqueue(
            .init(lane: .inputState, payload: Data([3]), supersessionKey: 7),
            nowNanoseconds: 3
        )

        #expect(
            replacement.dispositions == [
                .init(
                    id: try #require(first.acceptedID),
                    lane: .inputState,
                    outcome: .superseded(by: try #require(replacement.acceptedID))
                )
            ]
        )
        let firstSend = try #require(scheduler.dequeue(nowNanoseconds: 4).send)
        let secondSend = try #require(scheduler.dequeue(nowNanoseconds: 4).send)
        #expect(firstSend.id == replacement.acceptedID)
        #expect(secondSend.id == unrelated.acceptedID)
        #expect(firstSend.semanticSequence < secondSend.semanticSequence)
    }

    @Test("expired work is reported and never returned for a Network.framework send")
    func expirationBeforeSend() throws {
        let scheduler = try QUICSendScheduler(mode: .latency)
        let expired = scheduler.enqueue(
            .init(lane: .audio, payload: Data([1]), deadlineNanoseconds: 10),
            nowNanoseconds: 1
        )
        let live = scheduler.enqueue(
            .init(lane: .audio, payload: Data([2]), deadlineNanoseconds: 20),
            nowNanoseconds: 1
        )

        let drain = scheduler.dequeue(nowNanoseconds: 10)
        #expect(drain.send?.id == live.acceptedID)
        #expect(
            drain.dispositions == [
                .init(id: try #require(expired.acceptedID), lane: .audio, outcome: .expired)
            ]
        )
    }

    @Test("negotiated datagram payload cap is enforced at enqueue and again at dequeue")
    func datagramCap() throws {
        let scheduler = try QUICSendScheduler(mode: .latency)
        scheduler.updateUsableDatagramPayloadSize(4)
        let rejected = scheduler.enqueue(
            .init(lane: .video, payload: Data(repeating: 0, count: 5)),
            nowNanoseconds: 1
        )
        #expect(!rejected.isAccepted)
        #expect(rejected.dispositions.first?.outcome == .datagramTooLarge(maximumPayloadBytes: 4))

        scheduler.updateUsableDatagramPayloadSize(8)
        let accepted = scheduler.enqueue(
            .init(lane: .video, payload: Data(repeating: 0, count: 8)),
            nowNanoseconds: 2
        )
        scheduler.updateUsableDatagramPayloadSize(4)
        let drain = scheduler.dequeue(nowNanoseconds: 3)
        #expect(drain.send == nil)
        #expect(
            drain.dispositions == [
                .init(
                    id: try #require(accepted.acceptedID),
                    lane: .video,
                    outcome: .datagramTooLarge(maximumPayloadBytes: 4)
                )
            ]
        )
    }

    @Test("quality mode rejects overflow explicitly and preserves accepted order")
    func qualityBackpressureIsExplicitAndOrdered() throws {
        let limits = limits(totalCount: 2, totalBytes: 2, laneCount: 2, laneBytes: 2)
        let scheduler = try QUICSendScheduler(mode: .quality, limits: limits)
        let first = scheduler.enqueue(
            .init(lane: .control, payload: Data([1])),
            nowNanoseconds: 1
        )
        let second = scheduler.enqueue(
            .init(lane: .control, payload: Data([2])),
            nowNanoseconds: 2
        )
        let rejected = scheduler.enqueue(
            .init(lane: .control, payload: Data([3])),
            nowNanoseconds: 3
        )

        #expect(rejected.acceptedID == nil)
        #expect(rejected.dispositions.count == 1)
        #expect(rejected.dispositions[0].outcome == .rejectedQueueFull)
        #expect(scheduler.dequeue(nowNanoseconds: 4).send?.id == first.acceptedID)
        #expect(scheduler.dequeue(nowNanoseconds: 4).send?.id == second.acceptedID)
    }

    @Test("latency mode can evict lower-priority queued media but reports the loss")
    func latencyPriorityEvictionIsVisible() throws {
        let limits = limits(totalCount: 1, totalBytes: 8, laneCount: 1, laneBytes: 8)
        let scheduler = try QUICSendScheduler(mode: .latency, limits: limits)
        let video = scheduler.enqueue(
            .init(lane: .video, payload: Data([1])),
            nowNanoseconds: 1
        )
        let edge = scheduler.enqueue(
            .init(lane: .inputEdge, payload: Data([2])),
            nowNanoseconds: 2
        )

        #expect(edge.isAccepted)
        #expect(
            edge.dispositions == [
                .init(id: try #require(video.acceptedID), lane: .video, outcome: .cancelled)
            ]
        )
        #expect(scheduler.dequeue(nowNanoseconds: 3).send?.id == edge.acceptedID)
    }

    @Test("in-flight cap and eligible-lane gate bound Network.framework send calls")
    func inFlightAndEligibilityCaps() throws {
        let limits = QUICSchedulerLimits(
            totalMessageCount: 16,
            totalByteCount: 1_024,
            maximumInFlightSends: 1,
            perLane: Dictionary(
                uniqueKeysWithValues: QUICSemanticLane.allCases.map {
                    ($0, QUICLaneQueueLimit(messageCount: 16, byteCount: 1_024))
                }
            )
        )
        let scheduler = try QUICSendScheduler(mode: .latency, limits: limits)
        let edge = scheduler.enqueue(
            .init(lane: .inputEdge, payload: Data([1])),
            nowNanoseconds: 1
        )
        let control = scheduler.enqueue(
            .init(lane: .control, payload: Data([2])),
            nowNanoseconds: 2
        )

        let first = scheduler.dequeue(nowNanoseconds: 3, eligibleLanes: [.control])
        #expect(first.send?.id == control.acceptedID)
        #expect(scheduler.dequeue(nowNanoseconds: 3).send == nil)
        #expect(scheduler.complete(id: try #require(control.acceptedID))?.outcome == .submittedToNetwork)
        #expect(scheduler.dequeue(nowNanoseconds: 4).send?.id == edge.acceptedID)
    }

    @Test("cancellation reports every queued and in-flight message exactly once")
    func cancellationIsCompleteAndIdempotent() throws {
        let scheduler = try QUICSendScheduler(mode: .quality)
        let first = scheduler.enqueue(
            .init(lane: .control, payload: Data([1])),
            nowNanoseconds: 1
        )
        let second = scheduler.enqueue(
            .init(lane: .video, payload: Data([2])),
            nowNanoseconds: 2
        )
        _ = scheduler.dequeue(nowNanoseconds: 3)

        let cancelled = scheduler.cancel()
        #expect(Set(cancelled.map(\.id)) == Set([try #require(first.acceptedID), try #require(second.acceptedID)]))
        #expect(cancelled.allSatisfy { $0.outcome == .cancelled })
        #expect(scheduler.cancel().isEmpty)
        #expect(scheduler.snapshot().isCancelled)
    }

    @Test("steady nonempty backlog periodically releases popped payload storage")
    func steadyBacklogStorageBound() throws {
        let limits = limits(totalCount: 200, totalBytes: 200, laneCount: 200, laneBytes: 200)
        let scheduler = try QUICSendScheduler(mode: .quality, limits: limits)
        for _ in 0..<100 {
            #expect(scheduler.enqueue(.init(lane: .video, payload: Data([1])), nowNanoseconds: 1).isAccepted)
        }
        var peakRetainedSlots = 0
        for _ in 0..<2_000 {
            let send = try #require(scheduler.dequeue(nowNanoseconds: 2).send)
            _ = scheduler.complete(id: send.id)
            #expect(scheduler.enqueue(.init(lane: .video, payload: Data([1])), nowNanoseconds: 2).isAccepted)
            peakRetainedSlots = max(peakRetainedSlots, scheduler.snapshot().retainedQueueSlotCount)
        }
        let snapshot = scheduler.snapshot()
        #expect(snapshot.queuedMessageCount == 100)
        #expect(snapshot.retainedQueueSlotCount <= 163)
        #expect(peakRetainedSlots < 200)
    }

    @Test("sender refuses semantic sequence exhaustion safety band")
    func sequenceExhaustionBand() throws {
        let threshold = UInt64.max - 1_023
        let scheduler = try QUICSendScheduler(
            mode: .latency,
            testingInitialSemanticSequence: threshold - 1
        )
        let accepted = scheduler.enqueue(.init(lane: .video, payload: Data([1])), nowNanoseconds: 1)
        #expect(accepted.isAccepted)
        #expect(scheduler.dequeue(nowNanoseconds: 2).send?.semanticSequence == threshold - 1)
        let rejected = scheduler.enqueue(.init(lane: .video, payload: Data([2])), nowNanoseconds: 2)
        #expect(rejected.acceptedID == nil)
        #expect(rejected.dispositions.first?.outcome == .sequenceExhausted)
    }

    private func limits(
        totalCount: Int,
        totalBytes: Int,
        laneCount: Int,
        laneBytes: Int
    ) -> QUICSchedulerLimits {
        QUICSchedulerLimits(
            totalMessageCount: totalCount,
            totalByteCount: totalBytes,
            maximumInFlightSends: min(2, totalCount),
            perLane: Dictionary(
                uniqueKeysWithValues: QUICSemanticLane.allCases.map {
                    ($0, QUICLaneQueueLimit(messageCount: laneCount, byteCount: laneBytes))
                }
            )
        )
    }
}
