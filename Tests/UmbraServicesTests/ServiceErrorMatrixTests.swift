import Foundation
import XCTest
import UmbraCore
import UmbraNetworking
@testable import UmbraServices

final class ServiceErrorMatrixTests: XCTestCase {
    func testAuthenticationRequiredURLFailureMapsToAuthenticationFailure() {
        let mapped = ServiceErrorMapper.map(
            URLError(.userAuthenticationRequired),
            operation: .pairing,
            hostID: "host-1"
        )

        guard case .authenticationFailed(let message) = mapped else {
            return XCTFail("Expected an authentication failure, got \(mapped)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testRequestTimeoutMapsToHostUnavailableForTheAffectedHost() {
        let mapped = ServiceErrorMapper.map(
            URLError(.timedOut),
            operation: .refresh,
            hostID: "host-1"
        )

        guard case .hostUnavailable(hostID: "host-1", let message) = mapped else {
            return XCTFail("Expected a host-unavailable failure, got \(mapped)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testPinnedCertificateMismatchMapsToActionableAuthenticationFailure() {
        let mapped = ServiceErrorMapper.map(
            UmbraNetworkingError.certificateRejected(host: "gaming.example"),
            operation: .refresh,
            hostID: "host-1"
        )

        XCTAssertEqual(
            mapped,
            .authenticationFailed("The TLS certificate presented by gaming.example did not match the paired certificate.")
        )
    }

    func testClientIdentityFailureMapsToAuthenticationFailureWithoutLosingItsCause() {
        let mapped = ServiceErrorMapper.map(
            UmbraNetworkingError.clientIdentityUnavailable("client credential could not be loaded"),
            operation: .pairing,
            hostID: "host-1"
        )

        XCTAssertEqual(mapped, .authenticationFailed("client credential could not be loaded"))
    }

    func testBlockedPortsProduceTypedUserFacingSessionFailure() {
        let blocked = [
            ConnectivityPort(.tcp, 48_010),
            ConnectivityPort(.udp, 47_998),
        ]

        let failure = UmbraServiceError.networkBlocked(blocked).sessionFailure(stage: .connection)

        XCTAssertEqual(failure.kind, .networkBlocked)
        XCTAssertEqual(failure.stage, .connection)
        XCTAssertEqual(failure.failingPorts, [48_010, 47_998])
        XCTAssertEqual(
            failure.message,
            "The network blocked required ports: TCP 48010, UDP 47998."
        )
    }

    func testUnsupportedServerErrorProvidesHostSpecificMessage() {
        let error = UmbraServiceError.unsupportedServer("host-1")

        XCTAssertEqual(error.errorDescription, "Host host-1 is running an unsupported server version.")
    }

    func testTypedSessionFailureMappingPreservesClassificationStageAndCode() {
        let failure = SessionFailure(
            id: UUID(uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB")!,
            kind: .rendererUnavailable,
            message: "Metal rendering is unavailable.",
            stage: .platformInitialization,
            errorCode: -41,
            occurredAt: Date(timeIntervalSince1970: 123)
        )

        let mapped = ServiceErrorMapper.map(failure, operation: .streaming, hostID: "host-1")

        XCTAssertEqual(mapped, .streamFailure(failure))
        XCTAssertEqual(mapped.sessionFailure(stage: .connection), failure)
    }
}
