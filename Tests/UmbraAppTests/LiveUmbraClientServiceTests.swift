import Foundation
import UmbraCore
import UmbraNetworking
import UmbraProtocolV3
import UmbraServices
import XCTest
@testable import UmbraApp

@MainActor
final class LiveUmbraClientServiceTests: XCTestCase {
    func testRuntimeResolutionBuildsGUIIntentWithoutDroppingPolicy() {
        let runtime = makeDistinctRuntimeResolution()

        let intent = runtime.sessionIntent(
            hostID: "gui-host",
            applicationID: 7,
            kind: .launch
        )

        XCTAssertEqual(intent.hostID, "gui-host")
        XCTAssertEqual(intent.applicationID, 7)
        XCTAssertEqual(intent.preferences, runtime.preferences)
        XCTAssertEqual(intent.clientRefreshRateX100, runtime.clientRefreshRateX100)
        XCTAssertEqual(intent.effectivePolicy, runtime.effectivePolicy)
    }

    func testRuntimeResolutionUpdatesCLIIntentWithoutRecomputingPolicy() {
        let runtime = makeDistinctRuntimeResolution()
        var originalPreferences = StreamingPreferences.default
        originalPreferences.optimizationMode = .quality
        let original = SessionIntent(
            hostID: "cli-host",
            applicationID: 9,
            kind: .resume,
            preferences: originalPreferences
        )

        let intent = runtime.applying(to: original)

        XCTAssertEqual(intent.hostID, original.hostID)
        XCTAssertEqual(intent.applicationID, original.applicationID)
        XCTAssertEqual(intent.kind, original.kind)
        XCTAssertEqual(intent.preferences, runtime.preferences)
        XCTAssertEqual(intent.clientRefreshRateX100, runtime.clientRefreshRateX100)
        XCTAssertEqual(intent.effectivePolicy, runtime.effectivePolicy)
    }

    func testRuntimeResolverDisablesHDRWhenSelectedDisplayCannotPresentIt() {
        var preferences = StreamingPreferences.default
        preferences.enableHDR = true
        let resolver = RuntimeStreamingPreferencesResolver(
            audioOutputChannelCount: 2,
            displayResolver: { preferences, _ in preferences },
            hdrDisplaySupportResolver: HDRDisplaySupportResolver { _, _ in false }
        )

        let resolved = resolver.resolve(preferences, uiScreen: nil)

        XCTAssertFalse(resolved.enableHDR)
        XCTAssertTrue(preferences.enableHDR)
    }

    private func makeDistinctRuntimeResolution() -> RuntimeStreamingResolution {
        var runtimePreferences = StreamingPreferences.default
        runtimePreferences.optimizationMode = .quality
        runtimePreferences.enableVSync = true
        runtimePreferences.framePacing = true
        var policyPreferences = runtimePreferences
        policyPreferences.optimizationMode = .latency
        policyPreferences.enableVSync = false
        policyPreferences.framePacing = false
        return RuntimeStreamingResolution(
            preferences: runtimePreferences,
            clientRefreshRateX100: 14_400,
            effectivePolicy: .resolve(for: policyPreferences)
        )
    }

    func testRuntimeResolverPreservesHDRWhenSelectedDisplaySupportsIt() {
        var preferences = StreamingPreferences.default
        preferences.enableHDR = true
        let resolver = RuntimeStreamingPreferencesResolver(
            audioOutputChannelCount: 2,
            displayResolver: { preferences, _ in preferences },
            hdrDisplaySupportResolver: HDRDisplaySupportResolver { _, _ in true }
        )

        XCTAssertTrue(resolver.resolve(preferences, uiScreen: nil).enableHDR)
    }

