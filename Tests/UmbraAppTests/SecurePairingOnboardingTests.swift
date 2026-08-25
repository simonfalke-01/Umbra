import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI
import XCTest
@testable import UmbraApp

@MainActor
final class SecurePairingOnboardingTests: XCTestCase {
    func testInvalidInvitationIsRejectedBeforeServiceMutationAndDraftRemainsAvailable() {
        let service = SecurePairingServiceSpy()
        let store = AppStore(service: service)
        let draft = "not-an-invitation"

        store.showSecurePairing(invitationURI: draft)
        store.pairSecureHost(invitationURI: draft)

        XCTAssertEqual(store.presentedSheet, .addHost)
        XCTAssertEqual(store.pendingSecureInvitation, draft)
        XCTAssertEqual(service.invitations, [])
        XCTAssertEqual(
            store.securePairingError,
            "Paste the full Lumen invitation beginning with umbra://pair/v3#."
        )
    }

    func testValidInvitationUsesSecureServiceAndClosesOnlyAfterConfirmedSuccess() async {
        let pairedHost = HostDisplayModel(
            id: HostID("v3:paired"),
            name: "Gaming PC",
            status: .online,
            isPaired: true,
            hasActiveSession: false,
            canWake: false,
            isServerSupported: true,
            details: ""
        )
        let service = SecurePairingServiceSpy(result: .success(pairedHost), suspends: true)
        let store = AppStore(service: service)
        let invitation = makeCurrentInvitationURI()

        store.showSecurePairing(invitationURI: invitation)
        store.pairSecureHost(invitationURI: invitation)
        await waitUntil { service.invitations == [invitation] }

        XCTAssertEqual(store.presentedSheet, .addHost)
        XCTAssertEqual(store.operation?.kind, .pairing)

        service.completePairing()
        await waitUntil { store.operation == nil }

        XCTAssertNil(store.presentedSheet)
        XCTAssertNil(store.securePairingError)
        XCTAssertEqual(store.hosts, [pairedHost])
    }

    func testRecoverableSecurePairingFailureKeepsSheetAndInvitation() async {
        let service = SecurePairingServiceSpy(
            result: .failure(UmbraClientServiceError.unavailable("transport detail"))
        )
        let store = AppStore(service: service)
        let invitation = makeCurrentInvitationURI()

        store.showSecurePairing(invitationURI: invitation)
        store.pairSecureHost(invitationURI: invitation)
        await waitUntil { store.operation == nil && store.securePairingError != nil }

        XCTAssertEqual(store.presentedSheet, .addHost)
        XCTAssertEqual(store.pendingSecureInvitation, invitation)
        XCTAssertEqual(service.invitations, [invitation])
        XCTAssertEqual(
            store.securePairingError,
            "Umbra couldn’t complete secure pairing. Check that Lumen is running, then generate a new invitation and try again."
        )
    }

