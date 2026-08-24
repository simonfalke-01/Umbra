import AppKit
import CryptoKit
import XCTest
import UmbraCore
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

    func testPackagedInfoPlistRegistersSecurePairingURLScheme() throws {
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

        XCTAssertEqual(schemes, ["umbra"])
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
