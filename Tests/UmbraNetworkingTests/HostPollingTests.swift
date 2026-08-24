import Foundation
import XCTest
@testable import UmbraNetworking

final class HostPollingTests: XCTestCase {
    func testStateMachineTracksFailuresAndRecovery() {
        var machine = HostPollingStateMachine()
        let info = ServerInfo(name: "Host", uniqueID: "id")

        XCTAssertEqual(machine.state, .idle)
        machine.beginProbe()
        XCTAssertEqual(machine.state, .probing(attempt: 1))
        machine.failed(TestError.offline)
        XCTAssertEqual(machine.state, .offline(consecutiveFailures: 1, lastError: "offline"))
        machine.beginProbe()
        XCTAssertEqual(machine.state, .probing(attempt: 2))
        machine.received(info)
        XCTAssertEqual(machine.state, .online(info))
        machine.stop()
        machine.beginProbe()
        XCTAssertEqual(machine.state, .stopped)
    }

    private enum TestError: String, Error, LocalizedError {
        case offline
        var errorDescription: String? { rawValue }
    }
}
