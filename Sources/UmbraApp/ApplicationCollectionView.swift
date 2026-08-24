import AppKit
import SwiftUI

struct ApplicationCollectionView: NSViewRepresentable {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let applications: [ApplicationDisplayModel]
    @Binding var selectedApplicationID: ApplicationID?
    @Binding var scrollPositionID: ApplicationID?
    let onActivate: (ApplicationDisplayModel) -> Void
    let onRequestQuit: (ApplicationDisplayModel) -> Void
    let onToggleDirectLaunch: (ApplicationDisplayModel) -> Void
    let onToggleHidden: (ApplicationDisplayModel) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedApplicationID: $selectedApplicationID,
            scrollPositionID: $scrollPositionID,
            showsIncreasedContrast: colorSchemeContrast == .increased,
            onActivate: onActivate,
            onRequestQuit: onRequestQuit,
            onToggleDirectLaunch: onToggleDirectLaunch,
            onToggleHidden: onToggleHidden
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let flowLayout = ApplicationCollectionFlowLayout()
        flowLayout.itemSize = ApplicationCollectionMetrics.itemSize(
            width: UmbraLayout.applicationTileWidth
        )
        flowLayout.minimumInteritemSpacing = UmbraLayout.space4
        flowLayout.minimumLineSpacing = UmbraLayout.space6
        flowLayout.sectionInset = NSEdgeInsets(
            top: UmbraLayout.space6,
            left: UmbraLayout.space6,
            bottom: UmbraLayout.space6,
            right: UmbraLayout.space6
        )
        flowLayout.scrollDirection = .vertical

