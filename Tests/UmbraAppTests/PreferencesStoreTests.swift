import Foundation
import XCTest
import UmbraCore
import UmbraServices
@testable import UmbraApp

@MainActor
final class PreferencesStoreTests: XCTestCase {
    func testVisibleVideoPipelineChoicesExcludeLegacyHDRAndUseProductCopy() {
        XCTAssertEqual(
            VideoCodecPreference.macOSChoices,
            [.automatic, .h264, .hevc, .av1]
        )
        XCTAssertFalse(VideoCodecPreference.macOSChoices.contains { $0.rawValue == 3 })
        XCTAssertEqual(RendererPreference.avSampleBufferDisplayLayer.label, "System Renderer")
        XCTAssertEqual(UIDisplayMode.mainWindowChoices, [.windowed, .maximized])
        XCTAssertEqual(StreamOptimizationMode.latency.label, "Lowest Latency")
        XCTAssertEqual(StreamOptimizationMode.quality.label, "Best Quality")
    }

    func testLegacyPreferencesInferAndPersistOptimizationMode() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(StreamingPreferences.default)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "optimizationMode")
        object["enableVSync"] = false
        object["framePacing"] = false
        defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: "Umbra.streamingPreferences"
        )

        let preferences = PreferencesStore(defaults: defaults)

        XCTAssertEqual(preferences.settings.optimizationMode, .latency)
        XCTAssertFalse(preferences.settings.enableVSync)
        XCTAssertFalse(preferences.settings.framePacing)
        let migratedData = try XCTUnwrap(defaults.data(forKey: "Umbra.streamingPreferences"))
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["optimizationMode"] as? String, "latency")
        XCTAssertNil(migratedObject["streamOptimizationMode"])
    }

    func testFutureOptimizationModeSurfacesRecoveryAndPreservesOriginalBytes() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(StreamingPreferences.default)
            ) as? [String: Any]
        )
        object["optimizationMode"] = "quality-v2-future"
        let originalData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        defaults.set(originalData, forKey: "Umbra.streamingPreferences")

        let preferences = PreferencesStore(defaults: defaults)

        XCTAssertEqual(preferences.settings, .default)
        XCTAssertTrue(preferences.persistenceErrorMessage?.contains("newer version") == true)
        XCTAssertEqual(
            defaults.data(forKey: "Umbra.streamingPreferences"),
            originalData,
            "Unknown future-version evidence must remain byte-for-byte intact."
        )
    }

    func testSelectingOptimizationModeAppliesDefaultsAndKeepsLaterAdvancedOverrides() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)

        preferences.updateOptimizationMode(.latency)
        XCTAssertEqual(preferences.settings.optimizationMode, .latency)
        XCTAssertFalse(preferences.settings.enableVSync)
        XCTAssertFalse(preferences.settings.framePacing)

        preferences.update(\.enableVSync, to: true)
        preferences.update(\.framePacing, to: true)
        let reopened = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reopened.settings.optimizationMode, .latency)
        XCTAssertTrue(reopened.settings.enableVSync)
        XCTAssertTrue(reopened.settings.framePacing)

        reopened.updateOptimizationMode(.quality)
        XCTAssertEqual(reopened.settings.optimizationMode, .quality)
        XCTAssertTrue(reopened.settings.enableVSync)
        XCTAssertTrue(reopened.settings.framePacing)
    }

    func testLegacyHDRCodecPreferenceLoadsAsHEVCAndPersistsMigration() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var stored = StreamingPreferences.default
        stored.videoCodecPreference = try XCTUnwrap(VideoCodecPreference(rawValue: 3))
        defaults.set(try JSONEncoder().encode(stored), forKey: "Umbra.streamingPreferences")

        let preferences = PreferencesStore(defaults: defaults)

        XCTAssertEqual(preferences.settings.videoCodecPreference, .hevc)
        let normalizedData = try XCTUnwrap(
            defaults.data(forKey: "Umbra.streamingPreferences")
        )
        let normalized = try JSONDecoder().decode(
            StreamingPreferences.self,
            from: normalizedData
        )
        XCTAssertEqual(normalized.videoCodecPreference, .hevc)
    }

    func testUnsupportedStoredRendererLoadsAndPersistsAsAutomatic() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var stored = StreamingPreferences.default
        stored.rendererPreference = .vulkan
        defaults.set(try JSONEncoder().encode(stored), forKey: "Umbra.streamingPreferences")

        let preferences = PreferencesStore(defaults: defaults)
        let reopened = PreferencesStore(defaults: defaults)

        XCTAssertEqual(preferences.settings.rendererPreference, .automatic)
        XCTAssertEqual(reopened.settings.rendererPreference, .automatic)
        let normalizedData = try XCTUnwrap(
            defaults.data(forKey: "Umbra.streamingPreferences")
        )
        let normalized = try JSONDecoder().decode(
            StreamingPreferences.self,
            from: normalizedData
        )
        XCTAssertEqual(normalized.rendererPreference, .automatic)
    }

    func testLegacyFullscreenMainWindowPreferenceMigratesToWindowed() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var stored = StreamingPreferences.default
        stored.uiDisplayMode = .fullscreen
        defaults.set(try JSONEncoder().encode(stored), forKey: "Umbra.streamingPreferences")

        let preferences = PreferencesStore(defaults: defaults)

        XCTAssertEqual(preferences.settings.uiDisplayMode, .windowed)
        let normalizedData = try XCTUnwrap(
            defaults.data(forKey: "Umbra.streamingPreferences")
        )
        let normalized = try JSONDecoder().decode(
            StreamingPreferences.self,
            from: normalizedData
        )
        XCTAssertEqual(normalized.uiDisplayMode, .windowed)
    }

    func testSelectedSettingsTabPersistsAcrossStoreReopen() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = PreferencesStore(defaults: defaults)
        first.updateSelectedSettingsTab(.input)
        let reopened = PreferencesStore(defaults: defaults)

        XCTAssertEqual(reopened.selectedSettingsTab, .input)
    }

    func testAutomaticBitrateIsNormalizedWhenPreferencesLoad() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var stored = StreamingPreferences.default
        stored.bitrateKbps = 500
        stored.autoAdjustBitrate = true
        defaults.set(try JSONEncoder().encode(stored), forKey: "Umbra.streamingPreferences")

        let preferences = PreferencesStore(defaults: defaults)

        XCTAssertEqual(preferences.settings.bitrateKbps, 10_000)
    }

    func testFrameRateUpdateRecalculatesAutomaticBitrate() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)

        preferences.updateFrameRate(30)

        XCTAssertEqual(preferences.settings.fps, 30)
        XCTAssertEqual(preferences.settings.bitrateKbps, 5_000)
    }

    func testConfiguredResolutionUpdateRecalculatesAutomaticBitrate() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)

        preferences.updateConfiguredResolution(width: 1_920, height: 1_080)
        XCTAssertEqual(preferences.settings.width, 1_920)
        XCTAssertEqual(preferences.settings.height, 1_080)
        XCTAssertEqual(preferences.settings.displayResolutionPolicy, .configured)
        XCTAssertEqual(preferences.settings.bitrateKbps, 20_000)

        preferences.updateConfiguredResolution(width: 1_920, height: 1_440)
        XCTAssertEqual(preferences.settings.width, 1_920)
        XCTAssertEqual(preferences.settings.height, 1_440)
        XCTAssertEqual(
            preferences.settings.bitrateKbps,
            StreamingPreferences.defaultBitrateKbps(
                width: 1_920,
                height: 1_440,
                fps: preferences.settings.fps,
                yuv444: preferences.settings.enableYUV444
            )
        )
    }

    func testConfiguredResolutionUpdatePreservesManualBitrate() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.updateBitrateFromContinuousControl(31_500)

        preferences.updateConfiguredResolution(width: 2_560, height: 1_440)

        XCTAssertEqual(preferences.settings.bitrateKbps, 31_500)
        XCTAssertFalse(preferences.settings.autoAdjustBitrate)
    }

    func testEditingAutomaticBitrateAboveManualLimitUnlocksTheChosenValue() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stored = StreamingPreferences(
            width: 3_840,
            height: 2_160,
            fps: 240
        )
        XCTAssertEqual(stored.bitrateKbps, 160_000)
        defaults.set(try JSONEncoder().encode(stored), forKey: "Umbra.streamingPreferences")
        let preferences = PreferencesStore(defaults: defaults)

        preferences.updateBitrateFromContinuousControl(159_500)

        XCTAssertEqual(preferences.settings.bitrateKbps, 159_500)
        XCTAssertFalse(preferences.settings.autoAdjustBitrate)
        XCTAssertTrue(preferences.settings.unlockBitrate)
        XCTAssertNoThrow(try preferences.settings.validate())
    }

    func testLockingHighAutomaticBitrateCreatesAValidManualCap() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var stored = StreamingPreferences(
            width: 3_840,
            height: 2_160,
            fps: 240
        )
        stored.unlockBitrate = true
        defaults.set(try JSONEncoder().encode(stored), forKey: "Umbra.streamingPreferences")
        let preferences = PreferencesStore(defaults: defaults)

        preferences.setBitrateLimitUnlocked(false)

        XCTAssertEqual(preferences.settings.bitrateKbps, 150_000)
        XCTAssertFalse(preferences.settings.autoAdjustBitrate)
        XCTAssertFalse(preferences.settings.unlockBitrate)
        XCTAssertNoThrow(try preferences.settings.validate())
    }

    func testContinuousBitratePersistenceCoalescesToLatestValue() async throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshotStore = CountingPreferencesSnapshotStore()
        let preferences = PreferencesStore(defaults: defaults, snapshotStore: snapshotStore)

        preferences.updateBitrateFromContinuousControl(12_500)
        preferences.updateBitrateFromContinuousControl(13_000)
        preferences.updateBitrateFromContinuousControl(13_500)
        await preferences.waitForPendingPersistence()

        let persisted = await snapshotStore.value()
        let updateCount = await snapshotStore.updateCount
        XCTAssertEqual(updateCount, 1)
        XCTAssertEqual(persisted.preferences.bitrateKbps, 13_500)
        XCTAssertFalse(persisted.preferences.autoAdjustBitrate)

        let reopened = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reopened.settings.bitrateKbps, 13_500)
        XCTAssertFalse(reopened.settings.autoAdjustBitrate)
    }

    func testDiscreteUpdateSupersedesPendingContinuousBitratePersistence() async throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshotStore = CountingPreferencesSnapshotStore()
        let preferences = PreferencesStore(defaults: defaults, snapshotStore: snapshotStore)

        preferences.updateBitrateFromContinuousControl(22_500)
        preferences.updateBitrateFromContinuousControl(23_000)
        preferences.update(\.packetSize, to: 1_392)
        await preferences.waitForPendingPersistence()

        let persisted = await snapshotStore.value()
        let updateCount = await snapshotStore.updateCount
        XCTAssertEqual(updateCount, 1)
        XCTAssertEqual(persisted.preferences.bitrateKbps, 23_000)
        XCTAssertEqual(persisted.preferences.packetSize, 1_392)
    }

    func testContinuousBitratePersistenceFailureIsExposedToSettingsUI() async throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(
            defaults: defaults,
            snapshotStore: FailingPreferencesSnapshotStore()
        )

        preferences.updateBitrateFromContinuousControl(19_500)
        await preferences.waitForPendingPersistence()

        XCTAssertNotNil(preferences.persistenceErrorMessage)
    }

    func testRapidPreferenceCommitsReachSnapshotInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshotStore = JSONFileStore<UmbraSnapshot>(fileURL: directory.appendingPathComponent("state.json"))
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = PreferencesStore(defaults: defaults, snapshotStore: snapshotStore)

        preferences.update(\.showPerformanceOverlay, to: true)
        preferences.update(\.connectionWarnings, to: false)
        preferences.update(\.packetSize, to: 1_392)
        await preferences.waitForPendingPersistence()

        let snapshot = try await snapshotStore.load()
        XCTAssertTrue(snapshot.preferences.showPerformanceOverlay)
        XCTAssertFalse(snapshot.preferences.connectionWarnings)
        XCTAssertEqual(snapshot.preferences.packetSize, 1_392)
    }

    func testSnapshotPersistenceFailureIsExposedToSettingsUI() async throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(
            defaults: defaults,
            snapshotStore: FailingPreferencesSnapshotStore()
        )

        preferences.update(\.connectionWarnings, to: false)
        await preferences.waitForPendingPersistence()

        XCTAssertNotNil(preferences.persistenceErrorMessage)
        preferences.clearPersistenceError()
        XCTAssertNil(preferences.persistenceErrorMessage)
    }
}

private actor CountingPreferencesSnapshotStore: SnapshotPersisting {
    private var snapshot = UmbraSnapshot.defaultValue
    private(set) var updateCount = 0

    func load() async throws -> UmbraSnapshot { snapshot }

    func save(_ snapshot: UmbraSnapshot) async throws {
        self.snapshot = snapshot
    }

    func update(
        _ transform: @Sendable (UmbraSnapshot) throws -> UmbraSnapshot
    ) async throws -> UmbraSnapshot {
        snapshot = try transform(snapshot)
        updateCount += 1
        return snapshot
    }

    func value() -> UmbraSnapshot { snapshot }
}

private actor FailingPreferencesSnapshotStore: SnapshotPersisting {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "test write failed" }
    }

    func load() async throws -> UmbraSnapshot { .defaultValue }
    func save(_ snapshot: UmbraSnapshot) async throws { throw Failure() }
    func update(
        _ transform: @Sendable (UmbraSnapshot) throws -> UmbraSnapshot
    ) async throws -> UmbraSnapshot {
        throw Failure()
    }
}
