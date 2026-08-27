import CommonCrypto
import Foundation
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
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

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
        let reopenedIdentity = try FileBackedClientIdentityProvider(storageURL: storageURL).identity()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertFalse(reopenedIdentity.certificateDER.isEmpty)
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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)

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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)

        XCTAssertThrowsError(try FileBackedClientIdentityProvider(storageURL: storageURL).identity())
        XCTAssertEqual(try Data(contentsOf: storageURL), corruptData)
    }

    func testInvalidPersistedClientIDFailsWithoutChangingIdentityBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraPairingTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("client-identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try FileBackedClientIdentityProvider(storageURL: storageURL).identity()
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any]
        )
        envelope["clientID"] = "not-a-valid-client-id"
        let invalidBytes = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.prettyPrinted, .sortedKeys]
        )
        try invalidBytes.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)

        for operation in [
            { try FileBackedClientIdentityProvider(storageURL: storageURL).clientID() as Any },
            { try FileBackedClientIdentityProvider(storageURL: storageURL).identity() as Any },
        ] {
            XCTAssertThrowsError(try operation()) { error in
                guard case PairingError.identityUnavailable = error else {
                    return XCTFail("Expected identityUnavailable, received \(error)")
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: storageURL), invalidBytes)
    }

    func testOwnerReadableIdentityIsRejectedWithoutChangingBytesOrPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraPairingTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("client-identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try FileBackedClientIdentityProvider(storageURL: storageURL).identity()
        let identityBytes = try Data(contentsOf: storageURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storageURL.path)

        XCTAssertThrowsError(try FileBackedClientIdentityProvider(storageURL: storageURL).identity())
        XCTAssertEqual(try Data(contentsOf: storageURL), identityBytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testSymlinkedIdentityParentIsRejectedWithoutWritingExternalDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraPairingTests-\(UUID().uuidString)", isDirectory: true)
        let externalDirectory = root.appendingPathComponent("external", isDirectory: true)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: externalDirectory.path
        )
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: externalDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let externalIdentity = externalDirectory.appendingPathComponent("client-identity.json")
        XCTAssertThrowsError(
            try FileBackedClientIdentityProvider(
                storageURL: linkedDirectory.appendingPathComponent("client-identity.json")
            ).identity()
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalIdentity.path))
        let externalAttributes = try FileManager.default.attributesOfItem(atPath: externalDirectory.path)
        XCTAssertEqual((externalAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testSymlinkedIdentityFileIsRejectedWithoutChangingExternalTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraPairingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let externalURL = root.appendingPathComponent("external.json")
        let storageURL = root.appendingPathComponent("client-identity.json")
        let sentinel = Data("external-identity-sentinel".utf8)
        try sentinel.write(to: externalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: externalURL.path)
        try FileManager.default.createSymbolicLink(at: storageURL, withDestinationURL: externalURL)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try FileBackedClientIdentityProvider(storageURL: storageURL).identity())
        XCTAssertEqual(try Data(contentsOf: externalURL), sentinel)
    }

    func testSymlinkedIdentityLockIsRejectedWithoutChangingExternalTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraPairingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let externalURL = root.appendingPathComponent("external-lock")
        let storageURL = root.appendingPathComponent("client-identity.json")
        let sentinel = Data("external-lock-sentinel".utf8)
        try sentinel.write(to: externalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: externalURL.path)
        try FileManager.default.createSymbolicLink(
            at: storageURL.appendingPathExtension("lock"),
            withDestinationURL: externalURL
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try FileBackedClientIdentityProvider(storageURL: storageURL).identity())
        XCTAssertEqual(try Data(contentsOf: externalURL), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
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

    func testConcurrentIdentityCreationConvergesAcrossProcessesRepeatedly() throws {
        for iteration in 0..<3 {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("UmbraPairingSubprocess-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let barrierURL = directory.appendingPathComponent("barrier")
            let storageURL = directory.appendingPathComponent("client-identity.json")
            let workers = try (0..<4).map { workerIndex in
                try launchSubprocess(
                    test: "UmbraPairingTests.PairingCryptoTests/testIdentitySubprocessWorker",
                    environment: [
                        "UMBRA_IDENTITY_WORKER_DIRECTORY": directory.path,
                        "UMBRA_IDENTITY_WORKER_INDEX": String(workerIndex),
                    ]
                )
            }
            try Data().write(to: barrierURL)
            try assertSuccessful(workers)

            let certificates = try (0..<4).map { workerIndex in
                try Data(contentsOf: directory.appendingPathComponent("certificate-\(workerIndex).der"))
            }
            XCTAssertEqual(Set(certificates).count, 1, "iteration \(iteration)")
            let persisted = try FileBackedClientIdentityProvider(storageURL: storageURL).identity()
            XCTAssertEqual(certificates.first, persisted.certificateDER)
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    .filter { $0.hasSuffix(".tmp") }
                    .isEmpty,
                "Concurrent writes must use distinct temporary names and clean them up"
            )
        }
    }

    func testIdentitySubprocessWorker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directoryPath = environment["UMBRA_IDENTITY_WORKER_DIRECTORY"],
              let workerIndex = environment["UMBRA_IDENTITY_WORKER_INDEX"]
        else {
            return
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try waitForBarrier(at: directory.appendingPathComponent("barrier"))
        let identity = try FileBackedClientIdentityProvider(
            storageURL: directory.appendingPathComponent("client-identity.json")
        ).identity()
        try identity.certificateDER.write(
            to: directory.appendingPathComponent("certificate-\(workerIndex).der")
        )
    }

    private func launchSubprocess(
        test: String,
        environment additions: [String: String]
    ) throws -> (process: Process, output: Pipe) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", test, Bundle(for: Self.self).bundleURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, addition in addition }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return (process, output)
    }

    private func assertSuccessful(_ workers: [(process: Process, output: Pipe)]) throws {
        for worker in workers {
            worker.process.waitUntilExit()
            let output = worker.output.fileHandleForReading.readDataToEndOfFile()
            guard worker.process.terminationStatus == 0 else {
                XCTFail(String(decoding: output, as: UTF8.self))
                throw CocoaError(.executableRuntimeMismatch)
            }
        }
    }

    private func waitForBarrier(at barrierURL: URL) throws {
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: barrierURL.path) {
            guard Date() < deadline else {
                throw CocoaError(.fileReadUnknown)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