        let collectionView = ApplicationCollectionNSView(frame: .zero)
        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            ApplicationCollectionItem.self,
            forItemWithIdentifier: ApplicationCollectionItem.reuseIdentifier
        )
        collectionView.setAccessibilityElement(true)
        collectionView.setAccessibilityRole(.grid)
        collectionView.setAccessibilityLabel("Applications")
        collectionView.setAccessibilityIdentifier("application-collection")

        let scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = collectionView
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.install(collectionView: collectionView, scrollView: scrollView)
        context.coordinator.apply(applications: applications)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            selectedApplicationID: $selectedApplicationID,
            scrollPositionID: $scrollPositionID,
            showsIncreasedContrast: colorSchemeContrast == .increased,
            onActivate: onActivate,
            onRequestQuit: onRequestQuit,
            onToggleDirectLaunch: onToggleDirectLaunch,
            onToggleHidden: onToggleHidden
        )
        context.coordinator.apply(applications: applications)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate {
        private enum Section: Hashable {
            case applications
        }

        private var selectedApplicationID: Binding<ApplicationID?>
        private var scrollPositionID: Binding<ApplicationID?>
        private var showsIncreasedContrast: Bool
        private var onActivate: (ApplicationDisplayModel) -> Void
        private var onRequestQuit: (ApplicationDisplayModel) -> Void
        private var onToggleDirectLaunch: (ApplicationDisplayModel) -> Void
        private var onToggleHidden: (ApplicationDisplayModel) -> Void
        private weak var collectionView: ApplicationCollectionNSView?
        private var dataSource: NSCollectionViewDiffableDataSource<Section, ApplicationID>?
        private var applicationsByID: [ApplicationID: ApplicationDisplayModel] = [:]
        private var applicationOrder: [ApplicationID] = []
        private var lastAppliedScrollPositionID: ApplicationID?
        private var isApplyingState = false
        private var deferredScrollRestoration: Task<Void, Never>?
        private var deferredSelectionPublication: Task<Void, Never>?

        init(
            selectedApplicationID: Binding<ApplicationID?>,
            scrollPositionID: Binding<ApplicationID?>,
            showsIncreasedContrast: Bool,
            onActivate: @escaping (ApplicationDisplayModel) -> Void,
            onRequestQuit: @escaping (ApplicationDisplayModel) -> Void,
            onToggleDirectLaunch: @escaping (ApplicationDisplayModel) -> Void,
            onToggleHidden: @escaping (ApplicationDisplayModel) -> Void
        ) {
            self.selectedApplicationID = selectedApplicationID
            self.scrollPositionID = scrollPositionID
            self.showsIncreasedContrast = showsIncreasedContrast
            self.onActivate = onActivate
            self.onRequestQuit = onRequestQuit
            self.onToggleDirectLaunch = onToggleDirectLaunch
            self.onToggleHidden = onToggleHidden
        }

        func update(
            selectedApplicationID: Binding<ApplicationID?>,
            scrollPositionID: Binding<ApplicationID?>,
            showsIncreasedContrast: Bool,
            onActivate: @escaping (ApplicationDisplayModel) -> Void,
            onRequestQuit: @escaping (ApplicationDisplayModel) -> Void,
            onToggleDirectLaunch: @escaping (ApplicationDisplayModel) -> Void,
            onToggleHidden: @escaping (ApplicationDisplayModel) -> Void
        ) {
            self.selectedApplicationID = selectedApplicationID
            self.scrollPositionID = scrollPositionID
            self.showsIncreasedContrast = showsIncreasedContrast
            self.onActivate = onActivate
            self.onRequestQuit = onRequestQuit
            self.onToggleDirectLaunch = onToggleDirectLaunch
            self.onToggleHidden = onToggleHidden
        }

        func install(collectionView: ApplicationCollectionNSView, scrollView: NSScrollView) {
            self.collectionView = collectionView
            collectionView.delegate = self
            collectionView.orderedApplicationIDs = { [weak self] in self?.applicationOrder ?? [] }
            collectionView.applicationName = { [weak self] id in self?.applicationsByID[id]?.name }
            collectionView.activateApplication = { [weak self] id in self?.activate(id) }
            collectionView.contextMenu = { [weak self] id in self?.makeContextMenu(for: id) }
            collectionView.selectionDidChange = { [weak self] id in self?.publishSelection(id) }
            collectionView.visualStateDidChange = { [weak self] in self?.updateVisibleItems() }

            dataSource = NSCollectionViewDiffableDataSource<Section, ApplicationID>(
                collectionView: collectionView
            ) { [weak self] collectionView, indexPath, applicationID in
                guard let self,
                      let item = collectionView.makeItem(
                          withIdentifier: ApplicationCollectionItem.reuseIdentifier,
                          for: indexPath
                      ) as? ApplicationCollectionItem else { return nil }
                configure(item, applicationID: applicationID)
                return item
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        func uninstall() {
            NotificationCenter.default.removeObserver(self)
            deferredScrollRestoration?.cancel()
            deferredSelectionPublication?.cancel()
            collectionView?.delegate = nil
            collectionView?.orderedApplicationIDs = nil
            collectionView?.applicationName = nil
            collectionView?.activateApplication = nil
            collectionView?.contextMenu = nil
            collectionView?.selectionDidChange = nil
            collectionView?.visualStateDidChange = nil
            dataSource = nil
        }

        func apply(applications: [ApplicationDisplayModel]) {
            guard let collectionView, let dataSource else { return }

            let previousApplications = applicationsByID
            let previousOrder = applicationOrder
            applicationsByID = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
            applicationOrder = applications.map(\.id)

            var snapshot = NSDiffableDataSourceSnapshot<Section, ApplicationID>()
            snapshot.appendSections([.applications])
            snapshot.appendItems(applicationOrder, toSection: .applications)

            let existingIDs = Set(dataSource.snapshot().itemIdentifiers)
            let changedIDs = applications.compactMap { application -> ApplicationID? in
                guard existingIDs.contains(application.id),
                      previousApplications[application.id] != application else { return nil }
                return application.id
            }
            if !changedIDs.isEmpty {
                snapshot.reloadItems(changedIDs)
            }

            isApplyingState = true
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.layoutSubtreeIfNeeded()
            restoreSelection(in: collectionView)

            let requestedScrollID = scrollPositionID.wrappedValue
            if requestedScrollID != lastAppliedScrollPositionID || previousOrder != applicationOrder {
                restoreScrollPosition(requestedScrollID, in: collectionView)
            }
            isApplyingState = false
            updateVisibleItems()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didSelectItemsAt indexPaths: Set<IndexPath>
        ) {
            publishSelectionFromCollection()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didDeselectItemsAt indexPaths: Set<IndexPath>
        ) {
            publishSelectionFromCollection()
        }

        private func restoreSelection(in collectionView: ApplicationCollectionNSView) {
            let requestedID = selectedApplicationID.wrappedValue
            let selectedID = requestedID.flatMap { applicationOrder.contains($0) ? $0 : nil }
                ?? applicationOrder.first

            guard let selectedID,
                  let index = applicationOrder.firstIndex(of: selectedID) else {
                collectionView.deselectAll(nil)
                if requestedID != nil { publishSelectionAfterUpdate(nil) }
                return
            }

            let indexPath = IndexPath(item: index, section: 0)
            if collectionView.selectionIndexPaths != [indexPath] {
                collectionView.selectionIndexPaths = [indexPath]
            }
            if requestedID != selectedID {
                publishSelectionAfterUpdate(selectedID)
            }
        }

        private func restoreScrollPosition(
            _ applicationID: ApplicationID?,
            in collectionView: ApplicationCollectionNSView
        ) {
            lastAppliedScrollPositionID = applicationID
            guard let applicationID,
                  let index = applicationOrder.firstIndex(of: applicationID) else { return }
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.scrollToItems(at: [indexPath], scrollPosition: [.top, .nearestHorizontalEdge])

            deferredScrollRestoration?.cancel()
            deferredScrollRestoration = Task { @MainActor [weak self, weak collectionView] in
                await Task.yield()
                guard !Task.isCancelled, let self, let collectionView else { return }
                collectionView.layoutSubtreeIfNeeded()
                isApplyingState = true
                collectionView.scrollToItems(
                    at: [indexPath],
                    scrollPosition: [.top, .nearestHorizontalEdge]
                )
                isApplyingState = false
            }
        }

        private func publishSelectionFromCollection() {
            guard let collectionView else { return }
            let selectedID = collectionView.selectionIndexPaths
                .sorted(by: ApplicationCollectionView.indexPathOrder)
                .first
                .flatMap { dataSource?.itemIdentifier(for: $0) }
            publishSelection(selectedID)
            updateVisibleItems()
        }

        private func publishSelection(_ applicationID: ApplicationID?) {
            guard selectedApplicationID.wrappedValue != applicationID else { return }
            selectedApplicationID.wrappedValue = applicationID
        }

        private func publishSelectionAfterUpdate(_ applicationID: ApplicationID?) {
            deferredSelectionPublication?.cancel()
            deferredSelectionPublication = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.publishSelection(applicationID)
            }
        }

        private func publishScrollPosition(_ applicationID: ApplicationID?) {
            lastAppliedScrollPositionID = applicationID
            guard scrollPositionID.wrappedValue != applicationID else { return }
            scrollPositionID.wrappedValue = applicationID
        }

        @objc
        private func scrollBoundsDidChange(_ notification: Notification) {
            guard !isApplyingState,
                  let collectionView,
                  !collectionView.visibleItems().isEmpty else { return }
            let topVisibleID = collectionView.visibleItems()
                .compactMap { item -> (ApplicationID, CGFloat)? in
                    guard let indexPath = collectionView.indexPath(for: item),
                          let applicationID = dataSource?.itemIdentifier(for: indexPath) else { return nil }
                    return (applicationID, item.view.frame.minY)
                }
                .min { lhs, rhs in lhs.1 < rhs.1 }?
                .0
            publishScrollPosition(topVisibleID)
        }

        private func activate(_ applicationID: ApplicationID) {
            guard let application = applicationsByID[applicationID] else { return }
            onActivate(application)
        }

        private func configure(
            _ item: ApplicationCollectionItem,
            applicationID: ApplicationID
        ) {
            guard let application = applicationsByID[applicationID],
                  let collectionView else { return }
            item.update(
                application: application,
                showsFocusRing: collectionView.showsKeyboardFocus(for: applicationID),
                showsIncreasedContrast: showsIncreasedContrast,
                isPressed: collectionView.pressedApplicationID == applicationID,
                onPerformAction: { [weak self] kind in
                    self?.perform(kind, for: applicationID)
                }
            )
        }

        private func updateVisibleItems() {
            guard let collectionView else { return }
            for case let item as ApplicationCollectionItem in collectionView.visibleItems() {
                guard let indexPath = collectionView.indexPath(for: item),
                      let applicationID = dataSource?.itemIdentifier(for: indexPath) else { continue }
                configure(item, applicationID: applicationID)
            }
        }

        private func makeContextMenu(for applicationID: ApplicationID) -> NSMenu? {
            guard let application = applicationsByID[applicationID] else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (groupIndex, group) in ApplicationActionDescriptor.contextGroups(for: application).enumerated() {
                if groupIndex > 0 { menu.addItem(.separator()) }
                for action in group {
                    let item = menuItem(
                        descriptor: action,
                        applicationID: applicationID
                    )
                    item.state = action.state
                    item.isEnabled = action.isEnabled
                    menu.addItem(item)
                }
            }
            return menu
        }

        private func menuItem(
            descriptor: ApplicationActionDescriptor,
            applicationID: ApplicationID
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: descriptor.title,
                action: #selector(performMenuCommand(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ApplicationMenuCommand(
                kind: descriptor.kind,
                applicationID: applicationID
            )
            item.image = NSImage(
                systemSymbolName: descriptor.symbol,
                accessibilityDescription: nil
            )
            return item
        }

        @objc
        private func performMenuCommand(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? ApplicationMenuCommand,
                  applicationsByID[command.applicationID] != nil else { return }
            perform(command.kind, for: command.applicationID)
        }

        private func perform(
            _ kind: ApplicationActionDescriptor.Kind,
            for applicationID: ApplicationID
        ) {
            guard let application = applicationsByID[applicationID] else { return }
            switch kind {
            case .activate:
                onActivate(application)
            case .quit:
                guard application.isRunning else { return }
                onRequestQuit(application)
            case .toggleDirectLaunch:
                guard !application.isHidden else { return }
                onToggleDirectLaunch(application)
            case .toggleHidden:
                guard application.isHidden || (!application.isRunning && !application.isDirectLaunch)
                else { return }
                onToggleHidden(application)
            }
        }
    }

    fileprivate static func indexPathOrder(_ lhs: IndexPath, _ rhs: IndexPath) -> Bool {
        if lhs.section != rhs.section { return lhs.section < rhs.section }
        return lhs.item < rhs.item
    }
}

