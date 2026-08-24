import Darwin
import Foundation

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

    public init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let url {
            self.url = url
        } else {
            self.url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("app.umbra.Umbra", isDirectory: true)
                .appendingPathComponent("protocol-v3-trust-v1.json")
        }
    }

    public func identity() throws -> ProtocolV3ClientIdentity {
        try withExclusiveLock {
            var state = try loadOrCreate()
            if state.privateSeed.isEmpty {
                state.privateSeed = try ProtocolV3ClientIdentity.secureRandomBytes(count: 32)
                try persist(state)
            }
            return try ProtocolV3ClientIdentity(privateSeed: state.privateSeed)
        }
    }

    public func beginPairing(
        invitation: ProtocolV3PairingInvitation,
        requestedPermissions: UInt64,
        displayName: String
    ) throws -> ProtocolV3PairingAttempt {
        try withExclusiveLock {
            guard requestedPermissions != 0, requestedPermissions & ~UInt64(0xff) == 0,
                  !displayName.isEmpty, displayName.utf8.count <= 64 else {
                throw ProtocolV3WireError.invalidField("v3 pairing attempt")
            }
            var state = try loadOrCreate()
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
            try persist(state)
            return attempt
        }
    }

    public func cancelPairingAttempt(invitationID: Data) throws {
        try withExclusiveLock {
            var state = try loadOrCreate()
            let key = invitationID.map { String(format: "%02x", $0) }.joined()
            guard state.attempts.removeValue(forKey: key) != nil else { return }
            try persist(state)
        }
    }

    public func trust(hostID: Data) throws -> ProtocolV3TrustRecord? {
        try withExclusiveLock {
            try loadOrCreate().trusts[hostID.map { String(format: "%02x", $0) }.joined()]
        }
    }

    public func allTrusts() throws -> [ProtocolV3TrustRecord] {
        try withExclusiveLock { Array(try loadOrCreate().trusts.values) }
    }

    public func removeTrust(hostID: Data) throws {
        try withExclusiveLock {
            var state = try loadOrCreate()
            let key = hostID.map { String(format: "%02x", $0) }.joined()
            state.trusts.removeValue(forKey: key)
            try persist(state)
        }
    }

    public func commit(identity: ProtocolV3ClientIdentity, trust: ProtocolV3TrustRecord) throws {
        try withExclusiveLock {
            var state = try loadOrCreate()
            try validateIdentity(identity, trust: trust, state: state)
            commit(trust, to: &state)
            try persist(state)
        }
    }

    public func commitPairing(
        identity: ProtocolV3ClientIdentity,
        trust: ProtocolV3TrustRecord,
        invitationID: Data,
        attemptID: Data
    ) throws {
        try withExclusiveLock {
            var state = try loadOrCreate()
            try validateIdentity(identity, trust: trust, state: state)
            let key = invitationID.map { String(format: "%02x", $0) }.joined()
            guard state.attempts.count == 1,
                  let active = state.attempts[key],
                  active.invitationID == invitationID,
                  active.attemptID == attemptID else {
                throw ProtocolV3WireError.invalidField("inactive v3 pairing attempt")
            }
            commit(trust, to: &state)
            try persist(state)
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

    private func loadOrCreate() throws -> StoredState {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let state = try JSONDecoder().decode(StoredState.self, from: Data(contentsOf: url))
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
        try persist(state)
        return state
    }

    private func persist(_ state: StoredState) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(state)
        let temporary = directory.appendingPathComponent(".protocol-v3-\(UUID().uuidString).tmp")
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
        try encoded.withUnsafeBytes { raw in
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

    private func withExclusiveLock<Value>(_ operation: () throws -> Value) throws -> Value {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
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
