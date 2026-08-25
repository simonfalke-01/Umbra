import Darwin
import Foundation

public enum ProtocolV3TrustStorageScope: Sendable {
    case currentUser
}

public struct ProtocolV3TrustStorageDescriptor: Sendable {
    public let url: URL
    public let scope: ProtocolV3TrustStorageScope
    public let isBackupEligible: Bool
    public let usesSystemKeychain: Bool
}

enum ProtocolV3TrustStoreFaultPoint: Sendable {
    case beforeFileSync
    case beforeRename
    case beforeDirectorySync
}

public protocol ProtocolV3TrustPersisting: Sendable {
    func commitPairing(
        identity: ProtocolV3ClientIdentity,
        trust: ProtocolV3TrustRecord,
        invitationID: Data,
        attemptID: Data
    ) throws
}

public struct ProtocolV3PairingAttempt: Codable, Equatable, Sendable {
    public let invitationID: Data
    public let attemptID: Data
    public let requestedPermissions: UInt64
    public let displayName: String
}

public final class FileBackedProtocolV3TrustStore: ProtocolV3TrustPersisting, @unchecked Sendable {
    private static let processLock = NSLock()
    private struct StoredState: Codable {
        static let version = 1
        var version: Int
        var privateSeed: Data
        var trusts: [String: ProtocolV3TrustRecord]
        var attempts: [String: ProtocolV3PairingAttempt]
    }

    private let url: URL
    private let fileManager: FileManager
    private let faultInjector: @Sendable (ProtocolV3TrustStoreFaultPoint) throws -> Void

