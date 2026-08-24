import Foundation
import XCTest
@testable import UmbraCore

final class ModelRoundTripTests: XCTestCase {
    func testHostRoundTripRetainsPersistedAndRuntimeInventory() throws {
        let host = StreamHost(
            uuid: "host-123",
            name: "Living Room Mac",
            hasCustomName: true,
            macAddress: Data([0, 1, 2, 3, 4, 5]),
            localAddress: NetworkEndpoint(hostname: "192.168.1.5"),
            remoteAddress: NetworkEndpoint(hostname: "stream.example.com", port: 48_000),
            serverCertificate: Data("certificate".utf8),
            applications: [
                StreamApplication(id: 1, name: "Desktop", hdrSupported: true, supportsDirectLaunch: true),
            ],
            isNvidiaServerSoftware: false,
            status: .online,
            pairState: .paired,
            activeAddress: NetworkEndpoint(hostname: "192.168.1.5"),
            activeHTTPSPort: 47_984,
            activeAddressReachability: .lan,
            currentGameID: 1,
            gfeVersion: "3.27",
            appVersion: "7.1",
            displayModes: [DisplayMode(width: 3_840, height: 2_160, refreshRate: 120)],
            maxLumaPixelsHEVC: 8_294_400,
            codecSupport: [.h264, .hevc, .hevcMain10],
            gpuModel: "Apple M4 Max"
        )

        let encoded = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(StreamHost.self, from: encoded)

        XCTAssertEqual(decoded, host)
        XCTAssertEqual(decoded.id, "host-123")
        XCTAssertEqual(decoded.visibleApplications.map(\.name), ["Desktop"])
        XCTAssertNoThrow(try decoded.validate())
    }

    func testLegacyHostWithoutHEVCLumaCapabilityDecodesWithSafeDefaults() throws {
        let data = Data(#"{"uuid":"legacy-host","name":"Legacy Mac"}"#.utf8)

        let decoded = try JSONDecoder().decode(StreamHost.self, from: data)

        XCTAssertEqual(decoded.maxLumaPixelsHEVC, 0)
        XCTAssertEqual(decoded.codecSupport, [.h264])
        XCTAssertEqual(decoded.status, .unknown)
        XCTAssertTrue(decoded.isSupportedServerVersion)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testSessionStateRoundTrip() throws {
        let failure = SessionFailure(
            kind: .networkBlocked,
            message: "Required ports are blocked",
            stage: .serverHandshake,
            errorCode: -100,
            failingPorts: [47_984, 47_989],
            occurredAt: Date(timeIntervalSince1970: 1_000)
        )
        let session = StreamSession(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            hostID: "host-123",
            applicationID: 1,
            state: .failed(failure),
            launchWarnings: ["HDR was disabled"],
            createdAt: Date(timeIntervalSince1970: 500)
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(StreamSession.self, from: data)

        XCTAssertEqual(decoded, session)
        XCTAssertTrue(decoded.state.isTerminal)
    }

    func testUniqueHostAddressesPreservePriorityAndRemoveDuplicates() {
        let endpoint = NetworkEndpoint(hostname: "192.168.1.5")
        let host = StreamHost(
            uuid: "host",
            name: "Host",
            localAddress: endpoint,
            remoteAddress: NetworkEndpoint(hostname: "example.com"),
            activeAddress: endpoint
        )

        XCTAssertEqual(host.uniqueAddresses, [endpoint, NetworkEndpoint(hostname: "example.com")])
    }
}
