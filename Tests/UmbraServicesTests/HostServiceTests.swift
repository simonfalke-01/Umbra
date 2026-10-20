import XCTest
import UmbraCore
import UmbraNetworking
@testable import UmbraServices

final class HostServiceTests: XCTestCase {
    func testIndependentlyCachedServicesDoNotEraseConcurrentHostAdds() async throws {
        let store = MemorySnapshotStore()
        let firstClient = FakeGameStreamClient()
        let secondClient = FakeGameStreamClient()
        let firstAddress = HostAddress(host: "first.local")
        let secondAddress = HostAddress(host: "second.local")
        await firstClient.setServerInfo(makeServerInfo(id: "host-a", name: "First"), at: firstAddress)
        await secondClient.setServerInfo(makeServerInfo(id: "host-b", name: "Second"), at: secondAddress)
        let firstService = makeService(store: store, client: firstClient)
        let secondService = makeService(store: store, client: secondClient)
        _ = try await firstService.hosts()
        _ = try await secondService.hosts()

        async let first = firstService.addHost(address: firstAddress.host)
        async let second = secondService.addHost(address: secondAddress.host)
        _ = try await (first, second)

        let saved = await store.value()
        XCTAssertEqual(Set(saved.hosts.map(\.uuid)), Set(["host-a", "host-b"]))
    }

    func testOutOfOrderPersistenceReturnsCannotRegressPublishedSnapshot() async throws {
        let host = makeHost()
        let store = ReorderingSnapshotStore(UmbraSnapshot(hosts: [host]))
        let service = UmbraApplicationService(
            persistence: store,
            clientProvider: FakeClientProvider(value: FakeGameStreamClient()),
            discovery: nil
        )

        let rename = Task { try await service.renameHost(id: host.uuid, name: "Renamed") }
        await store.waitUntilFirstUpdateCommitted()
        try await service.setApplicationHidden(
            hostID: host.uuid,
            applicationID: 1,
            hidden: true
        )
        await store.releaseFirstReturn()
        _ = try await rename.value

        let hosts = try await service.hosts()
        let latest = try XCTUnwrap(hosts.first)
        XCTAssertEqual(latest.name, "Renamed")
        XCTAssertTrue(try XCTUnwrap(latest.applications.first).isHidden)
    }

    func testCompatibilityUpdateReclassifiesAndPersistsSavedNVIDIAHosts() async throws {
        var host = makeHost()
        host.isNvidiaServerSoftware = true
        host.gfeVersion = "100.0.0.0"
        host.isSupportedServerVersion = true
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let service = makeService(store: store, client: FakeGameStreamClient())

        try await service.updateMaximumSupportedNVIDIAVersion("99.99.99.99")

        let hosts = try await service.hosts()
        let saved = await store.value()
        XCTAssertFalse(hosts[0].isSupportedServerVersion)
        XCTAssertFalse(saved.hosts[0].isSupportedServerVersion)
    }

    func testCachedCompatibilityCeilingReclassifiesStaleHostsOnFirstLoad() async throws {
        var host = makeHost()
        host.isNvidiaServerSoftware = true
        host.gfeVersion = "100.0.0.0"
        host.isSupportedServerVersion = true
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let service = makeService(
            store: store,
            client: FakeGameStreamClient(),
            maximumSupportedNVIDIAVersion: "99.99.99.99"
        )

        let hosts = try await service.hosts()
        let saved = await store.value()

        XCTAssertFalse(hosts[0].isSupportedServerVersion)
        XCTAssertFalse(saved.hosts[0].isSupportedServerVersion)
    }

