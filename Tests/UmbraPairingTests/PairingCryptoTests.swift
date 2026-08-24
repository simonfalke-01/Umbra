import CommonCrypto
import Security
import XCTest
@testable import UmbraPairing

final class PairingCryptoTests: XCTestCase {
    func testDigestGenerationSwitchAndSaltedPINVectors() throws {
        XCTAssertEqual(try PairingDigest.forServerVersion("6.5.0.0"), .sha1)
        XCTAssertEqual(try PairingDigest.forServerVersion("7.0.0.0"), .sha256)
        XCTAssertEqual(try PairingDigest.forServerVersion("2025.122.0"), .sha256)
        XCTAssertThrowsError(try PairingDigest.forServerVersion("sunshine"))

        let salt = Data(0..<16)
        XCTAssertEqual(
            PairingCryptography.pinKey(salt: salt, pin: "1234", using: .sha1).pairingHex,
            "0cd2f00b23437ed6adc97cd8f7dbf3ed"
        )
        XCTAssertEqual(
            PairingCryptography.pinKey(salt: salt, pin: "1234", using: .sha256).pairingHex,
            "bad0b4f7cae08eb7c1b5acc763a8ed25"
        )
    }

    func testAES128ECBMatchesNISTVector() throws {
        let key = try Data(pairingHex: "2b7e151628aed2a6abf7158809cf4f3c")
        let plaintext = try Data(pairingHex: "6bc1bee22e409f96e93d7e117393172a")
        let expected = try Data(pairingHex: "3ad77bb40d7a3660a89ecaf32466ef97")

        let encrypted = try PairingCryptography.encrypt(plaintext, key: key)
        XCTAssertEqual(encrypted, expected)
        XCTAssertEqual(try PairingCryptography.decrypt(encrypted, key: key), plaintext)
    }

    func testGeneratedCertificateMatchesRSA2048KeyAndSupportsProtocolSignatures() throws {
        let identity = try makeEphemeralIdentity(serialNumber: Data([0x12, 0x34]))
        let attributes = SecKeyCopyAttributes(identity.privateKey) as? [CFString: Any]
        XCTAssertEqual(attributes?[kSecAttrKeySizeInBits] as? Int, 2_048)

        XCTAssertNotNil(SecCertificateCreateWithData(nil, identity.certificateDER as CFData))
        XCTAssertTrue(identity.certificatePEM.starts(with: Data("-----BEGIN CERTIFICATE-----".utf8)))
        XCTAssertFalse(try PairingCertificate.signature(from: identity.certificateDER).isEmpty)

        let message = Data("pairing-secret".utf8)
        let signature = try PairingCryptography.sign(message, with: identity.privateKey)
        let publicKey = try PairingCertificate.publicKey(from: identity.certificateDER)
        XCTAssertTrue(PairingCryptography.verify(signature, message: message, publicKey: publicKey))
        XCTAssertFalse(PairingCryptography.verify(signature, message: Data("tampered".utf8), publicKey: publicKey))
    }

    func testFileBackedIdentityPersistsAndResolvesForMutualTLS() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraPairingTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("client-identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try FileBackedClientIdentityProvider(storageURL: storageURL).identity()
        let second = try FileBackedClientIdentityProvider(storageURL: storageURL).identity()
        XCTAssertEqual(first.certificateDER, second.certificateDER)
        XCTAssertNoThrow(try first.makeURLCredential())

        let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let message = Data("persisted-identity".utf8)
        let signature = try PairingCryptography.sign(message, with: second.privateKey)
        let publicKey = try PairingCertificate.publicKey(from: first.certificateDER)
        XCTAssertTrue(PairingCryptography.verify(signature, message: message, publicKey: publicKey))
    }

    func testFileBackedClientIDPersistsAcrossProviderInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraPairingTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("client-identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try FileBackedClientIdentityProvider(
            storageURL: storageURL,
            randomSource: SecurePairingRandomSource()
        ).clientID()
        let second = try FileBackedClientIdentityProvider(
            storageURL: storageURL,
            randomSource: SecurePairingRandomSource()
        ).clientID()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testLegacyClientIDIsPreservedWhenCreatingTheFileBackedIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraPairingTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("client-identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyClientID = "2A3D9CC00DF249529E071C0A5C200084"
        let provider = FileBackedClientIdentityProvider(
            storageURL: storageURL,
            randomSource: SecurePairingRandomSource(),
            legacyClientIDProvider: { legacyClientID }
        )

        _ = try provider.identity()
        XCTAssertEqual(try provider.clientID(), legacyClientID)
        XCTAssertEqual(
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any]
            )["clientID"] as? String,
            legacyClientID
        )
    }

    func testLegacyIdentityMigratesClientIDWithoutChangingKeyMaterial() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraPairingTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("client-identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalProvider = FileBackedClientIdentityProvider(storageURL: storageURL)
        let originalIdentity = try originalProvider.identity()
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any]
        )
        envelope.removeValue(forKey: "clientID")
        try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
            .write(to: storageURL, options: .atomic)

        let legacyClientID = "2A3D9CC00DF249529E071C0A5C200084"
        let migratedProvider = FileBackedClientIdentityProvider(
            storageURL: storageURL,
            randomSource: SecurePairingRandomSource(),
            legacyClientIDProvider: { legacyClientID }
        )
        let clientID = try migratedProvider.clientID()
        let migratedIdentity = try migratedProvider.identity()

        XCTAssertEqual(clientID, legacyClientID)
        XCTAssertEqual(migratedIdentity.certificateDER, originalIdentity.certificateDER)

        let message = Data("legacy-migration".utf8)
        let signature = try PairingCryptography.sign(message, with: migratedIdentity.privateKey)
        let originalPublicKey = try PairingCertificate.publicKey(from: originalIdentity.certificateDER)
        XCTAssertTrue(PairingCryptography.verify(signature, message: message, publicKey: originalPublicKey))
    }

    func testCorruptStoredIdentityFailsWithoutReplacingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraPairingTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("client-identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try FileBackedClientIdentityProvider(storageURL: storageURL).identity()
        let corruptData = Data("not an identity".utf8)
        try corruptData.write(to: storageURL, options: .atomic)

        XCTAssertThrowsError(try FileBackedClientIdentityProvider(storageURL: storageURL).identity())
        XCTAssertEqual(try Data(contentsOf: storageURL), corruptData)
    }

    func testConcurrentProvidersConvergeOnOnePersistedIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraPairingTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("client-identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        async let first = Task.detached {
            try FileBackedClientIdentityProvider(storageURL: storageURL).identity()
        }.value
        async let second = Task.detached {
            try FileBackedClientIdentityProvider(storageURL: storageURL).identity()
        }.value

        let identities = try await (first, second)
        XCTAssertEqual(identities.0.certificateDER, identities.1.certificateDER)
    }
}
