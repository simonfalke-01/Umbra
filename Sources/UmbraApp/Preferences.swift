import Combine
import Foundation
import SwiftUI
import UmbraCore
import UmbraServices

extension AudioConfiguration: Identifiable {
    public var id: Int { rawValue }

    var label: String {
        switch self {
        case .stereo: UmbraLocalization.string("Stereo")
        case .surround51: UmbraLocalization.string("5.1 Surround Sound")
        case .surround71: UmbraLocalization.string("7.1 Surround Sound")
        }
    }
}

extension VideoCodecPreference: Identifiable {
    public var id: Int { rawValue }

    private static let legacyHDRRawValue = 3

    var label: String {
        switch rawValue {
        case Self.automatic.rawValue: UmbraLocalization.string("Automatic")
        case Self.h264.rawValue: UmbraLocalization.string("H.264")
        case Self.hevc.rawValue, Self.legacyHDRRawValue: UmbraLocalization.string("HEVC (H.265)")
        case Self.av1.rawValue: UmbraLocalization.string("AV1")
        default: UmbraLocalization.string("Automatic")
        }
    }

    static var macOSChoices: [VideoCodecPreference] {
        [.automatic, .h264, .hevc, .av1]
    }

    var normalizedForAppSettings: VideoCodecPreference {
        rawValue == Self.legacyHDRRawValue ? .hevc : self
    }
}

struct HDRTransferPreferenceOption: Hashable, Sendable {
    let value: HDRTransferPreference
    let label: String
}

extension HDRTransferPreference {
    static var macOSOptions: [HDRTransferPreferenceOption] {
        [
            HDRTransferPreferenceOption(
                value: .automatic,
                label: UmbraLocalization.string("Auto")
            ),
            HDRTransferPreferenceOption(
                value: .pq,
                label: UmbraLocalization.string("PQ")
            ),
            HDRTransferPreferenceOption(
                value: .hlg,
                label: UmbraLocalization.string("HLG")
            ),
        ]
    }

    static var macOSChoices: [HDRTransferPreference] {
        macOSOptions.map(\.value)
    }

    var label: String {
        Self.macOSOptions.first(where: { $0.value == self })?.label
            ?? UmbraLocalization.string("Auto")
    }
}

extension VideoDecoderPreference: Identifiable {
    public var id: Int { rawValue }

    var label: String {
        switch self {
        case .automatic: UmbraLocalization.string("Automatic")
        case .hardware: UmbraLocalization.string("Force Hardware Decoding")
        case .software: UmbraLocalization.string("Force Software Decoding")
        }
    }
}

extension RendererPreference: Identifiable {
    public var id: Int { rawValue }

    var label: String {
        switch self {
        case .probeOnly: UmbraLocalization.string("Compatibility Probe")
        case .automatic: UmbraLocalization.string("Automatic")
        case .vulkan: UmbraLocalization.string("Vulkan")
        case .metal: UmbraLocalization.string("Metal")
        case .avSampleBufferDisplayLayer: UmbraLocalization.string("System Renderer")
        }
    }

    static var macOSChoices: [RendererPreference] {
        [.automatic, .metal, .avSampleBufferDisplayLayer]
    }

    var normalizedForAppSettings: RendererPreference {
        Self.macOSChoices.contains(self) ? self : .automatic
    }
}

extension WindowMode: Identifiable {
    public var id: Int { rawValue }

    static let streamChoices: [WindowMode] = [
        .windowed,
        .fullscreenDesktop,
        .fullscreen,
    ]

    var label: String {
        switch self {
        case .fullscreen: UmbraLocalization.string("Fullscreen")
        case .fullscreenDesktop: UmbraLocalization.string("Borderless Windowed")
        case .windowed: UmbraLocalization.string("Windowed")
        }
    }
}

extension UIDisplayMode: Identifiable {
    public var id: Int { rawValue }

    static let mainWindowChoices: [UIDisplayMode] = [
        .windowed,
        .maximized,
    ]

    var label: String {
        switch self {
        case .windowed: UmbraLocalization.string("Windowed")
        case .maximized: UmbraLocalization.string("Maximized")
        case .fullscreen: UmbraLocalization.string("Fullscreen")
        }
    }
}

extension CaptureSystemKeysMode: Identifiable {
    public var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: UmbraLocalization.string("Off")
        case .fullscreen: UmbraLocalization.string("In Fullscreen")
        case .always: UmbraLocalization.string("Always")
        }
    }
}

