import AppKit
import SwiftUI

struct HostTableView: NSViewRepresentable {
    let hosts: [HostDisplayModel]
    @Binding var selectedHostID: HostID?
    let performAction: (HostBrowserActionDescriptor, HostDisplayModel) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedHostID: $selectedHostID,
            performAction: performAction
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = HostTableNSView(frame: .zero)
        let column = NSTableColumn(identifier: HostTableMetrics.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.allowsTypeSelect = true
        tableView.autosaveTableColumns = false
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.focusRingType = .default
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = HostTableMetrics.minimumRowHeight
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.usesAutomaticRowHeights = true
        tableView.setAccessibilityElement(true)
        tableView.setAccessibilityRole(.table)
        tableView.setAccessibilityLabel("Hosts")
        tableView.setAccessibilityIdentifier("host-table")

        let scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = tableView

        context.coordinator.install(tableView: tableView)
        context.coordinator.apply(hosts: hosts)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            selectedHostID: $selectedHostID,
            performAction: performAction
        )
        context.coordinator.apply(hosts: hosts)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate {
        private enum Section: Hashable {
            case hosts
        }

        private var selectedHostID: Binding<HostID?>
        private var performAction: (HostBrowserActionDescriptor, HostDisplayModel) -> Void
        private weak var tableView: HostTableNSView?
        private var dataSource: NSTableViewDiffableDataSource<Section, HostID>?
        private var hostsByID: [HostID: HostDisplayModel] = [:]
        private var hostOrder: [HostID] = []
        private var isApplyingState = false
        private var deferredSelectionPublication: Task<Void, Never>?

        init(
            selectedHostID: Binding<HostID?>,
            performAction: @escaping (HostBrowserActionDescriptor, HostDisplayModel) -> Void
        ) {
            self.selectedHostID = selectedHostID
            self.performAction = performAction
        }

        func update(
            selectedHostID: Binding<HostID?>,
            performAction: @escaping (HostBrowserActionDescriptor, HostDisplayModel) -> Void
        ) {
            self.selectedHostID = selectedHostID
            self.performAction = performAction
        }

        func install(tableView: HostTableNSView) {
            self.tableView = tableView
            tableView.delegate = self
            tableView.target = self
            tableView.doubleAction = #selector(activateDoubleClickedHost(_:))
            tableView.orderedHostIDs = { [weak self] in self?.hostOrder ?? [] }
            tableView.defaultAction = { [weak self] hostID in
                self?.hostsByID[hostID].flatMap { HostBrowserPresentation(host: $0).defaultAction }
            }
            tableView.activateHost = { [weak self] hostID in self?.activate(hostID) }
            tableView.contextMenu = { [weak self] hostID in self?.makeContextMenu(for: hostID) }
            tableView.selectionDidChange = { [weak self] hostID in self?.publishSelection(hostID) }

            dataSource = NSTableViewDiffableDataSource<Section, HostID>(
                tableView: tableView
            ) { [weak self] tableView, tableColumn, row, hostID in
                guard let self else { return NSTableCellView() }
                return self.makeCell(
                    tableView: tableView,
                    tableColumn: tableColumn,
                    row: row,
                    hostID: hostID
                )
            }
        }

        func uninstall() {
            deferredSelectionPublication?.cancel()
            tableView?.delegate = nil
            tableView?.target = nil
            tableView?.doubleAction = nil
            tableView?.orderedHostIDs = nil
            tableView?.defaultAction = nil
            tableView?.activateHost = nil
            tableView?.contextMenu = nil
            tableView?.selectionDidChange = nil
            dataSource = nil
        }

        func apply(hosts: [HostDisplayModel]) {
            guard let tableView, let dataSource else { return }

            let previousHosts = hostsByID
            let previousOrder = hostOrder
            hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
            hostOrder = hosts.map(\.id)

            var snapshot = NSDiffableDataSourceSnapshot<Section, HostID>()
            snapshot.appendSections([.hosts])
            snapshot.appendItems(hostOrder, toSection: .hosts)

            let existingIDs = Set(dataSource.snapshot().itemIdentifiers)
            let changedIDs = hosts.compactMap { host -> HostID? in
                guard existingIDs.contains(host.id), previousHosts[host.id] != host else { return nil }
                return host.id
            }
            if !changedIDs.isEmpty {
                snapshot.reloadItems(changedIDs)
            }

            isApplyingState = true
            if previousOrder != hostOrder || !changedIDs.isEmpty {
                dataSource.apply(snapshot, animatingDifferences: false)
            }
            tableView.layoutSubtreeIfNeeded()
            restoreSelection(in: tableView, previousOrder: previousOrder)
            updateVisibleSelection(in: tableView)
            isApplyingState = false
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingState, let tableView else { return }
            publishSelection(hostID(at: tableView.selectedRow))
            updateVisibleSelection(in: tableView)
        }

        func tableView(
            _ tableView: NSTableView,
            typeSelectStringFor tableColumn: NSTableColumn?,
            row: Int
        ) -> String? {
            hostID(at: row).flatMap { hostsByID[$0]?.name }
        }

        private func restoreSelection(
            in tableView: HostTableNSView,
            previousOrder: [HostID]
        ) {
            guard !hostOrder.isEmpty else {
                tableView.deselectAll(nil)
                publishSelectionAfterUpdate(nil)
                return
            }

            let requestedID = selectedHostID.wrappedValue
            let selectedID: HostID
            if let requestedID, hostOrder.contains(requestedID) {
                selectedID = requestedID
            } else if let requestedID,
                      let previousIndex = previousOrder.firstIndex(of: requestedID) {
                selectedID = hostOrder[min(previousIndex, hostOrder.count - 1)]
            } else {
                selectedID = hostOrder[0]
            }

            guard let row = hostOrder.firstIndex(of: selectedID) else { return }
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            if requestedID != selectedID {
                publishSelectionAfterUpdate(selectedID)
            }
        }

        private func publishSelection(_ hostID: HostID?) {
            guard selectedHostID.wrappedValue != hostID else { return }
            selectedHostID.wrappedValue = hostID
        }

        private func publishSelectionAfterUpdate(_ hostID: HostID?) {
            deferredSelectionPublication?.cancel()
            deferredSelectionPublication = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.publishSelection(hostID)
            }
        }