    func testClientIdentityChangeInvalidatesStalePairingState() async throws {
        let previousFingerprint = Data(repeating: 0x11, count: 32)
        let currentFingerprint = Data(repeating: 0x22, count: 32)
        let host = makeHost(pairState: .paired, certificate: Data([7, 7, 7]))
        let store = MemorySnapshotStore(UmbraSnapshot(
            schemaVersion: 1,
            hosts: [host],
            clientIdentityFingerprint: previousFingerprint
        ))
        let service = makeService(
            store: store,
            client: FakeGameStreamClient(),
            clientIdentityFingerprint: currentFingerprint
        )

        let hosts = try await service.hosts()

        XCTAssertEqual(hosts[0].pairState, .notPaired)
        XCTAssertTrue(hosts[0].serverCertificate.isEmpty)
        let saved = await store.value()
        XCTAssertEqual(saved.schemaVersion, UmbraSnapshot.currentSchemaVersion)
        XCTAssertEqual(saved.clientIdentityFingerprint, currentFingerprint)
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 1)
    }

    func testManualAddMergesByUUIDAndPreservesUserTraits() async throws {
        var app = StreamApplication(id: 1, name: "Old Desktop")
        app.isHidden = true
        app.supportsDirectLaunch = true
        var existing = makeHost(name: "My Custom Name", certificate: Data([4, 5, 6]), applications: [app])
        existing.hasCustomName = true
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [existing]))
        let client = FakeGameStreamClient()
        let manual = HostAddress(host: "gaming.example", port: 50_000)
        await client.setServerInfo(makeServerInfo(name: "Server Name"), at: manual)
        let service = makeService(store: store, client: client)

        let host = try await service.addHost(address: manual.host, port: manual.port)

        XCTAssertEqual(host.uuid, existing.uuid)
        XCTAssertEqual(host.name, "My Custom Name")
        XCTAssertTrue(host.hasCustomName)
        XCTAssertEqual(host.manualAddress, NetworkEndpoint(hostname: manual.host, port: manual.port))
        XCTAssertEqual(host.serverCertificate, Data([4, 5, 6]))
        XCTAssertTrue(host.applications[0].isHidden)
        XCTAssertTrue(host.applications[0].supportsDirectLaunch)
        let saved = await store.value()
        XCTAssertEqual(saved.hosts.count, 1)
    }

    func testRefreshTriesEveryAddressAndRequiresConsecutiveFailuresBeforeOfflining() async throws {
        var host = makeHost(certificate: Data())
        host.activeAddress = NetworkEndpoint(hostname: "unreachable.local")
        host.localAddress = NetworkEndpoint(hostname: "reachable.local")
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        let reachable = HostAddress(host: "reachable.local")
        await client.setServerInfo(makeServerInfo(), at: reachable)
        let service = makeService(store: store, client: client, offlineFailureThreshold: 2)

        let refreshed = try await service.refreshHost(id: host.uuid)
        XCTAssertEqual(refreshed.activeAddress?.hostname, "reachable.local")
        let calls = await client.recordedServerInfoCalls()
        XCTAssertEqual(calls.map(\.address.host), ["unreachable.local", "reachable.local"])

        await client.removeAllServerInfo()
        do {
            _ = try await service.refreshHost(id: host.uuid)
            XCTFail("Expected the first failure to remain non-terminal and report its error")
        } catch {
            let saved = await store.value()
            XCTAssertEqual(saved.hosts[0].status, .online)
        }
        let offline = try await service.refreshHost(id: host.uuid)
        XCTAssertEqual(offline.status, .offline)
    }

    func testBonjourDiscoveryFetchesServerInfoMergesAndPersists() async throws {
        let store = MemorySnapshotStore()
        let client = FakeGameStreamClient()
        let discovery = FakeBonjourDiscovery()
        let address = HostAddress(host: "studio.local")
        await client.setServerInfo(makeServerInfo(), at: address)
        let service = makeService(
            store: store,
            client: client,
            discovery: discovery,
            resolver: FakeDiscoveryResolver(address: address)
        )

        _ = try await service.startMonitoring()
        discovery.emit(.added(.init(name: "studio", type: "_nvstream._tcp", domain: "local.")))

        let discovered = await eventually { (try? await service.hosts().count) == 1 }
        XCTAssertTrue(discovered)
        let saved = await store.value()
        XCTAssertEqual(saved.hosts.first?.uuid, "host-1")
        await service.stopMonitoring()
    }

    func testBonjourDiscoveryCanBeToggledWithoutStoppingHostMonitoring() async throws {
        let savedHost = makeHost(id: "saved-host", name: "Saved Host")
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [savedHost]))
        let client = FakeGameStreamClient()
        let discovery = FakeBonjourDiscovery()
        let discoveredAddress = HostAddress(host: "new-host.local")
        await client.setServerInfo(
            makeServerInfo(id: "discovered-host", name: "Discovered Host"),
            at: discoveredAddress
        )
        let service = makeService(
            store: store,
            client: client,
            discovery: discovery,
            discoveryEnabled: false,
            resolver: FakeDiscoveryResolver(address: discoveredAddress)
        )

        _ = try await service.startMonitoring()
        XCTAssertEqual(discovery.recordedLifecycleCounts().starts, 0)

        await service.setDiscoveryEnabled(true)
        XCTAssertEqual(discovery.recordedLifecycleCounts().starts, 1)
        discovery.emit(.added(.init(name: "new-host", type: "_nvstream._tcp", domain: "local.")))
        let didDiscoverHost = await eventually {
            (try? await service.hosts().map(\.uuid))?.contains("discovered-host") == true
        }
        XCTAssertTrue(didDiscoverHost)

        await service.setDiscoveryEnabled(false)
        XCTAssertEqual(discovery.recordedLifecycleCounts().stops, 1)
        let hostsAfterDisabling = try await service.hosts()
        XCTAssertEqual(Set(hostsAfterDisabling.map(\.uuid)), ["saved-host", "discovered-host"])

        // Polling remains available while Bonjour is disabled, so saved hosts can still be
        // refreshed through the same monitoring service.
        _ = try await service.refreshHosts()
        let hostsAfterRefresh = try await service.hosts()
        XCTAssertEqual(Set(hostsAfterRefresh.map(\.uuid)), ["saved-host", "discovered-host"])

        await service.setDiscoveryEnabled(true)
        await service.setDiscoveryEnabled(true)
        XCTAssertEqual(discovery.recordedLifecycleCounts().starts, 2)
        await service.stopMonitoring()
        XCTAssertEqual(discovery.recordedLifecycleCounts().stops, 2)
    }

    func testDisablingBonjourIgnoresDiscoveryResolutionAlreadyInFlight() async throws {
        let store = MemorySnapshotStore()
        let client = FakeGameStreamClient()
        let discovery = FakeBonjourDiscovery()
        let address = HostAddress(host: "stale-host.local")
        let resolver = SuspendingDiscoveryResolver(address: address)
        await client.setServerInfo(makeServerInfo(), at: address)
        let service = makeService(
            store: store,
            client: client,
            discovery: discovery,
            resolver: resolver
        )

        _ = try await service.startMonitoring()
        discovery.emit(.added(.init(name: "stale-host", type: "_nvstream._tcp", domain: "local.")))
        let resolutionStarted = await eventually { await resolver.hasPendingResolution() }
        XCTAssertTrue(resolutionStarted)

        await service.setDiscoveryEnabled(false)
        await resolver.resume()
        try await Task.sleep(for: .milliseconds(20))

        let hosts = try await service.hosts()
        let serverInfoCalls = await client.recordedServerInfoCalls()
        XCTAssertTrue(hosts.isEmpty)
        XCTAssertTrue(serverInfoCalls.isEmpty)
        await service.stopMonitoring()
    }

    func testBonjourForPairedHostUsesInsecureResponseOnlyAsRouteHint() async throws {
        let host = makeHost(currentGameID: nil)
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        let discovery = FakeBonjourDiscovery()
        let discoveredAddress = HostAddress(host: "studio.local")
        let secureAddress = HostAddress(host: "studio.local", port: 47_984)
        await client.setServerInfo(
            makeServerInfo(pairState: .notPaired, currentGameID: 42),
            at: discoveredAddress
        )
        await client.setServerInfo(
            makeServerInfo(pairState: .paired, currentGameID: 0),
            at: secureAddress
        )
        let service = makeService(
            store: store,
            client: client,
            discovery: discovery,
            resolver: FakeDiscoveryResolver(address: discoveredAddress)
        )

        _ = try await service.startMonitoring()
        discovery.emit(.added(.init(name: "studio", type: "_nvstream._tcp", domain: "local.")))
        let securelyRefreshed = await eventually {
            await client.recordedServerInfoCalls().contains {
                $0.address == secureAddress && $0.secure
            }
        }
        XCTAssertTrue(securelyRefreshed)

        let saved = await store.value().hosts[0]
        XCTAssertEqual(saved.pairState, .paired)
        XCTAssertNil(saved.currentGameID)
        XCTAssertEqual(saved.serverCertificate, host.serverCertificate)
        await service.stopMonitoring()
    }

    func testCatalogPreservesFlagsAndBoxArtUsesSecureEndpoint() async throws {
        var app = StreamApplication(id: 1, name: "Old")
        app.isHidden = true
        app.supportsDirectLaunch = true
        let host = makeHost(applications: [app])
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        await client.setApplications([
            GameStreamApp(id: 1, name: "Desktop", supportsHDR: true),
            GameStreamApp(id: 2, name: "Steam"),
        ])
        await client.setAsset(Data([1, 2, 3]))
        let service = makeService(store: store, client: client)

        let visible = try await service.applications(hostID: host.uuid, refresh: true, includeHidden: false)
        XCTAssertEqual(visible.map(\.id), [2])
        let all = try await service.applications(hostID: host.uuid, refresh: false, includeHidden: true)
        XCTAssertTrue(all.first(where: { $0.id == 1 })!.supportsDirectLaunch)
        let art = try await service.boxArt(hostID: host.uuid, applicationID: 1)
        let applicationAddresses = await client.recordedApplicationAddresses()
        let assetRequests = await client.recordedAssetRequests()
        XCTAssertEqual(art, Data([1, 2, 3]))
        XCTAssertEqual(applicationAddresses.first?.port, 47_984)
        XCTAssertEqual(assetRequests.first?.1, 1)
    }

    func testAuthoritativeEmptyCatalogClearsSavedApplications() async throws {
        let savedApplication = StreamApplication(id: 1, name: "Desktop", isHidden: true)
        let host = makeHost(applications: [savedApplication])
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        await client.setApplications([])
        let service = makeService(store: store, client: client)

        let applications = try await service.applications(
            hostID: host.uuid,
            refresh: true,
            includeHidden: true
        )

        XCTAssertTrue(applications.isEmpty)
        let saved = await store.value()
        XCTAssertTrue(saved.hosts[0].applications.isEmpty)
    }

    func testCatalogFiltersInvalidEntriesWithoutDiscardingValidApplications() async throws {
        let host = makeHost(applications: [StreamApplication(id: 9, name: "Old")])
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        await client.setApplications([
            GameStreamApp(id: 1, name: "   "),
            GameStreamApp(id: 2, name: "  Desktop  ", supportsHDR: true),
            GameStreamApp(id: 2, name: "Duplicate"),
            GameStreamApp(id: 0, name: "Invalid ID"),
        ])
        let service = makeService(store: store, client: client)

        let applications = try await service.applications(
            hostID: host.uuid,
            refresh: true,
            includeHidden: true
        )

        XCTAssertEqual(applications, [
            StreamApplication(id: 2, name: "Desktop", hdrSupported: true),
        ])
        let saved = await store.value()
        XCTAssertEqual(saved.hosts[0].applications, applications)
    }

    func testAllInvalidCatalogPreservesLastTrustworthyApplications() async throws {
        let savedApplication = StreamApplication(id: 9, name: "Desktop")
        let host = makeHost(applications: [savedApplication])
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        await client.setApplications([
            GameStreamApp(id: 1, name: "   "),
            GameStreamApp(id: 0, name: "Invalid ID"),
        ])
        let service = makeService(store: store, client: client)

        do {
            _ = try await service.applications(hostID: host.uuid, refresh: true, includeHidden: true)
            XCTFail("An all-invalid nonempty catalog must not erase saved applications")
        } catch let error as UmbraServiceError {
            guard case .protocolFailure(operation: .applications, statusCode: nil, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let saved = await store.value()
        XCTAssertEqual(saved.hosts[0].applications, [savedApplication])
    }

    func testConcurrentCatalogRefreshesCoalesceAndLaterEmptyCatalogWins() async throws {
        let host = makeHost(applications: [StreamApplication(id: 9, name: "Saved")])
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        await client.setApplications([GameStreamApp(id: 1, name: "Desktop")])
        await client.suspendNextApplicationResponses()
        let service = makeService(store: store, client: client)

        let first = Task {
            try await service.applications(hostID: host.uuid, refresh: true, includeHidden: true)
        }
        let firstRequestStarted = await eventually {
            await client.recordedApplicationAddresses().count == 1
        }
        XCTAssertTrue(firstRequestStarted)
        let concurrent = Task {
            try await service.applications(hostID: host.uuid, refresh: true, includeHidden: true)
        }
        await Task.yield()
        let callsWhileSuspended = await client.recordedApplicationAddresses()
        XCTAssertEqual(callsWhileSuspended.count, 1)

        await client.resumeSuspendedApplicationResponses()
        let firstApplications = try await first.value
        let concurrentApplications = try await concurrent.value
        XCTAssertEqual(firstApplications.map(\.id), [1])
        XCTAssertEqual(concurrentApplications.map(\.id), [1])

        await client.setApplications([])
        let empty = try await service.applications(
            hostID: host.uuid,
            refresh: true,
            includeHidden: true
        )
        XCTAssertTrue(empty.isEmpty)
        let saved = await store.value()
        XCTAssertTrue(saved.hosts[0].applications.isEmpty)
    }

    func testOverlappingRefreshesCoalesceAndLaterRefreshAppliesNewHostState() async throws {
        let host = makeHost(currentGameID: nil)
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        let secureAddress = HostAddress(host: "192.168.1.10", port: 47_984)
        await client.enqueueServerInfo([
            makeServerInfo(currentGameID: 1),
            makeServerInfo(currentGameID: 0),
        ], at: secureAddress)
        await client.suspendNextServerInfoResponses()
        let service = makeService(store: store, client: client)

        let olderRefresh = Task { try await service.refreshHost(id: host.uuid) }
        let olderRefreshIsSuspended = await eventually {
            await client.recordedServerInfoCalls().count == 1
        }
        XCTAssertTrue(olderRefreshIsSuspended)

        let concurrentRefresh = Task { try await service.refreshHost(id: host.uuid) }
        await Task.yield()
        let callsWhileSuspended = await client.recordedServerInfoCalls()
        XCTAssertEqual(callsWhileSuspended.count, 1)

        await client.resumeSuspendedServerInfoResponses()
        let firstResult = try await olderRefresh.value
        let concurrentResult = try await concurrentRefresh.value
        XCTAssertEqual(firstResult.currentGameID, 1)
        XCTAssertEqual(concurrentResult.currentGameID, 1)

        let latest = try await service.refreshHost(id: host.uuid)
        XCTAssertNil(latest.currentGameID)
        let saved = await store.value()
        XCTAssertNil(saved.hosts[0].currentGameID)
    }

    func testWakeRenameDetailsAndRemoval() async throws {
        let host = makeHost()
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        let wake = FakeWakeSender()
        let service = makeService(
            store: store,
            client: client,
            wake: wake
        )

        let renamed = try await service.renameHost(id: host.uuid, name: "  Living Room  ")
        XCTAssertEqual(renamed.name, "Living Room")
        XCTAssertTrue(renamed.hasCustomName)
        let details = try await service.details(hostID: host.uuid)
        let woken = try await service.wakeHost(id: host.uuid)
        XCTAssertTrue(details.canWake)
        XCTAssertEqual(woken.status, .unknown)
        try await service.removeHost(id: host.uuid)
        let remaining = try await service.hosts()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPairingPassesVersionPersistsCertificateAndForwardsCancellation() async throws {
        var host = makeHost(pairState: .notPaired, certificate: Data())
        host.appVersion = "7.1.0"
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        let secure = HostAddress(host: "192.168.1.10", port: 47_984)
        await client.setServerInfo(makeServerInfo(pairState: .paired, appVersion: "7.1.0"), at: secure)
        let pairing = FakePairingAdapter(certificate: Data([7, 7, 7]))
        let service = makeService(store: store, client: client, pairing: pairing)

        let paired = try await service.pairHost(id: host.uuid, pin: "1234")
        XCTAssertEqual(paired.serverCertificate, Data([7, 7, 7]))
        XCTAssertEqual(paired.pairState, .paired)
        let received = await pairing.received()
        XCTAssertEqual(received.1, "1234")
        XCTAssertEqual(received.2, "7.1.0")
        XCTAssertEqual(received.3, false)
        await service.cancelPairing(hostID: host.uuid)
        let cancelledHostID = await pairing.cancelledHostID
        XCTAssertEqual(cancelledHostID, host.uuid)
    }

    func testRefreshKeepsBusySessionIndependentFromUnpairedState() async throws {
        let host = makeHost(pairState: .paired)
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        await client.setServerInfo(
            makeServerInfo(pairState: .notPaired, currentGameID: 42),
            at: HostAddress(host: "192.168.1.10", port: 47_984)
        )
        let service = makeService(store: store, client: client)

        let refreshed = try await service.refreshHost(id: host.uuid)

        XCTAssertEqual(refreshed.currentGameID, 42)
        XCTAssertEqual(refreshed.pairState, .notPaired)
    }

    func testRequestTimeoutMapsToHostUnavailableWithoutDiscardingPairingState() async throws {
        let host = makeHost(pairState: .paired, certificate: Data([9, 8, 7]))
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        await client.setURLError(.timedOut)
        let service = makeService(store: store, client: client, offlineFailureThreshold: 2)

        do {
            _ = try await service.refreshHost(id: host.uuid)
            XCTFail("Expected the request timeout to fail refresh")
        } catch let error as UmbraServiceError {
            guard case .hostUnavailable(hostID: host.uuid, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let saved = await store.value().hosts[0]
        XCTAssertEqual(saved.status, .online)
        XCTAssertEqual(saved.pairState, .paired)
        XCTAssertEqual(saved.serverCertificate, Data([9, 8, 7]))
    }

    func testSuccessfulRefreshResetsTransientTimeoutFailureCount() async throws {
        let host = makeHost()
        let store = MemorySnapshotStore(UmbraSnapshot(hosts: [host]))
        let client = FakeGameStreamClient()
        let secureAddress = HostAddress(host: "192.168.1.10", port: 47_984)
        let service = makeService(store: store, client: client, offlineFailureThreshold: 2)

        await client.setURLError(.timedOut)
        _ = try? await service.refreshHost(id: host.uuid)
        await client.setURLError(nil)
        await client.setServerInfo(makeServerInfo(), at: secureAddress)
        _ = try await service.refreshHost(id: host.uuid)
        await client.setURLError(.timedOut)

        do {
            _ = try await service.refreshHost(id: host.uuid)
            XCTFail("Expected a timeout after recovery")
        } catch let error as UmbraServiceError {
            guard case .hostUnavailable(hostID: host.uuid, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let saved = await store.value().hosts[0]
        XCTAssertEqual(saved.status, .online)
    }

    func testUnsupportedServerRejectsCatalogRefreshBeforeNetworkRequest() async throws {
        var host = makeHost()
        host.isNvidiaServerSoftware = true
        host.gfeVersion = "100.0.0.0"
        host.isSupportedServerVersion = false
        let client = FakeGameStreamClient()
        let service = makeService(
            store: MemorySnapshotStore(UmbraSnapshot(hosts: [host])),
            client: client
        )

        do {
            _ = try await service.applications(hostID: host.uuid, refresh: true, includeHidden: true)
            XCTFail("Expected an unsupported-server error")
        } catch let error as UmbraServiceError {
            XCTAssertEqual(error, .unsupportedServer(host.uuid))
        }

        let applicationRequests = await client.recordedApplicationAddresses()
        XCTAssertTrue(applicationRequests.isEmpty)
    }

    private func makeService(
        store: MemorySnapshotStore,
        client: FakeGameStreamClient,
        discovery: (any BonjourDiscovering)? = nil,
        discoveryEnabled: Bool = true,
        resolver: any DiscoveredServiceResolving = LocalNameServiceResolver(),
        wake: any WakeOnLANSending = FakeWakeSender(),
        pairing: (any HostPairingAdapting)? = nil,
        offlineFailureThreshold: Int = 2,
        clientIdentityFingerprint: Data? = nil,
        maximumSupportedNVIDIAVersion: String = NVIDIAServerCompatibilityPolicy.bundledMaximumVersion
    ) -> UmbraApplicationService {
        UmbraApplicationService(
            persistence: store,
            clientProvider: FakeClientProvider(value: client),
            discovery: discovery,
            discoveryEnabled: discoveryEnabled,
            discoveryResolver: resolver,
            wakeSender: wake,
            pairingAdapter: pairing,
            pollInterval: .seconds(3_600),
            offlineFailureThreshold: offlineFailureThreshold,
            clientIdentityFingerprint: clientIdentityFingerprint,
            maximumSupportedNVIDIAVersion: maximumSupportedNVIDIAVersion
        )
    }
}
