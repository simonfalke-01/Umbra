import Foundation
import UmbraCore
import XCTest
@testable import UmbraLSP

final class LSPPersistenceTests: XCTestCase {
    private struct InjectedPersistenceFailure: Error {}

    func testStoresUseDistinctLSPNamesAndRoundTripFreshTrust() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraLSPPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = LSPPersistence.stores(in: directory)
        let trustFileName = await stores.trust.fileURL.lastPathComponent
        let hostsFileName = await stores.hosts.fileURL.lastPathComponent
        XCTAssertEqual(trustFileName, "lsp-trust-v1.json")
        XCTAssertEqual(hostsFileName, "lsp-hosts-v1.json")

        let hostID = UUID()
        let trust = LSPTrustSnapshot(records: [
            LSPTrustRecord(
                hostID: hostID,
                hostIdentityKey: Data(repeating: 0x11, count: 32),
                dtlsSPKISHA256: Data(repeating: 0x22, count: 32),
                permissions: [.browseApplications, .startOrAttach, .input],
                revocationGeneration: 1
            ),
        ])
        let hosts = LSPHostSnapshot(records: [
            LSPHostRecord(
                hostID: hostID,
                name: "Lumen",
                address: "lumen.local",
                lastSeen: Date(timeIntervalSince1970: 1_700_000_000)
            ),
        ])

        try await stores.trust.save(trust)
        try await stores.hosts.save(hosts)

        let loadedTrust = try await stores.trust.load()
        let loadedHosts = try await stores.hosts.load()
        XCTAssertEqual(loadedTrust, trust)
        XCTAssertEqual(loadedHosts, hosts)
    }

    func testTrustRejectsUnknownPermissionAndInvalidPinLength() {
        let record = LSPTrustRecord(
            hostID: UUID(),
            hostIdentityKey: Data(repeating: 0x11, count: 32),
            dtlsSPKISHA256: Data(repeating: 0x22, count: 31),
            permissions: LSPPermission(rawValue: 1 << 31),
            revocationGeneration: 1
        )

        XCTAssertThrowsError(try record.validate())
    }

    func testPairingPersistenceRollsBackTrustAndCanRetryAfterHostWriteFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraLSPPairingTransaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = LSPPersistence.stores(in: directory)
        let hostID = UUID()
        let trust = LSPTrustRecord(
            hostID: hostID,
            hostIdentityKey: Data(repeating: 0x11, count: 32),
            dtlsSPKISHA256: Data(repeating: 0x22, count: 32),
            permissions: [.browseApplications, .startOrAttach, .input],
            revocationGeneration: 1
        )
        let unrelatedTrust = LSPTrustRecord(
            hostID: UUID(),
            hostIdentityKey: Data(repeating: 0x55, count: 32),
            dtlsSPKISHA256: Data(repeating: 0x66, count: 32),
            permissions: [.browseApplications],
            revocationGeneration: 4
        )
        let host = LSPHostRecord(
            hostID: hostID,
            name: "Unverified Bonjour Name",
            address: "actual-srv-target.local",
            port: 49_999,
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await stores.trust.save(.init(records: [unrelatedTrust]))

        do {
            try await LSPPairingPersistenceTransaction.commit(
                trust: trust,
                host: host,
                trustStore: stores.trust,
                hostStore: stores.hosts,
                afterTrustWrite: { throw InjectedPersistenceFailure() }
            )
            XCTFail("Injected second-write failure must abort the transaction")
        } catch is InjectedPersistenceFailure {}
        let rolledBackTrust = try await stores.trust.load()
        let unchangedHosts = try await stores.hosts.load()
        XCTAssertEqual(rolledBackTrust.records, [unrelatedTrust])
        XCTAssertEqual(unchangedHosts, .defaultValue)

        try await LSPPairingPersistenceTransaction.commit(
            trust: trust,
            host: host,
            trustStore: stores.trust,
            hostStore: stores.hosts
        )
        let committedTrust = try await stores.trust.load()
        let committedHosts = try await stores.hosts.load()
        XCTAssertEqual(Set(committedTrust.records), Set([unrelatedTrust, trust]))
        XCTAssertEqual(committedHosts.records, [host])
    }
}
