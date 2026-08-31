import CLSPCore
import XCTest
@testable import UmbraLSPTransport

final class LSPTransportTests: XCTestCase {
    func testABIVersionDigestAndInitialTelemetryMatchNativeCore() throws {
        XCTAssertEqual(clsp_core_abi_version(), 2)
        XCTAssertEqual(String(cString: clsp_core_source_digest()), LSPTransport.sourceDigest)

        let transport = try LSPTransport()
        let telemetry = try transport.telemetrySnapshot()

        XCTAssertEqual(telemetry.lifecycle, .created)
        XCTAssertEqual(telemetry.providers, LSPTransport.availableProviders)
        XCTAssertEqual(telemetry.receivedDatagrams, 0)
        XCTAssertEqual(telemetry.transmittedDatagrams, 0)
        XCTAssertEqual(telemetry.droppedDatagrams, 0)
        XCTAssertEqual(telemetry.authenticationFailures, 0)
    }

    func testStartFailsClosedAtFirstMissingSecurityProvider() throws {
        let transport = try LSPTransport(configuration: .init(handshakeTimeout: .seconds(1)))
        let providers = LSPTransport.availableProviders
        let endpoint = LSPTransportEndpoint(
            host: "127.0.0.1",
            port: 9,
            serverSPKISHA256: Data(repeating: 0x55, count: 32)
        )

        if !providers.contains(.wolfSSL) {
            XCTAssertThrowsError(try transport.start(endpoint: endpoint)) { error in
                XCTAssertEqual(error as? LSPTransportError, .missingWolfSSL)
            }
        } else if !providers.contains(.libSRTP) {
            XCTAssertThrowsError(try transport.start(endpoint: endpoint)) { error in
                XCTAssertEqual(error as? LSPTransportError, .missingLibSRTP)
            }
        } else {
            XCTAssertThrowsError(try transport.start(endpoint: endpoint)) { error in
                XCTAssertTrue(
                    [.timeout, .dtlsFailure, .socketFailure].contains(error as? LSPTransportError)
                )
            }
        }
    }

    func testCompetitionProfileRequiresExplicitCapacityCeiling() {
        XCTAssertThrowsError(
            try LSPTransport(
                configuration: .init(profile: .competitionLAN(capacityMbps: 0))
            )
        ) { error in
            XCTAssertEqual(error as? LSPTransportError, .invalidConfiguration)
        }
    }

    func testTelemetryIntervalRejectsSub250MillisecondPublication() {
        XCTAssertThrowsError(
            try LSPTransport(configuration: .init(telemetryInterval: .milliseconds(249)))
        ) { error in
            XCTAssertEqual(error as? LSPTransportError, .invalidConfiguration)
        }
    }
}
