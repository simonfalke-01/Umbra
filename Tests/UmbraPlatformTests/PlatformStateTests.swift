import AppKit
import XCTest
@testable import UmbraPlatform

final class PlatformStateTests: XCTestCase {
    func testDisplayRefreshUsesCurrentModeBeforeMaximumCapabilityFallback() {
        XCTAssertEqual(
            DisplayGeometry.effectiveRefreshRate(currentModeRefreshRate: 59.94, maximumFramesPerSecond: 120),
            59.94
        )
        XCTAssertEqual(
            DisplayGeometry.effectiveRefreshRate(currentModeRefreshRate: 0, maximumFramesPerSecond: 120),
            120
        )
    }

    func testNativePixelSizeExcludesNotchInsetsAtNativeScale() {
        let fullPixels = CGSize(width: 3_024, height: 1_964)
        let points = CGSize(width: 1_512, height: 982)
        let insets = DisplayEdgeInsets(top: 37, left: 0, bottom: 0, right: 0)

        XCTAssertEqual(
            DisplayGeometry.nativePixelSize(
                fullPixelSize: fullPixels,
                pointSize: points,
                safeAreaInsets: insets,
                excludingDisplayCutouts: false
            ),
            fullPixels
        )
        XCTAssertEqual(
            DisplayGeometry.nativePixelSize(
                fullPixelSize: fullPixels,
                pointSize: points,
                safeAreaInsets: insets,
                excludingDisplayCutouts: true
            ),
            CGSize(width: 3_024, height: 1_890)
        )
    }

    func testNativeModeDiscoveryIgnoresScaledDesktopCoordinatesAndFindsSafeMode() throws {
        let geometry = try XCTUnwrap(DisplayGeometry.nativeGeometry(
            modes: [
                .init(width: 2_056, height: 1_329, isNative: false),
                .init(width: 3_456, height: 2_234, isNative: true),
                .init(width: 3_456, height: 2_160, isNative: false),
            ],
            isBuiltIn: true
        ))

        XCTAssertEqual(geometry.fullPixelSize, CGSize(width: 3_456, height: 2_234))
        XCTAssertEqual(geometry.safePixelSize, CGSize(width: 3_456, height: 2_160))
        XCTAssertTrue(geometry.hasDisplayCutout)
    }

    func testExternalDisplayDoesNotMisclassifyShorterModeAsNotchSafe() throws {
        let geometry = try XCTUnwrap(DisplayGeometry.nativeGeometry(
            modes: [
                .init(width: 1_920, height: 1_200, isNative: true),
                .init(width: 1_920, height: 1_080, isNative: false),
            ],
            isBuiltIn: false
        ))

        XCTAssertEqual(geometry.safePixelSize, geometry.fullPixelSize)
        XCTAssertFalse(geometry.hasDisplayCutout)
    }

    func testClipboardNormalizationOnlyCollapsesCRLF() {
        XCTAssertEqual(
            ClipboardTextNormalizer.normalize("one\r\ntwo\rthree\nfour"),
            "one\ntwo\rthree\nfour"
        )
    }

    func testWindowStateMachineTransitions() {
        var machine = WindowModeStateMachine()
        XCTAssertEqual(machine.request(.windowed), .noChange)
        XCTAssertEqual(machine.request(.borderlessFullscreen), .enterBorderlessFullscreen)
        XCTAssertEqual(machine.presentation, .borderlessFullscreen)
        XCTAssertEqual(machine.request(.nativeFullscreen), .enterNativeFullscreen)
        XCTAssertEqual(machine.request(.windowed), .enterWindowed)
    }