@MainActor
final class ApplicationCollectionNSView: NSCollectionView {
    enum InputModality {
        case pointer
        case keyboard
    }

    var orderedApplicationIDs: (() -> [ApplicationID])?
    var applicationName: ((ApplicationID) -> String?)?
    var activateApplication: ((ApplicationID) -> Void)?
    var contextMenu: ((ApplicationID) -> NSMenu?)?
    var selectionDidChange: ((ApplicationID?) -> Void)?
    var visualStateDidChange: (() -> Void)?
    private(set) var pressedApplicationID: ApplicationID?
    private(set) var inputModality: InputModality = .pointer
    private var typeaheadBuffer = ""
    private var lastTypeaheadTimestamp: TimeInterval = 0
    private weak var observedWindow: NSWindow?

    override var acceptsFirstResponder: Bool { true }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            if NSApp.currentEvent?.type == .keyDown {
                inputModality = .keyboard
            }
            visualStateDidChange?()
        }
        return becameFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: observedWindow
            )
        }
        observedWindow = window
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowKeyStateDidChange(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowKeyStateDidChange(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
        visualStateDidChange?()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            pressedApplicationID = nil
            visualStateDidChange?()
        }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        inputModality = .pointer
        resetTypeahead()
        let applicationID = applicationID(at: event.locationInWindow)
        beginPrimaryPress(applicationID: applicationID)
        defer { endPrimaryPress() }
        super.mouseDown(with: event)
        finishPrimaryClick(clickCount: event.clickCount, applicationID: applicationID)
    }

    override func rightMouseDown(with event: NSEvent) {
        inputModality = .pointer
        resetTypeahead()
        visualStateDidChange?()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        inputModality = .pointer
        resetTypeahead()
        visualStateDidChange?()
        super.otherMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        inputModality = .keyboard
        visualStateDidChange?()

        switch event.keyCode {
        case 36, 49, 76:
            resetTypeahead()
            guard !event.isARepeat else { return }
            guard let applicationID = selectedApplicationID else { return }
            beginPrimaryPress(applicationID: applicationID)
            activateApplication?(applicationID)
        case 115:
            resetTypeahead()
            selectBoundaryApplication(first: true)
        case 119:
            resetTypeahead()
            selectBoundaryApplication(first: false)
        case 123:
            resetTypeahead()
            selectAdjacentApplication(direction: .left)
        case 124:
            resetTypeahead()
            selectAdjacentApplication(direction: .right)
        case 125:
            resetTypeahead()
            selectAdjacentApplication(direction: .down)
        case 126:
            resetTypeahead()
            selectAdjacentApplication(direction: .up)
        default:
            if performTypeahead(with: event) { return }
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) {
            endPrimaryPress()
            return
        }
        super.keyUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        inputModality = .pointer
        guard let applicationID = applicationID(at: event.locationInWindow) else { return nil }
        return prepareContextMenu(for: applicationID)
    }

    func finishPrimaryClick(clickCount: Int, applicationID: ApplicationID?) {
        guard clickCount == 2, let applicationID else { return }
        activateApplication?(applicationID)
    }

    func beginPrimaryPress(applicationID: ApplicationID?) {
        pressedApplicationID = applicationID
        visualStateDidChange?()
        displayIfNeeded()
    }

    func endPrimaryPress() {
        guard pressedApplicationID != nil else { return }
        pressedApplicationID = nil
        visualStateDidChange?()
        displayIfNeeded()
    }

    func prepareContextMenu(for applicationID: ApplicationID) -> NSMenu? {
        inputModality = .pointer
        select(applicationID, scrollPosition: [])
        visualStateDidChange?()
        return contextMenu?(applicationID)
    }

    func showsKeyboardFocus(for applicationID: ApplicationID) -> Bool {
        inputModality == .keyboard
            && window?.isKeyWindow == true
            && window?.firstResponder === self
            && selectedApplicationID == applicationID
    }

    @discardableResult
    func performTypeahead(text: String, timestamp: TimeInterval) -> Bool {
        let normalizedText = text.trimmingCharacters(in: .controlCharacters)
        guard normalizedText.count == 1,
              normalizedText.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace }) else { return false }

        let interval = timestamp - lastTypeaheadTimestamp
        let startsNewSearch = interval < 0 || interval > ApplicationCollectionMetrics.typeaheadInterval
        let repeatedSingleCharacter = !startsNewSearch
            && typeaheadBuffer.count == 1
            && typeaheadBuffer.localizedCaseInsensitiveCompare(normalizedText) == .orderedSame

        if startsNewSearch {
            typeaheadBuffer = normalizedText
        } else if !repeatedSingleCharacter {
            typeaheadBuffer.append(normalizedText)
        }
        lastTypeaheadTimestamp = timestamp

        guard let applicationID = matchingApplicationID(
            query: typeaheadBuffer,
            includeCurrentFirst: typeaheadBuffer.count > 1
        ) else {
            guard typeaheadBuffer.count > 1 else { return true }
            typeaheadBuffer = normalizedText
            guard let fallbackID = matchingApplicationID(
                query: normalizedText,
                includeCurrentFirst: false
            ) else { return true }
            select(fallbackID, scrollPosition: [.nearestVerticalEdge, .nearestHorizontalEdge])
            return true
        }
        select(applicationID, scrollPosition: [.nearestVerticalEdge, .nearestHorizontalEdge])
        return true
    }

    @objc
    private func windowKeyStateDidChange(_ notification: Notification) {
        visualStateDidChange?()
    }

    private func resetTypeahead() {
        typeaheadBuffer = ""
        lastTypeaheadTimestamp = 0
    }

    private var selectedApplicationID: ApplicationID? {
        guard let orderedApplicationIDs else { return nil }
        return selectionIndexPaths
            .sorted(by: ApplicationCollectionView.indexPathOrder)
            .first
            .flatMap { indexPath in
                let identifiers = orderedApplicationIDs()
                guard identifiers.indices.contains(indexPath.item) else { return nil }
                return identifiers[indexPath.item]
            }
    }

    private func performTypeahead(with event: NSEvent) -> Bool {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty,
              let characters = event.charactersIgnoringModifiers else { return false }
        return performTypeahead(text: characters, timestamp: event.timestamp)
    }

    private func matchingApplicationID(
        query: String,
        includeCurrentFirst: Bool
    ) -> ApplicationID? {
        guard let orderedApplicationIDs, let applicationName else { return nil }
        let identifiers = orderedApplicationIDs()
        guard !identifiers.isEmpty else { return nil }

        let selectedIndex = selectedApplicationID.flatMap { identifiers.firstIndex(of: $0) }
        let startIndex: Int
        if includeCurrentFirst, let selectedIndex {
            startIndex = selectedIndex
        } else if let selectedIndex {
            startIndex = (selectedIndex + 1) % identifiers.count
        } else {
            startIndex = 0
        }

        for offset in identifiers.indices {
            let index = (startIndex + offset) % identifiers.count
            let applicationID = identifiers[index]
            guard let name = applicationName(applicationID) else { continue }
            if name.range(
                of: query,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) != nil {
                return applicationID
            }
        }
        return nil
    }

    private func selectBoundaryApplication(first: Bool) {
        guard let orderedApplicationIDs else { return }
        let identifiers = orderedApplicationIDs()
        guard let applicationID = first ? identifiers.first : identifiers.last else { return }
        select(
            applicationID,
            scrollPosition: first ? [.top, .nearestHorizontalEdge] : [.bottom, .nearestHorizontalEdge]
        )
    }

    private func selectAdjacentApplication(direction: SpatialDirection) {
        guard let orderedApplicationIDs,
              let selectedIndexPath = selectionIndexPaths.first,
              let selectedAttributes = collectionViewLayout?.layoutAttributesForItem(at: selectedIndexPath) else {
            return
        }

        let identifiers = orderedApplicationIDs()
        let candidates = identifiers.indices.compactMap { itemIndex -> (IndexPath, NSCollectionViewLayoutAttributes)? in
            let indexPath = IndexPath(item: itemIndex, section: 0)
            guard indexPath != selectedIndexPath,
                  let attributes = collectionViewLayout?.layoutAttributesForItem(at: indexPath),
                  direction.includes(
                      candidateFrame: attributes.frame,
                      from: selectedAttributes.frame
                  ) else { return nil }
            return (indexPath, attributes)
        }

        guard let destination = candidates.min(by: { lhs, rhs in
            direction.score(
                candidateFrame: lhs.1.frame,
                from: selectedAttributes.frame
            ) < direction.score(
                candidateFrame: rhs.1.frame,
                from: selectedAttributes.frame
            )
        }), identifiers.indices.contains(destination.0.item) else { return }

        select(
            identifiers[destination.0.item],
            scrollPosition: [.nearestVerticalEdge, .nearestHorizontalEdge]
        )
    }

    private func select(
        _ applicationID: ApplicationID,
        scrollPosition: NSCollectionView.ScrollPosition
    ) {
        guard let orderedApplicationIDs,
              let index = orderedApplicationIDs().firstIndex(of: applicationID) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        selectionIndexPaths = [indexPath]
        if !scrollPosition.isEmpty {
            scrollToItems(at: [indexPath], scrollPosition: scrollPosition)
        }
        selectionDidChange?(applicationID)
        visualStateDidChange?()
    }

    private func applicationID(at windowPoint: NSPoint) -> ApplicationID? {
        let point = convert(windowPoint, from: nil)
        guard let indexPath = indexPathForItem(at: point),
              let orderedApplicationIDs else { return nil }
        let identifiers = orderedApplicationIDs()
        guard identifiers.indices.contains(indexPath.item) else { return nil }
        return identifiers[indexPath.item]
    }
}