    public init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.url = url ?? Self.storageDescriptor(
            applicationSupportDirectory: fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
        ).url
        faultInjector = { _ in }
    }

    public convenience init(
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.init(
            url: Self.storageDescriptor(
                applicationSupportDirectory: applicationSupportDirectory
            ).url,
            fileManager: fileManager
        )
    }

    init(
        url: URL,
        faultInjector: @escaping @Sendable (ProtocolV3TrustStoreFaultPoint) throws -> Void
    ) {
        self.url = url
        fileManager = .default
        self.faultInjector = faultInjector
    }

    public static func storageDescriptor(
        applicationSupportDirectory: URL
    ) -> ProtocolV3TrustStorageDescriptor {
        ProtocolV3TrustStorageDescriptor(
            url: applicationSupportDirectory
                .appendingPathComponent("app.umbra.Umbra", isDirectory: true)
                .appendingPathComponent("protocol-v3-trust-v1.json"),
            scope: .currentUser,
            isBackupEligible: true,
            usesSystemKeychain: false
        )
    }

    public func identity() throws -> ProtocolV3ClientIdentity {
        try withExclusiveLock { directory in
            var state = try loadOrCreate(in: directory)
            if state.privateSeed.isEmpty {
                state.privateSeed = try ProtocolV3ClientIdentity.secureRandomBytes(count: 32)
                try persist(state, in: directory)
            }
            return try ProtocolV3ClientIdentity(privateSeed: state.privateSeed)
        }
    }

    public func beginPairing(
        invitation: ProtocolV3PairingInvitation,
        requestedPermissions: UInt64,
        displayName: String
    ) throws -> ProtocolV3PairingAttempt {
        try withExclusiveLock { directory in
            guard requestedPermissions != 0, requestedPermissions & ~UInt64(0xff) == 0,
                  !displayName.isEmpty, displayName.utf8.count <= 64 else {
                throw ProtocolV3WireError.invalidField("v3 pairing attempt")
            }
            var state = try loadOrCreate(in: directory)
            let key = invitation.invitationID.map { String(format: "%02x", $0) }.joined()
            if let existing = state.attempts[key] {
                guard existing.requestedPermissions == requestedPermissions,
                      existing.displayName == displayName else {
                    throw ProtocolV3WireError.invalidField("conflicting v3 pairing retry")
                }
                return existing
            }
            let attempt = ProtocolV3PairingAttempt(
                invitationID: invitation.invitationID,
                attemptID: try ProtocolV3ClientIdentity.secureRandomBytes(count: 16),
                requestedPermissions: requestedPermissions,
                displayName: displayName
            )
            guard attempt.attemptID.contains(where: { $0 != 0 }) else {
                throw ProtocolV3WireError.cryptography
            }
            // One process-wide pairing authority is durable at a time. Starting
            // a new QR attempt atomically supersedes any abandoned prior attempt.
            state.attempts = [key: attempt]
            try persist(state, in: directory)
            return attempt
        }
    }

    public func cancelPairingAttempt(invitationID: Data) throws {
        try withExclusiveLock { directory in
            var state = try loadOrCreate(in: directory)
            let key = invitationID.map { String(format: "%02x", $0) }.joined()
            guard state.attempts.removeValue(forKey: key) != nil else { return }
            try persist(state, in: directory)
        }
    }

    public func trust(hostID: Data) throws -> ProtocolV3TrustRecord? {
        try withExclusiveLock { directory in
            try loadOrCreate(in: directory).trusts[hostID.map { String(format: "%02x", $0) }.joined()]
        }
    }

    public func allTrusts() throws -> [ProtocolV3TrustRecord] {
        try withExclusiveLock { directory in
            Array(try loadOrCreate(in: directory).trusts.values)
        }
    }

    public func removeTrust(hostID: Data) throws {
        try withExclusiveLock { directory in
            var state = try loadOrCreate(in: directory)
            let key = hostID.map { String(format: "%02x", $0) }.joined()
            state.trusts.removeValue(forKey: key)
            try persist(state, in: directory)
        }
    }

    public func commit(identity: ProtocolV3ClientIdentity, trust: ProtocolV3TrustRecord) throws {
        try withExclusiveLock { directory in
            var state = try loadOrCreate(in: directory)
            try validateIdentity(identity, trust: trust, state: state)
            commit(trust, to: &state)
            try persist(state, in: directory)
        }
    }

    public func commitPairing(
        identity: ProtocolV3ClientIdentity,
        trust: ProtocolV3TrustRecord,
        invitationID: Data,
        attemptID: Data
    ) throws {
        try withExclusiveLock { directory in
            var state = try loadOrCreate(in: directory)
            try validateIdentity(identity, trust: trust, state: state)
            let key = invitationID.map { String(format: "%02x", $0) }.joined()
            guard state.attempts.count == 1,
                  let active = state.attempts[key],
                  active.invitationID == invitationID,
                  active.attemptID == attemptID else {
                throw ProtocolV3WireError.invalidField("inactive v3 pairing attempt")
            }
            commit(trust, to: &state)
            try persist(state, in: directory)
        }
    }

    private func validateIdentity(
        _ identity: ProtocolV3ClientIdentity,
        trust: ProtocolV3TrustRecord,
        state: StoredState
    ) throws {
        guard state.privateSeed == identity.privateSeedData,
              trust.clientID == identity.clientID else {
            throw ProtocolV3WireError.invalidField("v3 identity persistence mismatch")
        }
    }

    private func commit(_ trust: ProtocolV3TrustRecord, to state: inout StoredState) {
        let hostKey = trust.hostID.map { String(format: "%02x", $0) }.joined()
        state.trusts[hostKey] = trust
        state.attempts.removeAll(keepingCapacity: false)
    }

    private func loadOrCreate(in directory: Int32) throws -> StoredState {
        if let descriptor = try openStateFileIfPresent(in: directory) {
            defer { Darwin.close(descriptor) }
            let state = try JSONDecoder().decode(
                StoredState.self,
                from: try readAll(from: descriptor)
            )
            guard state.version == StoredState.version, state.privateSeed.count == 32,
                  state.trusts.count <= 256, state.attempts.count <= 1 else {
                throw ProtocolV3WireError.invalidField("v3 trust-store state")
            }
            let identity = try ProtocolV3ClientIdentity(privateSeed: state.privateSeed)
            guard state.trusts.allSatisfy({ key, trust in
                key == trust.hostID.map { String(format: "%02x", $0) }.joined() &&
                    trust.clientID == identity.clientID
            }), state.attempts.allSatisfy({ key, attempt in
                key == attempt.invitationID.map { String(format: "%02x", $0) }.joined() &&
                    attempt.invitationID.count == 16 && attempt.invitationID.contains(where: { $0 != 0 }) &&
                    attempt.attemptID.count == 16 && attempt.attemptID.contains(where: { $0 != 0 }) &&
                    attempt.requestedPermissions != 0 && attempt.requestedPermissions & ~UInt64(0xff) == 0 &&
                    !attempt.displayName.isEmpty && attempt.displayName.utf8.count <= 64
            }) else {
                throw ProtocolV3WireError.invalidField("v3 trust-store authority")
            }
            return state
        }
        let state = StoredState(
            version: StoredState.version,
            privateSeed: try ProtocolV3ClientIdentity.secureRandomBytes(count: 32),
            trusts: [:],
            attempts: [:]
        )
        try persist(state, in: directory)
        return state
    }

    private func persist(_ state: StoredState, in directory: Int32) throws {
        try validateReplaceableTarget(in: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(state)
        let temporaryName = ".protocol-v3-\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(
            directory,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var renamed = false
        defer {
            Darwin.close(descriptor)
            if !renamed { Darwin.unlinkat(directory, temporaryName, 0) }
        }
        try harden(descriptor, type: S_IFREG, permissions: 0o600)
        try write(encoded, to: descriptor)
        try faultInjector(.beforeFileSync)
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
        try faultInjector(.beforeRename)
        guard Darwin.renameat(directory, temporaryName, directory, stateFileName) == 0 else {
            throw POSIXError(.EIO)
        }
        renamed = true
        try faultInjector(.beforeDirectorySync)
        guard Darwin.fsync(directory) == 0 else { throw POSIXError(.EIO) }
    }

    private func withExclusiveLock<Value>(_ operation: (Int32) throws -> Value) throws -> Value {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let directory = try openStorageDirectory()
        defer { Darwin.close(directory) }
        let descriptor = Darwin.openat(
            directory,
            lockFileName,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        try harden(descriptor, type: S_IFREG, permissions: 0o600)
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else { throw POSIXError(.EIO) }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try operation(directory)
    }

    private var stateFileName: String { url.lastPathComponent }
    private var lockFileName: String { stateFileName + ".lock" }

    private func openStorageDirectory() throws -> Int32 {
        guard url.isFileURL, !stateFileName.isEmpty, stateFileName != ".", stateFileName != ".." else {
            throw POSIXError(.EINVAL)
        }
        let directoryURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var metadata = stat()
        guard Darwin.lstat(directoryURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid() else {
            throw POSIXError(.EACCES)
        }
        let descriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        do {
            try harden(descriptor, type: S_IFDIR, permissions: 0o700)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openStateFileIfPresent(in directory: Int32) throws -> Int32? {
        var metadata = stat()
        if Darwin.fstatat(directory, stateFileName, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw POSIXError(.EIO) }
            return nil
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == Darwin.geteuid() else {
            throw POSIXError(.EACCES)
        }
        let descriptor = Darwin.openat(
            directory,
            stateFileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        do {
            try harden(descriptor, type: S_IFREG, permissions: 0o600)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func validateReplaceableTarget(in directory: Int32) throws {
        var metadata = stat()
        if Darwin.fstatat(directory, stateFileName, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw POSIXError(.EIO) }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == Darwin.geteuid() else {
            throw POSIXError(.EACCES)
        }
    }

    private func harden(_ descriptor: Int32, type: mode_t, permissions: mode_t) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == type,
              metadata.st_uid == Darwin.geteuid(),
              Darwin.fchmod(descriptor, permissions) == 0,
              Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & 0o777 == permissions else {
            throw POSIXError(.EACCES)
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw POSIXError(.EIO)
            }
            guard count > 0 else { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    raw.count - written
                )
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    throw POSIXError(.EIO)
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                written += count
            }
        }
    }
}
