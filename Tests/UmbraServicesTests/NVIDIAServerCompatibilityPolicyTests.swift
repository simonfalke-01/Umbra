import XCTest
@testable import UmbraServices

final class NVIDIAServerCompatibilityPolicyTests: XCTestCase {
    func testSunshineDoesNotUseNVIDIAVersionGate() throws {
        let policy = try XCTUnwrap(NVIDIAServerCompatibilityPolicy())
        XCTAssertTrue(policy.isSupported(isNVIDIAServerSoftware: false, gfeVersion: nil))
        XCTAssertTrue(policy.isSupported(isNVIDIAServerSoftware: false, gfeVersion: "invalid"))
    }

    func testNVIDIAVersionUsesNumericDottedComparison() throws {
        let policy = try XCTUnwrap(NVIDIAServerCompatibilityPolicy(maximumSupportedVersion: "3.23.0.74"))
        XCTAssertTrue(policy.isSupported(isNVIDIAServerSoftware: true, gfeVersion: "3.23"))
        XCTAssertTrue(policy.isSupported(isNVIDIAServerSoftware: true, gfeVersion: "3.23.0.74"))
        XCTAssertFalse(policy.isSupported(isNVIDIAServerSoftware: true, gfeVersion: "3.23.0.75"))
        XCTAssertTrue(policy.isSupported(isNVIDIAServerSoftware: true, gfeVersion: nil))
        XCTAssertTrue(policy.isSupported(isNVIDIAServerSoftware: true, gfeVersion: "3.x"))
    }

    func testBundledMoonlightSentinelRejectsOnlyFutureOutOfRangeVersions() throws {
        let policy = try XCTUnwrap(NVIDIAServerCompatibilityPolicy())
        XCTAssertTrue(policy.isSupported(isNVIDIAServerSoftware: true, gfeVersion: "3.23.0.74"))
        XCTAssertTrue(policy.isSupported(isNVIDIAServerSoftware: true, gfeVersion: "99.99.99.99"))
        XCTAssertFalse(policy.isSupported(isNVIDIAServerSoftware: true, gfeVersion: "100.0.0.0"))
    }

    func testMalformedCompatibilityCeilingIsRejected() {
        XCTAssertNil(NVIDIAServerCompatibilityPolicy(maximumSupportedVersion: ""))
        XCTAssertNil(NVIDIAServerCompatibilityPolicy(maximumSupportedVersion: "99"))
        XCTAssertNil(NVIDIAServerCompatibilityPolicy(maximumSupportedVersion: "99.-1"))
        XCTAssertNil(NVIDIAServerCompatibilityPolicy(maximumSupportedVersion: "99.99.99.99.1"))
    }
}