        private func hostID(at row: Int) -> HostID? {
            guard hostOrder.indices.contains(row) else { return nil }
            return hostOrder[row]
        }

        private func makeCell(
            tableView: NSTableView,
            tableColumn: NSTableColumn?,
            row: Int,
            hostID: HostID
        ) -> NSView {
            guard let host = hostsByID[hostID] else { return NSTableCellView() }
            let cell = tableView.makeView(
                withIdentifier: HostTableMetrics.cellIdentifier,
                owner: self
            ) as? HostTableCellView ?? HostTableCellView()
            cell.identifier = HostTableMetrics.cellIdentifier
            cell.update(
                presentation: HostBrowserPresentation(host: host),
                isSelected: tableView.selectedRow == row,
                activate: { [weak self] in self?.activate(hostID) },
                performAction: { [weak self] action in
                    guard let self, let host = self.hostsByID[hostID] else { return }
                    self.performAction(action, host)
                }
            )
            return cell
        }

        private func updateVisibleSelection(in tableView: HostTableNSView) {
            for row in 0..<tableView.numberOfRows {
                guard let cell = tableView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: false
                ) as? HostTableCellView else { continue }
                cell.updateSelection(isSelected: tableView.selectedRow == row)
            }
        }

        private func activate(_ hostID: HostID) {
            guard let host = hostsByID[hostID],
                  let action = HostBrowserPresentation(host: host).defaultAction else { return }
            performAction(action, host)
        }

        @objc
        private func activateDoubleClickedHost(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            tableView.finishPrimaryClick(
                clickCount: NSApp.currentEvent?.clickCount ?? 2,
                hostID: hostID(at: row)
            )
        }

        private func makeContextMenu(for hostID: HostID) -> NSMenu? {
            guard let host = hostsByID[hostID] else { return nil }
            let presentation = HostBrowserPresentation(host: host)
            let menu = NSMenu()
            menu.autoenablesItems = false

            for (index, group) in presentation.actionGroups.enumerated() {
                if index > 0 {
                    menu.addItem(.separator())
                }
                for action in group.actions {
                    menu.addItem(menuItem(hostID: hostID, action: action))
                }
            }
            return menu.items.isEmpty ? nil : menu
        }

        private func menuItem(
            hostID: HostID,
            action: HostBrowserActionDescriptor
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: action.title,
                action: #selector(performMenuAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = HostMenuCommand(hostID: hostID, action: action)
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            return item
        }

        @objc
        private func performMenuAction(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? HostMenuCommand,
                  let host = hostsByID[command.hostID] else { return }
            performAction(command.action, host)
        }
    }
}

