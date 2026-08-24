import CryptoKit
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

private let invitationHex = "554c4933010000ac00babb9e00030003000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf24f6ed6acbfe1009c030d7ca567c33ca808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7000000006553f100000000006553f22c000000000000017f000e0000766563746f722e6578616d706c65"
