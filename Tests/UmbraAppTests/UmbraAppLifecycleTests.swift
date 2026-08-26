import AppKit
import CryptoKit
import XCTest
import UmbraCore
import UmbraNetworking
import UmbraProtocolV3
@testable import UmbraApp

@MainActor
final class UmbraAppLifecycleTests: XCTestCase {
    func testRepeatedQuitSharesOneOrderedStopBarrierAndOneReply() async throws {
        let gate = TerminationBarrierGate()
        let delegate = UmbraApplicationDelegate()
        var stopCount = 0
        var replies: [Bool] = []
        delegate.stopBarrier = {
            stopCount += 1
            await gate.wait()
        }

        let first = delegate.requestTermination { replies.append($0) }
        let repeated = delegate.requestTermination { replies.append($0) }

        XCTAssertEqual(first.rawValue, NSApplication.TerminateReply.terminateLater.rawValue)
        XCTAssertEqual(repeated.rawValue, NSApplication.TerminateReply.terminateLater.rawValue)
        await eventually { stopCount == 1 }
        XCTAssertTrue(replies.isEmpty)

        gate.open()
        await eventually { replies == [true] }

        let afterReply = delegate.requestTermination { replies.append($0) }
        XCTAssertEqual(afterReply.rawValue, NSApplication.TerminateReply.terminateNow.rawValue)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(replies, [true])
    }

    func testPackagedInfoPlistRegistersSecurePairingAndBothDiscoveryProtocols() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistURL = repositoryRoot.appendingPathComponent("Resources/Umbra/Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let urlTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = try XCTUnwrap(urlTypes.first?["CFBundleURLSchemes"] as? [String])
        let bonjourServices = try XCTUnwrap(plist["NSBonjourServices"] as? [String])

        XCTAssertEqual(schemes, ["umbra"])
        XCTAssertEqual(bonjourServices, ["_nvstream._tcp", "_lumen-v3._udp"])
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let storage = FileBackedProtocolV3TrustStore.storageDescriptor(
            applicationSupportDirectory: applicationSupport
        )
        XCTAssertTrue(storage.url.path.hasSuffix(
            "/Application Support/app.umbra.Umbra/protocol-v3-trust-v1.json"
        ))
        XCTAssertFalse(storage.usesSystemKeychain)
        XCTAssertTrue(storage.isBackupEligible)
    }

    func testV3PairingRequestsOnlyEnabledPrivilegedFeatures() {
        var preferences = StreamingPreferences.default
        XCTAssertEqual(ModernLumenV3Manager.requestedPermissions(for: preferences), 0x17)
        preferences.clientMicrophoneEnabled = true
        XCTAssertEqual(ModernLumenV3Manager.requestedPermissions(for: preferences), 0x1F)
        preferences.quitAppAfter = true
        XCTAssertEqual(ModernLumenV3Manager.requestedPermissions(for: preferences), 0x3F)
        preferences.clientMicrophoneEnabled = false
        XCTAssertEqual(ModernLumenV3Manager.requestedPermissions(for: preferences), 0x37)
    }

    func testPersistedV3TrustPublishesNamespacedHostAndRemovalDeletesTrust() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraV3CatalogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trustStore = FileBackedProtocolV3TrustStore(
            url: root.appendingPathComponent("trust.json")
        )
        let catalog = FileBackedModernLumenV3HostCatalog(
            url: root.appendingPathComponent("hosts.json")
        )
        let identity = try trustStore.identity()
        let hostPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let hostID = Data(SHA256.hash(data: hostPublicKey).prefix(16))
        let trust = try ProtocolV3TrustRecord(
            hostID: hostID,
            hostPublicKey: hostPublicKey,
            tlsSPKIHash: Data(repeating: 0xA5, count: 32),
            clientID: identity.clientID,
            grantedPermissions: 0x17,
            pairingGeneration: 1
        )
        try trustStore.commit(identity: identity, trust: trust)
        try catalog.upsert(ModernLumenV3HostRecord(
            hostID: hostID,
            hostname: "lumen.local",
            hostnameIsIPLiteral: false,
            port: 47_998,
            displayName: "Lumen RTX",
            applications: [],
            applicationRevision: nil,
            runningApplicationID: nil
        ))
        let manager = ModernLumenV3Manager(
            trustStore: trustStore,
            hostCatalog: catalog,
            log: nil
        )

