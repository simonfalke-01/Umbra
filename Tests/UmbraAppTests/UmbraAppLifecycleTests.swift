import AppKit
import XCTest
import UmbraCLI
import UmbraCore
@testable import UmbraApp

@MainActor
final class UmbraAppLifecycleTests: XCTestCase {
    func testStorageRecoveryBootstrapReturnsExactBackupBeforeServiceExecution() throws {
        let backupURL = URL(fileURLWithPath: "/tmp/app.umbra.Umbra.recovery-fixture")
        var recoveryCallCount = 0

        let result = UmbraBootstrap.storageRecoveryResult(
            for: .ready(command: .recoverStorage, warnings: [])
        ) {
            recoveryCallCount += 1
            return UmbraStorageRecoveryResult(backupURL: backupURL)
        }

        XCTAssertEqual(recoveryCallCount, 1)
        XCTAssertEqual(
            result,
            .success(
                "Umbra storage was moved to this recoverable backup:\n"
                    + "/tmp/app.umbra.Umbra.recovery-fixture\n"
                    + "No fresh identity was created. Start Umbra normally to create fresh storage.\n"
            )
        )
    }

    func testStorageRecoveryBootstrapDoesNotRunForNormalLaunchAndSurfacesFailures() throws {
        var recoveryCallCount = 0
        let normalResult = UmbraBootstrap.storageRecoveryResult(
            for: .ready(command: .launchApplication, warnings: [])
        ) {
            recoveryCallCount += 1
            return UmbraStorageRecoveryResult(backupURL: URL(fileURLWithPath: "/unused"))
        }
        XCTAssertNil(normalResult)
        XCTAssertEqual(recoveryCallCount, 0)

        let failure = UmbraBootstrap.storageRecoveryResult(
            for: .ready(command: .recoverStorage, warnings: [])
        ) {
            throw CocoaError(.fileWriteNoPermission)
        }
        XCTAssertEqual(failure?.exitCode, CLIExitCode.failure.rawValue)
        XCTAssertTrue(failure?.standardError.contains("Storage recovery failed:") == true)
    }

    func testRepeatedQuitSharesOneOrderedStopBarrierAndOneReply() async throws {
        let gate = TerminationBarrierGate()
        let delegate = UmbraApplicationDelegate()
        var stopCount = 0
        var replies: [Bool] = []
        delegate.stopBarrier = {
            stopCount += 1
            await gate.wait()
        }

        let first = delegate.requestTermination { replies.append($0) }
        let repeated = delegate.requestTermination { replies.append($0) }

        XCTAssertEqual(first.rawValue, NSApplication.TerminateReply.terminateLater.rawValue)
        XCTAssertEqual(repeated.rawValue, NSApplication.TerminateReply.terminateLater.rawValue)
        await eventually { stopCount == 1 }
        XCTAssertTrue(replies.isEmpty)

        gate.open()
        await eventually { replies == [true] }

        let afterReply = delegate.requestTermination { replies.append($0) }
        XCTAssertEqual(afterReply.rawValue, NSApplication.TerminateReply.terminateNow.rawValue)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(replies, [true])
    }

    func testPackagedInfoPlistRegistersLegacyAndLSPDiscovery() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistURL = repositoryRoot.appendingPathComponent("Resources/Umbra/Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertNil(plist["CFBundleURLTypes"])
        XCTAssertEqual(
            plist["NSBonjourServices"] as? [String],
            ["_nvstream._tcp", "_lumen-stream._udp"]
        )
    }
}

@MainActor
private final class TerminationBarrierGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private func eventually(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<500 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Condition was not satisfied", file: file, line: line)
}
