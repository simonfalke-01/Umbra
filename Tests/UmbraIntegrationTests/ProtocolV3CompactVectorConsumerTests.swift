import CryptoKit
import Foundation
import XCTest
import UmbraProtocolV3
@testable import UmbraQUICTransport
@testable import UmbraIntegration

final class ProtocolV3CompactVectorConsumerTests: XCTestCase {
    func testBundledCompactVectorsHavePinnedProvenanceAndOptionalUpstreamIdentity() throws {
        let bundledURL = try XCTUnwrap(Bundle.module.url(
            forResource: "quic_v3_vectors",
            withExtension: "json"
        ))
        let provenanceURL = try XCTUnwrap(Bundle.module.url(
            forResource: "quic_v3_vectors.provenance",
            withExtension: "json"
        ))
        let bundled = try Data(contentsOf: bundledURL)
        let provenance = try JSONDecoder().decode(VectorProvenance.self, from: Data(contentsOf: provenanceURL))

        XCTAssertEqual(provenance.upstreamRepository, "Lumen")
        XCTAssertEqual(provenance.upstreamCommit, "82dba7c25b6976eb7f5aeac62c471c8a70826eb4")
        XCTAssertEqual(provenance.upstreamPath, "docs/protocols/vectors/quic_v3_vectors.json")
        XCTAssertEqual(Data(SHA256.hash(data: bundled)).hexadecimal, provenance.sha256)

        if let sourceRoot = ProcessInfo.processInfo.environment["LUMEN_SOURCE_ROOT"] {
            let upstream = URL(fileURLWithPath: sourceRoot)
                .appendingPathComponent(provenance.upstreamPath)
            XCTAssertEqual(try Data(contentsOf: upstream), bundled)
        }
    }

