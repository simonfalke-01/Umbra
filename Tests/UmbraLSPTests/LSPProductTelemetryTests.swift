import XCTest
@testable import UmbraLSP

final class LSPProductTelemetryTests: XCTestCase {
    func testFixedDistributionPublishesBoundedPercentilesMaximumDropsAndClock() throws {
        var window = LSPFixedDurationWindow()
        for value in 1...300 { window.record(UInt64(value)) }
        window.drop()
        let snapshot = try XCTUnwrap(window.snapshot())

        XCTAssertEqual(snapshot.count, 256)
        XCTAssertEqual(snapshot.p50Microseconds, 172)
        XCTAssertEqual(snapshot.p95Microseconds, 288)
        XCTAssertEqual(snapshot.p99Microseconds, 298)
        XCTAssertEqual(snapshot.maximumMicroseconds, 300)
        XCTAssertEqual(snapshot.drops, 1)
        XCTAssertEqual(snapshot.clockDomain, "client-monotonic")
    }

    func testHostEncoderDistributionRetainsHostDurationClockDomain() throws {
        var window = LSPFixedDurationWindow()
        window.record(2_400)
        window.record(3_600)

        let snapshot = try XCTUnwrap(window.snapshot(clockDomain: "host-monotonic-duration"))

        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.p50Microseconds, 2_400)
        XCTAssertEqual(snapshot.p99Microseconds, 3_600)
        XCTAssertEqual(snapshot.clockDomain, "host-monotonic-duration")
    }
}