    func testRuntimeResolverUsesResolved60HzDisplayFor120FPSStreamWithoutPersistingIt() {
        var preferences = StreamingPreferences.default
        preferences.fps = 120
        let resolver = RuntimeStreamingPreferencesResolver(
            audioOutputChannelCount: 2,
            displayResolver: { preferences, _ in preferences },
            displayRefreshRateResolver: { _, _ in 60 }
        )

        let resolution = resolver.resolveForStreaming(preferences, uiScreen: nil)

        XCTAssertEqual(resolution.preferences.fps, 120)
        XCTAssertEqual(resolution.clientRefreshRateX100, 6_000)
        XCTAssertEqual(preferences.fps, 120)
    }

    func testRuntimeResolverLeavesUnknownDisplayRefreshUnspecified() {
        let preferences = StreamingPreferences.default
        let resolver = RuntimeStreamingPreferencesResolver(
            audioOutputChannelCount: 2,
            displayResolver: { preferences, _ in preferences },
            displayRefreshRateResolver: { _, _ in nil }
        )

        let resolution = resolver.resolveForStreaming(preferences, uiScreen: nil)

        XCTAssertNil(resolution.clientRefreshRateX100)
    }

    func testRuntimeResolverCarriesOneImmutableLatencyPolicyPerSession() {
        var preferences = StreamingPreferences.default
        preferences.optimizationMode = .latency
        preferences.enableVSync = false
        preferences.framePacing = false
        let resolver = RuntimeStreamingPreferencesResolver(
            audioOutputChannelCount: 2,
            displayResolver: { preferences, _ in preferences }
        )

        let resolution = resolver.resolveForStreaming(preferences, uiScreen: nil)

        XCTAssertEqual(resolution.effectivePolicy.mode, .latency)
        XCTAssertEqual(resolution.effectivePolicy.inputCoalescingWindow, .microseconds(250))
        XCTAssertEqual(
            resolution.effectivePolicy.inputDeliveryIntent,
            .stateBasedUnreliableSequenced
        )
        XCTAssertEqual(resolution.effectivePolicy.maximumDecodeSubmissions, 4)
        XCTAssertEqual(resolution.effectivePolicy.maximumCompressedDecodeQueueFrames, 1)
        XCTAssertEqual(resolution.effectivePolicy.rendererQueueDepth, 1)
        XCTAssertEqual(resolution.effectivePolicy.presentationIntent, .immediateTearingAllowed)
        XCTAssertEqual(resolution.effectivePolicy.frameSchedulingIntent, .immediate)
        XCTAssertEqual(resolution.effectivePolicy.decoderIntent, .hardwareOnly)
        XCTAssertEqual(resolution.effectivePolicy.codecIntent, .lowestMeasuredP99)
        XCTAssertEqual(resolution.effectivePolicy.chromaIntent, .bandwidthAdaptive420)
        XCTAssertEqual(resolution.effectivePolicy.fecIntent, .adaptiveLANLow)
        XCTAssertTrue(resolution.effectivePolicy.measurementEnabled)
    }

    func testRuntimeResolverPreservesAdvancedOverridesAndResolvesConflictsDeterministically() {
        var preferences = StreamingPreferences.default
        preferences.optimizationMode = .quality
        preferences.enableVSync = false
        preferences.framePacing = true
        preferences.videoDecoderPreference = .software
        preferences.videoCodecPreference = .av1
        preferences.rendererPreference = .avSampleBufferDisplayLayer
        let resolver = RuntimeStreamingPreferencesResolver(
            audioOutputChannelCount: 2,
            displayResolver: { preferences, _ in preferences }
        )

        let resolution = resolver.resolveForStreaming(preferences, uiScreen: nil)
        let policy = resolution.effectivePolicy

        XCTAssertEqual(policy.mode, .quality)
        XCTAssertTrue(policy.vsyncDefault)
        XCTAssertFalse(policy.vsyncEnabled)
        XCTAssertEqual(policy.presentationIntent, .immediateTearingAllowed)
        XCTAssertEqual(policy.frameSchedulingIntent, .immediate)
        XCTAssertEqual(policy.decoderIntent, .softwareOnly)
        XCTAssertEqual(policy.codecIntent, .highestFidelity10Bit)
        XCTAssertEqual(policy.advancedOverrides.videoCodecPreference, .av1)
        XCTAssertEqual(
            policy.advancedOverrides.rendererPreference,
            .avSampleBufferDisplayLayer
        )
        XCTAssertFalse(policy.advancedOverrides.enableVSync)
        XCTAssertTrue(policy.advancedOverrides.framePacing)
        XCTAssertFalse(resolution.preferences.enableVSync)
        XCTAssertFalse(resolution.preferences.framePacing)
        XCTAssertTrue(preferences.framePacing, "Resolution must not mutate stored preferences.")
    }