    func testProductionInputSenderConsumesBundledCompactContractWithoutOversize() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.constants.clientInputCapabilities, 0x17f)
        XCTAssertEqual(fixture.constants.serverInputCapabilities, 0x37f)
        XCTAssertEqual(fixture.constants.compactInputCapability, 0x200)
        XCTAssertEqual(fixture.constants.maxSemanticPayload, 1_108)

        let compactOnly = try wirePayload(fixture.artifact("input_format3_16_controllers_1040"))
        let compactEdges = try wirePayload(fixture.artifact("input_format3_16_controllers_two_edges_1104"))
        let compactTouch = try wirePayload(fixture.artifact("input_format3_touch_after_edge_ack_1072"))
        let legacy = try wirePayload(fixture.artifact("input_format2_15_controllers_1104"))
        let legacyCompatibility = try wirePayload(fixture.artifact("input_format2_compatibility"))
        assertShape(compactOnly, byteCount: 1_040, format: 3, controllers: 16, edges: 0, touches: 0)
        assertShape(compactEdges, byteCount: 1_104, format: 3, controllers: 16, edges: 2, touches: 0)
        assertShape(compactTouch, byteCount: 1_072, format: 3, controllers: 16, edges: 0, touches: 1)
        assertShape(legacy, byteCount: 1_104, format: 2, controllers: 15, edges: 0, touches: 0)
        assertShape(legacyCompatibility, byteCount: 272, format: 2, controllers: 1, edges: 1, touches: 1)

        let compactSession = VectorRecordingInputSession()
        let compactSender = ProtocolV3InputStateSender(
            session: compactSession,
            sessionID: Data(repeating: 0xA5, count: 16),
            mode: .latency,
            usesAbsolutePointer: false,
            supportsCompactStateFormat:
                fixture.constants.serverInputCapabilities & fixture.constants.compactInputCapability != 0,
            maximumPayloadByteCount: fixture.constants.maxSemanticPayload,
            failureHandler: { _ in }
        )
        let oracleState = compactOnly.subdata(in: 32..<compactOnly.count)
        for controller in UInt8(0)..<16 {
            let offset = 112 + Int(controller) * 56
            try compactSender.send(.controllerArrival(
                number: controller,
                activeMask: UInt16.max,
                type: oracleState[offset + 1],
                supportedButtons: oracleState.read(UInt32.self, at: offset + 52),
                capabilities: oracleState.read(UInt16.self, at: offset + 2)
            ))
            compactSender.acknowledge(appliedEdgeID: UInt64(controller) + 1)
        }
        try compactSender.send(.scroll(vertical: 1, horizontal: 0))
        var produced = try XCTUnwrap(compactSession.datagrams.last)
        assertShape(produced.payload, byteCount: 1_040, format: 3, controllers: 16, edges: 0, touches: 0)
        let producedState = produced.payload.subdata(in: 32..<produced.payload.count)
        XCTAssertEqual(producedState.read(UInt32.self, at: 80), oracleState.read(UInt32.self, at: 80))
        XCTAssertEqual(producedState[87], oracleState[87])
        XCTAssertTrue(compactSender.acceptsControllerFeedback(
            inputGeneration: 1,
            controller: 15,
            controllerGeneration: 1
        ))

        try compactSender.send(.keyboard(keyCode: 1, action: 0x03, modifiers: 0, flags: 0))
        try compactSender.send(.keyboard(keyCode: 2, action: 0x03, modifiers: 0, flags: 0))
        try compactSender.send(.touch(pointerID: 7, eventType: 3, x: 0.25, y: 0.75, pressure: 0.5))
        produced = try XCTUnwrap(compactSession.datagrams.last)
        assertShape(produced.payload, byteCount: 1_104, format: 3, controllers: 16, edges: 2, touches: 0)

        compactSender.acknowledge(appliedEdgeID: 18)
        try compactSender.send(.touch(pointerID: 7, eventType: 3, x: 0.5, y: 0.5, pressure: 1))
        produced = try XCTUnwrap(compactSession.datagrams.last)
        assertShape(produced.payload, byteCount: 1_072, format: 3, controllers: 16, edges: 0, touches: 1)

        try compactSender.send(.controller(
            number: 0, activeMask: Int16(bitPattern: 0xFFFE), buttons: 0,
            leftTrigger: 0, rightTrigger: 0, leftStickX: 0, leftStickY: 0,
            rightStickX: 0, rightStickY: 0
        ))
        try compactSender.send(.controllerArrival(
            number: 0, activeMask: UInt16.max,
            type: oracleState[113],
            supportedButtons: oracleState.read(UInt32.self, at: 164),
            capabilities: oracleState.read(UInt16.self, at: 114)
        ))
        XCTAssertFalse(compactSender.acceptsControllerFeedback(
            inputGeneration: 1, controller: 0, controllerGeneration: 1
        ))
        XCTAssertTrue(compactSender.acceptsControllerFeedback(
            inputGeneration: 1, controller: 0, controllerGeneration: 2
        ))

        let beforeHostileCap = try XCTUnwrap(compactSession.datagrams.last).objectID
        compactSender.updateMaximumPayloadByteCount(100)
        try compactSender.send(.scroll(vertical: 1, horizontal: 0))
        XCTAssertEqual(compactSession.datagrams.last?.objectID, beforeHostileCap)
        XCTAssertThrowsError(try QUICWireCodec.datagramHeader(
            sessionID: Data(repeating: 0xA5, count: 16),
            channel: 1,
            kind: 1,
            flags: 0,
            sequence: 1,
            objectID: 1,
            payloadByteCount: fixture.constants.maxSemanticPayload + 1
        )) { error in
            XCTAssertEqual(error as? QUICWireCodec.WireError, .oversized)
        }
        compactSender.updateMaximumPayloadByteCount(fixture.constants.maxSemanticPayload + 1)
        try compactSender.send(.scroll(vertical: 1, horizontal: 0))
        let recovered = try XCTUnwrap(compactSession.datagrams.last)
        XCTAssertEqual(recovered.objectID, beforeHostileCap + 1)
        XCTAssertLessThanOrEqual(recovered.payload.count, fixture.constants.maxSemanticPayload)

        let legacySession = VectorRecordingInputSession()
        let degradations = VectorLockedStrings()
        let legacySender = ProtocolV3InputStateSender(
            session: legacySession,
            sessionID: Data(repeating: 0xA5, count: 16),
            mode: .quality,
            usesAbsolutePointer: false,
            supportsCompactStateFormat:
                fixture.constants.clientInputCapabilities & fixture.constants.compactInputCapability != 0,
            degradationHandler: { degradations.append($0) },
            failureHandler: { _ in }
        )
        for controller in UInt8(0)..<14 {
            try legacySender.send(.controllerArrival(
                number: controller, activeMask: UInt16.max, type: 5,
                supportedButtons: 1, capabilities: 1
            ))
            legacySender.acknowledge(appliedEdgeID: UInt64(controller) + 1)
        }
        let legacySequence = try XCTUnwrap(legacySession.datagrams.last).objectID
        try legacySender.send(.controllerArrival(
            number: 14, activeMask: UInt16.max, type: 5,
            supportedButtons: 1, capabilities: 1
        ))
        XCTAssertEqual(legacySession.datagrams.last?.objectID, legacySequence)
        XCTAssertEqual(degradations.values.count, 1)
        let reset = try legacySender.inputResetStateBlock()
        XCTAssertEqual(reset.count, 1_072)
        XCTAssertEqual(reset[84], 15)
        XCTAssertEqual(reset[87], 0)
    }

    private func loadFixture() throws -> CompactVectorFixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "quic_v3_vectors", withExtension: "json"))
        return try JSONDecoder().decode(CompactVectorFixture.self, from: Data(contentsOf: url))
    }

    private func wirePayload(_ artifact: CompactVectorFixture.Artifact) throws -> Data {
        let wire = try XCTUnwrap(Data(hexadecimal: artifact.hex))
        XCTAssertEqual(Data(SHA256.hash(data: wire)).hexadecimal, artifact.sha256)
        XCTAssertEqual(wire.prefix(4), Data("ULM3".utf8))
        let payloadLength = Int(wire.read(UInt16.self, at: 10))
        XCTAssertEqual(wire.count, 44 + payloadLength)
        return wire.subdata(in: 44..<wire.count)
    }

    private func assertShape(
        _ payload: Data,
        byteCount: Int,
        format: UInt16,
        controllers: UInt8,
        edges: UInt16,
        touches: UInt8
    ) {
        XCTAssertEqual(payload.count, byteCount)
        XCTAssertEqual(payload.read(UInt16.self, at: 20), format)
        XCTAssertEqual(payload.read(UInt16.self, at: 22), 2)
        XCTAssertEqual(payload.read(UInt16.self, at: 18), edges)
        XCTAssertEqual(payload[32 + 84], controllers)
        XCTAssertEqual(payload[32 + 85], touches)
        XCTAssertEqual(payload[32 + 87], format == 3 ? 3 : 0)
    }
}

