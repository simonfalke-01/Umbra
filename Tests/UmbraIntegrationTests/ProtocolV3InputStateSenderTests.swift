import Foundation
import Testing
import UmbraProtocolV3
import UmbraQUICTransport
@testable import UmbraIntegration

private final class RecordingProtocolV3InputSession: ProtocolV3SessionMediaControlling, @unchecked Sendable {
    struct Datagram: Sendable {
        let lane: QUICSemanticLane
        let payload: Data
        let objectID: UInt64
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
        lock.withLock {
            storedDatagrams.append(Datagram(lane: lane, payload: payload, objectID: objectID))
        }
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
    try sender.send(.controllerArrival(
        number: 0,
        activeMask: 1,
        type: 2,
        supportedButtons: 0x104000,
        capabilities: 0x0179
    ))
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

@Test
func protocolV3ControllerFeedbackRequiresExactInputAndControllerGenerations() throws {
    let session = RecordingProtocolV3InputSession()
    let sender = ProtocolV3InputStateSender(
        session: session,
        sessionID: Data(repeating: 0xA5, count: 16),
        mode: .latency,
        usesAbsolutePointer: false,
        inputGeneration: 7,
        failureHandler: { _ in }
    )

    try sender.send(.controllerArrival(
        number: 1,
        activeMask: 2,
        type: 2,
        supportedButtons: 0,
        capabilities: 0x007F
    ))
    #expect(sender.acceptsControllerFeedback(
        inputGeneration: 7,
        controller: 1,
        controllerGeneration: 1
    ))
    #expect(!sender.acceptsControllerFeedback(
        inputGeneration: 8,
        controller: 1,
        controllerGeneration: 1
    ))
    #expect(!sender.acceptsControllerFeedback(
        inputGeneration: 7,
        controller: 1,
        controllerGeneration: 2
    ))

    try sender.send(.controllerArrival(
        number: 1,
        activeMask: 2,
        type: 2,
        supportedButtons: 0,
        capabilities: 0x007F
    ))
    #expect(sender.acceptsControllerFeedback(
        inputGeneration: 7,
        controller: 1,
        controllerGeneration: 1
    ))

    try sender.send(.controller(
        number: 1,
        activeMask: 0,
        buttons: 0,
        leftTrigger: 0,
        rightTrigger: 0,
        leftStickX: 0,
        leftStickY: 0,
        rightStickX: 0,
        rightStickY: 0
    ))
    try sender.send(.controllerArrival(
        number: 1,
        activeMask: 2,
        type: 2,
        supportedButtons: 0,
        capabilities: 0x007F
    ))
    #expect(!sender.acceptsControllerFeedback(
        inputGeneration: 7,
        controller: 1,
        controllerGeneration: 1
    ))
    #expect(sender.acceptsControllerFeedback(
        inputGeneration: 7,
        controller: 1,
        controllerGeneration: 2
    ))

    try sender.updateInputGeneration(8)
    #expect(sender.acceptsControllerFeedback(
        inputGeneration: 8,
        controller: 1,
        controllerGeneration: 2
    ))
}

