import AppKit
import Foundation

public enum WindowTransitionCommand: Equatable, Sendable {
    case noChange
    case enterWindowed
    case enterBorderlessFullscreen
    case enterNativeFullscreen
}

public enum BorderlessFullscreenGeometry: Equatable, Sendable {
    case fullDisplay
    case safeArea

    var excludesDisplayCutouts: Bool {
        self == .safeArea
    }
}

public struct WindowModeStateMachine: Sendable {
    public private(set) var presentation: WindowPresentation

    public init(presentation: WindowPresentation = .windowed) {
        self.presentation = presentation
    }

    @discardableResult
    public mutating func request(_ requested: WindowPresentation) -> WindowTransitionCommand {
        guard presentation != requested else { return .noChange }
        presentation = requested
        switch requested {
        case .windowed: return .enterWindowed
        case .borderlessFullscreen: return .enterBorderlessFullscreen
        case .nativeFullscreen: return .enterNativeFullscreen
        }
    }

    public mutating func synchronize(_ presentation: WindowPresentation) {
        self.presentation = presentation
    }
}

@MainActor
public protocol WindowModeDriving: AnyObject {
    var presentation: WindowPresentation { get }
    func setWindowActivationSuppressed(_ suppressed: Bool)
    func nativeFullscreenExitDidFail()
    func forceWindowedAfterFailedFullscreenExit()
    func resetWindowedAfterDismissal()
    func enterWindowed()
    func enterBorderlessFullscreen(on screen: NSScreen?, geometry: BorderlessFullscreenGeometry)
    func enterNativeFullscreen()
}

public extension WindowModeDriving {
    func setWindowActivationSuppressed(_ suppressed: Bool) {}
    func nativeFullscreenExitDidFail() {}
    func forceWindowedAfterFailedFullscreenExit() { enterWindowed() }
    func resetWindowedAfterDismissal() { forceWindowedAfterFailedFullscreenExit() }
}

@MainActor
public final class AppKitWindowModeDriver: WindowModeDriving {
    public private(set) var presentation: WindowPresentation = .windowed

