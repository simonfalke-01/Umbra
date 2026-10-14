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
    public static let clipboard = Self(rawValue: 1 << 7)
    public static let allKnown: Self = [
        .browseApplications,
        .startOrAttach,
        .input,
        .microphone,
        .stopOwnStream,
        .quitApplication,
        .controllerOutput,
        .clipboard,
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

/// One address at which an LSP host has been reached or advertised.
public struct LSPHostEndpoint: Codable, Hashable, Sendable {
    /// How Umbra learned the address; stronger sources are kept when entries merge.
    public enum Source: Int, Codable, Comparable, Sendable {
        /// Resolved from a successful connection (for example, the LAN IP behind a Bonjour name).
        case learned = 0
        /// Advertised by Bonjour on the local network.
        case discovered = 1
        /// Entered by the user, such as a public address for remote access.
        case manual = 2

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var address: String
    public var port: UInt16
    public var source: Source
    public var lastSeen: Date?
    public var lastSucceeded: Date?

    public init(
        address: String,
        port: UInt16,
        source: Source,
        lastSeen: Date? = nil,
        lastSucceeded: Date? = nil
    ) {
        self.address = address
        self.port = port
        self.source = source
        self.lastSeen = lastSeen
        self.lastSucceeded = lastSucceeded
    }

    /// Case-insensitive address and port identity.
    var key: String { "\(address.lowercased())|\(port)" }
}

/// Persisted LSP host independent of legacy GameStream host records.
///
/// A host keeps every address it has been reached at, like Moonlight: Bonjour names,
/// learned LAN addresses, and manual (for example, public) addresses. Connections try
/// them in order of recent success, so changing networks never strands a saved host.
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
    /// Every known address, including the preferred `address`/`port`.
    public var endpoints: [LSPHostEndpoint]
    /// Lowercase GameStream unique ID advertised by the same host, when known.
    public var legacyHostID: String?

    /// Largest number of remembered addresses per source.
    static let maximumEndpointsPerSource = 4

    public init(
        hostID: UUID,
        name: String,
        address: String,
        port: UInt16 = 48_030,
        lastSeen: Date,
        discoveryDomain: String? = nil,
        interfaceName: String? = nil,
        hasManualEndpoint: Bool = false,
        endpoints: [LSPHostEndpoint] = [],
        legacyHostID: String? = nil
    ) {
        self.hostID = hostID
        self.name = name
        self.address = address
        self.port = port
        self.lastSeen = lastSeen
        self.discoveryDomain = discoveryDomain
        self.interfaceName = interfaceName
        self.hasManualEndpoint = hasManualEndpoint
        self.endpoints = endpoints
        self.legacyHostID = legacyHostID
        if !endpoints.contains(where: { $0.address.lowercased() == address.lowercased() && $0.port == port }) {
            self.endpoints.insert(
                .init(address: address, port: port, source: hasManualEndpoint ? .manual : .discovered, lastSeen: lastSeen),
                at: 0
            )
        }
    }

    /// Addresses to try, most recently successful first, then by source and recency.
    public func connectionCandidates() -> [LSPHostEndpoint] {
        let order: [LSPHostEndpoint.Source] = [.discovered, .learned, .manual]
        return endpoints.sorted { lhs, rhs in
            switch (lhs.lastSucceeded, rhs.lastSucceeded) {
            case let (left?, right?) where left != right:
                return left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }
            if lhs.source != rhs.source {
                // Discovered LAN names are fastest at home; manual addresses cover remote access.
                return order.firstIndex(of: lhs.source)! < order.firstIndex(of: rhs.source)!
            }
            return (lhs.lastSeen ?? .distantPast) > (rhs.lastSeen ?? .distantPast)
        }
    }

    /// Adds or refreshes one address without discarding any other known address.
    public mutating func upsert(_ endpoint: LSPHostEndpoint) {
        if let index = endpoints.firstIndex(where: { $0.key == endpoint.key }) {
            var merged = endpoints[index]
            merged.source = max(merged.source, endpoint.source)
            merged.lastSeen = [merged.lastSeen, endpoint.lastSeen].compactMap { $0 }.max()
            merged.lastSucceeded = [merged.lastSucceeded, endpoint.lastSucceeded].compactMap { $0 }.max()
            endpoints[index] = merged
        } else {
            endpoints.append(endpoint)
        }
        trimEndpoints()
    }

    /// Records a successful connection and makes that address preferred.
    public mutating func markSucceeded(address: String, port: UInt16, at date: Date = Date()) {
        upsert(.init(address: address, port: port, source: .learned, lastSeen: date, lastSucceeded: date))
        self.address = address
        self.port = port
        lastSeen = date
    }

    /// Replaces the user's manual address while keeping discovered and learned addresses.
    public mutating func setManualEndpoint(address: String, port: UInt16, at date: Date = Date()) {
        endpoints.removeAll { $0.source == .manual }
        upsert(.init(address: address, port: port, source: .manual, lastSeen: date))
        self.address = address
        self.port = port
        hasManualEndpoint = true
    }

    private mutating func trimEndpoints() {
        for source in [LSPHostEndpoint.Source.learned, .discovered, .manual] {
            let matching = endpoints.enumerated().filter { $0.element.source == source }
            guard matching.count > Self.maximumEndpointsPerSource else { continue }
            let removable = matching
                .sorted {
                    ($0.element.lastSucceeded ?? $0.element.lastSeen ?? .distantPast) <
                        ($1.element.lastSucceeded ?? $1.element.lastSeen ?? .distantPast)
                }
                .prefix(matching.count - Self.maximumEndpointsPerSource)
                .map(\.offset)
            for offset in removable.sorted(by: >) {
                endpoints.remove(at: offset)
            }
        }
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
        case endpoints
        case legacyHostID
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
            hasManualEndpoint: try container.decodeIfPresent(Bool.self, forKey: .hasManualEndpoint) ?? false,
            endpoints: try container.decodeIfPresent([LSPHostEndpoint].self, forKey: .endpoints) ?? [],
            legacyHostID: try container.decodeIfPresent(String.self, forKey: .legacyHostID)
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
        var mergedHost = host
        if let prior = originalHosts.records.first(where: { $0.hostID == host.hostID }) {
            // Re-pairing keeps every address the host was already reachable at.
            for endpoint in prior.endpoints { mergedHost.upsert(endpoint) }
            mergedHost.legacyHostID = host.legacyHostID ?? prior.legacyHostID
            mergedHost.hasManualEndpoint = prior.hasManualEndpoint || host.hasManualEndpoint
        }
        updatedHosts.records.removeAll { $0.hostID == host.hostID }
        updatedHosts.records.append(mergedHost)

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
