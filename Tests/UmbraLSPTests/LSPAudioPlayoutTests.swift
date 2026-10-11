import XCTest
@testable import UmbraLSP
@testable import UmbraLSPTransport

final class LSPAudioPlayoutTests: XCTestCase {
    func testContiguousPacketsDecodeImmediatelyWithoutSchedulingExpiry() {
        var state = LSPAudioSequenceState()
        let first = packet(sequence: 100)
        let second = packet(sequence: 101)

        XCTAssertEqual(state.submit(first, maximumConcealedFrames: 4), [.decode(first)])
        XCTAssertEqual(state.submit(second, maximumConcealedFrames: 4), [.decode(second)])
        XCTAssertEqual(state.expectedSequence, 102)
        XCTAssertNil(state.pendingPacket)
    }

    func testTrueGapAllowsReorderThenExpiresWithPLC() throws {
        var state = LSPAudioSequenceState()
        _ = state.submit(packet(sequence: 100), maximumConcealedFrames: 4)

        let future = packet(sequence: 102)
        let drainedToken = try scheduledToken(
            in: state.submit(future, maximumConcealedFrames: 4)
        )
        let predecessor = packet(sequence: 101)
        XCTAssertEqual(
            state.submit(predecessor, maximumConcealedFrames: 4),
            [.decode(predecessor), .decode(future)]
        )
        XCTAssertEqual(state.expire(drainedToken), [])

        let futureAfterLoss = packet(sequence: 104)
        let expiryToken = try scheduledToken(
            in: state.submit(futureAfterLoss, maximumConcealedFrames: 4)
        )
        XCTAssertEqual(state.expire(expiryToken), [.conceal, .decode(futureAfterLoss)])

        let afterFortyMillisecondGap = packet(sequence: 109)
        let gapActions = state.submit(afterFortyMillisecondGap, maximumConcealedFrames: 4)
        XCTAssertEqual(concealCount(in: gapActions), 4)
        XCTAssertEqual(resetCount(in: gapActions), 0)
        XCTAssertTrue(gapActions.contains(.decode(afterFortyMillisecondGap)))
        XCTAssertEqual(state.expectedSequence, 110)
        XCTAssertNil(state.pendingPacket)
    }

    func testStaleMarkerIsIgnoredAndForwardMarkerInvalidatesPendingExpiry() throws {
        var state = LSPAudioSequenceState()
        let first = packet(sequence: 100)
        XCTAssertEqual(state.submit(first, maximumConcealedFrames: 4), [.decode(first)])

        let staleMarker = packet(sequence: 100, marker: true)
        XCTAssertEqual(
            state.submit(staleMarker, maximumConcealedFrames: 4),
            [.discard(staleMarker)]
        )

        let pending = packet(sequence: 102)
        let oldToken = try scheduledToken(in: state.submit(pending, maximumConcealedFrames: 4))
        let marker = packet(sequence: 110, marker: true)
        let markerActions = state.submit(marker, maximumConcealedFrames: 4)
        XCTAssertEqual(resetCount(in: markerActions), 1)
        XCTAssertTrue(markerActions.contains(.discard(pending)))
        XCTAssertTrue(markerActions.contains(.decode(marker)))
        XCTAssertEqual(state.expire(oldToken), [])
        XCTAssertEqual(state.expectedSequence, 111)
        XCTAssertNil(state.pendingPacket)
    }

    func testSequenceWrapDecodesImmediatelyAsForwardProgress() {
        var state = LSPAudioSequenceState()
        let last = packet(sequence: .max)
        let wrapped = packet(sequence: 0)

        XCTAssertEqual(state.submit(last, maximumConcealedFrames: 4), [.decode(last)])
        XCTAssertEqual(state.expectedSequence, 0)
        XCTAssertEqual(state.submit(wrapped, maximumConcealedFrames: 4), [.decode(wrapped)])
        XCTAssertEqual(state.expectedSequence, 1)
        XCTAssertNil(state.pendingPacket)
    }

    func testLargeForwardGapAndGenerationChangeInvalidatePendingExpiry() throws {
        var state = LSPAudioSequenceState()
        _ = state.submit(packet(sequence: 100), maximumConcealedFrames: 4)
        let pending = packet(sequence: 102)
        let gapToken = try scheduledToken(in: state.submit(pending, maximumConcealedFrames: 4))

        let discontinuity = packet(sequence: 107)
        let actions = state.submit(discontinuity, maximumConcealedFrames: 4)
        XCTAssertEqual(resetCount(in: actions), 1)
        XCTAssertTrue(actions.contains(.discard(pending)))
        XCTAssertTrue(actions.contains(.decode(discontinuity)))
        XCTAssertEqual(state.expire(gapToken), [])

        let nextGenerationPending = packet(sequence: 109)
        let generationToken = try scheduledToken(
            in: state.submit(nextGenerationPending, maximumConcealedFrames: 4)
        )
        state.invalidate()
        XCTAssertEqual(
            state.submit(nextGenerationPending, maximumConcealedFrames: 4),
            [.decode(nextGenerationPending)]
        )
        XCTAssertEqual(state.expire(generationToken), [])
    }

    private func packet(sequence: UInt16, marker: Bool = false) -> LSPAudioPacket {
        LSPAudioPacket(
            audioGeneration: 1,
            ssrc: 2,
            sequenceNumber: sequence,
            timestamp: UInt32(sequence) * 480,
            marker: marker,
            opusPacket: Data([UInt8(truncatingIfNeeded: sequence)])
        )
    }

    private func scheduledToken(
        in actions: [LSPAudioSequenceState.Action]
    ) throws -> LSPAudioSequenceState.PendingToken {
        try XCTUnwrap(actions.compactMap { action -> LSPAudioSequenceState.PendingToken? in
            guard case let .schedule(token) = action else { return nil }
            return token
        }.last)
    }

    private func resetCount(in actions: [LSPAudioSequenceState.Action]) -> Int {
        actions.count { $0 == .reset }
    }

    private func concealCount(in actions: [LSPAudioSequenceState.Action]) -> Int {
        actions.count { $0 == .conceal }
    }
}
