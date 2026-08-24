import Foundation
import XCTest
@testable import UmbraServices

final class SessionStartupTelemetryTests: XCTestCase {
    func testRecorderUsesOneMonotonicOriginAndRecordsEachStageOnce() throws {
        let clock = StartupTelemetryTestClock(values: [10, 12, 11, 15, 16])
        let messages = StartupTelemetryMessages()
        let recorder = SessionStartupTelemetryRecorder(
            now: clock.now,
            diagnosticHandler: messages.append
        )
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        recorder.begin(sessionID: sessionID, uiActivationTime: 9)
        recorder.record(sessionID: sessionID, stage: .hostLaunch)
        recorder.record(sessionID: sessionID, stage: .sessionStart)
        recorder.record(sessionID: sessionID, stage: .sessionStart)
        recorder.record(sessionID: sessionID, stage: .decoderSubmitRequested)
        recorder.record(sessionID: sessionID, stage: .presentationCommit)

        let elapsed = try XCTUnwrap(recorder.snapshot(sessionID: sessionID)).elapsedByStage
        XCTAssertEqual(elapsed[.uiActivate], 0)
        XCTAssertEqual(elapsed[.hostLaunch], 3)
        XCTAssertEqual(elapsed[.sessionStart], 3, "A regressing clock sample must be clamped.")
        XCTAssertEqual(elapsed[.decoderSubmitRequested], 7)
        XCTAssertEqual(elapsed[.presentationCommit], 7)
        XCTAssertEqual(messages.values.count, 5, "Duplicate milestones must not skew startup evidence.")
        XCTAssertTrue(messages.values.allSatisfy { $0.contains("elapsed_proxy_ms=") })
        XCTAssertFalse(messages.values.contains { $0.localizedCaseInsensitiveContains("wall clock") })
    }
}

private final class StartupTelemetryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]

    init(values: [TimeInterval]) {
        self.values = values
    }

    func now() -> TimeInterval {
        lock.withLock {
            guard values.count > 1 else { return values.first ?? 0 }
            return values.removeFirst()
        }
    }
}

private final class StartupTelemetryMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] { lock.withLock { storedValues } }
    func append(_ value: String) { lock.withLock { storedValues.append(value) } }
}
