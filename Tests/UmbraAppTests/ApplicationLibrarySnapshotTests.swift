import AppKit
import SwiftUI
import XCTest
@testable import UmbraApp

@MainActor
final class ApplicationLibrarySnapshotTests: XCTestCase {
    private struct Appearance {
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
        let appKitName: NSAppearance.Name
        let name: String
    }

    func testApplicationLibraryRendersAsContentLedCollection() async throws {
        let artwork = try makeArtworkFixtures()
        defer { try? FileManager.default.removeItem(at: artwork.directory) }
        let service = DemoUmbraClientService(artworkURLs: artwork.urls)
        let store = AppStore(service: service)
        store.start()
        await waitUntil { !store.hosts.isEmpty }
        let host = try XCTUnwrap(store.hosts.first(where: { $0.status == .online }))
        store.openApplications(for: host)
        await waitUntil { !store.applications.isEmpty }
        store.selectedApplicationID = store.applications.first(where: { !$0.isRunning })?.id

        let appearances = [
            Appearance(scheme: .light, contrast: .standard, appKitName: .aqua, name: "light"),
            Appearance(scheme: .dark, contrast: .standard, appKitName: .darkAqua, name: "dark"),
            Appearance(
                scheme: .light,
                contrast: .increased,
                appKitName: .accessibilityHighContrastAqua,
                name: "light-increased-contrast"
            ),
            Appearance(
                scheme: .dark,
                contrast: .increased,
                appKitName: .accessibilityHighContrastDarkAqua,
                name: "dark-increased-contrast"
            ),
        ]
        var pngs: [String: Data] = [:]
        for appearance in appearances {
            let representation = try render(
                store: store,
                appearance: appearance,
                expectedArtworkColors: artwork.colors
            )
            XCTAssertEqual(representation.size, CGSize(width: 1_040, height: 720))
            assertContainsArtworkColors(artwork.colors, in: representation)
            let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            pngs[appearance.name] = png
            try writeIfRequested(png, appearance: appearance)
        }
        XCTAssertNotEqual(pngs["light"], pngs["dark"])
        XCTAssertNotEqual(pngs["light"], pngs["light-increased-contrast"])
        XCTAssertNotEqual(pngs["dark"], pngs["dark-increased-contrast"])
    }

    func testApplicationLibraryRendersAtNarrowWindowWidth() async throws {
        let artwork = try makeArtworkFixtures()
        defer { try? FileManager.default.removeItem(at: artwork.directory) }
        let service = DemoUmbraClientService(artworkURLs: artwork.urls)
        let store = AppStore(service: service)
        store.start()
        await waitUntil { !store.hosts.isEmpty }
        let host = try XCTUnwrap(store.hosts.first(where: { $0.status == .online }))
        store.openApplications(for: host)
        await waitUntil { !store.applications.isEmpty }
        store.selectedApplicationID = store.applications.first(where: { !$0.isRunning })?.id

        let appearances = [
            Appearance(scheme: .light, contrast: .standard, appKitName: .aqua, name: "light"),
            Appearance(scheme: .dark, contrast: .standard, appKitName: .darkAqua, name: "dark"),
        ]
        let size = CGSize(width: 720, height: 720)
        for appearance in appearances {
            let representation = try render(
                store: store,
                appearance: appearance,
                size: size,
                expectedArtworkColors: artwork.colors
            )
            XCTAssertEqual(representation.size, size)
            assertContainsArtworkColors(artwork.colors, in: representation)
            let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            try writeIfRequested(png, appearance: appearance, suffix: "-narrow")
        }
    }

    func testApplicationLibraryRendersAuthoritativeEmptyState() async throws {
        let service = DemoUmbraClientService(applications: [])
        let store = AppStore(service: service)
        store.start()
        await waitUntil { !store.hosts.isEmpty }
        let host = try XCTUnwrap(store.hosts.first(where: { $0.status == .online }))
        store.openApplications(for: host)
        await waitUntil {
            if case .loaded = store.applicationsState { return true }
            return false
        }

        let appearance = Appearance(
            scheme: .light,
            contrast: .standard,
            appKitName: .aqua,
            name: "light"
        )
        let representation = try render(store: store, appearance: appearance)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try writeIfRequested(png, appearance: appearance, suffix: "-empty")
    }

