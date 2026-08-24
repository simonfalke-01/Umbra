import AppKit
import SwiftUI
import XCTest
@testable import UmbraApp

@MainActor
final class HostTableNavigationTests: XCTestCase {
    func testReturnSpaceAndDoubleClickActivateExactlyOncePerGesture() throws {
        let readyHost = makeHost(id: "ready", name: "Ready Host", status: .online)
        let checkingHost = makeHost(id: "checking", name: "Checking Host", status: .unknown)
        let fixture = makeTable(hosts: [readyHost, checkingHost])
        fixture.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var activations: [HostID] = []
        fixture.table.activateHost = { activations.append($0) }

        fixture.table.keyDown(with: try keyEvent(keyCode: 36, characters: "\r"))
        fixture.table.keyDown(with: try keyEvent(keyCode: 36, characters: "\r", isARepeat: true))
        XCTAssertEqual(activations, [readyHost.id])

        fixture.table.keyDown(with: try keyEvent(keyCode: 49, characters: " "))
        XCTAssertEqual(activations, [readyHost.id, readyHost.id])

        fixture.table.finishPrimaryClick(clickCount: 1, hostID: readyHost.id)
        fixture.table.finishPrimaryClick(clickCount: 2, hostID: readyHost.id)
        fixture.table.finishPrimaryClick(clickCount: 3, hostID: readyHost.id)
        XCTAssertEqual(activations, [readyHost.id, readyHost.id, readyHost.id])

        fixture.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        fixture.table.keyDown(with: try keyEvent(keyCode: 36, characters: "\r"))
        fixture.table.finishPrimaryClick(clickCount: 2, hostID: checkingHost.id)
        XCTAssertEqual(activations, [readyHost.id, readyHost.id, readyHost.id])
    }

    func testContextMenuSelectsTheClickedHostBeforePresentation() {
        let alpha = makeHost(id: "alpha", name: "Alpha", status: .online)
        let beta = makeHost(id: "beta", name: "Beta", status: .online)
        let fixture = makeTable(hosts: [alpha, beta])
        fixture.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var selectedHostID: HostID?
        var menuHostID: HostID?
        fixture.table.selectionDidChange = { selectedHostID = $0 }
        fixture.table.contextMenu = { hostID in
            menuHostID = hostID
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Applications", action: nil, keyEquivalent: "")
            return menu
        }

        let menu = fixture.table.prepareContextMenu(for: beta.id)

        XCTAssertEqual(selectedHostID, beta.id)
        XCTAssertEqual(menuHostID, beta.id)
        XCTAssertEqual(fixture.table.selectedRow, 1)
        XCTAssertEqual(menu?.items.map(\.title), ["Open Applications"])
    }

    func testHostedTableUsesNativeSelectionTypeSelectAutomaticRowsAndVoiceOver() async throws {
        let hosts = [
            makeHost(id: "alpha", name: "Alpha Workstation", status: .online),
            makeHost(
                id: "cjk",
                name: "制作スタジオの非常に長いホスト名",
                status: .online,
                isPaired: false,
                hasActiveSession: true
            ),
        ]
        let harness = HostTableHarness(hosts: hosts)
        let hostingView = NSHostingView(rootView: HostTableHarnessView(harness: harness))
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 240)
        await settle(hostingView)

        let table = try XCTUnwrap(findSubview(of: HostTableNSView.self, in: hostingView))
        XCTAssertNil(table.headerView)
        XCTAssertTrue(table.usesAutomaticRowHeights)
        XCTAssertTrue(table.allowsTypeSelect)
        XCTAssertEqual(table.selectionHighlightStyle, .regular)
        XCTAssertEqual(table.accessibilityRole(), .table)
        XCTAssertEqual(table.accessibilityLabel(), "Hosts")
        XCTAssertEqual(table.selectedRow, 0)

        table.keyDown(with: try keyEvent(
            keyCode: 125,
            characters: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        ))
        XCTAssertEqual(table.selectedRow, 1)
        table.keyDown(with: try keyEvent(
            keyCode: 126,
            characters: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        ))
        XCTAssertEqual(table.selectedRow, 0)
        table.keyDown(with: try keyEvent(
            keyCode: 119,
            characters: String(UnicodeScalar(NSEndFunctionKey)!)
        ))
        table.keyDown(with: try keyEvent(
            keyCode: 115,
            characters: String(UnicodeScalar(NSHomeFunctionKey)!)
        ))
        XCTAssertTrue(harness.performedActions.isEmpty)
        table.keyDown(with: try keyEvent(keyCode: 0, characters: "制"))
        XCTAssertEqual(table.selectedRow, 1)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await settle(hostingView)
        XCTAssertEqual(table.selectedRow, 0)

