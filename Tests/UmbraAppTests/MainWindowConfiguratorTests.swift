import AppKit
import UmbraCore
import XCTest
@testable import UmbraApp

@MainActor
final class MainWindowConfiguratorTests: XCTestCase {
    func testDisplayModeAppliesOncePerOpenWindowLifecycle() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        var appliedModes: [UIDisplayMode] = []
        let controller = MainWindowDisplayModeController(mode: .maximized) { mode, appliedWindow in
            XCTAssertTrue(appliedWindow === window)
            appliedModes.append(mode)
        }
        controller.attach(to: window)

        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: window)
        )
        controller.update(mode: .windowed)
        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: window)
        )

        XCTAssertEqual(appliedModes, [.maximized])

        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: window)
        )
        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: window)
        )

        XCTAssertEqual(appliedModes, [.maximized, .windowed])
    }

    func testDisplayModeIgnoresOtherWindowsAndDetachedUpdates() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let otherWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        var applicationCount = 0
        let controller = MainWindowDisplayModeController(mode: .fullscreen) { _, _ in
            applicationCount += 1
        }
        controller.attach(to: window)

        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: otherWindow)
        )
        controller.attach(to: nil)
        controller.update(mode: .windowed)
        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: window)
        )

        XCTAssertEqual(applicationCount, 0)
    }
}
