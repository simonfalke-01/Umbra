import Darwin
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

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.fileManager = .default
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> Value {
        try withExclusiveFileLock { try loadUnlocked() }
    }

    public func save(_ value: Value) throws {
        try withExclusiveFileLock { try saveUnlocked(value) }
    }

    @discardableResult
    public func update(_ transform: @Sendable (Value) throws -> Value) throws -> Value {
        try withExclusiveFileLock {
            let updated = try transform(loadUnlocked())
            try saveUnlocked(updated)
            return updated
        }
    }

    public func reset() throws {
        try save(Value.defaultValue)
    }

    private func loadUnlocked() throws -> Value {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return Value.defaultValue
        }
        let data = try Data(contentsOf: fileURL)
        let value = try decoder.decode(Value.self, from: data)
        try value.validate()
        return value
    }

    private func saveUnlocked(_ value: Value) throws {
        try value.validate()
        let parentDirectory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func withExclusiveFileLock<T>(_ operation: () throws -> T) throws -> T {
        jsonFileStoreProcessLock.lock()
        defer { jsonFileStoreProcessLock.unlock() }
        let parentDirectory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try operation()
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
