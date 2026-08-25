import Foundation
import Testing
import UmbraQUICTransport
@testable import UmbraIntegration

@Test
func protocolV3ControllerFeedbackDecodesAllProductionCommands() throws {
    let rumble = try ProtocolV3SessionMediaCoordinator.decodeControllerFeedback(
        message(command: 1, value: [0x12, 0x34, 0xAB, 0xCD])
    )
    #expect(rumble.inputGeneration == 7)
    #expect(rumble.controllerGeneration == 3)
    #expect(rumble.controller == 2)
    #expect(rumble.command == .rumble(lowFrequency: 0x1234, highFrequency: 0xABCD))

    let trigger = try ProtocolV3SessionMediaCoordinator.decodeControllerFeedback(
        message(command: 2, value: [0, 1, 0, 2])
    )
    #expect(trigger.command == .triggerRumble(left: 1, right: 2))

    let motion = try ProtocolV3SessionMediaCoordinator.decodeControllerFeedback(
        message(command: 3, value: [2, 0, 0, 100])
    )
    #expect(motion.command == .motionState(type: 2, reportRateHz: 100))

    let led = try ProtocolV3SessionMediaCoordinator.decodeControllerFeedback(
        message(command: 4, value: [1, 2, 3])
    )
    #expect(led.command == .led(red: 1, green: 2, blue: 3))

    let adaptiveValue = [UInt8(0x0C), 1, 2, 0]
        + Array(repeating: UInt8(0x11), count: 10)
        + Array(repeating: UInt8(0x22), count: 10)
    let adaptive = try ProtocolV3SessionMediaCoordinator.decodeControllerFeedback(
        message(command: 5, value: adaptiveValue)
    )
    #expect(adaptive.command == .adaptiveTriggers(
        flags: 0x0C,
        leftType: 1,
        rightType: 2,
        left: Data(repeating: 0x11, count: 10),
        right: Data(repeating: 0x22, count: 10)
    ))
}

@Test
func protocolV3ControllerFeedbackRejectsStaleAndHostileLayouts() throws {
    var staleObject = message(command: 1, value: [0, 1, 0, 2])
    staleObject = QUICInboundMessage(
        lane: staleObject.lane,
        payload: staleObject.payload,
        receivedAtNanoseconds: staleObject.receivedAtNanoseconds,
        semanticSequence: staleObject.semanticSequence,
        objectID: 8,
        controlFlags: nil,
        controlType: nil,
        requestID: nil,
        datagramChannel: 1,
        datagramKind: 4,
        datagramFlags: 0
    )
    #expect(throws: ProtocolV3SessionMediaError.invalidInput) {
        try ProtocolV3SessionMediaCoordinator.decodeControllerFeedback(staleObject)
    }

    var reserved = message(command: 3, value: [2, 0, 0, 100])
    var payload = reserved.payload
    payload[16] = 1
    reserved = QUICInboundMessage(
        lane: .inputState,
        payload: payload,
        receivedAtNanoseconds: 1,
        semanticSequence: 1,
        objectID: 7,
        controlFlags: nil,
        controlType: nil,
        requestID: nil,
        datagramChannel: 1,
        datagramKind: 4,
        datagramFlags: 0
    )
    #expect(throws: ProtocolV3SessionMediaError.invalidInput) {
        try ProtocolV3SessionMediaCoordinator.decodeControllerFeedback(reserved)
    }

    #expect(throws: ProtocolV3SessionMediaError.invalidInput) {
        try ProtocolV3SessionMediaCoordinator.decodeControllerFeedback(
            message(command: 5, value: [1, 0, 0, 0] + Array(repeating: 0, count: 20))
        )
    }
}

@Test
func protocolV3RTTTelemetryDecodesOnlyBoundedMatchingGenerations() throws {
    let telemetry = try ProtocolV3SessionMediaCoordinator.decodeRTTTelemetry(
        rttMessage(generation: 9, smoothed: 4_000, minimum: 3_000, variation: 1_000)
    )
    #expect(telemetry == ProtocolV3RTTTelemetry(
        generation: 9,
        smoothedMicroseconds: 4_000,
        minimumMicroseconds: 3_000,
        variationMicroseconds: 1_000
    ))

    #expect(throws: ProtocolV3SessionMediaError.invalidInput) {
        try ProtocolV3SessionMediaCoordinator.decodeRTTTelemetry(
            rttMessage(generation: 9, objectID: 8, smoothed: 4_000, minimum: 3_000, variation: 1_000)
        )
    }
    #expect(throws: ProtocolV3SessionMediaError.invalidInput) {
        try ProtocolV3SessionMediaCoordinator.decodeRTTTelemetry(
            rttMessage(generation: 9, smoothed: 4_000, minimum: 4_001, variation: 1_000)
        )
    }
    #expect(throws: ProtocolV3SessionMediaError.invalidInput) {
        try ProtocolV3SessionMediaCoordinator.decodeRTTTelemetry(
            rttMessage(generation: 9, smoothed: 4_000, minimum: 3_000, variation: 1_000_001)
        )
    }
}

private func message(command: UInt8, value: [UInt8]) -> QUICInboundMessage {
    var payload = Data(repeating: 0, count: 40)
    payload[3] = 7
    payload[7] = 3
    payload[8] = 2
    payload[9] = command
    payload[10] = UInt8(value.count >> 8)
    payload[11] = UInt8(value.count)
    payload.replaceSubrange(12..<(12 + value.count), with: value)
    return QUICInboundMessage(
        lane: .inputState,
        payload: payload,
        receivedAtNanoseconds: 1,
        semanticSequence: 1,
        objectID: 7,
        controlFlags: nil,
        controlType: nil,
        requestID: nil,
        datagramChannel: 1,
        datagramKind: 4,
        datagramFlags: 0
    )
}

private func rttMessage(
    generation: UInt64,
    objectID: UInt64? = nil,
    smoothed: UInt32,
    minimum: UInt32,
    variation: UInt32
) -> QUICInboundMessage {
    var payload = Data()
    appendBigEndian(generation, to: &payload)
    appendBigEndian(smoothed, to: &payload)
    appendBigEndian(minimum, to: &payload)
    appendBigEndian(variation, to: &payload)
    appendBigEndian(UInt32(0), to: &payload)
    return QUICInboundMessage(
        lane: .hostEvents,
        payload: payload,
        receivedAtNanoseconds: 1,
        semanticSequence: generation,
        objectID: objectID ?? generation,
        controlFlags: nil,
        controlType: nil,
        requestID: nil,
        datagramChannel: 5,
        datagramKind: 1,
        datagramFlags: 0
    )
}

private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}
