import Foundation
import XCTest
@testable import UmbraNetworking

final class WakeOnLANTests: XCTestCase {
    func testBuildsStandardMagicPacket() throws {
        let packet = try WakeOnLAN.magicPacket(macAddress: "01:23:45:67:89:ab")

        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(packet.prefix(6), Data(repeating: 0xFF, count: 6))
        let mac = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB])
        for index in 0..<16 {
            let start = 6 + (index * 6)
            XCTAssertEqual(packet[start..<(start + 6)], mac[0..<6])
        }
    }

    func testRejectsMalformedMACAddresses() throws {
        XCTAssertThrowsError(try WakeOnLAN.magicPacket(macAddress: "01:23:45"))
        XCTAssertThrowsError(try WakeOnLAN.magicPacket(macAddress: "01:23:45:67:89:XX"))
    }

    func testBuildsGameStreamStaticAndBasePortRelativePorts() {
        XCTAssertEqual(WakeOnLAN.dynamicPorts(baseHTTPPort: 47_989), [47_998, 47_999, 48_000, 48_002, 48_010])
        XCTAssertEqual(WakeOnLAN.dynamicPorts(baseHTTPPort: 48_989), [48_998, 48_999, 49_000, 49_002, 49_010])
        XCTAssertEqual(WakeOnLAN.ports(baseHTTPPorts: [47_989]), [9, 47_009, 47_998, 47_999, 48_000, 48_002, 48_010])
    }

    func testTargetsIncludeKnownHostAndGlobalBroadcast() {
        let targets = WakeOnLAN.targets(hosts: [HostAddress(host: "192.168.1.10", port: 47_989)])

        XCTAssertEqual(targets.count, 14)
        XCTAssertTrue(targets.contains(WakeOnLANTarget(host: "192.168.1.10", port: 9)))
        XCTAssertTrue(targets.contains(WakeOnLANTarget(host: "192.168.1.10", port: 48_010)))
        XCTAssertTrue(targets.contains(WakeOnLANTarget(host: "255.255.255.255", port: 47_009)))
        XCTAssertTrue(targets.contains(WakeOnLANTarget(host: "255.255.255.255", port: 47_998)))
    }
}
