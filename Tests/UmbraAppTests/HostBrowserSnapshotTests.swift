import AppKit
import SwiftUI
import UmbraCore
import XCTest
@testable import UmbraApp

@MainActor
final class HostBrowserSnapshotTests: XCTestCase {
    private struct Appearance {
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
        let appKitName: NSAppearance.Name
        let name: String
    }

    func testHostBrowserRendersLightDarkContrastNarrowLongAndCJKStates() async throws {
        let hosts = hostileHosts()
        let store = AppStore(service: HostSnapshotService(hosts: hosts))
        store.start()
        await waitUntil { store.hosts.count == hosts.count }
        store.focusedHostID = hosts.first?.id

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
            let rendered = try await render(
                store: store,
                appearance: appearance,
                size: CGSize(width: 900, height: 720)
            )
            let table = try XCTUnwrap(rendered.table)
            XCTAssertEqual(rendered.representation.size, CGSize(width: 900, height: 720))
            XCTAssertEqual(table.numberOfRows, hosts.count)
            XCTAssertNil(table.headerView)
            XCTAssertTrue(table.usesAutomaticRowHeights)
            let png = try pngData(rendered.representation)
            pngs[appearance.name] = png
            try writeIfRequested(png, name: "host-browser-\(appearance.name).png")
        }

        XCTAssertNotEqual(pngs["light"], pngs["dark"])

        let narrow = try await render(
            store: store,
            appearance: appearances[0],
            size: CGSize(width: 420, height: 520)
        )
        let narrowTable = try XCTUnwrap(narrow.table)
        XCTAssertEqual(narrow.representation.size, CGSize(width: 420, height: 520))
        XCTAssertEqual(narrowTable.numberOfRows, hosts.count)
        let longNameRow = try XCTUnwrap(store.hosts.firstIndex { $0.id == HostID("long") })
        let readyRow = try XCTUnwrap(store.hosts.firstIndex { $0.id == HostID("ready") })
        let cjkRow = try XCTUnwrap(store.hosts.firstIndex { $0.id == HostID("cjk") })
        XCTAssertGreaterThan(narrowTable.rect(ofRow: longNameRow).height, narrowTable.rect(ofRow: readyRow).height)
        XCTAssertGreaterThan(narrowTable.rect(ofRow: cjkRow).height, 0)

