import XCTest
@testable import UmbraNetworking

final class AddressNormalizerTests: XCTestCase {
    private let normalizer = AddressNormalizer()

    func testNormalizesGameStreamURLsHostnamesAndPorts() throws {
        XCTAssertEqual(try normalizer.normalize("gamestream://Gaming-PC.local:48089"), HostAddress(host: "Gaming-PC.local", port: 48_089))
        XCTAssertEqual(try normalizer.normalize("gaming-pc.local"), HostAddress(host: "gaming-pc.local", port: 47_989))
        XCTAssertEqual(try normalizer.normalize("192.168.1.4:50000"), HostAddress(host: "192.168.1.4", port: 50_000))
    }

    func testNormalizesBracketedAndRawIPv6() throws {
        XCTAssertEqual(try normalizer.normalize("[2001:db8::1]:48089"), HostAddress(host: "2001:db8::1", port: 48_089))
        XCTAssertEqual(try normalizer.normalize("2001:db8::1"), HostAddress(host: "2001:db8::1", port: 47_989))
        XCTAssertEqual(try normalizer.normalize("gamestream://[fe80::1]:47989"), HostAddress(host: "fe80::1", port: 47_989))
    }

    func testRejectsAmbiguousOrInvalidInput() throws {
        XCTAssertThrowsError(try normalizer.normalize(""))
        XCTAssertThrowsError(try normalizer.normalize("host:0"))
        XCTAssertThrowsError(try normalizer.normalize("host:70000"))
        XCTAssertThrowsError(try normalizer.normalize("gamestream://host/path"))
        XCTAssertThrowsError(try normalizer.normalize("not a host"))
    }
}