private enum SpatialDirection {
    case left
    case right
    case up
    case down

    func includes(candidateFrame: NSRect, from selectedFrame: NSRect) -> Bool {
        let rowTolerance = min(candidateFrame.height, selectedFrame.height) * 0.25
        switch self {
        case .left:
            return candidateFrame.midX < selectedFrame.midX
                && abs(candidateFrame.midY - selectedFrame.midY) <= rowTolerance
        case .right:
            return candidateFrame.midX > selectedFrame.midX
                && abs(candidateFrame.midY - selectedFrame.midY) <= rowTolerance
        case .up:
            return candidateFrame.midY < selectedFrame.midY
        case .down:
            return candidateFrame.midY > selectedFrame.midY
        }
    }

    func score(candidateFrame: NSRect, from selectedFrame: NSRect) -> SpatialNavigationScore {
        switch self {
        case .left, .right:
            SpatialNavigationScore(
                primaryDistance: abs(candidateFrame.midX - selectedFrame.midX),
                crossAxisDistance: abs(candidateFrame.midY - selectedFrame.midY)
            )
        case .up, .down:
            SpatialNavigationScore(
                primaryDistance: abs(candidateFrame.midY - selectedFrame.midY),
                crossAxisDistance: abs(candidateFrame.midX - selectedFrame.midX)
            )
        }
    }
}