@Test
func protocolV3ControllerMetadataRebindIncrementsGenerationAndRejectsStaleFeedback() throws {
    let sender = ProtocolV3InputStateSender(
        session: RecordingProtocolV3InputSession(),
        sessionID: Data(repeating: 0xA5, count: 16),
        mode: .latency,
        usesAbsolutePointer: false,
        inputGeneration: 9,
        failureHandler: { _ in }
    )

    try sender.send(.controllerArrival(
        number: 0, activeMask: 1, type: 1,
        supportedButtons: 0x0003, capabilities: 0x0001
    ))
    #expect(sender.acceptsControllerFeedback(
        inputGeneration: 9, controller: 0, controllerGeneration: 1
    ))

    #expect(throws: ProtocolV3InputError.invalidCommand) {
        try sender.send(.controllerArrival(
            number: 0, activeMask: 1, type: 5,
            supportedButtons: 0x0013, capabilities: 0x0003
        ))
    }
    try sender.send(.controller(
        number: 0, activeMask: 0, buttons: 0,
        leftTrigger: 0, rightTrigger: 0,
        leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0
    ))
    try sender.send(.controllerArrival(
        number: 0, activeMask: 1, type: 5,
        supportedButtons: 0x0013, capabilities: 0x0003
    ))
    #expect(!sender.acceptsControllerFeedback(
        inputGeneration: 9, controller: 0, controllerGeneration: 1
    ))
    #expect(sender.acceptsControllerFeedback(
        inputGeneration: 9, controller: 0, controllerGeneration: 2
    ))

    try sender.send(.controllerArrival(
        number: 0, activeMask: 1, type: 5,
        supportedButtons: 0x0013, capabilities: 0x0003
    ))
    #expect(sender.acceptsControllerFeedback(
        inputGeneration: 9, controller: 0, controllerGeneration: 2
    ))
}

@Test
func protocolV3CompactInputFitsSixteenControllersAndBudgetsEdgesBeforeDirtyTouches() throws {
    let session = RecordingProtocolV3InputSession()
    let sender = ProtocolV3InputStateSender(
        session: session,
        sessionID: Data(repeating: 0xA5, count: 16),
        mode: .latency,
        usesAbsolutePointer: false,
        supportsCompactStateFormat: true,
        failureHandler: { _ in }
    )

    for controller in UInt8(0)..<16 {
        try sender.send(.controllerArrival(
            number: controller,
            activeMask: UInt16.max,
            type: 5,
            supportedButtons: 1,
            capabilities: 1
        ))
    }

    var payload = try #require(session.datagrams.last?.payload)
    #expect(payload.count == 1_104)
    #expect(payload.read(UInt16.self, at: 20) == 3)
    #expect(payload.read(UInt16.self, at: 22) == 2)
    let stateLength = Int(payload.read(UInt16.self, at: 16))
    #expect(stateLength == 1_008)
    let state = payload.subdata(in: 32..<(32 + stateLength))
    #expect(state[84] == 16)
    #expect(state[85] == 0)
    #expect(state[87] == 3)
    #expect(state.read(UInt32.self, at: 80) == UInt32(UInt16.max))
    #expect(state[112] == 0)
    #expect(state[112 + 15 * 56] == 15)
    #expect(state.read(UInt32.self, at: 112 + 15 * 56 + 52) == 1)
    #expect(sender.acceptsControllerFeedback(
        inputGeneration: 1,
        controller: 15,
        controllerGeneration: 1
    ))
    #expect(payload.read(UInt16.self, at: 18) == 2)
    #expect(payload.read(UInt64.self, at: 32 + stateLength) == 1)
    #expect(payload.read(UInt64.self, at: 32 + stateLength + 32) == 2)

    sender.acknowledge(appliedEdgeID: 16)
    try sender.send(.scroll(vertical: 1, horizontal: 0))
    payload = try #require(session.datagrams.last?.payload)
    #expect(payload.count == 1_040)
    #expect(payload.read(UInt16.self, at: 18) == 0)

    try sender.send(.keyboard(keyCode: 1, action: 0x03, modifiers: 0, flags: 0))
    try sender.send(.keyboard(keyCode: 2, action: 0x03, modifiers: 0, flags: 0))
    try sender.send(.touch(
        pointerID: 9,
        eventType: 3,
        x: 0.25,
        y: 0.75,
        pressure: 0.5
    ))
    payload = try #require(session.datagrams.last?.payload)
    let nextStateLength = Int(payload.read(UInt16.self, at: 16))
    #expect(payload.count == 1_104)
    #expect(payload.read(UInt64.self, at: 32 + nextStateLength) == 17)
    #expect(payload[payload.startIndex + 32 + 85] == 0)

    sender.acknowledge(appliedEdgeID: 18)
    try sender.send(.touch(
        pointerID: 9,
        eventType: 3,
        x: 0.5,
        y: 0.5,
        pressure: 1
    ))
    payload = try #require(session.datagrams.last?.payload)
    let drainedStateLength = Int(payload.read(UInt16.self, at: 16))
    #expect(payload.count == 1_072)
    #expect(payload.read(UInt16.self, at: 18) == 0)
    #expect(payload[payload.startIndex + 32 + 85] == 1)
    #expect(drainedStateLength == 1_040)
}

