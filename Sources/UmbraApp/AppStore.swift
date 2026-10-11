import Combine
import Foundation
import UmbraCore
import UmbraServices

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var hostsState: LoadingState<[HostDisplayModel]> = .idle
    @Published private(set) var applicationsState: LoadingState<[ApplicationDisplayModel]> = .idle
    @Published var focusedHostID: HostID?
    @Published var selectedHostID: HostID?
    @Published var showHiddenApplications = false {
        didSet { reconcileApplicationBrowserContext() }
    }
    @Published var applicationFilter = "" {
        didSet { reconcileApplicationBrowserContext() }
    }
    @Published var selectedApplicationID: ApplicationID?
    @Published var applicationScrollPositionID: ApplicationID?
    @Published var presentedSheet: PresentedSheet?
    @Published var confirmation: PresentedConfirmation?
    @Published var failure: PresentedFailure?
    @Published private(set) var applicationCatalogWarning: String?
    @Published private(set) var sessionDegradation: String?
    @Published private(set) var operation: OperationPresentation?
    @Published private(set) var pairingPreparations: [HostID: PairingPreparation] = [:]

    let preferences: PreferencesStore

    private let service: UmbraClientServicing
    private var activeTask: Task<Void, Never>?
    private var sessionDisconnectTask: Task<Void, Never>?
    private var applicationCatalogTask: Task<Void, Never>?
    private var nextApplicationCatalogRequestToken: UInt64 = 0
    private var currentApplicationCatalogRequest: ApplicationCatalogRequest?
    private var applicationMutationTasks: [UInt64: Task<Void, Never>] = [:]
    private var nextApplicationMutationToken: UInt64 = 0
    private var applicationMutationQueues: [ApplicationMutationKey: ApplicationMutationQueue] = [:]
    private var streamingBrowserContext: ApplicationBrowserContext?
    private var nextOperationToken: UInt64 = 0
    private var currentOperationToken: UInt64?
    private var activationInFlight: ApplicationActivationReservation?
    private var hasObservedSessionLifecycleEvent = false
    private var hasReachedStreamingState = false
    private var pairingPreparationReservation: (id: UUID, hostID: HostID)?

    init(
        service: UmbraClientServicing,
        preferences: PreferencesStore = PreferencesStore()
    ) {
        self.service = service
        self.preferences = preferences
        service.setEventHandler { [weak self] event in self?.handle(event) }
    }

    var hosts: [HostDisplayModel] {
        guard case let .loaded(hosts) = hostsState else { return [] }
        return hosts
    }

    var applications: [ApplicationDisplayModel] {
        guard case let .loaded(applications) = applicationsState else { return [] }
        return applications
    }

    var visibleApplications: [ApplicationDisplayModel] {
        let filter = applicationFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return applications.filter { application in
            guard filter.isEmpty || application.name.localizedCaseInsensitiveContains(filter)
            else { return false }
            if application.isRunning { return true }
            guard showHiddenApplications || !application.isHidden else { return false }
            return true
        }
    }

    var selectedHost: HostDisplayModel? {
        guard let selectedHostID else { return nil }
        return host(id: selectedHostID)
    }

    var focusedHost: HostDisplayModel? {
        guard let focusedHostID else { return nil }
        return host(id: focusedHostID)
    }

    var selectedVisibleApplication: ApplicationDisplayModel? {
        guard let selectedApplicationID else { return nil }
        return visibleApplications.first { $0.id == selectedApplicationID }
    }

    func start() {
        guard case .idle = hostsState else { return }
        refreshHosts()
    }

    func refreshHosts() {
        activeTask?.cancel()
        if hosts.isEmpty {
            hostsState = .loading
        }

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hosts = try await service.discoverHosts()
                try Task.checkCancellation()
                hostsState = .loaded(hosts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            } catch is CancellationError {
                return
            } catch {
                if hosts.isEmpty {
                    hostsState = .failed(message: error.localizedDescription)
                } else {
                    presentFailure(title: "Couldn’t Refresh Hosts", error: error)
                }
            }
        }
    }

    func showAddHost() {
        presentedSheet = .addHost
    }

    func addHost(address: String, portText: String) {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            failure = PresentedFailure(title: "Address Required", message: "Enter the host name or IP address to add.")
            return
        }

        let port: Int?
        if portText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            port = nil
        } else if let parsedPort = Int(portText), (1...65_535).contains(parsedPort) {
            port = parsedPort
        } else {
            failure = PresentedFailure(title: "Invalid Port", message: "Enter a port between 1 and 65535, or leave the port blank to use the default.")
            return
        }

        presentedSheet = nil
        let operationToken = beginOperation(OperationPresentation(
            kind: .addingHost,
            title: "Connecting to Host",
            message: "Contacting \(trimmedAddress)...",
            progress: nil,
            isCancellable: true
        ))

        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(operationToken) }
            do {
                let host = try await service.addHost(.init(address: trimmedAddress, port: port))
                try Task.checkCancellation()
                upsert(host)
            } catch is CancellationError {
                return
            } catch {
                presentFailure(title: "Couldn’t Add Host", error: error, ownedBy: operationToken)
            }
        }
    }

    func activate(_ host: HostDisplayModel) {
        guard let action = HostBrowserPresentation(host: host).defaultAction else {
            return
        }
        performHostBrowserAction(action, for: host)
    }

    func performHostBrowserAction(
        _ action: HostBrowserActionDescriptor,
        for host: HostDisplayModel
    ) {
        let currentHost = self.host(id: host.id) ?? host
        let availableActions = HostBrowserPresentation(host: currentHost)
            .actionGroups
            .flatMap(\.actions)
        guard availableActions.contains(where: { $0.kind == action.kind }) else {
            return
        }

        switch action.kind {
        case .openApplications:
            openApplications(for: currentHost)
        case .pair:
            beginPairing(currentHost)
        case .wake:
            wake(currentHost)
        case .details:
            presentedSheet = .details(currentHost.id)
        case .testNetwork:
            testNetwork(currentHost)
        case .rename:
            presentedSheet = .rename(currentHost.id)
        case .remove:
            requestDelete(currentHost)
        }
    }

    func beginPairing(_ host: HostDisplayModel) {
        if !host.id.rawValue.hasPrefix("lsp:") {
            let prior = pairingPreparationReservation
            pairingPreparationReservation = nil
            activeTask?.cancel()
            if let prior {
                Task { await service.cancelPairing(hostID: prior.hostID) }
            }
            let pin = String(format: "%04d", Int.random(in: 0...9_999))
            pairingPreparations[host.id] = .init(
                pin: pin,
                provisionalSPKIFingerprint: nil,
                requestedPermissions: [],
                effectivePermissions: []
            )
            presentedSheet = .pair(host.id, pin: pin)
            return
        }
        let prior = pairingPreparationReservation
        let reservationID = UUID()
        pairingPreparationReservation = (reservationID, host.id)
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let prior {
                    await service.cancelPairing(hostID: prior.hostID)
                }
                let preparation = try await service.preparePairing(hostID: host.id)
                try Task.checkCancellation()
                guard pairingPreparationReservation?.id == reservationID else {
                    throw CancellationError()
                }
                guard preparation.pin.count == 6, preparation.pin.allSatisfy(\.isNumber),
                      preparation.provisionalSPKIFingerprint?.isEmpty == false else {
                    throw UmbraClientServiceError.unavailable("The native LSP core returned an invalid pairing PIN.")
                }
                pairingPreparationReservation = nil
                pairingPreparations[host.id] = preparation
                presentedSheet = .pair(host.id, pin: preparation.pin)
            } catch {
                let ownsReservation = pairingPreparationReservation?.id == reservationID
                if ownsReservation {
                    pairingPreparationReservation = nil
                    await service.cancelPairing(hostID: host.id)
                }
                guard !(error is CancellationError), !Task.isCancelled else { return }
                presentFailure(title: "Pairing Failed", error: error)
            }
        }
    }

    func performPairing(hostID: HostID, pin: String) {
        let isLSP = hostID.rawValue.hasPrefix("lsp:")
        let operationToken = beginOperation(OperationPresentation(
            kind: .pairing,
            title: "Pairing with Host",
            message: isLSP
                ? "Enter \(pin) in the Lumen admin panel. This window closes after Lumen confirms pairing."
                : "Enter \(pin) on the host. This window closes after the host confirms pairing.",
            progress: nil,
            isCancellable: true
        ))

        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(operationToken) }
            do {
                let host = try await service.pairHost(.init(hostID: hostID, pin: pin))
                try Task.checkCancellation()
                upsert(host)
                pairingPreparations.removeValue(forKey: hostID)
                presentedSheet = nil
            } catch {
                if error is CancellationError
                    || (error as? UmbraServiceError) == .cancelled
                    || Task.isCancelled {
                    return
                }
                presentFailure(title: "Pairing Failed", error: error, ownedBy: operationToken)
            }
        }
    }

    func cancelCurrentOperation() {
        let pairingHostID: HostID?
        if case let .pair(hostID, _) = presentedSheet {
            pairingHostID = hostID
        } else {
            pairingHostID = pairingPreparationReservation?.hostID
        }
        pairingPreparationReservation = nil
        let wasActivatingApplication = activationInFlight != nil
        activeTask?.cancel()
        activeTask = nil
        activationInFlight = nil
        invalidateCurrentOperation()
        if wasActivatingApplication {
            restoreApplicationBrowserContext()
            sessionDisconnectTask = Task { await service.disconnectSession() }
        }
        if let pairingHostID {
            pairingPreparations.removeValue(forKey: pairingHostID)
            Task { await service.cancelPairing(hostID: pairingHostID) }
        }
    }

    func openApplications(for host: HostDisplayModel) {
        if selectedHostID != host.id {
            activeTask?.cancel()
            activeTask = nil
            invalidateApplicationMutations()
            activationInFlight = nil
            invalidateCurrentOperation()
            resetApplicationBrowserContext()
        }
        selectedHostID = host.id
        applicationsState = .loading
        loadApplications(allowDirectLaunch: true)
    }

    func closeApplications() {
        activeTask?.cancel()
        cancelApplicationCatalogRequest()
        invalidateApplicationMutations()
        selectedHostID = nil
        applicationCatalogWarning = nil
        applicationsState = .idle
        resetApplicationBrowserContext()
    }

    func loadApplications() {
        loadApplications(allowDirectLaunch: false)
    }

    func dismissApplicationCatalogWarning() {
        applicationCatalogWarning = nil
    }

    private func loadApplications(allowDirectLaunch: Bool) {
        guard let hostID = selectedHostID else { return }
        applicationCatalogTask?.cancel()
        nextApplicationCatalogRequestToken &+= 1
        let request = ApplicationCatalogRequest(
            hostID: hostID,
            token: nextApplicationCatalogRequestToken
        )
        currentApplicationCatalogRequest = request
        applicationCatalogWarning = nil
        if applications.isEmpty {
            applicationsState = .loading
        }

        applicationCatalogTask = Task { [weak self] in
            guard let self else { return }
            defer { finishApplicationCatalogRequest(request) }
            do {
                let apps = try await service.applications(for: request.hostID, includeHidden: true)
                try Task.checkCancellation()
                guard ownsApplicationCatalogRequest(request) else { return }
                var sortedApps = apps.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                applyPendingApplicationMutations(to: &sortedApps, on: request.hostID)
                applicationsState = .loaded(sortedApps)
                reconcileApplicationBrowserContext()

                if allowDirectLaunch,
                   !showHiddenApplications,
                   !apps.contains(where: \.isRunning),
                   let directLaunch = apps.first(where: { $0.isDirectLaunch && !$0.isHidden }) {
                    launch(directLaunch)
                }
            } catch is CancellationError {
                return
            } catch {
                guard ownsApplicationCatalogRequest(request) else { return }
                applicationsState = .failed(message: error.localizedDescription)
            }
        }
    }

    func launch(_ application: ApplicationDisplayModel) {
        guard let hostID = selectedHostID else { return }
        guard activationInFlight == nil else { return }
        guard application.hostID == hostID else { return }
        guard let currentApplication = self.application(id: application.id) else { return }
        guard currentApplication.hostID == hostID else { return }
        guard visibleApplications.contains(where: { $0.id == currentApplication.id }) else { return }
        selectedApplicationID = currentApplication.id
        if let running = applications.first(where: \.isRunning), running.id != currentApplication.id {
            confirmation = .replaceRunningApplication(current: running.id, next: currentApplication.id)
            return
        }
        connect(to: currentApplication, on: hostID)
    }

    private func connect(
        to application: ApplicationDisplayModel,
        on hostID: HostID,
        resumeOverride: Bool? = nil,
        isRecovery: Bool = false
    ) {
        guard activationInFlight == nil else { return }
        guard selectedHostID == hostID, application.hostID == hostID else { return }
        let resume = resumeOverride ?? application.isRunning
        let activationUptime = ProcessInfo.processInfo.systemUptime
        let operationToken = beginOperation(OperationPresentation(
            kind: .connecting,
            title: isRecovery
                ? "Reconnecting to \(application.name)"
                : (resume ? "Resuming \(application.name)" : "Launching \(application.name)"),
            message: "Negotiating a secure streaming session with the host...",
            progress: nil,
            isCancellable: true
        ))
        let activation = ApplicationActivationReservation(
            hostID: hostID,
            applicationID: application.id,
            operationToken: operationToken
        )
        activationInFlight = activation
        hasObservedSessionLifecycleEvent = false
        hasReachedStreamingState = false
        sessionDegradation = nil
        preserveApplicationBrowserContext(for: hostID)
        activeTask = Task { [weak self] in
            guard let self else { return }
            var lifecycleOwnsOperation = false
            defer {
                if !lifecycleOwnsOperation {
                    finishActivation(activation)
                    finishOperation(operationToken)
                }
            }
            do {
                if let sessionDisconnectTask {
                    await sessionDisconnectTask.value
                    try Task.checkCancellation()
                    guard activationInFlight == activation else { return }
                }
                try await service.launchApplication(
                    id: application.id,
                    on: hostID,
                    resume: resume,
                    activationUptime: activationUptime
                )
                try Task.checkCancellation()
                guard selectedHostID == hostID else { return }
                guard activationInFlight == activation || hasReachedStreamingState else { return }
                markRunning(application.id)
                lifecycleOwnsOperation = hasObservedSessionLifecycleEvent
            } catch is CancellationError {
                restoreApplicationBrowserContext(ownedBy: activation)
                return
            } catch {
                restoreApplicationBrowserContext(ownedBy: activation)
                presentFailure(
                    title: isRecovery
                        ? "Couldn’t Reconnect"
                        : (resume ? "Couldn’t Resume App" : "Couldn’t Launch App"),
                    error: error,
                    ownedBy: operationToken
                )
            }
        }
    }

    func requestQuit(_ application: ApplicationDisplayModel) {
        confirmation = .quitApplication(application.id)
    }

    func performRecovery(_ recovery: PresentedFailureRecovery) {
        switch recovery {
        case let .reconnect(hostID, applicationID):
            guard selectedHostID == hostID else {
                failure = PresentedFailure(
                    title: "Couldn’t Reconnect",
                    message: "Return to the host where this stream was running and try again."
                )
                return
            }
            guard let application = application(id: applicationID) else {
                failure = PresentedFailure(
                    title: "Couldn’t Reconnect",
                    message: "The streamed application is no longer available on this host."
                )
                return
            }
            guard activationInFlight == nil else { return }
            failure = nil
            connect(
                to: application,
                on: hostID,
                resumeOverride: true,
                isRecovery: true
            )
        }
    }

    func confirm(_ confirmation: PresentedConfirmation) {
        self.confirmation = nil
        switch confirmation {
        case let .deleteHost(id):
            deleteHost(id)
        case let .quitApplication(id):
            quitApplication(id, thenLaunch: nil)
        case let .replaceRunningApplication(current, next):
            quitApplication(current, thenLaunch: next)
        }
    }

    func requestDelete(_ host: HostDisplayModel) {
        confirmation = .deleteHost(host.id)
    }

    func rename(_ host: HostDisplayModel, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            failure = PresentedFailure(title: "Name Required", message: "Enter a name for this host.")
            return
        }
        presentedSheet = nil
        let operationToken = beginOperation(OperationPresentation(
            kind: .updating,
            title: "Renaming Host",
            message: "Updating \(host.name)...",
            progress: nil,
            isCancellable: false
        ))
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(operationToken) }
            do {
                upsert(try await service.renameHost(id: host.id, name: trimmedName))
            } catch {
                presentFailure(title: "Couldn’t Rename Host", error: error, ownedBy: operationToken)
            }
        }
    }

    /// Saves an endpoint without dismissing drafts or presenting a blocking network operation.
    func updateHostEndpoint(_ host: HostDisplayModel, address: String, portText: String) async throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            throw UmbraClientServiceError.invalidInput("Enter an IP address or hostname.")
        }
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), port != 0 else {
            throw UmbraClientServiceError.invalidInput("Enter a UDP port from 1 to 65535.")
        }
        let updated = try await service.updateHostEndpoint(
            id: host.id,
            endpoint: HostEndpointInput(address: address, port: Int(port))
        )
        upsert(updated)
    }

    func wake(_ host: HostDisplayModel) {
        let operationToken = beginOperation(OperationPresentation(
            kind: .waking,
            title: "Waking \(host.name)",
            message: "Sending a Wake-on-LAN packet...",
            progress: nil,
            isCancellable: false
        ))
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(operationToken) }
            do {
                upsert(try await service.wakeHost(id: host.id))
            } catch {
                presentFailure(title: "Couldn’t Wake Host", error: error, ownedBy: operationToken)
            }
        }
    }

    func testNetwork(_ host: HostDisplayModel) {
        let operationToken = beginOperation(OperationPresentation(
            kind: .testing,
            title: "Testing Network",
            message: "Checking whether required streaming ports are reachable...",
            progress: nil,
            isCancellable: true
        ))
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(operationToken) }
            do {
                let result = try await service.testNetwork(for: host.id)
                try Task.checkCancellation()
                presentedSheet = .networkResult(result)
            } catch is CancellationError {
                return
            } catch {
                presentFailure(title: "Network Test Failed", error: error, ownedBy: operationToken)
            }
        }
    }

    func toggleHidden(_ application: ApplicationDisplayModel) {
        guard let hostID = selectedHostID,
              let currentApplication = self.application(id: application.id),
              currentApplication.hostID == hostID else { return }
        let previousValue = currentApplication.isHidden
        let requestedValue = !previousValue
        enqueueApplicationMutation(
            key: .hidden(hostID: hostID, applicationID: currentApplication.id),
            payload: .hidden(applicationID: currentApplication.id, value: requestedValue),
            value: .hidden(applicationID: currentApplication.id, value: requestedValue),
            initialValue: .hidden(applicationID: currentApplication.id, value: previousValue)
        )
    }

    func toggleDirectLaunch(_ application: ApplicationDisplayModel) {
        guard let hostID = selectedHostID,
              let currentApplication = self.application(id: application.id),
              currentApplication.hostID == hostID else { return }
        let enabling = !currentApplication.isDirectLaunch
        let previousValues = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0.isDirectLaunch) })
        let requestedValues = Dictionary(uniqueKeysWithValues: applications.map {
            ($0.id, $0.id == currentApplication.id ? enabling : false)
        })
        enqueueApplicationMutation(
            key: .directLaunch(hostID: hostID),
            payload: .directLaunch(applicationID: currentApplication.id, enabled: enabling),
            value: .directLaunch(values: requestedValues, defaultValue: false),
            initialValue: .directLaunch(values: previousValues, defaultValue: nil)
        )
    }

    private func quitApplication(_ id: ApplicationID, thenLaunch nextID: ApplicationID?) {
        guard let hostID = selectedHostID,
              let application = applications.first(where: { $0.id == id }) else { return }
        let operationToken = beginOperation(OperationPresentation(
            kind: .quitting,
            title: "Quitting \(application.name)",
            message: "Waiting for the host to close the app...",
            progress: nil,
            isCancellable: true
        ))
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(operationToken) }
            do {
                try await service.quitApplication(id: id, on: hostID)
                try Task.checkCancellation()
                updateApplication(id) { $0.isRunning = false }
                if let nextID, let next = applications.first(where: { $0.id == nextID }) {
                    finishOperation(operationToken)
                    connect(to: next, on: hostID)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                presentFailure(title: "Couldn’t Quit App", error: error, ownedBy: operationToken)
            }
        }
    }

    private func deleteHost(_ id: HostID) {
        guard let host = host(id: id) else { return }
        let operationToken = beginOperation(OperationPresentation(
            kind: .updating,
            title: "Removing \(host.name)",
            message: "Deleting this host from Umbra...",
            progress: nil,
            isCancellable: false
        ))
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(operationToken) }
            do {
                try await service.deleteHost(id: id)
                hostsState = .loaded(hosts.filter { $0.id != id })
            } catch {
                presentFailure(title: "Couldn’t Remove Host", error: error, ownedBy: operationToken)
            }
        }
    }

    func host(id: HostID) -> HostDisplayModel? {
        hosts.first { $0.id == id }
    }

    func application(id: ApplicationID) -> ApplicationDisplayModel? {
        applications.first { $0.id == id }
    }

    private func upsert(_ host: HostDisplayModel) {
        var hosts = hosts
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        hostsState = .loaded(hosts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    private func markRunning(_ id: ApplicationID) {
        var apps = applications
        for index in apps.indices {
            apps[index].isRunning = apps[index].id == id
        }
        applicationsState = .loaded(apps)
    }

    private func updateApplication(_ id: ApplicationID, update: (inout ApplicationDisplayModel) -> Void) {
        var apps = applications
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        update(&apps[index])
        applicationsState = .loaded(apps)
        reconcileApplicationBrowserContext()
    }

    private func preserveApplicationBrowserContext(for hostID: HostID) {
        guard streamingBrowserContext == nil else { return }
        streamingBrowserContext = ApplicationBrowserContext(
            hostID: hostID,
            filter: applicationFilter,
            showsHiddenApplications: showHiddenApplications,
            selectedApplicationID: selectedApplicationID,
            scrollPositionID: applicationScrollPositionID
        )
    }

    private func restoreApplicationBrowserContext() {
        guard let context = streamingBrowserContext else { return }
        streamingBrowserContext = nil
        selectedHostID = context.hostID
        applicationFilter = context.filter
        showHiddenApplications = context.showsHiddenApplications
        selectedApplicationID = context.selectedApplicationID
        applicationScrollPositionID = context.scrollPositionID
    }

    private func restoreApplicationBrowserContext(ownedBy activation: ApplicationActivationReservation) {
        guard activationInFlight == activation else { return }
        restoreApplicationBrowserContext()
    }

    private func resetApplicationBrowserContext() {
        applicationFilter = ""
        showHiddenApplications = false
        selectedApplicationID = nil
        applicationScrollPositionID = nil
        streamingBrowserContext = nil
    }

    private func reconcileApplicationBrowserContext() {
        let applicationIDs = Set(applications.map(\.id))
        if let selectedApplicationID, !applicationIDs.contains(selectedApplicationID) {
            self.selectedApplicationID = nil
        }

        let visibleIDs = Set(visibleApplications.map(\.id))
        if let selectedApplicationID, !visibleIDs.contains(selectedApplicationID) {
            self.selectedApplicationID = nil
        }
        if let applicationScrollPositionID, !visibleIDs.contains(applicationScrollPositionID) {
            self.applicationScrollPositionID = self.selectedApplicationID.flatMap { visibleIDs.contains($0) ? $0 : nil }
                ?? visibleApplications.first?.id
        }
    }

    private func ownsApplicationCatalogRequest(_ request: ApplicationCatalogRequest) -> Bool {
        currentApplicationCatalogRequest == request && selectedHostID == request.hostID
    }

    private func finishApplicationCatalogRequest(_ request: ApplicationCatalogRequest) {
        guard currentApplicationCatalogRequest == request else { return }
        currentApplicationCatalogRequest = nil
        applicationCatalogTask = nil
    }

    private func cancelApplicationCatalogRequest() {
        applicationCatalogTask?.cancel()
        applicationCatalogTask = nil
        currentApplicationCatalogRequest = nil
    }

    private func enqueueApplicationMutation(
        key: ApplicationMutationKey,
        payload: ApplicationMutationPayload,
        value: ApplicationMutationValue,
        initialValue: ApplicationMutationValue
    ) {
        nextApplicationMutationToken &+= 1
        let request = ApplicationMutationRequest(
            key: key,
            token: nextApplicationMutationToken,
            payload: payload,
            value: value
        )
        if var queue = applicationMutationQueues[key] {
            queue.queued = request
            applicationMutationQueues[key] = queue
        } else {
            applicationMutationQueues[key] = ApplicationMutationQueue(
                appliedValue: initialValue,
                inFlight: request,
                queued: nil
            )
            startApplicationMutation(request)
        }
        applyApplicationMutationValue(value)
    }

    private func startApplicationMutation(_ request: ApplicationMutationRequest) {
        applicationMutationTasks[request.token] = Task { [weak self] in
            guard let self else { return }
            let result: Result<Void, any Error>
            do {
                switch request.payload {
                case let .hidden(applicationID, value):
                    try await service.setApplicationHidden(
                        id: applicationID,
                        on: request.key.hostID,
                        hidden: value
                    )
                case let .directLaunch(applicationID, enabled):
                    try await service.setDirectLaunch(
                        id: applicationID,
                        on: request.key.hostID,
                        enabled: enabled
                    )
                }
                try Task.checkCancellation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            completeApplicationMutation(request, result: result)
        }
    }

    private func completeApplicationMutation(
        _ request: ApplicationMutationRequest,
        result: Result<Void, any Error>
    ) {
        applicationMutationTasks[request.token] = nil
        guard selectedHostID == request.key.hostID,
              var queue = applicationMutationQueues[request.key],
              queue.inFlight.token == request.token else { return }

        if case .success = result {
            queue.appliedValue = request.value
        }

        if let queued = queue.queued {
            queue.inFlight = queued
            queue.queued = nil
            applicationMutationQueues[request.key] = queue
            applyApplicationMutationValue(queued.value)
            startApplicationMutation(queued)
            return
        }

        applicationMutationQueues[request.key] = nil
        switch result {
        case .success:
            applyApplicationMutationValue(request.value)
        case let .failure(error):
            guard !(error is CancellationError) else { return }
            applyApplicationMutationValue(queue.appliedValue)
            presentFailure(
                title: request.payload.failureTitle,
                error: error
            )
        }
    }

    private func invalidateApplicationMutations() {
        for task in applicationMutationTasks.values {
            task.cancel()
        }
        applicationMutationTasks.removeAll()
        applicationMutationQueues.removeAll()
    }

    private func applyApplicationMutationValue(_ value: ApplicationMutationValue) {
        guard case .loaded(var apps) = applicationsState else { return }
        Self.applyApplicationMutationValue(value, to: &apps)
        applicationsState = .loaded(apps)
        reconcileApplicationBrowserContext()
    }

    private func applyPendingApplicationMutations(
        to apps: inout [ApplicationDisplayModel],
        on hostID: HostID
    ) {
        for (key, queue) in applicationMutationQueues where key.hostID == hostID {
            let value = queue.queued?.value ?? queue.inFlight.value
            Self.applyApplicationMutationValue(value, to: &apps)
        }
    }

    private static func applyApplicationMutationValue(
        _ value: ApplicationMutationValue,
        to apps: inout [ApplicationDisplayModel]
    ) {
        switch value {
        case let .hidden(applicationID, value):
            guard let index = apps.firstIndex(where: { $0.id == applicationID }) else { return }
            apps[index].isHidden = value
        case let .directLaunch(values, defaultValue):
            for index in apps.indices {
                if let value = values[apps[index].id] {
                    apps[index].isDirectLaunch = value
                } else if let defaultValue {
                    apps[index].isDirectLaunch = defaultValue
                }
            }
        }
    }

    private func beginOperation(_ presentation: OperationPresentation) -> UInt64 {
        nextOperationToken &+= 1
        currentOperationToken = nextOperationToken
        operation = presentation
        return nextOperationToken
    }

    private func finishOperation(_ token: UInt64) {
        guard currentOperationToken == token else { return }
        currentOperationToken = nil
        operation = nil
    }

    private func invalidateCurrentOperation() {
        currentOperationToken = nil
        operation = nil
    }

    private func finishActivation(_ activation: ApplicationActivationReservation) {
        guard activationInFlight == activation else { return }
        activationInFlight = nil
    }

    private func presentFailure(title: String, error: Error) {
        failure = PresentedFailure(title: title, message: error.localizedDescription)
    }

    private func presentFailure(title: String, error: Error, ownedBy operationToken: UInt64) {
        guard currentOperationToken == operationToken else { return }
        presentFailure(title: title, error: error)
    }

    private func handle(_ event: UmbraClientEvent) {
        switch event {
        case let .hosts(hosts):
            hostsState = .loaded(hosts.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            })
            if let selectedHostID,
               let selectedHost = hosts.first(where: { $0.id == selectedHostID }),
               case .loaded(var currentApplications) = applicationsState {
                for index in currentApplications.indices {
                    currentApplications[index].isRunning =
                        currentApplications[index].id == selectedHost.runningApplicationID
                }
                applicationsState = .loaded(currentApplications)
            }
        case let .applicationCatalogUpdated(hostID, updatedApplications):
            guard selectedHostID == hostID, case .loaded = applicationsState else { return }
            var artworkURLs: [ApplicationID: URL] = [:]
            for application in updatedApplications {
                artworkURLs[application.id] = application.artworkURL
            }
            guard !artworkURLs.isEmpty else { return }
            var currentApplications = applications
            for index in currentApplications.indices {
                if let artworkURL = artworkURLs[currentApplications[index].id] {
                    currentApplications[index].artworkURL = artworkURL
                }
            }
            applicationsState = .loaded(currentApplications)
        case let .applicationCatalogRefreshWarning(hostID, message):
            guard selectedHostID == hostID else { return }
            applicationCatalogWarning = message
        case .sessionPreparing:
            hasObservedSessionLifecycleEvent = true
            updateConnectionOperation(
                message: sessionDegradation ?? "Preparing the stream...",
                progress: 0.05
            )
        case let .sessionConnecting(stage):
            hasObservedSessionLifecycleEvent = true
            updateConnectionOperation(
                message: sessionDegradation ?? Self.connectionMessage(for: stage),
                progress: Self.connectionProgress(for: stage)
            )
        case .sessionStreaming:
            hasObservedSessionLifecycleEvent = true
            hasReachedStreamingState = true
            activationInFlight = nil
            invalidateCurrentOperation()
        case let .sessionFailed(sessionFailure):
            let wasStreaming = hasReachedStreamingState
            hasObservedSessionLifecycleEvent = false
            hasReachedStreamingState = false
            sessionDegradation = nil
            let recovery = Self.canReconnect(after: sessionFailure, wasStreaming: wasStreaming)
                ? streamingBrowserContext.flatMap { context in
                context.selectedApplicationID.map {
                    PresentedFailureRecovery.reconnect(
                        hostID: context.hostID,
                        applicationID: $0
                    )
                }
                }
                : nil
            activationInFlight = nil
            activeTask?.cancel()
            activeTask = nil
            invalidateCurrentOperation()
            restoreApplicationBrowserContext()
            if sessionFailure.kind != .cancelled {
                failure = PresentedFailure(
                    title: wasStreaming ? "Streaming Ended" : "Couldn’t Start Stream",
                    message: sessionFailure.message,
                    recovery: recovery
                )
            }
            if selectedHostID != nil { loadApplications() }
        case .sessionEnded:
            hasObservedSessionLifecycleEvent = false
            hasReachedStreamingState = false
            sessionDegradation = nil
            activationInFlight = nil
            activeTask?.cancel()
            activeTask = nil
            invalidateCurrentOperation()
            restoreApplicationBrowserContext()
            if selectedHostID != nil { loadApplications() }
        case let .sessionWarning(message):
            if preferences.settings.connectionWarnings, operation?.kind == .connecting {
                operation = OperationPresentation(
                    kind: .connecting,
                    title: operation?.title ?? "Connecting",
                    message: message,
                    progress: operation?.progress,
                    isCancellable: true
                )
            } else if preferences.settings.connectionWarnings {
                // Recoverable streaming notices must not present a modal or take input focus.
                // Terminal failures have their own sessionFailed event and recovery action.
                sessionDegradation = message
            }
        case let .sessionDegraded(message):
            sessionDegradation = message
            if operation?.kind == .connecting {
                operation = OperationPresentation(
                    kind: .connecting,
                    title: operation?.title ?? "Connecting",
                    message: message,
                    progress: operation?.progress,
                    isCancellable: true
                )
            }
        case .configurationWarnings:
            break
        }
    }

    private static func canReconnect(
        after failure: SessionFailure,
        wasStreaming: Bool
    ) -> Bool {
        guard wasStreaming else { return false }
        switch failure.kind {
        case .connectionFailed, .hostUnavailable, .streamTerminated:
            return true
        default:
            return false
        }
    }

    private func updateConnectionOperation(message: String, progress: Double) {
        guard operation?.kind == .connecting else { return }
        let monotonicProgress = max(operation?.progress ?? 0, progress)
        operation = OperationPresentation(
            kind: .connecting,
            title: operation?.title ?? "Connecting",
            message: message,
            progress: monotonicProgress,
            isCancellable: true
        )
    }

    private static func connectionMessage(for stage: SessionStage) -> String {
        switch stage {
        case .platformInitialization: "Initializing this Mac..."
        case .nameResolution: "Resolving the host..."
        case .serverHandshake: "Negotiating with the host..."
        case .controlStreamInitialization: "Starting stream controls..."
        case .videoStreamInitialization: "Starting video..."
        case .audioStreamInitialization: "Starting audio..."
        case .inputStreamInitialization: "Starting input..."
        case .connection: "Finishing the connection..."
        }
    }

    private static func connectionProgress(for stage: SessionStage) -> Double {
        switch stage {
        case .connection: 0.10
        case .platformInitialization: 0.18
        case .nameResolution: 0.28
        case .audioStreamInitialization: 0.38
        case .serverHandshake: 0.48
        case .controlStreamInitialization: 0.60
        case .videoStreamInitialization: 0.72
        case .inputStreamInitialization: 0.84
        }
    }
}

private struct ApplicationActivationReservation: Equatable {
    let hostID: HostID
    let applicationID: ApplicationID
    let operationToken: UInt64
}

private struct ApplicationCatalogRequest: Equatable {
    let hostID: HostID
    let token: UInt64
}

private enum ApplicationMutationKey: Hashable {
    case hidden(hostID: HostID, applicationID: ApplicationID)
    case directLaunch(hostID: HostID)

    var hostID: HostID {
        switch self {
        case let .hidden(hostID, _), let .directLaunch(hostID): hostID
        }
    }
}

private enum ApplicationMutationPayload {
    case hidden(applicationID: ApplicationID, value: Bool)
    case directLaunch(applicationID: ApplicationID, enabled: Bool)

    var failureTitle: String {
        switch self {
        case .hidden: "Couldn’t Update App Visibility"
        case .directLaunch: "Couldn’t Update Direct Launch"
        }
    }
}

private enum ApplicationMutationValue {
    case hidden(applicationID: ApplicationID, value: Bool)
    case directLaunch(values: [ApplicationID: Bool], defaultValue: Bool?)
}

private struct ApplicationMutationRequest {
    let key: ApplicationMutationKey
    let token: UInt64
    let payload: ApplicationMutationPayload
    let value: ApplicationMutationValue
}

private struct ApplicationMutationQueue {
    var appliedValue: ApplicationMutationValue
    var inFlight: ApplicationMutationRequest
    var queued: ApplicationMutationRequest?
}