private struct SpatialNavigationScore: Comparable {
    let primaryDistance: CGFloat
    let crossAxisDistance: CGFloat

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.primaryDistance != rhs.primaryDistance {
            return lhs.primaryDistance < rhs.primaryDistance
        }
        return lhs.crossAxisDistance < rhs.crossAxisDistance
    }
}

@MainActor
final class ApplicationCollectionFlowLayout: NSCollectionViewFlowLayout {
    override func prepare() {
        guard let collectionView, collectionView.bounds.width > 0 else {
            super.prepare()
            return
        }

        let baseInset = UmbraLayout.space6
        let spacing = UmbraLayout.space4
        let availableWidth = max(
            UmbraLayout.applicationTileWidth,
            collectionView.bounds.width - (baseInset * 2)
        )
        let columnCount = max(
            1,
            Int((availableWidth + spacing) / (UmbraLayout.applicationTileWidth + spacing))
        )
        let unconstrainedWidth = (
            availableWidth - (CGFloat(columnCount - 1) * spacing)
        ) / CGFloat(columnCount)
        let itemWidth = min(UmbraLayout.applicationTileWidth, unconstrainedWidth)
        let usedWidth = (CGFloat(columnCount) * itemWidth) + (CGFloat(columnCount - 1) * spacing)
        let extraSideInset = max(0, (availableWidth - usedWidth) / 2)

        sectionInset = NSEdgeInsets(
            top: baseInset,
            left: baseInset + extraSideInset,
            bottom: baseInset,
            right: baseInset + extraSideInset
        )
        itemSize = ApplicationCollectionMetrics.itemSize(width: itemWidth)
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return super.shouldInvalidateLayout(forBoundsChange: newBounds) }
        return collectionView.bounds.width != newBounds.width
            || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

@MainActor
final class ApplicationCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ApplicationCollectionItem")