    func testNewerSecurePairingSuccessRejectsOlderFailureCompletedLast() async {
        let service = SecurePairingServiceSpy(suspends: true)
        let store = AppStore(service: service)
        let firstInvitation = makeCurrentInvitationURI(marker: 0xA1)
        let secondInvitation = makeCurrentInvitationURI(marker: 0xA2)
        let secondHost = pairedHost(id: "v3:second")

        store.showSecurePairing(invitationURI: firstInvitation)
        store.pairSecureHost(invitationURI: firstInvitation)
        await waitUntil { service.pendingPairingCount == 1 }

        store.showSecurePairing(invitationURI: secondInvitation)
        store.pairSecureHost(invitationURI: secondInvitation)
        await waitUntil { service.pendingPairingCount == 2 }

        service.completePairing(
            at: 1,
            with: .success(secondHost)
        )
        await waitUntil { store.operation == nil && store.hosts == [secondHost] }
        service.completePairing(
            at: 0,
            with: .failure(UmbraClientServiceError.unavailable("stale failure"))
        )
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.hosts, [secondHost])
        XCTAssertNil(store.securePairingError)
        XCTAssertNil(store.presentedSheet)
    }

    func testNewerSecurePairingFailureRejectsOlderSuccessCompletedLast() async {
        let service = SecurePairingServiceSpy(suspends: true)
        let store = AppStore(service: service)
        let firstInvitation = makeCurrentInvitationURI(marker: 0xA3)
        let secondInvitation = makeCurrentInvitationURI(marker: 0xA4)

        store.showSecurePairing(invitationURI: firstInvitation)
        store.pairSecureHost(invitationURI: firstInvitation)
        await waitUntil { service.pendingPairingCount == 1 }

        store.showSecurePairing(invitationURI: secondInvitation)
        store.pairSecureHost(invitationURI: secondInvitation)
        await waitUntil { service.pendingPairingCount == 2 }

        service.completePairing(
            at: 1,
            with: .failure(UmbraClientServiceError.unavailable("latest failure"))
        )
        await waitUntil { store.operation == nil && store.securePairingError != nil }
        service.completePairing(at: 0, with: .success(pairedHost(id: "v3:stale")))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.hosts, [])
        XCTAssertEqual(store.pendingSecureInvitation, secondInvitation)
        XCTAssertEqual(store.presentedSheet, .addHost)
        XCTAssertEqual(
            store.securePairingError,
            "Umbra couldn’t complete secure pairing. Check that Lumen is running, then generate a new invitation and try again."
        )
    }

    func testInvalidManualPairPreservesValidInFlightPairing() async {
        let service = SecurePairingServiceSpy(suspends: true)
        let store = AppStore(service: service)
        let validInvitation = makeCurrentInvitationURI(marker: 0xA9)
        let paired = pairedHost(id: "v3:valid-in-flight")

        store.showSecurePairing(invitationURI: validInvitation)
        store.pairSecureHost(invitationURI: validInvitation)
        await waitUntil { service.pendingPairingCount == 1 }

        store.pairSecureHost(invitationURI: "malformed manual invitation")

        XCTAssertEqual(store.operation?.kind, .pairing)
        XCTAssertEqual(store.pendingSecureInvitation, "malformed manual invitation")
        XCTAssertEqual(
            store.securePairingError,
            "Paste the full Lumen invitation beginning with umbra://pair/v3#."
        )

        service.completePairing(at: 0, with: .success(paired))
        await waitUntil { store.operation == nil && store.hosts == [paired] }
        XCTAssertNil(store.presentedSheet)
        XCTAssertNil(store.securePairingError)
    }

    func testMalformedDeepLinkPreservesValidInFlightPairing() async {
        let service = SecurePairingServiceSpy(suspends: true)
        let store = AppStore(service: service)
        let validInvitation = makeCurrentInvitationURI(marker: 0xAA)
        let malformedReplacement = "umbra://pair/v3#damaged"
        let paired = pairedHost(id: "v3:deep-link-in-flight")

        store.showSecurePairing(invitationURI: validInvitation)
        store.pairSecureHost(invitationURI: validInvitation)
        await waitUntil { service.pendingPairingCount == 1 }
        let hostingView = NSHostingView(rootView: AddHostSheet(store: store))
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        hostingView.layoutSubtreeIfNeeded()

        store.showSecurePairing(invitationURI: malformedReplacement)

        XCTAssertEqual(store.operation?.kind, .pairing)
        XCTAssertEqual(store.pendingSecureInvitation, malformedReplacement)
        XCTAssertNotNil(store.securePairingError)
        XCTAssertEqual(store.presentedSheet, .addHost)
        guard let expectedError = store.securePairingError else {
            return XCTFail("Malformed deep link did not produce an error")
        }
        for _ in 0..<10 { await Task.yield() }
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let renderedValues = findSubviews(of: NSTextField.self, in: hostingView).map(\.stringValue)
        XCTAssertTrue(
            renderedValues.contains(malformedReplacement),
            "Rendered values: \(renderedValues)"
        )
        XCTAssertEqual(store.operation?.kind, .pairing)
        XCTAssertEqual(store.securePairingError, expectedError)

        service.completePairing(at: 0, with: .success(paired))
        await waitUntil { store.operation == nil && store.hosts == [paired] }
        XCTAssertNil(store.presentedSheet)
        XCTAssertNil(store.securePairingError)
    }

    func testMalformedDeepLinkDoesNotCancelUnrelatedActiveOperation() async {
        let addedHost = pairedHost(id: "manually-added")
        let service = SecurePairingServiceSpy(
            suspendsAddHost: true,
            addedHost: addedHost
        )
        let store = AppStore(service: service)
        let malformedReplacement = "umbra://pair/v3#not-valid"

        store.addHost(address: "gaming-pc.local", portText: "")
        await waitUntil { service.pendingAddHostCount == 1 }
        XCTAssertEqual(store.operation?.kind, .addingHost)

        store.showSecurePairing(invitationURI: malformedReplacement)

        XCTAssertEqual(store.operation?.kind, .addingHost)
        XCTAssertEqual(store.pendingSecureInvitation, malformedReplacement)
        XCTAssertNotNil(store.securePairingError)
        XCTAssertEqual(store.presentedSheet, .addHost)

        service.completeAddHost()
        await waitUntil { store.operation == nil && store.hosts == [addedHost] }
        XCTAssertEqual(store.hosts, [addedHost])
    }

    func testReplacementDeepLinkUpdatesAlreadyOpenAddHostSheet() async {
        let store = AppStore(service: SecurePairingServiceSpy())
        let firstInvitation = makeCurrentInvitationURI(marker: 0xA5)
        let secondInvitation = makeCurrentInvitationURI(marker: 0xA6)
        store.showSecurePairing(invitationURI: firstInvitation)

        let hostingView = NSHostingView(rootView: AddHostSheet(store: store))
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            findSubviews(of: NSTextField.self, in: hostingView)
                .contains(where: { $0.stringValue == firstInvitation })
        )

        store.showSecurePairing(invitationURI: secondInvitation)
        await waitUntil {
            hostingView.layoutSubtreeIfNeeded()
            return findSubviews(of: NSTextField.self, in: hostingView)
                .contains(where: { $0.stringValue == secondInvitation })
        }

        let values = findSubviews(of: NSTextField.self, in: hostingView).map(\.stringValue)
        XCTAssertTrue(values.contains(secondInvitation))
        XCTAssertFalse(values.contains(firstInvitation))
    }

    func testReplacementDeepLinkSupersedesInFlightPairingBeforeRetry() async {
        let service = SecurePairingServiceSpy(suspends: true)
        let store = AppStore(service: service)
        let firstInvitation = makeCurrentInvitationURI(marker: 0xA7)
        let replacementInvitation = makeCurrentInvitationURI(marker: 0xA8)

        store.showSecurePairing(invitationURI: firstInvitation)
        store.pairSecureHost(invitationURI: firstInvitation)
        await waitUntil { service.pendingPairingCount == 1 }

        store.showSecurePairing(invitationURI: replacementInvitation)
        service.completePairing(at: 0, with: .success(pairedHost(id: "v3:superseded")))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.pendingSecureInvitation, replacementInvitation)
        XCTAssertEqual(store.presentedSheet, .addHost)
        XCTAssertNil(store.operation)
        XCTAssertEqual(store.hosts, [])
        XCTAssertNil(store.securePairingError)
    }

    func testLatestInvitationImportWinsWhenOlderCompletionArrivesLast() async {
        let loader = ControlledInvitationLoader()
        let coordinator = SecurePairingInvitationImportCoordinator { url in
            try await loader.load(url)
        }
        let firstURL = URL(fileURLWithPath: "/tmp/umbra-first-invitation.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/umbra-second-invitation.txt")

        coordinator.start(url: firstURL)
        await waitUntilAsync { await loader.pendingCount == 1 }
        coordinator.start(url: secondURL)
        await waitUntilAsync { await loader.pendingCount == 2 }

        await loader.succeed(secondURL, value: "second")
        await waitUntil { coordinator.completion?.outcome == .success("second") }
        let latestCompletion = coordinator.completion
        await loader.fail(firstURL)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(coordinator.completion, latestCompletion)
    }

    func testDismissedInvitationImportCannotPublishLateCompletion() async {
        let loader = ControlledInvitationLoader()
        let coordinator = SecurePairingInvitationImportCoordinator { url in
            try await loader.load(url)
        }
        let url = URL(fileURLWithPath: "/tmp/umbra-dismissed-invitation.txt")

        coordinator.start(url: url)
        await waitUntilAsync { await loader.pendingCount == 1 }
        coordinator.invalidate()
        await loader.succeed(url, value: "late")
        for _ in 0..<10 { await Task.yield() }

        XCTAssertNil(coordinator.completion)
    }

    func testSecurePairingSheetRendersPrefilledErrorStateWithoutClipping() throws {
        let service = SecurePairingServiceSpy()
        let store = AppStore(service: service)
        store.showSecurePairing(invitationURI: "damaged invitation")
        store.pairSecureHost(invitationURI: store.pendingSecureInvitation)

        let hostingView = NSHostingView(rootView: ZStack {
            Color(nsColor: .windowBackgroundColor)
            AddHostSheet(store: store)
        }
        .environment(\.colorScheme, .light))
        hostingView.appearance = NSAppearance(named: .aqua)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(
            origin: .zero,
            size: CGSize(width: max(520, fittingSize.width), height: max(280, fittingSize.height))
        )
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let labels = findSubviews(of: NSTextField.self, in: hostingView).map(\.stringValue)
        XCTAssertTrue(labels.contains(store.pendingSecureInvitation))
        XCTAssertGreaterThanOrEqual(hostingView.bounds.width, 520)
        XCTAssertGreaterThanOrEqual(hostingView.bounds.height, 280)

        if let output = ProcessInfo.processInfo.environment["UMBRA_PAIRING_SNAPSHOT_PATH"] {
            let representation = try XCTUnwrap(
                hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
            )
            hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
            let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    func testSecurePairingSheetVisualStateMatrix() async throws {
        let invitation = makeCurrentInvitationURI()

        let defaultStore = AppStore(service: SecurePairingServiceSpy())
        defaultStore.showAddHost()
        let defaultPNG = try renderPairingSheet(
            store: defaultStore,
            colorScheme: .light,
            appearance: .aqua,
            outputName: "default-light"
        )

        let prefilledStore = AppStore(service: SecurePairingServiceSpy())
        prefilledStore.showSecurePairing(invitationURI: invitation)
        let prefilledPNG = try renderPairingSheet(
            store: prefilledStore,
            colorScheme: .light,
            appearance: .aqua,
            outputName: "prefilled-light"
        )

        let progressService = SecurePairingServiceSpy(
            result: .failure(UmbraClientServiceError.unavailable("cancelled by test")),
            suspends: true
        )
        let progressStore = AppStore(service: progressService)
        progressStore.showSecurePairing(invitationURI: invitation)
        progressStore.pairSecureHost(invitationURI: invitation)
        await waitUntil {
            progressStore.operation?.kind == .pairing
                && progressService.invitations == [invitation]
        }
        let progressPNG = try renderPairingSheet(
            store: progressStore,
            colorScheme: .light,
            appearance: .aqua,
            outputName: "progress-light"
        )
        progressStore.cancelCurrentOperation()
        progressService.completePairing()
        await waitUntil { progressStore.operation == nil }

        let failureStore = AppStore(service: SecurePairingServiceSpy(
            result: .failure(UmbraClientServiceError.unavailable("transport detail"))
        ))
        failureStore.showSecurePairing(invitationURI: invitation)
        failureStore.pairSecureHost(invitationURI: invitation)
        await waitUntil { failureStore.operation == nil && failureStore.securePairingError != nil }
        let failurePNG = try renderPairingSheet(
            store: failureStore,
            colorScheme: .dark,
            appearance: .darkAqua,
            outputName: "failure-dark"
        )

        XCTAssertEqual(Set([defaultPNG, prefilledPNG, progressPNG, failurePNG]).count, 4)
    }

    func testNativeQRCodeImageImportExtractsLumenInvitation() async throws {
        let invitation = makeCurrentInvitationURI()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("invitation.png")

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(invitation.utf8)
        filter.correctionLevel = "M"
        let image = try XCTUnwrap(filter.outputImage).transformed(
            by: CGAffineTransform(scaleX: 6, y: 6)
        )
        try CIContext().writePNGRepresentation(
            of: image,
            to: imageURL,
            format: .RGBA8,
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        )

        let imported = try await SecurePairingInvitationImporter.load(from: imageURL)
        XCTAssertEqual(imported, invitation)
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

    private func waitUntilAsync(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not satisfied", file: file, line: line)
    }

    private func renderPairingSheet(
        store: AppStore,
        colorScheme: ColorScheme,
        appearance: NSAppearance.Name,
        outputName: String
    ) throws -> Data {
        let hostingView = NSHostingView(rootView: ZStack {
            Color(nsColor: .windowBackgroundColor)
            AddHostSheet(store: store)
        }
        .environment(\.colorScheme, colorScheme))
        hostingView.appearance = NSAppearance(named: appearance)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(
            origin: .zero,
            size: CGSize(width: max(520, fittingSize.width), height: max(280, fittingSize.height))
        )
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        if let directory = ProcessInfo.processInfo.environment["UMBRA_PAIRING_SNAPSHOT_DIRECTORY"] {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                withIntermediateDirectories: true
            )
            try png.write(
                to: URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("pairing-\(outputName).png"),
                options: .atomic
            )
        }
        return png
    }
}

@MainActor
private func findSubviews<ViewType: NSView>(
    of type: ViewType.Type,
    in root: NSView
) -> [ViewType] {
    var result: [ViewType] = []
    if let typedRoot = root as? ViewType {
        result.append(typedRoot)
    }
    for child in root.subviews {
        result.append(contentsOf: findSubviews(of: type, in: child))
    }
    return result
}

@MainActor
private final class SecurePairingServiceSpy: UmbraClientServicing {
    private let result: Result<HostDisplayModel, Error>
    private let suspends: Bool
    private let suspendsAddHost: Bool
    private let addedHost: HostDisplayModel?
    private var continuations: [CheckedContinuation<HostDisplayModel, Error>] = []
    private var addHostContinuations: [CheckedContinuation<HostDisplayModel, Error>] = []
    private(set) var invitations: [String] = []
    var pendingPairingCount: Int { continuations.count }
    var pendingAddHostCount: Int { addHostContinuations.count }

    init(
        result: Result<HostDisplayModel, Error> = .failure(
            UmbraClientServiceError.unavailable("unused")
        ),
        suspends: Bool = false,
        suspendsAddHost: Bool = false,
        addedHost: HostDisplayModel? = nil
    ) {
        self.result = result
        self.suspends = suspends
        self.suspendsAddHost = suspendsAddHost
        self.addedHost = addedHost
    }

    func pairSecureHost(invitationURI: String) async throws -> HostDisplayModel {
        invitations.append(invitationURI)
        if suspends {
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        return try result.get()
    }

    func completePairing() {
        guard !continuations.isEmpty else {
            XCTFail("No secure pairing is pending")
            return
        }
        continuations.removeFirst().resume(with: result)
    }

    func completePairing(
        at index: Int,
        with result: Result<HostDisplayModel, Error>
    ) {
        guard continuations.indices.contains(index) else {
            XCTFail("No secure pairing is pending at index \(index)")
            return
        }
        continuations.remove(at: index).resume(with: result)
    }

    func completeAddHost() {
        guard !addHostContinuations.isEmpty, let addedHost else {
            XCTFail("No Add Host operation is pending")
            return
        }
        addHostContinuations.removeFirst().resume(returning: addedHost)
    }

    func setEventHandler(_ handler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?) {}
    func discoverHosts() async throws -> [HostDisplayModel] { [] }
    func addHost(_ endpoint: HostEndpointInput) async throws -> HostDisplayModel {
        guard suspendsAddHost else { throw unused() }
        return try await withCheckedThrowingContinuation { addHostContinuations.append($0) }
    }
    func pairHost(_ request: PairingRequest) async throws -> HostDisplayModel { throw unused() }
    func cancelPairing(hostID: HostID) async {}
    func renameHost(id: HostID, name: String) async throws -> HostDisplayModel { throw unused() }
    func deleteHost(id: HostID) async throws { throw unused() }
    func wakeHost(id: HostID) async throws -> HostDisplayModel { throw unused() }
    func testNetwork(for id: HostID) async throws -> NetworkTestOutcome { throw unused() }
    func applications(for id: HostID, includeHidden: Bool) async throws -> [ApplicationDisplayModel] { throw unused() }
    func launchApplication(id: ApplicationID, on hostID: HostID, resume: Bool) async throws { throw unused() }
    func quitApplication(id: ApplicationID, on hostID: HostID) async throws { throw unused() }
    func setApplicationHidden(id: ApplicationID, on hostID: HostID, hidden: Bool) async throws { throw unused() }
    func setDirectLaunch(id: ApplicationID, on hostID: HostID, enabled: Bool) async throws { throw unused() }

    private func unused() -> UmbraClientServiceError {
        .unavailable("Unexpected test service call")
    }
}

private func makeCurrentInvitationURI(
    now: UInt64 = UInt64(Date().timeIntervalSince1970),
    marker: UInt8? = nil
) -> String {
    var bytes = Data(hexadecimal: invitationHex)
    if let marker {
        bytes[32] = marker
    }
    bytes.replaceSubrange(144..<152, with: now.bigEndianBytes)
    bytes.replaceSubrange(152..<160, with: (now + 300).bigEndianBytes)
    let fragment = bytes.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "umbra://pair/v3#\(fragment)"
}

private func pairedHost(id: String) -> HostDisplayModel {
    HostDisplayModel(
        id: HostID(id),
        name: id,
        status: .online,
        isPaired: true,
        hasActiveSession: false,
        canWake: false,
        isServerSupported: true,
        details: ""
    )
}

private actor ControlledInvitationLoader {
    private struct Pending {
        let url: URL
        let continuation: CheckedContinuation<String, Error>
    }

    private var pending: [Pending] = []

    var pendingCount: Int { pending.count }

    func load(_ url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(url: url, continuation: continuation))
        }
    }

    func succeed(_ url: URL, value: String) {
        guard let index = pending.firstIndex(where: { $0.url == url }) else {
            XCTFail("No pending import for \(url)")
            return
        }
        pending.remove(at: index).continuation.resume(returning: value)
    }

    func fail(_ url: URL) {
        guard let index = pending.firstIndex(where: { $0.url == url }) else {
            XCTFail("No pending import for \(url)")
            return
        }
        pending.remove(at: index).continuation.resume(throwing: InvitationImportTestError.failed)
    }
}

private enum InvitationImportTestError: LocalizedError {
    case failed

    var errorDescription: String? { "Import failed." }
}

private extension Data {
    init(hexadecimal: String) {
        self.init()
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let end = hexadecimal.index(index, offsetBy: 2)
            append(UInt8(hexadecimal[index..<end], radix: 16)!)
            index = end
        }
    }
}

private extension UInt64 {
    var bigEndianBytes: Data {
        var value = bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private let invitationHex = "554c4933010000ac00babb9e00030003000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf24f6ed6acbfe1009c030d7ca567c33ca808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7000000006553f100000000006553f22c000000000000017f000e0000766563746f722e6578616d706c65"
