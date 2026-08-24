import Foundation
import UmbraCore
import XCTest
@testable import UmbraApp

@MainActor
final class AppStoreMutationOwnershipTests: XCTestCase {
    func testOlderVisibilityFailureCannotOverwriteNewerSuccess() async {
        let host = mutationHost(id: "host")
        let application = mutationApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = ApplicationMutationServiceSpy(hosts: [host], applications: [host.id: [application]])
        let store = AppStore(service: service)
        await loadApplications(on: host, into: store)

        store.toggleHidden(application)
        await waitUntil { service.pendingMutations.count == 1 }
        store.toggleHidden(application)
        await Task.yield()
        XCTAssertEqual(service.pendingMutations.map(\.kind), [
            .hidden(hostID: host.id, applicationID: application.id, value: true),
        ])

        service.failMutation(at: 0)
        await waitUntil {
            service.pendingMutations.map(\.kind) == [
                .hidden(hostID: host.id, applicationID: application.id, value: false),
            ]
        }
        service.completeMutation(at: 0)
        await waitUntil { service.pendingMutations.isEmpty && store.applications[0].isHidden == false }

        XCTAssertFalse(store.applications[0].isHidden)
        XCTAssertNil(store.failure)
    }

    func testNewerVisibilityFailureRestoresLatestPreviousValueAndPreservesCatalogUpdate() async {
        let host = mutationHost(id: "host")
        let application = mutationApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = ApplicationMutationServiceSpy(hosts: [host], applications: [host.id: [application]])
        let store = AppStore(service: service)
        await loadApplications(on: host, into: store)

        store.toggleHidden(application)
        await waitUntil { service.pendingMutations.count == 1 }
        store.toggleHidden(application)
        await Task.yield()

        let artworkURL = URL(fileURLWithPath: "/tmp/umbra-visibility-artwork.png")
        service.send(.applicationCatalogUpdated(
            hostID: host.id,
            applications: [mutationApplication(
                id: 1,
                hostID: host.id,
                name: "Desktop",
                artworkURL: artworkURL
            )]
        ))
        service.completeMutation(at: 0)
        await waitUntil {
            service.pendingMutations.map(\.kind) == [
                .hidden(hostID: host.id, applicationID: application.id, value: false),
            ]
        }
        service.failMutation(at: 0)
        await waitUntil { store.failure?.title == "Couldn’t Update App Visibility" }

        XCTAssertTrue(store.applications[0].isHidden)
        XCTAssertEqual(store.applications[0].artworkURL, artworkURL)
        XCTAssertEqual(store.failure?.title, "Couldn’t Update App Visibility")
    }

    func testVisibilityMutationsForDifferentAppsKeepIndependentOwnership() async {
        let host = mutationHost(id: "host")
        let alpha = mutationApplication(id: 1, hostID: host.id, name: "Alpha")
        let beta = mutationApplication(id: 2, hostID: host.id, name: "Beta")
        let service = ApplicationMutationServiceSpy(
            hosts: [host],
            applications: [host.id: [alpha, beta]]
        )
        let store = AppStore(service: service)
        await loadApplications(on: host, into: store)

        store.toggleHidden(alpha)
        store.toggleHidden(beta)
        await waitUntil { service.pendingMutations.count == 2 }

        service.completeMutation(at: 1)
        service.failMutation(at: 0)
        await waitUntil { store.failure?.title == "Couldn’t Update App Visibility" }

        XCTAssertEqual(store.applications.first(where: { $0.id == alpha.id })?.isHidden, false)
        XCTAssertEqual(store.applications.first(where: { $0.id == beta.id })?.isHidden, true)
        XCTAssertEqual(store.failure?.title, "Couldn’t Update App Visibility")
    }

    func testOlderDirectLaunchFailureCannotOverwriteNewerSuccessAcrossApps() async throws {
        let host = mutationHost(id: "host")
        let alpha = mutationApplication(id: 1, hostID: host.id, name: "Alpha")
        let beta = mutationApplication(id: 2, hostID: host.id, name: "Beta")
        let service = ApplicationMutationServiceSpy(
            hosts: [host],
            applications: [host.id: [alpha, beta]]
        )
        let store = AppStore(service: service)
        await loadApplications(on: host, into: store)

        store.toggleDirectLaunch(alpha)
        await waitUntil { service.pendingMutations.count == 1 }
        store.toggleDirectLaunch(try XCTUnwrap(store.applications.first(where: { $0.id == beta.id })))
        await Task.yield()
        XCTAssertEqual(service.pendingMutations.map(\.kind), [
            .directLaunch(hostID: host.id, applicationID: alpha.id, value: true),
        ])

        let artworkURL = URL(fileURLWithPath: "/tmp/umbra-direct-launch-artwork.png")
        service.send(.applicationCatalogUpdated(
            hostID: host.id,
            applications: [mutationApplication(
                id: beta.id.rawValue,
                hostID: host.id,
                name: beta.name,
                artworkURL: artworkURL
            )]
        ))
        service.failMutation(at: 0)
        await waitUntil {
            service.pendingMutations.map(\.kind) == [
                .directLaunch(hostID: host.id, applicationID: beta.id, value: true),
            ]
        }
        service.completeMutation(at: 0)
        await waitUntil { service.pendingMutations.isEmpty }

        XCTAssertEqual(store.applications.first(where: { $0.id == alpha.id })?.isDirectLaunch, false)
        XCTAssertEqual(store.applications.first(where: { $0.id == beta.id })?.isDirectLaunch, true)
        XCTAssertEqual(store.applications.first(where: { $0.id == beta.id })?.artworkURL, artworkURL)
        XCTAssertNil(store.failure)
    }

