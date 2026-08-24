import AppKit
import SwiftUI
import UmbraCore

struct MainWindowConfigurator: NSViewRepresentable {
    var mode: UIDisplayMode

    func makeCoordinator() -> MainWindowDisplayModeController {
        MainWindowDisplayModeController(mode: mode)
    }

    func makeNSView(context: Context) -> MainWindowConfigurationView {
        let view = MainWindowConfigurationView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ view: MainWindowConfigurationView, context: Context) {
        context.coordinator.update(mode: mode)
        context.coordinator.attach(to: view.window)
    }
}

@MainActor
final class MainWindowDisplayModeController: NSObject {
    typealias ApplyDisplayMode = @MainActor (UIDisplayMode, NSWindow) -> Void

    private var mode: UIDisplayMode
    private weak var window: NSWindow?
    private var openLifecycleIsActive = false
    private let applyDisplayMode: ApplyDisplayMode

    init(
        mode: UIDisplayMode,
        applyDisplayMode: @escaping ApplyDisplayMode = MainWindowDisplayModeController.apply
    ) {
        self.mode = mode
        self.applyDisplayMode = applyDisplayMode
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(mode: UIDisplayMode) {
        self.mode = mode
    }

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        self.window = window
        openLifecycleIsActive = false
        if window?.isVisible == true {
            beginOpenLifecycle()
        }
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        beginOpenLifecycle()
    }

    @objc func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        openLifecycleIsActive = false
    }

    private func beginOpenLifecycle() {
        guard let window, !openLifecycleIsActive else { return }
        openLifecycleIsActive = true
        applyDisplayMode(mode, window)
    }

    private static func apply(_ mode: UIDisplayMode, to window: NSWindow) {
        switch mode {
        case .fullscreen:
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case .maximized:
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else if !window.isZoomed {
                window.zoom(nil)
            }
        case .windowed:
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else if window.isZoomed {
                window.zoom(nil)
            }
        }
    }
}

@MainActor
final class MainWindowConfigurationView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