@MainActor
final class HostTableNSView: NSTableView {
    var orderedHostIDs: (() -> [HostID])?
    var defaultAction: ((HostID) -> HostBrowserActionDescriptor?)?
    var activateHost: ((HostID) -> Void)?
    var contextMenu: ((HostID) -> NSMenu?)?
    var selectionDidChange: ((HostID?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76:
            guard !event.isARepeat else { return }
            performSelectedDefaultAction()
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard let hostID = hostID(at: row) else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectionDidChange?(hostID)
        return contextMenu?(hostID)
    }

    func performSelectedDefaultAction() {
        guard let hostID = hostID(at: selectedRow), defaultAction?(hostID) != nil else { return }
        activateHost?(hostID)
    }

    func finishPrimaryClick(clickCount: Int, hostID: HostID?) {
        guard clickCount == 2, let hostID, defaultAction?(hostID) != nil else { return }
        activateHost?(hostID)
    }

    func prepareContextMenu(for hostID: HostID) -> NSMenu? {
        guard let row = orderedHostIDs?().firstIndex(of: hostID) else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectionDidChange?(hostID)
        return contextMenu?(hostID)
    }

    private func hostID(at row: Int) -> HostID? {
        guard let orderedHostIDs else { return nil }
        let hostIDs = orderedHostIDs()
        guard hostIDs.indices.contains(row) else { return nil }
        return hostIDs[row]
    }
}

@MainActor
private final class HostTableCellView: NSTableCellView {
    private let hostImageView = NSImageView()
    private let statusImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var presentation: HostBrowserPresentation?
    private var activate: (() -> Void)?
    private var performAction: ((HostBrowserActionDescriptor) -> Void)?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpView()
    }

    override func accessibilityPerformPress() -> Bool {
        guard activate != nil else { return false }
        activate?()
        return true
    }

    func update(
        presentation: HostBrowserPresentation,
        isSelected: Bool,
        activate: @escaping () -> Void,
        performAction: @escaping (HostBrowserActionDescriptor) -> Void
    ) {
        self.presentation = presentation
        self.activate = presentation.defaultAction == nil ? nil : activate
        self.performAction = performAction

        hostImageView.image = NSImage(
            systemSymbolName: UmbraSymbol.host,
            accessibilityDescription: nil
        )
        statusImageView.image = NSImage(
            systemSymbolName: presentation.statusSymbol,
            accessibilityDescription: nil
        )
        nameLabel.stringValue = presentation.name
        statusLabel.stringValue = presentation.statusSummary
        updateColors()

        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityValue(presentation.accessibilityValue)
        setAccessibilityHelp(presentation.accessibilityHelp)
        setAccessibilityIdentifier("host-\(presentation.hostID.rawValue)")
        setAccessibilityCustomActions(
            presentation.actionGroups.flatMap(\.actions).map { [weak self] action in
                NSAccessibilityCustomAction(name: action.title) {
                    guard let self, self.performAction != nil else { return false }
                    self.performAction?(action)
                    return true
                }
            }
        )
        updateSelection(isSelected: isSelected)
    }

