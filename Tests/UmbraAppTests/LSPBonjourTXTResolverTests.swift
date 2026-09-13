import Darwin
import Foundation
import XCTest
@testable import UmbraApp

final class LSPBonjourTXTResolverTests: XCTestCase {
    func testResolvedIPv4IsUsedInsteadOfResolvingTheHostnameAgain() {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        XCTAssertEqual(inet_pton(AF_INET, "192.168.1.236", &address.sin_addr), 1)
        let bytes = withUnsafeBytes(of: &address) { Data($0) }
        XCTAssertEqual(LSPBonjourTXTResolver.numericHost(from: [bytes]), "192.168.1.236")
    }

    func testIPv4IsPreferredButIPv6OnlyHostsRemainUsable() {
        var ipv6 = sockaddr_in6()
        ipv6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        ipv6.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "fe80::1234", &ipv6.sin6_addr), 1)
        ipv6.sin6_scope_id = if_nametoindex("lo0")
        let ipv6Bytes = withUnsafeBytes(of: &ipv6) { Data($0) }
        XCTAssertEqual(LSPBonjourTXTResolver.numericHost(from: [ipv6Bytes]), "fe80::1234%lo0")

        var ipv4 = sockaddr_in()
        ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        ipv4.sin_family = sa_family_t(AF_INET)
        XCTAssertEqual(inet_pton(AF_INET, "192.168.1.236", &ipv4.sin_addr), 1)
        let ipv4Bytes = withUnsafeBytes(of: &ipv4) { Data($0) }
        XCTAssertEqual(LSPBonjourTXTResolver.numericHost(from: [ipv6Bytes, ipv4Bytes]), "192.168.1.236")
    }

    func testMalformedAddressesCannotBecomeSavedEndpoints() {
        var truncatedIPv6 = sockaddr()
        truncatedIPv6.sa_family = sa_family_t(AF_INET6)
        let bytes = withUnsafeBytes(of: &truncatedIPv6) { Data($0) }
        XCTAssertNil(LSPBonjourTXTResolver.numericHost(from: [
            Data(), Data([0]), bytes,
            Data(repeating: 0, count: MemoryLayout<sockaddr_storage>.size + 1),
        ]))
    }
}
