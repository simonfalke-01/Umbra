import Foundation
import UmbraCore
import UmbraNetworking

/// LSP permission bits stored for one freshly paired client/host relationship.
public struct LSPPermission: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let browseApplications = Self(rawValue: 1 << 0)
    public static let startOrAttach = Self(rawValue: 1 << 1)
    public static let input = Self(rawValue: 1 << 2)
    public static let microphone = Self(rawValue: 1 << 3)
    public static let stopOwnStream = Self(rawValue: 1 << 4)
    public static let quitApplication = Self(rawValue: 1 << 5)
    public static let controllerOutput = Self(rawValue: 1 << 6)
    public static let allKnown: Self = [
        .browseApplications,
        .startOrAttach,
        .input,
        .microphone,
        .stopOwnStream,
        .quitApplication,
        .controllerOutput,
    ]
}

/// Authenticated LSP trust established by a fresh LSP pairing.
public struct LSPTrustRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { hostID }
    public var hostID: UUID
    public var hostIdentityKey: Data
    public var dtlsSPKISHA256: Data
    public var pendingDTLSSPKISHA256: Data?
    public var permissions: LSPPermission
    public var revocationGeneration: UInt64
    public var certificateRotationGeneration: UInt32?

    public init(
        hostID: UUID,
        hostIdentityKey: Data,
        dtlsSPKISHA256: Data,
        permissions: LSPPermission,
        revocationGeneration: UInt64,
        certificateRotationGeneration: UInt32 = 0,
        pendingDTLSSPKISHA256: Data? = nil
    ) {
        self.hostID = hostID
        self.hostIdentityKey = hostIdentityKey
        self.dtlsSPKISHA256 = dtlsSPKISHA256
        self.pendingDTLSSPKISHA256 = pendingDTLSSPKISHA256
        self.permissions = permissions
        self.revocationGeneration = revocationGeneration
        self.certificateRotationGeneration = certificateRotationGeneration
    }

    public func validate() throws {
        guard hostIdentityKey.count == 32 else {
            throw ModelValidationError(field: "lspTrust.hostIdentityKey", reason: "must contain 32 bytes")
        }
        guard dtlsSPKISHA256.count == 32 else {
            throw ModelValidationError(field: "lspTrust.dtlsSPKISHA256", reason: "must contain 32 bytes")
        }
        if let pendingDTLSSPKISHA256 {
            guard pendingDTLSSPKISHA256.count == 32,
                  pendingDTLSSPKISHA256 != dtlsSPKISHA256 else {
                throw ModelValidationError(
                    field: "lspTrust.pendingDTLSSPKISHA256",
                    reason: "must contain a distinct 32-byte staged pin"
                )
            }
        }
        guard permissions.subtracting(.allKnown).isEmpty else {
            throw ModelValidationError(field: "lspTrust.permissions", reason: "contains unknown permission bits")
        }
        guard revocationGeneration > 0 else {
            throw ModelValidationError(field: "lspTrust.revocationGeneration", reason: "must be nonzero")
        }
    }

    public func promotingAuthenticatedSPKI(_ authenticatedSPKI: Data) -> Self? {
        guard authenticatedSPKI == dtlsSPKISHA256 || authenticatedSPKI == pendingDTLSSPKISHA256 else {
            return nil
        }
        var updated = self
        if authenticatedSPKI == pendingDTLSSPKISHA256 {
            updated.dtlsSPKISHA256 = authenticatedSPKI
            updated.pendingDTLSSPKISHA256 = nil
        }
        return updated
    }
}

