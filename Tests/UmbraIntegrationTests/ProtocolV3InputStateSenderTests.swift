import Foundation
import Testing
import UmbraProtocolV3
import UmbraQUICTransport
@testable import UmbraIntegration

private final class RecordingProtocolV3InputSession: ProtocolV3SessionMediaControlling, @unchecked Sendable {
    struct Datagram: Sendable {
        let lane: QUICSemanticLane
        let payload: Data
    }

    private let lock = NSLock()
    private var storedDatagrams: [Datagram] = []

    var datagrams: [Datagram] { lock.withLock { storedDatagrams } }

    func sendControlRequest(type: UInt16, fields: [UInt64: ProtocolV3CBORValue]) throws -> UInt64 { 1 }

    func sendControlResponse(
        type: UInt16,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue],
        isError: Bool
    ) throws {}

    func sendDatagram(
        lane: QUICSemanticLane,
        sessionID: Data,
        channel: UInt8,
        kind: UInt8,
        flags: UInt8,
        objectID: UInt64,
        payload: Data,
        deadlineNanoseconds: UInt64?,
        supersessionKey: UInt64?
    ) {
        lock.withLock { storedDatagrams.append(Datagram(lane: lane, payload: payload)) }
    }
}

@Test
func protocolV3ControllerInputUsesFormatTwoAndPreservesAdvancedState() throws {
    let session = RecordingProtocolV3InputSession()
    let sender = ProtocolV3InputStateSender(
        session: session,
        sessionID: Data(repeating: 0xA5, count: 16),
        mode: .latency,
        usesAbsolutePointer: false,
        failureHandler: { _ in }
    )

    try sender.send(.controllerArrival(
        number: 0,
        activeMask: 1,
        type: 2,
        supportedButtons: 0x104000,
        capabilities: 0x0179
    ))
    try sender.send(.controller(
        number: 0,
        activeMask: 1,
        buttons: 0x104000,
        leftTrigger: 0x20,
        rightTrigger: 0x40,
        leftStickX: -1_000,
        leftStickY: 1_000,
        rightStickX: -2_000,
        rightStickY: 2_000
    ))
    try sender.send(.controllerMotion(number: 0, type: 2, x: 1.5, y: -0.5, z: 0.25))
    try sender.send(.controllerMotion(number: 0, type: 1, x: 1, y: 2, z: -1))
    try sender.send(.controllerBattery(number: 0, state: 3, percentage: 75))
    try sender.send(.controllerTouch(
        number: 0,
        eventType: 1,
        touchpadIndex: 0,
        pointerID: 1,
        x: 0.25,
        y: 0.75,
        pressure: 0.5
    ))

    let payload = try #require(session.datagrams.last?.payload)
    #expect(payload.read(UInt16.self, at: 20) == 2)
    #expect(payload.read(UInt16.self, at: 22) == 2)
    let stateLength = Int(payload.read(UInt16.self, at: 16))
    let state = payload.subdata(in: 32..<(32 + stateLength))
    #expect(state.read(UInt32.self, at: 80) == 1)
    #expect(state[84] == 1)
    #expect(state[85] == 1)

    let controller = 112
    #expect(state[controller] == 0)
    #expect(state[controller + 1] == 2)
    #expect(state.read(UInt16.self, at: controller + 2) == 0x0179)
    #expect(state.read(UInt64.self, at: controller + 4) == 0x104000)
    #expect(state.read(UInt16.self, at: controller + 48) == 7_500)
    #expect(state[controller + 50] == 3)
    #expect(state.read(UInt32.self, at: controller + 52) == 0x104000)

    let touch = controller + 64
    #expect(state.read(UInt32.self, at: touch) == 0x01000001)

    let edgeCount = Int(payload.read(UInt16.self, at: 18))
    let edges = payload.subdata(in: (32 + stateLength)..<payload.count)
    let arrival = (0..<edgeCount)
        .map { edges.subdata(in: ($0 * 32)..<(($0 + 1) * 32)) }
        .first { $0[16] == 4 }
    let arrivalEdge = try #require(arrival)
    #expect(arrivalEdge[17] == 0)
    #expect(arrivalEdge.read(UInt16.self, at: 18) == 0x0179)
    #expect(arrivalEdge.read(UInt32.self, at: 20) == 2)
    #expect(arrivalEdge.read(UInt32.self, at: 24) == 0x104000)
}

private extension Data {
    func read<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        self[offset..<(offset + MemoryLayout<T>.size)].reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