    func testDisplaySelectionUsesDeterministicFallbackOrder() {
        let displays: [CGDirectDisplayID] = [11, 22, 33, 44]

        XCTAssertEqual(
            DisplaySelectionResolver.resolve(
                availableDisplayIDs: displays,
                preferredDisplayID: 22,
                currentDisplayID: 33,
                uiDisplayID: 44,
                mainDisplayID: 11
            ),
            22
        )
        XCTAssertEqual(
            DisplaySelectionResolver.resolve(
                availableDisplayIDs: displays,
                preferredDisplayID: 99,
                currentDisplayID: 33,
                uiDisplayID: 44,
                mainDisplayID: 11
            ),
            33
        )
        XCTAssertEqual(
            DisplaySelectionResolver.resolve(
                availableDisplayIDs: displays,
                preferredDisplayID: 99,
                currentDisplayID: 98,
                uiDisplayID: 44,
                mainDisplayID: 11
            ),
            44
        )
        XCTAssertEqual(
            DisplaySelectionResolver.resolve(
                availableDisplayIDs: displays,
                preferredDisplayID: 99,
                currentDisplayID: 98,
                uiDisplayID: 97,
                mainDisplayID: 11
            ),
            11
        )
        XCTAssertEqual(
            DisplaySelectionResolver.resolve(
                availableDisplayIDs: displays,
                preferredDisplayID: 99,
                currentDisplayID: 98,
                uiDisplayID: 97,
                mainDisplayID: 96
            ),
            11
        )
        XCTAssertNil(
            DisplaySelectionResolver.resolve(
                availableDisplayIDs: [],
                preferredDisplayID: 22,
                currentDisplayID: nil,
                uiDisplayID: nil,
                mainDisplayID: nil
            )
        )
    }

    func testDisplaySelectionFallsBackAfterPreferredDisplayIsUnplugged() {
        XCTAssertEqual(
            DisplaySelectionResolver.resolve(
                availableDisplayIDs: [11, 22],
                preferredDisplayID: 22,
                currentDisplayID: 22,
                uiDisplayID: 11,
                mainDisplayID: 11
            ),
            22
        )
        XCTAssertEqual(
            DisplaySelectionResolver.resolve(
                availableDisplayIDs: [11],
                preferredDisplayID: 22,
                currentDisplayID: 22,
                uiDisplayID: 11,
                mainDisplayID: 11
            ),
            11
        )
    }

    func testSafeDisplayGeometryAppliesInsetsWithoutUsingVisibleFrame() {
        let fullFrame = CGRect(x: -1_440, y: 100, width: 1_440, height: 900)
        let insets = DisplayEdgeInsets(top: 32, left: 4, bottom: 6, right: 8)

        XCTAssertEqual(
            DisplayGeometry.borderlessFrame(
                fullFrame: fullFrame,
                safeAreaInsets: insets,
                excludingDisplayCutouts: false
            ),
            fullFrame
        )
        XCTAssertEqual(
            DisplayGeometry.borderlessFrame(
                fullFrame: fullFrame,
                safeAreaInsets: insets,
                excludingDisplayCutouts: true
            ),
            CGRect(x: -1_436, y: 106, width: 1_428, height: 862)
        )
    }

    func testSafeDisplayGeometryClampsInvalidInsets() {
        XCTAssertEqual(
            DisplayGeometry.borderlessFrame(
                fullFrame: CGRect(x: 10, y: 20, width: 100, height: 80),
                safeAreaInsets: DisplayEdgeInsets(top: 200, left: -10, bottom: 5, right: 200),
                excludingDisplayCutouts: true
            ),
            CGRect(x: 10, y: 25, width: 0, height: 0)
        )
    }

    @MainActor
    func testCoordinatorForwardsNotchSafeBorderlessSelection() {
        let driver = RecordingWindowModeDriver()
        let coordinator = WindowModeCoordinator(driver: driver)

        coordinator.request(.borderlessFullscreen, borderlessGeometry: .safeArea)
        coordinator.request(.borderlessFullscreen, borderlessGeometry: .fullDisplay)

        XCTAssertEqual(driver.borderlessGeometries, [.safeArea, .fullDisplay])
    }

    @MainActor
    func testCoordinatorSynchronizesExternallyDrivenFullscreenTransitions() {
        let driver = RecordingWindowModeDriver()
        let coordinator = WindowModeCoordinator(driver: driver)
        var observedPresentations: [WindowPresentation] = []
        coordinator.onPresentationChanged = { observedPresentations.append($0) }

        coordinator.synchronizePresentation(.nativeFullscreen)
        coordinator.synchronizePresentation(.nativeFullscreen)
        coordinator.synchronizePresentation(.windowed)

        XCTAssertEqual(coordinator.machine.presentation, .windowed)
        XCTAssertEqual(observedPresentations, [.nativeFullscreen, .windowed])
    }

