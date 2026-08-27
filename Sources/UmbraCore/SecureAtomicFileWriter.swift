import Darwin
import Foundation

public struct SecurePersistenceError: Error, LocalizedError, Sendable {
    public let errorDescription: String?

    init(_ description: String) {
        self.errorDescription = description
    }
}

/// Provides locked access to one owner-private persistence file without following symlinks.
public enum SecureAtomicFileWriter {
    public struct Access {
        fileprivate let directoryDescriptor: Int32
        fileprivate let fileName: String

        public func fileExists() throws -> Bool {
            try SecureAtomicFileWriter.validateDataEntryIfPresent(
                directoryDescriptor: directoryDescriptor,
                fileName: fileName
            ) != nil
        }

        public func read() throws -> Data {
            try read(hardeningLegacyOwnerReadablePermissions: false)
        }

        public func readIfPresentHardeningLegacyOwnerReadablePermissions() throws -> Data? {
            guard let pathStatus = try SecureAtomicFileWriter.validateDataEntryIfPresent(
                directoryDescriptor: directoryDescriptor,
                fileName: fileName,
                allowingLegacyOwnerReadablePermissions: true
            ) else {
                return nil
            }
            return try read(
                pathStatus: pathStatus,
                hardeningLegacyOwnerReadablePermissions: true
            )
        }

        private func read(hardeningLegacyOwnerReadablePermissions: Bool) throws -> Data {
            let pathStatus = try SecureAtomicFileWriter.requiredEntryStatus(
                directoryDescriptor: directoryDescriptor,
                name: fileName,
                label: "persistence file"
            )
            return try read(
                pathStatus: pathStatus,
                hardeningLegacyOwnerReadablePermissions: hardeningLegacyOwnerReadablePermissions
            )
        }

        private func read(
            pathStatus: stat,
            hardeningLegacyOwnerReadablePermissions: Bool
        ) throws -> Data {
            try SecureAtomicFileWriter.validateRegularOwnedFile(pathStatus, label: "persistence file")
            let pathPermissions = pathStatus.st_mode & mode_t(0o777)
            let requiresHardening = pathPermissions == mode_t(0o644)
            guard pathPermissions == mode_t(0o600)
                    || (hardeningLegacyOwnerReadablePermissions && requiresHardening)
            else {
                throw SecurePersistenceError("The persistence file is not owner-private")
            }

            let descriptor = fileName.withCString { name in
                Darwin.openat(directoryDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw SecureAtomicFileWriter.posixError("The persistence file could not be opened")
            }
            defer { Darwin.close(descriptor) }

            let descriptorStatus = try SecureAtomicFileWriter.fileStatus(
                descriptor: descriptor,
                label: "persistence file"
            )
            try SecureAtomicFileWriter.validateRegularOwnedFile(descriptorStatus, label: "persistence file")
            try SecureAtomicFileWriter.requireSameFile(
                pathStatus,
                descriptorStatus,
                label: "persistence file"
            )

            var securedDescriptorStatus = descriptorStatus
            if requiresHardening {
                guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                    throw SecureAtomicFileWriter.posixError(
                        "The legacy persistence file permissions could not be secured"
                    )
                }
                securedDescriptorStatus = try SecureAtomicFileWriter.fileStatus(
                    descriptor: descriptor,
                    label: "persistence file"
                )
                try SecureAtomicFileWriter.validateRegularOwnerPrivateFile(
                    securedDescriptorStatus,
                    label: "persistence file"
                )
                try SecureAtomicFileWriter.requireSameFile(
                    descriptorStatus,
                    securedDescriptorStatus,
                    label: "persistence file"
                )
                let securedPathStatus = try SecureAtomicFileWriter.requiredEntryStatus(
                    directoryDescriptor: directoryDescriptor,
                    name: fileName,
                    label: "persistence file"
                )
                try SecureAtomicFileWriter.validateRegularOwnerPrivateFile(
                    securedPathStatus,
                    label: "persistence file"
                )
                try SecureAtomicFileWriter.requireSameFile(
                    securedDescriptorStatus,
                    securedPathStatus,
                    label: "persistence file"
                )
            } else {
                try SecureAtomicFileWriter.validateRegularOwnerPrivateFile(
                    descriptorStatus,
                    label: "persistence file"
                )
            }

            var result = Data()
            result.reserveCapacity(max(0, Int(securedDescriptorStatus.st_size)))
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    result.append(buffer, count: count)
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    throw SecureAtomicFileWriter.posixError("The persistence file could not be read")
                }
            }

