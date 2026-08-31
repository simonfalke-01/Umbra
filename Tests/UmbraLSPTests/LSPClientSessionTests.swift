import XCTest
@testable import UmbraLSP
import UmbraLSPTransport

final class LSPClientSessionTests: XCTestCase {
    func testSessionFailsClosedWithoutRequiredProviders() async throws {
        let session = try LSPClientSession()
        let providers = LSPTransport.availableProviders

        if !providers.contains(.wolfSSL) {
            do {
                try await session.start()
                XCTFail("Starting without wolfSSL must fail closed")
            } catch {
                XCTAssertEqual(error as? LSPTransportError, .missingWolfSSL)
            }
            let state = await session.state
            XCTAssertEqual(state, .failed(.missingWolfSSL))
        } else if !providers.contains(.libSRTP) {
            do {
                try await session.start()
                XCTFail("Starting without libSRTP must fail closed")
            } catch {
                XCTAssertEqual(error as? LSPTransportError, .missingLibSRTP)
            }
            let state = await session.state
            XCTAssertEqual(state, .failed(.missingLibSRTP))
        } else {
            do {
                try await session.start()
                XCTFail("Starting before the native runtime exists must fail closed")
            } catch {
                XCTAssertEqual(error as? LSPTransportError, .unsupported)
            }
            let state = await session.state
            XCTAssertEqual(state, .failed(.unsupported))
        }
    }
}