    func testDisplayHDRDowngradeEmitsOneConfigurationWarning() async throws {
        let hostID = "host-hdr-warning"
        let application = StreamApplication(id: 7, name: "Desktop", hdrSupported: true)
        let endpoint = NetworkEndpoint(hostname: "host.local")
        let host = StreamHost(
            uuid: hostID,
            name: "Host",
            localAddress: endpoint,
            serverCertificate: Data([1]),
            applications: [application],
            status: .online,
            pairState: .paired,
            activeAddress: endpoint,
            activeHTTPSPort: NetworkEndpoint.defaultHTTPSPort
        )
        let applicationService = UmbraApplicationService(
            persistence: LiveServiceMemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            clientProvider: CatalogClientProvider(client: CatalogGameStreamClient(
                applications: [],
                failedArtworkIDs: [],
                catalogRefreshFailure: .none
            )),
            discovery: nil,
            pollInterval: .seconds(3_600)
        )
        let defaultsName = "Umbra.LiveUmbraClientServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update(\.enableHDR, to: true)
        let client = LiveUmbraClientService(
            service: applicationService,
            preferences: preferences,
            securePorts: SecurePortRegistry(),
            preferenceResolver: { requested in
                var resolved = requested
                resolved.enableHDR = false
                return RuntimeStreamingResolution(preferences: resolved)
            }
        )
        var warningEvents: [[String]] = []
        client.setEventHandler { event in
            if case let .configurationWarnings(warnings) = event {
                warningEvents.append(warnings)
            }
        }

        do {
            try await client.launchApplication(
                id: ApplicationID(application.id),
                on: HostID(hostID),
                resume: false
            )
        } catch {
            // The fixture has no stream driver; the preflight warning is emitted before launch.
        }

        XCTAssertEqual(warningEvents, [[
            "The selected display cannot present HDR. Umbra will use SDR for this stream."
        ]])
    }

