import Foundation
@testable import UmbraCore
import XCTest

final class ObsoleteStreamingStateCleanupTests: XCTestCase {
    func testCleanupRemovesOnlyRetiredFilesAndRunsOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraStateCleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let removedNames = [
            "protocol-v3-trust-v1.json",
            "protocol-v3-trust-v1.json.lock",
            "protocol-v3-hosts-v1.json",
            "protocol-v3-hosts-v1.json.lock",
            ".protocol-v3-fixture.tmp",
            ".protocol-v3-hosts-fixture.tmp",
        ]
        for name in removedNames {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        let preserved = root.appendingPathComponent("state.json")
        try Data("legacy".utf8).write(to: preserved)
        let similarlyNamedDirectory = root.appendingPathComponent(
            "protocol-v3-hosts-v1.json",
            isDirectory: true
        )
        try FileManager.default.removeItem(at: root.appendingPathComponent("protocol-v3-hosts-v1.json"))
        try FileManager.default.createDirectory(
            at: similarlyNamedDirectory,
            withIntermediateDirectories: false
        )

        try ObsoleteStreamingStateCleanup.performIfNeeded(in: root)

        for name in removedNames where name != "protocol-v3-hosts-v1.json" {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: similarlyNamedDirectory.path))

        let lateRetiredFile = root.appendingPathComponent("protocol-v3-trust-v1.json")
        try Data("late".utf8).write(to: lateRetiredFile)
        try ObsoleteStreamingStateCleanup.performIfNeeded(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lateRetiredFile.path))
    }
}
