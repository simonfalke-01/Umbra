import Darwin
import Foundation
import XCTest
@testable import UmbraCore

final class UmbraStorageRecoveryTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_787_875_200.123)
    private let identifier = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!

    func testRecoveryMovesUnreadableContentsWithoutReadingOrCreatingFreshStorage() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraStorageRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let storage = parent.appendingPathComponent("app.umbra.Umbra", isDirectory: true)
        let protectedFile = storage.appendingPathComponent("client-identity-v1.json")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let sentinel = Data("kernel-unreadable-identity".utf8)
        try sentinel.write(to: protectedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: protectedFile.path)
        defer { try? FileManager.default.removeItem(at: parent) }

        let result = try UmbraStorageRecovery.recoverStorage(
            at: storage,
            timestamp: timestamp,
            identifier: identifier
        )
        let expectedBackup = UmbraStorageRecovery.backupURL(
            for: storage,
            timestamp: timestamp,
            identifier: identifier
        )

        XCTAssertEqual(result.backupURL, expectedBackup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedBackup.path))
        let recoveredFile = expectedBackup.appendingPathComponent("client-identity-v1.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveredFile.path)
        XCTAssertEqual(try Data(contentsOf: recoveredFile), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
    }

    func testRecoveryRejectsSymlinkedStorageWithoutChangingExternalTarget() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraStorageRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let external = parent.appendingPathComponent("external", isDirectory: true)
        let storage = parent.appendingPathComponent("app.umbra.Umbra", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinelURL = external.appendingPathComponent("sentinel")
        let sentinel = Data("external-storage".utf8)
        try sentinel.write(to: sentinelURL)
        try FileManager.default.createSymbolicLink(at: storage, withDestinationURL: external)
        defer { try? FileManager.default.removeItem(at: parent) }

        XCTAssertThrowsError(
            try UmbraStorageRecovery.recoverStorage(
                at: storage,
                timestamp: timestamp,
                identifier: identifier
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.path))
    }

    func testRecoveryRejectsSymlinkedParentWithoutChangingExternalTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraStorageRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let externalParent = root.appendingPathComponent("external-parent", isDirectory: true)
        let linkedParent = root.appendingPathComponent("linked-parent", isDirectory: true)
        let externalStorage = externalParent.appendingPathComponent("app.umbra.Umbra", isDirectory: true)
        try FileManager.default.createDirectory(at: externalStorage, withIntermediateDirectories: true)
        let sentinelURL = externalStorage.appendingPathComponent("sentinel")
        let sentinel = Data("external-parent-storage".utf8)
        try sentinel.write(to: sentinelURL)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: externalParent)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try UmbraStorageRecovery.recoverStorage(
                at: linkedParent.appendingPathComponent("app.umbra.Umbra"),
                timestamp: timestamp,
                identifier: identifier
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalStorage.path))
    }

    func testRecoveryRejectsIntermediateParentSymlinkWithoutChangingExternalStorage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraStorageRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let externalParent = root.appendingPathComponent("external-parent", isDirectory: true)
        let nestedParent = externalParent.appendingPathComponent("nested", isDirectory: true)
        let linkedAncestor = root.appendingPathComponent("linked-ancestor", isDirectory: true)
        let externalStorage = nestedParent.appendingPathComponent("app.umbra.Umbra", isDirectory: true)
        try FileManager.default.createDirectory(at: externalStorage, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: externalStorage.path
        )
        let sentinelURL = externalStorage.appendingPathComponent("sentinel")
        let sentinel = Data("intermediate-symlink-storage".utf8)
        try sentinel.write(to: sentinelURL)
        try FileManager.default.createSymbolicLink(at: linkedAncestor, withDestinationURL: externalParent)
        defer { try? FileManager.default.removeItem(at: root) }

        let requestedStorage = linkedAncestor
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("app.umbra.Umbra", isDirectory: true)
        let requestedBackup = UmbraStorageRecovery.backupURL(
            for: requestedStorage,
            timestamp: timestamp,
            identifier: identifier
        )
        XCTAssertThrowsError(
            try UmbraStorageRecovery.recoverStorage(
                at: requestedStorage,
                timestamp: timestamp,
                identifier: identifier
            )
        )

        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalStorage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestedBackup.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: externalStorage.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testRecoveryRefusesBackupCollisionAndPreservesBothDirectories() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraStorageRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let storage = parent.appendingPathComponent("app.umbra.Umbra", isDirectory: true)
        let backup = UmbraStorageRecovery.backupURL(
            for: storage,
            timestamp: timestamp,
            identifier: identifier
        )
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let sourceSentinel = storage.appendingPathComponent("source")
        let backupSentinel = backup.appendingPathComponent("backup")
        try Data("source".utf8).write(to: sourceSentinel)
        try Data("backup".utf8).write(to: backupSentinel)
        defer { try? FileManager.default.removeItem(at: parent) }

        XCTAssertThrowsError(
            try UmbraStorageRecovery.recoverStorage(
                at: storage,
                timestamp: timestamp,
                identifier: identifier
            )
        )
        XCTAssertEqual(try Data(contentsOf: sourceSentinel), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: backupSentinel), Data("backup".utf8))
    }

    func testRecoveryRejectsNonDirectoryAndWrongOwnerMetadata() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraStorageRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("app.umbra.Umbra")
        let sentinel = Data("not-a-directory".utf8)
        try sentinel.write(to: file)
        defer { try? FileManager.default.removeItem(at: parent) }

        XCTAssertThrowsError(try UmbraStorageRecovery.recoverStorage(at: file))
        XCTAssertEqual(try Data(contentsOf: file), sentinel)

        var status = stat()
        status.st_mode = mode_t(S_IFDIR | 0o700)
        status.st_uid = geteuid() == 0 ? 1 : 0
        XCTAssertThrowsError(
            try UmbraStorageRecovery.validateDirectory(status, label: "test recovery directory")
        )
    }
}
