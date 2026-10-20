import Foundation
import XCTest
import UmbraNetworking
@testable import UmbraServices

final class LiveGameStreamClientProviderTests: XCTestCase {
    func testUnpairedDiscoveryUsesExplicitPlainTransportInsteadOfURLSession() async throws {
        let plain = ServerInfoRecordingTransport()
        let provider = LiveGameStreamClientProvider(
            uniqueID: "client-id",
            useTrueUniqueID: true,
            plainTransport: plain
        )

        let info = try await provider.client(for: nil).fetchServerInfo(
            address: HostAddress(host: "203.0.113.9", port: 47_989),
            secure: false,
            fastFail: true
        )

        XCTAssertEqual(info.uniqueID, "host-id")
        let requests = await plain.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.scheme, "http")
        XCTAssertEqual(requests[0].url?.host, "203.0.113.9")
        XCTAssertEqual(requests[0].url?.port, 47_989)
    }
}

private actor ServerInfoRecordingTransport: HTTPTransport {
    private var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body = Data("""
        <root status_code="200">
          <hostname>Test Host</hostname><uniqueid>host-id</uniqueid>
          <PairStatus>0</PairStatus><currentgame>0</currentgame>
          <state>LUMEN_SERVER_FREE</state>
        </root>
        """.utf8)
        return (
            body,
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(body.count)]
            )!
        )
    }

    func recordedRequests() -> [URLRequest] { requests }
}