    @MainActor
    func testCoordinatorForcedRecoveryReconcilesDriverAndMachineForNextSession() {
        let driver = RecordingWindowModeDriver()
        driver.presentation = .nativeFullscreen
        let coordinator = WindowModeCoordinator(driver: driver)

        coordinator.forceWindowedAfterFailedFullscreenExit()
        coordinator.request(.nativeFullscreen)

        XCTAssertEqual(driver.forcedRecoveryCount, 1)
        XCTAssertEqual(driver.presentation, .nativeFullscreen)
        XCTAssertEqual(coordinator.machine.presentation, .nativeFullscreen)
    }

    @MainActor
    func testCoordinatorReissuesWindowedRequestAfterFullscreenExitFailure() {
        let driver = RecordingWindowModeDriver()
        driver.presentation = .nativeFullscreen
        let coordinator = WindowModeCoordinator(driver: driver)

        coordinator.request(.windowed)
        coordinator.nativeFullscreenExitDidFail()
        coordinator.request(.windowed)

        XCTAssertEqual(driver.windowedRequestCount, 2)
        XCTAssertEqual(driver.fullscreenExitFailureCount, 1)
        XCTAssertEqual(coordinator.machine.presentation, .windowed)
    }

    @MainActor
    func testAppKitDriverForcedRecoveryLeavesReusableHiddenWindow() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        let driver = AppKitWindowModeDriver(window: window)
        driver.setWindowActivationSuppressed(true)

        driver.forceWindowedAfterFailedFullscreenExit()
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertEqual(driver.presentation, .windowed)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertEqual(
            driver.presentation,
            .windowed,
            "A stale prior exit cannot override a newly entering transition."
        )
        driver.setWindowActivationSuppressed(false)
        driver.enterWindowed()

        XCTAssertEqual(driver.presentation, .windowed)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone))
        XCTAssertTrue(window.isVisible)
        window.close()
    }

    func testSystemShortcutCaptureReadiness() {
        let granted = SystemShortcutPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            isAppSandboxed: false
        )
        var state = SystemShortcutCaptureState(
            mode: .always,
            windowFocused: true,
            presentation: .windowed,
            permissions: granted
        )
        XCTAssertEqual(state.readiness, .ready)
        state.windowFocused = false
        XCTAssertEqual(state.readiness, .inactive)
        state.mode = .off
        XCTAssertEqual(state.readiness, .disabled)
    }

    func testFullscreenOnlyShortcutCapture() {
        let granted = SystemShortcutPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            isAppSandboxed: false
        )
        var state = SystemShortcutCaptureState(
            mode: .fullscreenOnly,
            windowFocused: true,
            presentation: .windowed,
            permissions: granted
        )
        XCTAssertEqual(state.readiness, .inactive)
        state.presentation = .borderlessFullscreen
        XCTAssertEqual(state.readiness, .ready)
    }

    func testSystemShortcutCaptureReportsPermissionsAndSandbox() {
        var state = SystemShortcutCaptureState(
            mode: .always,
            windowFocused: true,
            presentation: .windowed,
            permissions: .init(
                inputMonitoringGranted: false,
                accessibilityGranted: true,
                isAppSandboxed: false
            )
        )
        XCTAssertEqual(state.readiness, .permissionRequired([.inputMonitoring]))
        state.permissions.isAppSandboxed = true
        XCTAssertEqual(state.readiness, .unavailableInAppSandbox)
    }
}

@MainActor
private final class RecordingWindowModeDriver: WindowModeDriving {
    var presentation: WindowPresentation = .windowed
    var borderlessGeometries: [BorderlessFullscreenGeometry] = []
    var forcedRecoveryCount = 0
    var windowedRequestCount = 0
    var fullscreenExitFailureCount = 0

    func nativeFullscreenExitDidFail() {
        fullscreenExitFailureCount += 1
        presentation = .nativeFullscreen
    }

    func forceWindowedAfterFailedFullscreenExit() {
        forcedRecoveryCount += 1
        presentation = .windowed
    }

    func enterWindowed() {
        windowedRequestCount += 1
        presentation = .windowed
    }

    func enterBorderlessFullscreen(on screen: NSScreen?, geometry: BorderlessFullscreenGeometry) {
        presentation = .borderlessFullscreen
        borderlessGeometries.append(geometry)
    }

    func enterNativeFullscreen() {
        presentation = .nativeFullscreen
    }
}
