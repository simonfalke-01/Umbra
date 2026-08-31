import CLSPCore
import XCTest
@testable import UmbraLSPTransport

final class LSPTransportTests: XCTestCase {
    func testABIVersionDigestAndInitialTelemetryMatchNativeCore() throws {
        XCTAssertEqual(clsp_core_abi_version(), 1)
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
        let transport = try LSPTransport()
        let providers = LSPTransport.availableProviders

        if !providers.contains(.wolfSSL) {
            XCTAssertThrowsError(try transport.start()) { error in
                XCTAssertEqual(error as? LSPTransportError, .missingWolfSSL)
            }
        } else if !providers.contains(.libSRTP) {
            XCTAssertThrowsError(try transport.start()) { error in
                XCTAssertEqual(error as? LSPTransportError, .missingLibSRTP)
            }
        } else {
            XCTAssertThrowsError(try transport.start()) { error in
                XCTAssertEqual(error as? LSPTransportError, .unsupported)
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
