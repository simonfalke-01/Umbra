import Darwin
import Foundation
import XCTest
@testable import UmbraCore

final class PersistenceTests: XCTestCase {
    func testMissingFileLoadsSaneDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONFileStore<UmbraSnapshot>(fileURL: directory.appendingPathComponent("state.json"))

        let snapshot = try await store.load()

        XCTAssertEqual(snapshot, .defaultValue)
    }

    func testActorStoreRoundTripAndUpdate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("nested/state.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStore<UmbraSnapshot>(fileURL: fileURL)
        let host = StreamHost(uuid: "host-123", name: "Mac Studio")
        let snapshot = UmbraSnapshot(hosts: [host])

        try await store.save(snapshot)
        let reopenedStore = JSONFileStore<UmbraSnapshot>(fileURL: fileURL)
        let loadedSnapshot = try await reopenedStore.load()
        XCTAssertEqual(loadedSnapshot, snapshot)

        let updated = try await reopenedStore.update { current in
            var current = current
            current.preferences.showPerformanceOverlay = true
            return current
        }
        XCTAssertTrue(updated.preferences.showPerformanceOverlay)
        let reloadedSnapshot = try await JSONFileStore<UmbraSnapshot>(fileURL: fileURL).load()
        XCTAssertTrue(reloadedSnapshot.preferences.showPerformanceOverlay)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testStoreRejectsInvalidModelsBeforeWriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("state.json")
        let store = JSONFileStore<UmbraSnapshot>(fileURL: fileURL)
        let invalidHosts = [StreamHost(uuid: "duplicate", name: "A"), StreamHost(uuid: "duplicate", name: "B")]

        do {
            try await store.save(UmbraSnapshot(hosts: invalidHosts))
            XCTFail("Expected validation to fail")
        } catch is ModelValidationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    func testLegacyOwnerReadableStateIsHardenedWithoutChangingBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = UmbraSnapshot(
            hosts: [StreamHost(uuid: "legacy-host", name: "Legacy Gaming PC")]
        )
        let store = JSONFileStore<UmbraSnapshot>(fileURL: fileURL)
        try await store.save(snapshot)
        let legacyBytes = try Data(contentsOf: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        let loaded = try await JSONFileStore<UmbraSnapshot>(fileURL: fileURL).load()

        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(try Data(contentsOf: fileURL), legacyBytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testHardLinkedLegacyStateIsRejectedWithoutChangingExternalTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let externalURL = directory.appendingPathComponent("external.json")
        let stateURL = directory.appendingPathComponent("state.json")
        let sentinel = Data("hard-linked-state-sentinel".utf8)
        try sentinel.write(to: externalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: externalURL.path)
        try FileManager.default.linkItem(at: externalURL, to: stateURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await JSONFileStore<UmbraSnapshot>(fileURL: stateURL).load()
            XCTFail("Expected a multiply linked legacy state file to be rejected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: externalURL), sentinel)
        let attributes = try FileManager.default.attributesOfItem(atPath: externalURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testWrongOwnerMetadataRemainsRejectedForLegacyPermissionHardening() throws {
        var status = stat()
        status.st_mode = mode_t(S_IFREG | 0o644)
        status.st_uid = geteuid() == 0 ? 1 : 0
        status.st_nlink = 1

        XCTAssertThrowsError(
            try SecureAtomicFileWriter.validateRegularOwnedFile(status, label: "test persistence file")
        )
    }

    func testIndependentStoreInstancesAtomicallyMergeConcurrentUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("state.json")
        let first = JSONFileStore<UmbraSnapshot>(fileURL: fileURL)
        let second = JSONFileStore<UmbraSnapshot>(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        async let hostUpdate = first.update { snapshot in
            var updated = snapshot
            updated.hosts = [StreamHost(uuid: "host-1", name: "Gaming PC")]
            return updated
        }
        async let preferenceUpdate = second.update { snapshot in
            var updated = snapshot
            updated.preferences.showPerformanceOverlay = true
            return updated
        }
        _ = try await (hostUpdate, preferenceUpdate)

        let final = try await first.load()
        XCTAssertEqual(final.hosts.map(\.uuid), ["host-1"])
        XCTAssertTrue(final.preferences.showPerformanceOverlay)
    }

    func testSymlinkedStateParentIsRejectedWithoutWritingExternalDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let externalDirectory = root.appendingPathComponent("external", isDirectory: true)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: externalDirectory.path
        )
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: externalDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let externalState = externalDirectory.appendingPathComponent("state.json")
        let store = JSONFileStore<UmbraSnapshot>(
            fileURL: linkedDirectory.appendingPathComponent("state.json")
        )
        do {
            try await store.save(.defaultValue)
            XCTFail("Expected a symlinked parent to be rejected")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalState.path))
        let externalAttributes = try FileManager.default.attributesOfItem(atPath: externalDirectory.path)
        XCTAssertEqual((externalAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testSymlinkedStateFileIsRejectedWithoutChangingExternalTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let externalURL = root.appendingPathComponent("external.json")
        let stateURL = root.appendingPathComponent("state.json")
        let sentinel = Data("external-state-sentinel".utf8)
        try sentinel.write(to: externalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: externalURL.path)
        try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: externalURL)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try await JSONFileStore<UmbraSnapshot>(fileURL: stateURL).save(.defaultValue)
            XCTFail("Expected a symlinked state file to be rejected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: externalURL), sentinel)
    }

    func testSymlinkedStateLockIsRejectedWithoutChangingExternalTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let externalURL = root.appendingPathComponent("external-lock")
        let stateURL = root.appendingPathComponent("state.json")
        let sentinel = Data("external-lock-sentinel".utf8)
        try sentinel.write(to: externalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: externalURL.path)
        try FileManager.default.createSymbolicLink(
            at: stateURL.appendingPathExtension("lock"),
            withDestinationURL: externalURL
        )
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try await JSONFileStore<UmbraSnapshot>(fileURL: stateURL).save(.defaultValue)
            XCTFail("Expected a symlinked state lock to be rejected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: externalURL), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testConcurrentSnapshotUpdatesMergeAcrossProcessesRepeatedly() async throws {
        for iteration in 0..<3 {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("UmbraPersistenceSubprocess-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let workers = try (0..<4).map { workerIndex in
                try launchSubprocess(
                    test: "UmbraCoreTests.PersistenceTests/testPersistenceSubprocessWorker",
                    environment: [
                        "UMBRA_PERSISTENCE_WORKER_DIRECTORY": directory.path,
                        "UMBRA_PERSISTENCE_WORKER_INDEX": String(workerIndex),
                    ]
                )
            }
            try Data().write(to: directory.appendingPathComponent("barrier"))
            try assertSuccessful(workers)

            let final = try await JSONFileStore<UmbraSnapshot>(
                fileURL: directory.appendingPathComponent("state.json")
            ).load()
            XCTAssertEqual(
                Set(final.hosts.map(\.uuid)),
                Set((0..<4).map { "worker-\($0)" }),
                "iteration \(iteration)"
            )
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    .filter { $0.hasSuffix(".tmp") }
                    .isEmpty,
                "Concurrent writes must use distinct temporary names and clean them up"
            )
        }
    }

    func testPersistenceSubprocessWorker() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directoryPath = environment["UMBRA_PERSISTENCE_WORKER_DIRECTORY"],
              let workerIndex = environment["UMBRA_PERSISTENCE_WORKER_INDEX"]
        else {
            return
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try waitForBarrier(at: directory.appendingPathComponent("barrier"))
        let store = JSONFileStore<UmbraSnapshot>(
            fileURL: directory.appendingPathComponent("state.json")
        )
        _ = try await store.update { snapshot in
            var updated = snapshot
            updated.hosts.append(
                StreamHost(uuid: "worker-\(workerIndex)", name: "Worker \(workerIndex)")
            )
            return updated
        }
    }

    private func launchSubprocess(
        test: String,
        environment additions: [String: String]
    ) throws -> (process: Process, output: Pipe) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", test, Bundle(for: Self.self).bundleURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, addition in addition }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return (process, output)
    }

    private func assertSuccessful(_ workers: [(process: Process, output: Pipe)]) throws {
        for worker in workers {
            worker.process.waitUntilExit()
            let output = worker.output.fileHandleForReading.readDataToEndOfFile()
            guard worker.process.terminationStatus == 0 else {
                XCTFail(String(decoding: output, as: UTF8.self))
                throw CocoaError(.executableRuntimeMismatch)
            }
        }
    }

    private func waitForBarrier(at barrierURL: URL) throws {
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: barrierURL.path) {
            guard Date() < deadline else {
                throw CocoaError(.fileReadUnknown)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
