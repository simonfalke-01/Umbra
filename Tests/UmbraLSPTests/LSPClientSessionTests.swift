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
            count: 9
        )
        guard case .array(let offers) = values[7] else {
            return XCTFail("START audio offers must be an array")
        }
        let first = try DeterministicCBOR.exactMap(offers[0], count: 5)
        XCTAssertEqual(first[0], .unsigned(2))
        XCTAssertEqual(first[1], .unsigned(480))
        XCTAssertEqual(values[8], .unsigned(1_472))
    }
}
