import Darwin
import Foundation

public struct UmbraStorageRecoveryResult: Equatable, Sendable {
    public let backupURL: URL

    public init(backupURL: URL) {
        self.backupURL = backupURL
    }
}

public struct UmbraStorageRecoveryError: Error, LocalizedError, Sendable {
    public let errorDescription: String?

    init(_ description: String) {
        self.errorDescription = description
    }
}

/// Explicitly preserves an unreadable Umbra storage directory for later recovery.
///
/// Recovery never reads or deletes the directory's contents. It validates the directory entry and
/// atomically renames it to a unique sibling, allowing the next normal launch to create fresh state.
public enum UmbraStorageRecovery {
    public static func defaultStorageDirectory(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "app.umbra.Umbra"
    ) throws -> URL {
        let supportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return supportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static func recoverDefaultStorage(
        fileManager: FileManager = .default,
        timestamp: Date = Date(),
        identifier: UUID = UUID()
    ) throws -> UmbraStorageRecoveryResult {
        try recoverStorage(
            at: defaultStorageDirectory(fileManager: fileManager),
            timestamp: timestamp,
            identifier: identifier
        )
    }

    public static func recoverStorage(
        at directoryURL: URL,
        timestamp: Date = Date(),
        identifier: UUID = UUID()
    ) throws -> UmbraStorageRecoveryResult {
        guard directoryURL.isFileURL else {
            throw UmbraStorageRecoveryError("The Umbra storage location must be a file URL")
        }
        let standardizedURL = directoryURL.standardizedFileURL
        let sourceName = standardizedURL.lastPathComponent
        guard !sourceName.isEmpty, sourceName != ".", sourceName != "..", !sourceName.contains("/") else {
            throw UmbraStorageRecoveryError("The Umbra storage directory name is invalid")
        }

        let parentURL = standardizedURL.deletingLastPathComponent()
        let parentDescriptor: Int32
        do {
            parentDescriptor = try SecureAtomicFileWriter.openSecureDirectory(
                at: parentURL,
                createIfMissing: false,
                secureFinalPermissions: false
            )
        } catch {
            throw UmbraStorageRecoveryError(
                "The Umbra storage parent directory is unsafe: \(error.localizedDescription)"
            )
        }
        defer { Darwin.close(parentDescriptor) }

        let sourceStatus = try entryStatus(
            directoryDescriptor: parentDescriptor,
            name: sourceName,
            label: "Umbra storage directory"
        )
        guard sourceStatus.st_mode & S_IFMT != S_IFLNK else {
            throw UmbraStorageRecoveryError("A symlinked Umbra storage directory is not allowed")
        }
        try validateDirectory(sourceStatus, label: "Umbra storage directory")

        let sourceDescriptor = sourceName.withCString { name in
            Darwin.openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sourceDescriptor >= 0 else {
            throw posixError("The Umbra storage directory could not be opened")
        }
        defer { Darwin.close(sourceDescriptor) }

        let sourceDescriptorStatus = try descriptorStatus(
            sourceDescriptor,
            label: "Umbra storage directory"
        )
        try validateDirectory(sourceDescriptorStatus, label: "Umbra storage directory")
        try requireSameEntry(sourceStatus, sourceDescriptorStatus, label: "Umbra storage directory")

        let backupURL = backupURL(
            for: standardizedURL,
            timestamp: timestamp,
            identifier: identifier
        )
        let backupName = backupURL.lastPathComponent
        var collisionStatus = stat()
        let collisionResult = backupName.withCString { name in
            Darwin.fstatat(parentDescriptor, name, &collisionStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard collisionResult != 0, errno == ENOENT else {
            throw UmbraStorageRecoveryError("The requested Umbra storage backup path already exists")
        }

        let revalidatedSourceStatus = try entryStatus(
            directoryDescriptor: parentDescriptor,
            name: sourceName,
            label: "Umbra storage directory"
        )
        try validateDirectory(revalidatedSourceStatus, label: "Umbra storage directory")
        try requireSameEntry(
            sourceDescriptorStatus,
            revalidatedSourceStatus,
            label: "Umbra storage directory"
        )

        let renameResult = sourceName.withCString { sourceName in
            backupName.withCString { backupName in
                Darwin.renameatx_np(
                    parentDescriptor,
                    sourceName,
                    parentDescriptor,
                    backupName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            throw posixError("The Umbra storage directory could not be moved to its backup")
        }

        do {
            let installedBackupStatus = try entryStatus(
                directoryDescriptor: parentDescriptor,
                name: backupName,
                label: "Umbra storage backup directory"
            )
            guard installedBackupStatus.st_mode & S_IFMT != S_IFLNK else {
                throw UmbraStorageRecoveryError(
                    "The installed Umbra storage backup is unexpectedly symlinked"
                )
            }
            try validateDirectory(installedBackupStatus, label: "Umbra storage backup directory")
            try requireSameEntry(
                sourceDescriptorStatus,
                installedBackupStatus,
                label: "Umbra storage backup directory"
            )
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw posixError("The Umbra storage backup directory entry could not be synchronized")
            }
        } catch {
            throw UmbraStorageRecoveryError(
                "Umbra storage was moved to the recoverable backup at \(backupURL.path), "
                    + "but final verification failed: \(error.localizedDescription)"
            )
        }
        return UmbraStorageRecoveryResult(backupURL: backupURL)
    }

    static func backupURL(for directoryURL: URL, timestamp: Date, identifier: UUID) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        let backupName = directoryURL.lastPathComponent
            + ".recovery-"
            + formatter.string(from: timestamp)
            + "-"
            + identifier.uuidString.lowercased()
        return directoryURL.deletingLastPathComponent()
            .appendingPathComponent(backupName, isDirectory: true)
    }

    static func validateDirectory(_ status: stat, label: String) throws {
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw UmbraStorageRecoveryError("The \(label) is not a real directory")
        }
        guard status.st_uid == geteuid() else {
            throw UmbraStorageRecoveryError("The \(label) is not owned by the current user")
        }
    }

    private static func entryStatus(
        directoryDescriptor: Int32,
        name: String,
        label: String
    ) throws -> stat {
        var status = stat()
        let result = name.withCString { name in
            Darwin.fstatat(directoryDescriptor, name, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw posixError("The \(label) could not be inspected")
        }
        return status
    }

    private static func descriptorStatus(_ descriptor: Int32, label: String) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw posixError("The \(label) descriptor could not be inspected")
        }
        return status
    }

    private static func requireSameEntry(_ lhs: stat, _ rhs: stat, label: String) throws {
        guard lhs.st_dev == rhs.st_dev, lhs.st_ino == rhs.st_ino else {
            throw UmbraStorageRecoveryError("The \(label) changed while it was being validated")
        }
    }

    private static func posixError(_ message: String) -> UmbraStorageRecoveryError {
        let code = errno
        return UmbraStorageRecoveryError(
            "\(message) (errno \(code): \(String(cString: strerror(code))))"
        )
    }
}
