import AppKit
import Combine
import Foundation
import ImageIO
import UmbraCore
import UmbraDiagnostics
import UmbraIntegration
import UmbraLSP
import UmbraMedia
import UmbraMicrophone
import UmbraNetworking
import UmbraPairing
import UmbraServices

final class SecurePortRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [String: UInt16] = [:]

    func register(_ host: StreamHost) {
        guard let port = host.activeHTTPSPort else { return }
        lock.withLock {
            for endpoint in host.uniqueAddresses {
                ports[endpoint.hostname.lowercased()] = port
            }
        }
    }

    func port(for address: HostAddress) -> UInt16 {
        lock.withLock { ports[address.host.lowercased()] } ?? HostAddress.defaultHTTPSPort
    }
}

actor ApplicationArtworkCache {
    private enum CacheError: Error {
        case unavailable
        case invalidated
        case invalidArtwork
    }

    private let rootDirectory: URL?
    private var hostGenerations: [String: UInt64] = [:]

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            self.rootDirectory = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("Umbra/BoxArt", isDirectory: true)
        }
    }

    func artworkURL(
        hostID: String,
        applicationID: Int,
        loader: @Sendable () async throws -> Data
    ) async throws -> URL {
        if let cached = cachedArtworkURL(hostID: hostID, applicationID: applicationID) {
            return cached
        }
        guard let rootDirectory else { throw CacheError.unavailable }
        let fileManager = FileManager.default
        let hostDirectory = hostDirectory(rootDirectory: rootDirectory, hostID: hostID)
        let destination = hostDirectory.appendingPathComponent("\(applicationID).png")

        let generation = hostGenerations[hostID, default: 0]
        let data = try await loader()
        try Task.checkCancellation()
        guard Self.isDecodableArtwork(data) else {
            throw CacheError.invalidArtwork
        }
        try Task.checkCancellation()
        guard hostGenerations[hostID, default: 0] == generation else {
            throw CacheError.invalidated
        }
        try fileManager.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func cachedArtworkURLs(hostID: String, applicationIDs: [Int]) -> [Int: URL] {
        var result: [Int: URL] = [:]
        result.reserveCapacity(applicationIDs.count)
        for applicationID in applicationIDs {
            result[applicationID] = cachedArtworkURL(hostID: hostID, applicationID: applicationID)
        }
        return result
    }

    func removeHost(_ hostID: String) {
        hostGenerations[hostID, default: 0] &+= 1
        guard let rootDirectory else { return }

        let fileManager = FileManager.default
        let hostDirectory = hostDirectory(rootDirectory: rootDirectory, hostID: hostID)
        try? fileManager.removeItem(at: hostDirectory)

        let legacyPrefix = "\(Self.legacyFileSystemComponent(for: hostID))-"
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(legacyPrefix) {
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func fileSystemComponent(for value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func legacyFileSystemComponent(for value: String) -> String {
        value.replacingOccurrences(of: "/", with: "_")
    }

    private func cachedArtworkURL(hostID: String, applicationID: Int) -> URL? {
        guard let rootDirectory else { return nil }
        let fileManager = FileManager.default
        let destination = hostDirectory(rootDirectory: rootDirectory, hostID: hostID)
            .appendingPathComponent("\(applicationID).png")
        if fileManager.fileExists(atPath: destination.path) {
            if Self.isDecodableArtwork(at: destination) { return destination }
            try? fileManager.removeItem(at: destination)
        }

        // Read caches created by older Umbra builds without forcing another network request.
        let legacyDestination = rootDirectory.appendingPathComponent(
            "\(Self.legacyFileSystemComponent(for: hostID))-\(applicationID).png"
        )
        guard fileManager.fileExists(atPath: legacyDestination.path) else { return nil }
        guard Self.isDecodableArtwork(at: legacyDestination) else {
            try? fileManager.removeItem(at: legacyDestination)
            return nil
        }
        return legacyDestination
    }

    private static func isDecodableArtwork(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return isDecodableArtwork(CGImageSourceCreateWithData(data as CFData, nil))
    }

    private static func isDecodableArtwork(at url: URL) -> Bool {
        guard let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              resourceValues.isRegularFile == true,
              let fileSize = resourceValues.fileSize,
              fileSize > 0 else {
            return false
        }
        return isDecodableArtwork(CGImageSourceCreateWithURL(url as CFURL, nil))
    }

    private static func isDecodableArtwork(_ source: CGImageSource?) -> Bool {
        guard let source, CGImageSourceGetCount(source) > 0 else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    private func hostDirectory(rootDirectory: URL, hostID: String) -> URL {
        rootDirectory.appendingPathComponent(Self.fileSystemComponent(for: hostID), isDirectory: true)
    }
}

struct SessionWarningDeliveryState {
    private var sessionID: UUID?
    private var deliveredWarningCount = 0

    mutating func takeNewWarnings(from session: StreamSession) -> ArraySlice<String> {
        guard !session.state.isTerminal else {
            reset()
            return []
        }
        if sessionID != session.id {
            sessionID = session.id
            deliveredWarningCount = 0
        } else if deliveredWarningCount > session.launchWarnings.count {
            // Be defensive if an authoritative session snapshot replaces a longer local one.
            deliveredWarningCount = 0
        }
        let warnings = session.launchWarnings.dropFirst(deliveredWarningCount)
        deliveredWarningCount = session.launchWarnings.count
        return warnings
    }

    mutating func reset() {
        sessionID = nil
        deliveredWarningCount = 0
    }
}

@MainActor
final class LiveUmbraClientService: UmbraClientServicing {
    var onSessionTerminated: (@MainActor @Sendable (Bool) -> Void)?
    private let service: UmbraApplicationService
    private let preferences: PreferencesStore
    private let securePorts: SecurePortRegistry
    private let preferenceResolver: (StreamingPreferences) -> RuntimeStreamingResolution
    private let configurationWarningEvaluator: any StreamingConfigurationWarningEvaluating
    private let artworkCache: ApplicationArtworkCache
    private let maximumConcurrentArtworkRequests: Int
    private let lspProduct: LSPProductClient?
    private let lspDiscovery = LSPDiscovery.makeBonjourBrowser()
    private let lspInputCapture = LSPAppKitInputCapture()
    private var eventHandler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?
    private var sessionWarningDeliveryState = SessionWarningDeliveryState()
    private var artworkLoadingTasks: [String: Task<Void, Never>] = [:]
    private var artworkLoadingIDs: [String: UUID] = [:]
    private let handlerInstallationTask: Task<Void, Never>
    private var serviceEventTask: Task<Void, Never>?
    private var discoveryPreferenceTask: Task<Void, Never>?
    private var lastLegacyHosts: [HostDisplayModel] = []
    private var lastLSPHosts: [HostDisplayModel] = []
    private var discoveredLSPHosts: [UUID: HostDisplayModel] = [:]
    private var lspApplicationIDs: [HostID: [Int: String]] = [:]

    init(
        service: UmbraApplicationService,
        preferences: PreferencesStore,
        securePorts: SecurePortRegistry,
        preferenceResolver: @escaping (StreamingPreferences) -> RuntimeStreamingResolution = {
            RuntimeStreamingResolution(preferences: $0)
        },
        configurationWarningEvaluator: any StreamingConfigurationWarningEvaluating = StreamingConfigurationWarningEvaluator(),
        artworkCache: ApplicationArtworkCache = ApplicationArtworkCache(),
        maximumConcurrentArtworkRequests: Int = 4,
        lspProduct: LSPProductClient? = nil
    ) {
        self.service = service
        self.preferences = preferences
        self.securePorts = securePorts
        self.preferenceResolver = preferenceResolver
        self.configurationWarningEvaluator = configurationWarningEvaluator
        self.artworkCache = artworkCache
        self.maximumConcurrentArtworkRequests = max(1, maximumConcurrentArtworkRequests)
        self.lspProduct = lspProduct
        let (events, continuation) = AsyncStream<HostServiceEvent>.makeStream()
        handlerInstallationTask = Task { [service, continuation] in
            await service.setEventHandler { event in
                continuation.yield(event)
            }
        }
        serviceEventTask = Task { @MainActor [weak self, events] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
        discoveryPreferenceTask = Task { @MainActor [weak self, preferences, service, lspDiscovery] in
            var lastEnabledValue: Bool?
            for await settings in preferences.$settings.values {
                guard !Task.isCancelled else { return }
                guard settings.enableMDNS != lastEnabledValue else { continue }
                lastEnabledValue = settings.enableMDNS
                await service.setDiscoveryEnabled(settings.enableMDNS)
                if settings.enableMDNS {
                    lspDiscovery.start { [weak self] event in
                        Task { @MainActor [weak self] in
                            self?.handleLSPDiscovery(event)
                        }
                    }
                } else {
                    lspDiscovery.stop()
                }
            }
        }
        lspInputCapture.failureHandler = { [weak self] error in
            self?.eventHandler?(.sessionWarning("Native LSP input stopped: \(error.localizedDescription)"))
        }
    }

    deinit {
        handlerInstallationTask.cancel()
        serviceEventTask?.cancel()
        discoveryPreferenceTask?.cancel()
        lspDiscovery.stop()
        for task in artworkLoadingTasks.values { task.cancel() }
    }

    func waitUntilReady() async {
        await handlerInstallationTask.value
    }

    func setEventHandler(_ handler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?) {
        eventHandler = handler
    }

    func discoverHosts() async throws -> [HostDisplayModel] {
        let initial = try await service.startMonitoring()
        let hosts = initial.isEmpty ? initial : try await service.refreshHosts()
        lastLegacyHosts = hosts.map(displayHost)
        try await refreshPersistedLSPHosts()
        return combinedHosts()
    }

    func addHost(_ endpoint: HostEndpointInput) async throws -> HostDisplayModel {
        if endpoint.address.hasPrefix("umbra://pair/lsp1#") {
            guard endpoint.port == nil, let lspProduct else {
                throw UmbraClientServiceError.invalidInput(
                    "LSP invitations contain their own authenticated host and port. Leave the port field empty."
                )
            }
            let host = try await lspProduct.pair(invitationURI: endpoint.address)
            let display = displayLSPHost(host, paired: true, online: true)
            upsertLSPHost(display)
            eventHandler?(.hosts(combinedHosts()))
            return display
        }
        let port = endpoint.port.flatMap(UInt16.init(exactly:))
        return displayHost(try await service.addHost(address: endpoint.address, port: port))
    }

    func pairHost(_ request: PairingRequest) async throws -> HostDisplayModel {
        if lspHostID(request.hostID) != nil {
            throw UmbraClientServiceError.invalidInput(
                "Native LSP pairing requires a single-use umbra://pair/lsp1 invitation. Import it with Add Host."
            )
        }
        return displayHost(try await service.pairHost(id: request.hostID.rawValue, pin: request.pin))
    }

    func cancelPairing(hostID: HostID) async {
        await service.cancelPairing(hostID: hostID.rawValue)
    }

    func renameHost(id: HostID, name: String) async throws -> HostDisplayModel {
        if let hostID = lspHostID(id), let lspProduct {
            let updated = try await lspProduct.rename(hostID: hostID, name: name)
            let display = displayLSPHost(updated, paired: true, online: true)
            upsertLSPHost(display)
            return display
        }
        return displayHost(try await service.renameHost(id: id.rawValue, name: name))
    }

    func deleteHost(id: HostID) async throws {
        if let hostID = lspHostID(id), let lspProduct {
            try await lspProduct.remove(hostID: hostID)
            lastLSPHosts.removeAll { $0.id == id }
            discoveredLSPHosts.removeValue(forKey: hostID)
            lspApplicationIDs.removeValue(forKey: id)
            eventHandler?(.hosts(combinedHosts()))
            return
        }
        try await service.removeHost(id: id.rawValue)
        artworkLoadingTasks[id.rawValue]?.cancel()
        artworkLoadingTasks[id.rawValue] = nil
        artworkLoadingIDs[id.rawValue] = nil
        await artworkCache.removeHost(id.rawValue)
    }

    func wakeHost(id: HostID) async throws -> HostDisplayModel {
        if lspHostID(id) != nil {
            throw UmbraClientServiceError.unavailable("Wake-on-LAN is not part of LSP/1.")
        }
        return displayHost(try await service.wakeHost(id: id.rawValue))
    }

    func testNetwork(for id: HostID) async throws -> NetworkTestOutcome {
        if lspHostID(id) != nil {
            return .unavailable
        }
        _ = try await service.details(hostID: id.rawValue)
        switch await service.testConnectivity() {
        case .clear:
            return .clear
        case let .blocked(ports):
            return .blocked(ports: ports.map(\.description))
        case .inconclusive:
            return .unavailable
        }
    }

    func applications(for id: HostID, includeHidden: Bool) async throws -> [ApplicationDisplayModel] {
        if let hostID = lspHostID(id), let lspProduct {
            let applications = try await lspProduct.applications(hostID: hostID)
            var wireIDs: [Int: String] = [:]
            var display: [ApplicationDisplayModel] = []
            display.reserveCapacity(applications.count)
            for application in applications {
                var candidate = Self.stableLSPApplicationID(application.id)
                while let existing = wireIDs[candidate], existing != application.id {
                    candidate = candidate == Int.max ? 1 : candidate + 1
                }
                wireIDs[candidate] = application.id
                display.append(ApplicationDisplayModel(
                    id: ApplicationID(candidate),
                    hostID: id,
                    name: application.name,
                    artworkURL: nil,
                    isRunning: false,
                    isHidden: false,
                    isDirectLaunch: false
                ))
            }
            lspApplicationIDs[id] = wireIDs
            return display
        }
        let catalog = try await applicationsPreservingLastCatalog(
            hostID: id.rawValue,
            includeHidden: includeHidden
        )
        let host = try await service.details(hostID: id.rawValue).host
        securePorts.register(host)
        let artworkURLs = await artworkCache.cachedArtworkURLs(
            hostID: id.rawValue,
            applicationIDs: catalog.applications.map(\.id)
        )

        let displayApplications = catalog.applications.map { application in
            ApplicationDisplayModel(
                id: ApplicationID(application.id),
                hostID: id,
                name: application.name,
                artworkURL: artworkURLs[application.id],
                isRunning: host.currentGameID == application.id,
                isHidden: application.isHidden,
                isDirectLaunch: application.supportsDirectLaunch
            )
        }
        startArtworkLoading(
            hostID: id,
            applicationIDs: catalog.applications.map(\.id),
            displayApplications: displayApplications,
            loader: { [service] applicationID in
                try await service.boxArt(hostID: id.rawValue, applicationID: applicationID)
            }
        )
        if let warning = catalog.refreshWarning {
            eventHandler?(.applicationCatalogRefreshWarning(hostID: id, message: warning))
        }
        return displayApplications
    }

    func launchApplication(id: ApplicationID, on hostID: HostID, resume: Bool) async throws {
        try await launchApplication(
            id: id,
            on: hostID,
            resume: resume,
            activationUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    func launchApplication(
        id: ApplicationID,
        on hostID: HostID,
        resume: Bool,
        activationUptime: TimeInterval
    ) async throws {
        if let nativeHostID = lspHostID(hostID) {
            guard let lspProduct, let applicationID = lspApplicationIDs[hostID]?[id.rawValue] else {
                throw UmbraClientServiceError.invalidInput("The selected native LSP application is no longer available.")
            }
            let session = try await lspProduct.startInput(
                hostID: nativeHostID,
                applicationID: applicationID,
                pointerRate: 1_000
            )
            lspInputCapture.start(session: session)
            installLSPReconnectHandler(session: session, hostID: nativeHostID)
            return
        }
        do {
            let runtimeResolution = preferenceResolver(preferences.settings)
            let resolvedPreferences = runtimeResolution.preferences
            if resolvedPreferences.configurationWarnings {
                var warningMessages: [String] = []
                if preferences.settings.enableHDR && !resolvedPreferences.enableHDR {
                    warningMessages.append(
                        "The selected display cannot present HDR. Umbra will use SDR for this stream."
                    )
                }
                if resolvedPreferences.audioConfiguration
                    != preferences.settings.audioConfiguration {
                    warningMessages.append(
                        "The active audio device cannot play the selected surround layout. Umbra will use Stereo for this stream."
                    )
                }
                let host = try await service.details(hostID: hostID.rawValue).host
                if let application = host.applications.first(where: { $0.id == id.rawValue }) {
                    warningMessages.append(contentsOf: configurationWarningEvaluator.warnings(
                        host: host,
                        application: application,
                        preferences: resolvedPreferences
                    ).map(\.message))
                }
                var deliveredWarnings = Set<String>()
                warningMessages = warningMessages.filter {
                    deliveredWarnings.insert($0).inserted
                }
                if !warningMessages.isEmpty {
                    eventHandler?(.configurationWarnings(warningMessages))
                }
            }
            _ = try await service.beginSession(
                runtimeResolution.sessionIntent(
                    hostID: hostID.rawValue,
                    applicationID: id.rawValue,
                    kind: resume ? .resume : .launch
                ),
                uiActivationUptime: activationUptime
            )
        } catch {
            guard preferences.settings.detectNetworkBlocking else { throw error }
            if case let .blocked(ports) = await service.testConnectivity() {
                throw UmbraClientServiceError.unavailable(
                    "\(error.localizedDescription) Required ports appear blocked: "
                        + ports.map(\.description).joined(separator: ", ")
                )
            }
            throw error
        }
    }

    func disconnectSession() async {
        lspInputCapture.stop()
        _ = try? await service.stopSession(quitHostApplication: false)
    }

    /// Executes the product reconnect/rekey boundary without legacy fallback.
    func reconnectLSPInput(
        hostID: UUID,
        reason: LSPReconnectReason
    ) async throws {
        guard let lspProduct else { throw UmbraClientServiceError.unavailable("Native LSP is unavailable.") }
        let replacement = try await lspProduct.reconnectInput(hostID: hostID, reason: reason)
        lspInputCapture.start(session: replacement)
        installLSPReconnectHandler(session: replacement, hostID: hostID)
    }

    private func installLSPReconnectHandler(session: LSPClientSession, hostID: UUID) {
        session.setTransportLifecycleHandler { [weak self, weak session] lifecycle in
            guard lifecycle == .failed, session != nil else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.reconnectLSPInput(hostID: hostID, reason: .transportLoss)
                    self.eventHandler?(.sessionWarning("Native LSP input reconnected with fresh security keys."))
                } catch {
                    self.lspInputCapture.stop()
                    self.eventHandler?(.sessionWarning("Native LSP reconnect failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    func quitApplication(id: ApplicationID, on hostID: HostID) async throws {
        if lspHostID(hostID) != nil {
            throw UmbraClientServiceError.unavailable("LSP application quit is not implemented by the current control slice.")
        }
        _ = try await service.cancelHostApplication(
            hostID: hostID.rawValue,
            applicationID: id.rawValue
        )
    }

    func setApplicationHidden(id: ApplicationID, on hostID: HostID, hidden: Bool) async throws {
        if lspHostID(hostID) != nil {
            throw UmbraClientServiceError.unavailable("Native LSP applications do not use legacy hidden-app state.")
        }
        try await service.setApplicationHidden(
            hostID: hostID.rawValue,
            applicationID: id.rawValue,
            hidden: hidden
        )
    }

    func setDirectLaunch(id: ApplicationID, on hostID: HostID, enabled: Bool) async throws {
        if lspHostID(hostID) != nil {
            throw UmbraClientServiceError.unavailable("Native LSP applications do not use legacy direct-launch state.")
        }
        try await service.setDirectLaunch(
            hostID: hostID.rawValue,
            applicationID: id.rawValue,
            enabled: enabled
        )
    }

    private func displayHost(_ host: StreamHost) -> HostDisplayModel {
        securePorts.register(host)
        return HostDisplayModel(
            id: HostID(host.uuid),
            name: host.name,
            status: HostConnectionStatus(rawValue: host.status.rawValue) ?? .unknown,
            isPaired: host.pairState == .paired,
            hasActiveSession: host.currentGameID != nil,
            runningApplicationID: host.currentGameID.map(ApplicationID.init),
            canWake: host.macAddress.count == 6,
            isServerSupported: host.isSupportedServerVersion,
            details: details(for: host)
        )
    }

    private func displayLSPHost(
        _ host: LSPHostRecord,
        paired: Bool,
        online: Bool
    ) -> HostDisplayModel {
        HostDisplayModel(
            id: HostID("lsp:\(host.hostID.uuidString.lowercased())"),
            name: host.name,
            status: online ? .online : .unknown,
            isPaired: paired,
            hasActiveSession: false,
            canWake: false,
            isServerSupported: true,
            details: "Protocol: Lumen Streaming Protocol\nAddress: \(host.address):\(host.port)\nTrust: \(paired ? "Paired" : "Invitation required")"
        )
    }

    private func details(for host: StreamHost) -> String {
        var lines = [
            "Status: \(host.status.rawValue.capitalized)",
            "Pairing: \(host.pairState == .paired ? "Paired" : "Not paired")",
        ]
        if let gpu = host.gpuModel, !gpu.isEmpty { lines.append("GPU: \(gpu)") }
        if let version = host.appVersion, !version.isEmpty { lines.append("Host version: \(version)") }
        if let compatibilityVersion = host.gfeVersion, !compatibilityVersion.isEmpty {
            let label = host.isNvidiaServerSoftware
                ? "GeForce Experience"
                : "GameStream compatibility"
            lines.append("\(label): \(compatibilityVersion)")
        }
        if !host.uniqueAddresses.isEmpty {
            lines.append("Addresses: \(host.uniqueAddresses.map(\.displayName).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func applicationsPreservingLastCatalog(
        hostID: String,
        includeHidden: Bool
    ) async throws -> (applications: [StreamApplication], refreshWarning: String?) {
        do {
            return (
                try await service.applications(
                    hostID: hostID,
                    refresh: true,
                    includeHidden: includeHidden
                ),
                nil
            )
        } catch {
            guard Self.canUseSavedCatalog(after: error) else { throw error }
            let saved = try await service.applications(
                hostID: hostID,
                refresh: false,
                includeHidden: includeHidden
            )
            guard !saved.isEmpty else { throw error }
            return (
                saved,
                "Couldn’t refresh this host’s application list. Umbra is showing the last saved version."
            )
        }
    }

    private func startArtworkLoading(
        hostID: HostID,
        applicationIDs: [Int],
        displayApplications: [ApplicationDisplayModel],
        loader: @escaping @Sendable (Int) async throws -> Data
    ) {
        let missingArtworkIndices = displayApplications.indices.filter {
            displayApplications[$0].artworkURL == nil
        }
        artworkLoadingTasks[hostID.rawValue]?.cancel()
        guard !missingArtworkIndices.isEmpty else {
            artworkLoadingTasks[hostID.rawValue] = nil
            artworkLoadingIDs[hostID.rawValue] = nil
            return
        }

        let loadingID = UUID()
        let requestLimit = maximumConcurrentArtworkRequests
        let artworkCache = self.artworkCache
        artworkLoadingIDs[hostID.rawValue] = loadingID
        artworkLoadingTasks[hostID.rawValue] = Task { [weak self] in
            await Self.loadArtworkIncrementally(
                hostID: hostID,
                applicationIDs: applicationIDs,
                displayApplications: displayApplications,
                missingArtworkIndices: missingArtworkIndices,
                maximumConcurrentRequests: requestLimit,
                cache: artworkCache,
                loader: loader
            ) { [weak self] updatedApplications in
                guard let self, self.artworkLoadingIDs[hostID.rawValue] == loadingID else { return false }
                self.eventHandler?(.applicationCatalogUpdated(
                    hostID: hostID,
                    applications: updatedApplications
                ))
                return true
            }
            guard let self, self.artworkLoadingIDs[hostID.rawValue] == loadingID else { return }
            self.artworkLoadingTasks[hostID.rawValue] = nil
            self.artworkLoadingIDs[hostID.rawValue] = nil
        }
    }

    private nonisolated static func loadArtworkIncrementally(
        hostID: HostID,
        applicationIDs: [Int],
        displayApplications: [ApplicationDisplayModel],
        missingArtworkIndices: [Int],
        maximumConcurrentRequests: Int,
        cache: ApplicationArtworkCache,
        loader: @escaping @Sendable (Int) async throws -> Data,
        update: @escaping @MainActor @Sendable ([ApplicationDisplayModel]) -> Bool
    ) async {
        var updatedApplications = displayApplications
        let requestLimit = min(maximumConcurrentRequests, missingArtworkIndices.count)

        await withTaskGroup(of: IndexedArtwork.self) { group in
            var nextIndex = 0
            while nextIndex < requestLimit {
                let index = missingArtworkIndices[nextIndex]
                let applicationID = applicationIDs[index]
                group.addTask {
                    await Self.loadArtwork(
                        index: index,
                        hostID: hostID.rawValue,
                        applicationID: applicationID,
                        cache: cache,
                        loader: loader
                    )
                }
                nextIndex += 1
            }

            while let artwork = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let url = artwork.url {
                    updatedApplications[artwork.index].artworkURL = url
                    guard await update(updatedApplications) else {
                        group.cancelAll()
                        return
                    }
                }
                if nextIndex < missingArtworkIndices.count {
                    let index = missingArtworkIndices[nextIndex]
                    let applicationID = applicationIDs[index]
                    group.addTask {
                        await Self.loadArtwork(
                            index: index,
                            hostID: hostID.rawValue,
                            applicationID: applicationID,
                            cache: cache,
                            loader: loader
                        )
                    }
                    nextIndex += 1
                }
            }
        }
    }

    private struct IndexedArtwork: Sendable {
        var index: Int
        var url: URL?
    }

    private nonisolated static func loadArtwork(
        index: Int,
        hostID: String,
        applicationID: Int,
        cache: ApplicationArtworkCache,
        loader: @escaping @Sendable (Int) async throws -> Data
    ) async -> IndexedArtwork {
        guard !Task.isCancelled else { return IndexedArtwork(index: index, url: nil) }
        do {
            let url = try await cache.artworkURL(hostID: hostID, applicationID: applicationID) {
                try await loader(applicationID)
            }
            return IndexedArtwork(index: index, url: url)
        } catch {
            // Artwork is optional. One failed asset must not hide the application catalog.
            return IndexedArtwork(index: index, url: nil)
        }
    }

    private nonisolated static func canUseSavedCatalog(after error: Error) -> Bool {
        guard let serviceError = error as? UmbraServiceError else { return false }
        return switch serviceError {
        case .hostUnavailable:
            true
        case let .protocolFailure(operation, statusCode, _):
            operation == .applications && (
                statusCode == 408
                    || statusCode == 409
                    || statusCode == 423
                    || statusCode == 429
                    || (statusCode.map { $0 >= 500 } ?? false)
            )
        default:
            false
        }
    }

    private func handle(_ event: HostServiceEvent) {
        switch event {
        case let .hosts(hosts):
            lastLegacyHosts = hosts.map(displayHost)
            eventHandler?(.hosts(combinedHosts()))
        case .failure:
            // Background discovery/polling failures preserve the last trustworthy host state.
            break
        case let .session(session):
            guard let session else {
                sessionWarningDeliveryState.reset()
                return
            }
            let newWarnings = sessionWarningDeliveryState.takeNewWarnings(from: session)
            for warning in newWarnings {
                eventHandler?(.sessionWarning(warning))
            }
            switch session.state {
            case .preparing:
                eventHandler?(.sessionPreparing)
            case let .connecting(stage):
                eventHandler?(.sessionConnecting(stage))
            case .streaming:
                eventHandler?(.sessionStreaming)
            case let .failed(failure):
                eventHandler?(.sessionFailed(failure))
                onSessionTerminated?(false)
            case .finished:
                eventHandler?(.sessionEnded)
                onSessionTerminated?(true)
            case .idle, .stopping:
                break
            }
        case .pairing:
            break
        }
    }

    private func combinedHosts() -> [HostDisplayModel] {
        var nativeByID = Dictionary(uniqueKeysWithValues: discoveredLSPHosts.map {
            (HostID("lsp:\($0.key.uuidString.lowercased())"), $0.value)
        })
        for host in lastLSPHosts {
            nativeByID[host.id] = host
        }
        return lastLegacyHosts + nativeByID.values
    }

    private func refreshPersistedLSPHosts() async throws {
        guard let lspProduct else {
            lastLSPHosts = []
            return
        }
        lastLSPHosts = try await lspProduct.hosts().map {
            displayLSPHost($0, paired: true, online: true)
        }
    }

    private func upsertLSPHost(_ host: HostDisplayModel) {
        lastLSPHosts.removeAll { $0.id == host.id }
        lastLSPHosts.append(host)
    }

    private func handleLSPDiscovery(_ event: DiscoveryEvent) {
        switch event {
        case .added(let service), .updated(_, let service):
            guard service.txtRecord["v"] == "1",
                  let encodedID = service.txtRecord["id"],
                  let hostID = Self.uuid(fromLowercaseHex: encodedID)
            else { return }
            let record = LSPHostRecord(
                hostID: hostID,
                name: service.name,
                address: "\(service.name).local",
                lastSeen: Date()
            )
            discoveredLSPHosts[hostID] = displayLSPHost(record, paired: false, online: true)
            eventHandler?(.hosts(combinedHosts()))
        case .removed(let service):
            if let encodedID = service.txtRecord["id"], let hostID = Self.uuid(fromLowercaseHex: encodedID) {
                discoveredLSPHosts.removeValue(forKey: hostID)
                eventHandler?(.hosts(combinedHosts()))
            }
        case .failed:
            break
        }
    }

    private func lspHostID(_ id: HostID) -> UUID? {
        guard id.rawValue.hasPrefix("lsp:") else { return nil }
        return UUID(uuidString: String(id.rawValue.dropFirst(4)))
    }

    private static func uuid(fromLowercaseHex value: String) -> UUID? {
        guard value.count == 32, value.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
            return nil
        }
        let groups = [8, 4, 4, 4, 12]
        var cursor = value.startIndex
        var parts: [String] = []
        for length in groups {
            let end = value.index(cursor, offsetBy: length)
            parts.append(String(value[cursor..<end]))
            cursor = end
        }
        return UUID(uuidString: parts.joined(separator: "-"))
    }

    private static func stableLSPApplicationID(_ value: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return max(1, Int(hash & UInt64(Int.max)))
    }
}

@MainActor
final class LiveApplicationComposition {
    let preferences: PreferencesStore
    let clientService: LiveUmbraClientService
    let applicationService: UmbraApplicationService
    let streamWindow: StreamWindowController
    let runtimePreferenceResolver: RuntimeStreamingPreferencesResolver
    let supportLog: SupportLog?

    init() throws {
        let persistence: JSONFileStore<UmbraSnapshot> = try .applicationSupport()
        let lspProduct = try LSPProductClient.applicationSupport()
        preferences = PreferencesStore(snapshotStore: persistence)
        let supportLogger = Self.makeSupportLog()
        supportLog = supportLogger
        let startupTelemetry = SessionStartupTelemetryRecorder(
            diagnosticHandler: { [supportLogger] message in
                supportLogger?.record(source: "Startup", level: .info, message: message)
            }
        )
        streamWindow = try StreamWindowController(
            startupTelemetry: startupTelemetry,
            diagnosticHandler: { [supportLogger] message in
                supportLogger?.record(source: "Window", level: .info, message: message)
            }
        )

        let securePorts = SecurePortRegistry()
        let compatibilityUpdater = NVIDIAServerCompatibilityUpdater()
        let identityProvider = FileBackedClientIdentityProvider()
        let uniqueID = try identityProvider.clientID()
        let clientIdentity = try identityProvider.identity()
        let clientProvider = try AuthenticatedGameStreamClientProvider(
            uniqueID: uniqueID,
            identityProvider: identityProvider
        )
        let pairingAdapter = FactoryBackedHostPairingAdapter(
            uniqueID: uniqueID,
            securePortProvider: securePorts.port,
            identityProvider: identityProvider
        )
        let mediaCapabilities = AppleStreamingCapabilities.probe()
        runtimePreferenceResolver = RuntimeStreamingPreferencesResolver(
            streamWindow: streamWindow,
            audioOutputChannelCount: mediaCapabilities.audioOutputChannelCount
        )
        let mediaProvider = AppleStreamingMediaProvider(
            capabilities: mediaCapabilities,
            renderer: streamWindow.videoRenderer,
            diagnosticHandler: { [supportLogger] message in
                let isSuccess = message.hasPrefix("Video decoder produced")
                    || message.hasPrefix("Audio playback started")
                    || message.hasPrefix("Audio output start accepted")
                    || message.hasPrefix("Audio output started")
                    || message.hasPrefix("First decoded PCM buffer queued")
                    || message.hasPrefix("First non-silent PCM buffer queued")
                    || message.hasPrefix("Audio playback confirmed")
                    || message.hasPrefix("AudioQueue restarted")
                    || message.hasPrefix("Audio output summary")
                    || message.hasPrefix("First frame color")
                let isCapacityWarning = message.hasPrefix("AudioQueue rejected")
                    || message.hasPrefix("AudioQueue preserved chronological playback")
                let level: SupportLogLevel
                if isSuccess {
                    level = .info
                } else if isCapacityWarning {
                    level = .warning
                } else {
                    level = .error
                }
                supportLogger?.record(source: "Media", level: level, message: message)
            }
        )
        let motionPolicy = ControllerMotionPolicy()
        let output = StreamingSessionOutputAdapter(
            controllers: streamWindow.controllers,
            motionEnabler: streamWindow.controllers,
            motionPolicy: motionPolicy,
            hdrHandler: { [supportLogger] enabled, metadata in
                supportLogger?.record(
                    source: "Media",
                    level: .info,
                    message: enabled
                        ? "Host HDR mode is active; static metadata present: \(metadata != nil)."
                        : "Host HDR mode is inactive."
                )
            },
            statisticsHandler: { [weak streamWindow] statistics in
                streamWindow?.updateStreamingStatistics(statistics)
            },
            videoStatisticsHandler: { [weak streamWindow] statistics in
                streamWindow?.updateVideoPipelineStatistics(statistics)
            }
        )
        let appLifecycle = AppStreamLifecycleCoordinator(
            windowController: streamWindow,
            audio: mediaProvider.audioSessionController
        )
        let lifecycle = CompositeStreamSessionLifecycleCoordinator([
            appLifecycle,
            DiscordRichPresenceLifecycleCoordinator(),
        ])
        let streamDriver = NativeStreamSessionDriver(
            mediaProvider: mediaProvider,
            output: output,
            motionPolicy: motionPolicy,
            inputInstaller: streamWindow,
            lifecycle: lifecycle,
            microphonePreparer: SystemClientMicrophonePreparer(),
            diagnosticHandler: { [supportLogger] message in
                supportLogger?.record(source: "Moonlight", level: .debug, message: message)
            },
            startupTelemetry: startupTelemetry
        )
        applicationService = UmbraApplicationService(
            persistence: persistence,
            clientProvider: clientProvider,
            discovery: NetworkBonjourDiscovery(),
            discoveryEnabled: preferences.settings.enableMDNS,
            pairingAdapter: pairingAdapter,
            streamDriver: streamDriver,
            clientIdentityFingerprint: clientIdentity.persistenceFingerprint,
            startupTelemetry: startupTelemetry,
            maximumSupportedNVIDIAVersion: compatibilityUpdater.cachedMaximumVersion
        )
        clientService = LiveUmbraClientService(
            service: applicationService,
            preferences: preferences,
            securePorts: securePorts,
            preferenceResolver: { [runtimePreferenceResolver] preferences in
                runtimePreferenceResolver.resolveForStreaming(
                    preferences,
                    uiScreen: NSApp.keyWindow?.screen
                )
            },
            configurationWarningEvaluator: StreamingConfigurationWarningEvaluator(
                capabilities: mediaCapabilities
            ),
            lspProduct: lspProduct
        )
        streamWindow.onStopRequested = { [applicationService] quitHostApplication in
            _ = try? await applicationService.stopSession(
                quitHostApplication: quitHostApplication
            )
        }
        Task { await compatibilityUpdater.refresh(applicationService) }
    }

    func stopForApplicationTermination() async {
        await clientService.disconnectSession()
        _ = try? await applicationService.stopSession(quitHostApplication: false)
    }

    private static func makeSupportLog() -> SupportLog? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return try? SupportLog(configuration: .init(
            directoryURL: applicationSupport
                .appendingPathComponent("app.umbra.Umbra", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
        ))
    }
}