    private var application: ApplicationDisplayModel?
    private var showsFocusRing = false
    private var showsIncreasedContrast = false
    private var isPressed = false
    private var onPerformAction: ((ApplicationActionDescriptor.Kind) -> Void)?

    override var isSelected: Bool {
        didSet { render() }
    }

    override func loadView() {
        view = ApplicationCollectionItemView(frame: .zero)
    }

    func update(
        application: ApplicationDisplayModel,
        showsFocusRing: Bool,
        showsIncreasedContrast: Bool = false,
        isPressed: Bool,
        onActivate: @escaping () -> Void
    ) {
        update(
            application: application,
            showsFocusRing: showsFocusRing,
            showsIncreasedContrast: showsIncreasedContrast,
            isPressed: isPressed,
            onPerformAction: { kind in
                guard kind == .activate else { return }
                onActivate()
            }
        )
    }

    fileprivate func update(
        application: ApplicationDisplayModel,
        showsFocusRing: Bool,
        showsIncreasedContrast: Bool,
        isPressed: Bool,
        onPerformAction: @escaping (ApplicationActionDescriptor.Kind) -> Void
    ) {
        self.application = application
        self.showsFocusRing = showsFocusRing
        self.showsIncreasedContrast = showsIncreasedContrast
        self.isPressed = isPressed
        self.onPerformAction = onPerformAction
        render()
    }

