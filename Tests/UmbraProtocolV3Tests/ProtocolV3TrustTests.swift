import CryptoKit
import Darwin
import Foundation
import Testing
@testable import UmbraProtocolV3

@Test func trustRecordRejectsDowngradeOnDecode() throws {
    let invalid = Data(#"{"hostID":"","hostPublicKey":"","tlsSPKIHash":"","clientID":"","grantedPermissions":0,"pairingGeneration":0,"minimumProtocol":2,"legacyFallbackAllowed":true}"#.utf8)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(ProtocolV3TrustRecord.self, from: invalid)
    }
}

@Test func trustStoreRoundTripsIdentityAndStrictTrust() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let store = FileBackedProtocolV3TrustStore(url: url)
    let identity = try store.identity()
    let hostKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(32..<64))
    let hostPublicKey = hostKey.publicKey.rawRepresentation
    let hostID = Data(SHA256.hash(data: hostPublicKey).prefix(16))
    let trust = try ProtocolV3TrustRecord(
        hostID: hostID,
        hostPublicKey: hostPublicKey,
        tlsSPKIHash: Data(128..<160),
        clientID: identity.clientID,
        grantedPermissions: 0x17,
        pairingGeneration: 1
    )
    try store.commit(identity: identity, trust: trust)
    #expect(try store.trust(hostID: hostID) == trust)
    #expect(try store.identity().clientID == identity.clientID)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)

    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(trust)) as? [String: Any])
    object["unexpected"] = true
    let unknown = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(ProtocolV3TrustRecord.self, from: unknown)
    }
}

@Test func identityCopiesSeedIntoNativeKey() throws {
    var seed = Data(0..<32)
    let identity = try ProtocolV3ClientIdentity(privateSeed: seed)
    seed.resetBytes(in: seed.indices)
    let expected = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
    #expect(identity.publicKey == expected.publicKey.rawRepresentation)
}

@Test func concurrentStoresShareIdentityAndPairAttempt() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let invitation = try ProtocolV3PairingInvitation.decode(
        Data(hexadecimal: invitationHex),
        nowUnixSeconds: 1_700_000_010
    )
    let first = FileBackedProtocolV3TrustStore(url: url)
    let second = FileBackedProtocolV3TrustStore(url: url)
    async let firstID = Task.detached { try first.identity().clientID }.value
    async let secondID = Task.detached { try second.identity().clientID }.value
    #expect(try await firstID == secondID)
    let initial = try first.beginPairing(
        invitation: invitation,
        requestedPermissions: 0x17,
        displayName: "Umbra"
    )
    let retry = try second.beginPairing(
        invitation: invitation,
        requestedPermissions: 0x17,
        displayName: "Umbra"
    )
    #expect(retry == initial)
}

@Test func trustStoreHardensEveryPersistentNodeAndCleansFailedAtomicWrites() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("protocol-v3-trust-v1.json")
    let store = FileBackedProtocolV3TrustStore(url: url)
    let identity = try store.identity()
    let original = try Data(contentsOf: url)

    try expectNode(url.deletingLastPathComponent(), type: S_IFDIR, mode: 0o700)
    try expectNode(url, type: S_IFREG, mode: 0o600)
    try expectNode(url.appendingPathExtension("lock"), type: S_IFREG, mode: 0o600)

    let observation = TrustStoreFaultObservation()
    let failing = FileBackedProtocolV3TrustStore(url: url) { point in
        guard point == .beforeRename else { return }
        let temporary = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".protocol-v3-") }
        )
        try expectNode(temporary, type: S_IFREG, mode: 0o600)
        observation.didObserveTemporary = true
        throw TrustStoreTestError.injected
    }
    #expect(throws: TrustStoreTestError.injected) {
        try failing.commit(identity: identity, trust: makeTrust(identity: identity, marker: 0x44))
    }
    #expect(observation.didObserveTemporary)
    #expect(try Data(contentsOf: url) == original)
    #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .allSatisfy { !$0.lastPathComponent.hasPrefix(".protocol-v3-") })

    let fsyncFailing = FileBackedProtocolV3TrustStore(url: url) { point in
        guard point == .beforeFileSync else { return }
        throw TrustStoreTestError.injected
    }
    #expect(throws: TrustStoreTestError.injected) {
        try fsyncFailing.commit(identity: identity, trust: makeTrust(identity: identity, marker: 0x45))
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .allSatisfy { !$0.lastPathComponent.hasPrefix(".protocol-v3-") })
}

