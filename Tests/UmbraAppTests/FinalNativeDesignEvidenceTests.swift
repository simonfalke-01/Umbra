import AppKit
import SwiftUI
import UmbraCore
import XCTest
@testable import UmbraApp

@MainActor
final class FinalNativeDesignEvidenceTests: XCTestCase {
    private struct Appearance {
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
        let appKitName: NSAppearance.Name
        let artifactName: String
    }

    private struct WindowCapture {
        let window: NSWindow
        let hostingView: NSView
        let frameView: NSView
        let representation: NSBitmapImageRep
    }

    private let minimumMainContentSize = CGSize(width: 720, height: 520)

    func testMinimumMainWindowLightIncreasedContrastKeepsWarningCollectionAndOperationVisible() async throws {
        try requireIsolatedAppKitInputRun()
        let light = Appearance(
            scheme: .light,
            contrast: .increased,
            appKitName: .accessibilityHighContrastAqua,
            artifactName: "main-window-minimum-light-increased-contrast"
        )
        let fixture = try await makeConcurrentStatusFixture()
        let lightCapture = try await renderProductionWindow(
            store: fixture.store,
            appearance: light,
            makeKey: false
        )
        var didClose = false
        defer {
            fixture.store.cancelCurrentOperation()
            if !didClose { close(lightCapture.window) }
        }

        try assertMinimumMainWindowStatusEvidence(
            capture: lightCapture,
            store: fixture.store,
            appearance: light
        )

        fixture.store.cancelCurrentOperation()
        await closeAndDrain(lightCapture.window)
        didClose = true
    }

    func testMinimumMainWindowDarkIncreasedContrastKeyWindowKeepsWarningCollectionAndOperationVisible() async throws {
        try requireIsolatedAppKitInputRun()
        let appearance = Appearance(
            scheme: .dark,
            contrast: .increased,
            appKitName: .accessibilityHighContrastDarkAqua,
            artifactName: "main-window-minimum-dark-increased-contrast"
        )
        let fixture = try await makeConcurrentStatusFixture()
        let capture = try await renderProductionWindow(
            store: fixture.store,
            appearance: appearance,
            makeKey: true
        )
        var didClose = false
        defer {
            fixture.store.cancelCurrentOperation()
            if !didClose { close(capture.window) }
        }
        try assertMinimumMainWindowStatusEvidence(
            capture: capture,
            store: fixture.store,
            appearance: appearance
        )
        fixture.store.cancelCurrentOperation()
        await closeAndDrain(capture.window)
        didClose = true
    }

    func testApplicationToolbarKeepsOnePrimaryActionAndLeavesQuitInTheContextMenu() async throws {
        let fixture = try await makeLoadedApplicationFixture()
        let launchApplication = try XCTUnwrap(fixture.store.applications.first { !$0.isRunning })
        let runningApplication = try XCTUnwrap(fixture.store.applications.first(where: \.isRunning))
        fixture.store.selectedApplicationID = launchApplication.id

        XCTAssertTrue(
            mirrorContains(
                "Launch selected app",
                in: ApplicationBrowserView(store: fixture.store).body
            )
        )

        fixture.store.selectedApplicationID = runningApplication.id
        let runningBody = ApplicationBrowserView(store: fixture.store).body
        XCTAssertTrue(
            mirrorContains("Resume selected app", in: runningBody)
        )
        XCTAssertFalse(
            mirrorContains("Quit selected app on the host", in: runningBody),
            "Quit remains in the native application context menu and must not compete with Resume in the toolbar."
        )
    }

    func testRunningApplicationUsesTheNormalApplicationCollection() async throws {
        let fixture = try await makeLoadedApplicationFixture()
        let browserBody = ApplicationBrowserView(store: fixture.store).body
        XCTAssertNil(
            reflectedView(named: "CurrentSessionRail", in: browserBody),
            "Running apps must not be pulled into a separate full-width session rail."
        )
        let collection = try XCTUnwrap(
            reflectedView(named: "ApplicationCollectionView", in: browserBody)
        )
        XCTAssertTrue(
            mirrorContains("Media Center", in: collection),
            "The running app must remain in the same collection as every other application."
        )
    }