    private func render() {
        guard let application,
              let itemView = view as? ApplicationCollectionItemView else { return }
        itemView.update(
            content: ApplicationTileContent(
                application: application,
                isSelected: isSelected,
                showsFocusRing: showsFocusRing,
                showsIncreasedContrast: showsIncreasedContrast,
                isPressed: isPressed
            ),
            application: application,
            isSelected: isSelected,
            onPerformAction: onPerformAction
        )
    }
}

@MainActor
private final class ApplicationCollectionItemView: NSView {
    private var hostingView: NSHostingView<ApplicationTileContent>?
    private var onPerformAction: ((ApplicationActionDescriptor.Kind) -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let onPerformAction else { return false }
        onPerformAction(.activate)
        return true
    }

    func update(
        content: ApplicationTileContent,
        application: ApplicationDisplayModel,
        isSelected: Bool,
        onPerformAction: ((ApplicationActionDescriptor.Kind) -> Void)?
    ) {
        self.onPerformAction = onPerformAction
        if let hostingView {
            hostingView.rootView = content
        } else {
            let hostingView = NSHostingView(rootView: content)
            hostingView.frame = bounds
            hostingView.autoresizingMask = [.width, .height]
            hostingView.setAccessibilityElement(false)
            addSubview(hostingView)
            self.hostingView = hostingView
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityLabel(application.name)
        setAccessibilityHelp(
            application.isRunning
                ? "Press to resume \(application.name)."
                : "Press to launch \(application.name)."
        )
        setAccessibilityIdentifier("application-\(application.id.rawValue)")
        setAccessibilitySelected(isSelected)
        let values = [
            isSelected ? "Selected" : nil,
            application.isRunning ? "Running" : nil,
            application.isDirectLaunch ? "Direct Launch enabled" : nil,
            application.isHidden ? "Hidden" : nil,
        ].compactMap { $0 }
        setAccessibilityValue(values.isEmpty ? nil : values.joined(separator: ", "))
        let actionHandler = onPerformAction
        setAccessibilityCustomActions(
            ApplicationActionDescriptor.contextGroups(for: application)
                .flatMap { $0 }
                .filter(\.isEnabled)
                .map { action in
                    NSAccessibilityCustomAction(name: action.title) {
                        guard let actionHandler else { return false }
                        actionHandler(action.kind)
                        return true
                    }
                }
        )
    }
}

private struct ApplicationTileContent: View {
    let application: ApplicationDisplayModel
    let isSelected: Bool
    let showsFocusRing: Bool
    let showsIncreasedContrast: Bool
    let isPressed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraLayout.space2) {
            ApplicationArtwork(application: application)
                .aspectRatio(UmbraLayout.artworkAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(
                    cornerRadius: UmbraLayout.cornerSmall,
                    style: .continuous
                ))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: UmbraLayout.cornerSmall,
                        style: .continuous
                    )
                        .stroke(
                            isSelected ? Color.accentColor : .clear,
                            lineWidth: showsIncreasedContrast ? 3 : 2
                        )
                }
                .opacity(application.isHidden ? 0.5 : 1)

            HStack(alignment: .firstTextBaseline, spacing: UmbraLayout.space2) {
                Text(application.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if application.isDirectLaunch {
                    Image(systemName: UmbraSymbol.directLaunch)
                        .foregroundStyle(.secondary)
                        .help("Direct Launch")
                }
                if application.isHidden {
                    Image(systemName: UmbraSymbol.hidden)
                        .foregroundStyle(.secondary)
                        .help("Hidden app")
                }
                if application.isRunning {
                    Image(systemName: UmbraSymbol.running)
                        .foregroundStyle(.secondary)
                        .help("Running")
                }
            }
        }
        .padding(UmbraLayout.space2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(
                cornerRadius: UmbraLayout.cornerMedium,
                style: .continuous
            )
                .fill(isPressed ? Color.accentColor.opacity(0.12) : .clear)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: UmbraLayout.cornerMedium,
                style: .continuous
            )
                .stroke(
                    showsFocusRing ? Color(nsColor: .keyboardFocusIndicatorColor) : .clear,
                    lineWidth: showsIncreasedContrast ? 3 : 2
                )
        }
        .accessibilityHidden(true)
    }
}

