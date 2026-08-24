import AppKit
import XCTest
@testable import UmbraApp

@MainActor
final class ApplicationGridNavigationTests: XCTestCase {
    func testTypeaheadUsesLocalizedPrefixMatchingAndCyclesRepeatedCharacters() {
        let fixture = makeCollection(names: ["Alpha", "Beta", "Bravo", "Café"])
        fixture.collectionView.selectItems(
            at: [IndexPath(item: 0, section: 0)],
            scrollPosition: []
        )

        XCTAssertTrue(fixture.collectionView.performTypeahead(text: "b", timestamp: 1.0))
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 1, section: 0)])

        XCTAssertTrue(fixture.collectionView.performTypeahead(text: "b", timestamp: 1.1))
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 2, section: 0)])

        XCTAssertTrue(fixture.collectionView.performTypeahead(text: "r", timestamp: 1.2))
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 2, section: 0)])

        XCTAssertTrue(fixture.collectionView.performTypeahead(text: "c", timestamp: 2.0))
        XCTAssertTrue(fixture.collectionView.performTypeahead(text: "a", timestamp: 2.1))
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 3, section: 0)])

        XCTAssertTrue(fixture.collectionView.performTypeahead(text: "z", timestamp: 3.0))
        XCTAssertTrue(fixture.collectionView.performTypeahead(text: "a", timestamp: 3.1))
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 0, section: 0)])
    }

    func testHomeAndEndSelectNativeCollectionBoundaries() throws {
        let fixture = makeCollection(names: ["Alpha", "Beta", "Gamma"])
        fixture.collectionView.selectItems(
            at: [IndexPath(item: 1, section: 0)],
            scrollPosition: []
        )

        fixture.collectionView.keyDown(with: try keyEvent(keyCode: 119))
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 2, section: 0)])

        fixture.collectionView.keyDown(with: try keyEvent(keyCode: 115))
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 0, section: 0)])
    }

    func testArrowKeysFollowTheNativeLayoutGeometry() throws {
        let fixture = makeCollection(names: ["One", "Two", "Three", "Four", "Five", "Six"])
        fixture.collectionView.selectItems(
            at: [IndexPath(item: 0, section: 0)],
            scrollPosition: []
        )

        fixture.collectionView.keyDown(with: try keyEvent(keyCode: 124))
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 1, section: 0)])

        fixture.collectionView.keyDown(with: try keyEvent(keyCode: 125))
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 4, section: 0)])

        fixture.collectionView.keyDown(with: try keyEvent(keyCode: 123))
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 3, section: 0)])

        fixture.collectionView.keyDown(with: try keyEvent(keyCode: 126))
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 0, section: 0)])
    }

    func testReturnSpaceAndDoubleClickActivateExactlyOncePerGesture() throws {
        let fixture = makeCollection(names: ["Alpha"])
        fixture.collectionView.selectItems(
            at: [IndexPath(item: 0, section: 0)],
            scrollPosition: []
        )
        var activations: [ApplicationID] = []
        fixture.collectionView.activateApplication = { activations.append($0) }

        fixture.collectionView.keyDown(with: try keyEvent(keyCode: 36, characters: "\r"))
        fixture.collectionView.keyDown(with: try keyEvent(keyCode: 36, characters: "\r", isARepeat: true))
        fixture.collectionView.keyUp(with: try keyEvent(type: .keyUp, keyCode: 36, characters: "\r"))
        XCTAssertEqual(activations, [fixture.ids[0]])

        fixture.collectionView.keyDown(with: try keyEvent(keyCode: 49, characters: " "))
        fixture.collectionView.keyUp(with: try keyEvent(type: .keyUp, keyCode: 49, characters: " "))
        XCTAssertEqual(activations, [fixture.ids[0], fixture.ids[0]])

        fixture.collectionView.finishPrimaryClick(clickCount: 1, applicationID: fixture.ids[0])
        fixture.collectionView.finishPrimaryClick(clickCount: 2, applicationID: fixture.ids[0])
        fixture.collectionView.finishPrimaryClick(clickCount: 3, applicationID: fixture.ids[0])
        XCTAssertEqual(activations, [fixture.ids[0], fixture.ids[0], fixture.ids[0]])
    }

    func testHeldPressKeepsCollectionAndItemGeometryStableUntilRelease() {
        let fixture = makeCollection(names: ["Alpha"])
        let indexPath = IndexPath(item: 0, section: 0)
        let collectionFrame = fixture.collectionView.frame
        let itemFrame = fixture.collectionView.item(at: indexPath)?.view.frame

        fixture.collectionView.beginPrimaryPress(applicationID: fixture.ids[0])

        XCTAssertEqual(fixture.collectionView.pressedApplicationID, fixture.ids[0])
        XCTAssertEqual(fixture.collectionView.frame, collectionFrame)
        XCTAssertEqual(fixture.collectionView.item(at: indexPath)?.view.frame, itemFrame)

        fixture.collectionView.endPrimaryPress()

        XCTAssertNil(fixture.collectionView.pressedApplicationID)
        XCTAssertEqual(fixture.collectionView.frame, collectionFrame)
        XCTAssertEqual(fixture.collectionView.item(at: indexPath)?.view.frame, itemFrame)
    }

    func testContextMenuSelectsItsApplicationBeforeMenuPresentation() {
        let fixture = makeCollection(names: ["Alpha", "Beta"])
        fixture.collectionView.selectItems(
            at: [IndexPath(item: 0, section: 0)],
            scrollPosition: []
        )
        var selectedApplicationID: ApplicationID?
        var menuApplicationID: ApplicationID?
        fixture.collectionView.selectionDidChange = { selectedApplicationID = $0 }
        fixture.collectionView.contextMenu = { applicationID in
            menuApplicationID = applicationID
            let menu = NSMenu()
            menu.addItem(withTitle: "Launch", action: nil, keyEquivalent: "")
            return menu
        }

        let menu = fixture.collectionView.prepareContextMenu(for: fixture.ids[1])

        XCTAssertEqual(selectedApplicationID, fixture.ids[1])
        XCTAssertEqual(menuApplicationID, fixture.ids[1])
        XCTAssertEqual(fixture.collectionView.selectionIndexPaths, [IndexPath(item: 1, section: 0)])
        XCTAssertEqual(menu?.items.map(\.title), ["Launch"])
    }

    private func makeCollection(names: [String]) -> CollectionFixture {
        let ids = names.indices.map { ApplicationID($0 + 1) }
        let dataSource = FixtureDataSource(count: ids.count)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 120, height: 160)
        let collectionView = ApplicationCollectionNSView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.register(
            NSCollectionViewItem.self,
            forItemWithIdentifier: FixtureDataSource.reuseIdentifier
        )
        collectionView.dataSource = dataSource
        collectionView.orderedApplicationIDs = { ids }
        let namesByID = Dictionary(uniqueKeysWithValues: zip(ids, names))
        collectionView.applicationName = { namesByID[$0] }
        let scrollView = NSScrollView(frame: collectionView.frame)
        scrollView.documentView = collectionView
        collectionView.reloadData()
        scrollView.layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()
        return CollectionFixture(
            collectionView: collectionView,
            scrollView: scrollView,
            dataSource: dataSource,
            ids: ids
        )
    }

    private func keyEvent(
        type: NSEvent.EventType = .keyDown,
        keyCode: UInt16,
        characters: String = "",
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type,
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
}

@MainActor
private final class FixtureDataSource: NSObject, NSCollectionViewDataSource {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FixtureItem")
    let count: Int

    init(count: Int) {
        self.count = count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        collectionView.makeItem(withIdentifier: Self.reuseIdentifier, for: indexPath)
    }
}

private struct CollectionFixture {
    let collectionView: ApplicationCollectionNSView
    let scrollView: NSScrollView
    // NSCollectionView does not retain its data source.
    let dataSource: FixtureDataSource
    let ids: [ApplicationID]
}