@Test
func protocolV3FormatTwoFifteenControllersWithPendingEdgeDoesNotAdvanceSequence() throws {
    let session = RecordingProtocolV3InputSession()
    let degradations = LockedStrings()
    let sender = ProtocolV3InputStateSender(
        session: session,
        sessionID: Data(repeating: 0xA5, count: 16),
        mode: .latency,
        usesAbsolutePointer: false,
        degradationHandler: { degradations.append($0) },
        failureHandler: { _ in }
    )

    for controller in UInt8(0)..<14 {
        try sender.send(.controllerArrival(
            number: controller, activeMask: UInt16.max, type: 5,
            supportedButtons: 1, capabilities: 1
        ))
        sender.acknowledge(appliedEdgeID: UInt64(controller) + 1)
    }
    let beforeDegradation = try #require(session.datagrams.last)

    try sender.send(.controllerArrival(
        number: 14, activeMask: UInt16.max, type: 5,
        supportedButtons: 1, capabilities: 1
    ))
    #expect(session.datagrams.last?.objectID == beforeDegradation.objectID)
    #expect(degradations.values.count == 1)
    #expect(degradations.values[0].contains("15 format-2 controllers"))
    let resetState = try sender.inputResetStateBlock()
    #expect(resetState.count == 1_072)
    #expect(resetState[84] == 15)

    try sender.send(.keyboard(keyCode: 1, action: 0x03, modifiers: 0, flags: 0))
    #expect(session.datagrams.last?.objectID == beforeDegradation.objectID)
    #expect(degradations.values.count == 1)

    try sender.send(.controller(
        number: 14,
        activeMask: Int16(bitPattern: 0x3FFF),
        buttons: 0,
        leftTrigger: 0,
        rightTrigger: 0,
        leftStickX: 0,
        leftStickY: 0,
        rightStickX: 0,
        rightStickY: 0
    ))
    #expect(session.datagrams.last?.objectID == beforeDegradation.objectID + 1)
    #expect(try #require(session.datagrams.last?.payload.count) <= 1_108)
}

@Test
func protocolV3InputCapShrinkDoesNotAdvanceSequenceOrEnqueueOversize() throws {
    let session = RecordingProtocolV3InputSession()
    let degradations = LockedStrings()
    let sender = ProtocolV3InputStateSender(
        session: session,
        sessionID: Data(repeating: 0xA5, count: 16),
        mode: .latency,
        usesAbsolutePointer: false,
        supportsCompactStateFormat: true,
        degradationHandler: { degradations.append($0) },
        failureHandler: { _ in }
    )
    try sender.send(.scroll(vertical: 1, horizontal: 0))
    let first = try #require(session.datagrams.last)

    sender.updateMaximumPayloadByteCount(100)
    try sender.send(.scroll(vertical: 1, horizontal: 0))
    #expect(session.datagrams.count == 1)
    #expect(degradations.values.count == 1)

    sender.updateMaximumPayloadByteCount(1_108)
    try sender.send(.scroll(vertical: 1, horizontal: 0))
    let recovered = try #require(session.datagrams.last)
    #expect(recovered.objectID == first.objectID + 1)
    #expect(recovered.payload.count <= 1_108)
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private extension Data {
    func read<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        self[offset..<(offset + MemoryLayout<T>.size)].reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