    func testNewerDirectLaunchFailureRestoresPreviousSelectionAndPreservesCatalogUpdate() async throws {
        let host = mutationHost(id: "host")
        let alpha = mutationApplication(id: 1, hostID: host.id, name: "Alpha")
        let beta = mutationApplication(id: 2, hostID: host.id, name: "Beta")
        let service = ApplicationMutationServiceSpy(
            hosts: [host],
            applications: [host.id: [alpha, beta]]
        )
        let store = AppStore(service: service)
        await loadApplications(on: host, into: store)

        store.toggleDirectLaunch(alpha)
        await waitUntil { service.pendingMutations.count == 1 }
        store.toggleDirectLaunch(try XCTUnwrap(store.applications.first(where: { $0.id == beta.id })))
        await Task.yield()

        let artworkURL = URL(fileURLWithPath: "/tmp/umbra-alpha-artwork.png")
        service.send(.applicationCatalogUpdated(
            hostID: host.id,
            applications: [mutationApplication(
                id: alpha.id.rawValue,
                hostID: host.id,
                name: alpha.name,
                artworkURL: artworkURL
            )]
        ))
        service.completeMutation(at: 0)
        await waitUntil {
            service.pendingMutations.map(\.kind) == [
                .directLaunch(hostID: host.id, applicationID: beta.id, value: true),
            ]
        }
        service.failMutation(at: 0)
        await waitUntil { store.failure?.title == "Couldn’t Update Direct Launch" }

        XCTAssertEqual(store.applications.first(where: { $0.id == alpha.id })?.isDirectLaunch, true)
        XCTAssertEqual(store.applications.first(where: { $0.id == beta.id })?.isDirectLaunch, false)
        XCTAssertEqual(store.applications.first(where: { $0.id == alpha.id })?.artworkURL, artworkURL)
        XCTAssertEqual(store.failure?.title, "Couldn’t Update Direct Launch")
    }

    func testHostNavigationInvalidatesPendingApplicationMutations() async {
        let hostA = mutationHost(id: "host-a")
        let hostB = mutationHost(id: "host-b")
        let alpha = mutationApplication(id: 1, hostID: hostA.id, name: "Alpha")
        let beta = mutationApplication(id: 2, hostID: hostB.id, name: "Beta")
        let service = ApplicationMutationServiceSpy(
            hosts: [hostA, hostB],
            applications: [hostA.id: [alpha], hostB.id: [beta]]
        )
        let store = AppStore(service: service)
        await loadApplications(on: hostA, into: store)

        store.toggleHidden(alpha)
        store.toggleDirectLaunch(alpha)
        await waitUntil { service.pendingMutations.count == 2 }

        store.openApplications(for: hostB)
        await waitUntil { store.selectedHostID == hostB.id && store.applications == [beta] }
        service.failAllMutations()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.applications, [beta])
        XCTAssertNil(store.failure)
    }

    func testCatalogReloadPreservesPendingFieldScopedOptimism() async {
        let host = mutationHost(id: "host")
        let application = mutationApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = ApplicationMutationServiceSpy(hosts: [host], applications: [host.id: [application]])
        let store = AppStore(service: service)
        await loadApplications(on: host, into: store)

        store.toggleHidden(application)
        store.toggleDirectLaunch(application)
        await waitUntil { service.pendingMutations.count == 2 }

        let artworkURL = URL(fileURLWithPath: "/tmp/umbra-reloaded-artwork.png")
        var newlyDiscovered = mutationApplication(id: 2, hostID: host.id, name: "New App")
        newlyDiscovered.isDirectLaunch = true
        service.setApplications(
            [mutationApplication(
                id: application.id.rawValue,
                hostID: host.id,
                name: application.name,
                artworkURL: artworkURL
            ), newlyDiscovered],
            for: host.id
        )
        store.loadApplications()
        await waitUntil { store.applications[0].artworkURL == artworkURL }

        XCTAssertEqual(store.applications[0].isHidden, true)
        XCTAssertEqual(store.applications[0].isDirectLaunch, true)
        XCTAssertEqual(store.applications[1].isDirectLaunch, false)

        service.completeMutation(at: 1)
        service.completeMutation(at: 0)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.applications[0].isHidden, true)
        XCTAssertEqual(store.applications[0].isDirectLaunch, true)
        XCTAssertNil(store.failure)
    }

    private func loadApplications(on host: HostDisplayModel, into store: AppStore) async {
        store.selectedHostID = host.id
        store.loadApplications()
        await waitUntil { !store.applications.isEmpty }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not satisfied", file: file, line: line)
    }
}