        let typeSelectName = table.delegate?.tableView?(
            table,
            typeSelectStringFor: table.tableColumns.first,
            row: 1
        )
        XCTAssertEqual(typeSelectName, hosts[1].name)

        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        XCTAssertEqual(cell.accessibilityRole(), .cell)
        XCTAssertEqual(cell.accessibilityLabel(), hosts[1].name)
        XCTAssertEqual(cell.accessibilityValue() as? String, "Streaming, Pair Required")
        XCTAssertEqual(cell.accessibilityHelp(), "Press to pair host.")
        XCTAssertFalse(cell.isAccessibilitySelected())
        XCTAssertEqual(
            cell.accessibilityCustomActions()?.map(\.name),
            ["Pair Host...", "Test Network...", "Rename Host...", "Show Details", "Remove Host..."]
        )
        XCTAssertTrue(cell.accessibilityPerformPress())
        XCTAssertEqual(harness.performedActions.map { $0.0 }, [.pair])
        XCTAssertEqual(harness.performedActions.map { $0.1 }, [hosts[1].id])
        let renameAction = try XCTUnwrap(
            cell.accessibilityCustomActions()?.first { $0.name == "Rename Host..." }
        )
        XCTAssertTrue(renameAction.handler?() == true)
        XCTAssertEqual(harness.performedActions.map { $0.0 }, [.pair, .rename])
        XCTAssertGreaterThan(table.rect(ofRow: 1).height, 0)

        let selectedCell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertTrue(selectedCell.isAccessibilitySelected())

        let menu = try XCTUnwrap(table.prepareContextMenu(for: hosts[1].id))
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Pair Host...", "Test Network...", "Rename Host...", "Show Details", "Remove Host..."]
        )
        XCTAssertTrue(cell.isAccessibilitySelected())
        XCTAssertFalse(menu.items.contains { $0.title.localizedCaseInsensitiveContains("hidden") })
    }

    func testDiffableUpdatesPreserveStableHostSelectionAndChooseNearestReplacement() async throws {
        let alpha = makeHost(id: "alpha", name: "Alpha", status: .online)
        let beta = makeHost(id: "beta", name: "Beta", status: .online)
        let gamma = makeHost(id: "gamma", name: "Gamma", status: .online)
        let harness = HostTableHarness(hosts: [alpha, beta, gamma])
        harness.selectedHostID = beta.id
        let hostingView = NSHostingView(rootView: HostTableHarnessView(harness: harness))
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
        await settle(hostingView)
        let table = try XCTUnwrap(findSubview(of: HostTableNSView.self, in: hostingView))
        XCTAssertEqual(table.selectedRow, 1)

        harness.hosts = [gamma, beta, alpha]
        await settle(hostingView)
        XCTAssertEqual(harness.selectedHostID, beta.id)
        XCTAssertEqual(table.selectedRow, 1)

        harness.hosts = [gamma, alpha]
        await settle(hostingView)
        XCTAssertEqual(harness.selectedHostID, alpha.id)
        XCTAssertEqual(table.selectedRow, 1)
    }

    private func makeTable(hosts: [HostDisplayModel]) -> TableFixture {
        let table = HostTableNSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Fixture")))
        let dataSource = HostTableFixtureDataSource(count: hosts.count)
        table.dataSource = dataSource
        table.orderedHostIDs = { hosts.map(\.id) }
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        table.defaultAction = { id in
            hostsByID[id].flatMap { HostBrowserPresentation(host: $0).defaultAction }
        }
        table.reloadData()
        return TableFixture(table: table, dataSource: dataSource)
    }

    private func makeHost(
        id: String,
        name: String,
        status: HostConnectionStatus,
        isPaired: Bool = true,
        hasActiveSession: Bool = false
    ) -> HostDisplayModel {
        HostDisplayModel(
            id: HostID(id),
            name: name,
            status: status,
            isPaired: isPaired,
            hasActiveSession: hasActiveSession,
            canWake: status == .offline,
            isServerSupported: true,
            details: ""
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isARepeat,
            keyCode: keyCode
        ))
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<12 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(5))
        }
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
private final class HostTableHarness: ObservableObject {
    @Published var hosts: [HostDisplayModel]
    @Published var selectedHostID: HostID?
    private(set) var performedActions: [(HostBrowserActionKind, HostID)] = []

    init(hosts: [HostDisplayModel], selectedHostID: HostID? = nil) {
        self.hosts = hosts
        self.selectedHostID = selectedHostID
    }

    func perform(_ action: HostBrowserActionDescriptor, host: HostDisplayModel) {
        performedActions.append((action.kind, host.id))
    }
}

private struct HostTableHarnessView: View {
    @ObservedObject var harness: HostTableHarness

    var body: some View {
        HostTableView(
            hosts: harness.hosts,
            selectedHostID: $harness.selectedHostID,
            performAction: harness.perform
        )
    }
}

private struct TableFixture {
    let table: HostTableNSView
    // NSTableView does not retain its data source.
    let dataSource: HostTableFixtureDataSource
}

@MainActor
private final class HostTableFixtureDataSource: NSObject, NSTableViewDataSource {
    let count: Int

    init(count: Int) {
        self.count = count
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        count
    }
}
