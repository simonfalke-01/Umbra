import AppKit
import Combine
import Foundation
import ImageIO
import UmbraCLI
import UmbraCLIExecution
import UmbraCore
import UmbraDiagnostics
import UmbraIntegration
import UmbraLSP
import UmbraLSPTransport
import UmbraMedia
import UmbraMicrophone
import UmbraNetworking
import UmbraPairing
import UmbraServices

private extension CLILSPStopOutcome {
    var isLocallyStopped: Bool {
        switch self {
        case .notRunning, .stopped:
            true
        case .rejected, .transportFailed:
            false
        }
    }
}

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
    typealias LSPHostProbe = @MainActor @Sendable (UUID) async throws -> Void

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
    private let lspInputCapture: LSPAppKitInputCapture
    private weak var streamWindow: StreamWindowController?
    private let lspMediaCapabilities: AppleStreamingCapabilities
    private let lspFailureHandler: @Sendable (String) -> Void
    private let lspHostProbe: LSPHostProbe
    private var activeLSPHostID: UUID?
    private var activeLSPApplicationID: String?
    private var lspOwnerEndpoint: LSPCLIOwnerEndpoint?
    private var cliStopReplyPending = false
    private var didNotifyLSPSessionTermination = false
    private var plannedLSPRekeyTask: Task<Void, Never>?
    private var lspTelemetryTask: Task<Void, Never>?
    private var lspDeviceOfferTask: Task<Void, Never>?
    private var lspHostStatusTask: Task<Void, Never>?
    private var lspHostCheckInFlight = false
    private var lspHostCheckErrors: [UUID: String] = [:]
    private var latestLSPTelemetry: LSPTelemetrySnapshot?
    private var latestLSPReconnectTelemetry: LSPReconnectSnapshot?
    private var lspReconnectTasks: [UUID: Task<Void, Error>] = [:]
    private var eventHandler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?
    private var sessionWarningDeliveryState = SessionWarningDeliveryState()
    private var artworkLoadingTasks: [String: Task<Void, Never>] = [:]
    private var artworkLoadingIDs: [String: UUID] = [:]
    private let handlerInstallationTask: Task<Void, Never>
    private var serviceEventTask: Task<Void, Never>?
    private var discoveryPreferenceTask: Task<Void, Never>?
    private var lspPairingDiscoveryHandlerTask: Task<Void, Never>?
    private var lastLegacyHosts: [HostDisplayModel] = []
    private var lastLSPHosts: [HostDisplayModel] = []
    private var discoveredLSPHosts: [UUID: HostDisplayModel] = [:]
    private var onlineLSPHostIDs: Set<UUID> = []
    private var identityChangedLSPHostIDs: Set<UUID> = []
    private var latestLSPDiscoveryTokens: [String: UInt64] = [:]
    private var lspDiscoveryHostIDsByServiceID: [String: UUID] = [:]
    private var lspApplicationIDs: [HostID: [Int: String]] = [:]
    private var lspApplicationArtworkReferences: [HostID: [Int: String]] = [:]

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
        lspProduct: LSPProductClient? = nil,
        streamWindow: StreamWindowController? = nil,
        lspMediaCapabilities: AppleStreamingCapabilities = .probe(),
        lspFailureHandler: @escaping @Sendable (String) -> Void = { _ in },
        lspHostProbe: LSPHostProbe? = nil
    ) {
        self.service = service
        self.preferences = preferences
        self.securePorts = securePorts
        self.preferenceResolver = preferenceResolver
        self.configurationWarningEvaluator = configurationWarningEvaluator
        self.artworkCache = artworkCache
        self.maximumConcurrentArtworkRequests = max(1, maximumConcurrentArtworkRequests)
        self.lspProduct = lspProduct
        self.streamWindow = streamWindow
        self.lspInputCapture = LSPAppKitInputCapture(targetWindow: streamWindow?.inputCaptureWindow)
        self.lspMediaCapabilities = lspMediaCapabilities
        self.lspFailureHandler = lspFailureHandler
        self.lspHostProbe = lspHostProbe ?? { hostID in
            guard let lspProduct else { throw LSPTransportError.invalidState }
            _ = try await lspProduct.applications(hostID: hostID)
        }
        let (events, continuation) = AsyncStream<HostServiceEvent>.makeStream()
        handlerInstallationTask = Task { [service, continuation] in
            await service.setEventHandler { event in
                continuation.yield(event)
            }
        }
        lspPairingDiscoveryHandlerTask = Task { [weak self, lspProduct] in
            await lspProduct?.setPairingDiscoveryMutationHandler { [weak self] mutation in
                Task { @MainActor [weak self] in
                    self?.handleLSPPairingDiscoveryMutation(mutation)
                }
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
                            await self?.handleLSPDiscovery(event)
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
        lspPairingDiscoveryHandlerTask?.cancel()
        lspHostStatusTask?.cancel()
        lspDiscovery.stop()
        lspOwnerEndpoint?.stop()
        for task in artworkLoadingTasks.values { task.cancel() }
    }

    func waitUntilReady() async {
        await handlerInstallationTask.value
        await lspPairingDiscoveryHandlerTask?.value
    }

    func setEventHandler(_ handler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?) {
        eventHandler = handler
    }

    func discoverHosts() async throws -> [HostDisplayModel] {
        let initial = try await service.startMonitoring()
        lastLegacyHosts = initial.map(displayHost)
        do {
            try await refreshPersistedLSPHosts()
        } catch {
            lastLSPHosts = []
            eventHandler?(.sessionWarning(
                "LSP host storage is unavailable; legacy GameStream discovery remains active."
            ))
        }
        eventHandler?(.hosts(combinedHosts()))
        await refreshLSPReachability()
        startLSPHostStatusMonitoring()
        // Retry resolution on an explicit refresh even when Bonjour's service
        // set has not changed. A previous timeout must not strand a saved host.
        for discovered in lspDiscovery.discoveredServices {
            if let advertisedID = discovered.txtRecord["id"].flatMap(Self.uuid(fromLowercaseHex:)),
               onlineLSPHostIDs.contains(advertisedID) { continue }
            await handleLSPDiscovery(.added(discovered))
        }
        if !initial.isEmpty {
            lastLegacyHosts = try await service.refreshHosts().map(displayHost)
        }
        return combinedHosts()
    }

    func addHost(_ endpoint: HostEndpointInput) async throws -> HostDisplayModel {
        let port = endpoint.port.flatMap(UInt16.init(exactly:))
        return displayHost(try await service.addHost(address: endpoint.address, port: port))
    }

    func preparePairing(hostID: HostID) async throws -> PairingPreparation {
        guard let nativeHostID = lspHostID(hostID) else {
            return .init(
                pin: String(format: "%04d", Int.random(in: 0...9_999)),
                provisionalSPKIFingerprint: nil,
                requestedPermissions: [],
                effectivePermissions: []
            )
        }
        guard let lspProduct else {
            throw UmbraClientServiceError.unavailable("Native LSP pairing is unavailable in this build.")
        }
        var permissions: LSPPermission = [
            .browseApplications, .startOrAttach, .input, .stopOwnStream, .controllerOutput,
        ]
        if preferences.settings.lspPairMicrophonePermission || preferences.settings.clientMicrophoneEnabled {
            permissions.insert(.microphone)
        }
        if preferences.settings.lspPairQuitPermission {
            permissions.insert(.quitApplication)
        }
        let prompt = try await lspProduct.beginPairing(
            hostID: nativeHostID,
            requestedPermissions: permissions
        )
        return .init(
            pin: prompt.pin,
            provisionalSPKIFingerprint: prompt.host.provisionalSPKIFingerprint,
            requestedPermissions: Self.permissionNames(prompt.requestedPermissions),
            effectivePermissions: Self.permissionNames(prompt.effectivePermissions)
        )
    }

    func pairHost(_ request: PairingRequest) async throws -> HostDisplayModel {
        if let nativeHostID = lspHostID(request.hostID) {
            guard let lspProduct else {
                throw UmbraClientServiceError.unavailable("Native LSP pairing is unavailable in this build.")
            }
            let host = try await lspProduct.completePairing(hostID: nativeHostID)
            let display = displayLSPHost(
                host,
                paired: true,
                online: true,
                trust: try await lspProduct.trust(hostID: nativeHostID)
            )
            identityChangedLSPHostIDs.remove(nativeHostID)
            onlineLSPHostIDs.insert(nativeHostID)
            discoveredLSPHosts.removeValue(forKey: nativeHostID)
            upsertLSPHost(display)
            eventHandler?(.hosts(combinedHosts()))
            return display
        }
        return displayHost(try await service.pairHost(id: request.hostID.rawValue, pin: request.pin))
    }

    func cancelPairing(hostID: HostID) async {
        if let nativeHostID = lspHostID(hostID), let lspProduct {
            await lspProduct.cancelPairing(hostID: nativeHostID)
            return
        }
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
            onlineLSPHostIDs.remove(hostID)
            discoveredLSPHosts.removeValue(forKey: hostID)
            lspApplicationIDs.removeValue(forKey: id)
            lspApplicationArtworkReferences.removeValue(forKey: id)
            artworkLoadingTasks[id.rawValue]?.cancel()
            artworkLoadingTasks[id.rawValue] = nil
            artworkLoadingIDs[id.rawValue] = nil
            await artworkCache.removeHost(id.rawValue)
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
            try await configureLSPTransport(lspProduct)
            let applications = try await lspProduct.applications(hostID: hostID)
            var wireIDs: [Int: String] = [:]
            var artworkReferences: [Int: String] = [:]
            var display: [ApplicationDisplayModel] = []
            display.reserveCapacity(applications.count)
            for application in applications {
                var candidate = Self.stableLSPApplicationID(application.id)
                while let existing = wireIDs[candidate], existing != application.id {
                    candidate = candidate == Int.max ? 1 : candidate + 1
                }
                wireIDs[candidate] = application.id
                if LSPObjectReference.decode(application.imagePath) != nil {
                    artworkReferences[candidate] = application.imagePath
                }
                display.append(ApplicationDisplayModel(
                    id: ApplicationID(candidate),
                    hostID: id,
                    name: application.name,
                    artworkURL: nil,
                    isRunning: application.isRunning,
                    isHidden: false,
                    isDirectLaunch: false
                ))
            }
            lspApplicationIDs[id] = wireIDs
            lspApplicationArtworkReferences[id] = artworkReferences
            markLSPHostSession(hostID: hostID, runningApplicationID: display.first(where: \.isRunning)?.id)
            if !artworkReferences.isEmpty {
                let immutableArtworkReferences = artworkReferences
                startArtworkLoading(
                    hostID: id,
                    applicationIDs: display.map { $0.id.rawValue },
                    displayApplications: display,
                    loader: { [lspProduct] displayID in
                        guard let reference = immutableArtworkReferences[displayID] else {
                            throw UmbraClientServiceError.invalidInput("Missing LSP artwork reference.")
                        }
                        return try await lspProduct.applicationObject(
                            hostID: hostID,
                            reference: reference
                        )
                    }
                )
            }
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
            if activeLSPHostID == nativeHostID, activeLSPApplicationID == applicationID,
               await streamWindow?.focusExistingSession() == true {
                return
            }
            try Task.checkCancellation()
            let microphoneOffer = try await lspMicrophoneOffer()
            let resolved = preferenceResolver(preferences.settings).preferences
            try await startLSPStream(
                product: lspProduct,
                hostID: nativeHostID,
                applicationID: applicationID,
                applicationName: applicationID,
                displayApplicationID: id,
                resume: resume,
                preferences: resolved,
                microphoneOffer: microphoneOffer
            )
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

    /// Starts a CLI-resolved stream through the same native window, decoder, renderer, and input
    /// lifecycle used by the graphical application. The command-line resolver never owns media.
    func beginCLIStream(_ request: CLIStreamLaunchRequest) async throws -> CLILSPTelemetry? {
        guard let target = request.lsp else {
            _ = try await service.beginSession(request.intent)
            return nil
        }
        guard request.intent.hostID == "lsp:\(target.hostID.uuidString.lowercased())" else {
            throw UmbraClientServiceError.invalidInput("The resolved LSP host does not match the stream intent.")
        }
        guard let lspProduct else {
            throw UmbraClientServiceError.unavailable("Native LSP is unavailable in this build.")
        }
        let microphoneOffer = try await lspMicrophoneOffer(mode: target.microphone)
        try await startLSPStream(
            product: lspProduct,
            hostID: target.hostID,
            applicationID: target.applicationID,
            applicationName: target.applicationName,
            displayApplicationID: ApplicationID(request.intent.applicationID),
            resume: request.intent.kind == .resume,
            preferences: request.intent.preferences,
            microphoneOffer: microphoneOffer
        )
        guard target.emitTelemetry else { return nil }
        return try await lspTelemetry(hostID: target.hostID)
    }

    private func startLSPStream(
        product: LSPProductClient,
        hostID: UUID,
        applicationID: String,
        applicationName: String,
        displayApplicationID: ApplicationID,
        resume: Bool,
        preferences: StreamingPreferences,
        microphoneOffer: LSPMicrophoneOffer?
    ) async throws {
        guard activeLSPHostID == nil, lspOwnerEndpoint == nil else { throw LSPControlStatus.busy }
        guard lspMediaCapabilities.hasMetalDevice,
              let frameRate = preferences.normalizedFrameRate
        else { throw UmbraClientServiceError.unavailable("Native LSP requires Metal and a valid refresh rate.") }
        guard let streamWindow else {
            throw UmbraClientServiceError.unavailable("Native LSP hardware video is unavailable.")
        }
        // Reserve ownership before the first suspension in GUI and CLI startup.
        // A second instance must not send START or prepare another stream window
        // while this host is already owned locally.
        try installCLIOwnerEndpoint(hostID: hostID)
        let session: LSPClientSession
        var remoteStarted = false
        do {
            try await configureLSPTransport(product, preferences: preferences)
            try await streamWindow.prepareLSPVideo(
                applicationName: applicationName,
                preferences: preferences
            )
            session = try await product.startInput(
                hostID: hostID,
                applicationID: applicationID,
                resume: resume,
                pointerRate: UInt32(preferences.lspPointerRate),
                controllerRate: UInt32(preferences.lspControllerRate),
                sensorRate: UInt32(preferences.lspSensorRate),
                reconciliationRate: UInt32(preferences.lspReconciliationRate),
                microphoneOffer: microphoneOffer,
                capabilities: lspMediaCapabilities,
                preferences: preferences,
                refreshNumerator: frameRate.numerator,
                refreshDenominator: frameRate.denominator,
                decoderSurfaces: 3,
                maximumCaptureToPresentMicroseconds: UInt32(max(
                    10_000,
                    Int(2_000_000 * Double(frameRate.denominator) / Double(frameRate.numerator))
                ))
            )
            remoteStarted = true
            try lspInputCapture.transfer(to: session)
            activeLSPHostID = hostID
            activeLSPApplicationID = applicationID
            didNotifyLSPSessionTermination = false
        } catch {
            lspInputCapture.stop()
            if remoteStarted { _ = await product.stop(hostID: hostID) }
            await streamWindow.finish()
            lspOwnerEndpoint?.stop()
            lspOwnerEndpoint = nil
            activeLSPHostID = nil
            activeLSPApplicationID = nil
            throw error
        }
        markLSPHostSession(hostID: hostID, runningApplicationID: displayApplicationID)
        streamWindow.onTextCommit = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self, self.activeLSPHostID == hostID else { return }
                do {
                    try await self.lspInputCapture.performTextCommit {
                        try await product.sendText(hostID: hostID, text: text)
                    }
                } catch {
                    self.eventHandler?(.sessionWarning(
                        "LSP text input failed: \(error.localizedDescription)"
                    ))
                }
            }
        }
        installLSPReconnectHandler(session: session, hostID: hostID)
        scheduleLSPMaintenance(session: session, hostID: hostID)
    }

    func disconnectSession() async {
        guard activeLSPHostID != nil else {
            _ = try? await service.stopSession(quitHostApplication: false)
            return
        }
        let stopResult = await stopActiveLSPStream()
        switch stopResult {
        case .notRunning, .stopped:
            break
        case .rejected(let reason):
            eventHandler?(.sessionWarning("Lumen rejected remote STOP (\(reason)); local teardown completed."))
        case .transportFailed(let reason):
            eventHandler?(.sessionWarning("Remote STOP could not be confirmed: \(reason). Local teardown completed."))
        }
    }

    private func stopActiveLSPStream(
        preserveOwnerEndpointUntilReply: Bool = false
    ) async -> CLILSPStopOutcome {
        for task in lspReconnectTasks.values { task.cancel() }
        lspReconnectTasks.removeAll(keepingCapacity: true)
        plannedLSPRekeyTask?.cancel()
        plannedLSPRekeyTask = nil
        lspTelemetryTask?.cancel()
        lspTelemetryTask = nil
        lspDeviceOfferTask?.cancel()
        lspDeviceOfferTask = nil
        lspInputCapture.stop()
        streamWindow?.onTextCommit = nil
        guard let hostID = activeLSPHostID else { return .notRunning }
        let stopResult = await lspProduct?.stop(hostID: hostID) ?? .notRunning
        activeLSPHostID = nil
        activeLSPApplicationID = nil
        if !preserveOwnerEndpointUntilReply {
            cliStopReplyPending = false
            lspOwnerEndpoint?.stop()
            lspOwnerEndpoint = nil
        }
        markLSPHostSession(hostID: hostID, runningApplicationID: nil)
        await streamWindow?.finish()
        return switch stopResult {
        case .notRunning: .notRunning
        case .stopped: .stopped
        case .remoteRejected(let status): .rejected("status \(status.rawValue)")
        case .transportFailed(let error): .transportFailed(error.localizedDescription)
        }
    }

    func stopFromStreamWindow(quitHostApplication: Bool) async {
        if activeLSPHostID != nil {
            let outcome = await stopActiveLSPStream()
            notifyLSPSessionTerminated(succeeded: outcome.isLocallyStopped)
        } else {
            _ = try? await service.stopSession(quitHostApplication: quitHostApplication)
        }
    }

    private func installCLIOwnerEndpoint(hostID: UUID) throws {
        lspOwnerEndpoint = try LSPCLIOwnerEndpoint(
            hostID: hostID,
            handler: { [weak self] request in
                guard let self else {
                    return LSPCLIOwnerResponse(
                        error: LSPCLIOwnerIPCError.unavailable.localizedDescription,
                        stopKind: nil,
                        telemetry: nil
                    )
                }
                return await self.handleCLIOwnerRequest(request)
            },
            responseSentHandler: { [weak self] request, response in
                guard request.command == .stop else { return }
                await self?.finishCLIStopAfterReply(response)
            }
        )
    }

    private func handleCLIOwnerRequest(_ request: LSPCLIOwnerRequest) async -> LSPCLIOwnerResponse {
        guard request.hostID == activeLSPHostID else {
            return .init(
                error: LSPCLIOwnerIPCError.unavailable.localizedDescription,
                stopKind: nil,
                telemetry: nil
            )
        }
        do {
            switch request.command {
            case .attach:
                try await reconnectLSPInput(hostID: request.hostID, reason: .transportLoss)
                return .init(error: nil, stopKind: nil, telemetry: nil)
            case .stop:
                cliStopReplyPending = true
                return .init(
                    error: nil,
                    stopKind: stopKind(await stopActiveLSPStream(
                        preserveOwnerEndpointUntilReply: true
                    )),
                    telemetry: nil
                )
            case .quit:
                guard let applicationID = activeLSPApplicationID, let lspProduct else {
                    throw LSPTransportError.invalidState
                }
                try await lspProduct.quitApplication(
                    hostID: request.hostID,
                    applicationID: applicationID
                )
                activeLSPApplicationID = nil
                return .init(error: nil, stopKind: nil, telemetry: nil)
            case .telemetry:
                let value = try await lspTelemetry(hostID: request.hostID)
                return .init(
                    error: nil,
                    stopKind: nil,
                    telemetry: .init(value)
                )
            }
        } catch {
            return .init(error: error.localizedDescription, stopKind: nil, telemetry: nil)
        }
    }

    private func lspTelemetry(hostID: UUID) async throws -> CLILSPTelemetry {
        guard let session = await lspProduct?.currentSession(hostID: hostID) else {
            throw LSPTransportError.invalidState
        }
        let telemetry = try await session.telemetrySnapshot()
        let reconnect = await lspProduct?.reconnectTelemetry(hostID: hostID)
        let media = await lspProduct?.productTelemetry(hostID: hostID)
        return .init(
            lifecycle: String(describing: telemetry.lifecycle),
            receivedDatagrams: telemetry.receivedDatagrams,
            transmittedDatagrams: telemetry.transmittedDatagrams,
            droppedDatagrams: telemetry.droppedDatagrams,
            authenticationFailures: telemetry.authenticationFailures,
            currentUDPPayloadSize: telemetry.currentUDPPayloadSize,
            reconnectPhase: reconnect.map { String(describing: $0.phase) },
            completeFrameReceiveToVideoToolboxSubmit: media
                .flatMap(\.completeFrameReceiveToVideoToolboxSubmit)
                .map(CLILSPTimingDistribution.init),
            videoToolboxSubmitToDecodeCompletion: media
                .flatMap(\.videoToolboxSubmitToDecodeCompletion)
                .map(CLILSPTimingDistribution.init),
            completeFrameReceiveToMetalEnqueue: media
                .flatMap(\.completeFrameReceiveToMetalEnqueue)
                .map(CLILSPTimingDistribution.init),
            metalEnqueueToCommit: media
                .flatMap(\.metalEnqueueToCommit)
                .map(CLILSPTimingDistribution.init),
            audioReceiveToDecode: media
                .flatMap(\.audioReceiveToDecode)
                .map(CLILSPTimingDistribution.init),
            audioDecodeAndRenderEnqueue: media
                .flatMap(\.audioDecodeAndRenderEnqueue)
                .map(CLILSPTimingDistribution.init),
            audioUnderruns: media?.audioUnderruns,
            audioRebuffers: media?.audioRebuffers
        )
    }

    private func stopKind(_ outcome: CLILSPStopOutcome) -> String {
        switch outcome {
        case .notRunning: "not-running"
        case .stopped: "stopped"
        case .rejected(let reason): "rejected:\(reason)"
        case .transportFailed(let reason): "transport:\(reason)"
        }
    }

    private func finishCLIStopAfterReply(_ response: LSPCLIOwnerResponse) {
        guard cliStopReplyPending else { return }
        cliStopReplyPending = false
        lspOwnerEndpoint?.stop()
        lspOwnerEndpoint = nil
        let succeeded = response.error == nil
            && (response.stopKind == "stopped" || response.stopKind == "not-running")
        notifyLSPSessionTerminated(succeeded: succeeded)
    }

    private func notifyLSPSessionTerminated(succeeded: Bool, reason: String? = nil) {
        guard !didNotifyLSPSessionTermination else { return }
        didNotifyLSPSessionTermination = true
        if let reason {
            lspFailureHandler(reason)
            if onSessionTerminated != nil {
                FileHandle.standardError.write(Data((reason + "\n").utf8))
            }
        }
        onSessionTerminated?(succeeded)
    }

    /// Executes the product reconnect/rekey boundary without legacy fallback.
    func reconnectLSPInput(
        hostID: UUID,
        reason: LSPReconnectReason
    ) async throws {
        if let existing = lspReconnectTasks[hostID] {
            return try await existing.value
        }
        let task = Task { @MainActor [self] in
            try await performLSPReconnect(hostID: hostID, reason: reason)
        }
        lspReconnectTasks[hostID] = task
        do {
            try await task.value
            lspReconnectTasks.removeValue(forKey: hostID)
        } catch {
            lspReconnectTasks.removeValue(forKey: hostID)
            throw error
        }
    }

    private func performLSPReconnect(
        hostID: UUID,
        reason: LSPReconnectReason
    ) async throws {
        try Task.checkCancellation()
        guard let lspProduct else { throw UmbraClientServiceError.unavailable("Native LSP is unavailable.") }
        var publishedReplacement: LSPClientSession?
        do {
            let replacement = try await lspProduct.reconnectInput(
                hostID: hostID,
                reason: reason,
                quiesceOldCapture: { @MainActor [weak self] in
                    self?.lspInputCapture.stop()
                }
            )
            publishedReplacement = replacement
            try Task.checkCancellation()
            guard await lspProduct.isCurrentSession(replacement, hostID: hostID) else {
                throw CancellationError()
            }
            do {
                try lspInputCapture.transfer(to: replacement)
            } catch {
                await replacement.invalidateAuthorityAfterAmbiguousAttach()
                throw error
            }
            try Task.checkCancellation()
            guard await lspProduct.isCurrentSession(replacement, hostID: hostID) else {
                lspInputCapture.stop()
                throw CancellationError()
            }
            await lspProduct.markCaptureTransferred(hostID: hostID, session: replacement)
            try Task.checkCancellation()
            guard await lspProduct.isCurrentSession(replacement, hostID: hostID) else {
                lspInputCapture.stop()
                throw CancellationError()
            }
            installLSPReconnectHandler(session: replacement, hostID: hostID)
            scheduleLSPMaintenance(session: replacement, hostID: hostID)
        } catch is CancellationError {
            lspInputCapture.stop()
            if let publishedReplacement {
                await publishedReplacement.invalidateAuthorityAfterAmbiguousAttach()
            }
            throw CancellationError()
        } catch {
            if let current = await lspProduct.currentSession(hostID: hostID),
               await current.state == .inputActive {
                try? lspInputCapture.transfer(to: current)
            }
            throw error
        }
    }

    private func installLSPReconnectHandler(session: LSPClientSession, hostID: UUID) {
        session.setTerminationHandler { [weak self, weak session] termination in
            guard let session else { return }
            Task { @MainActor [weak self, session] in
                guard let self else { return }
                guard await self.lspProduct?.isCurrentSession(session, hostID: hostID) == true else { return }
                self.plannedLSPRekeyTask?.cancel()
                self.lspTelemetryTask?.cancel()
                self.lspDeviceOfferTask?.cancel()
                self.lspInputCapture.stop()
                self.activeLSPHostID = nil
                self.activeLSPApplicationID = nil
                if !self.cliStopReplyPending {
                    self.lspOwnerEndpoint?.stop()
                    self.lspOwnerEndpoint = nil
                }
                self.markLSPHostSession(hostID: hostID, runningApplicationID: nil)
                self.streamWindow?.onTextCommit = nil
                await self.streamWindow?.finish()
                switch termination {
                case .streamEnded:
                    self.eventHandler?(.sessionEnded)
                    if !self.cliStopReplyPending {
                        self.notifyLSPSessionTerminated(succeeded: true)
                    }
                case .failed(let error):
                    self.eventHandler?(.sessionWarning("Native LSP stream failed: \(error.localizedDescription)"))
                    if !self.cliStopReplyPending {
                        self.notifyLSPSessionTerminated(
                            succeeded: false,
                            reason: "Native LSP stream failed: \(error.localizedDescription)"
                        )
                    }
                }
            }
        }
        session.setTransportLifecycleHandler { [weak self, weak session] lifecycle in
            guard lifecycle == .failed, let session else { return }
            Task { @MainActor [weak self, session] in
                guard let self else { return }
                guard await self.lspProduct?.isCurrentSession(session, hostID: hostID) == true else { return }
                do {
                    try await self.reconnectLSPInput(hostID: hostID, reason: .transportLoss)
                    self.eventHandler?(.sessionWarning("Native LSP input reconnected with fresh security keys."))
                } catch {
                    self.plannedLSPRekeyTask?.cancel()
                    self.lspTelemetryTask?.cancel()
                    self.lspDeviceOfferTask?.cancel()
                    self.lspInputCapture.stop()
                    self.activeLSPHostID = nil
                    self.activeLSPApplicationID = nil
                    if !self.cliStopReplyPending {
                        self.lspOwnerEndpoint?.stop()
                        self.lspOwnerEndpoint = nil
                    }
                    self.markLSPHostSession(hostID: hostID, runningApplicationID: nil)
                    self.streamWindow?.onTextCommit = nil
                    await self.lspProduct?.failSession(hostID: hostID)
                    await self.streamWindow?.finish()
                    self.eventHandler?(.sessionWarning("Native LSP reconnect failed: \(error.localizedDescription)"))
                    if !self.cliStopReplyPending {
                        self.notifyLSPSessionTerminated(
                            succeeded: false,
                            reason: "Native LSP reconnect failed: \(error.localizedDescription)"
                        )
                    }
                }
            }
        }
    }

    private func scheduleLSPMaintenance(session: LSPClientSession, hostID: UUID) {
        plannedLSPRekeyTask?.cancel()
        lspTelemetryTask?.cancel()
        lspDeviceOfferTask?.cancel()
        plannedLSPRekeyTask = Task { @MainActor [weak self, session] in
            do {
                try await Task.sleep(for: .seconds(30 * 60))
                guard !Task.isCancelled, let self,
                      await self.lspProduct?.isCurrentSession(session, hostID: hostID) == true else { return }
                try await self.reconnectLSPInput(hostID: hostID, reason: .plannedRekey)
            } catch is CancellationError {
                return
            } catch {
                self?.eventHandler?(.sessionWarning("Native LSP planned rekey failed: \(error.localizedDescription)"))
            }
        }
        lspTelemetryTask = Task { @MainActor [weak self, session] in
            while !Task.isCancelled {
                guard let self,
                      await self.lspProduct?.isCurrentSession(session, hostID: hostID) == true else { return }
                self.latestLSPTelemetry = try? await session.telemetrySnapshot()
                self.latestLSPReconnectTelemetry = await self.lspProduct?.reconnectTelemetry(hostID: hostID)
                if let telemetry = self.latestLSPTelemetry {
                    let devices = await self.lspProduct?.deviceRateTelemetry(hostID: hostID) ?? []
                    let productTelemetry = await self.lspProduct?.productTelemetry(hostID: hostID)
                    let nativeTiming = try? await self.lspProduct?.nativeTimingTelemetry(hostID: hostID)
                    if let decoder = productTelemetry?.videoDecoderStatistics {
                        self.streamWindow?.updateVideoPipelineStatistics(decoder)
                    }
                    self.streamWindow?.updateLSPStatistics(
                        telemetry,
                        reconnect: self.latestLSPReconnectTelemetry,
                        devices: devices,
                        product: productTelemetry,
                        nativeTiming: nativeTiming ?? nil
                    )
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        lspDeviceOfferTask = Task { @MainActor [weak self, session] in
            while !Task.isCancelled {
                guard let self,
                      await self.lspProduct?.isCurrentSession(session, hostID: hostID) == true else { return }
                do {
                    try await self.lspProduct?.drainDeviceOffers(hostID: hostID)
                } catch is CancellationError {
                    return
                } catch {
                    self.eventHandler?(.sessionWarning(
                        "LSP device rate negotiation failed and will retry: \(error.localizedDescription)"
                    ))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func configureLSPTransport(
        _ product: LSPProductClient,
        preferences explicitPreferences: StreamingPreferences? = nil
    ) async throws {
        let settings = explicitPreferences ?? preferenceResolver(preferences.settings).preferences
        let profile: LSPTransportProfile
        switch settings.lspNetworkProfile {
        case .adaptiveLowLatency:
            profile = .adaptiveLowLatency
        case .competitionLAN:
            guard let capacity = UInt32(exactly: settings.lspCompetitionCapacityMbps), capacity > 0 else {
                throw UmbraClientServiceError.invalidInput(
                    "Competition LSP requires an explicit positive capacity ceiling."
                )
            }
            profile = .competitionLAN(capacityMbps: capacity)
        }
        try await product.configureTransport(.init(profile: profile))
    }

    private func lspMicrophoneOffer() async throws -> LSPMicrophoneOffer? {
        let settings = preferences.settings
        return try await lspMicrophoneOffer(
            enabled: settings.clientMicrophoneEnabled,
            required: settings.clientMicrophoneRequired
        )
    }

    private func lspMicrophoneOffer(mode: CLILSPMicrophoneMode) async throws -> LSPMicrophoneOffer? {
        switch mode {
        case .off:
            return nil
        case .optional:
            return try await lspMicrophoneOffer(enabled: true, required: false)
        case .required:
            return try await lspMicrophoneOffer(enabled: true, required: true)
        }
    }

    private func lspMicrophoneOffer(
        enabled: Bool,
        required: Bool
    ) async throws -> LSPMicrophoneOffer? {
        guard enabled else { return nil }
        let authorization = SystemClientMicrophoneAuthorization()
        let status = await authorization.requestAuthorization()
        guard status.permitsCapture else {
            if required {
                throw UmbraClientServiceError.unavailable(
                    "Microphone forwarding is required, but macOS microphone access is not available."
                )
            }
            return nil
        }
        guard AudioQueueMicrophoneCapture.isAvailable() else {
            if required {
                throw UmbraClientServiceError.unavailable(
                    "Microphone forwarding is required, but no usable AudioQueue input is available."
                )
            }
            return nil
        }
        return LSPMicrophoneOffer(
            maximumBitrate: 64_000,
            inbandFEC: true,
            dtx: true,
            required: required
        )
    }

    func quitApplication(id: ApplicationID, on hostID: HostID) async throws {
        if let nativeHostID = lspHostID(hostID) {
            guard let applicationID = lspApplicationIDs[hostID]?[id.rawValue], let lspProduct else {
                throw UmbraClientServiceError.invalidInput("The selected native LSP application is no longer available.")
            }
            try await lspProduct.quitApplication(hostID: nativeHostID, applicationID: applicationID)
            return
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
        online: Bool,
        provisionalSPKIFingerprint: String? = nil,
        nameIsUnverified: Bool = false,
        trust: LSPTrustRecord? = nil,
        identityChanged: Bool = false
    ) -> HostDisplayModel {
        var details = [
            "Protocol: Lumen Streaming Protocol",
            "Address: \(host.address):\(host.port)",
            "Trust: \(identityChanged ? "Identity changed — re-pair required" : (paired ? "Paired" : "PIN pairing required"))",
        ]
        if nameIsUnverified {
            details.append("Discovery name (unverified): \(host.name)")
        }
        if let provisionalSPKIFingerprint {
            details.append("Provisional SPKI: \(provisionalSPKIFingerprint)")
        }
        if let domain = host.discoveryDomain {
            details.append("Bonjour domain: \(domain)")
        }
        if let interfaceName = host.interfaceName {
            details.append("Network interface: \(interfaceName)")
        }
        if let trust {
            details.append("Effective permissions: \(Self.permissionNames(trust.permissions).joined(separator: ", "))")
        }
        return HostDisplayModel(
            id: HostID("lsp:\(host.hostID.uuidString.lowercased())"),
            name: host.name,
            status: online && !identityChanged ? .online : .offline,
            isPaired: paired && !identityChanged,
            hasActiveSession: false,
            canWake: false,
            isServerSupported: true,
            details: details.joined(separator: "\n")
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
            if let hostID = lspHostID(host.id), identityChangedLSPHostIDs.contains(hostID) {
                continue
            }
            nativeByID[host.id] = host
        }
        return lastLegacyHosts + nativeByID.values
    }

    private func refreshPersistedLSPHosts() async throws {
        guard let lspProduct else {
            lastLSPHosts = []
            return
        }
        var persisted: [(LSPHostRecord, LSPTrustRecord?)] = []
        for host in try await lspProduct.hosts() {
            persisted.append((host, try await lspProduct.trust(hostID: host.hostID)))
        }
        // Read presence only after storage awaits finish: discovery may have
        // marked a host online while the saved records were being loaded.
        lastLSPHosts = persisted.map { host, trust in
            displayLSPHost(
                host,
                paired: trust != nil,
                online: onlineLSPHostIDs.contains(host.hostID),
                trust: trust,
                identityChanged: identityChangedLSPHostIDs.contains(host.hostID)
            )
        }
    }

    private func upsertLSPHost(_ host: HostDisplayModel) {
        lastLSPHosts.removeAll { $0.id == host.id }
        lastLSPHosts.append(host)
    }

    /// Checks saved paired hosts through authenticated LSP, independently of Bonjour resolution.
    /// APPLICATIONS is read-only and reuses an existing session without issuing START or ATTACH.
    private func refreshLSPReachability() async {
        guard !lspHostCheckInFlight, lspOwnerEndpoint == nil, lspReconnectTasks.isEmpty else { return }
        lspHostCheckInFlight = true
        defer { lspHostCheckInFlight = false }
        let hostIDs = lastLSPHosts.filter(\.isPaired).compactMap { lspHostID($0.id) }
        for hostID in hostIDs {
            guard !Task.isCancelled, lspOwnerEndpoint == nil else { return }
            let reachable: Bool
            do {
                try await lspHostProbe(hostID)
                reachable = true
                lspHostCheckErrors.removeValue(forKey: hostID)
            } catch {
                guard !Task.isCancelled else { return }
                reachable = false
                let message = error.localizedDescription
                if lspHostCheckErrors[hostID] != message {
                    lspHostCheckErrors[hostID] = message
                    lspFailureHandler("LSP host check failed for \(hostID): \(message)")
                }
            }
            guard lspOwnerEndpoint == nil else { return }
            guard let index = lastLSPHosts.firstIndex(where: { lspHostID($0.id) == hostID }) else { continue }
            if reachable {
                onlineLSPHostIDs.insert(hostID)
            } else {
                onlineLSPHostIDs.remove(hostID)
            }
            let status: HostConnectionStatus = reachable ? .online : .offline
            if lastLSPHosts[index].status != status {
                lastLSPHosts[index].status = status
                eventHandler?(.hosts(combinedHosts()))
            }
        }
    }

    /// Retries idle-host checks at the existing legacy monitor's three-second cadence.
    private func startLSPHostStatusMonitoring() {
        guard lspHostStatusTask == nil else { return }
        lspHostStatusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await self?.refreshLSPReachability()
            }
        }
    }

    private func markLSPHostSession(
        hostID: UUID,
        runningApplicationID: ApplicationID?
    ) {
        let displayID = HostID("lsp:\(hostID.uuidString.lowercased())")
        if let index = lastLSPHosts.firstIndex(where: { $0.id == displayID }) {
            lastLSPHosts[index].hasActiveSession = runningApplicationID != nil
            lastLSPHosts[index].runningApplicationID = runningApplicationID
        }
        if var discovered = discoveredLSPHosts[hostID] {
            discovered.hasActiveSession = runningApplicationID != nil
            discovered.runningApplicationID = runningApplicationID
            discoveredLSPHosts[hostID] = discovered
        }
        eventHandler?(.hosts(combinedHosts()))
    }

    private func handleLSPDiscovery(_ event: DiscoveryEvent) async {
        switch event {
        case .added(let service), .updated(_, let service):
            latestLSPDiscoveryTokens[service.id] = service.changeToken
            guard let resolved = await LSPBonjourTXTResolver().resolve(service),
                  latestLSPDiscoveryTokens[service.id] == service.changeToken,
                  let candidate = LSPDiscovery.pairingHost(
                    from: resolved.service,
                    resolvedEndpoint: resolved.endpoint
                  ) else { return }
            lspDiscoveryHostIDsByServiceID[service.id] = candidate.hostID
            if let lspProduct {
                let refresh: LSPPairedDiscoveryRefresh
                do {
                    refresh = try await lspProduct.refreshPairedDiscovery(candidate)
                } catch {
                    eventHandler?(.sessionWarning(
                        "Couldn’t securely refresh discovered LSP host state: \(error.localizedDescription)"
                    ))
                    return
                }
                guard latestLSPDiscoveryTokens[service.id] == service.changeToken else { return }
                _ = await lspProduct.registerDiscoveredPairingHost(candidate)
                guard latestLSPDiscoveryTokens[service.id] == service.changeToken else { return }
                switch refresh {
                case .matched(let host, let trust):
                    applyMatchedLSPHost(host, trust: trust)
                    return
                case .identityChanged(let expected, let advertised):
                    identityChangedLSPHostIDs.insert(candidate.hostID)
                    onlineLSPHostIDs.remove(candidate.hostID)
                    let record = LSPHostRecord(
                        hostID: candidate.hostID,
                        name: candidate.name,
                        address: candidate.host,
                        port: candidate.port,
                        lastSeen: Date(),
                        discoveryDomain: candidate.domain,
                        interfaceName: candidate.interfaceName
                    )
                    var display = displayLSPHost(
                        record,
                        paired: false,
                        online: true,
                        provisionalSPKIFingerprint: candidate.provisionalSPKIFingerprint,
                        nameIsUnverified: true,
                        identityChanged: true
                    )
                    display.details += "\nStored SPKI: \(Self.groupedFingerprint(expected))"
                    display.details += "\nAdvertised SPKI: \(Self.groupedFingerprint(advertised))"
                    discoveredLSPHosts[candidate.hostID] = display
                    eventHandler?(.hosts(combinedHosts()))
                    return
                case .unpaired:
                    break
                }
            }
            let displayedCandidate: LSPDiscoveredPairingHost
            if let lspProduct {
                displayedCandidate = await lspProduct.registerDiscoveredPairingHost(candidate)
            } else {
                displayedCandidate = candidate
            }
            let record = LSPHostRecord(
                hostID: displayedCandidate.hostID,
                name: displayedCandidate.name,
                address: displayedCandidate.host,
                port: displayedCandidate.port,
                lastSeen: Date(),
                discoveryDomain: displayedCandidate.domain,
                interfaceName: displayedCandidate.interfaceName
            )
            discoveredLSPHosts[displayedCandidate.hostID] = displayLSPHost(
                record,
                paired: false,
                online: true,
                provisionalSPKIFingerprint: displayedCandidate.provisionalSPKIFingerprint,
                nameIsUnverified: true
            )
            eventHandler?(.hosts(combinedHosts()))
        case .removed(let service):
            latestLSPDiscoveryTokens.removeValue(forKey: service.id)
            let hostID = lspDiscoveryHostIDsByServiceID.removeValue(forKey: service.id) ??
                service.txtRecord["id"].flatMap(Self.uuid(fromLowercaseHex:))
            if let hostID {
                let canRemove: Bool
                if let lspProduct {
                    canRemove = await lspProduct.unregisterDiscoveredPairingHost(
                        hostID: hostID,
                        discoveryServiceID: service.id
                    )
                } else {
                    canRemove = true
                }
                if canRemove {
                    discoveredLSPHosts.removeValue(forKey: hostID)
                }
                if lspDiscoveryHostIDsByServiceID.values.contains(hostID) { return }
                onlineLSPHostIDs.remove(hostID)
                identityChangedLSPHostIDs.remove(hostID)
                await markPersistedLSPHostOffline(hostID)
                eventHandler?(.hosts(combinedHosts()))
            }
        case .failed:
            break
        }
    }

    /// Publishes a discovery record whose stable host ID and SPKI matched saved trust.
    func applyMatchedLSPHost(_ host: LSPHostRecord, trust: LSPTrustRecord) {
        identityChangedLSPHostIDs.remove(host.hostID)
        onlineLSPHostIDs.insert(host.hostID)
        discoveredLSPHosts.removeValue(forKey: host.hostID)
        upsertLSPHost(displayLSPHost(host, paired: true, online: true, trust: trust))
        eventHandler?(.hosts(combinedHosts()))
    }

    func handleLSPPairingDiscoveryMutation(_ mutation: LSPPairingDiscoveryMutation) {
        switch mutation {
        case .replaced(let oldHostID, let host):
            discoveredLSPHosts.removeValue(forKey: oldHostID)
            let record = LSPHostRecord(
                hostID: host.hostID,
                name: host.name,
                address: host.host,
                port: host.port,
                lastSeen: Date(),
                discoveryDomain: host.domain,
                interfaceName: host.interfaceName
            )
            discoveredLSPHosts[host.hostID] = displayLSPHost(
                record,
                paired: false,
                online: true,
                provisionalSPKIFingerprint: host.provisionalSPKIFingerprint,
                nameIsUnverified: true
            )
        case .removed(let hostID):
            discoveredLSPHosts.removeValue(forKey: hostID)
        }
        eventHandler?(.hosts(combinedHosts()))
    }

    private func markPersistedLSPHostOffline(_ hostID: UUID) async {
        guard let lspProduct,
              let host = try? await lspProduct.hosts().first(where: { $0.hostID == hostID }) else {
            return
        }
        upsertLSPHost(displayLSPHost(
            host,
            paired: true,
            online: false,
            trust: try? await lspProduct.trust(hostID: hostID)
        ))
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

    private static func permissionNames(_ permissions: LSPPermission) -> [String] {
        [
            (LSPPermission.browseApplications, "Browse applications"),
            (.startOrAttach, "Start or attach streams"),
            (.input, "Keyboard, pointer, controller, and text input"),
            (.microphone, "Microphone forwarding"),
            (.stopOwnStream, "Stop own stream"),
            (.quitApplication, "Quit hosted application"),
            (.controllerOutput, "Controller rumble, lights, and haptics"),
        ].compactMap { permissions.contains($0.0) ? $0.1 : nil }
    }

    private static func groupedFingerprint(_ bytes: Data) -> String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 8).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(8, hex.count - offset))
            return String(hex[start..<end])
        }.joined(separator: " ")
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
        let lspProduct = try LSPProductClient.applicationSupport(videoRenderer: streamWindow.videoRenderer)

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
            lspProduct: lspProduct,
            streamWindow: streamWindow,
            lspMediaCapabilities: mediaCapabilities,
            lspFailureHandler: { [supportLogger] message in
                supportLogger?.record(source: "LSP", level: .error, message: message)
            }
        )
        streamWindow.onStopRequested = { [weak clientService] quitHostApplication in
            await clientService?.stopFromStreamWindow(quitHostApplication: quitHostApplication)
        }
        Task { await compatibilityUpdater.refresh(applicationService) }
    }

    func stopForApplicationTermination() async {
        await clientService.disconnectSession()
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