@MainActor
private final class ApplicationMutationServiceSpy: UmbraClientServicing {
    private var eventHandler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?
    private let hosts: [HostDisplayModel]
    private var applicationsByHost: [HostID: [ApplicationDisplayModel]]
    private(set) var pendingMutations: [PendingApplicationMutation] = []

    init(
        hosts: [HostDisplayModel],
        applications: [HostID: [ApplicationDisplayModel]]
    ) {
        self.hosts = hosts
        applicationsByHost = applications
    }

    func setEventHandler(_ handler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?) {
        eventHandler = handler
    }

    func send(_ event: UmbraClientEvent) {
        eventHandler?(event)
    }

    func discoverHosts() async throws -> [HostDisplayModel] { hosts }

    func applications(for id: HostID, includeHidden: Bool) async throws -> [ApplicationDisplayModel] {
        applicationsByHost[id] ?? []
    }

    func setApplications(_ applications: [ApplicationDisplayModel], for hostID: HostID) {
        applicationsByHost[hostID] = applications
    }

    func setApplicationHidden(id: ApplicationID, on hostID: HostID, hidden: Bool) async throws {
        try await suspend(.hidden(hostID: hostID, applicationID: id, value: hidden))
    }

    func setDirectLaunch(id: ApplicationID, on hostID: HostID, enabled: Bool) async throws {
        try await suspend(.directLaunch(hostID: hostID, applicationID: id, value: enabled))
    }

    func completeMutation(at index: Int) {
        pendingMutations.remove(at: index).continuation.resume(returning: ())
    }

    func failMutation(at index: Int) {
        pendingMutations.remove(at: index).continuation.resume(
            throwing: MutationTestError.rejected
        )
    }

    func failAllMutations() {
        let mutations = pendingMutations
        pendingMutations.removeAll()
        for mutation in mutations {
            mutation.continuation.resume(throwing: MutationTestError.rejected)
        }
    }

    func addHost(_ endpoint: HostEndpointInput) async throws -> HostDisplayModel { throw unused() }
    func pairHost(_ request: PairingRequest) async throws -> HostDisplayModel { throw unused() }
    func cancelPairing(hostID: HostID) async {}
    func renameHost(id: HostID, name: String) async throws -> HostDisplayModel { throw unused() }
    func deleteHost(id: HostID) async throws { throw unused() }
    func wakeHost(id: HostID) async throws -> HostDisplayModel { throw unused() }
    func testNetwork(for id: HostID) async throws -> NetworkTestOutcome { throw unused() }
    func launchApplication(id: ApplicationID, on hostID: HostID, resume: Bool) async throws { throw unused() }
    func quitApplication(id: ApplicationID, on hostID: HostID) async throws { throw unused() }

    private func suspend(_ kind: PendingApplicationMutation.Kind) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pendingMutations.append(PendingApplicationMutation(
                kind: kind,
                continuation: continuation
            ))
        }
    }

    private func unused() -> UmbraClientServiceError {
        .unavailable("Unexpected test service call")
    }
}

private struct PendingApplicationMutation {
    enum Kind: Equatable {
        case hidden(hostID: HostID, applicationID: ApplicationID, value: Bool)
        case directLaunch(hostID: HostID, applicationID: ApplicationID, value: Bool)
    }

    let kind: Kind
    let continuation: CheckedContinuation<Void, any Error>
}

private enum MutationTestError: LocalizedError {
    case rejected

    var errorDescription: String? { "The host rejected the mutation." }
}

private func mutationHost(id: String) -> HostDisplayModel {
    HostDisplayModel(
        id: HostID(id),
        name: id.capitalized,
        status: .online,
        isPaired: true,
        hasActiveSession: false,
        runningApplicationID: nil,
        canWake: false,
        isServerSupported: true,
        details: ""
    )
}

private func mutationApplication(
    id: Int,
    hostID: HostID,
    name: String,
    artworkURL: URL? = nil
) -> ApplicationDisplayModel {
    ApplicationDisplayModel(
        id: ApplicationID(id),
        hostID: hostID,
        name: name,
        artworkURL: artworkURL,
        isRunning: false,
        isHidden: false,
        isDirectLaunch: false
    )
}