    func testMDNSPreferenceTakesEffectWhileMonitoringIsRunning() async throws {
        let defaultsName = "Umbra.LiveUmbraClientServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update(\.enableMDNS, to: false)
        let discovery = RecordingBonjourDiscovery()
        let applicationService = UmbraApplicationService(
            persistence: LiveServiceMemorySnapshotStore(UmbraSnapshot()),
            clientProvider: CatalogClientProvider(client: CatalogGameStreamClient(
                applications: [],
                failedArtworkIDs: [],
                catalogRefreshFailure: .none
            )),
            discovery: discovery,
            discoveryEnabled: preferences.settings.enableMDNS,
            pollInterval: .seconds(3_600)
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraModernDiscoveryPreference-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let modernDiscovery = RecordingProtocolV3Discovery()
        let modernManager = ModernLumenV3Manager(
            trustStore: FileBackedProtocolV3TrustStore(
                url: root.appendingPathComponent("trust.json")
            ),
            hostCatalog: FileBackedModernLumenV3HostCatalog(
                url: root.appendingPathComponent("hosts.json")
            ),
            discovery: modernDiscovery,
            log: nil
        )
        let client = LiveUmbraClientService(
            service: applicationService,
            preferences: preferences,
            securePorts: SecurePortRegistry(),
            protocolV3: modernManager
        )

        _ = try await client.discoverHosts()
        XCTAssertEqual(discovery.lifecycleCounts().starts, 0)
        XCTAssertEqual(modernDiscovery.lifecycleCounts().starts, 0)

        preferences.update(\.enableMDNS, to: true)
        await eventually {
            discovery.lifecycleCounts().starts == 1
                && modernDiscovery.lifecycleCounts().starts == 1
        }

        preferences.update(\.enableMDNS, to: false)
        await eventually {
            discovery.lifecycleCounts().stops == 1
                && modernDiscovery.lifecycleCounts().stops == 1
        }
        await applicationService.stopMonitoring()
    }

    func testRuntimeResolverFallsBackCLI51And71PreferencesOnStereoOutput() {
        let resolver = RuntimeStreamingPreferencesResolver(
            audioOutputChannelCount: 2,
            displayResolver: { preferences, _ in preferences }
        )

        for requested in [AudioConfiguration.surround51, .surround71] {
            var cliPreferences = StreamingPreferences.default
            cliPreferences.audioConfiguration = requested

            let resolved = resolver.resolve(cliPreferences, uiScreen: nil)

            XCTAssertEqual(resolved.audioConfiguration, .stereo)
        }
    }

    func testRuntimeResolverPreservesSupportedAndUnknownAudioCapabilities() {
        var preferences = StreamingPreferences.default
        preferences.audioConfiguration = .surround71
        let supported = RuntimeStreamingPreferencesResolver(
            audioOutputChannelCount: 8,
            displayResolver: { preferences, _ in preferences }
        )
        let unknown = RuntimeStreamingPreferencesResolver(
            audioOutputChannelCount: 0,
            displayResolver: { preferences, _ in preferences }
        )

        XCTAssertEqual(
            supported.resolve(preferences, uiScreen: nil).audioConfiguration,
            .surround71
        )
        XCTAssertEqual(
            unknown.resolve(preferences, uiScreen: nil).audioConfiguration,
            .surround71
        )
    }

    func testApplicationArtworkFetchesAreBoundedConcurrentOrderedAndFailureTolerant() async throws {
        let remoteApplications = [9, 2, 7, 1, 8, 3, 6, 4, 5].map {
            GameStreamApp(id: $0, name: "Application \($0)")
        }
        let fixture = makeFixture(remoteApplications: remoteApplications, failedArtworkIDs: [8])
        var catalogUpdates: [[ApplicationDisplayModel]] = []
        fixture.client.setEventHandler { event in
            if case let .applicationCatalogUpdated(hostID, applications) = event,
               hostID == HostID(fixture.hostID) {
                catalogUpdates.append(applications)
            }
        }

        let applications = try await fixture.client.applications(for: HostID(fixture.hostID), includeHidden: true)

        XCTAssertEqual(applications.map(\.id.rawValue), remoteApplications.map(\.id))
        XCTAssertTrue(applications.allSatisfy { $0.artworkURL == nil })

        await eventually {
            let metrics = await fixture.gameStreamClient.artworkMetrics()
            return metrics.requestedIDs.count == remoteApplications.count
                && catalogUpdates.last?.compactMap(\.artworkURL).count == remoteApplications.count - 1
        }

        let latestApplications = try XCTUnwrap(catalogUpdates.last)
        XCTAssertEqual(latestApplications.map(\.id.rawValue), remoteApplications.map(\.id))
        XCTAssertNil(latestApplications.first(where: { $0.id.rawValue == 8 })?.artworkURL)
        for application in latestApplications where application.id.rawValue != 8 {
            let artworkURL = try XCTUnwrap(application.artworkURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: artworkURL.path))
        }
        let metrics = await fixture.gameStreamClient.artworkMetrics()
        XCTAssertEqual(Set(metrics.requestedIDs), Set(remoteApplications.map(\.id)))
        XCTAssertEqual(metrics.maximumConcurrentRequests, 4)
    }

