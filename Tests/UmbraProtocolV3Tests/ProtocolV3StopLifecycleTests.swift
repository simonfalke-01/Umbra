import CryptoKit
import Foundation
import Testing
@testable import UmbraProtocolV3
import UmbraQUICTransport

@Test func stopWaitsForSessionEndedAndReusesAuthenticatedControl() async throws {
    let codec = ProtocolV3CBORCodec()
    let identity = try ProtocolV3ClientIdentity(privateSeed: Data(0..<32))
    let hostKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(32..<64))
    let hostPublicKey = hostKey.publicKey.rawRepresentation
    let hostID = Data(SHA256.hash(data: hostPublicKey).prefix(16))
    let spki = Data(repeating: 0x71, count: 32)
    let trust = try ProtocolV3TrustRecord(
        hostID: hostID,
        hostPublicKey: hostPublicKey,
        tlsSPKIHash: spki,
        clientID: identity.clientID,
        grantedPermissions: 0x12,
        pairingGeneration: 1
    )
    let transport = StopLifecycleTransport(spki: spki)
    let recorder = StopLifecycleEventRecorder()
    let session = ProtocolV3ClientControlSession(
        transport: transport,
        identity: identity,
        mode: .paired(trust, replaceExisting: false),
        randomBytes: { count in
            switch count {
            case 32: Data(repeating: 0x31, count: count)
            case 16: Data(repeating: 0x41, count: count)
            default: throw ProtocolV3WireError.invalidField("test random byte count")
            }
        }
    )
    session.setEventHandler { event in recorder.record(event) }

    try session.start()
    let clientHello = try await transport.request(at: 0)
    let serverHelloFields: [UInt64: ProtocolV3CBORValue] = [
        1: .unsigned(3),
        2: .bytes(Data(repeating: 0x51, count: 32)),
        3: .bytes(hostID),
        4: .bytes(hostPublicKey),
        5: .bytes(spki),
        6: .unsigned(0x17f),
        7: .unsigned(UInt64(QUICTransportProfile.semanticDatagramByteCount)),
        8: .bytes(Data(repeating: 0x41, count: 16)),
    ]
    let serverHello = try stopLifecycleFrame(
        type: 0x0002,
        requestID: 1,
        flags: 1,
        fields: serverHelloFields,
        codec: codec
    )
    transport.receive(type: 0x0002, requestID: 1, flags: 1, fields: serverHelloFields, codec: codec)

    let authorization = try await transport.request(at: 1)
    var authorizationResponseFields: [UInt64: ProtocolV3CBORValue] = [
        1: .unsigned(0),
        2: .bytes(identity.clientID),
        3: .unsigned(0x12),
        4: .unsigned(1),
        5: .null,
        6: .bytes(Data(repeating: 0x41, count: 16)),
    ]
    let unsignedAuthorizationResponse = try stopLifecycleFrame(
        type: 0x0004,
        requestID: 3,
        flags: 1,
        fields: authorizationResponseFields,
        codec: codec
    )
    authorizationResponseFields[7] = .bytes(try hostKey.signature(for: stopLifecycleTranscript(
        domain: "lumen/3 auth host\0",
        spki: spki,
        frames: [
            try stopLifecycleFrame(for: clientHello, codec: codec),
            serverHello,
            try stopLifecycleFrame(for: authorization, codec: codec),
            unsignedAuthorizationResponse,
        ]
    )))
    transport.receive(
        type: 0x0004,
        requestID: 3,
        flags: 1,
        fields: authorizationResponseFields,
        codec: codec
    )
    try await stopLifecycleWait { recorder.authenticatedCount == 1 }

    let firstSessionID = Data(repeating: 0x61, count: 16)
    let firstIntent = Data(repeating: 0x62, count: 16)
    let firstStartID = try session.beginStart(fields: stopLifecycleStartFields(intent: firstIntent))
    #expect(firstStartID == 5)
    _ = try await transport.request(at: 2)
    transport.receive(
        type: 0x0101,
        requestID: firstStartID,
        flags: 1,
        fields: stopLifecycleStartResponse(intent: firstIntent, sessionID: firstSessionID),
        codec: codec
    )
    try await stopLifecycleWait { transport.currentActiveSessionID == firstSessionID }

    let firstStopIntent = Data(repeating: 0x63, count: 16)
    let firstStopID = try session.stop(fields: stopLifecycleStopFields(
        sessionID: firstSessionID,
        intent: firstStopIntent
    ))
    #expect(firstStopID == 7)
    _ = try await transport.request(at: 3)
    transport.receive(
        type: 0x0131,
        requestID: firstStopID,
        flags: 1,
        fields: stopLifecycleStopResponse(sessionID: firstSessionID, intent: firstStopIntent),
        codec: codec
    )
    try await stopLifecycleWait { transport.currentActiveSessionID == nil }
    #expect(throws: ProtocolV3ClientError.invalidState) {
        try session.beginStart(fields: stopLifecycleStartFields(intent: Data(repeating: 0x70, count: 16)))
    }

    transport.receive(
        type: 0x0133,
        requestID: 0,
        flags: 0,
        fields: stopLifecycleEndedFields(sessionID: firstSessionID),
        codec: codec
    )
    try await stopLifecycleWait { recorder.endedSessionIDs == [firstSessionID] }

    let secondSessionID = Data(repeating: 0x72, count: 16)
    let secondIntent = Data(repeating: 0x73, count: 16)
    let secondStartID = try session.beginStart(fields: stopLifecycleStartFields(intent: secondIntent))
    #expect(secondStartID == 9)
    _ = try await transport.request(at: 4)
    transport.receive(
        type: 0x0101,
        requestID: secondStartID,
        flags: 1,
        fields: stopLifecycleStartResponse(intent: secondIntent, sessionID: secondSessionID),
        codec: codec
    )
    try await stopLifecycleWait { transport.currentActiveSessionID == secondSessionID }

    let secondStopIntent = Data(repeating: 0x74, count: 16)
    let secondStopID = try session.stop(fields: stopLifecycleStopFields(
        sessionID: secondSessionID,
        intent: secondStopIntent
    ))
    #expect(secondStopID == 11)
    transport.receive(
        type: 0x0131,
        requestID: secondStopID,
        flags: 1,
        fields: stopLifecycleStopResponse(sessionID: secondSessionID, intent: secondStopIntent),
        codec: codec
    )
    transport.receive(
        type: 0x0133,
        requestID: 0,
        flags: 0,
        fields: stopLifecycleEndedFields(sessionID: secondSessionID),
        codec: codec
    )
    try await stopLifecycleWait {
        recorder.endedSessionIDs == [firstSessionID, secondSessionID]
    }
    #expect(transport.cancelCount == 0)
    #expect(recorder.failureCount == 0)
}

