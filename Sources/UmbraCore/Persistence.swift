import Foundation

private let jsonFileStoreProcessLock = NSLock()

public protocol ValidatedPersistenceModel: Codable, Sendable {
    static var defaultValue: Self { get }
    func validate() throws
}

public struct UmbraSnapshot: ValidatedPersistenceModel, Hashable, Sendable {
    public static let currentSchemaVersion = 2
    public static let defaultValue = UmbraSnapshot()

    public var schemaVersion: Int
    public var hosts: [StreamHost]
    public var preferences: StreamingPreferences
    public var clientIdentityFingerprint: Data?

    public init(
        schemaVersion: Int = UmbraSnapshot.currentSchemaVersion,
        hosts: [StreamHost] = [],
        preferences: StreamingPreferences = .default,
        clientIdentityFingerprint: Data? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.hosts = hosts
        self.preferences = preferences
        self.clientIdentityFingerprint = clientIdentityFingerprint
    }

    public func validate() throws {
        guard schemaVersion > 0, schemaVersion <= Self.currentSchemaVersion else {
            throw ModelValidationError(
                field: "snapshot.schemaVersion",
                reason: "unsupported schema version \(schemaVersion)"
            )
        }
        try preferences.validate()
        var hostIDs = Set<String>()
        for host in hosts {
            try host.validate()
            guard hostIDs.insert(host.id).inserted else {
                throw ModelValidationError(field: "snapshot.hosts", reason: "contains duplicate host id \(host.id)")
            }
        }
    }
}

public actor JSONFileStore<Value: ValidatedPersistenceModel> {
    public let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> Value {
        try withExclusiveFileLock { access in try loadUnlocked(access: access) }
    }

    public func save(_ value: Value) throws {
        try withExclusiveFileLock { access in try saveUnlocked(value, access: access) }
    }

    @discardableResult
    public func update(_ transform: @Sendable (Value) throws -> Value) throws -> Value {
        try withExclusiveFileLock { access in
            let updated = try transform(loadUnlocked(access: access))
            try saveUnlocked(updated, access: access)
            return updated
        }
    }

    public func reset() throws {
        try save(Value.defaultValue)
    }

    private func loadUnlocked(access: SecureAtomicFileWriter.Access) throws -> Value {
        guard let data = try access.readIfPresentHardeningLegacyOwnerReadablePermissions() else {
            return Value.defaultValue
        }
        let value = try decoder.decode(Value.self, from: data)
        try value.validate()
        return value
    }

    private func saveUnlocked(_ value: Value, access: SecureAtomicFileWriter.Access) throws {
        try value.validate()
        let data = try encoder.encode(value)
        try access.atomicWrite(data)
    }

    private func withExclusiveFileLock<T>(
        _ operation: (SecureAtomicFileWriter.Access) throws -> T
    ) throws -> T {
        jsonFileStoreProcessLock.lock()
        defer { jsonFileStoreProcessLock.unlock() }
        return try SecureAtomicFileWriter.withExclusiveAccess(to: fileURL, operation)
    }
}

public extension JSONFileStore where Value == UmbraSnapshot {
    static func applicationSupport(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "app.umbra.Umbra"
    ) throws -> JSONFileStore<UmbraSnapshot> {
        let supportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return JSONFileStore(
            fileURL: supportDirectory
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false)
        )
    }
}