    func testZeroByteCachedArtworkIsEvictedRefetchedOnceAndReused() async throws {
        let application = GameStreamApp(id: 1, name: "Desktop")
        let fixture = makeFixture(remoteApplications: [application])
        let cachedURL = try await fixture.artworkCache.artworkURL(
            hostID: fixture.hostID,
            applicationID: application.id
        ) {
            validArtworkData
        }
        try Data().write(to: cachedURL)
        var latestApplications: [ApplicationDisplayModel]?
        fixture.client.setEventHandler { event in
            if case let .applicationCatalogUpdated(hostID, applications) = event,
               hostID == HostID(fixture.hostID) {
                latestApplications = applications
            }
        }

        let initialApplications = try await fixture.client.applications(
            for: HostID(fixture.hostID),
            includeHidden: true
        )

        XCTAssertNil(initialApplications.first?.artworkURL)
        await eventually {
            let metrics = await fixture.gameStreamClient.artworkMetrics()
            return metrics.requestedIDs == [application.id]
                && latestApplications?.first?.artworkURL != nil
        }
        let repairedURL = try XCTUnwrap(latestApplications?.first?.artworkURL)
        XCTAssertEqual(try Data(contentsOf: repairedURL), validArtworkData)

        let cachedApplications = try await fixture.client.applications(
            for: HostID(fixture.hostID),
            includeHidden: true
        )
        XCTAssertEqual(cachedApplications.first?.artworkURL, repairedURL)
        try await Task.sleep(for: .milliseconds(50))
        let metrics = await fixture.gameStreamClient.artworkMetrics()
        XCTAssertEqual(metrics.requestedIDs, [application.id])
    }

    func testUndecodableCachedArtworkIsEvictedAndRecovered() async throws {
        let application = GameStreamApp(id: 2, name: "Game")
        let fixture = makeFixture(remoteApplications: [application])
        try FileManager.default.createDirectory(
            at: fixture.cacheRoot,
            withIntermediateDirectories: true
        )
        let legacyURL = fixture.cacheRoot.appendingPathComponent(
            "\(fixture.hostID)-\(application.id).png"
        )
        try Data("not-an-image".utf8).write(to: legacyURL)
        var recoveredURL: URL?
        fixture.client.setEventHandler { event in
            if case let .applicationCatalogUpdated(hostID, applications) = event,
               hostID == HostID(fixture.hostID) {
                recoveredURL = applications.first?.artworkURL
            }
        }

        let applications = try await fixture.client.applications(
            for: HostID(fixture.hostID),
            includeHidden: true
        )

        XCTAssertNil(applications.first?.artworkURL)
        await eventually {
            let metrics = await fixture.gameStreamClient.artworkMetrics()
            return metrics.requestedIDs == [application.id] && recoveredURL != nil
        }
        let finalURL = try XCTUnwrap(recoveredURL)
        XCTAssertNotEqual(finalURL, legacyURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(try Data(contentsOf: finalURL), validArtworkData)
    }

    func testCorruptCachedArtworkWithFailedRefetchStaysAPlaceholderWithoutRetryLoop() async throws {
        let application = GameStreamApp(id: 3, name: "Unavailable Art")
        let fixture = makeFixture(
            remoteApplications: [application],
            failedArtworkIDs: [application.id]
        )
        let cachedURL = try await fixture.artworkCache.artworkURL(
            hostID: fixture.hostID,
            applicationID: application.id
        ) {
            validArtworkData
        }
        try Data("corrupt-cache-entry".utf8).write(to: cachedURL)
        var catalogUpdates: [[ApplicationDisplayModel]] = []
        fixture.client.setEventHandler { event in
            if case let .applicationCatalogUpdated(hostID, applications) = event,
               hostID == HostID(fixture.hostID) {
                catalogUpdates.append(applications)
            }
        }

        let applications = try await fixture.client.applications(
            for: HostID(fixture.hostID),
            includeHidden: true
        )

        XCTAssertNil(applications.first?.artworkURL)
        await eventually {
            let metrics = await fixture.gameStreamClient.artworkMetrics()
            return metrics.requestedIDs == [application.id]
        }
        try await Task.sleep(for: .milliseconds(50))
        let metrics = await fixture.gameStreamClient.artworkMetrics()
        XCTAssertEqual(metrics.requestedIDs, [application.id])
        XCTAssertTrue(catalogUpdates.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedURL.path))
    }

