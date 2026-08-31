import XCTest
@testable import UmbraLSP

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
            offeredMaximumUDPPayload: 1_472
        )
        let values = try DeterministicCBOR.exactMap(
            DeterministicCBOR.decode(try LSPControlWire.start(request)),
            count: 10
        )
        guard case .array(let offers) = values[7] else {
            return XCTFail("START audio offers must be an array")
        }
        let first = try DeterministicCBOR.exactMap(offers[0], count: 5)
        XCTAssertEqual(first[0], .unsigned(2))
        XCTAssertEqual(first[1], .unsigned(480))
        XCTAssertEqual(values[8], .unsigned(1_472))
        XCTAssertEqual(values[9], .null)
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
            )
        )
        let values = try DeterministicCBOR.exactMap(
            DeterministicCBOR.decode(try LSPControlWire.start(request)),
            count: 10
        )
        let microphone = try DeterministicCBOR.exactMap(values[9], count: 6)
        XCTAssertEqual(microphone[0], .unsigned(1))
        XCTAssertEqual(microphone[1], .unsigned(960))
        XCTAssertEqual(microphone[2], .unsigned(64_000))
        XCTAssertEqual(microphone[5], .boolean(true))
    }
}