/// Persisted LSP host address independent of legacy GameStream hosts.
public struct LSPHostRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { hostID }
    public var hostID: UUID
    public var name: String
    public var address: String
    public var port: UInt16
    public var lastSeen: Date
    public var discoveryDomain: String?
    public var interfaceName: String?
    public var hasManualEndpoint: Bool

    public init(
        hostID: UUID,
        name: String,
        address: String,
        port: UInt16 = 48_030,
        lastSeen: Date,
        discoveryDomain: String? = nil,
        interfaceName: String? = nil,
        hasManualEndpoint: Bool = false
    ) {
        self.hostID = hostID
        self.name = name
        self.address = address
        self.port = port
        self.lastSeen = lastSeen
        self.discoveryDomain = discoveryDomain
        self.interfaceName = interfaceName
        self.hasManualEndpoint = hasManualEndpoint
    }

    private enum CodingKeys: String, CodingKey {
        case hostID
        case name
        case address
        case port
        case lastSeen
        case discoveryDomain
        case interfaceName
        case hasManualEndpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hostID: try container.decode(UUID.self, forKey: .hostID),
            name: try container.decode(String.self, forKey: .name),
            address: try container.decode(String.self, forKey: .address),
            port: try container.decode(UInt16.self, forKey: .port),
            lastSeen: try container.decode(Date.self, forKey: .lastSeen),
            discoveryDomain: try container.decodeIfPresent(String.self, forKey: .discoveryDomain),
            interfaceName: try container.decodeIfPresent(String.self, forKey: .interfaceName),
            hasManualEndpoint: try container.decodeIfPresent(Bool.self, forKey: .hasManualEndpoint) ?? false
        )
    }

    /// Validates and canonicalizes a manually entered IPv4, IPv6, or DNS endpoint address.
    ///
    /// The port remains a separate field. An address containing an explicit port is accepted only
    /// when it matches that field, preventing an ambiguous endpoint from being persisted.
    ///
    /// - Parameters:
    ///   - address: User-entered IPv4 literal, IPv6 literal, or DNS hostname.
    ///   - port: Separate nonzero LSP UDP port.
    /// - Returns: Canonical address text suitable for the native transport.
    public static func normalizedManualAddress(_ address: String, port: UInt16) throws -> String {
        guard port != 0 else { throw UmbraNetworkingError.invalidPort(String(port)) }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("://") else { throw UmbraNetworkingError.invalidAddress(address) }
        let endpoint = try AddressNormalizer().normalize(trimmed, defaultPort: port)
        guard endpoint.port == port else { throw UmbraNetworkingError.invalidAddress(address) }
        return endpoint.host
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError(field: "lspHost.name", reason: "must not be empty")
        }
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError(field: "lspHost.address", reason: "must not be empty")
        }
        guard port != 0 else {
            throw ModelValidationError(field: "lspHost.port", reason: "must be nonzero")
        }
        if let discoveryDomain {
            guard !discoveryDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ModelValidationError(field: "lspHost.discoveryDomain", reason: "must not be empty")
            }
        }
        if let interfaceName {
            guard !interfaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ModelValidationError(field: "lspHost.interfaceName", reason: "must not be empty")
            }
        }
    }
}

/// Version-one LSP trust-file payload.
public struct LSPTrustSnapshot: ValidatedPersistenceModel, Hashable, Sendable {
    /// Empty version-one trust snapshot.
    public static let defaultValue = LSPTrustSnapshot()

    /// Persistence schema version, exactly one.
    public var schemaVersion: Int

    /// Fresh LSP trust records keyed by host ID.
    public var records: [LSPTrustRecord]

    public init(schemaVersion: Int = 1, records: [LSPTrustRecord] = []) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw ModelValidationError(field: "lspTrust.schemaVersion", reason: "must equal one")
        }
        var identifiers = Set<UUID>()
        for record in records {
            try record.validate()
            guard identifiers.insert(record.id).inserted else {
                throw ModelValidationError(field: "lspTrust.records", reason: "contains duplicate host IDs")
            }
        }
    }
}

/// Version-one LSP host-catalog payload.
public struct LSPHostSnapshot: ValidatedPersistenceModel, Hashable, Sendable {
    /// Empty version-one host snapshot.
    public static let defaultValue = LSPHostSnapshot()

    /// Persistence schema version, exactly one.
    public var schemaVersion: Int

    /// Native LSP hosts keyed by host ID.
    public var records: [LSPHostRecord]

    public init(schemaVersion: Int = 1, records: [LSPHostRecord] = []) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw ModelValidationError(field: "lspHosts.schemaVersion", reason: "must equal one")
        }
        var identifiers = Set<UUID>()
        for record in records {
            try record.validate()
            guard identifiers.insert(record.id).inserted else {
                throw ModelValidationError(field: "lspHosts.records", reason: "contains duplicate host IDs")
            }
        }
    }
}

/// Version-one LSP-only client application-identity payload.
public struct LSPClientIdentitySnapshot: ValidatedPersistenceModel, Equatable, Sendable {
    public static let defaultValue = LSPClientIdentitySnapshot()

    public var schemaVersion: Int
    public var identity: LSPClientIdentity?