    func testHostedLibraryRoutesArrowKeyIntoGridSelection() async throws {
        guard ProcessInfo.processInfo.environment["UMBRA_RUN_APPKIT_INPUT_TESTS"] == "1" else {
            throw XCTSkip(
                "Run in isolation with UMBRA_RUN_APPKIT_INPUT_TESTS=1; a key-window AppKit test destabilizes later media tests in the same process."
            )
        }
        let service = DemoUmbraClientService()
        let store = AppStore(service: service)
        store.start()
        await waitUntil { !store.hosts.isEmpty }
        let host = try XCTUnwrap(store.hosts.first(where: { $0.status == .online }))
        store.openApplications(for: host)
        await waitUntil { store.applications.count > 2 }
        let applications = store.visibleApplications
        let first = try XCTUnwrap(applications.first)
        let second = try XCTUnwrap(applications.dropFirst().first)
        store.selectedApplicationID = first.id

        let hostingView = NSHostingView(rootView: NavigationStack {
            ApplicationBrowserView(store: store)
        })
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_040, height: 720)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<8 {
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let collectionView = try XCTUnwrap(findSubview(
            of: ApplicationCollectionNSView.self,
            in: hostingView
        ))
        XCTAssertTrue(window.makeFirstResponder(collectionView))
        XCTAssertEqual(collectionView.selectionIndexPaths, [IndexPath(item: 0, section: 0)])
        XCTAssertEqual(store.selectedApplicationID, first.id)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            isARepeat: false,
            keyCode: 124
        ))
        window.sendEvent(event)
        await waitUntil { store.selectedApplicationID == second.id }
        XCTAssertEqual(store.selectedApplicationID, second.id)

        window.orderOut(nil)
        window.contentView = nil
        window.close()
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testNativeCollectionOwnsSelectionAndAccessibility() async throws {
        let applications = makeApplications(count: 30)
        let harness = ApplicationCollectionHarness(
            applications: applications,
            selectedApplicationID: applications[0].id,
            scrollPositionID: nil
        )
        let hostingView = NSHostingView(rootView: ApplicationCollectionHarnessView(harness: harness))
        hostingView.frame = CGRect(x: 0, y: 0, width: 720, height: 360)

        for _ in 0..<12 {
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        let collectionView = try XCTUnwrap(findSubview(
            of: ApplicationCollectionNSView.self,
            in: hostingView
        ))
        let selectedIndexPath = IndexPath(item: 0, section: 0)
        XCTAssertEqual(collectionView.selectionIndexPaths, [selectedIndexPath])
        XCTAssertTrue(collectionView.indexPathsForVisibleItems().contains(selectedIndexPath))
        let layoutAttributes = try XCTUnwrap(
            collectionView.collectionViewLayout?.layoutAttributesForItem(at: selectedIndexPath)
        )
        XCTAssertEqual(
            layoutAttributes.frame.width,
            UmbraLayout.applicationTileWidth,
            accuracy: 0.5,
            "Application artwork must keep a stable browsing density instead of expanding into oversized cards."
        )
        XCTAssertEqual(collectionView.accessibilityRole(), .grid)
        XCTAssertEqual(collectionView.accessibilityLabel(), "Applications")

        let item = try XCTUnwrap(collectionView.item(at: selectedIndexPath))
        XCTAssertEqual(item.view.accessibilityRole(), .cell)
        XCTAssertEqual(item.view.accessibilityLabel(), applications[0].name)
        XCTAssertEqual(item.view.accessibilityHelp(), "Press to launch \(applications[0].name).")
        XCTAssertEqual(item.view.isAccessibilitySelected(), true)
        XCTAssertTrue(item.view.accessibilityPerformPress())
        XCTAssertEqual(harness.activatedApplicationIDs, [applications[0].id])
    }

    func testNativeCollectionRestoresScrollPosition() async throws {
        guard ProcessInfo.processInfo.environment["UMBRA_RUN_APPKIT_INPUT_TESTS"] == "1" else {
            throw XCTSkip("Run in isolation because realizing an offscreen collection item owns an AppKit window.")
        }

        let applications = makeApplications(count: 30)
        let harness = ApplicationCollectionHarness(
            applications: applications,
            selectedApplicationID: applications[19].id,
            scrollPositionID: applications[19].id
        )
        let hostingView = NSHostingView(rootView: ApplicationCollectionHarnessView(harness: harness))
        hostingView.frame = CGRect(x: 0, y: 0, width: 720, height: 360)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderBack(nil)

        for _ in 0..<12 {
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        let collectionView = try XCTUnwrap(findSubview(
            of: ApplicationCollectionNSView.self,
            in: hostingView
        ))
        let selectedIndexPath = IndexPath(item: 19, section: 0)
        XCTAssertEqual(collectionView.selectionIndexPaths, [selectedIndexPath])
        XCTAssertTrue(collectionView.indexPathsForVisibleItems().contains(selectedIndexPath))

        window.orderOut(nil)
        window.contentView = nil
        window.close()
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testReusableHostedTilesKeepArtworkBoundToApplicationIdentity() throws {
        let artwork = try makeArtworkFixtures()
        defer { try? FileManager.default.removeItem(at: artwork.directory) }
        let hostID = HostID("artwork-reuse-host")
        let application: (Int, String) -> ApplicationDisplayModel = { id, name in
            ApplicationDisplayModel(
                id: ApplicationID(id),
                hostID: hostID,
                name: name,
                artworkURL: artwork.urls[id],
                isRunning: false,
                isHidden: false,
                isDirectLaunch: false
            )
        }
        let initialApplications = [application(4, "Creative Workspace"), application(8, "Remote Workspace")]
        let replacementApplications = [application(1, "Desktop"), application(5, "Game Library")]
        let item = ApplicationCollectionItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 168, height: 264)

        item.update(
            application: initialApplications[0],
            showsFocusRing: false,
            isPressed: false,
            onActivate: {}
        )
        try assertArtwork(
            color: XCTUnwrap(artwork.colorsByID[4]),
            application: initialApplications[0],
            in: item.view
        )

        item.update(
            application: initialApplications[1],
            showsFocusRing: false,
            isPressed: false,
            onActivate: {}
        )
        try assertArtwork(
            color: XCTUnwrap(artwork.colorsByID[8]),
            application: initialApplications[1],
            in: item.view
        )

        item.update(
            application: replacementApplications[0],
            showsFocusRing: false,
            isPressed: false,
            onActivate: {}
        )
        try assertArtwork(
            color: XCTUnwrap(artwork.colorsByID[1]),
            application: replacementApplications[0],
            in: item.view
        )

        item.update(
            application: replacementApplications[1],
            showsFocusRing: false,
            isPressed: false,
            onActivate: {}
        )
        try assertArtwork(
            color: XCTUnwrap(artwork.colorsByID[5]),
            application: replacementApplications[1],
            in: item.view
        )
    }

    func testTileAccessibilityNamesHiddenAndDirectLaunchStatus() {
        let hostID = HostID("tile-status-host")
        let item = ApplicationCollectionItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 168, height: 264)

        item.update(
            application: ApplicationDisplayModel(
                id: ApplicationID(1),
                hostID: hostID,
                name: "Hidden Utility",
                artworkURL: nil,
                isRunning: false,
                isHidden: true,
                isDirectLaunch: false
            ),
            showsFocusRing: false,
            isPressed: false,
            onActivate: {}
        )
        XCTAssertEqual(item.view.accessibilityValue() as? String, "Hidden")

        item.update(
            application: ApplicationDisplayModel(
                id: ApplicationID(2),
                hostID: hostID,
                name: "Desktop",
                artworkURL: nil,
                isRunning: false,
                isHidden: false,
                isDirectLaunch: true
            ),
            showsFocusRing: false,
            isPressed: false,
            onActivate: {}
        )
        XCTAssertEqual(item.view.accessibilityValue() as? String, "Direct Launch enabled")
    }

    func testRunningApplicationUsesNormalTileActionsAndAccessibility() async throws {
        let hostID = HostID("running-tile-host")
        let running = ApplicationDisplayModel(
            id: ApplicationID(1),
            hostID: hostID,
            name: "Desktop",
            artworkURL: nil,
            isRunning: true,
            isHidden: false,
            isDirectLaunch: false
        )
        let harness = ApplicationCollectionHarness(
            applications: [running],
            selectedApplicationID: running.id,
            scrollPositionID: nil
        )
        let hostingView = NSHostingView(rootView: ApplicationCollectionHarnessView(harness: harness))
        hostingView.frame = CGRect(x: 0, y: 0, width: 720, height: 360)
        for _ in 0..<8 {
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        let collectionView = try XCTUnwrap(findSubview(
            of: ApplicationCollectionNSView.self,
            in: hostingView
        ))
        let item = try XCTUnwrap(collectionView.item(at: IndexPath(item: 0, section: 0)))
        XCTAssertEqual(item.view.accessibilityLabel(), "Desktop")
        XCTAssertEqual(item.view.accessibilityValue() as? String, "Selected, Running")
        XCTAssertEqual(item.view.accessibilityHelp(), "Press to resume Desktop.")
        XCTAssertEqual(
            item.view.accessibilityCustomActions()?.map(\.name),
            ["Resume Desktop", "Direct Launch", "Quit Desktop..."]
        )

        let menu = try XCTUnwrap(collectionView.prepareContextMenu(for: running.id))
        XCTAssertEqual(
            menu.items.map(\.title),
            ["Resume Desktop", "", "Direct Launch", "Hide App", "", "Quit Desktop..."]
        )
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "Hide App" }).isEnabled)
        let quitAction = try XCTUnwrap(
            item.view.accessibilityCustomActions()?.first { $0.name == "Quit Desktop..." }
        )
        XCTAssertTrue(quitAction.handler?() == true)
        XCTAssertEqual(harness.quitRequestedApplicationIDs, [running.id])
    }

    func testRetainedAccessibilityActionKeepsItsOriginalTileActionAcrossReuse() throws {
        let hostID = HostID("accessibility-reuse-host")
        let first = ApplicationDisplayModel(
            id: ApplicationID(1),
            hostID: hostID,
            name: "First",
            artworkURL: nil,
            isRunning: false,
            isHidden: false,
            isDirectLaunch: false
        )
        let second = ApplicationDisplayModel(
            id: ApplicationID(2),
            hostID: hostID,
            name: "Second",
            artworkURL: nil,
            isRunning: false,
            isHidden: false,
            isDirectLaunch: false
        )
        let item = ApplicationCollectionItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 168, height: 264)
        var activations: [ApplicationID] = []

        item.update(
            application: first,
            showsFocusRing: false,
            isPressed: false,
            onActivate: { activations.append(first.id) }
        )
        let retainedAction = try XCTUnwrap(
            item.view.accessibilityCustomActions()?.first { $0.name == "Launch First" }
        )

        item.update(
            application: second,
            showsFocusRing: false,
            isPressed: false,
            onActivate: { activations.append(second.id) }
        )

        XCTAssertTrue(retainedAction.handler?() == true)
        XCTAssertEqual(
            activations,
            [first.id],
            "A retained accessibility action must not dispatch through a reused tile's new application."
        )
    }

    func testCollectionSnapshotUpdatePreservesSearchFieldFocus() async throws {
        guard ProcessInfo.processInfo.environment["UMBRA_RUN_APPKIT_INPUT_TESTS"] == "1" else {
            throw XCTSkip("Run in isolation because this test owns the key window and field editor.")
        }

        let applications = makeApplications(count: 8)
        let harness = ApplicationCollectionHarness(
            applications: applications,
            selectedApplicationID: applications[0].id,
            scrollPositionID: nil
        )
        let hostingView = NSHostingView(rootView: ApplicationCollectionHarnessView(harness: harness))
        let searchField = NSSearchField(frame: NSRect(x: 16, y: 372, width: 260, height: 28))
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 360)
        contentView.addSubview(hostingView)
        contentView.addSubview(searchField)

        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(searchField))
        let fieldEditor = try XCTUnwrap(searchField.currentEditor())

        harness.applications = Array(applications.dropFirst())
        for _ in 0..<8 {
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(window.firstResponder === fieldEditor)
        XCTAssertTrue(searchField.currentEditor() === fieldEditor)

        window.orderOut(nil)
        window.contentView = nil
        window.close()
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testApplicationLibraryWindowChromeRendersWithToolbarSearch() async throws {
        guard ProcessInfo.processInfo.environment["UMBRA_RUN_APPKIT_INPUT_TESTS"] == "1" else {
            throw XCTSkip("Run in isolation because this test captures the production key-window chrome.")
        }

        let artwork = try makeArtworkFixtures()
        defer { try? FileManager.default.removeItem(at: artwork.directory) }
        let service = DemoUmbraClientService(artworkURLs: artwork.urls)
        let store = AppStore(service: service)
        store.start()
        await waitUntil { !store.hosts.isEmpty }
        let host = try XCTUnwrap(store.hosts.first(where: { $0.status == .online }))
        store.openApplications(for: host)
        await waitUntil { !store.applications.isEmpty }

        let hostingView = NSHostingView(rootView: RootView(store: store))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_040, height: 720)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)

        for _ in 0..<12 {
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNotNil(window.toolbar)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        XCTAssertNotNil(findSubview(of: NSSearchField.self, in: frameView))
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        let representation = try XCTUnwrap(
            frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        )
        frameView.cacheDisplay(in: frameView.bounds, to: representation)
        XCTAssertGreaterThan(representation.size.height, hostingView.bounds.height)
        assertContainsArtworkColors(artwork.colors, in: representation)

        if let path = ProcessInfo.processInfo.environment["UMBRA_UI_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("applications-library-window-light.png"))
        }

        window.orderOut(nil)
        window.contentView = nil
        window.close()
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func makeArtworkFixtures() throws -> (
        directory: URL,
        urls: [Int: URL],
        colors: [NSColor],
        colorsByID: [Int: NSColor]
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraAppLibraryArtwork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures: [(Int, NSColor, String)] = [
            (1, NSColor(srgbRed: 0.29, green: 0.25, blue: 0.72, alpha: 1), "D"),
            (2, NSColor(srgbRed: 0.55, green: 0.24, blue: 0.67, alpha: 1), "M"),
            (4, NSColor(srgbRed: 0.05, green: 0.55, blue: 0.57, alpha: 1), "C"),
            (5, NSColor(srgbRed: 0.91, green: 0.42, blue: 0.09, alpha: 1), "G"),
            (8, NSColor(srgbRed: 0.10, green: 0.42, blue: 0.82, alpha: 1), "R"),
        ]
        var urls: [Int: URL] = [:]
        var encodedColors: [NSColor] = []
        var colorsByID: [Int: NSColor] = [:]
        for (id, color, initial) in fixtures {
            let size = NSSize(width: 300, height: 400)
            let image = NSImage(size: size, flipped: false) { rect in
                color.setFill()
                rect.fill()
                NSColor.white.withAlphaComponent(0.16).setFill()
                NSBezierPath(
                    roundedRect: rect.insetBy(dx: 32, dy: 48),
                    xRadius: 28,
                    yRadius: 28
                ).fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 108, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                let text = NSAttributedString(string: initial, attributes: attributes)
                let textSize = text.size()
                text.draw(at: NSPoint(
                    x: rect.midX - textSize.width / 2,
                    y: rect.midY - textSize.height / 2
                ))
                return true
            }
            let representation = try XCTUnwrap(
                image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
            )
            let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            let encodedRepresentation = try XCTUnwrap(NSBitmapImageRep(data: data))
            let encodedColor = try XCTUnwrap(encodedRepresentation.colorAt(x: 8, y: 8))
            encodedColors.append(encodedColor)
            colorsByID[id] = encodedColor
            let url = directory.appendingPathComponent("\(id).png")
            try data.write(to: url)
            FileArtworkImageCache.shared.insert(image, for: url)
            urls[id] = url
        }
        return (directory, urls, encodedColors, colorsByID)
    }

    private func makeApplications(count: Int) -> [ApplicationDisplayModel] {
        let hostID = HostID("collection-test-host")
        return (1...count).map { index in
            ApplicationDisplayModel(
                id: ApplicationID(index),
                hostID: hostID,
                name: String(format: "Application %02d", index),
                artworkURL: nil,
                isRunning: false,
                isHidden: false,
                isDirectLaunch: index.isMultiple(of: 7)
            )
        }
    }

    private func render(
        store: AppStore,
        appearance: Appearance,
        size: CGSize = CGSize(width: 1_040, height: 720),
        expectedArtworkColors: [NSColor] = []
    ) throws -> NSBitmapImageRep {
        let view = NavigationStack {
            ApplicationBrowserView(store: store)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, appearance.scheme)
        .environment(\._colorSchemeContrast, appearance.contrast)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: appearance.appKitName)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        representation.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        XCTAssertTrue(
            expectedArtworkColors.allSatisfy({ contains(color: $0, in: representation) }),
            "The snapshot was captured before all fixture-backed artwork rendered."
        )
        return representation
    }

    private func assertContainsArtworkColors(
        _ colors: [NSColor],
        in representation: NSBitmapImageRep,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for color in colors {
            XCTAssertTrue(
                contains(color: color, in: representation),
                "The rendered library did not contain the expected fixture artwork color \(color).",
                file: file,
                line: line
            )
        }
    }

    private func assertArtwork(
        color: NSColor,
        application: ApplicationDisplayModel,
        in itemView: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(itemView.accessibilityLabel(), application.name, file: file, line: line)
        itemView.layoutSubtreeIfNeeded()
        itemView.displayIfNeeded()
        let representation = try XCTUnwrap(
            itemView.bitmapImageRepForCachingDisplay(in: itemView.bounds),
            file: file,
            line: line
        )
        itemView.cacheDisplay(in: itemView.bounds, to: representation)
        XCTAssertTrue(
            contains(color: color, in: representation),
            "The reusable tile for \(application.name) displayed another application's artwork.",
            file: file,
            line: line
        )
    }

    private func contains(color target: NSColor, in representation: NSBitmapImageRep) -> Bool {
        let targetHue = target.hueComponent
        for y in stride(from: 0, to: representation.pixelsHigh, by: 16) {
            for x in stride(from: 0, to: representation.pixelsWide, by: 16) {
                guard let sample = representation.colorAt(x: x, y: y) else { continue }
                let hueDistance = abs(sample.hueComponent - targetHue)
                if min(hueDistance, 1 - hueDistance) <= 0.04,
                   sample.saturationComponent >= 0.35,
                   abs(sample.brightnessComponent - target.brightnessComponent) <= 0.30 {
                    return true
                }
            }
        }
        return false
    }

    private func writeIfRequested(
        _ png: Data,
        appearance: Appearance,
        suffix: String = ""
    ) throws {
        guard let path = ProcessInfo.processInfo.environment["UMBRA_UI_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(
            to: directory.appendingPathComponent(
                "applications-library-\(appearance.name)\(suffix).png"
            )
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not satisfied")
    }

    private func findSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = findSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}

