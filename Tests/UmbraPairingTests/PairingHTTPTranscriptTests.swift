import Foundation
import XCTest
import UmbraNetworking
@testable import UmbraPairing

final class PairingHTTPTranscriptTests: XCTestCase {
    func testNVIDIAPairingUsesLegacyIDWhileSunshineUsesTrueID() async throws {
        let identity = try makeEphemeralIdentity()
        let nvidiaTransport = RecordingPairingTransport()
        let sunshineTransport = RecordingPairingTransport()
        let nvidia = URLSessionPairingHTTPTranscript(
            plainTransport: nvidiaTransport,
            uniqueID: "true-client-id",
            useTrueUniqueID: false
        )
        let sunshine = URLSessionPairingHTTPTranscript(
            plainTransport: sunshineTransport,
            uniqueID: "true-client-id",
            useTrueUniqueID: true
        )
        let request = PairingTranscriptRequest(
            host: HostAddress(host: "pairing.test"),
            scheme: .http,
            endpoint: .pair,
            parameters: ["phrase": "getservercert"],
            pinnedServerCertificateDER: nil,
            clientIdentity: identity
        )

        _ = try await nvidia.exchange(request)
        _ = try await sunshine.exchange(request)

        let nvidiaRequests = await nvidiaTransport.requests
        let sunshineRequests = await sunshineTransport.requests
        let nvidiaRequest = try XCTUnwrap(nvidiaRequests.first)
        let sunshineRequest = try XCTUnwrap(sunshineRequests.first)
        XCTAssertEqual(queryValue("uniqueid", in: nvidiaRequest), GameStreamRequestBuilder.legacyNVIDIAUniqueID)
        XCTAssertEqual(queryValue("uniqueid", in: sunshineRequest), "true-client-id")
    }

    func testCertificateRequestAllowsTimeForHumanPINConfirmation() async throws {
        let transport = RecordingPairingTransport()
        let transcript = URLSessionPairingHTTPTranscript(
            plainTransport: transport,
            uniqueID: "test-client",
            uuidProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
        )
        let identity = try makeEphemeralIdentity()

        _ = try await transcript.exchange(
            PairingTranscriptRequest(
                host: HostAddress(host: "pairing.test"),
                scheme: .http,
                endpoint: .pair,
                parameters: ["phrase": "getservercert"],
                pinnedServerCertificateDER: nil,
                clientIdentity: identity
            )
        )

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests[0].timeoutInterval,
            URLSessionPairingHTTPTranscript.defaultPINConfirmationTimeout
        )
    }

    func testFollowUpPairingRequestsRetainShortNetworkTimeout() async throws {
        let transport = RecordingPairingTransport()
        let transcript = URLSessionPairingHTTPTranscript(
            plainTransport: transport,
            uniqueID: "test-client"
        )
        let identity = try makeEphemeralIdentity()

        _ = try await transcript.exchange(
            PairingTranscriptRequest(
                host: HostAddress(host: "pairing.test"),
                scheme: .http,
                endpoint: .pair,
                parameters: ["clientchallenge": "00"],
                pinnedServerCertificateDER: nil,
                clientIdentity: identity
            )
        )

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].timeoutInterval, 5)
    }

    func testPlainPairingBuildsScopedIPv6URLForBoundedTransport() async throws {
        let transport = RecordingPairingTransport()
        let transcript = URLSessionPairingHTTPTranscript(
            plainTransport: transport,
            uniqueID: "test-client"
        )
        let identity = try makeEphemeralIdentity()

        _ = try await transcript.exchange(
            PairingTranscriptRequest(
                host: HostAddress(host: "fe80::1%lo0", port: 47_989),
                scheme: .http,
                endpoint: .pair,
                parameters: ["phrase": "getservercert"],
                pinnedServerCertificateDER: nil,
                clientIdentity: identity
            )
        )

        let requests = await transport.requests
        let url = try XCTUnwrap(requests.first?.url)
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "fe80::1%lo0")
        XCTAssertEqual(url.port, 47_989)
    }
}

private func queryValue(_ name: String, in request: URLRequest) -> String? {
    request.url
        .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
        .queryItems?
        .first { $0.name == name }?
        .value
}

private actor RecordingPairingTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data("<root status_code=\"200\"><paired>1</paired></root>".utf8), response)
    }
}
