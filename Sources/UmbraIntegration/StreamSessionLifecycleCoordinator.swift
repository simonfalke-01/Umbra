import Foundation
import UmbraCore
import UmbraMedia
import UmbraPlatform
import UmbraServices

public protocol StreamSessionLifecycleCoordinating: Sendable {
    func prepare(for bootstrap: StreamBootstrap) async throws
    /// Applies capability-dependent preferences resolved after the native control
    /// channel starts without rebuilding or revealing the prepared presentation.
    func updatePreparation(for bootstrap: StreamBootstrap) async throws
    func commitStreaming(for bootstrap: StreamBootstrap) async
    /// Dismisses local presentation without touching callback-owned media resources.
    /// The native session may still be delivering stop-phase callbacks when this runs.
    func finishPresentation() async
    /// Releases final non-callback resources after `StreamingSession.close()` has completed
    /// Moonlight stop, thread join, and media cleanup.
    func finish() async
}

public extension StreamSessionLifecycleCoordinating {
    func updatePreparation(for bootstrap: StreamBootstrap) async throws {}
    func commitStreaming(for bootstrap: StreamBootstrap) async {}
    func finishPresentation() async {}
}

public struct NoOpStreamSessionLifecycleCoordinator: StreamSessionLifecycleCoordinating, Sendable {
    public init() {}
    public func prepare(for bootstrap: StreamBootstrap) async throws {}
    public func finish() async {}
}

@MainActor
public protocol KeepAwakeControlling: AnyObject {
    func setActive(_ active: Bool, reason: String)
}

extension KeepAwakeActivity: KeepAwakeControlling {}

@MainActor
public protocol StreamWindowModeControlling: AnyObject {
    func request(_ presentation: WindowPresentation)
}

extension WindowModeCoordinator: StreamWindowModeControlling {
    public func request(_ presentation: WindowPresentation) {
        request(presentation, screen: nil)
    }
}

public protocol StreamAudioLifecycleControlling: AnyObject, Sendable {
    func setApplicationActive(_ active: Bool)
    @discardableResult func stop() -> PCMRendererTeardownStatus
}


/// Stable lifecycle handle for audio renderers that are rebuilt when a session's
/// channel layout changes. The media provider attaches the current renderer and
/// App lifecycle notifications can keep using this same controller instance.
public final class NativeAudioSessionController: StreamAudioLifecycleControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let lifecycleLock = NSLock()
    private var renderer: (any PCMRendering)?
    private var pendingTeardownRenderers: [any PCMRendering] = []
    private var applicationActive = true

    public init() {}

    public func attach(_ renderer: any PCMRendering) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let (retryCandidates, applicationActive) = lock.withLock {
            () -> ([any PCMRendering], Bool) in
            let previous = self.renderer
            self.renderer = renderer
            var candidates = pendingTeardownRenderers.filter { $0 !== renderer }
            pendingTeardownRenderers.removeAll()
            if let previous, previous !== renderer {
                candidates.append(previous)
            }
            return (Self.uniqueRenderers(candidates), self.applicationActive)
        }
        renderer.setApplicationActive(applicationActive)
        retainIncompleteTeardowns(retryCandidates)
    }

    public func detach(_ renderer: any PCMRendering) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let status = renderer.stop()
        lock.withLock {
            pendingTeardownRenderers.removeAll { $0 === renderer }
            switch status {
            case .complete:
                if self.renderer === renderer { self.renderer = nil }
            case .retryRequired:
                if self.renderer !== renderer {
                    pendingTeardownRenderers.append(renderer)
                }
            }
        }
    }

    public func setApplicationActive(_ active: Bool) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let renderer = lock.withLock { () -> (any PCMRendering)? in
            applicationActive = active
            return self.renderer
        }
        renderer?.setApplicationActive(active)
    }

    @discardableResult
    public func stop() -> PCMRendererTeardownStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let renderers = lock.withLock {
            Self.uniqueRenderers(([renderer].compactMap { $0 }) + pendingTeardownRenderers)
        }
        let incomplete = renderers.filter { $0.stop() == .retryRequired }
        lock.withLock {
            if let renderer, !incomplete.contains(where: { $0 === renderer }) {
                self.renderer = nil
            }
            pendingTeardownRenderers = incomplete.filter { candidate in
                self.renderer !== candidate
            }
        }
        return incomplete.isEmpty ? .complete : .retryRequired
    }

    var retainedRendererCount: Int {
        lock.withLock {
            Self.uniqueRenderers(([renderer].compactMap { $0 }) + pendingTeardownRenderers).count
        }
    }

    private func retainIncompleteTeardowns(_ renderers: [any PCMRendering]) {
        let incomplete = renderers.filter { $0.stop() == .retryRequired }
        guard !incomplete.isEmpty else { return }
        lock.withLock {
            pendingTeardownRenderers = Self.uniqueRenderers(
                pendingTeardownRenderers + incomplete
            )
        }
    }

    private static func uniqueRenderers(
        _ renderers: [any PCMRendering]
    ) -> [any PCMRendering] {
        renderers.reduce(into: []) { result, renderer in
            if !result.contains(where: { $0 === renderer }) {
                result.append(renderer)
            }
        }
    }
}

@MainActor
public protocol StreamPlatformLifecycleControlling: AnyObject {
    func start()
    func stop()
}

extension AppleGameControllerService: StreamPlatformLifecycleControlling {}

/// Coordinates platform resources which must follow the streaming session as a
/// unit: power assertions, window presentation, controller monitoring, and audio
/// focus/output. All AppKit and GameController calls execute on the main actor.
public final class NativeStreamSessionLifecycleCoordinator: StreamSessionLifecycleCoordinating, @unchecked Sendable {
    private let keepAwake: any KeepAwakeControlling
    private let window: (any StreamWindowModeControlling)?
    private let audio: (any StreamAudioLifecycleControlling)?
    private let platform: (any StreamPlatformLifecycleControlling)?

    public init(
        keepAwake: any KeepAwakeControlling,
        window: (any StreamWindowModeControlling)? = nil,
        audio: (any StreamAudioLifecycleControlling)? = nil,
        platform: (any StreamPlatformLifecycleControlling)? = nil
    ) {
        self.keepAwake = keepAwake
        self.window = window
        self.audio = audio
        self.platform = platform
    }

    public func prepare(for bootstrap: StreamBootstrap) async throws {
        await keepAwake.setActive(
            bootstrap.preferences.keepAwake,
            reason: "Umbra is streaming \(bootstrap.application.name)"
        )
        await window?.request(Self.presentation(for: bootstrap.preferences.windowMode))
        audio?.setApplicationActive(true)
        await platform?.start()
    }

    public func finish() async {
        await platform?.stop()
        audio?.stop()
        await keepAwake.setActive(false, reason: "Umbra game stream ended")
    }

    public func applicationActiveStateChanged(_ active: Bool) async {
        audio?.setApplicationActive(active)
    }

    public static func presentation(for mode: UmbraCore.WindowMode) -> WindowPresentation {
        switch mode {
        case .windowed: .windowed
        case .fullscreenDesktop: .borderlessFullscreen
        case .fullscreen: .nativeFullscreen
        }
    }
}
