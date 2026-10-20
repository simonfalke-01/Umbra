import XCTest
@testable import UmbraApp

@MainActor
final class HostBrowserPresentationTests: XCTestCase {
    func testStatusAndDefaultActionMatrix() {
        let cases: [(HostDisplayModel, String, HostBrowserActionKind?, HostBrowserPresentation.StatusTone)] = [
            (
                makeHost(status: .unknown, isPaired: true),
                "Checking...",
                nil,
                .checking
            ),
            (
                makeHost(status: .offline, canWake: true),
                "Offline, Can Wake",
                .wake,
                .neutral
            ),
            (
                makeHost(status: .offline, canWake: false),
                "Offline",
                .details,
                .neutral
            ),
            (
                makeHost(status: .online, isPaired: true),
                "Ready",
                .openApplications,
                .neutral
            ),
            (
                makeHost(status: .online, isPaired: true, hasActiveSession: true),
                "Streaming",
                .openApplications,
                .neutral
            ),
            (
                makeHost(status: .online, isPaired: false),
                "Pair Required",
                .pair,
                .warning
            ),
            (
                makeHost(status: .online, isPaired: false, hasActiveSession: true),
                "Streaming, Pair Required",
                .pair,
                .warning
            ),
            (
                makeHost(status: .online, isPaired: true, isServerSupported: false),
                "Unsupported Host",
                .details,
                .failure
            ),
            (
                makeHost(
                    status: .online,
                    isPaired: false,
                    hasActiveSession: true,
                    isServerSupported: false
                ),
                "Unsupported Host, Streaming, Pair Required",
                .details,
                .failure
            ),
        ]

        for (host, expectedStatus, expectedAction, expectedTone) in cases {
            let presentation = HostBrowserPresentation(host: host)
            XCTAssertEqual(presentation.statusSummary, expectedStatus)
            XCTAssertEqual(presentation.defaultAction?.kind, expectedAction)
            XCTAssertEqual(presentation.statusTone, expectedTone)
        }
    }

    func testContextCommandsUseTheSharedDescriptorOrder() {
        let presentation = HostBrowserPresentation(host: makeHost(status: .online, isPaired: true))

        XCTAssertEqual(
            presentation.actionGroups.flatMap(\.actions).map(\.kind),
            [.openApplications, .rename, .details, .remove]
        )
        XCTAssertEqual(
            presentation.actionGroups.flatMap(\.actions).last?.role,
            .destructive
        )
    }

    func testDetailsDefaultIsNotDuplicatedInContextCommands() {
        let presentation = HostBrowserPresentation(
            host: makeHost(status: .online, isPaired: true, isServerSupported: false)
        )

        XCTAssertEqual(
            presentation.actionGroups.flatMap(\.actions).map(\.kind),
            [.details, .rename, .remove]
        )
    }

    func testVoiceOverHelpDescribesTheActualDefaultAction() {
        let ready = HostBrowserPresentation(host: makeHost(status: .online, isPaired: true))
        let checking = HostBrowserPresentation(host: makeHost(status: .unknown, isPaired: false))

        XCTAssertEqual(ready.accessibilityHelp, "Press to open applications.")
        XCTAssertEqual(checking.accessibilityHelp, "Host status is still being checked.")
    }

    func testOpeningApplicationsDoesNotChangeHiddenApplicationVisibility() throws {
        let host = makeHost(status: .online, isPaired: true)
        let store = AppStore(service: UnavailableUmbraClientService())
        store.showHiddenApplications = false
        let action = try XCTUnwrap(HostBrowserPresentation(host: host).defaultAction)

        store.performHostBrowserAction(action, for: host)

        XCTAssertFalse(store.showHiddenApplications)
        XCTAssertEqual(store.selectedHostID, host.id)
    }

    func testStoreActivationUsesTheSameDefaultActionMatrix() {
        let store = AppStore(service: UnavailableUmbraClientService())
        let checking = makeHost(status: .unknown, isPaired: false)
        store.activate(checking)
        XCTAssertNil(store.presentedSheet)
        XCTAssertNil(store.failure)

        let unsupported = makeHost(
            status: .online,
            isPaired: true,
            isServerSupported: false
        )
        store.activate(unsupported)
        XCTAssertEqual(store.presentedSheet, .details(unsupported.id))
        XCTAssertNil(store.failure)

        store.presentedSheet = nil
        let streamingUnpaired = makeHost(
            status: .online,
            isPaired: false,
            hasActiveSession: true
        )
        store.activate(streamingUnpaired)
        guard case let .pair(hostID, pin) = store.presentedSheet else {
            return XCTFail("An online unpaired host must start pairing even while streaming.")
        }
        XCTAssertEqual(hostID, streamingUnpaired.id)
        XCTAssertEqual(pin.count, 4)
    }

    private func makeHost(
        status: HostConnectionStatus,
        isPaired: Bool = true,
        hasActiveSession: Bool = false,
        canWake: Bool = false,
        isServerSupported: Bool = true
    ) -> HostDisplayModel {
        HostDisplayModel(
            id: HostID(UUID().uuidString),
            name: "Test Host",
            status: status,
            isPaired: isPaired,
            hasActiveSession: hasActiveSession,
            canWake: canWake,
            isServerSupported: isServerSupported,
            details: ""
        )
    }
}
