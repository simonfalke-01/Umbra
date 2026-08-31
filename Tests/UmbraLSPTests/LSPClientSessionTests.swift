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
}