    func testUndecodableRefetchIsNotCommittedToTheArtworkCache() async throws {
        let application = GameStreamApp(id: 4, name: "Invalid Art")
        let invalidArtwork = Data("not-an-image-response".utf8)
        let fixture = makeFixture(
            remoteApplications: [application],
            artworkDataByID: [application.id: invalidArtwork]
        )
        var catalogUpdates: [[ApplicationDisplayModel]] = []
        fixture.client.setEventHandler { event in
            if case let .applicationCatalogUpdated(hostID, applications) = event,
               hostID == HostID(fixture.hostID) {
                catalogUpdates.append(applications)
            }
        }

        let applications = try await fixture.client.applications(
            for: HostID(fixture.hostID),
            includeHidden: true
        )

        XCTAssertNil(applications.first?.artworkURL)
        await eventually {
            let metrics = await fixture.gameStreamClient.artworkMetrics()
            return metrics.requestedIDs == [application.id]
        }
        try await Task.sleep(for: .milliseconds(50))
        let cached = await fixture.artworkCache.cachedArtworkURLs(
            hostID: fixture.hostID,
            applicationIDs: [application.id]
        )
        XCTAssertTrue(cached.isEmpty)
        XCTAssertTrue(catalogUpdates.isEmpty)
    }

    func testDeletingHostRemovesCurrentAndLegacyArtworkCacheEntries() async throws {
        let fixture = makeFixture(remoteApplications: [GameStreamApp(id: 1, name: "Desktop")])
        var loadedArtworkURL: URL?
        fixture.client.setEventHandler { event in
            if case let .applicationCatalogUpdated(hostID, applications) = event,
               hostID == HostID(fixture.hostID) {
                loadedArtworkURL = applications.first?.artworkURL
            }
        }
        _ = try await fixture.client.applications(for: HostID(fixture.hostID), includeHidden: true)
        await eventually { loadedArtworkURL != nil }
        let artworkURL = try XCTUnwrap(loadedArtworkURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkURL.path))

        let legacyURL = fixture.cacheRoot.appendingPathComponent("\(fixture.hostID)-99.png")
        try Data([99]).write(to: legacyURL)

        try await fixture.client.deleteHost(id: HostID(fixture.hostID))

