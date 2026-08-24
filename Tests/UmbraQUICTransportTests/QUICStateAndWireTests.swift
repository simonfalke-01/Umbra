import CryptoKit
import Foundation
import Testing
@testable import UmbraQUICTransport

@Suite("QUIC v3 state, wire, migration, and trust")
struct QUICStateAndWireTests {
    @Test("state machine makes failed and cancelled terminal")
    func terminalStates() throws {
        let failed = QUICSessionStateMachine()
        _ = try failed.start()
        #expect(failed.fail(reason: "x") == .failed("x"))
        #expect(failed.cancel() == .failed("x"))
        #expect(failed.fail(reason: "y") == .failed("x"))

        let cancelled = QUICSessionStateMachine()
        _ = try cancelled.start()
        #expect(cancelled.cancel() == .cancelled)
        #expect(cancelled.fail(reason: "late") == .cancelled)
    }

    @Test("authentication requires verification and readiness")
    func orderedAuthenticationState() throws {
        let state = QUICSessionStateMachine()
        #expect(try state.start() == .preparing)
        #expect(try state.beginPeerVerification() == .verifyingPeer)
        #expect(try state.networkBecameReady() == .verifyingPeer)
        #expect(state.peerVerificationCompleted(success: true) == .authenticatingApplication)
        #expect(try state.applicationAuthenticationCompleted(success: true) == .ready)
    }

    @Test("temporary waiting restores the exact prior state")
    func waitingRecovery() throws {
        let state = QUICSessionStateMachine()
        _ = try state.start()
        _ = try state.beginPeerVerification()
        _ = state.peerVerificationCompleted(success: true)
        _ = try state.networkBecameReady()
        _ = try state.applicationAuthenticationCompleted(success: true)
        #expect(state.wait(reason: "migration") == .waiting("migration"))
        #expect(try state.networkRecovered() == .ready)
    }

    @Test("ULC3 client hello oracle frame decodes exactly across fragmentation")
    func controlOracle() throws {
        let oracle = hex(
            "554c43330300000100000000000000010000005600000000" +
            "a801030203035820edfdcfe57755b4c812057de3ef1972d5320bcaff9a3e8c3e" +
            "b6439760ae5ec10d0419017f0582010206f60750000102030405060708090a0b" +
            "0c0d0e0f0850e20470e65c123567174f47921b44d67b"
        )
        let decoder = QUICControlFrameDecoder()
        #expect(try decoder.append(oracle.prefix(17)) == [])
        let frames = try decoder.append(oracle.dropFirst(17))
        let frame = try #require(frames.only)
        #expect(frame.type == 1)
        #expect(frame.requestID == 1)
        #expect(frame.payload == oracle.dropFirst(24))
    }