        let readyCell = try XCTUnwrap(
            narrowTable.view(atColumn: 0, row: readyRow, makeIfNecessary: true)
        )
        let passiveActionTitles = Set(
            hostileHosts().compactMap {
                HostBrowserPresentation(host: $0).defaultAction?.compactTitle
            }
        )
        XCTAssertFalse(
            findSubviews(of: NSTextField.self, in: readyCell)
                .contains { passiveActionTitles.contains($0.stringValue) },
            "A host row must not present a noninteractive label that looks like its primary action."
        )
        try writeIfRequested(
            try pngData(narrow.representation),
            name: "host-browser-light-narrow.png"
        )
    }

    func testHostBrowserRendersDenseAndEmptyCollections() async throws {
        let denseHosts = (1...80).map { index in
            makeHost(
                id: "dense-\(index)",
                name: String(format: "Editing Workstation %02d", index),
                status: index.isMultiple(of: 9) ? .offline : .online,
                isPaired: !index.isMultiple(of: 7),
                hasActiveSession: index.isMultiple(of: 11),
                canWake: index.isMultiple(of: 9),
                isServerSupported: !index.isMultiple(of: 13)
            )
        }
        let denseStore = AppStore(service: HostSnapshotService(hosts: denseHosts))
        denseStore.start()
        await waitUntil { denseStore.hosts.count == denseHosts.count }
        denseStore.focusedHostID = denseHosts.first?.id
        let dark = Appearance(
            scheme: .dark,
            contrast: .standard,
            appKitName: .darkAqua,
            name: "dark"
        )
        let dense = try await render(
            store: denseStore,
            appearance: dark,
            size: CGSize(width: 720, height: 520)
        )
        let denseTable = try XCTUnwrap(dense.table)
        XCTAssertEqual(denseTable.numberOfRows, 80)
        XCTAssertLessThan(denseTable.rows(in: denseTable.visibleRect).length, 80)
        try writeIfRequested(
            try pngData(dense.representation),
            name: "host-browser-dark-dense.png"
        )

        let emptyStore = AppStore(service: HostSnapshotService(hosts: []))
        emptyStore.start()
        await waitUntil {
            if case .loaded = emptyStore.hostsState { return true }
            return false
        }
        let empty = try await render(
            store: emptyStore,
            appearance: dark,
            size: CGSize(width: 720, height: 520),
            expectsTable: false
        )
        XCTAssertNil(findSubview(of: HostTableNSView.self, in: empty.hostingView))
        try writeIfRequested(
            try pngData(empty.representation),
            name: "host-browser-dark-empty.png"
        )
    }

    func testHostBrowserRendersLoadingFailureAndSingleEmojiHost() async throws {
        let light = Appearance(
            scheme: .light,
            contrast: .standard,
            appKitName: .aqua,
            name: "light"
        )

        let loadingStore = AppStore(service: HostSnapshotService(hosts: []))
        let loading = try await render(
            store: loadingStore,
            appearance: light,
            size: CGSize(width: 720, height: 520),
            expectsTable: false
        )
        try writeIfRequested(
            try pngData(loading.representation),
            name: "host-browser-light-loading.png"
        )

        let failedStore = AppStore(service: HostSnapshotService(
            hosts: [],
            discoveryError: UmbraClientServiceError.unavailable(
                "The saved host list couldn’t be loaded. Check the network and try again."
            )
        ))
        failedStore.start()
        await waitUntil {
            if case .failed = failedStore.hostsState { return true }
            return false
        }
        let failed = try await render(
            store: failedStore,
            appearance: light,
            size: CGSize(width: 720, height: 520),
            expectsTable: false
        )
        try writeIfRequested(
            try pngData(failed.representation),
            name: "host-browser-light-failed.png"
        )

        let emojiHost = makeHost(
            id: "emoji",
            name: "Studio 🖥️ Rendering Host",
            status: .online,
            hasActiveSession: true
        )
        let singleStore = AppStore(service: HostSnapshotService(hosts: [emojiHost]))
        singleStore.start()
        await waitUntil { singleStore.hosts == [emojiHost] }
        singleStore.focusedHostID = emojiHost.id
        let single = try await render(
            store: singleStore,
            appearance: light,
            size: CGSize(width: 720, height: 520)
        )
        XCTAssertEqual(try XCTUnwrap(single.table).numberOfRows, 1)
        try writeIfRequested(
            try pngData(single.representation),
            name: "host-browser-light-one-row-emoji.png"
        )
    }

    func testProductionHostWindowPlacesTheSelectedHostActionInTheToolbar() async throws {
        guard ProcessInfo.processInfo.environment["UMBRA_RUN_APPKIT_INPUT_TESTS"] == "1" else {
            throw XCTSkip("Run in isolation because this test captures production key-window chrome.")
        }
        let host = makeHost(id: "ready", name: "Studio Mac", status: .online)
        let store = AppStore(service: HostSnapshotService(hosts: [host]))
        store.start()
        await waitUntil { store.hosts == [host] }
        store.focusedHostID = host.id

        let hostingView = NSHostingView(rootView: RootView(store: store))
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        for _ in 0..<16 {
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let frameView = try XCTUnwrap(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        let toolbarItems = window.toolbar?.items ?? []
        let toolbarItemDescriptions = toolbarItems.map {
            "id=\($0.itemIdentifier.rawValue), label=\($0.label), palette=\($0.paletteLabel)"
        }
        XCTAssertTrue(
            toolbarItems.contains {
                $0.label == "Open Applications" || $0.paletteLabel == "Open Applications"
            },
            toolbarItemDescriptions.joined(separator: " | ")
        )

        let representation = try XCTUnwrap(
            frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        )
        representation.size = frameView.bounds.size
        frameView.cacheDisplay(in: frameView.bounds, to: representation)
        try writeIfRequested(
            try pngData(representation),
            name: "host-browser-window-light.png"
        )
    }

    func testPairingSheetRendersWaitingAndRecoverableCancelledStates() async throws {
        guard ProcessInfo.processInfo.environment["UMBRA_RUN_APPKIT_INPUT_TESTS"] == "1" else {
            throw XCTSkip("Run in isolation because this test owns an AppKit sheet window.")
        }
        let host = makeHost(
            id: "pairing",
            name: "Studio Mac",
            status: .online,
            isPaired: false
        )
        let service = HostSnapshotService(hosts: [host], suspendsPairing: true)
        let store = AppStore(service: service)
        let content = ZStack {
            Color(nsColor: .windowBackgroundColor)
            PairHostSheet(host: host, pin: "4827", store: store)
        }
        .environment(\.colorScheme, .light)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 440, height: 360)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hostingView
        window.orderBack(nil)
        defer {
            store.cancelCurrentOperation()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        await waitUntil { store.operation?.kind == .pairing }
        for _ in 0..<8 {
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let waitingPNG = try capturePNG(of: hostingView)
        try writeIfRequested(waitingPNG, name: "pair-host-light-waiting.png")
        XCTAssertEqual(store.operation?.title, "Pairing with Host")
        XCTAssertTrue(store.operation?.message.contains("4827") == true)

        store.cancelCurrentOperation()
        await waitUntil { store.operation == nil }
        for _ in 0..<4 {
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelledPNG = try capturePNG(of: hostingView)
        try writeIfRequested(cancelledPNG, name: "pair-host-light-cancelled.png")
        XCTAssertNotEqual(waitingPNG, cancelledPNG)
        XCTAssertFalse(hostingView.bounds.isEmpty)
    }

    private func hostileHosts() -> [HostDisplayModel] {
        [
            makeHost(id: "ready", name: "Studio Mac", status: .online),
            makeHost(id: "streaming", name: "Living Room PC", status: .online, hasActiveSession: true),
            makeHost(id: "pair", name: "Render Node", status: .online, isPaired: false),
            makeHost(
                id: "pair-streaming",
                name: "Capture Station",
                status: .online,
                isPaired: false,
                hasActiveSession: true
            ),
            makeHost(id: "unsupported", name: "Legacy Host", status: .online, isServerSupported: false),
            makeHost(id: "offline-wake", name: "Office PC", status: .offline, canWake: true),
            makeHost(id: "offline", name: "Travel Rig", status: .offline),
            makeHost(id: "checking", name: "New Host", status: .unknown),
            makeHost(
                id: "long",
                name: "A Very Long Descriptive Workstation Name That Must Wrap Without Clipping",
                status: .online
            ),
            makeHost(id: "cjk", name: "制作スタジオの配信用コンピュータ", status: .online, isPaired: false),
        ]
    }

    private func makeHost(
        id: String,
        name: String,
        status: HostConnectionStatus,
        isPaired: Bool = true,
        hasActiveSession: Bool = false,
        canWake: Bool = false,
        isServerSupported: Bool = true
    ) -> HostDisplayModel {
        HostDisplayModel(
            id: HostID(id),
            name: name,
            status: status,
            isPaired: isPaired,
            hasActiveSession: hasActiveSession,
            canWake: canWake,
            isServerSupported: isServerSupported,
            details: ""
        )
    }

    private func render(
        store: AppStore,
        appearance: Appearance,
        size: CGSize,
        expectsTable: Bool = true
    ) async throws -> RenderedHostBrowser {
        let view = NavigationStack {
            HostBrowserView(store: store)
        }
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, appearance.scheme)
        .environment(\._colorSchemeContrast, appearance.contrast)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: appearance.appKitName)

        for _ in 0..<12 {
            hostingView.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(5))
        }
        hostingView.displayIfNeeded()

        let table = findSubview(of: HostTableNSView.self, in: hostingView)
        if expectsTable {
            XCTAssertNotNil(table)
        }
        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        representation.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        return RenderedHostBrowser(
            representation: representation,
            hostingView: hostingView,
            table: table
        )
    }

    private func pngData(_ representation: NSBitmapImageRep) throws -> Data {
        try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func capturePNG(of view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let representation = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        representation.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: representation)
        return try pngData(representation)
    }

    private func writeIfRequested(_ png: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["UMBRA_UI_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name))
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

    private func findSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var matches: [T] = []
        if let match = root as? T {
            matches.append(match)
        }
        for subview in root.subviews {
            matches.append(contentsOf: findSubviews(of: type, in: subview))
        }
        return matches
    }
}

@MainActor
private struct RenderedHostBrowser {
    let representation: NSBitmapImageRep
    let hostingView: NSView
    let table: HostTableNSView?
}

@MainActor
private final class HostSnapshotService: UmbraClientServicing {
    let hosts: [HostDisplayModel]
    let discoveryError: Error?
    let suspendsPairing: Bool

    init(
        hosts: [HostDisplayModel],
        discoveryError: Error? = nil,
        suspendsPairing: Bool = false
    ) {
        self.hosts = hosts
        self.discoveryError = discoveryError
        self.suspendsPairing = suspendsPairing
    }

    func setEventHandler(_ handler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?) {}
    func discoverHosts() async throws -> [HostDisplayModel] {
        if let discoveryError { throw discoveryError }
        return hosts
    }
    func addHost(_ endpoint: HostEndpointInput) async throws -> HostDisplayModel { throw unavailable() }
    func pairSecureHost(invitationURI: String) async throws -> HostDisplayModel { throw unavailable() }
    func pairHost(_ request: PairingRequest) async throws -> HostDisplayModel {
        guard suspendsPairing else { throw unavailable() }
        try await Task.sleep(for: .seconds(60))
        guard let host = hosts.first else { throw unavailable() }
        return host
    }
    func cancelPairing(hostID: HostID) async {}
    func renameHost(id: HostID, name: String) async throws -> HostDisplayModel { throw unavailable() }
    func deleteHost(id: HostID) async throws { throw unavailable() }
    func wakeHost(id: HostID) async throws -> HostDisplayModel { throw unavailable() }
    func testNetwork(for id: HostID) async throws -> NetworkTestOutcome { throw unavailable() }
    func applications(for id: HostID, includeHidden: Bool) async throws -> [ApplicationDisplayModel] { [] }
    func launchApplication(id: ApplicationID, on hostID: HostID, resume: Bool) async throws { throw unavailable() }
    func quitApplication(id: ApplicationID, on hostID: HostID) async throws { throw unavailable() }
    func setApplicationHidden(id: ApplicationID, on hostID: HostID, hidden: Bool) async throws { throw unavailable() }
    func setDirectLaunch(id: ApplicationID, on hostID: HostID, enabled: Bool) async throws { throw unavailable() }

    private func unavailable() -> UmbraClientServiceError {
        .unavailable("Snapshot service does not perform actions.")
    }
}