    public init(schemaVersion: Int = 1, identity: LSPClientIdentity? = nil) {
        self.schemaVersion = schemaVersion
        self.identity = identity
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw ModelValidationError(field: "lspIdentity.schemaVersion", reason: "must equal one")
        }
        if let identity {
            guard identity.clientID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                  identity.privateKeyRawRepresentation.count == 32
            else {
                throw ModelValidationError(field: "lspIdentity.identity", reason: "must contain a nonzero ID and Ed25519 key")
            }
            _ = try identity.publicKeyRawRepresentation
        }
    }
}

/// Factory for LSP-only persistence files that never reuse retired experimental or legacy state.
public enum LSPPersistence {
    /// LSP-only trust-store filename.
    public static let trustFileName = "lsp-trust-v1.json"

    /// LSP-only host-catalog filename.
    public static let hostsFileName = "lsp-hosts-v1.json"

    /// LSP-only owner-private application identity filename.
    public static let clientIdentityFileName = "lsp-client-identity-v1.json"

    /// Creates LSP stores rooted at an explicit application-support directory.
    ///
    /// - Parameter directory: Umbra application-support directory.
    /// - Returns: Independent trust and host JSON stores.
    public static func stores(
        in directory: URL
    ) -> (
        trust: JSONFileStore<LSPTrustSnapshot>,
        hosts: JSONFileStore<LSPHostSnapshot>,
        identity: JSONFileStore<LSPClientIdentitySnapshot>
    ) {
        (
            JSONFileStore(fileURL: directory.appendingPathComponent(trustFileName, isDirectory: false)),
            JSONFileStore(fileURL: directory.appendingPathComponent(hostsFileName, isDirectory: false)),
            JSONFileStore(fileURL: directory.appendingPathComponent(clientIdentityFileName, isDirectory: false))
        )
    }

    /// Creates LSP stores in Umbra's normal application-support directory.
    ///
    /// - Parameters:
    ///   - fileManager: File manager used to resolve application support.
    ///   - bundleIdentifier: Application-support directory name.
    /// - Returns: Independent trust and host JSON stores.
    public static func applicationSupportStores(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "app.umbra.Umbra"
    ) throws -> (
        trust: JSONFileStore<LSPTrustSnapshot>,
        hosts: JSONFileStore<LSPHostSnapshot>,
        identity: JSONFileStore<LSPClientIdentitySnapshot>
    ) {
        let supportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return stores(in: supportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }

    /// Loads the stable LSP-only identity or atomically creates it on first use.
    public static func loadOrCreateClientIdentity(
        from store: JSONFileStore<LSPClientIdentitySnapshot>
    ) async throws -> LSPClientIdentity {
        let snapshot = try await store.load()
        if let identity = snapshot.identity {
            return identity
        }
        let generated = LSPClientIdentity.generate()
        try await store.save(LSPClientIdentitySnapshot(identity: generated))
        return generated
    }
}

enum LSPPairingPersistenceTransactionError: Error {
    case rollbackFailed
}

enum LSPPairingPersistenceTransaction {
    static func commit(
        trust: LSPTrustRecord,
        host: LSPHostRecord,
        trustStore: JSONFileStore<LSPTrustSnapshot>,
        hostStore: JSONFileStore<LSPHostSnapshot>,
        afterTrustWrite: @Sendable () throws -> Void = {}
    ) async throws {
        let originalTrust = try await trustStore.load()
        let originalHosts = try await hostStore.load()
        var updatedTrust = originalTrust
        updatedTrust.records.removeAll { $0.hostID == trust.hostID }
        updatedTrust.records.append(trust)
        var updatedHosts = originalHosts
        updatedHosts.records.removeAll { $0.hostID == host.hostID }
        updatedHosts.records.append(host)

        try await trustStore.save(updatedTrust)
        do {
            try afterTrustWrite()
            try await hostStore.save(updatedHosts)
        } catch {
            do {
                _ = try await trustStore.update { current in
                    var restored = current
                    restored.records.removeAll { $0.hostID == trust.hostID }
                    if let prior = originalTrust.records.first(where: { $0.hostID == trust.hostID }) {
                        restored.records.append(prior)
                    }
                    return restored
                }
            } catch {
                throw LSPPairingPersistenceTransactionError.rollbackFailed
            }
            throw error
        }
    }
}