    private weak var window: NSWindow?
    private var savedWindowedFrame: NSRect?
    private var nativeFullscreenExitTarget: WindowPresentation?
    private var nativeFullscreenExitScreen: NSScreen?
    private var nativeFullscreenExitGeometry: BorderlessFullscreenGeometry = .fullDisplay
    private var suppressesWindowActivation = false
    private var isEnteringNativeFullscreen = false
    private var isExitingNativeFullscreen = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    public init(window: NSWindow) {
        self.window = window
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isEnteringNativeFullscreen = true
                self?.isExitingNativeFullscreen = false
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window,
                      self.isEnteringNativeFullscreen,
                      window.isVisible, window.styleMask.contains(.fullScreen)
                else { return }
                self.isEnteringNativeFullscreen = false
                self.isExitingNativeFullscreen = false
                self.presentation = .nativeFullscreen
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.willExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isEnteringNativeFullscreen = false
                self?.isExitingNativeFullscreen = true
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window,
                      !self.isEnteringNativeFullscreen
                else { return }
                let observedMatchingExit = self.isExitingNativeFullscreen
                let completedRequestedExit = self.nativeFullscreenExitTarget != nil
                    && !window.styleMask.contains(.fullScreen)
                guard observedMatchingExit || completedRequestedExit else { return }
                self.isExitingNativeFullscreen = false
                self.finishNativeFullscreenExit()
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    public func setWindowActivationSuppressed(_ suppressed: Bool) {
        suppressesWindowActivation = suppressed
    }

    public func nativeFullscreenExitDidFail() {
        isExitingNativeFullscreen = false
    }

    public func forceWindowedAfterFailedFullscreenExit() {
        resetWindowedAfterDismissal()
    }

    public func resetWindowedAfterDismissal() {
        guard let window else { return }
        window.orderOut(nil)
        window.close()
        nativeFullscreenExitTarget = nil
        nativeFullscreenExitScreen = nil
        nativeFullscreenExitGeometry = .fullDisplay
        isEnteringNativeFullscreen = false
        isExitingNativeFullscreen = false
        applyWindowed()
    }

    public func enterWindowed() {
        guard let window else { return }
        nativeFullscreenExitTarget = .windowed
        guard !isExitingNativeFullscreen else { return }
        if window.styleMask.contains(.fullScreen) {
            isEnteringNativeFullscreen = false
            isExitingNativeFullscreen = true
            window.toggleFullScreen(nil)
            return
        }
        nativeFullscreenExitTarget = nil
        applyWindowed()
    }

    public func enterBorderlessFullscreen(
        on screen: NSScreen?,
        geometry: BorderlessFullscreenGeometry = .fullDisplay
    ) {
        guard let window else { return }
        let targetScreen = screen ?? window.screen ?? NSScreen.main
        nativeFullscreenExitTarget = .borderlessFullscreen
        nativeFullscreenExitScreen = targetScreen
        nativeFullscreenExitGeometry = geometry
        guard !isExitingNativeFullscreen else { return }
        if window.styleMask.contains(.fullScreen) {
            isEnteringNativeFullscreen = false
            isExitingNativeFullscreen = true
            window.toggleFullScreen(nil)
            return
        }
        nativeFullscreenExitTarget = nil
        nativeFullscreenExitScreen = nil
        nativeFullscreenExitGeometry = .fullDisplay
        applyBorderless(on: targetScreen, geometry: geometry)
    }

    public func enterNativeFullscreen() {
        guard let window else { return }
        guard !isEnteringNativeFullscreen else { return }
        if presentation == .borderlessFullscreen {
            applyWindowed()
        }
        guard !window.styleMask.contains(.fullScreen) else {
            presentation = .nativeFullscreen
            return
        }
        savedWindowedFrame = savedWindowedFrame ?? window.frame
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
        if !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
        isEnteringNativeFullscreen = true
        isExitingNativeFullscreen = false
        window.toggleFullScreen(nil)
    }

    private func finishNativeFullscreenExit() {
        let target = nativeFullscreenExitTarget ?? .windowed
        nativeFullscreenExitTarget = nil
        switch target {
        case .windowed: applyWindowed()
        case .borderlessFullscreen:
            applyBorderless(
                on: nativeFullscreenExitScreen ?? window?.screen ?? NSScreen.main,
                geometry: nativeFullscreenExitGeometry
            )
        case .nativeFullscreen: break
        }
        nativeFullscreenExitScreen = nil
        nativeFullscreenExitGeometry = .fullDisplay
    }

    private func applyWindowed() {
        guard let window else { return }
        isEnteringNativeFullscreen = false
        isExitingNativeFullscreen = false
        window.level = .normal
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
        if let savedWindowedFrame {
            window.setFrame(savedWindowedFrame, display: true, animate: false)
        }
        if !suppressesWindowActivation { window.makeKeyAndOrderFront(nil) }
        presentation = .windowed
    }

    private func applyBorderless(on screen: NSScreen?, geometry: BorderlessFullscreenGeometry) {
        guard let window, let screen else { return }
        isEnteringNativeFullscreen = false
        isExitingNativeFullscreen = false
        if presentation == .windowed { savedWindowedFrame = window.frame }
        window.level = .normal
        window.styleMask = [.borderless]
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.setFrame(
            DisplayGeometry.borderlessFrame(
                for: screen,
                excludingDisplayCutouts: geometry.excludesDisplayCutouts
            ),
            display: true,
            animate: false
        )
        if !suppressesWindowActivation { window.makeKeyAndOrderFront(nil) }
        presentation = .borderlessFullscreen
    }
}

@MainActor
public final class WindowModeCoordinator {
    public private(set) var machine: WindowModeStateMachine
    public var onPresentationChanged: ((WindowPresentation) -> Void)?

    private let driver: WindowModeDriving

    public init(driver: WindowModeDriving) {
        self.driver = driver
        machine = .init(presentation: driver.presentation)
    }

    public func request(
        _ presentation: WindowPresentation,
        screen: NSScreen? = nil,
        borderlessGeometry: BorderlessFullscreenGeometry = .fullDisplay
    ) {
        let command = machine.request(presentation)
        switch command {
        case .noChange:
            if presentation == .borderlessFullscreen {
                driver.enterBorderlessFullscreen(on: screen, geometry: borderlessGeometry)
            }
            return
        case .enterWindowed: driver.enterWindowed()
        case .enterBorderlessFullscreen:
            driver.enterBorderlessFullscreen(on: screen, geometry: borderlessGeometry)
        case .enterNativeFullscreen: driver.enterNativeFullscreen()
        }
        onPresentationChanged?(presentation)
    }

    public func toggleFullscreen(preferredFullscreenMode: WindowPresentation = .borderlessFullscreen) {
        request(machine.presentation == .windowed ? preferredFullscreenMode : .windowed)
    }

    public func setWindowActivationSuppressed(_ suppressed: Bool) {
        driver.setWindowActivationSuppressed(suppressed)
    }

    public func nativeFullscreenExitDidFail() {
        driver.nativeFullscreenExitDidFail()
        machine.synchronize(driver.presentation)
    }

    public func forceWindowedAfterFailedFullscreenExit() {
        driver.forceWindowedAfterFailedFullscreenExit()
        machine.synchronize(.windowed)
        onPresentationChanged?(.windowed)
    }

    public func resetWindowedAfterDismissal() {
        let changed = machine.presentation != .windowed
        driver.resetWindowedAfterDismissal()
        machine.synchronize(.windowed)
        if changed { onPresentationChanged?(.windowed) }
    }

    public func synchronizePresentation(_ presentation: WindowPresentation) {
        guard machine.presentation != presentation else { return }
        machine.synchronize(presentation)
        onPresentationChanged?(presentation)
    }
}