extension StreamOptimizationMode: Identifiable {
    public var id: String { rawValue }

    var label: String {
        switch self {
        case .latency: UmbraLocalization.string("Lowest Latency")
        case .quality: UmbraLocalization.string("Best Quality")
        }
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    @Published private(set) var settings: StreamingPreferences
    @Published private(set) var appLocalePreference: AppLocalePreference
    @Published private(set) var persistenceErrorMessage: String? = nil

    private let defaults: UserDefaults
    private let snapshotStore: (any SnapshotPersisting)?
    private let storageKey = "Umbra.streamingPreferences"
    private let selectedSettingsTabKey = "Umbra.selectedSettingsTab"
    private var persistenceTask: Task<Void, Never>?
    private var deferredPersistenceTask: Task<Void, Never>?

    private enum PersistenceTiming {
        case immediate
        case afterContinuousInteraction
    }

    private static let continuousInteractionPersistenceDelay = Duration.milliseconds(150)

    init(
        defaults: UserDefaults = .standard,
        snapshotStore: (any SnapshotPersisting)? = nil
    ) {
        self.defaults = defaults
        self.snapshotStore = snapshotStore
        if let data = defaults.data(forKey: storageKey),
           var decoded = try? JSONDecoder().decode(StreamingPreferences.self, from: data),
           (try? decoded.validate()) != nil {
            var normalizedStoredPreferences = AppLocalePreferencePersistence.migrateLegacyLanguage(
                in: &decoded,
                defaults: defaults
            )
            let encodedObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if encodedObject?["optimizationMode"] as? String != decoded.optimizationMode.rawValue {
                normalizedStoredPreferences = true
            }
            if encodedObject?["hdrTransferPreference"] as? String
                != decoded.hdrTransferPreference.rawValue {
                normalizedStoredPreferences = true
            }
            let normalizedCodec = decoded.videoCodecPreference.normalizedForAppSettings
            if normalizedCodec != decoded.videoCodecPreference {
                decoded.videoCodecPreference = normalizedCodec
                normalizedStoredPreferences = true
            }
            let normalizedRenderer = decoded.rendererPreference.normalizedForAppSettings
            if normalizedRenderer != decoded.rendererPreference {
                decoded.rendererPreference = normalizedRenderer
                normalizedStoredPreferences = true
            }
            if decoded.uiDisplayMode == .fullscreen {
                decoded.uiDisplayMode = .windowed
                normalizedStoredPreferences = true
            }
            if decoded.autoAdjustBitrate {
                decoded.bitrateKbps = StreamingPreferences.defaultBitrateKbps(
                    width: decoded.width,
                    height: decoded.height,
                    fps: decoded.exactFrameRate,
                    yuv444: decoded.enableYUV444
                )
            }
            settings = decoded
            if normalizedStoredPreferences,
               let normalizedData = try? JSONEncoder().encode(decoded) {
                defaults.set(normalizedData, forKey: storageKey)
            }
        } else {
            settings = .default
            if defaults.data(forKey: storageKey) != nil {
                persistenceErrorMessage = UmbraLocalization.string(
                    "Umbra couldn’t load the saved streaming settings. The original data was left unchanged in case it was written by a newer version."
                )
            }
        }
        appLocalePreference = AppLocalePreferencePersistence.load(from: defaults)
    }

    func binding<Value>(for keyPath: WritableKeyPath<StreamingPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.update(keyPath, to: newValue) }
        )
    }

    var selectedSettingsTab: SettingsTab {
        defaults.string(forKey: selectedSettingsTabKey)
            .flatMap(SettingsTab.init(rawValue:)) ?? .general
    }

    func updateSelectedSettingsTab(_ tab: SettingsTab) {
        defaults.set(tab.rawValue, forKey: selectedSettingsTabKey)
    }

    func updateAppLocalePreference(_ preference: AppLocalePreference) {
        guard preference != appLocalePreference else { return }
        AppLocalePreferencePersistence.save(preference, to: defaults)
        appLocalePreference = preference
    }

    func update<Value>(_ keyPath: WritableKeyPath<StreamingPreferences, Value>, to value: Value) {
        var copy = settings
        copy[keyPath: keyPath] = value
        commit(copy)
    }

    func update(_ transform: (inout StreamingPreferences) -> Void) {
        var copy = settings
        transform(&copy)
        commit(copy)
    }

    func resetBitrateToDefault() {
        update { settings in
            settings.bitrateKbps = StreamingPreferences.defaultBitrateKbps(
                width: settings.width,
                height: settings.height,
                fps: settings.exactFrameRate,
                yuv444: settings.enableYUV444
            )
            settings.autoAdjustBitrate = true
        }
    }

    func updateBitrateFromContinuousControl(_ bitrateKbps: Int) {
        var copy = settings
        copy.bitrateKbps = bitrateKbps
        if bitrateKbps > 150_000 {
            copy.unlockBitrate = true
        }
        copy.autoAdjustBitrate = false
        commit(copy, persistenceTiming: .afterContinuousInteraction)
    }

    func setBitrateLimitUnlocked(_ enabled: Bool) {
        update { settings in
            settings.unlockBitrate = enabled
            guard !enabled else { return }
            settings.bitrateKbps = min(settings.bitrateKbps, 150_000)
            let automaticBitrate = StreamingPreferences.defaultBitrateKbps(
                width: settings.width,
                height: settings.height,
                fps: settings.exactFrameRate,
                yuv444: settings.enableYUV444
            )
            if settings.autoAdjustBitrate, automaticBitrate > 150_000 {
                settings.autoAdjustBitrate = false
            }
        }
    }

    func updateConfiguredResolution(width: Int, height: Int) {
        update { settings in
            settings.displayResolutionPolicy = .configured
            settings.width = width
            settings.height = height
            if settings.autoAdjustBitrate {
                settings.bitrateKbps = StreamingPreferences.defaultBitrateKbps(
                    width: width,
                    height: height,
                    fps: settings.exactFrameRate,
                    yuv444: settings.enableYUV444
                )
            }
        }
    }

    func updateFrameRate(_ fps: Int) {
        updateFrameRate(numerator: fps, denominator: 1)
    }

    func updateFrameRate(numerator: Int, denominator: Int) {
        update { settings in
            settings.setFrameRate(numerator: numerator, denominator: denominator)
            if settings.autoAdjustBitrate {
                settings.bitrateKbps = StreamingPreferences.defaultBitrateKbps(
                    width: settings.width,
                    height: settings.height,
                    fps: settings.exactFrameRate,
                    yuv444: settings.enableYUV444
                )
            }
        }
    }

    func updateOptimizationMode(_ mode: StreamOptimizationMode) {
        update { settings in
            settings.optimizationMode = mode
            settings.enableVSync = mode.recommendedVSync
            settings.framePacing = mode.recommendedFramePacing
        }
    }

    func resetAll() {
        AppLocalePreferencePersistence.reset(in: defaults)
        appLocalePreference = .system
        commit(.default)
    }

    private func commit(
        _ candidate: StreamingPreferences,
        persistenceTiming: PersistenceTiming = .immediate
    ) {
        guard (try? candidate.validate()) != nil else { return }
        settings = candidate

        switch persistenceTiming {
        case .immediate:
            deferredPersistenceTask?.cancel()
            deferredPersistenceTask = nil
            persist(candidate)
        case .afterContinuousInteraction:
            scheduleDeferredPersistence(candidate)
        }
    }

    private func scheduleDeferredPersistence(_ candidate: StreamingPreferences) {
        deferredPersistenceTask?.cancel()
        deferredPersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.continuousInteractionPersistenceDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            deferredPersistenceTask = nil
            persist(candidate)
        }
    }

    private func persist(_ candidate: StreamingPreferences) {
        guard let data = try? JSONEncoder().encode(candidate) else { return }
        defaults.set(data, forKey: storageKey)
        if let snapshotStore {
            let previousTask = persistenceTask
            persistenceTask = Task {
                await previousTask?.value
                do {
                    _ = try await snapshotStore.update { snapshot in
                        var copy = snapshot
                        copy.preferences = candidate
                        return copy
                    }
                    persistenceErrorMessage = nil
                } catch {
                    persistenceErrorMessage = "Umbra could not save these settings to its application data. \(error.localizedDescription)"
                }
            }
        }
    }

    func clearPersistenceError() {
        persistenceErrorMessage = nil
    }

    func waitForPendingPersistence() async {
        await deferredPersistenceTask?.value
        await persistenceTask?.value
    }
}