struct ApplicationArtwork: View {
    let application: ApplicationDisplayModel

    var body: some View {
        if let url = application.artworkURL {
            if url.isFileURL {
                FileArtworkImage(url: url)
                    .id(url)
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ArtworkPlaceholder()
                    case .failure:
                        ArtworkPlaceholder()
                    @unknown default:
                        ArtworkPlaceholder()
                    }
                }
            }
        } else {
            ArtworkPlaceholder()
        }
    }
}

private struct FileArtworkImage: View {
    let url: URL
    @State private var image: NSImage?
    @State private var loadFailed = false

    init(url: URL) {
        self.url = url
        _image = State(initialValue: FileArtworkImageCache.shared.image(for: url))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if loadFailed {
                ArtworkPlaceholder()
            } else {
                ArtworkPlaceholder()
            }
        }
        .task(id: url) {
            if let cached = FileArtworkImageCache.shared.image(for: url) {
                image = cached
                loadFailed = false
                return
            }
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled else { return }
            guard let data, let decoded = NSImage(data: data) else {
                loadFailed = true
                return
            }
            FileArtworkImageCache.shared.insert(decoded, for: url)
            image = decoded
            loadFailed = false
        }
    }
}

@MainActor
final class FileArtworkImageCache {
    static let shared = FileArtworkImageCache()
    private let storage = NSCache<NSURL, NSImage>()

    private init() {
        storage.countLimit = 256
    }

    func image(for url: URL) -> NSImage? {
        storage.object(forKey: url as NSURL)
    }

    func insert(_ image: NSImage, for url: URL) {
        storage.setObject(image, forKey: url as NSURL)
    }
}

private struct ArtworkPlaceholder: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: UmbraSymbol.application)
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }
}

private enum ApplicationCollectionMetrics {
    static let typeaheadInterval: TimeInterval = 0.7

    static func itemSize(width: CGFloat) -> NSSize {
        let tileHeight = ceil(
            ((width - UmbraLayout.space4) / UmbraLayout.artworkAspectRatio)
                + UmbraLayout.space2
                + 36
                + UmbraLayout.space4
        )
        return NSSize(width: width, height: tileHeight)
    }
}

private final class ApplicationMenuCommand: NSObject {
    let kind: ApplicationActionDescriptor.Kind
    let applicationID: ApplicationID

    init(kind: ApplicationActionDescriptor.Kind, applicationID: ApplicationID) {
        self.kind = kind
        self.applicationID = applicationID
    }
}

private struct ApplicationActionDescriptor {
    enum Kind {
        case activate
        case toggleDirectLaunch
        case toggleHidden
        case quit
    }

    let kind: Kind
    let title: String
    let symbol: String
    let isEnabled: Bool
    let state: NSControl.StateValue

    static func contextGroups(
        for application: ApplicationDisplayModel
    ) -> [[ApplicationActionDescriptor]] {
        let activation = ApplicationActionDescriptor(
            kind: .activate,
            title: "\(application.isRunning ? "Resume" : "Launch") \(application.name)",
            symbol: application.isRunning ? UmbraSymbol.resume : UmbraSymbol.launch,
            isEnabled: true,
            state: .off
        )
        let organization = [
            ApplicationActionDescriptor(
                kind: .toggleDirectLaunch,
                title: "Direct Launch",
                symbol: UmbraSymbol.directLaunch,
                isEnabled: !application.isHidden,
                state: application.isDirectLaunch ? .on : .off
            ),
            ApplicationActionDescriptor(
                kind: .toggleHidden,
                title: "Hide App",
                symbol: UmbraSymbol.hidden,
                isEnabled: application.isHidden
                    || (!application.isRunning && !application.isDirectLaunch),
                state: application.isHidden ? .on : .off
            ),
        ]
        guard application.isRunning else { return [[activation], organization] }
        return [
            [activation],
            organization,
            [ApplicationActionDescriptor(
                kind: .quit,
                title: "Quit \(application.name)...",
                symbol: UmbraSymbol.quit,
                isEnabled: true,
                state: .off
            )],
        ]
    }
}
