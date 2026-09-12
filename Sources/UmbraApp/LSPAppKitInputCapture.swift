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
                MainActor.assumeIsolated { self?.startSources() }
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
                MainActor.assumeIsolated { self?.startSources() }
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

    private func startSourcesThrowing() throws {
        guard nativeCapture == nil,
              let session,
              NSApp.isActive,
              targetWindow?.isKeyWindow == true else { return }
        do {
            nativeCapture = try session.startAppleInputCapture()
            return
        } catch LSPTransportError.inputPermissionDenied, LSPTransportError.inputUnavailable {
            // Native start quiesces completely before returning, so AppKit now
            // becomes the sole keyboard/pointer owner.
        } catch {
            throw error
        }
        nativeCapture = try session.startAppleAppKitInputCapture()
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
        if let nativeCapture {
            nativeCapture.stop()
            self.nativeCapture = nil
        }
    }
}
