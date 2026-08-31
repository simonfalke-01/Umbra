import XCTest
@testable import UmbraLSP
@testable import UmbraLSPTransport

final class LSPClientSessionTests: XCTestCase {
    func testSessionStartsIdleWithStableInjectedIdentity() async throws {
        let identity = LSPClientIdentity.generate()
        let session = try LSPClientSession(identity: identity)
        let state = await session.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(try identity.publicKeyRawRepresentation.count, 32)
    }

    func testStartEncodesOrderedAdaptiveAudioOffersAndMaximumPayload() throws {
        let request = LSPInputStartRequest(
            applicationID: "desktop",
            audioOffers: LSPAudioOffer.adaptiveDefaults,
            offeredMaximumUDPPayload: 1_472,
            videoOffers: [Self.h264Offer]
        )
        let values = try DeterministicCBOR.exactMap(
            DeterministicCBOR.decode(try LSPControlWire.start(request)),
            count: 16
        )
        guard case .array(let offers) = values[7] else {
            return XCTFail("START audio offers must be an array")
        }
        let first = try DeterministicCBOR.exactMap(offers[0], count: 5)
        XCTAssertEqual(first[0], .unsigned(2))
        XCTAssertEqual(first[1], .unsigned(480))
        XCTAssertEqual(values[8], .unsigned(1_472))
        XCTAssertEqual(values[9], .null)
        XCTAssertEqual(values[10], .unsigned(0))
        let videoOffers = try XCTUnwrap({ if case .array(let value) = values[11] { value } else { nil } }())
        let video = try DeterministicCBOR.exactMap(videoOffers[0], count: 12)
        XCTAssertEqual(video[0], .unsigned(1))
        XCTAssertEqual(video[8], .unsigned(1))
        XCTAssertEqual(values[15], .unsigned(50_000))
    }

    func testStartEncodesExactRequiredMicrophoneOffer() throws {
        let request = LSPInputStartRequest(
            applicationID: "desktop",
            audioOffers: LSPAudioOffer.adaptiveDefaults,
            microphoneOffer: LSPMicrophoneOffer(
                maximumBitrate: 64_000,
                inbandFEC: true,
                dtx: true,
                required: true
            ),
            videoOffers: [Self.h264Offer]
        )
        let values = try DeterministicCBOR.exactMap(
            DeterministicCBOR.decode(try LSPControlWire.start(request)),
            count: 16
        )
        let microphone = try DeterministicCBOR.exactMap(values[9], count: 6)
        XCTAssertEqual(microphone[0], .unsigned(1))
        XCTAssertEqual(microphone[1], .unsigned(960))
        XCTAssertEqual(microphone[2], .unsigned(64_000))
        XCTAssertEqual(microphone[5], .boolean(true))
    }

    private static let h264Offer = LSPVideoOffer(
        codec: 1,
        profile: 1,
        width: 1_920,
        height: 1_080,
        refreshNumerator: 60,
        refreshDenominator: 1,
        preferredBitsPerSecond: 20_000_000,
        maximumBitsPerSecond: 20_000_000
    )

    func testVideoConfigParsesKey28FrameAgeAndEncodesFiveKeyAck() throws {
        let sessionID = UUID()
        let selection = DeterministicCBORValue.map((1...28).map { key in
            let value: DeterministicCBORValue = switch key {
            case 1: .unsigned(9)
            case 2: .unsigned(10)
            case 3: .unsigned(110)
            case 4: .unsigned(90_000)
            case 5, 6, 12, 13, 14, 15, 19, 20, 21: .unsigned(1)
            case 7: .unsigned(1_920)
            case 8: .unsigned(1_080)
            case 9: .unsigned(60)
            case 10: .unsigned(1)
            case 11: .unsigned(20_000_000)
            case 16, 26, 27: .boolean(false)
            case 17: .unsigned(1_200)
            case 18: .unsigned(3)
            case 22: .unsigned(2)
            case 23: .unsigned(3)
            case 24: .unsigned(4)
            case 25: .unsigned(5)
            case 28: .unsigned(33_333)
            default: .unsigned(1)
            }
            return .init(key: UInt64(key), value: value)
        })
        let payload = try DeterministicCBOR.encode(.map([
            .init(key: 1, value: .unsigned(1)),
            .init(key: 2, value: .bytes(LSPControlWire.uuidBytes(sessionID))),
            .init(key: 3, value: .unsigned(7)),
            .init(key: 4, value: selection),
            .init(key: 5, value: .array([.bytes(Data([0x67])), .bytes(Data([0x68]))])),
            .init(key: 6, value: .unsigned(100)),
            .init(key: 7, value: .unsigned(1)),
            .init(key: 8, value: .unsigned(1_000_000)),
        ]))
        let request = try LSPControlWire.videoConfig(from: LSPControlEvent(
            messageType: LSPControlMessageType.videoConfig.rawValue,
            flags: [.acknowledgementRequired],
            connectionGeneration: 1,
            messageID: 1,
            requestID: 2,
            payload: payload
        ))
        XCTAssertEqual(request.nativeConfiguration.maximumFrameAgeMicroseconds, 33_333)
        let ack = try DeterministicCBOR.exactMap(
            DeterministicCBOR.decode(try LSPControlWire.videoConfigAck(
                status: .success,
                sessionID: sessionID,
                videoGeneration: 9,
                decoderCredit: 3
            )),
            count: 5
        )
        XCTAssertEqual(ack[4], .unsigned(3))
    }

    func testPathProbeIntentAndAcknowledgementUseExactThreeKeySchemas() throws {
        let payload = try LSPControlWire.pathProbe(probeID: 77, udpPayloadSize: 1_400)
        let intent = try LSPControlWire.pathProbe(from: LSPControlEvent(
            messageType: LSPControlMessageType.pathProbe.rawValue,
            flags: [.acknowledgementRequired],
            connectionGeneration: 1,
            messageID: 9,
            requestID: 10,
            payload: payload
        ))
        XCTAssertEqual(intent, .init(probeID: 77, udpPayloadSize: 1_400))

        let acknowledgement = try LSPControlWire.pathProbeAck(from: LSPControlEvent(
            messageType: LSPControlMessageType.pathProbeAck.rawValue,
            flags: [.response],
            connectionGeneration: 1,
            messageID: 10,
            requestID: 10,
            payload: try LSPControlWire.pathProbeAck(probeID: 77, receivedSize: 1_400)
        ))
        XCTAssertEqual(acknowledgement, intent)
        XCTAssertThrowsError(try LSPControlWire.pathProbe(probeID: 0, udpPayloadSize: 1_400))
    }
}