@MainActor
private final class ApplicationCollectionHarness: ObservableObject {
    @Published var applications: [ApplicationDisplayModel]
    @Published var selectedApplicationID: ApplicationID?
    @Published var scrollPositionID: ApplicationID?
    private(set) var activatedApplicationIDs: [ApplicationID] = []
    private(set) var quitRequestedApplicationIDs: [ApplicationID] = []

    init(
        applications: [ApplicationDisplayModel],
        selectedApplicationID: ApplicationID?,
        scrollPositionID: ApplicationID?
    ) {
        self.applications = applications
        self.selectedApplicationID = selectedApplicationID
        self.scrollPositionID = scrollPositionID
    }

    func activate(_ application: ApplicationDisplayModel) {
        activatedApplicationIDs.append(application.id)
    }

    func requestQuit(_ application: ApplicationDisplayModel) {
        quitRequestedApplicationIDs.append(application.id)
    }
}

private struct ApplicationCollectionHarnessView: View {
    @ObservedObject var harness: ApplicationCollectionHarness

    var body: some View {
        ApplicationCollectionView(
            applications: harness.applications,
            selectedApplicationID: $harness.selectedApplicationID,
            scrollPositionID: $harness.scrollPositionID,
            onActivate: harness.activate,
            onRequestQuit: harness.requestQuit,
            onToggleDirectLaunch: { _ in },
            onToggleHidden: { _ in }
        )
    }
}