    func testHostCommandFallbackIsLocalizedAndSelectedHostProvidesRealActions() {
        let fallback = UmbraLocalization.string("No Host Selected")
        XCTAssertEqual(fallback, "No Host Selected")
        let commandBody = UmbraCommands().body
        XCTAssertEqual(reflectedStringCount(fallback, in: commandBody), 1)
        XCTAssertTrue(
            containsDisabledButton(labeled: fallback, in: commandBody),
            "The one no-host fallback command must carry SwiftUI's disabled environment transform."
        )

        let host = makeHost()
        let actionGroups = HostBrowserPresentation(host: host).actionGroups
        let actionTitles = actionGroups.flatMap(\.actions).map(\.title)

        XCTAssertFalse(actionGroups.isEmpty)
        XCTAssertFalse(actionTitles.isEmpty)
        XCTAssertFalse(actionTitles.contains(fallback))
        XCTAssertTrue(
            actionGroups.flatMap(\.actions).contains { $0.kind == .openApplications }
        )
        XCTAssertTrue(actionTitles.contains("Open Applications"))
    }

    func testSelectedKeyboardFocusAndHeldPointerPressProduceStableDistinctTileVisuals() async throws {
        try requireIsolatedAppKitInputRun()
        let fixture = try await makeLoadedApplicationFixture()
        fixture.store.selectedApplicationID = fixture.store.applications.first { !$0.isRunning }?.id
        let capture = try await renderApplicationWindow(store: fixture.store, makeKey: true)
        var didClose = false
        defer { if !didClose { close(capture.window) } }

        let collectionView = try XCTUnwrap(findSubview(
            of: ApplicationCollectionNSView.self,
            in: capture.hostingView
        ))
        XCTAssertTrue(capture.window.makeFirstResponder(collectionView))
        collectionView.keyDown(with: try keyEvent(keyCode: 115))
        try await settle(capture.hostingView)

        let selectedID = try XCTUnwrap(fixture.store.selectedApplicationID)
        let selectedIndex = try XCTUnwrap(
            fixture.store.visibleApplications
                .firstIndex { $0.id == selectedID }
        )
        let item = try XCTUnwrap(collectionView.item(at: IndexPath(item: selectedIndex, section: 0)))
        let focusedFrame = item.view.frame
        let focused = try capturePNG(of: item.view)
        let focusedAgain = try capturePNG(of: item.view)
        XCTAssertEqual(focused, focusedAgain, "A settled keyboard-focus state must render deterministically.")
        try writeArtifact(focused, name: "application-tile-selected-keyboard-focus-increased-contrast.png")

        _ = collectionView.prepareContextMenu(for: selectedID)
        collectionView.beginPrimaryPress(applicationID: selectedID)
        XCTAssertEqual(item.view.frame, focusedFrame)
        let pressed = try capturePNG(of: item.view)
        let pressedAgain = try capturePNG(of: item.view)
        XCTAssertEqual(pressed, pressedAgain, "A held pointer press must render deterministically.")
        XCTAssertNotEqual(pressed, focused, "Pointer contact must remain visually distinct from keyboard focus.")
        XCTAssertEqual(item.view.frame, focusedFrame, "Press feedback must not change tile geometry.")
        try writeArtifact(pressed, name: "application-tile-held-pointer-press-increased-contrast.png")
        collectionView.endPrimaryPress()

        let contextSelection = try capturePNG(of: item.view)
        let contextSelectionAgain = try capturePNG(of: item.view)
        XCTAssertEqual(
            contextSelection,
            contextSelectionAgain,
            "A selected tile behind its context menu must render deterministically."
        )
        XCTAssertNotEqual(contextSelection, focused)
        XCTAssertNotEqual(contextSelection, pressed)
        try writeArtifact(
            contextSelection,
            name: "application-tile-context-menu-selection-increased-contrast.png"
        )
        await closeAndDrain(capture.window)
        didClose = true
    }