@Test func trustStoreRejectsFileLockAndDirectorySymlinksWithoutTouchingTargets() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let victim = root.appendingPathComponent("victim")
    try Data("do not touch".utf8).write(to: victim)

    let fileURL = root.appendingPathComponent("file-link.json")
    try FileManager.default.createSymbolicLink(atPath: fileURL.path, withDestinationPath: victim.path)
    #expect(throws: (any Error).self) {
        _ = try FileBackedProtocolV3TrustStore(url: fileURL).identity()
    }
    #expect(try Data(contentsOf: victim) == Data("do not touch".utf8))

    let lockURL = root.appendingPathComponent("lock-link.json")
    try FileManager.default.createSymbolicLink(
        atPath: lockURL.appendingPathExtension("lock").path,
        withDestinationPath: victim.path
    )
    #expect(throws: (any Error).self) {
        _ = try FileBackedProtocolV3TrustStore(url: lockURL).identity()
    }
    #expect(try Data(contentsOf: victim) == Data("do not touch".utf8))

    let realDirectory = root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createSymbolicLink(
        atPath: linkedDirectory.path,
        withDestinationPath: realDirectory.path
    )
    #expect(throws: (any Error).self) {
        _ = try FileBackedProtocolV3TrustStore(
            url: linkedDirectory.appendingPathComponent("trust.json")
        ).identity()
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: realDirectory.path).isEmpty)
}

@Test func trustStoreBackupRestorePreservesIdentityAndSeparateUserRootsDoNotShareIt() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appendingPathComponent("user-a/trust.json")
    let secondURL = root.appendingPathComponent("user-b/trust.json")
    let restoredURL = root.appendingPathComponent("restored/trust.json")

    let first = FileBackedProtocolV3TrustStore(url: firstURL)
    let firstIdentity = try first.identity()
    let trust = try makeTrust(identity: firstIdentity, marker: 0x55)
    try first.commit(identity: firstIdentity, trust: trust)

    let secondIdentity = try FileBackedProtocolV3TrustStore(url: secondURL).identity()
    #expect(secondIdentity.clientID != firstIdentity.clientID)

    try FileManager.default.createDirectory(
        at: restoredURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(at: firstURL, to: restoredURL)
    let restored = FileBackedProtocolV3TrustStore(url: restoredURL)
    #expect(try restored.identity().clientID == firstIdentity.clientID)
    #expect(try restored.trust(hostID: trust.hostID) == trust)
    try expectNode(restoredURL.deletingLastPathComponent(), type: S_IFDIR, mode: 0o700)
    try expectNode(restoredURL, type: S_IFREG, mode: 0o600)
}

@Test func packagedStorageDescriptorIsUserScopedFileBackedAndKeychainFree() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = FileBackedProtocolV3TrustStore.storageDescriptor(
        applicationSupportDirectory: root
    )
    #expect(descriptor.url == root
        .appendingPathComponent("app.umbra.Umbra", isDirectory: true)
        .appendingPathComponent("protocol-v3-trust-v1.json"))
    #expect(descriptor.scope == .currentUser)
    #expect(descriptor.isBackupEligible)
    #expect(!descriptor.usesSystemKeychain)

    let store = FileBackedProtocolV3TrustStore(applicationSupportDirectory: root)
    _ = try store.identity()
    #expect(FileManager.default.fileExists(atPath: descriptor.url.path))
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

private enum TrustStoreTestError: Error {
    case injected
}

private final class TrustStoreFaultObservation: @unchecked Sendable {
    var didObserveTemporary = false
}

private func makeTrust(
    identity: ProtocolV3ClientIdentity,
    marker: UInt8
) throws -> ProtocolV3TrustRecord {
    let hostKey = try Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(repeating: marker, count: 32)
    )
    let publicKey = hostKey.publicKey.rawRepresentation
    return try ProtocolV3TrustRecord(
        hostID: Data(SHA256.hash(data: publicKey).prefix(16)),
        hostPublicKey: publicKey,
        tlsSPKIHash: Data(repeating: marker, count: 32),
        clientID: identity.clientID,
        grantedPermissions: 0x17,
        pairingGeneration: 1
    )
}

private func expectNode(_ url: URL, type: mode_t, mode: mode_t) throws {
    var metadata = stat()
    try #require(Darwin.lstat(url.path, &metadata) == 0)
    #expect(metadata.st_uid == Darwin.geteuid())
    #expect(metadata.st_mode & S_IFMT == type)
    #expect(metadata.st_mode & 0o777 == mode)
}

private let invitationHex = "554c4933010000ac00babb9e00030003000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf24f6ed6acbfe1009c030d7ca567c33ca808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7000000006553f100000000006553f22c000000000000017f000e0000766563746f722e6578616d706c65"