        XCTAssertFalse(FileManager.default.fileExists(atPath: artworkURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testTransientCatalogRefreshFailureReturnsSavedCatalog() async throws {
        let savedApplication = StreamApplication(id: 42, name: "Saved Desktop")
        let fixture = makeFixture(
            savedApplications: [savedApplication],
            remoteApplications: [],
            catalogRefreshFailure: .timedOut
        )
        var refreshWarning: String?
        fixture.client.setEventHandler { event in
            if case let .applicationCatalogRefreshWarning(hostID, message) = event,
               hostID == HostID(fixture.hostID) {
                refreshWarning = message
            }
        }

        let applications = try await fixture.client.applications(for: HostID(fixture.hostID), includeHidden: true)

        XCTAssertEqual(applications.map(\.id.rawValue), [savedApplication.id])
        XCTAssertEqual(applications.map(\.name), [savedApplication.name])
        XCTAssertNotNil(refreshWarning)
    }

    func testMalformedCatalogResponseIsNotMaskedBySavedCatalog() async throws {
        let fixture = makeFixture(
            savedApplications: [StreamApplication(id: 42, name: "Saved Desktop")],
            remoteApplications: [],
            catalogRefreshFailure: .malformedResponse
        )

        do {
            _ = try await fixture.client.applications(for: HostID(fixture.hostID), includeHidden: true)
            XCTFail("Expected the malformed application catalog to fail")
        } catch let error as UmbraServiceError {
            guard case let .protocolFailure(operation, statusCode, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, .applications)
            XCTAssertNil(statusCode)
        }
    }

    func testSessionWarningDeliveryStateEmitsOnlyNewWarningsAndResets() {
        let firstID = UUID()
        let secondID = UUID()
        var delivery = SessionWarningDeliveryState()

        var session = StreamSession(
            id: firstID,
            hostID: "host",
            applicationID: 1,
            state: .preparing,
            launchWarnings: ["HDR was disabled"]
        )
        XCTAssertEqual(Array(delivery.takeNewWarnings(from: session)), ["HDR was disabled"])
        XCTAssertTrue(delivery.takeNewWarnings(from: session).isEmpty)

        session.launchWarnings.append("The requested frame rate was reduced")
        XCTAssertEqual(
            Array(delivery.takeNewWarnings(from: session)),
            ["The requested frame rate was reduced"]
        )

        let nextSession = StreamSession(
            id: secondID,
            hostID: "host",
            applicationID: 2,
            state: .connecting(stage: .controlStreamInitialization),
            launchWarnings: ["A new session warning"]
        )
        XCTAssertEqual(Array(delivery.takeNewWarnings(from: nextSession)), ["A new session warning"])

        var finishedSession = nextSession
        finishedSession.state = SessionState.finished(SessionResult())
        XCTAssertTrue(delivery.takeNewWarnings(from: finishedSession).isEmpty)

        var reusedSnapshot = nextSession
        reusedSnapshot.launchWarnings.append("Warning after reset")
        XCTAssertEqual(
            Array(delivery.takeNewWarnings(from: reusedSnapshot)),
            ["A new session warning", "Warning after reset"]
        )
    }

    private func makeFixture(
        savedApplications: [StreamApplication] = [],
        remoteApplications: [GameStreamApp],
        failedArtworkIDs: Set<Int> = [],
        artworkDataByID: [Int: Data] = [:],
        catalogRefreshFailure: CatalogRefreshFailure = .none
    ) -> LiveServiceFixture {
        let hostID = "host-cache"
        let endpoint = NetworkEndpoint(hostname: "host.local")
        let host = StreamHost(
            uuid: hostID,
            name: "Host",
            localAddress: endpoint,
            serverCertificate: Data([1]),
            applications: savedApplications,
            status: .online,
            pairState: .paired,
            activeAddress: endpoint,
            activeHTTPSPort: NetworkEndpoint.defaultHTTPSPort
        )
        let store = LiveServiceMemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let gameStreamClient = CatalogGameStreamClient(
            applications: remoteApplications,
            failedArtworkIDs: failedArtworkIDs,
            artworkDataByID: artworkDataByID,
            catalogRefreshFailure: catalogRefreshFailure
        )
        let applicationService = UmbraApplicationService(
            persistence: store,
            clientProvider: CatalogClientProvider(client: gameStreamClient),
            discovery: nil,
            pollInterval: .seconds(3_600)
        )
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraArtworkTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheRoot) }
        let defaultsName = "Umbra.LiveUmbraClientServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsName) }
        let artworkCache = ApplicationArtworkCache(rootDirectory: cacheRoot)
        let client = LiveUmbraClientService(
            service: applicationService,
            preferences: PreferencesStore(defaults: defaults),
            securePorts: SecurePortRegistry(),
            artworkCache: artworkCache,
            maximumConcurrentArtworkRequests: 4
        )
        return LiveServiceFixture(
            client: client,
            gameStreamClient: gameStreamClient,
            hostID: hostID,
            cacheRoot: cacheRoot,
            artworkCache: artworkCache
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition was not satisfied", file: file, line: line)
    }
}

private final class RecordingBonjourDiscovery: BonjourDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    func start(eventHandler: @escaping @Sendable (DiscoveryEvent) -> Void) {
        lock.withLock { starts += 1 }
    }

    func stop() {
        lock.withLock { stops += 1 }
    }

    func lifecycleCounts() -> (starts: Int, stops: Int) {
        lock.withLock { (starts, stops) }
    }
}

private final class RecordingProtocolV3Discovery: ProtocolV3Discovering, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var running = false

    func start(eventHandler: @escaping @Sendable (ProtocolV3DiscoveryEvent) -> Void) {
        lock.withLock {
            guard !running else { return }
            running = true
            starts += 1
        }
    }

    func stop() {
        lock.withLock {
            guard running else { return }
            running = false
            stops += 1
        }
    }

    func lifecycleCounts() -> (starts: Int, stops: Int) {
        lock.withLock { (starts, stops) }
    }
}