            let finalDescriptorStatus = try SecureAtomicFileWriter.fileStatus(
                descriptor: descriptor,
                label: "persistence file"
            )
            let finalPathStatus = try SecureAtomicFileWriter.requiredEntryStatus(
                directoryDescriptor: directoryDescriptor,
                name: fileName,
                label: "persistence file"
            )
            try SecureAtomicFileWriter.requireSameFile(
                securedDescriptorStatus,
                finalDescriptorStatus,
                label: "persistence file"
            )
            try SecureAtomicFileWriter.requireSameFile(
                securedDescriptorStatus,
                finalPathStatus,
                label: "persistence file"
            )
            try SecureAtomicFileWriter.validateRegularOwnerPrivateFile(
                finalDescriptorStatus,
                label: "persistence file"
            )
            try SecureAtomicFileWriter.validateRegularOwnerPrivateFile(
                finalPathStatus,
                label: "persistence file"
            )
            guard result.count == securedDescriptorStatus.st_size else {
                throw SecurePersistenceError("The persistence file changed while it was being read")
            }
            return result
        }

        public func atomicWrite(_ data: Data) throws {
            _ = try SecureAtomicFileWriter.validateDataEntryIfPresent(
                directoryDescriptor: directoryDescriptor,
                fileName: fileName
            )

            let temporaryName = ".\(fileName).\(UUID().uuidString).tmp"
            let descriptor = temporaryName.withCString { name in
                Darwin.openat(
                    directoryDescriptor,
                    name,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard descriptor >= 0 else {
                throw SecureAtomicFileWriter.posixError("The temporary persistence file could not be created")
            }

            var shouldRemoveTemporaryFile = true
            defer {
                Darwin.close(descriptor)
                if shouldRemoveTemporaryFile {
                    _ = temporaryName.withCString { name in
                        Darwin.unlinkat(directoryDescriptor, name, 0)
                    }
                }
            }

            let initialStatus = try SecureAtomicFileWriter.fileStatus(
                descriptor: descriptor,
                label: "temporary persistence file"
            )
            try SecureAtomicFileWriter.validateRegularOwnerPrivateFile(
                initialStatus,
                label: "temporary persistence file"
            )

            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count > 0 {
                        offset += count
                    } else if count == 0 {
                        throw SecurePersistenceError("The temporary persistence file accepted an incomplete write")
                    } else if errno != EINTR {
                        throw SecureAtomicFileWriter.posixError("The temporary persistence file could not be written")
                    }
                }
            }

            guard Darwin.fsync(descriptor) == 0 else {
                throw SecureAtomicFileWriter.posixError("The temporary persistence file could not be synchronized")
            }
            let completedStatus = try SecureAtomicFileWriter.fileStatus(
                descriptor: descriptor,
                label: "temporary persistence file"
            )
            try SecureAtomicFileWriter.validateRegularOwnerPrivateFile(
                completedStatus,
                label: "temporary persistence file"
            )
            try SecureAtomicFileWriter.requireSameFile(
                initialStatus,
                completedStatus,
                label: "temporary persistence file"
            )
            guard completedStatus.st_size == data.count else {
                throw SecurePersistenceError("The temporary persistence file contains an incomplete write")
            }

            if let destinationStatus = try SecureAtomicFileWriter.validateDataEntryIfPresent(
                directoryDescriptor: directoryDescriptor,
                fileName: fileName
            ) {
                let revalidatedStatus = try SecureAtomicFileWriter.requiredEntryStatus(
                    directoryDescriptor: directoryDescriptor,
                    name: fileName,
                    label: "persistence file"
                )
                try SecureAtomicFileWriter.requireSameFile(
                    destinationStatus,
                    revalidatedStatus,
                    label: "persistence file"
                )
            }

            let renameResult = temporaryName.withCString { temporaryName in
                fileName.withCString { fileName in
                    Darwin.renameat(directoryDescriptor, temporaryName, directoryDescriptor, fileName)
                }
            }
            guard renameResult == 0 else {
                throw SecureAtomicFileWriter.posixError("The persistence file could not be atomically replaced")
            }
            shouldRemoveTemporaryFile = false

            let installedStatus = try SecureAtomicFileWriter.requiredEntryStatus(
                directoryDescriptor: directoryDescriptor,
                name: fileName,
                label: "persistence file"
            )
            try SecureAtomicFileWriter.validateRegularOwnerPrivateFile(
                installedStatus,
                label: "persistence file"
            )
            try SecureAtomicFileWriter.requireSameFile(
                completedStatus,
                installedStatus,
                label: "persistence file"
            )
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw SecureAtomicFileWriter.posixError("The persistence directory could not be synchronized")
            }
        }
    }

    public static func withExclusiveAccess<T>(
        to fileURL: URL,
        _ operation: (Access) throws -> T
    ) throws -> T {
        let location = try openSecureLocation(for: fileURL)
        defer { Darwin.close(location.directoryDescriptor) }

        let lockName = "\(location.fileName).lock"
        try rejectSymlinkIfPresent(
            directoryDescriptor: location.directoryDescriptor,
            name: lockName,
            label: "persistence lock"
        )
        let lockDescriptor = try openOrCreateLock(
            directoryDescriptor: location.directoryDescriptor,
            name: lockName
        )
        defer { Darwin.close(lockDescriptor) }

        let lockStatus = try fileStatus(descriptor: lockDescriptor, label: "persistence lock")
        try validateRegularOwnedFile(lockStatus, label: "persistence lock")
        guard Darwin.fchmod(lockDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw posixError("The persistence lock permissions could not be secured")
        }
        let securedLockStatus = try fileStatus(descriptor: lockDescriptor, label: "persistence lock")
        try validateRegularOwnerPrivateFile(securedLockStatus, label: "persistence lock")
        let lockPathStatus = try requiredEntryStatus(
            directoryDescriptor: location.directoryDescriptor,
            name: lockName,
            label: "persistence lock"
        )
        try requireSameFile(securedLockStatus, lockPathStatus, label: "persistence lock")

        guard Darwin.lockf(lockDescriptor, F_LOCK, 0) == 0 else {
            throw posixError("The persistence lock could not be acquired")
        }
        defer { _ = Darwin.lockf(lockDescriptor, F_ULOCK, 0) }

        let revalidatedLockStatus = try requiredEntryStatus(
            directoryDescriptor: location.directoryDescriptor,
            name: lockName,
            label: "persistence lock"
        )
        try requireSameFile(securedLockStatus, revalidatedLockStatus, label: "persistence lock")
        return try operation(
            Access(directoryDescriptor: location.directoryDescriptor, fileName: location.fileName)
        )
    }

    private struct SecureLocation {
        let directoryDescriptor: Int32
        let fileName: String
    }

    private static func openSecureLocation(for fileURL: URL) throws -> SecureLocation {
        guard fileURL.isFileURL else {
            throw SecurePersistenceError("The persistence location must be a file URL")
        }
        let standardizedURL = fileURL.standardizedFileURL
        let fileName = standardizedURL.lastPathComponent
        guard !fileName.isEmpty, fileName != ".", fileName != "..", !fileName.contains("/") else {
            throw SecurePersistenceError("The persistence file name is invalid")
        }

        let directoryURL = standardizedURL.deletingLastPathComponent()
        let descriptor = try openSecureDirectory(
            at: directoryURL,
            createIfMissing: true,
            secureFinalPermissions: true
        )
        return SecureLocation(directoryDescriptor: descriptor, fileName: fileName)
    }

    static func openSecureDirectory(
        at directoryURL: URL,
        createIfMissing: Bool,
        secureFinalPermissions: Bool
    ) throws -> Int32 {
        let components = directoryURL.pathComponents
        guard directoryURL.path.hasPrefix("/"), components.count > 1 else {
            throw SecurePersistenceError("The persistence directory must be an absolute non-root directory")
        }

        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw posixError("The filesystem root could not be opened")
        }

        do {
            let directoryComponents = components.dropFirst().filter { $0 != "/" && !$0.isEmpty }
            for (index, component) in directoryComponents.enumerated() {
                let nextDescriptor = try openDirectoryComponent(
                    parentDescriptor: descriptor,
                    name: component,
                    allowRootOwnedSymlink: index < directoryComponents.count - 1,
                    createIfMissing: createIfMissing
                )
                Darwin.close(descriptor)
                descriptor = nextDescriptor
            }

            let directoryStatus = try fileStatus(descriptor: descriptor, label: "persistence directory")
            try validateDirectory(directoryStatus, requireCurrentUser: true)
            if secureFinalPermissions {
                guard Darwin.fchmod(descriptor, mode_t(S_IRWXU)) == 0 else {
                    throw posixError("The persistence directory permissions could not be secured")
                }
                let securedDirectoryStatus = try fileStatus(
                    descriptor: descriptor,
                    label: "persistence directory"
                )
                try validateDirectory(securedDirectoryStatus, requireCurrentUser: true)
                guard securedDirectoryStatus.st_mode & mode_t(0o777) == mode_t(0o700) else {
                    throw SecurePersistenceError("The persistence directory is not owner-private")
                }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openDirectoryComponent(
        parentDescriptor: Int32,
        name: String,
        allowRootOwnedSymlink: Bool,
        createIfMissing: Bool
    ) throws -> Int32 {
        var pathStatus = stat()
        var statusResult = name.withCString { component in
            Darwin.fstatat(parentDescriptor, component, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0 {
            guard errno == ENOENT, createIfMissing else {
                throw posixError("A persistence directory component could not be inspected")
            }
            let creationResult = name.withCString { component in
                Darwin.mkdirat(parentDescriptor, component, mode_t(S_IRWXU))
            }
            guard creationResult == 0 || errno == EEXIST else {
                throw posixError("A persistence directory component could not be created")
            }
            statusResult = name.withCString { component in
                Darwin.fstatat(parentDescriptor, component, &pathStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0 else {
                throw posixError("A persistence directory component could not be inspected after creation")
            }
        }
        if pathStatus.st_mode & S_IFMT == S_IFLNK {
            let parentStatus = try fileStatus(
                descriptor: parentDescriptor,
                label: "persistence directory parent"
            )
            guard allowRootOwnedSymlink, pathStatus.st_uid == 0, parentStatus.st_uid == 0 else {
                throw SecurePersistenceError("A symlinked persistence directory is not allowed")
            }
            let descriptor = name.withCString { component in
                Darwin.openat(parentDescriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw posixError("A system persistence directory link could not be opened")
            }
            do {
                let descriptorStatus = try fileStatus(
                    descriptor: descriptor,
                    label: "system persistence directory link"
                )
                try validateDirectory(descriptorStatus, requireCurrentUser: false)
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        try validateDirectory(pathStatus, requireCurrentUser: false)

        let descriptor = name.withCString { component in
            Darwin.openat(parentDescriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw posixError("A persistence directory component could not be opened")
        }
        do {
            let descriptorStatus = try fileStatus(descriptor: descriptor, label: "persistence directory component")
            try validateDirectory(descriptorStatus, requireCurrentUser: false)
            try requireSameFile(pathStatus, descriptorStatus, label: "persistence directory component")
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateDirectory(_ status: stat, requireCurrentUser: Bool) throws {
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw SecurePersistenceError("The persistence path contains a non-directory component")
        }
        let currentUser = geteuid()
        if requireCurrentUser {
            guard status.st_uid == currentUser else {
                throw SecurePersistenceError("The persistence directory is not owned by the current user")
            }
        } else {
            guard status.st_uid == currentUser || status.st_uid == 0 else {
                throw SecurePersistenceError("A persistence directory component has an unexpected owner")
            }
        }
    }

    private static func validateDataEntryIfPresent(
        directoryDescriptor: Int32,
        fileName: String,
        allowingLegacyOwnerReadablePermissions: Bool = false
    ) throws -> stat? {
        var status = stat()
        let result = fileName.withCString { name in
            Darwin.fstatat(directoryDescriptor, name, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            guard status.st_mode & S_IFMT != S_IFLNK else {
                throw SecurePersistenceError("A symlinked persistence file is not allowed")
            }
            if allowingLegacyOwnerReadablePermissions,
               status.st_mode & mode_t(0o777) == mode_t(0o644) {
                try validateRegularOwnedFile(status, label: "persistence file")
            } else {
                try validateRegularOwnerPrivateFile(status, label: "persistence file")
            }
            return status
        }
        guard errno == ENOENT else {
            throw posixError("The persistence file could not be inspected")
        }
        return nil
    }

    private static func rejectSymlinkIfPresent(
        directoryDescriptor: Int32,
        name: String,
        label: String
    ) throws {
        var status = stat()
        let result = name.withCString { name in
            Darwin.fstatat(directoryDescriptor, name, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            guard status.st_mode & S_IFMT != S_IFLNK else {
                throw SecurePersistenceError("A symlinked \(label) is not allowed")
            }
            return
        }
        guard errno == ENOENT else {
            throw posixError("The \(label) could not be inspected")
        }
    }

    private static func openOrCreateLock(directoryDescriptor: Int32, name: String) throws -> Int32 {
        while true {
            let existingDescriptor = name.withCString { name in
                Darwin.openat(directoryDescriptor, name, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
            if existingDescriptor >= 0 {
                return existingDescriptor
            }
            guard errno == ENOENT else {
                if errno == EINTR { continue }
                throw posixError("The persistence lock could not be opened")
            }

            let createdDescriptor = name.withCString { name in
                Darwin.openat(
                    directoryDescriptor,
                    name,
                    O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if createdDescriptor >= 0 {
                return createdDescriptor
            }
            if errno == EEXIST || errno == EINTR {
                continue
            }
            throw posixError("The persistence lock could not be created")
        }
    }

    private static func requiredEntryStatus(
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
        guard status.st_mode & S_IFMT != S_IFLNK else {
            throw SecurePersistenceError("A symlinked \(label) is not allowed")
        }
        return status
    }

    private static func fileStatus(descriptor: Int32, label: String) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw posixError("The \(label) descriptor could not be inspected")
        }
        return status
    }

    static func validateRegularOwnedFile(_ status: stat, label: String) throws {
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw SecurePersistenceError("The \(label) is not a regular file")
        }
        guard status.st_uid == geteuid() else {
            throw SecurePersistenceError("The \(label) is not owned by the current user")
        }
        guard status.st_nlink == 1 else {
            throw SecurePersistenceError("The \(label) has an unexpected link count")
        }
    }

    private static func validateRegularOwnerPrivateFile(_ status: stat, label: String) throws {
        try validateRegularOwnedFile(status, label: label)
        guard status.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw SecurePersistenceError("The \(label) is not owner-private")
        }
    }

    private static func requireSameFile(_ lhs: stat, _ rhs: stat, label: String) throws {
        guard lhs.st_dev == rhs.st_dev, lhs.st_ino == rhs.st_ino else {
            throw SecurePersistenceError("The \(label) changed while it was being validated")
        }
    }

    private static func posixError(_ message: String) -> SecurePersistenceError {
        let code = errno
        return SecurePersistenceError("\(message) (errno \(code): \(String(cString: strerror(code))))")
    }
}