        let host = try XCTUnwrap(manager.displayHosts().first)
        XCTAssertEqual(host.id, ModernLumenV3Manager.hostID(for: hostID))
        XCTAssertTrue(host.canBrowseApplications)
        XCTAssertTrue(host.details.contains("downgrade disabled"))
        XCTAssertTrue(host.details.contains("Microphone: Not granted"))

        try manager.removeHost(id: host.id)
        XCTAssertTrue(try manager.displayHosts().isEmpty)
        XCTAssertNil(try trustStore.trust(hostID: hostID))
        XCTAssertNil(try catalog.host(hostID: hostID))
    }

    func testModernDiscoveryUpdatesOnlyPinnedCatalogAndFailureNeverDowngrades() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraV3DiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trustStore = FileBackedProtocolV3TrustStore(url: root.appendingPathComponent("trust.json"))
        let catalog = FileBackedModernLumenV3HostCatalog(url: root.appendingPathComponent("hosts.json"))
        let identity = try trustStore.identity()
        let hostPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let hostID = Data(SHA256.hash(data: hostPublicKey).prefix(16))
        let trust = try ProtocolV3TrustRecord(
            hostID: hostID,
            hostPublicKey: hostPublicKey,
            tlsSPKIHash: Data(repeating: 0xA5, count: 32),
            clientID: identity.clientID,
            grantedPermissions: 0x17,
            pairingGeneration: 1
        )
        try trustStore.commit(identity: identity, trust: trust)
        try catalog.upsert(ModernLumenV3HostRecord(
            hostID: hostID,
            hostname: "old.local",
            hostnameIsIPLiteral: false,
            port: 47_998,
            displayName: "Pinned Lumen",
            applications: [],
            applicationRevision: nil,
            runningApplicationID: nil
        ))
        let discovery = FixtureModernDiscovery()
        let manager = ModernLumenV3Manager(
            trustStore: trustStore,
            hostCatalog: catalog,
            discovery: discovery,
            log: nil
        )
        manager.startDiscovery()

        discovery.emit(.available(try ProtocolV3DiscoveredServiceRecord(
            service: modernService(hostID: hostID),
            resolvedHost: "new.local",
            resolvedPort: 47_998
        )))
        await eventually { (try? catalog.host(hostID: hostID)?.hostname) == "new.local" }
        XCTAssertEqual(try catalog.host(hostID: hostID)?.hostname, "new.local")
        XCTAssertEqual(try catalog.host(hostID: hostID)?.port, 47_998)

        discovery.emit(.failed("modern browse failed"))
        let persisted = try XCTUnwrap(manager.displayHosts().first)
        XCTAssertTrue(persisted.id.rawValue.hasPrefix("v3:"))
        XCTAssertTrue(persisted.details.contains("downgrade disabled"))
        XCTAssertTrue(persisted.details.contains("new.local:47998"))

        let untrustedID = Data(repeating: 0x22, count: 16)
        discovery.emit(.available(try ProtocolV3DiscoveredServiceRecord(
            service: modernService(hostID: untrustedID),
            resolvedHost: "untrusted.local",
            resolvedPort: 47_998
        )))
        await Task.yield()
        XCTAssertNil(try catalog.host(hostID: untrustedID))
        XCTAssertEqual(try manager.displayHosts().count, 1)
        manager.stopDiscovery()
        XCTAssertEqual(discovery.stopCount, 1)
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private final class FixtureModernDiscovery: ProtocolV3Discovering, @unchecked Sendable {
    private var handler: (@Sendable (ProtocolV3DiscoveryEvent) -> Void)?
    private(set) var stopCount = 0

    func start(eventHandler: @escaping @Sendable (ProtocolV3DiscoveryEvent) -> Void) {
        handler = eventHandler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ event: ProtocolV3DiscoveryEvent) {
        handler?(event)
    }
}

private func modernService(hostID: Data) -> DiscoveredHostService {
    DiscoveredHostService(
        name: "Lumen",
        type: "_lumen-v3._udp",
        domain: "local.",
        txtRecord: [
            "v": "3",
            "id": hostID.map { String(format: "%02x", $0) }.joined(),
            "port": "47998",
            "caps": "0000000000000017",
        ]
    )
}

@MainActor
private final class TerminationBarrierGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}
