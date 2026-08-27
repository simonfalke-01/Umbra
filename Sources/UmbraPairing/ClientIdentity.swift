import CommonCrypto
import Foundation
import Security
import UmbraCore

public struct ClientIdentity: @unchecked Sendable {
    public let privateKey: SecKey
    public let certificateDER: Data

    public init(privateKey: SecKey, certificateDER: Data) throws {
        let certificateKey = try PairingCertificate.publicKey(from: certificateDER)
        guard let expectedKey = SecKeyCopyPublicKey(privateKey),
              keysMatch(expectedKey, certificateKey)
        else {
            throw PairingError.identityUnavailable("The certificate does not match the private key")
        }
        self.privateKey = privateKey
        self.certificateDER = certificateDER
    }

    public var certificatePEM: Data {
        PairingCertificate.pem(from: certificateDER)
    }

    public var persistenceFingerprint: Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        certificateDER.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return Data(digest)
    }

    public func makeURLCredential() throws -> URLCredential {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw PairingError.invalidCertificate("The client certificate could not be decoded for TLS authentication")
        }
        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw PairingError.identityUnavailable("The TLS certificate does not match the client private key")
        }
        return URLCredential(identity: identity, certificates: [certificate], persistence: .forSession)
    }
}

public protocol ClientIdentityProviding: Sendable {
    func identity() throws -> ClientIdentity
}

public struct StaticClientIdentityProvider: ClientIdentityProviding, @unchecked Sendable {
    private let value: ClientIdentity

    public init(_ value: ClientIdentity) {
        self.value = value
    }

    public func identity() throws -> ClientIdentity { value }
}

public final class FileBackedClientIdentityProvider: ClientIdentityProviding, @unchecked Sendable {
    private static let processFileLock = NSLock()
    private static let legacyClientIDKey = "Umbra.gameStreamClientID"
    private static let legacyPreferenceDomains = ["io.umbra.Umbra", "Umbra"]

    private struct StoredIdentity: Codable {
        static let currentVersion = 1

        let version: Int
        let privateKeyDER: Data
        let certificateDER: Data
        var clientID: String?
    }

    private let storageURL: URL
    private let randomSource: any PairingRandomSource
    private let legacyClientIDProvider: @Sendable () -> String?
    private let lock = NSLock()
    private var cachedIdentity: ClientIdentity?
    private var cachedClientID: String?

    public convenience init() {
        self.init(storageURL: Self.defaultStorageURL())
    }

    public init(storageURL: URL) {
        self.storageURL = storageURL
        self.randomSource = SecurePairingRandomSource()
        self.legacyClientIDProvider = Self.loadLegacyClientID
    }

    init(
        storageURL: URL,
        randomSource: any PairingRandomSource,
        legacyClientIDProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.storageURL = storageURL
        self.randomSource = randomSource
        self.legacyClientIDProvider = legacyClientIDProvider
    }

    public static func defaultStorageURL(fileManager: FileManager = .default) -> URL {
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return supportDirectory
            .appendingPathComponent("app.umbra.Umbra", isDirectory: true)
            .appendingPathComponent("client-identity-v1.json", isDirectory: false)
    }

    public func identity() throws -> ClientIdentity {
        lock.lock()
        defer { lock.unlock() }

        if let cachedIdentity { return cachedIdentity }
        Self.processFileLock.lock()
        defer { Self.processFileLock.unlock() }
        let identity = try withExclusiveFileLock { access in
            if try access.fileExists() {
                return try loadIdentity(access: access)
            }
            return try createAndPersistIdentity(access: access)
        }
        cachedIdentity = identity
        return identity
    }