private struct CompactVectorFixture: Decodable {
    struct Constants: Decodable {
        let clientInputCapabilities: UInt64
        let compactInputCapability: UInt64
        let maxSemanticPayload: Int
        let serverInputCapabilities: UInt64

        enum CodingKeys: String, CodingKey {
            case clientInputCapabilities = "client_input_capabilities"
            case compactInputCapability = "compact_input_capability"
            case maxSemanticPayload = "max_semantic_payload"
            case serverInputCapabilities = "server_input_capabilities"
        }
    }

    struct Artifact: Decodable {
        let hex: String
        let sha256: String
    }

    let artifacts: [String: Artifact]
    let constants: Constants

    func artifact(_ name: String) throws -> Artifact {
        guard let artifact = artifacts[name] else { throw VectorError.missingArtifact(name) }
        return artifact
    }
}

private struct VectorProvenance: Decodable {
    let upstreamRepository: String
    let upstreamCommit: String
    let upstreamPath: String
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case upstreamRepository = "upstream_repository"
        case upstreamCommit = "upstream_commit"
        case upstreamPath = "upstream_path"
        case sha256
    }
}

private enum VectorError: Error {
    case missingArtifact(String)
    case invalidHex
}

private final class VectorRecordingInputSession: ProtocolV3SessionMediaControlling, @unchecked Sendable {
    struct Datagram: Sendable {
        let payload: Data
        let objectID: UInt64
    }

    private let lock = NSLock()
    private var storage: [Datagram] = []
    var datagrams: [Datagram] { lock.withLock { storage } }

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
        lock.withLock { storage.append(.init(payload: payload, objectID: objectID)) }
    }
}

private final class VectorLockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private extension Data {
    init?(hexadecimal: String) {
        guard hexadecimal.count.isMultiple(of: 2) else { return nil }
        self.init()
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }

    var hexadecimal: String { map { String(format: "%02x", $0) }.joined() }

    func read<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        self[offset..<(offset + MemoryLayout<T>.size)].reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
