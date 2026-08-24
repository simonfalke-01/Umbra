import Darwin
import Foundation

struct ModernLumenV3ApplicationRecord: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var isRunning: Bool
    var artworkSHA256: Data?
    var isHidden: Bool
    var isDirectLaunch: Bool
}

struct ModernLumenV3HostRecord: Codable, Equatable, Sendable {
    var hostID: Data
    var hostname: String
    var hostnameIsIPLiteral: Bool?
    var port: UInt16
    var displayName: String
    var applications: [ModernLumenV3ApplicationRecord]
    var applicationRevision: UInt64?
    var runningApplicationID: Int?
}

final class FileBackedModernLumenV3HostCatalog: @unchecked Sendable {
    private struct StoredCatalog: Codable {
        static let version = 1
        var version: Int
        var hosts: [ModernLumenV3HostRecord]
    }

    private static let lock = NSLock()
    private let url: URL
    private let fileManager: FileManager

    init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.url = url ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("app.umbra.Umbra", isDirectory: true)
            .appendingPathComponent("protocol-v3-hosts-v1.json")
    }

    func allHosts() throws -> [ModernLumenV3HostRecord] {
        try withLock { try load().hosts }
    }

    func host(hostID: Data) throws -> ModernLumenV3HostRecord? {
        try withLock { try load().hosts.first { $0.hostID == hostID } }
    }

    func upsert(_ host: ModernLumenV3HostRecord) throws {
        try validate(host)
        try withLock {
            var catalog = try load()
            if let index = catalog.hosts.firstIndex(where: { $0.hostID == host.hostID }) {
                catalog.hosts[index] = host
            } else {
                catalog.hosts.append(host)
            }
            catalog.hosts.sort { $0.hostID.lexicographicallyPrecedes($1.hostID) }
            try persist(catalog)
        }
    }

    func remove(hostID: Data) throws {
        try withLock {
            var catalog = try load()
            catalog.hosts.removeAll { $0.hostID == hostID }
            try persist(catalog)
        }
    }

    private func load() throws -> StoredCatalog {
        guard fileManager.fileExists(atPath: url.path) else {
            return StoredCatalog(version: StoredCatalog.version, hosts: [])
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let catalog = try JSONDecoder().decode(StoredCatalog.self, from: Data(contentsOf: url))
        guard catalog.version == StoredCatalog.version else {
            throw UmbraClientServiceError.unavailable("The saved secure-host catalog has an unsupported version.")
        }
        try catalog.hosts.forEach(validate)
        guard Set(catalog.hosts.map(\.hostID)).count == catalog.hosts.count else {
            throw UmbraClientServiceError.unavailable("The saved secure-host catalog contains duplicate hosts.")
        }
        return catalog
    }

    private func validate(_ host: ModernLumenV3HostRecord) throws {
        guard host.hostID.count == 16,
              host.hostID.contains(where: { $0 != 0 }),
              !host.hostname.isEmpty,
              host.hostname.utf8.count <= 255,
              !host.displayName.isEmpty,
              host.displayName.utf8.count <= 255,
              Set(host.applications.map(\.id)).count == host.applications.count,
              host.applications.allSatisfy({
                  $0.id > 0 && !$0.name.isEmpty && $0.name.utf8.count <= 256
                      && ($0.artworkSHA256 == nil || $0.artworkSHA256?.count == 32)
              }),
              host.applications.filter(\.isRunning).count <= 1 else {
            throw UmbraClientServiceError.unavailable("The saved secure-host catalog is invalid.")
        }
    }

    private func persist(_ catalog: StoredCatalog) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        let temporary = directory.appendingPathComponent(".protocol-v3-hosts-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var renamed = false
        defer {
            Darwin.close(descriptor)
            if !renamed { Darwin.unlink(temporary.path) }
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), raw.count - written)
                guard count > 0 else { throw POSIXError(.EIO) }
                written += count
            }
        }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.rename(temporary.path, url.path) == 0 else {
            throw POSIXError(.EIO)
        }
        renamed = true
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else { throw POSIXError(.EIO) }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
        try Self.lock.withLock {
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let lockURL = url.appendingPathExtension("lock")
            let descriptor = Darwin.open(
                lockURL.path,
                O_CREAT | O_RDWR | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(descriptor) }
            guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else { throw POSIXError(.EIO) }
            defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
            return try operation()
        }
    }
}