    public func clientID() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cachedClientID { return cachedClientID }
        Self.processFileLock.lock()
        defer { Self.processFileLock.unlock() }
        let clientID = try withExclusiveFileLock { access in
            if try !access.fileExists() {
                cachedIdentity = try createAndPersistIdentity(access: access)
            }
            var stored = try loadStoredIdentity(access: access)
            if let existing = stored.clientID {
                return existing
            }
            let resolvedID = legacyClientIDProvider().flatMap(Self.validClientID) ?? Self.makeClientID()
            stored.clientID = resolvedID
            try persist(stored, access: access)
            return resolvedID
        }
        cachedClientID = clientID
        return clientID
    }

    private func createAndPersistIdentity(access: SecureAtomicFileWriter.Access) throws -> ClientIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
        ]
        var generationError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &generationError) else {
            throw PairingError.identityUnavailable(
                generationError?.takeRetainedValue().localizedDescription ?? "RSA-2048 generation failed"
            )
        }
        var serial = try randomSource.bytes(count: 16)
        if !serial.isEmpty { serial[serial.startIndex] &= 0x7F }
        let now = Date()
        let certificate = try PairingCertificate.makeSelfSigned(
            privateKey: privateKey,
            serialNumber: serial,
            notBefore: now.addingTimeInterval(-86_400),
            notAfter: now.addingTimeInterval(20 * 365 * 86_400)
        )
        var exportError: Unmanaged<CFError>?
        guard let privateKeyDER = SecKeyCopyExternalRepresentation(privateKey, &exportError) as Data? else {
            throw PairingError.identityUnavailable(
                exportError?.takeRetainedValue().localizedDescription ?? "RSA private-key export failed"
            )
        }
        let identity = try ClientIdentity(privateKey: privateKey, certificateDER: certificate)
        let stored = StoredIdentity(
            version: StoredIdentity.currentVersion,
            privateKeyDER: privateKeyDER,
            certificateDER: certificate,
            clientID: legacyClientIDProvider().flatMap(Self.validClientID) ?? Self.makeClientID()
        )
        try persist(stored, access: access)
        cachedClientID = stored.clientID
        return identity
    }

    private func loadIdentity(access: SecureAtomicFileWriter.Access) throws -> ClientIdentity {
        do {
            let stored = try loadStoredIdentity(access: access)
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 2_048,
            ]
            var importError: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateWithData(
                stored.privateKeyDER as CFData,
                attributes as CFDictionary,
                &importError
            ) else {
                throw PairingError.identityUnavailable(
                    importError?.takeRetainedValue().localizedDescription ?? "The stored RSA private key is unreadable"
                )
            }
            return try ClientIdentity(privateKey: privateKey, certificateDER: stored.certificateDER)
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.identityUnavailable(
                "The stored client identity is unreadable and was not replaced: \(error.localizedDescription)"
            )
        }
    }

    private func loadStoredIdentity(access: SecureAtomicFileWriter.Access) throws -> StoredIdentity {
        let stored = try JSONDecoder().decode(StoredIdentity.self, from: access.read())
        guard stored.version == StoredIdentity.currentVersion else {
            throw PairingError.identityUnavailable("The stored client identity version is unsupported")
        }
        if let clientID = stored.clientID, !Self.isValidClientID(clientID) {
            throw PairingError.identityUnavailable(
                "The stored client identifier is invalid and was not replaced"
            )
        }
        return stored
    }

    private func persist(_ stored: StoredIdentity, access: SecureAtomicFileWriter.Access) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)
        try access.atomicWrite(data)
    }

    private static func makeClientID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func loadLegacyClientID() -> String? {
        for domain in legacyPreferenceDomains {
            let value = UserDefaults.standard
                .persistentDomain(forName: domain)?[legacyClientIDKey] as? String
            if let valid = validClientID(value) { return valid }
        }
        return validClientID(UserDefaults.standard.string(forKey: legacyClientIDKey))
    }

    private static func validClientID(_ value: String?) -> String? {
        guard let value, isValidClientID(value) else { return nil }
        return value
    }

    private static func isValidClientID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private func withExclusiveFileLock<T>(
        _ operation: (SecureAtomicFileWriter.Access) throws -> T
    ) throws -> T {
        do {
            return try SecureAtomicFileWriter.withExclusiveAccess(to: storageURL, operation)
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.identityUnavailable(
                "The client identity persistence path is unavailable: \(error.localizedDescription)"
            )
        }
    }
}

func makeEphemeralIdentity(
    commonName: String = "NVIDIA GameStream Client",
    serialNumber: Data = Data([1]),
    notBefore: Date = Date(timeIntervalSince1970: 1_704_067_200),
    notAfter: Date = Date(timeIntervalSince1970: 2_335_219_200)
) throws -> ClientIdentity {
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits as String: 2_048,
    ]
    var error: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
        throw PairingError.identityUnavailable(error?.takeRetainedValue().localizedDescription ?? "Ephemeral RSA generation failed")
    }
    let certificate = try PairingCertificate.makeSelfSigned(
        privateKey: privateKey,
        commonName: commonName,
        serialNumber: serialNumber,
        notBefore: notBefore,
        notAfter: notAfter
    )
    return try ClientIdentity(privateKey: privateKey, certificateDER: certificate)
}

private func keysMatch(_ lhs: SecKey, _ rhs: SecKey) -> Bool {
    guard let lhsData = SecKeyCopyExternalRepresentation(lhs, nil) as Data?,
          let rhsData = SecKeyCopyExternalRepresentation(rhs, nil) as Data?
    else { return false }
    return lhsData == rhsData
}
