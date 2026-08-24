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
        let store = JSONFileStore<UmbraSnapshot>(fileURL: fileURL)
        let host = StreamHost(uuid: "host-123", name: "Mac Studio")
        let snapshot = UmbraSnapshot(hosts: [host])

        try await store.save(snapshot)
        let loadedSnapshot = try await store.load()
        XCTAssertEqual(loadedSnapshot, snapshot)

        let updated = try await store.update { current in
            var current = current
            current.preferences.showPerformanceOverlay = true
            return current
        }
        XCTAssertTrue(updated.preferences.showPerformanceOverlay)
        let reloadedSnapshot = try await store.load()
        XCTAssertTrue(reloadedSnapshot.preferences.showPerformanceOverlay)
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
}