private struct LiveServiceFixture {
    var client: LiveUmbraClientService
    var gameStreamClient: CatalogGameStreamClient
    var hostID: String
    var cacheRoot: URL
    var artworkCache: ApplicationArtworkCache
}

private actor LiveServiceMemorySnapshotStore: SnapshotPersisting {
    private var snapshot: UmbraSnapshot

    init(_ snapshot: UmbraSnapshot) {
        self.snapshot = snapshot
    }

    func load() async throws -> UmbraSnapshot {
        snapshot
    }

    func save(_ snapshot: UmbraSnapshot) async throws {
        self.snapshot = snapshot
    }

    func update(
        _ transform: @Sendable (UmbraSnapshot) throws -> UmbraSnapshot
    ) async throws -> UmbraSnapshot {
        snapshot = try transform(snapshot)
        return snapshot
    }
}

private struct CatalogClientProvider: GameStreamClientProviding {
    var client: CatalogGameStreamClient

    func client(for host: StreamHost?) -> any GameStreamServing {
        client
    }
}

private enum CatalogRefreshFailure: Sendable {
    case none
    case timedOut
    case malformedResponse
}

private actor CatalogGameStreamClient: GameStreamServing {
    struct ArtworkMetrics: Sendable {
        var requestedIDs: [Int]
        var maximumConcurrentRequests: Int
    }

    private let applications: [GameStreamApp]
    private let failedArtworkIDs: Set<Int>
    private let artworkDataByID: [Int: Data]
    private let catalogRefreshFailure: CatalogRefreshFailure
    private var requestedArtworkIDs: [Int] = []
    private var concurrentArtworkRequests = 0
    private var maximumConcurrentArtworkRequests = 0

    init(
        applications: [GameStreamApp],
        failedArtworkIDs: Set<Int>,
        artworkDataByID: [Int: Data] = [:],
        catalogRefreshFailure: CatalogRefreshFailure
    ) {
        self.applications = applications
        self.failedArtworkIDs = failedArtworkIDs
        self.artworkDataByID = artworkDataByID
        self.catalogRefreshFailure = catalogRefreshFailure
    }

    func fetchServerInfo(address: HostAddress, secure: Bool, fastFail: Bool) async throws -> ServerInfo {
        throw URLError(.unsupportedURL)
    }

    func fetchApplications(address: HostAddress) async throws -> [GameStreamApp] {
        switch catalogRefreshFailure {
        case .none:
            applications
        case .timedOut:
            throw URLError(.timedOut)
        case .malformedResponse:
            throw UmbraNetworkingError.malformedXML("invalid application list")
        }
    }

    func startSession(
        kind: SessionStartKind,
        address: HostAddress,
        configuration: LaunchConfiguration
    ) async throws -> LaunchResponse {
        throw URLError(.unsupportedURL)
    }

    func cancelSession(address: HostAddress) async throws {
        throw URLError(.unsupportedURL)
    }

    func fetchApplicationAsset(address: HostAddress, appID: Int) async throws -> Data {
        requestedArtworkIDs.append(appID)
        concurrentArtworkRequests += 1
        defer { concurrentArtworkRequests -= 1 }
        maximumConcurrentArtworkRequests = max(
            maximumConcurrentArtworkRequests,
            concurrentArtworkRequests
        )
        try await Task.sleep(for: .milliseconds(20))
        if failedArtworkIDs.contains(appID) { throw URLError(.cannotLoadFromNetwork) }
        return artworkDataByID[appID] ?? validArtworkData
    }

    func artworkMetrics() -> ArtworkMetrics {
        ArtworkMetrics(
            requestedIDs: requestedArtworkIDs,
            maximumConcurrentRequests: maximumConcurrentArtworkRequests
        )
    }
}

private let validArtworkData = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)!
