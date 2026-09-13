import Foundation
import UmbraCore
import UmbraServices
import XCTest
@testable import UmbraApp

@MainActor
final class AppStoreApplicationTests: XCTestCase {
    func testHostWithActiveSessionOpensApplicationLibrary() async {
        let host = makeHost(id: "host", hasActiveSession: true)
        let running = makeApplication(id: 1, hostID: host.id, name: "Desktop", isRunning: true)
        let service = AppStoreClientServiceSpy(hosts: [host], applications: [host.id: [running]])
        let store = AppStore(service: service)

        store.activate(host)
        await waitUntil { store.applications == [running] }

        XCTAssertEqual(store.selectedHostID, host.id)
        XCTAssertNil(store.failure)
    }

    func testAuthoritativeHostEventsReconcileExternallyRunningApplication() async {
        let host = makeHost(id: "host")
        let alpha = makeApplication(id: 1, hostID: host.id, name: "Alpha")
        let beta = makeApplication(id: 2, hostID: host.id, name: "Beta")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [alpha, beta]]
        )
        let store = AppStore(service: service)
        store.start()
        await waitUntil { store.hosts == [host] }
        store.openApplications(for: host)
        await waitUntil { store.applications.count == 2 }

        service.send(.hosts([
            makeHost(id: "host", runningApplicationID: beta.id),
        ]))
        await waitUntil {
            store.applications.first(where: { $0.id == beta.id })?.isRunning == true
        }
        XCTAssertFalse(store.applications.first(where: { $0.id == alpha.id })?.isRunning == true)

        service.send(.hosts([makeHost(id: "host")]))
        await waitUntil { !store.applications.contains(where: \.isRunning) }
    }

    func testRunningApplicationUsesNormalSearchFilteringWhileRemainingReachableWhenHidden() async {
        let host = makeHost(id: "host")
        let desktop = makeApplication(
            id: 1,
            hostID: host.id,
            name: "Desktop",
            isRunning: true,
            isHidden: true
        )
        let game = makeApplication(id: 2, hostID: host.id, name: "Game")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [desktop, game]]
        )
        let store = AppStore(service: service)
        store.start()
        await waitUntil { store.hosts == [host] }
        store.openApplications(for: host)
        await waitUntil { store.applications.count == 2 }

        store.applicationFilter = "game"
        XCTAssertEqual(store.visibleApplications.map(\.id), [game.id])

        store.applicationFilter = "desk"
        XCTAssertEqual(
            store.visibleApplications.map(\.id),
            [desktop.id],
            "A matching hidden running app must remain reachable for Resume and Quit."
        )
    }

    func testPairingServiceCancellationDoesNotPresentFailure() async {
        let host = makeHost(id: "host")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [:],
            pairingError: UmbraServiceError.cancelled
        )
        let store = AppStore(service: service)

        store.performPairing(hostID: host.id, pin: "1234")
        await waitUntil { store.operation == nil }

        XCTAssertNil(store.failure)
    }

    func testLSPPairingDisplaysNativeSixDigitPINWithoutRegeneration() async {
        let host = makeHost(id: "lsp:00112233-4455-6677-8899-aabbccddeeff")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [:],
            preparedPIN: "004200"
        )
        let store = AppStore(service: service)

        store.beginPairing(host)
        await waitUntil { store.presentedSheet == .pair(host.id, pin: "004200") }

        XCTAssertEqual(service.preparePairingRequests, [host.id])
        XCTAssertEqual(
            store.pairingPreparations[host.id]?.provisionalSPKIFingerprint,
            "00112233 44556677"
        )
    }

    func testCancellingLSPBeforePINSheetCancelsServiceAttempt() async {
        let host = makeHost(id: "lsp:00112233-4455-6677-8899-aabbccddeeff")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [:],
            suspendsPairingPreparation: true,
            preparedPIN: "004200"
        )
        let store = AppStore(service: service)

        store.beginPairing(host)
        await waitUntil { service.pendingPairingPreparationCount == 1 }
        store.cancelCurrentOperation()
        await waitUntil { service.cancelPairingRequests == [host.id] }

        XCTAssertNil(store.presentedSheet)
        XCTAssertNil(store.pairingPreparations[host.id])
    }

    func testReplacingRunningApplicationWaitsForExplicitConfirmation() async throws {
        let host = makeHost(id: "host")
        let running = makeApplication(id: 1, hostID: host.id, name: "Running", isRunning: true)
        let next = makeApplication(id: 2, hostID: host.id, name: "Next")
        let service = AppStoreClientServiceSpy(hosts: [host], applications: [host.id: [running, next]])
        let store = AppStore(service: service)

        store.start()
        await waitUntil { store.hosts == [host] }
        store.openApplications(for: host)
        await waitUntil { store.applications.count == 2 }

        store.launch(next)

        let confirmation = try XCTUnwrap(store.confirmation)
        XCTAssertEqual(confirmation, .replaceRunningApplication(current: running.id, next: next.id))
        XCTAssertEqual(service.applicationOperations, [])

        store.confirm(confirmation)
        await waitUntil { service.applicationOperations.count == 2 }

        XCTAssertEqual(service.applicationOperations, [
            .quit(hostID: host.id, applicationID: running.id),
            .launch(hostID: host.id, applicationID: next.id, resume: false),
        ])
        await waitUntil { store.operation == nil }
        XCTAssertEqual(store.applications.first(where: { $0.id == next.id })?.isRunning, true)
    }

    func testSessionEndRestoresApplicationBrowserContextBeforeRefreshing() async {
        let host = makeHost(id: "host")
        let otherHost = makeHost(id: "other")
        let alpha = makeApplication(id: 1, hostID: host.id, name: "Alpha")
        let beta = makeApplication(id: 2, hostID: host.id, name: "Beta", isHidden: true)
        let service = AppStoreClientServiceSpy(
            hosts: [host, otherHost],
            applications: [host.id: [alpha, beta], otherHost.id: []]
        )
        let store = AppStore(service: service)

        store.start()
        await waitUntil { store.hosts.count == 2 }
        store.openApplications(for: host)
        await waitUntil { store.applications.count == 2 }
        store.applicationFilter = "a"
        store.showHiddenApplications = true
        store.selectedApplicationID = alpha.id
        store.applicationScrollPositionID = beta.id

        store.launch(alpha)
        await waitUntil { service.applicationOperations.count == 1 }

        store.selectedHostID = otherHost.id
        store.applicationFilter = "changed"
        store.showHiddenApplications = false
        store.selectedApplicationID = nil
        store.applicationScrollPositionID = nil

        service.send(.sessionEnded)
        await waitUntil { service.applicationRequestCount(for: host.id) == 2 }

        XCTAssertEqual(store.selectedHostID, host.id)
        XCTAssertEqual(store.applicationFilter, "a")
        XCTAssertTrue(store.showHiddenApplications)
        XCTAssertEqual(store.selectedApplicationID, alpha.id)
        XCTAssertEqual(store.applicationScrollPositionID, beta.id)
        XCTAssertEqual(store.visibleApplications.map(\.id), [alpha.id, beta.id])
    }

    func testApplicationFilterIncludesHiddenAppsOnlyWhenRequested() async {
        let host = makeHost(id: "host")
        let desktop = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let hiddenDesktop = makeApplication(id: 2, hostID: host.id, name: "Hidden Desktop", isHidden: true)
        let game = makeApplication(id: 3, hostID: host.id, name: "Game")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [desktop, hiddenDesktop, game]]
        )
        let store = AppStore(service: service)

        store.start()
        await waitUntil { store.hosts == [host] }
        store.openApplications(for: host)
        await waitUntil { store.applications.count == 3 }

        store.applicationFilter = "desktop"
        XCTAssertEqual(store.visibleApplications.map(\.id), [desktop.id])

        store.showHiddenApplications = true
        XCTAssertEqual(store.visibleApplications.map(\.id), [desktop.id, hiddenDesktop.id])
    }

    func testFilteringAndHidingReconcileSelectionAgainstVisibleApplications() async {
        let host = makeHost(id: "host")
        let desktop = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let hidden = makeApplication(id: 2, hostID: host.id, name: "Hidden", isHidden: true)
        let game = makeApplication(id: 3, hostID: host.id, name: "Game")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [desktop, hidden, game]]
        )
        let store = AppStore(service: service)

        store.openApplications(for: host)
        await waitUntil { store.applications.count == 3 }

        store.selectedApplicationID = desktop.id
        store.applicationFilter = "game"
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedVisibleApplication)

        store.applicationFilter = ""
        store.showHiddenApplications = true
        store.selectedApplicationID = hidden.id
        XCTAssertEqual(store.selectedVisibleApplication?.id, hidden.id)

        store.showHiddenApplications = false
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedVisibleApplication)
    }

    func testFilteredApplicationCannotLaunchThroughAStaleSelection() async {
        let host = makeHost(id: "host")
        let desktop = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let game = makeApplication(id: 2, hostID: host.id, name: "Game")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [desktop, game]]
        )
        let store = AppStore(service: service)

        store.openApplications(for: host)
        await waitUntil { store.applications.count == 2 }
        store.selectedApplicationID = desktop.id
        store.applicationFilter = "game"

        store.launch(desktop)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertNil(store.selectedApplicationID)
        XCTAssertEqual(service.applicationOperations, [])
    }

    func testApplicationModelFromAnotherHostCannotLaunchMatchingNumericID() async {
        let hostA = makeHost(id: "host-a")
        let hostB = makeHost(id: "host-b")
        let applicationFromA = makeApplication(id: 1, hostID: hostA.id, name: "Alpha")
        let applicationFromB = makeApplication(id: 1, hostID: hostB.id, name: "Beta")
        let service = AppStoreClientServiceSpy(
            hosts: [hostA, hostB],
            applications: [hostA.id: [applicationFromA], hostB.id: [applicationFromB]]
        )
        let store = AppStore(service: service)

        store.openApplications(for: hostB)
        await waitUntil { store.applications == [applicationFromB] }

        store.launch(applicationFromA)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertNil(store.selectedApplicationID)
        XCTAssertEqual(service.applicationOperations, [])
    }

    func testRapidDuplicateActivationStartsOneConnection() async {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [application]],
            suspendsApplicationLaunch: true
        )
        let store = AppStore(service: service)

        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }

        store.launch(application)
        store.launch(application)
        await waitUntil { service.pendingApplicationLaunchCount == 1 }

        XCTAssertEqual(service.applicationOperations, [
            .launch(hostID: host.id, applicationID: application.id, resume: false),
        ])

        service.completeNextApplicationLaunch()
        await waitUntil { store.operation == nil }
    }

    func testConnectionStagesRemainVisibleUntilStreamingStarts() async throws {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [application]],
            suspendsApplicationLaunch: true
        )
        let store = AppStore(service: service)
        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }

        store.launch(application)
        await waitUntil { service.pendingApplicationLaunchCount == 1 }
        service.send(.sessionPreparing)
        XCTAssertEqual(store.operation?.message, "Preparing the stream...")
        service.send(.sessionConnecting(.connection))
        let genericConnectionProgress = try XCTUnwrap(store.operation?.progress)
        service.send(.sessionConnecting(.platformInitialization))
        let platformProgress = try XCTUnwrap(store.operation?.progress)
        service.send(.sessionConnecting(.videoStreamInitialization))
        XCTAssertEqual(store.operation?.message, "Starting video...")
        let videoProgress = try XCTUnwrap(store.operation?.progress)
        service.send(.sessionConnecting(.audioStreamInitialization))
        let repeatedAudioProgress = try XCTUnwrap(store.operation?.progress)
        XCTAssertEqual(repeatedAudioProgress, videoProgress)
        XCTAssertLessThanOrEqual(genericConnectionProgress, platformProgress)
        XCTAssertLessThanOrEqual(platformProgress, videoProgress)

        service.completeNextApplicationLaunch()
        await waitUntil { store.applications.first?.isRunning == true }
        XCTAssertNotNil(store.operation)
        service.send(.sessionStreaming)
        XCTAssertNil(store.operation)
    }

    func testConfigurationWarningsRemainNonvisualThroughoutConnection() async throws {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [application]],
            suspendsApplicationLaunch: true
        )
        let store = AppStore(service: service)
        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }

        store.launch(application)
        await waitUntil { service.pendingApplicationLaunchCount == 1 }
        let operationBeforeWarnings = try XCTUnwrap(store.operation)
        service.send(.configurationWarnings([
            "The selected display cannot present HDR. Umbra will use SDR for this stream.",
            "The active audio device cannot play surround sound. Umbra will use Stereo for this stream.",
        ]))

        XCTAssertNil(store.failure)
        XCTAssertEqual(store.operation, operationBeforeWarnings)
        XCTAssertTrue(try XCTUnwrap(store.operation?.isCancellable))
        XCTAssertEqual(service.pendingApplicationLaunchCount, 1)

        service.send(.sessionConnecting(.platformInitialization))
        XCTAssertEqual(store.operation?.message, "Initializing this Mac...")
        service.send(.sessionConnecting(.videoStreamInitialization))
        XCTAssertEqual(store.operation?.message, "Starting video...")
        XCTAssertTrue(try XCTUnwrap(store.operation?.isCancellable))
        service.send(.sessionWarning("Network conditions changed while connecting."))
        XCTAssertEqual(store.operation?.message, "Network conditions changed while connecting.")

        service.completeNextApplicationLaunch()
        await waitUntil { store.applications.first?.isRunning == true }
        service.send(.sessionStreaming)

        XCTAssertNil(store.operation)
        XCTAssertNil(store.failure)
    }

    func testStreamingWarningsNeverPresentAModalOrInterruptTheSession() async {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(hosts: [host], applications: [host.id: [application]])
        let store = AppStore(service: service)
        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }
        store.launch(application)
        await waitUntil { service.applicationOperations.count == 1 }
        service.send(.sessionStreaming)

        for message in [
            "Native LSP input reconnected with fresh security keys.",
            "LSP device rate negotiation failed and will retry.",
            "A recoverable streaming warning.",
        ] {
            service.send(.sessionWarning(message))
            XCTAssertNil(store.failure)
            XCTAssertNil(store.operation)
            XCTAssertEqual(store.sessionDegradation, message)
        }

        service.send(.sessionFailed(.init(kind: .connectionFailed, message: "Connection recovery failed.")))
        XCTAssertEqual(store.failure?.message, "Connection recovery failed.")
    }

    func testSessionDegradationPersistsAcrossConnectionStagesUntilSessionEnds() async {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [application]],
            suspendsApplicationLaunch: true
        )
        let store = AppStore(service: service)
        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }
        store.launch(application)
        await waitUntil { service.pendingApplicationLaunchCount == 1 }

        let message = "Microphone forwarding is unavailable. Umbra will stream without it."
        service.send(.sessionDegraded(message))
        XCTAssertEqual(store.sessionDegradation, message)
        XCTAssertEqual(store.operation?.message, message)

        service.send(.sessionPreparing)
        service.send(.sessionConnecting(.videoStreamInitialization))
        XCTAssertEqual(store.operation?.message, message)

        service.send(.sessionStreaming)
        XCTAssertEqual(store.sessionDegradation, message)
        service.send(.sessionEnded)
        XCTAssertNil(store.sessionDegradation)
    }

    func testConfigurationWarningWithoutActiveOperationHasNoPresentation() {
        let service = AppStoreClientServiceSpy(hosts: [], applications: [:])
        let store = AppStore(service: service)

        service.send(.configurationWarnings(["Review the selected video settings."]))

        XCTAssertNil(store.failure)
        XCTAssertNil(store.operation)

        service.send(.sessionStreaming)
        XCTAssertNil(store.failure)
    }

    func testCancellingConnectionWithConfigurationWarningClearsOperation() async {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [application]],
            suspendsApplicationLaunch: true
        )
        let store = AppStore(service: service)
        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }

        store.launch(application)
        await waitUntil { service.pendingApplicationLaunchCount == 1 }
        service.send(.configurationWarnings(["Umbra will use a compatible fallback."]))
        XCTAssertTrue(store.operation?.isCancellable == true)

        store.cancelCurrentOperation()

        XCTAssertNil(store.operation)
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.selectedApplicationID, application.id)
        await waitUntil { service.disconnectCount == 1 }

        service.completeNextApplicationLaunch()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(store.operation)
    }

    func testStreamingLifecycleCanTakeOwnershipBeforeLaunchCallReturns() async {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [application]],
            suspendsApplicationLaunch: true
        )
        let store = AppStore(service: service)
        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }

        store.launch(application)
        await waitUntil { service.pendingApplicationLaunchCount == 1 }
        service.send(.sessionStreaming)
        service.completeNextApplicationLaunch()

        await waitUntil { store.applications.first?.isRunning == true }
        XCTAssertNil(store.operation)
    }

    func testActivationInFlightPreventsASecondApplicationConnection() async {
        let host = makeHost(id: "host")
        let first = makeApplication(id: 1, hostID: host.id, name: "First")
        let second = makeApplication(id: 2, hostID: host.id, name: "Second")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [host.id: [first, second]],
            suspendsApplicationLaunch: true
        )
        let store = AppStore(service: service)

        store.openApplications(for: host)
        await waitUntil { store.applications.count == 2 }

        store.launch(first)
        store.launch(second)
        await waitUntil { service.pendingApplicationLaunchCount == 1 }

        XCTAssertEqual(store.selectedApplicationID, first.id)
        XCTAssertEqual(service.applicationOperations, [
            .launch(hostID: host.id, applicationID: first.id, resume: false),
        ])

        service.completeNextApplicationLaunch()
        await waitUntil { store.operation == nil }
    }

    func testCancelledOperationCannotClearImmediateRetry() async {
        let host = makeHost(id: "host")
        let service = AppStoreClientServiceSpy(
            hosts: [host],
            applications: [:],
            suspendsPairing: true
        )
        let store = AppStore(service: service)

        store.performPairing(hostID: host.id, pin: "1111")
        await waitUntil { service.pendingPairingCount == 1 }

        store.cancelCurrentOperation()
        store.performPairing(hostID: host.id, pin: "2222")
        await waitUntil { service.pendingPairingCount == 2 }

        service.completeNextPairing(with: host)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(store.operation?.kind, .pairing)
        XCTAssertNil(store.failure)

        service.completeNextPairing(with: host)
        await waitUntil { store.operation == nil }
        XCTAssertNil(store.failure)
    }

    func testCancelledSessionFailureEndsSilently() async {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(hosts: [host], applications: [host.id: [application]])
        let store = AppStore(service: service)

        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }
        service.send(.sessionFailed(SessionFailure(kind: .cancelled, message: "The operation was cancelled.")))
        await waitUntil { service.applicationRequestCount(for: host.id) == 2 }

        XCTAssertNil(store.failure)
        XCTAssertNil(store.operation)
    }

    func testNonCancelledSessionFailurePreservesMessage() async {
        let host = makeHost(id: "host")
        let service = AppStoreClientServiceSpy(hosts: [host], applications: [host.id: []])
        let store = AppStore(service: service)

        store.openApplications(for: host)
        await waitUntil { service.applicationRequestCount(for: host.id) == 1 }
        service.send(.sessionFailed(SessionFailure(kind: .connectionFailed, message: "The host closed the stream.")))

        XCTAssertEqual(store.failure?.title, "Couldn’t Start Stream")
        XCTAssertEqual(store.failure?.message, "The host closed the stream.")
        XCTAssertNil(store.failure?.recovery)
    }

    func testStreamFailureReconnectIsResumeOnlyAfterCatalogReportsAppStopped() async throws {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(hosts: [host], applications: [host.id: [application]])
        let store = AppStore(service: service)
        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }

        store.launch(application)
        await waitUntil { service.applicationOperations.count == 1 }
        service.send(.sessionStreaming)
        service.send(.sessionFailed(SessionFailure(
            kind: .connectionFailed,
            message: "The connection was interrupted."
        )))

        let recovery = try XCTUnwrap(store.failure?.recovery)
        XCTAssertEqual(recovery, .reconnect(hostID: host.id, applicationID: application.id))
        await waitUntil {
            service.applicationRequestCount(for: host.id) == 2
                && store.applications.first?.isRunning == false
        }
        store.performRecovery(recovery)
        await waitUntil { service.applicationOperations.count == 2 }
        XCTAssertEqual(service.applicationOperations.last, .launch(
            hostID: host.id,
            applicationID: application.id,
            resume: true
        ))
    }

    func testNonTransientStreamFailureDoesNotOfferReconnect() async {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(hosts: [host], applications: [host.id: [application]])
        let store = AppStore(service: service)
        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }

        store.launch(application)
        await waitUntil { service.applicationOperations.count == 1 }
        service.send(.sessionStreaming)
        service.send(.sessionFailed(SessionFailure(
            kind: .decoderUnavailable,
            message: "The selected video format is unavailable."
        )))

        XCTAssertEqual(store.failure?.title, "Streaming Ended")
        XCTAssertNil(store.failure?.recovery)
    }

    func testReconnectRemainsActionableWhenApplicationDisappears() async {
        let host = makeHost(id: "host")
        let service = AppStoreClientServiceSpy(hosts: [host], applications: [host.id: []])
        let store = AppStore(service: service)
        store.openApplications(for: host)
        await waitUntil { service.applicationRequestCount(for: host.id) == 1 }
        let recovery = PresentedFailureRecovery.reconnect(
            hostID: host.id,
            applicationID: ApplicationID(99)
        )
        store.failure = PresentedFailure(
            title: "Streaming Ended",
            message: "The connection was interrupted.",
            recovery: recovery
        )

        store.performRecovery(recovery)

        XCTAssertEqual(store.failure?.title, "Couldn’t Reconnect")
        XCTAssertEqual(
            store.failure?.message,
            "The streamed application is no longer available on this host."
        )
        XCTAssertEqual(service.applicationOperations, [])
    }

    func testIncrementalArtworkUpdatePreservesLibraryContext() async {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(hosts: [host], applications: [host.id: [application]])
        let store = AppStore(service: service)

        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }
        store.applicationFilter = "desk"
        store.selectedApplicationID = application.id
        store.applicationScrollPositionID = application.id

        var updatedApplication = application
        updatedApplication.artworkURL = URL(fileURLWithPath: "/tmp/umbra-artwork.png")
        service.send(.applicationCatalogUpdated(hostID: host.id, applications: [updatedApplication]))

        XCTAssertEqual(store.applications.first?.artworkURL, updatedApplication.artworkURL)
        XCTAssertEqual(store.applicationFilter, "desk")
        XCTAssertEqual(store.selectedApplicationID, application.id)
        XCTAssertEqual(store.applicationScrollPositionID, application.id)
    }

    func testCatalogRefreshWarningIsNonDestructiveAndDismissible() async {
        let host = makeHost(id: "host")
        let application = makeApplication(id: 1, hostID: host.id, name: "Desktop")
        let service = AppStoreClientServiceSpy(hosts: [host], applications: [host.id: [application]])
        let store = AppStore(service: service)

        store.openApplications(for: host)
        await waitUntil { store.applications == [application] }
        service.send(.applicationCatalogRefreshWarning(
            hostID: host.id,
            message: "Umbra is showing the last saved version."
        ))

        XCTAssertEqual(store.applications, [application])
        XCTAssertEqual(store.applicationCatalogWarning, "Umbra is showing the last saved version.")
        XCTAssertNil(store.failure)

        store.dismissApplicationCatalogWarning()
        XCTAssertNil(store.applicationCatalogWarning)
    }

    func testReconnectCannotUntrackOldCatalogRefreshAcrossHostNavigation() async throws {
        let hostA = makeHost(id: "host-a")
        let hostB = makeHost(id: "host-b")
        let applicationA = makeApplication(id: 1, hostID: hostA.id, name: "Alpha")
        let applicationB = makeApplication(id: 1, hostID: hostB.id, name: "Beta")
        let service = AppStoreClientServiceSpy(
            hosts: [hostA, hostB],
            applications: [hostA.id: [applicationA], hostB.id: [applicationB]],
            suspendsApplicationRequests: true
        )
        let store = AppStore(service: service)

        store.openApplications(for: hostA)
        await waitUntil { service.pendingApplicationRequestCount(for: hostA.id) == 1 }
        service.completeNextApplicationRequest(for: hostA.id)
        await waitUntil { store.applications == [applicationA] }
        store.selectedApplicationID = applicationA.id

        store.launch(applicationA)
        await waitUntil { service.applicationOperations.count == 1 }
        service.send(.sessionStreaming)
        service.send(.sessionFailed(SessionFailure(
            kind: .connectionFailed,
            message: "The connection was interrupted."
        )))
        let recovery = try XCTUnwrap(store.failure?.recovery)
        await waitUntil { service.pendingApplicationRequestCount(for: hostA.id) == 1 }

        store.performRecovery(recovery)
        await waitUntil { service.applicationOperations.count == 2 }
        store.openApplications(for: hostB)
        await waitUntil { service.pendingApplicationRequestCount(for: hostB.id) == 1 }
        service.completeNextApplicationRequest(for: hostB.id)
        await waitUntil { store.applications == [applicationB] }

        store.applicationFilter = "beta"
        store.showHiddenApplications = true
        store.selectedApplicationID = applicationB.id
        store.applicationScrollPositionID = applicationB.id

        service.completeNextApplicationRequest(for: hostA.id)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.selectedHostID, hostB.id)
        XCTAssertEqual(store.applications, [applicationB])
        XCTAssertEqual(store.visibleApplications, [applicationB])
        XCTAssertEqual(store.applicationFilter, "beta")
        XCTAssertTrue(store.showHiddenApplications)
        XCTAssertEqual(store.selectedApplicationID, applicationB.id)
        XCTAssertEqual(store.applicationScrollPositionID, applicationB.id)
        XCTAssertEqual(service.applicationOperations.last, .launch(
            hostID: hostA.id,
            applicationID: applicationA.id,
            resume: true
        ))
    }

    func testFailedCancelledCatalogRefreshCannotOverwriteNewHostCatalog() async {
        let hostA = makeHost(id: "host-a")
        let hostB = makeHost(id: "host-b")
        let applicationA = makeApplication(id: 1, hostID: hostA.id, name: "Alpha")
        let applicationB = makeApplication(id: 2, hostID: hostB.id, name: "Beta")
        let service = AppStoreClientServiceSpy(
            hosts: [hostA, hostB],
            applications: [hostA.id: [applicationA], hostB.id: [applicationB]],
            suspendsApplicationRequests: true
        )
        let store = AppStore(service: service)

        store.openApplications(for: hostA)
        await waitUntil { service.pendingApplicationRequestCount(for: hostA.id) == 1 }
        store.openApplications(for: hostB)
        await waitUntil { service.pendingApplicationRequestCount(for: hostB.id) == 1 }
        service.completeNextApplicationRequest(for: hostB.id)
        await waitUntil { store.applications == [applicationB] }
        store.applicationFilter = "beta"
        store.selectedApplicationID = applicationB.id

        service.failNextApplicationRequest(
            for: hostA.id,
            with: UmbraClientServiceError.unavailable("Host A refresh failed")
        )
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.selectedHostID, hostB.id)
        XCTAssertEqual(store.applications, [applicationB])
        XCTAssertEqual(store.visibleApplications, [applicationB])
        XCTAssertEqual(store.applicationFilter, "beta")
        XCTAssertEqual(store.selectedApplicationID, applicationB.id)
        XCTAssertNil(store.failure)
    }

    func testDirectLaunchDoesNotLoopWhenStreamEnds() async {
        let host = makeHost(id: "host")
        let directLaunch = makeApplication(id: 1, hostID: host.id, name: "Desktop", isDirectLaunch: true)
        let service = AppStoreClientServiceSpy(hosts: [host], applications: [host.id: [directLaunch]])
        let store = AppStore(service: service)

        store.start()
        await waitUntil { store.hosts == [host] }
        store.openApplications(for: host)
        await waitUntil { service.applicationOperations.count == 1 }

        service.send(.sessionEnded)
        await waitUntil { service.applicationRequestCount(for: host.id) == 2 }
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(service.applicationOperations, [
            .launch(hostID: host.id, applicationID: directLaunch.id, resume: false),
        ])
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

private enum RecordedApplicationOperation: Equatable {
    case launch(hostID: HostID, applicationID: ApplicationID, resume: Bool)
    case quit(hostID: HostID, applicationID: ApplicationID)
}

@MainActor
private final class AppStoreClientServiceSpy: UmbraClientServicing {
    private var eventHandler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?
    private let hosts: [HostDisplayModel]
    private let applicationsByHost: [HostID: [ApplicationDisplayModel]]
    private var applicationRequests: [HostID] = []
    private(set) var applicationOperations: [RecordedApplicationOperation] = []
    private(set) var disconnectCount = 0
    private let pairingError: Error?
    private let suspendsPairing: Bool
    private let suspendsApplicationLaunch: Bool
    private let suspendsApplicationRequests: Bool
    private let preparedPIN: String
    private let suspendsPairingPreparation: Bool
    private(set) var preparePairingRequests: [HostID] = []
    private(set) var cancelPairingRequests: [HostID] = []
    private var pairingPreparationContinuations: [HostID: CheckedContinuation<PairingPreparation, Error>] = [:]
    private var pairingContinuations: [CheckedContinuation<HostDisplayModel, any Error>] = []
    private var applicationLaunchContinuations: [CheckedContinuation<Void, any Error>] = []
    private var pendingApplicationRequests: [PendingApplicationRequest] = []

    init(
        hosts: [HostDisplayModel],
        applications: [HostID: [ApplicationDisplayModel]],
        pairingError: Error? = nil,
        suspendsPairing: Bool = false,
        suspendsApplicationLaunch: Bool = false,
        suspendsApplicationRequests: Bool = false,
        suspendsPairingPreparation: Bool = false,
        preparedPIN: String = "1234"
    ) {
        self.hosts = hosts
        applicationsByHost = applications
        self.pairingError = pairingError
        self.suspendsPairing = suspendsPairing
        self.suspendsApplicationLaunch = suspendsApplicationLaunch
        self.suspendsApplicationRequests = suspendsApplicationRequests
        self.suspendsPairingPreparation = suspendsPairingPreparation
        self.preparedPIN = preparedPIN
    }

    var pendingPairingCount: Int { pairingContinuations.count }
    var pendingPairingPreparationCount: Int { pairingPreparationContinuations.count }
    var pendingApplicationLaunchCount: Int { applicationLaunchContinuations.count }

    func pendingApplicationRequestCount(for hostID: HostID) -> Int {
        pendingApplicationRequests.count(where: { $0.hostID == hostID })
    }

    func setEventHandler(_ handler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?) {
        eventHandler = handler
    }

    func send(_ event: UmbraClientEvent) {
        eventHandler?(event)
    }

    func applicationRequestCount(for hostID: HostID) -> Int {
        applicationRequests.count(where: { $0 == hostID })
    }

    func discoverHosts() async throws -> [HostDisplayModel] { hosts }

    func applications(for id: HostID, includeHidden: Bool) async throws -> [ApplicationDisplayModel] {
        applicationRequests.append(id)
        if suspendsApplicationRequests {
            return try await withCheckedThrowingContinuation { continuation in
                pendingApplicationRequests.append(PendingApplicationRequest(
                    hostID: id,
                    continuation: continuation
                ))
            }
        }
        return applicationsByHost[id] ?? []
    }

    func completeNextApplicationRequest(for hostID: HostID) {
        guard let index = pendingApplicationRequests.firstIndex(where: { $0.hostID == hostID }) else {
            XCTFail("No pending application request for \(hostID)")
            return
        }
        let request = pendingApplicationRequests.remove(at: index)
        request.continuation.resume(returning: applicationsByHost[hostID] ?? [])
    }

    func failNextApplicationRequest(for hostID: HostID, with error: Error) {
        guard let index = pendingApplicationRequests.firstIndex(where: { $0.hostID == hostID }) else {
            XCTFail("No pending application request for \(hostID)")
            return
        }
        pendingApplicationRequests.remove(at: index).continuation.resume(throwing: error)
    }

    func launchApplication(id: ApplicationID, on hostID: HostID, resume: Bool) async throws {
        applicationOperations.append(.launch(hostID: hostID, applicationID: id, resume: resume))
        if suspendsApplicationLaunch {
            try await withCheckedThrowingContinuation { continuation in
                applicationLaunchContinuations.append(continuation)
            }
        }
    }

    func quitApplication(id: ApplicationID, on hostID: HostID) async throws {
        applicationOperations.append(.quit(hostID: hostID, applicationID: id))
    }

    func disconnectSession() async { disconnectCount += 1 }

    func addHost(_ endpoint: HostEndpointInput) async throws -> HostDisplayModel { throw unused() }
    func preparePairing(hostID: HostID) async throws -> PairingPreparation {
        preparePairingRequests.append(hostID)
        let preparation = PairingPreparation(
            pin: preparedPIN,
            provisionalSPKIFingerprint: preparedPIN.count == 6 ? "00112233 44556677" : nil,
            requestedPermissions: [],
            effectivePermissions: []
        )
        guard suspendsPairingPreparation else { return preparation }
        return try await withCheckedThrowingContinuation { continuation in
            pairingPreparationContinuations[hostID] = continuation
        }
    }
    func pairHost(_ request: PairingRequest) async throws -> HostDisplayModel {
        if let pairingError { throw pairingError }
        if suspendsPairing {
            return try await withCheckedThrowingContinuation { continuation in
                pairingContinuations.append(continuation)
            }
        }
        throw unused()
    }

    func completeNextPairing(with host: HostDisplayModel) {
        pairingContinuations.removeFirst().resume(returning: host)
    }

    func completeNextApplicationLaunch() {
        applicationLaunchContinuations.removeFirst().resume(returning: ())
    }
    func cancelPairing(hostID: HostID) async {
        cancelPairingRequests.append(hostID)
        pairingPreparationContinuations.removeValue(forKey: hostID)?.resume(throwing: CancellationError())
    }
    func renameHost(id: HostID, name: String) async throws -> HostDisplayModel { throw unused() }
    func deleteHost(id: HostID) async throws { throw unused() }
    func wakeHost(id: HostID) async throws -> HostDisplayModel { throw unused() }
    func testNetwork(for id: HostID) async throws -> NetworkTestOutcome { throw unused() }
    func setApplicationHidden(id: ApplicationID, on hostID: HostID, hidden: Bool) async throws { throw unused() }
    func setDirectLaunch(id: ApplicationID, on hostID: HostID, enabled: Bool) async throws { throw unused() }

    private func unused() -> UmbraClientServiceError {
        .unavailable("Unexpected test service call")
    }
}

private struct PendingApplicationRequest {
    let hostID: HostID
    let continuation: CheckedContinuation<[ApplicationDisplayModel], any Error>
}

private func makeHost(
    id: String,
    hasActiveSession: Bool = false,
    runningApplicationID: ApplicationID? = nil
) -> HostDisplayModel {
    HostDisplayModel(
        id: HostID(id),
        name: id.capitalized,
        status: .online,
        isPaired: true,
        hasActiveSession: hasActiveSession || runningApplicationID != nil,
        runningApplicationID: runningApplicationID,
        canWake: false,
        isServerSupported: true,
        details: ""
    )
}

private func makeApplication(
    id: Int,
    hostID: HostID,
    name: String,
    isRunning: Bool = false,
    isHidden: Bool = false,
    isDirectLaunch: Bool = false
) -> ApplicationDisplayModel {
    ApplicationDisplayModel(
        id: ApplicationID(id),
        hostID: hostID,
        name: name,
        artworkURL: nil,
        isRunning: isRunning,
        isHidden: isHidden,
        isDirectLaunch: isDirectLaunch
    )
}
