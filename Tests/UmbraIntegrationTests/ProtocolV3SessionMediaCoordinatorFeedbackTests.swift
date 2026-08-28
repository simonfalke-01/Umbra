import Foundation
import Testing
import UmbraQUICTransport
@testable import UmbraIntegration

@Suite("Protocol-v3 session video feedback")
struct ProtocolV3SessionMediaCoordinatorFeedbackTests {
    @Test("recovery feedback keeps its affected frame without illegal supersession")
    func recoveryFeedbackUsesUnreliableDatagramAdmission() throws {
        let feedback = ProtocolV3VideoFeedback(
            affectedFrameID: 5,
            lastReassembledFrameID: 4,
            lastDecodedFrameID: 3,
            action: 4,
            deadlineMissMicroseconds: 0
        )
        let scheduling = ProtocolV3SessionMediaCoordinator.videoFeedbackScheduling(feedback)
        #expect(scheduling.objectID == feedback.affectedFrameID)
        #expect(scheduling.supersessionKey == nil)

        let sessionID = Data(repeating: 1, count: 16)
        let request = QUICOutboundRequest(
            lane: .video,
            payload: Data([1]),
            supersessionKey: scheduling.supersessionKey,
            wireMetadata: .datagram(
                sessionID: sessionID,
                channel: 2,
                kind: 3,
                flags: 0,
                objectID: scheduling.objectID
            )
        )
        let scheduler = try QUICSendScheduler(mode: .latency)
        let accepted = scheduler.enqueue(request, nowNanoseconds: 1)
        #expect(accepted.acceptedID != nil)

        let rejected = scheduler.enqueue(
            QUICOutboundRequest(
                lane: .video,
                payload: Data([1]),
                supersessionKey: feedback.affectedFrameID,
                wireMetadata: request.wireMetadata
            ),
            nowNanoseconds: 2
        )
        #expect(rejected.acceptedID == nil)
        #expect(rejected.dispositions.only?.outcome == .rejectedInvalidRequest)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