private final class StopLifecycleTransport: QUICTransportProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let spki: Data
    private var requests: [QUICOutboundRequest] = []
    private var activeSessionID: Data?
    private var storedCancelCount = 0
    var eventHandler: (@Sendable (QUICTransportEvent) -> Void)?
    var authenticationHandler: (@Sendable (QUICApplicationAuthenticationHandoff) -> Void)?

    init(spki: Data) {
        self.spki = spki
    }

    var currentActiveSessionID: Data? { lock.withLock { activeSessionID } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }

    func start() throws {
        authenticationHandler?(.init(leafSPKISHA256: spki))
    }

    func send(_ request: QUICOutboundRequest) {
        lock.withLock { requests.append(request) }
    }

    func setActiveSessionID(_ sessionID: Data?) throws {
        lock.withLock { activeSessionID = sessionID }
    }

    func applicationHelloDidComplete(success _: Bool) {}
    func applicationAuthenticationDidComplete(success _: Bool) {}
    func acceptInboundBulk(requestID _: UInt64, objectID _: UInt64) {}
    func rejectInboundBulk(requestID _: UInt64, objectID _: UInt64) {}

    func cancel() {
        lock.withLock { storedCancelCount += 1 }
    }

    func request(at index: Int) async throws -> QUICOutboundRequest {
        try await stopLifecycleWait {
            self.lock.withLock { self.requests.count > index }
        }
        return lock.withLock { requests[index] }
    }

    func receive(
        type: UInt16,
        requestID: UInt64,
        flags: UInt8,
        fields: [UInt64: ProtocolV3CBORValue],
        codec: ProtocolV3CBORCodec
    ) {
        let payload = try! codec.encode(.map(fields))
        eventHandler?(.inbound(.init(
            lane: .control,
            payload: payload,
            receivedAtNanoseconds: 1,
            semanticSequence: nil,
            objectID: nil,
            controlFlags: flags,
            controlType: type,
            requestID: requestID
        )))
    }
}

