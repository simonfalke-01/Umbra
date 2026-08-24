import AppKit
import UmbraCore
import UmbraPlatform
import UmbraServices

struct RuntimeStreamingResolution: Equatable {
    let preferences: StreamingPreferences
    let clientRefreshRateX100: Int32?
    let effectivePolicy: EffectiveStreamingPolicy

    init(
        preferences: StreamingPreferences,
        clientRefreshRateX100: Int32? = nil,
        effectivePolicy: EffectiveStreamingPolicy? = nil
    ) {
        self.preferences = preferences
        self.clientRefreshRateX100 = clientRefreshRateX100
        self.effectivePolicy = effectivePolicy ?? .resolve(for: preferences)
    }

    func applying(to intent: SessionIntent) -> SessionIntent {
        var resolved = intent
        resolved.preferences = preferences
        resolved.clientRefreshRateX100 = clientRefreshRateX100
        resolved.effectivePolicy = effectivePolicy
        return resolved
    }

    func sessionIntent(
        hostID: String,
        applicationID: Int,
        kind: SessionIntentKind
    ) -> SessionIntent {
        SessionIntent(
            hostID: hostID,
            applicationID: applicationID,
            kind: kind,
            preferences: preferences,
            clientRefreshRateX100: clientRefreshRateX100,
            effectivePolicy: effectivePolicy,
            gamepadMask: preferences.multiController ? 0 : 1,
            persistGameControllers: !preferences.multiController
        )
    }
}

@MainActor
struct HDRDisplaySupportResolver {
    private let resolve: (DisplaySelection, NSScreen?) -> Bool

    init(resolve: @escaping (DisplaySelection, NSScreen?) -> Bool) {
        self.resolve = resolve
    }

    func supportsHDR(
        for selection: DisplaySelection,
        uiScreen: NSScreen?
    ) -> Bool {
        resolve(selection, uiScreen)
    }

    static let system = Self { selection, uiScreen in
        let preferredDisplayID: CGDirectDisplayID? = switch selection {
        case .automatic: nil
        case let .specific(displayID): displayID
        }
        let screen = AppKitDisplaySelection.resolveScreen(
            preferredDisplayID: preferredDisplayID,
            currentScreen: nil,
            uiScreen: uiScreen
        )
        return (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    }
}

/// Resolves preferences that depend on the Mac's active display and audio output at launch time.
@MainActor
struct RuntimeStreamingPreferencesResolver {
    typealias DisplayResolver = @MainActor (StreamingPreferences, NSScreen?) -> StreamingPreferences
    typealias DisplayRefreshRateResolver = @MainActor (DisplaySelection, NSScreen?) -> Double?

    private let displayResolver: DisplayResolver
    private let displayRefreshRateResolver: DisplayRefreshRateResolver
    private let audioOutputChannelCount: UInt32
    private let hdrDisplaySupportResolver: HDRDisplaySupportResolver

    init(
        streamWindow: StreamWindowController,
        audioOutputChannelCount: UInt32,
        hdrDisplaySupportResolver: HDRDisplaySupportResolver = .system
    ) {
        self.init(
            audioOutputChannelCount: audioOutputChannelCount,
            displayResolver: { [streamWindow] preferences, screen in
                streamWindow.resolveStreamingPreferences(preferences, uiScreen: screen)
            },
            hdrDisplaySupportResolver: hdrDisplaySupportResolver
        )
    }

    init(
        audioOutputChannelCount: UInt32,
        displayResolver: @escaping DisplayResolver,
        hdrDisplaySupportResolver: HDRDisplaySupportResolver = .system,
        displayRefreshRateResolver: DisplayRefreshRateResolver? = nil
    ) {
        self.audioOutputChannelCount = audioOutputChannelCount
        self.displayResolver = displayResolver
        self.hdrDisplaySupportResolver = hdrDisplaySupportResolver
        self.displayRefreshRateResolver = displayRefreshRateResolver ?? Self.systemDisplayRefreshRate
    }

    func resolve(
        _ preferences: StreamingPreferences,
        uiScreen: NSScreen?
    ) -> StreamingPreferences {
        resolvedPreferencesAndPolicy(preferences, uiScreen: uiScreen).preferences
    }

    func resolveForStreaming(
        _ preferences: StreamingPreferences,
        uiScreen: NSScreen?
    ) -> RuntimeStreamingResolution {
        let runtime = resolvedPreferencesAndPolicy(preferences, uiScreen: uiScreen)
        let resolved = runtime.preferences
        let refreshRate = displayRefreshRateResolver(resolved.displaySelection, uiScreen)
        let refreshRateX100 = refreshRate.flatMap { refreshRate -> Int32? in
            guard refreshRate.isFinite, refreshRate > 0 else { return nil }
            let scaled = (refreshRate * 100).rounded()
            guard scaled <= Double(Int32.max) else { return nil }
            return Int32(scaled)
        }
        return RuntimeStreamingResolution(
            preferences: resolved,
            clientRefreshRateX100: refreshRateX100,
            effectivePolicy: runtime.policy
        )
    }

    private func resolvedPreferencesAndPolicy(
        _ preferences: StreamingPreferences,
        uiScreen: NSScreen?
    ) -> (preferences: StreamingPreferences, policy: EffectiveStreamingPolicy) {
        var resolved = displayResolver(preferences, uiScreen)
        resolved.enableHDR = resolved.enableHDR && hdrDisplaySupportResolver.supportsHDR(
            for: resolved.displaySelection,
            uiScreen: uiScreen
        )
        resolved.audioConfiguration = Self.resolveAudioConfiguration(
            resolved.audioConfiguration,
            outputChannelCount: audioOutputChannelCount
        )
        let policy = EffectiveStreamingPolicy.resolve(for: resolved)
        resolved.enableVSync = policy.vsyncEnabled
        resolved.framePacing = policy.frameSchedulingIntent == .adaptiveDisplayDeadline
        return (resolved, policy)
    }

    private static func systemDisplayRefreshRate(
        selection: DisplaySelection,
        uiScreen: NSScreen?
    ) -> Double? {
        let preferredDisplayID: CGDirectDisplayID? = switch selection {
        case .automatic: nil
        case let .specific(displayID): displayID
        }
        guard let screen = AppKitDisplaySelection.resolveScreen(
            preferredDisplayID: preferredDisplayID,
            currentScreen: nil,
            uiScreen: uiScreen
        ) else { return nil }
        let currentModeRefreshRate = AppKitDisplaySelection.displayID(for: screen)
            .flatMap(CGDisplayCopyDisplayMode)?
            .refreshRate ?? 0
        return DisplayGeometry.effectiveRefreshRate(
            currentModeRefreshRate: currentModeRefreshRate,
            maximumFramesPerSecond: screen.maximumFramesPerSecond
        )
    }

    private static func resolveAudioConfiguration(
        _ requested: AudioConfiguration,
        outputChannelCount: UInt32
    ) -> AudioConfiguration {
        let requestedChannels = switch requested {
        case .stereo: UInt32(2)
        case .surround51: UInt32(6)
        case .surround71: UInt32(8)
        }
        guard outputChannelCount > 0,
              requestedChannels > outputChannelCount else { return requested }
        return .stereo
    }
}
