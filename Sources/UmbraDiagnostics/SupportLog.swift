import Foundation

public enum SupportLogLevel: String, Codable, CaseIterable, Sendable {
    case verbose
    case debug
    case info
    case warning
    case error
    case critical
}

public struct SupportLogConfiguration: Sendable, Equatable {
    public static let defaultMaximumFileSize = 10 * 1024 * 1024
    public static let defaultRetainedFileCount = 10

    public var directoryURL: URL
    public var filePrefix: String
    public var maximumFileSize: Int
    public var retainedFileCount: Int

    public init(
        directoryURL: URL,
        filePrefix: String = "Umbra",
        maximumFileSize: Int = Self.defaultMaximumFileSize,
        retainedFileCount: Int = Self.defaultRetainedFileCount
    ) {
        self.directoryURL = directoryURL
        self.filePrefix = filePrefix
        self.maximumFileSize = maximumFileSize
        self.retainedFileCount = retainedFileCount
    }
}

public enum SupportLogError: Error, Equatable {
    case invalidConfiguration
    case couldNotCreateLogFile(URL)
}

public struct SupportLogDescriptor: Codable, Hashable, Sendable {
    public var fileName: String
    public var byteCount: Int

    public init(fileName: String, byteCount: Int) {
        self.fileName = fileName
        self.byteCount = byteCount
    }
}

/// A process-wide support log suitable for messages originating in Swift or C callbacks.
///
/// Writes are serialized, secret query parameters are redacted before they reach disk, and
/// a single launch can never write more than `maximumFileSize` bytes. A new file is created
/// for each instance and old launch logs are pruned to `retainedFileCount`.
public final class SupportLog: @unchecked Sendable {
    private let configuration: SupportLogConfiguration
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private let timestamp: @Sendable () -> Date
    private var bytesWritten = 0
    private var didWriteLimitMarker = false
    private var lastWriteFailureStorage: String?

    public let fileURL: URL

    public init(
        configuration: SupportLogConfiguration,
        now: @escaping @Sendable () -> Date = Date.init,
        identifier: String = UUID().uuidString
    ) throws {
        guard configuration.maximumFileSize > 0,
              configuration.retainedFileCount > 0,
              !configuration.filePrefix.isEmpty else {
            throw SupportLogError.invalidConfiguration
        }

        self.configuration = configuration
        self.timestamp = now

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: configuration.directoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: configuration.directoryURL.path
        )

        let milliseconds = Int64(now().timeIntervalSince1970 * 1_000)
        let fileName = "\(configuration.filePrefix)-\(milliseconds)-\(identifier).log"
        let fileURL = configuration.directoryURL.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.createFile(atPath: fileURL.path, contents: nil),
              let fileHandle = try? FileHandle(forWritingTo: fileURL) else {
            throw SupportLogError.couldNotCreateLogFile(fileURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        self.fileURL = fileURL.resolvingSymlinksInPath()
        self.fileHandle = fileHandle

        try pruneOldLogs()
    }

    deinit {
        try? fileHandle.close()
    }

    public var lastWriteFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastWriteFailureStorage
    }

    public func record(
        source: String,
        level: SupportLogLevel,
        message: String
    ) {
        let cleanSource = Self.redact(source)
        let cleanMessage = Self.redact(message)
        let date = ISO8601DateFormatter().string(from: timestamp())
        let line = "\(date) [\(level.rawValue.uppercased())] [\(cleanSource)] \(cleanMessage)\n"
        append(Data(line.utf8))
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileHandle.synchronize()
        } catch {
            lastWriteFailureStorage = String(describing: error)
        }
    }

    public func availableLogFiles() -> [URL] {
        flush()
        return Self.logFiles(for: configuration)
    }

    public func descriptors() -> [SupportLogDescriptor] {
        availableLogFiles().compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else {
                return nil
            }
            return SupportLogDescriptor(fileName: url.lastPathComponent, byteCount: size)
        }
    }

    public static func redact(_ message: String) -> String {
        message.replacingOccurrences(
            of: #"(?i)([?&]?\b(?:rikey|rikeyid)\s*=\s*)[^&\s]+"#,
            with: "$1REDACTED",
            options: .regularExpression
        )
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        guard bytesWritten < configuration.maximumFileSize else { return }
        let remaining = configuration.maximumFileSize - bytesWritten
        let output: Data
        if data.count <= remaining {
            output = data
        } else if !didWriteLimitMarker {
            didWriteLimitMarker = true
            let marker = Data("Log size limit reached!\n".utf8)
            output = marker.prefix(remaining)
        } else {
            return
        }

        do {
            try fileHandle.write(contentsOf: output)
            bytesWritten += output.count
        } catch {
            lastWriteFailureStorage = String(describing: error)
        }
    }

    private func pruneOldLogs() throws {
        let currentPath = fileURL.resolvingSymlinksInPath().path
        let oldLogs = Self.logFiles(for: configuration).filter {
            $0.resolvingSymlinksInPath().path != currentPath
        }
        let oldLogsToKeep = configuration.retainedFileCount - 1
        guard oldLogs.count > oldLogsToKeep else { return }
        for url in oldLogs.dropFirst(oldLogsToKeep) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func logFiles(for configuration: SupportLogConfiguration) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: configuration.directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let prefix = "\(configuration.filePrefix)-"
        return urls.filter { url in
            guard url.lastPathComponent.hasPrefix(prefix), url.pathExtension == "log" else {
                return false
            }
            return (try? url.resourceValues(forKeys: keys).isRegularFile) == true
        }.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }
    }
}

/// Own this object for at least as long as native code can invoke its callback context.
public final class SupportLogCallbackContext: @unchecked Sendable {
    public let logger: SupportLog
    public var opaquePointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    public init(logger: SupportLog) {
        self.logger = logger
    }
}

public enum SupportLogCallbacks {
    public typealias NativeCallback = @convention(c) (
        UnsafeMutableRawPointer?,
        Int32,
        UnsafePointer<CChar>?
    ) -> Void

    /// C-compatible callback for native libraries that accept a context pointer, severity, and message.
    public static let native: NativeCallback = { context, severity, message in
        guard let context, let message else { return }
        let callbackContext = Unmanaged<SupportLogCallbackContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        callbackContext.logger.record(
            source: "Native",
            level: SupportLogLevel(nativeSeverity: severity),
            message: String(cString: message)
        )
    }

    public static func swift(
        logger: SupportLog,
        source: String
    ) -> @Sendable (SupportLogLevel, String) -> Void {
        { level, message in
            logger.record(source: source, level: level, message: message)
        }
    }
}

private extension SupportLogLevel {
    init(nativeSeverity: Int32) {
        switch nativeSeverity {
        case ...0: self = .verbose
        case 1: self = .debug
        case 2: self = .info
        case 3: self = .warning
        case 4: self = .error
        default: self = .critical
        }
    }
}