private final class StopLifecycleEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProtocolV3ClientEvent] = []

    var authenticatedCount: Int {
        lock.withLock { events.count { if case .authenticated = $0 { true } else { false } } }
    }

    var endedSessionIDs: [Data] {
        lock.withLock {
            events.compactMap {
                guard case let .controlMessage(type, requestID, fields) = $0,
                      type == 0x0133, requestID == 0 else { return nil }
                return fields[1]?.bytesValue
            }
        }
    }

    var failureCount: Int {
        lock.withLock { events.count { if case .failed = $0 { true } else { false } } }
    }

    func record(_ event: ProtocolV3ClientEvent) {
        lock.withLock { events.append(event) }
    }
}

private func stopLifecycleStartFields(intent: Data) -> [UInt64: ProtocolV3CBORValue] {
    var fields = Dictionary(uniqueKeysWithValues: (1...17).map { (UInt64($0), ProtocolV3CBORValue.null) })
    fields[1] = .bytes(intent)
    fields[2] = .unsigned(0)
    fields[3] = .unsigned(1)
    fields[4] = .unsigned(1_920)
    fields[5] = .unsigned(1_080)
    fields[12] = .unsigned(UInt64(QUICTransportProfile.semanticDatagramByteCount))
    fields[13] = .bytes(Data(repeating: 0x42, count: 16))
    return fields
}

private func stopLifecycleStartResponse(
    intent: Data,
    sessionID: Data
) -> [UInt64: ProtocolV3CBORValue] {
    var fields = Dictionary(uniqueKeysWithValues: (1...23).map { (UInt64($0), ProtocolV3CBORValue.null) })
    fields[1] = .unsigned(0)
    fields[2] = .bytes(intent)
    fields[3] = .bytes(sessionID)
    fields[11] = .unsigned(UInt64(QUICTransportProfile.semanticDatagramByteCount))
    return fields
}

private func stopLifecycleStopFields(
    sessionID: Data,
    intent: Data
) -> [UInt64: ProtocolV3CBORValue] {
    [1: .bytes(sessionID), 2: .unsigned(0), 3: .unsigned(1), 4: .bytes(intent)]
}

private func stopLifecycleStopResponse(
    sessionID: Data,
    intent: Data
) -> [UInt64: ProtocolV3CBORValue] {
    [1: .unsigned(0), 2: .bytes(sessionID), 3: .bytes(intent), 4: .boolean(false)]
}

private func stopLifecycleEndedFields(sessionID: Data) -> [UInt64: ProtocolV3CBORValue] {
    [
        1: .bytes(sessionID), 2: .unsigned(1), 3: .unsigned(1), 4: .boolean(false),
        5: .unsigned(0), 6: .unsigned(0), 7: .unsigned(0), 8: .unsigned(0),
    ]
}

private func stopLifecycleFrame(
    for request: QUICOutboundRequest,
    codec _: ProtocolV3CBORCodec
) throws -> Data {
    guard case let .control(flags, type, requestID) = request.wireMetadata else {
        throw ProtocolV3WireError.invalidField("test control metadata")
    }
    return stopLifecycleFrame(
        type: type,
        requestID: requestID,
        flags: flags,
        payload: request.payload
    )
}

private func stopLifecycleFrame(
    type: UInt16,
    requestID: UInt64,
    flags: UInt8,
    fields: [UInt64: ProtocolV3CBORValue],
    codec: ProtocolV3CBORCodec
) throws -> Data {
    try stopLifecycleFrame(
        type: type,
        requestID: requestID,
        flags: flags,
        payload: codec.encode(.map(fields))
    )
}

private func stopLifecycleFrame(
    type: UInt16,
    requestID: UInt64,
    flags: UInt8,
    payload: Data
) -> Data {
    var output = Data("ULC3".utf8)
    output.append(3)
    output.append(flags)
    stopLifecycleAppend(type, to: &output)
    stopLifecycleAppend(requestID, to: &output)
    stopLifecycleAppend(UInt32(payload.count), to: &output)
    stopLifecycleAppend(UInt32(0), to: &output)
    output.append(payload)
    return output
}

private func stopLifecycleTranscript(
    domain: String,
    spki: Data,
    frames: [Data]
) -> Data {
    var output = Data(domain.utf8)
    output.append(spki)
    for frame in frames {
        stopLifecycleAppend(UInt32(frame.count), to: &output)
        output.append(frame)
    }
    return output
}

private func stopLifecycleAppend<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

private func stopLifecycleWait(
    timeout: Duration = .seconds(2),
    until condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw ProtocolV3WireError.invalidField("test timeout") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