    func testNativeContextMenuOpenStateIsAttachedAndKeepsTileSelected() async throws {
        try requireIsolatedAppKitInputRun()
        let fixture = try await makeLoadedApplicationFixture()
        let capture = try await renderApplicationWindow(store: fixture.store, makeKey: true)
        var didClose = false
        defer { if !didClose { close(capture.window) } }

        let collectionView = try XCTUnwrap(findSubview(
            of: ApplicationCollectionNSView.self,
            in: capture.hostingView
        ))
        let application = try XCTUnwrap(
            fixture.store.visibleApplications.filter { !$0.isRunning }.dropFirst().first
        )
        let applicationIndex = try XCTUnwrap(
            fixture.store.visibleApplications
                .firstIndex { $0.id == application.id }
        )
        let indexPath = IndexPath(item: applicationIndex, section: 0)
        let item = try XCTUnwrap(collectionView.item(at: indexPath))
        let menu = try XCTUnwrap(collectionView.prepareContextMenu(for: application.id))
        try await settle(capture.hostingView)

        XCTAssertEqual(collectionView.selectionIndexPaths, [indexPath])
        XCTAssertEqual(fixture.store.selectedApplicationID, application.id)
        XCTAssertEqual(menu.items.first?.title, "Launch \(application.name)")
        XCTAssertTrue(menu.items.contains { $0.title == "Direct Launch" })
        XCTAssertTrue(menu.items.contains { $0.title == "Hide App" })

        let contextTile = try capturePNG(of: item.view)
        try writeArtifact(contextTile, name: "application-tile-context-menu-selection-increased-contrast.png")

        let probe = NativeMenuCaptureProbe(
            menu: menu,
            excludingWindowNumbers: Set(NSApp.windows.map(\.windowNumber))
        )
        let timer = Timer(
            timeInterval: 0.08,
            target: probe,
            selector: #selector(NativeMenuCaptureProbe.captureAndDismiss),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .eventTracking)
        _ = menu.popUp(
            positioning: menu.items.first,
            at: NSPoint(x: item.view.frame.minX + 12, y: item.view.frame.minY + 12),
            in: collectionView
        )

        XCTAssertTrue(probe.menuWasAttached, "The evidence must exercise an actually open native NSMenu.")
        XCTAssertEqual(collectionView.selectionIndexPaths, [indexPath])
        try removeArtifactIfPresent("application-native-context-menu-open-increased-contrast.png")
        if let menuPNG = probe.menuPNG {
            try writeArtifact(
                menuPNG,
                name: "application-native-context-menu-highlighted-launch-increased-contrast.png"
            )
        } else {
            try writeArtifact(
                Data(
                    "NSMenu was attached and tracked, but AppKit did not expose its private menu window through NSApplication.windows; no menu bitmap was fabricated.\n"
                        .utf8
                ),
                name: "application-native-context-menu-open-platform-limitation.txt"
            )
        }
        try writeArtifact(
            Data(
                "The test opens and tracks the production NSMenu, asserts all three native rows (Launch, Direct Launch, Hide App), and verifies the clicked tile remains selected. AppKit exposes its private menu window to NSView bitmap caching, but only the highlighted row's SwiftUI label sublayer serializes; unhighlighted labels appear as blank menu space. The PNG is therefore explicitly named as the highlighted Launch-row evidence and is not claimed as a complete menu bitmap. No missing rows were fabricated or composited.\n"
                    .utf8
            ),
            name: "application-native-context-menu-bitmap-platform-limitation.txt"
        )
        await closeAndDrain(capture.window)
        didClose = true
    }

    func testWindowHostedSettingsExposesNativeTabToolbarAndStableViewport() async throws {
        try requireIsolatedAppKitInputRun()
        let suiteName = "FinalNativeDesignEvidenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update {
            $0.displayResolutionPolicy = .configured
            $0.width = 3_841
            $0.height = 2_161
            $0.fps = 75
            $0.autoAdjustBitrate = false
            $0.enableVSync = false
        }

        let darkAppearance = Appearance(
            scheme: .dark,
            contrast: .increased,
            appKitName: .accessibilityHighContrastDarkAqua,
            artifactName: "settings-window-video-dark-increased-contrast"
        )
        let lightAppearance = Appearance(
            scheme: .light,
            contrast: .increased,
            appKitName: .accessibilityHighContrastAqua,
            artifactName: "settings-window-video-light-increased-contrast"
        )
        let hostingView = NSHostingView(rootView: settingsRootView(
            preferences: preferences,
            appearance: darkAppearance
        ))
        hostingView.frame = NSRect(
            origin: .zero,
            size: CGSize(width: UmbraLayout.settingsWidth, height: UmbraLayout.settingsMaximumHeight)
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: darkAppearance.appKitName)
        window.title = "Umbra Settings"
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        var didClose = false
        defer { if !didClose { close(window) } }

        try await settle(hostingView, passes: 16)
        // Outside a SwiftUI Settings scene, the first TabView pass reserves
        // toolbar geometry before installing its native items. Reapplying the
        // same production root completes that in-process AppKit transaction.
        hostingView.rootView = settingsRootView(
            preferences: preferences,
            appearance: darkAppearance
        )
        try await settle(hostingView, passes: 16)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        try await settle(frameView)
        let scrollViews = findSubviews(of: NSScrollView.self, in: hostingView)
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.height > 0 }
        let settingsScrollView = try XCTUnwrap(scrollViews.first { $0.documentView != nil })

        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentLayoutRect.width, UmbraLayout.settingsWidth, accuracy: 1)
        XCTAssertLessThanOrEqual(window.contentLayoutRect.height, UmbraLayout.settingsMaximumHeight + 1)
        XCTAssertLessThanOrEqual(
            settingsScrollView.documentView?.bounds.height ?? 0,
            settingsScrollView.contentView.bounds.height + 1,
            "The simplified video pane should use its intrinsic height instead of creating unnecessary scrolling."
        )
        XCTAssertTrue(settingsScrollView.hasVerticalScroller)
        XCTAssertFalse(settingsScrollView.hasHorizontalScroller)

        let settingsBody = UmbraSettingsView(
            preferences: preferences,
            initialSelection: .video
        ).body
        for tabName in ["General", "Video", "Audio", "Input", "Controller", "Advanced"] {
            XCTAssertTrue(mirrorContains(tabName, in: settingsBody))
        }
        let darkWarmupRepresentation = try captureBitmap(of: frameView)
        XCTAssertGreaterThan(darkWarmupRepresentation.size.height, hostingView.bounds.height)
        let settingsContentRect = hostingView.convert(hostingView.bounds, to: frameView)
        let darkContentRepresentation = try captureBitmap(
            of: frameView,
            in: settingsContentRect
        )

        window.appearance = NSAppearance(named: lightAppearance.appKitName)
        hostingView.appearance = NSAppearance(named: lightAppearance.appKitName)
        hostingView.rootView = settingsRootView(
            preferences: preferences,
            appearance: lightAppearance
        )
        try await settle(hostingView, passes: 16)
        try await settle(frameView)
        let lightRepresentation = try captureBitmap(of: frameView)
        try writeArtifact(
            try pngData(lightRepresentation),
            name: "\(lightAppearance.artifactName).png"
        )

        XCTAssertNotEqual(
            try pngData(darkContentRepresentation),
            try pngData(lightRepresentation)
        )
        try writeArtifact(
            try pngData(darkContentRepresentation),
            name: "settings-content-video-dark-increased-contrast.png"
        )

        try removeArtifactIfPresent("settings-scene-toolbar-platform-limitation.txt")
        try removeArtifactIfPresent("settings-window-video-dark-increased-contrast.png")
        try writeArtifact(
            Data(
                "The in-process titled NSWindow renders the production Settings TabView toolbar in light increased contrast after AppKit completes its second layout transaction. Under dark increased contrast, NSView bitmap caching does not serialize the unified-toolbar label sublayers even though the production content viewport, controls, and scrolling render correctly. The evidence therefore includes a truthful dark content-viewport capture and does not fabricate or composite native toolbar chrome. Launching and externally capturing the @main Settings scene would require the UI automation/screencapture paths this lane explicitly forbids.\n"
                    .utf8
            ),
            name: "settings-dark-toolbar-bitmap-platform-limitation.txt"
        )
        await closeAndDrain(window)
        didClose = true
    }

    private func assertMinimumMainWindowStatusEvidence(
        capture: WindowCapture,
        store: AppStore,
        appearance: Appearance
    ) throws {
        XCTAssertEqual(capture.window.contentLayoutRect.width, minimumMainContentSize.width)
        XCTAssertGreaterThanOrEqual(capture.window.contentLayoutRect.height, minimumMainContentSize.height)
        XCTAssertLessThanOrEqual(capture.window.contentLayoutRect.height, 600)
        XCTAssertGreaterThan(capture.representation.size.height, minimumMainContentSize.height)

        let browserBody = ApplicationBrowserView(store: store).body
        XCTAssertTrue(mirrorContains("Umbra is showing the last saved application catalog.", in: browserBody))
        XCTAssertTrue(mirrorContains("Media Center", in: browserBody))
        XCTAssertTrue(try XCTUnwrap(store.applications.first(where: \.isRunning)).isRunning)
        let operation = try XCTUnwrap(store.operation)
        let operationBody = OperationRail(operation: operation, cancel: {}).body
        XCTAssertTrue(mirrorContains("Starting video...", in: operationBody))
        XCTAssertFalse(mirrorContains("Stream startup continues", in: operationBody))
        XCTAssertFalse(mirrorContains("The selected display cannot present HDR", in: operationBody))
        XCTAssertTrue(mirrorContains("Cancel", in: operationBody))

        let collectionScrollView = try XCTUnwrap(findSubview(of: NSScrollView.self, in: capture.hostingView) {
            findSubview(of: ApplicationCollectionNSView.self, in: $0) != nil
        })
        XCTAssertTrue(collectionScrollView.hasVerticalScroller)
        XCTAssertFalse(collectionScrollView.hasHorizontalScroller)
        XCTAssertGreaterThan(collectionScrollView.contentView.bounds.height, 0)
        XCTAssertGreaterThan(collectionScrollView.documentView?.bounds.height ?? 0, 0)
        assertVisibleAndUnclipped(collectionScrollView, in: capture.window)
        let collectionRect = collectionScrollView.convert(collectionScrollView.bounds, to: nil)
        let topRailReservation = capture.window.contentLayoutRect.maxY - collectionRect.maxY
        let bottomRailReservation = collectionRect.minY - capture.window.contentLayoutRect.minY
        let calloutLineHeight = ceil(NSFont.preferredFont(forTextStyle: .callout).boundingRectForFont.height)
        let captionLineHeight = ceil(NSFont.preferredFont(forTextStyle: .caption1).boundingRectForFont.height)
        let minimumTopRailReservation = (UmbraLayout.space3 * 2) + calloutLineHeight
        let minimumBottomRailReservation = (UmbraLayout.space3 * 2)
            + calloutLineHeight
            + UmbraLayout.space1
            + captionLineHeight
        XCTAssertGreaterThanOrEqual(
            topRailReservation,
            minimumTopRailReservation,
            "The catalog warning must remain below the toolbar without displacing the application collection."
        )
        XCTAssertGreaterThanOrEqual(
            bottomRailReservation,
            minimumBottomRailReservation,
            "The operation rail must reserve enough height for title, message, and Cancel."
        )
        let scrollOwners = findSubviews(of: NSScrollView.self, in: capture.hostingView).filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.documentView != nil && $0.bounds.height > 0
        }
        XCTAssertEqual(scrollOwners.count, 1, "The application collection must be the only scroll owner.")

        if appearance.scheme == .dark {
            try removeArtifactIfPresent("\(appearance.artifactName).png")
            try writeArtifact(
                try capturePNG(of: capture.hostingView),
                name: "main-content-minimum-dark-increased-contrast.png"
            )
            try writeArtifact(
                Data(
                    "The dark increased-contrast production window is hosted and geometry-verified as a key-window isolation test. NSView bitmap caching omits SwiftUI label sublayers in the unified native toolbar under this appearance, producing false white control blobs. The evidence intentionally captures the truthful production content viewport instead of presenting or compositing false toolbar chrome. External window capture would require a screencapture/UI-automation path forbidden for this lane.\n"
                        .utf8
                ),
                name: "main-dark-toolbar-bitmap-platform-limitation.txt"
            )
        } else {
            let png = try pngData(capture.representation)
            try writeArtifact(png, name: "\(appearance.artifactName).png")
        }
    }

    private func makeConcurrentStatusFixture() async throws -> (
        store: AppStore,
        service: FinalVisualEvidenceService
    ) {
        let service = FinalVisualEvidenceService()
        let store = AppStore(service: service)
        store.start()
        await waitUntil { !store.hosts.isEmpty }
        let host = try XCTUnwrap(store.hosts.first)
        store.openApplications(for: host)
        await waitUntil { !store.applications.isEmpty }
        let running = try XCTUnwrap(store.applications.first(where: \.isRunning))
        store.selectedApplicationID = running.id

        service.send(.applicationCatalogRefreshWarning(
            hostID: host.id,
            message: "Umbra is showing the last saved application catalog."
        ))
        store.launch(running)
        await waitUntil { service.applicationLaunchStarted }
        service.send(.configurationWarnings([
            "The selected display cannot present HDR. Umbra will use SDR for this stream.",
            "The active audio device cannot play surround sound. Umbra will use Stereo for this stream.",
        ]))
        service.send(.sessionConnecting(.videoStreamInitialization))
        await waitUntil { store.operation?.message == "Starting video..." }
        return (store, service)
    }

    private func makeLoadedApplicationFixture() async throws -> (
        store: AppStore,
        service: FinalVisualEvidenceService
    ) {
        let service = FinalVisualEvidenceService()
        let store = AppStore(service: service)
        store.start()
        await waitUntil { !store.hosts.isEmpty }
        let host = try XCTUnwrap(store.hosts.first)
        store.openApplications(for: host)
        await waitUntil { !store.applications.isEmpty }
        return (store, service)
    }

    private func renderProductionWindow(
        store: AppStore,
        appearance: Appearance,
        makeKey: Bool
    ) async throws -> WindowCapture {
        let hostingView = NSHostingView(rootView: productionRootView(
            store: store,
            appearance: appearance
        ))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: minimumMainContentSize)
        let window: NSWindow
        if makeKey {
            window = VisualEvidenceKeyWindow(
                contentRect: hostingView.frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
        } else {
            window = NSWindow(
                contentRect: hostingView.frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
        }
        window.appearance = NSAppearance(named: appearance.appKitName)
        window.title = "Umbra"
        window.contentView = hostingView
        if makeKey {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderBack(nil)
        }
        try await settle(hostingView, passes: 16)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        try await settle(frameView)
        return WindowCapture(
            window: window,
            hostingView: hostingView,
            frameView: frameView,
            representation: try captureBitmap(of: frameView)
        )
    }

    private func productionRootView(
        store: AppStore,
        appearance: Appearance
    ) -> AnyView {
        AnyView(
            RootView(store: store)
                .environment(\.colorScheme, appearance.scheme)
                .environment(\._colorSchemeContrast, appearance.contrast)
        )
    }

    private func settingsRootView(
        preferences: PreferencesStore,
        appearance: Appearance
    ) -> AnyView {
        AnyView(
            UmbraSettingsView(preferences: preferences, initialSelection: .video)
                .environment(\.colorScheme, appearance.scheme)
                .environment(\._colorSchemeContrast, appearance.contrast)
        )
    }

    private func renderApplicationWindow(
        store: AppStore,
        makeKey: Bool
    ) async throws -> WindowCapture {
        try await renderProductionWindow(
            store: store,
            appearance: Appearance(
                scheme: .dark,
                contrast: .increased,
                appKitName: .accessibilityHighContrastDarkAqua,
                artifactName: "unused"
            ),
            makeKey: makeKey
        )
    }

    private func assertVisibleAndUnclipped(
        _ view: NSView,
        in window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rect = view.convert(view.bounds, to: nil)
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, file: file, line: line)
        XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
        XCTAssertGreaterThan(rect.height, 0, file: file, line: line)
        XCTAssertTrue(
            window.contentLayoutRect.insetBy(dx: -1, dy: -1).contains(rect),
            "\(type(of: view)) at \(rect) falls outside content layout \(window.contentLayoutRect).",
            file: file,
            line: line
        )
    }

    private func captureBitmap(of view: NSView) throws -> NSBitmapImageRep {
        try captureBitmap(of: view, in: view.bounds)
    }

    private func captureBitmap(
        of view: NSView,
        in rect: NSRect
    ) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        var captured: NSBitmapImageRep?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let representation = view.bitmapImageRepForCachingDisplay(in: rect) else {
                return
            }
            representation.size = rect.size
            view.cacheDisplay(in: rect, to: representation)
            captured = representation
        }
        return try XCTUnwrap(captured)
    }

    private func capturePNG(of view: NSView) throws -> Data {
        try pngData(captureBitmap(of: view))
    }

    private func pngData(_ representation: NSBitmapImageRep) throws -> Data {
        try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func writeArtifact(_ data: Data, name: String) throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["UMBRA_UI_SNAPSHOT_DIR"] else {
            return
        }
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func removeArtifactIfPresent(_ name: String) throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["UMBRA_UI_SNAPSHOT_DIR"] else {
            return
        }
        let url = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func settle(_ view: NSView, passes: Int = 10) async throws {
        for _ in 0..<passes {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition was not satisfied")
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private func closeAndDrain(_ window: NSWindow) async {
        close(window)
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func requireIsolatedAppKitInputRun() throws {
        guard ProcessInfo.processInfo.environment["UMBRA_RUN_APPKIT_INPUT_TESTS"] == "1" else {
            throw XCTSkip(
                "Run in isolation with UMBRA_RUN_APPKIT_INPUT_TESTS=1 because this test owns the key window or native menu-tracking loop."
            )
        }
    }

    private func keyEvent(keyCode: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func findSubview<T: NSView>(
        of type: T.Type,
        in root: NSView,
        where predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = root as? T, predicate(match) { return match }
        for subview in root.subviews {
            if let match = findSubview(of: type, in: subview, where: predicate) { return match }
        }
        return nil
    }

    private func findSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var matches: [T] = []
        if let match = root as? T { matches.append(match) }
        for subview in root.subviews {
            matches.append(contentsOf: findSubviews(of: type, in: subview))
        }
        return matches
    }

    private func mirrorContains(
        _ expected: String,
        in value: Any,
        depth: Int = 0,
        visited: inout Set<ObjectIdentifier>
    ) -> Bool {
        if let string = value as? String, string == expected { return true }
        if String(reflecting: value).contains("\"\(expected)\"") { return true }
        guard depth < 24 else { return false }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .class, let object = value as AnyObject? {
            let identifier = ObjectIdentifier(object)
            guard visited.insert(identifier).inserted else { return false }
        }
        for child in mirror.children {
            if mirrorContains(
                expected,
                in: child.value,
                depth: depth + 1,
                visited: &visited
            ) {
                return true
            }
        }
        return false
    }

    private func mirrorContains(_ expected: String, in value: Any) -> Bool {
        var visited: Set<ObjectIdentifier> = []
        return mirrorContains(expected, in: value, visited: &visited)
    }

    private func reflectedView(
        named typeName: String,
        in value: Any,
        depth: Int = 0
    ) -> (any View)? {
        let reflectedType = String(reflecting: type(of: value))
        if reflectedType.hasSuffix(".\(typeName)"), let view = value as? any View {
            return view
        }
        guard depth < 20 else { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return nil }
        for child in mirror.children {
            if let match = reflectedView(named: typeName, in: child.value, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    private func evaluatedBody<V: View>(of view: V) -> Any {
        view.body
    }

    private func reflectedTypeCount(
        named typeName: String,
        in value: Any,
        depth: Int = 0
    ) -> Int {
        guard depth < 32 else { return 0 }
        let ownCount = String(reflecting: type(of: value)).contains(typeName) ? 1 : 0
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return ownCount }
        return mirror.children.reduce(ownCount) { count, child in
            count + reflectedTypeCount(named: typeName, in: child.value, depth: depth + 1)
        }
    }

    private func reflectedStringCount(
        _ expected: String,
        in value: Any,
        depth: Int = 0
    ) -> Int {
        guard depth < 32 else { return 0 }
        let ownCount = (value as? String) == expected ? 1 : 0
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return ownCount }
        return mirror.children.reduce(ownCount) { count, child in
            count + reflectedStringCount(expected, in: child.value, depth: depth + 1)
        }
    }

    private func containsDisabledButton(
        labeled label: String,
        in value: Any,
        depth: Int = 0
    ) -> Bool {
        guard depth < 32 else { return false }
        let typeName = String(reflecting: type(of: value))
        if typeName.hasPrefix("SwiftUI.ModifiedContent<SwiftUI.Button"),
           typeName.contains("EnvironmentKeyTransformModifier<Swift.Bool>"),
           mirrorContains(label, in: value) {
            return true
        }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return false }
        return mirror.children.contains {
            containsDisabledButton(labeled: label, in: $0.value, depth: depth + 1)
        }
    }


    private func makeHost() -> HostDisplayModel {
        HostDisplayModel(
            id: HostID("final-visual-host"),
            name: "Studio Mac",
            status: .online,
            isPaired: true,
            hasActiveSession: true,
            runningApplicationID: ApplicationID(2),
            canWake: true,
            isServerSupported: true,
            details: "Ready"
        )
    }
}

@MainActor
private final class VisualEvidenceKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor
private final class NativeMenuCaptureProbe: NSObject {
    private let menu: NSMenu
    private let excludingWindowNumbers: Set<Int>
    private(set) var menuWasAttached = false
    private(set) var menuPNG: Data?

    init(menu: NSMenu, excludingWindowNumbers: Set<Int>) {
        self.menu = menu
        self.excludingWindowNumbers = excludingWindowNumbers
    }

    @objc
    func captureAndDismiss() {
        // This callback is dispatched in NSEventTrackingRunLoopMode while the
        // synchronous NSMenu.popUp call is still active. Reaching it proves
        // the native menu entered its tracking loop before cancellation.
        menuWasAttached = true
        let menuWindow = NSApp.windows.first {
            !excludingWindowNumbers.contains($0.windowNumber) && $0.isVisible
        }
        if let view = menuWindow?.contentView?.superview ?? menuWindow?.contentView {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            if let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                representation.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: representation)
                menuPNG = representation.representation(using: .png, properties: [:])
            }
        }
        menu.cancelTracking()
    }
}

@MainActor
private final class FinalVisualEvidenceService: UmbraClientServicing {
    private var eventHandler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?
    private let host: HostDisplayModel
    private let applications: [ApplicationDisplayModel]
    private(set) var applicationLaunchStarted = false

    init() {
        let hostID = HostID("final-visual-host")
        host = HostDisplayModel(
            id: hostID,
            name: "Studio Mac",
            status: .online,
            isPaired: true,
            hasActiveSession: true,
            runningApplicationID: ApplicationID(2),
            canWake: true,
            isServerSupported: true,
            details: "Ready"
        )
        applications = [
            ApplicationDisplayModel(
                id: ApplicationID(1),
                hostID: hostID,
                name: "Desktop",
                artworkURL: nil,
                isRunning: false,
                isHidden: false,
                isDirectLaunch: true
            ),
            ApplicationDisplayModel(
                id: ApplicationID(2),
                hostID: hostID,
                name: "Media Center",
                artworkURL: nil,
                isRunning: true,
                isHidden: false,
                isDirectLaunch: false
            ),
            ApplicationDisplayModel(
                id: ApplicationID(3),
                hostID: hostID,
                name: "Creative Workspace",
                artworkURL: nil,
                isRunning: false,
                isHidden: false,
                isDirectLaunch: false
            ),
            ApplicationDisplayModel(
                id: ApplicationID(4),
                hostID: hostID,
                name: "リモートデスクトップ",
                artworkURL: nil,
                isRunning: false,
                isHidden: false,
                isDirectLaunch: false
            ),
        ]
    }

    func setEventHandler(_ handler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?) {
        eventHandler = handler
    }

    func send(_ event: UmbraClientEvent) {
        eventHandler?(event)
    }

    func discoverHosts() async throws -> [HostDisplayModel] { [host] }
    func addHost(_ endpoint: HostEndpointInput) async throws -> HostDisplayModel { throw unavailable() }
    func pairSecureHost(invitationURI: String) async throws -> HostDisplayModel { throw unavailable() }
    func pairHost(_ request: PairingRequest) async throws -> HostDisplayModel { throw unavailable() }
    func cancelPairing(hostID: HostID) async {}
    func renameHost(id: HostID, name: String) async throws -> HostDisplayModel { throw unavailable() }
    func deleteHost(id: HostID) async throws { throw unavailable() }
    func wakeHost(id: HostID) async throws -> HostDisplayModel { throw unavailable() }
    func testNetwork(for id: HostID) async throws -> NetworkTestOutcome { .unavailable }
    func applications(for id: HostID, includeHidden: Bool) async throws -> [ApplicationDisplayModel] {
        applications
    }
    func launchApplication(id: ApplicationID, on hostID: HostID, resume: Bool) async throws {
        applicationLaunchStarted = true
        try await Task.sleep(for: .seconds(30))
    }
    func quitApplication(id: ApplicationID, on hostID: HostID) async throws { throw unavailable() }
    func setApplicationHidden(id: ApplicationID, on hostID: HostID, hidden: Bool) async throws {}
    func setDirectLaunch(id: ApplicationID, on hostID: HostID, enabled: Bool) async throws {}

    private func unavailable() -> UmbraClientServiceError {
        .unavailable("Visual evidence service does not perform this action.")
    }
}