    @Test("ULC3 permits request-zero events but rejects reserved and oversized frames")
    func controlHostile() throws {
        let payload = Data([0xA0])
        let event = try QUICWireCodec.controlHeader(
            flags: 0,
            type: 0x0200,
            requestID: 0,
            payloadByteCount: 1
        ) + payload
        #expect(try QUICControlFrameDecoder().append(event).first?.requestID == 0)
        let response = try QUICWireCodec.controlHeader(
            flags: 0x03,
            type: 0x0004,
            requestID: 1,
            payloadByteCount: 1
        ) + payload
        #expect(try QUICControlFrameDecoder().append(response).first?.flags == 0x03)
        var errorWithoutResponse = event
        errorWithoutResponse[5] = 0x02
        #expect(throws: QUICWireCodec.WireError.malformed) {
            try QUICControlFrameDecoder().append(errorWithoutResponse)
        }
        var reserved = event
        reserved[5] = 0x08
        #expect(throws: QUICWireCodec.WireError.malformed) {
            try QUICControlFrameDecoder().append(reserved)
        }
        #expect(throws: QUICWireCodec.WireError.oversized) {
            try QUICWireCodec.controlHeader(
                flags: 0,
                type: 1,
                requestID: 1,
                payloadByteCount: QUICWireCodec.maximumControlPayloadByteCount + 1
            )
        }
    }

    @Test("ULM3 outbound input-state header matches the checked-in v3 oracle")
    func outboundDatagramOracle() throws {
        let session = Data((0xC0...0xCF).map(UInt8.init))
        let header = try QUICWireCodec.datagramHeader(
            sessionID: session,
            channel: 1,
            kind: 1,
            flags: 0,
            sequence: 43,
            objectID: 77,
            payloadByteCount: 144
        )
        #expect(
            header == hex(
                "554c4d3303010100002c0090c0c1c2c3c4c5c6c7c8c9cacbcccdcecf" +
                "000000000000002b000000000000004d"
            )
        )
    }

    @Test("ULM3 inbound video oracle exposes session, sequence, object, and payload slice")
    func inboundDatagramOracle() throws {
        let oracle = validVideoRecord()
        let decoded = try QUICWireCodec.decodeDatagram(oracle)
        #expect(decoded.channel == 2)
        #expect(decoded.kind == 1)
        #expect(decoded.flags == 5)
        #expect(decoded.semanticSequence == 46)
        #expect(decoded.objectID == 9_001)
        #expect(decoded.payload.count == 128)
        #expect(try QUICWireCodec.inboundLane(channel: 2, kind: 1) == .video)
    }

    @Test("ULM3 rejects wrong direction, repair, forbidden flags, and length abuse")
    func hostileDatagrams() throws {
        let session = Data(repeating: 1, count: 16)
        let outbound = try QUICWireCodec.datagramHeader(
            sessionID: session,
            channel: 1,
            kind: 1,
            flags: 0,
            sequence: 1,
            objectID: 1,
            payloadByteCount: 1
        ) + Data([0])
        #expect(throws: QUICWireCodec.WireError.malformed) {
            try QUICWireCodec.decodeDatagram(outbound)
        }

        var repair = inboundDatagram(channel: 2, kind: 2, flags: 0)
        #expect(throws: QUICWireCodec.WireError.malformed) { try QUICWireCodec.decodeDatagram(repair) }
        repair = inboundDatagram(channel: 3, kind: 1, flags: 1)
        #expect(throws: QUICWireCodec.WireError.malformed) { try QUICWireCodec.decodeDatagram(repair) }
        repair = inboundDatagram(channel: 2, kind: 1, flags: 0x02)
        #expect(throws: QUICWireCodec.WireError.malformed) { try QUICWireCodec.decodeDatagram(repair) }
        var missingFinal = validVideoRecord()
        missingFinal[7] = 0x01
        #expect(throws: QUICWireCodec.WireError.malformed) { try QUICWireCodec.decodeDatagram(missingFinal) }
        var configFlag = validVideoRecord()
        configFlag[7] = 0x07
        #expect(throws: QUICWireCodec.WireError.malformed) { try QUICWireCodec.decodeDatagram(configFlag) }
        var mismatch = inboundDatagram(channel: 3, kind: 1, flags: 0)
        mismatch[10] = 0
        mismatch[11] = 2
        #expect(throws: QUICWireCodec.WireError.oversized) { try QUICWireCodec.decodeDatagram(mismatch) }

        var feedback = Data(repeating: 0, count: 40)
        feedback[16] = 2
        feedback[17] = 2
        feedback[32] = 0
        feedback[33] = 0
        feedback[34] = 0
        feedback[35] = 2
        feedback[36] = 0
        feedback[37] = 1
        feedback[38] = 0
        feedback[39] = 1
        #expect(throws: QUICWireCodec.WireError.malformed) {
            try QUICWireCodec.validateOutboundPayload(
                channel: 2,
                kind: 3,
                objectID: 1,
                payload: feedback
            )
        }
    }

    @Test("semantic sequence tracker rejects duplicates, stale values, zero, and wrap")
    func sequenceTracker() {
        let tracker = QUICReceiveSequenceTracker()
        #expect(tracker.observe(channel: 2, sequence: 10) == .accepted)
        #expect(tracker.observe(channel: 2, sequence: 10) == .duplicate)
        #expect(tracker.observe(channel: 2, sequence: 9) == .accepted)
        #expect(tracker.observe(channel: 2, sequence: 9) == .duplicate)
        #expect(tracker.observe(channel: 2, sequence: 0) == .staleOrWrapped)
        #expect(tracker.observe(channel: 2, sequence: .max) == .staleOrWrapped)
        #expect(tracker.observe(channel: 2, sequence: 1) == .accepted)
        #expect(tracker.observe(channel: 3, sequence: 1, objectID: 48_000) == .accepted)
        #expect(tracker.observe(channel: 3, sequence: 2, objectID: 47_999) == .accepted)
        #expect(tracker.observe(channel: 4, sequence: 2_048) == .accepted)
        #expect(tracker.observe(channel: 4, sequence: 1_025) == .accepted)
        #expect(tracker.observe(channel: 4, sequence: 1_025) == .duplicate)
        #expect(tracker.observe(channel: 4, sequence: 1_024) == .staleOrWrapped)
        let threshold = UInt64.max - 1_023
        #expect(tracker.observe(channel: 5, sequence: threshold - 1) == .accepted)
        #expect(tracker.observe(channel: 5, sequence: threshold) == .staleOrWrapped)
    }

    @Test("hot-path replay window retains one fixed bitmap allocation")
    func replayWindowStorageStability() throws {
        let tracker = QUICReceiveSequenceTracker()
        #expect(tracker.observe(channel: 2, sequence: 1) == .accepted)
        let initialAddress = try #require(tracker.debugWindowStorageAddress(channel: 2))
        for sequence in 2...100_000 {
            #expect(tracker.observe(channel: 2, sequence: UInt64(sequence)) == .accepted)
        }
        #expect(tracker.debugWindowStorageAddress(channel: 2) == initialAddress)
    }

    @Test("migration tracker ignores initial and duplicate paths")
    func migrationTracking() throws {
        let tracker = QUICPathMigrationTracker()
        let wired = path(wifi: false)
        let wifi = path(wifi: true)
        #expect(tracker.observe(wired) == nil)
        #expect(tracker.observe(wired) == nil)
        #expect(try #require(tracker.observe(wifi)).generation == 1)
    }

    @Test("leaf SPKI pin hashes the complete DER SubjectPublicKeyInfo")
    func spkiPinning() throws {
        let spki = sequence(integer(42), bitString([1, 2, 3, 4]))
        let certificate = sequence(
            sequence(integer(1), sequence(), sequence(), sequence(), sequence(), spki),
            sequence(),
            bitString([0])
        )
        let expected = Data(SHA256.hash(data: spki))
        #expect(try QUICLeafSPKIVerifier.verify(certificateDER: certificate, expectedSHA256: expected) == expected)
        #expect(throws: QUICLeafSPKIVerifier.VerificationError.pinMismatch) {
            try QUICLeafSPKIVerifier.verify(
                certificateDER: certificate,
                expectedSHA256: Data(repeating: 0, count: 32)
            )
        }
    }

    @Test("configuration is immutable lumen/3 with exact semantic cap")
    func configurationInvariants() {
        let config = QUICTransportConfiguration(
            endpoint: .init(host: "127.0.0.1", port: 48_030),
            expectedLeafSPKISHA256: Data(count: 32),
            mode: .latency
        )
        #expect(config.isValid)
        #expect(QUICTransportConfiguration.applicationProtocol == "lumen/3")
        #expect(QUICTransportProfile.semanticDatagramByteCount == 1_152)
        #expect(config.profile.timeouts.tlsNanoseconds == 5_000_000_000)
        #expect(config.profile.timeouts.readinessNanoseconds == 2_000_000_000)
    }

    private func inboundDatagram(channel: UInt8, kind: UInt8, flags: UInt8) -> Data {
        var data = Data([0x55, 0x4C, 0x4D, 0x33, 3, channel, kind, flags, 0, 44, 0, 1])
        data.append(Data(repeating: 1, count: 16))
        data.append(Data([0, 0, 0, 0, 0, 0, 0, 1]))
        data.append(Data([0, 0, 0, 0, 0, 0, 0, 1]))
        data.append(0)
        return data
    }

    private func validVideoRecord() -> Data {
        hex(
            "554c4d3303020105002c0080c0c1c2c3c4c5c6c7c8c9cacbcccdcecf" +
            "000000000000002e000000000000232900000000000f4240000000c8000004e2" +
            "000000000000004d000000000000000c00000040000000000000000100000000" +
            "000000000003090a0000000100000000000102030405060708090a0b0c0d0e0f" +
            "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f" +
            "303132333435363738393a3b3c3d3e3f"
        )
    }

    private func path(wifi: Bool) -> QUICPathSnapshot {
        .init(
            status: .satisfied,
            usesWiFi: wifi,
            usesWiredEthernet: !wifi,
            usesCellular: false,
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
    }

    private func hex(_ value: String) -> Data {
        let bytes = Array(value.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(decoding: bytes[$0...($0 + 1)], as: UTF8.self), radix: 16)!
        })
    }

    private func sequence(_ fields: Data...) -> Data {
        tlv(0x30, fields.reduce(into: Data()) { $0.append($1) })
    }
    private func integer(_ value: UInt8) -> Data { tlv(0x02, Data([value])) }
    private func bitString(_ bytes: [UInt8]) -> Data { tlv(0x03, Data([0]) + Data(bytes)) }
    private func tlv(_ tag: UInt8, _ value: Data) -> Data { Data([tag, UInt8(value.count)]) + value }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
