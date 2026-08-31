import Foundation
import UmbraCore

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
    public var permissions: LSPPermission
    public var revocationGeneration: UInt64

    public init(
        hostID: UUID,
        hostIdentityKey: Data,
        dtlsSPKISHA256: Data,
        permissions: LSPPermission,
        revocationGeneration: UInt64
    ) {
        self.hostID = hostID
        self.hostIdentityKey = hostIdentityKey
        self.dtlsSPKISHA256 = dtlsSPKISHA256
        self.permissions = permissions
        self.revocationGeneration = revocationGeneration
    }

    public func validate() throws {
        guard hostIdentityKey.count == 32 else {
            throw ModelValidationError(field: "lspTrust.hostIdentityKey", reason: "must contain 32 bytes")
        }
        guard dtlsSPKISHA256.count == 32 else {
            throw ModelValidationError(field: "lspTrust.dtlsSPKISHA256", reason: "must contain 32 bytes")
        }
        guard permissions.subtracting(.allKnown).isEmpty else {
            throw ModelValidationError(field: "lspTrust.permissions", reason: "contains unknown permission bits")
        }
        guard revocationGeneration > 0 else {
            throw ModelValidationError(field: "lspTrust.revocationGeneration", reason: "must be nonzero")
        }
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

    public init(
        hostID: UUID,
        name: String,
        address: String,
        port: UInt16 = 48_030,
        lastSeen: Date
    ) {
        self.hostID = hostID
        self.name = name
        self.address = address
        self.port = port
        self.lastSeen = lastSeen
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

/// Factory for LSP-only persistence files that never reuse retired v3 or legacy state.
public enum LSPPersistence {
    /// LSP-only trust-store filename.
    public static let trustFileName = "lsp-trust-v1.json"

    /// LSP-only host-catalog filename.
    public static let hostsFileName = "lsp-hosts-v1.json"

    /// Creates LSP stores rooted at an explicit application-support directory.
    ///
    /// - Parameter directory: Umbra application-support directory.
    /// - Returns: Independent trust and host JSON stores.
    public static func stores(
        in directory: URL
    ) -> (trust: JSONFileStore<LSPTrustSnapshot>, hosts: JSONFileStore<LSPHostSnapshot>) {
        (
            JSONFileStore(fileURL: directory.appendingPathComponent(trustFileName, isDirectory: false)),
            JSONFileStore(fileURL: directory.appendingPathComponent(hostsFileName, isDirectory: false))
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
    ) throws -> (trust: JSONFileStore<LSPTrustSnapshot>, hosts: JSONFileStore<LSPHostSnapshot>) {
        let supportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return stores(in: supportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }
}
