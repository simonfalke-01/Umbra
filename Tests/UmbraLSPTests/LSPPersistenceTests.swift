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

    func testLegacyHostRecordDefaultsToAutomaticDiscoveryEndpoint() throws {
        struct LegacyHostRecord: Encodable {
            var hostID: UUID
            var name: String
            var address: String
            var port: UInt16
            var lastSeen: Date
            var discoveryDomain: String?
            var interfaceName: String?
        }
        struct LegacySnapshot: Encodable {
            var schemaVersion = 1
            var records: [LegacyHostRecord]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let hostID = UUID()
        let data = try encoder.encode(LegacySnapshot(records: [LegacyHostRecord(
            hostID: hostID,
            name: "Lumen",
            address: "lumen.local",
            port: 48_030,
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            discoveryDomain: "local.",
            interfaceName: "en0"
        )]))

        let decoded = try decoder.decode(LSPHostSnapshot.self, from: data)

        XCTAssertEqual(decoded.records.first?.hostID, hostID)
        XCTAssertEqual(decoded.records.first?.hasManualEndpoint, false)
    }

    func testManualAddressNormalizationAcceptsHostAndIPv6ButRejectsConflictingPort() throws {
        XCTAssertEqual(
            try LSPHostRecord.normalizedManualAddress("  stream.example.com  ", port: 48_030),
            "stream.example.com"
        )
        XCTAssertEqual(
            try LSPHostRecord.normalizedManualAddress("[2001:db8::1234]", port: 48_030),
            "2001:db8::1234"
        )
        XCTAssertThrowsError(
            try LSPHostRecord.normalizedManualAddress("stream.example.com:48031", port: 48_030)
        )
        XCTAssertThrowsError(
            try LSPHostRecord.normalizedManualAddress("https://stream.example.com", port: 48_030)
        )
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

    func testPendingCertificatePinPromotesOnlyAfterThatPinAuthenticates() throws {
        let active = Data(repeating: 0x11, count: 32)
        let pending = Data(repeating: 0x22, count: 32)
        let trust = LSPTrustRecord(
            hostID: UUID(),
            hostIdentityKey: Data(repeating: 0x33, count: 32),
            dtlsSPKISHA256: active,
            permissions: [.browseApplications],
            revocationGeneration: 1,
            certificateRotationGeneration: 2,
            pendingDTLSSPKISHA256: pending
        )
        let stillActive = try XCTUnwrap(trust.promotingAuthenticatedSPKI(active))
        XCTAssertEqual(stillActive.dtlsSPKISHA256, active)
        XCTAssertEqual(stillActive.pendingDTLSSPKISHA256, pending)
        let promoted = try XCTUnwrap(trust.promotingAuthenticatedSPKI(pending))
        XCTAssertEqual(promoted.dtlsSPKISHA256, pending)
        XCTAssertNil(promoted.pendingDTLSSPKISHA256)
        XCTAssertNil(trust.promotingAuthenticatedSPKI(Data(repeating: 0x44, count: 32)))
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
