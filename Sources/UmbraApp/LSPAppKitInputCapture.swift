import AppKit
import Foundation
import UmbraLSP
import UmbraLSPTransport

/// Coarse focus and text-barrier owner for native Apple input capture.
@MainActor
final class LSPAppKitInputCapture {
    var failureHandler: (@MainActor @Sendable (Error) -> Void)?

    private weak var targetWindow: NSWindow?
    private var session: LSPClientSession?
    private var nativeCapture: LSPAppleInputCapture?
    private var focusObservers: [NSObjectProtocol] = []
    private var scheduledSourceStart: Task<Void, Never>?
    private var isStartingSources = false
    private var pointerMotionAbsolute = false
    private var pointerInsideVideo = false

    init(targetWindow: NSWindow?) {
        self.targetWindow = targetWindow
    }

    /// Begins preferred native capture while the application owns focus.
    func start(session: LSPClientSession) {
        do {
            try transfer(to: session)
        } catch {
            failureHandler?(error)
        }
    }

    /// Synchronously quiesces prior capture and transfers physical ownership.
    func transfer(to session: LSPClientSession) throws {
        stop()
        guard let targetWindow else { throw LSPTransportError.invalidState }
        self.session = session
        try session.setPointerMotionAbsolute(pointerMotionAbsolute, insideVideo: pointerInsideVideo)
        let center = NotificationCenter.default
        focusObservers = [
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopSources() }
            },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reclaimKeyWindowIfOrphaned()
                    self?.scheduleSourceStart()
                }
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: targetWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopSources() }
            },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: targetWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSourceStart() }
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: targetWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
        ]
        try startSourcesThrowing()
    }

    /// Selects Mac-cursor absolute motion and whether that cursor is over the video.
    func setPointerMotion(absolute: Bool, insideVideo: Bool) {
        pointerMotionAbsolute = absolute
        pointerInsideVideo = insideVideo
        do {
            try session?.setPointerMotionAbsolute(absolute, insideVideo: insideVideo)
        } catch {
            failureHandler?(error)
        }
    }

    /// Sends one Mac-cursor position while this window owns input capture.
    func submitAbsolutePointer(sampleTimeMicroseconds: UInt64, x: UInt32, y: UInt32) {
        guard pointerMotionAbsolute, nativeCapture != nil, let session else { return }
        try? session.submitAbsolutePointer(sampleTimeMicroseconds: sampleTimeMicroseconds, x: x, y: y)
    }

    /// Pauses all capture, neutralizes held state, commits text, then restarts with a fresh baseline.
    func performTextCommit(_ operation: () async throws -> Void) async throws {
        guard session != nil else { throw LSPTransportError.invalidState }
        stopSources()
        do {
            try await operation()
            try session?.restartInputBaseline()
            try startSourcesThrowing()
        } catch {
            try? session?.restartInputBaseline()
            try? startSourcesThrowing()
            throw error
        }
    }

    private func startSources() {
        do {
            try startSourcesThrowing()
        } catch {
            failureHandler?(error)
        }
    }

    /// Coalesces activation and key-window notifications after the current AppKit transition unwinds.
    private func scheduleSourceStart() {
        guard scheduledSourceStart == nil else { return }
        scheduledSourceStart = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.scheduledSourceStart = nil
            self.startSources()
        }
    }

    /// Reactivation (Cmd-Tab, Spaces, Dock) does not always make the stream window key,
    /// which left capture off until the user clicked the stream. Claim key status unless
    /// another visible Umbra window legitimately holds it.
    private func reclaimKeyWindowIfOrphaned() {
        guard let targetWindow, targetWindow.isVisible, !targetWindow.isKeyWindow else { return }
        if let keyWindow = NSApp.keyWindow, keyWindow !== targetWindow, keyWindow.isVisible { return }
        targetWindow.makeKeyAndOrderFront(nil)
    }

    /// Returns whether the exact stream window currently owns application input focus.
    private var ownsInputFocus: Bool {
        guard NSApp.isActive,
              let targetWindow,
              let keyWindow = NSApp.keyWindow else { return false }
        return targetWindow.isKeyWindow && keyWindow === targetWindow
    }

    private func startSourcesThrowing() throws {
        guard nativeCapture == nil,
              let session,
              ownsInputFocus else { return }
        guard !isStartingSources else {
            scheduleSourceStart()
            return
        }
        isStartingSources = true
        defer { isStartingSources = false }
        do {
            let capture = try session.startAppleInputCapture()
            guard self.session === session, ownsInputFocus else {
                capture.stop()
                return
            }
            nativeCapture = capture
            return
        } catch LSPTransportError.inputPermissionDenied, LSPTransportError.inputUnavailable {
            // Native start quiesces completely before returning, so AppKit now
            // becomes the sole keyboard/pointer owner.
        } catch {
            throw error
        }
        guard self.session === session, ownsInputFocus else { return }
        let capture = try session.startAppleAppKitInputCapture()
        guard self.session === session, ownsInputFocus else {
            capture.stop()
            return
        }
        nativeCapture = capture
    }

    /// Emits releases, neutralizes native authority, restores coalescing, and removes callbacks.
    func stop() {
        stopSources()
        let center = NotificationCenter.default
        for observer in focusObservers {
            center.removeObserver(observer)
        }
        focusObservers.removeAll(keepingCapacity: true)
        self.session = nil
    }

    private func stopSources() {
        scheduledSourceStart?.cancel()
        scheduledSourceStart = nil
        if let nativeCapture {
            nativeCapture.stop()
            self.nativeCapture = nil
        }
    }
}