    func updateSelection(isSelected: Bool) {
        setAccessibilitySelected(isSelected)
    }

    private func setUpView() {
        hostImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: HostTableMetrics.hostSymbolSize,
            weight: .regular
        )
        hostImageView.imageScaling = .scaleProportionallyDown
        hostImageView.translatesAutoresizingMaskIntoConstraints = false
        hostImageView.setAccessibilityElement(false)

        statusImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: HostTableMetrics.statusSymbolSize,
            weight: .medium
        )
        statusImageView.imageScaling = .scaleProportionallyDown
        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.setAccessibilityElement(false)

        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.maximumNumberOfLines = 0
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setAccessibilityElement(false)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setAccessibilityElement(false)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [nameLabel, statusLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.distribution = .gravityAreas
        textStack.spacing = HostTableMetrics.textSpacing
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(hostImageView)
        addSubview(statusImageView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            hostImageView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: HostTableMetrics.horizontalInset
            ),
            hostImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            hostImageView.widthAnchor.constraint(equalToConstant: HostTableMetrics.hostImageWidth),
            hostImageView.heightAnchor.constraint(equalToConstant: HostTableMetrics.hostImageHeight),

            statusImageView.leadingAnchor.constraint(
                equalTo: hostImageView.trailingAnchor,
                constant: HostTableMetrics.iconSpacing
            ),
            statusImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImageView.widthAnchor.constraint(equalToConstant: HostTableMetrics.statusImageSize),
            statusImageView.heightAnchor.constraint(equalToConstant: HostTableMetrics.statusImageSize),

            textStack.leadingAnchor.constraint(
                equalTo: statusImageView.trailingAnchor,
                constant: HostTableMetrics.textLeadingSpacing
            ),
            textStack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: HostTableMetrics.verticalInset
            ),
            textStack.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -HostTableMetrics.verticalInset
            ),
            textStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -HostTableMetrics.horizontalInset
            ),
        ])
    }

    private func updateColors() {
        let isSelected = backgroundStyle == .emphasized
        let primaryColor: NSColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        let secondaryColor: NSColor = isSelected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        nameLabel.textColor = primaryColor
        statusLabel.textColor = secondaryColor
        hostImageView.contentTintColor = secondaryColor

        guard let presentation else {
            statusImageView.contentTintColor = secondaryColor
            return
        }
        if isSelected {
            statusImageView.contentTintColor = primaryColor
        } else {
            switch presentation.statusTone {
            case .neutral, .checking:
                statusImageView.contentTintColor = .secondaryLabelColor
            case .warning:
                statusImageView.contentTintColor = .systemOrange
            case .failure:
                statusImageView.contentTintColor = .systemRed
            }
        }
    }
}

private enum HostTableMetrics {
    static let columnIdentifier = NSUserInterfaceItemIdentifier("HostColumn")
    static let cellIdentifier = NSUserInterfaceItemIdentifier("HostCell")
    static let minimumRowHeight: CGFloat = 56
    static let horizontalInset: CGFloat = UmbraLayout.space3
    static let verticalInset: CGFloat = UmbraLayout.space2
    static let iconSpacing: CGFloat = UmbraLayout.space2
    static let textLeadingSpacing: CGFloat = UmbraLayout.space2
    static let textSpacing: CGFloat = 2
    static let hostImageWidth: CGFloat = 30
    static let hostImageHeight: CGFloat = 32
    static let hostSymbolSize: CGFloat = 24
    static let statusImageSize: CGFloat = 14
    static let statusSymbolSize: CGFloat = 9
}

private final class HostMenuCommand: NSObject {
    let hostID: HostID
    let action: HostBrowserActionDescriptor

    init(hostID: HostID, action: HostBrowserActionDescriptor) {
        self.hostID = hostID
        self.action = action
    }
}
