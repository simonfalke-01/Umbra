import Darwin
import Foundation

public struct ApplicationBuildInfo: Codable, Hashable, Sendable {
    public var name: String
    public var version: String
    public var build: String

    public init(name: String, version: String, build: String) {
        self.name = name
        self.version = version
        self.build = build
    }

    public static func current(bundle: Bundle = .main) -> Self {
        Self(
            name: (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Umbra",
            version: (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown",
            build: (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        )
    }
}

public struct OperatingSystemSnapshot: Codable, Hashable, Sendable {
    public var name: String
    public var version: String
    public var kernelVersion: String
    public var architecture: UpdateArchitecture

    public init(
        name: String,
        version: String,
        kernelVersion: String,
        architecture: UpdateArchitecture
    ) {
        self.name = name
        self.version = version
        self.kernelVersion = kernelVersion
        self.architecture = architecture
    }

    public static func current(processInfo: ProcessInfo = .processInfo) -> Self {
        let version = processInfo.operatingSystemVersion
        return Self(
            name: "macOS",
            version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            kernelVersion: kernelRelease(),
            architecture: .current
        )
    }

    private static func kernelRelease() -> String {
        var system = utsname()
        guard uname(&system) == 0 else { return "unknown" }
        return withUnsafePointer(to: &system.release) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

public struct DiagnosticsSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var createdAt: Date
    public var application: ApplicationBuildInfo
    public var operatingSystem: OperatingSystemSnapshot
    public var decoderCapabilities: DecoderCapabilityInventory
    public var displayCapabilities: DisplayCapabilityInventory
    public var supportLogs: [SupportLogDescriptor]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        createdAt: Date,
        application: ApplicationBuildInfo,
        operatingSystem: OperatingSystemSnapshot,
        decoderCapabilities: DecoderCapabilityInventory,
        displayCapabilities: DisplayCapabilityInventory,
        supportLogs: [SupportLogDescriptor] = []
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.application = application
        self.operatingSystem = operatingSystem
        self.decoderCapabilities = decoderCapabilities
        self.displayCapabilities = displayCapabilities
        self.supportLogs = supportLogs
    }

    /// Captures only support-relevant capability data. Usernames, hostnames, serial numbers,
    /// network addresses, and persistent display identifiers are intentionally absent.
    @MainActor
    public static func capture(
        application: ApplicationBuildInfo = .current(),
        logger: SupportLog? = nil,
        now: @Sendable () -> Date = Date.init
    ) -> Self {
        Self(
            createdAt: now(),
            application: application,
            operatingSystem: .current(),
            decoderCapabilities: .probe(),
            displayCapabilities: .probe(),
            supportLogs: logger?.descriptors() ?? []
        )
    }
}

public struct DiagnosticsExporter: Sendable {
    public init() {}

    public func encodedSnapshot(_ snapshot: DiagnosticsSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    /// Writes a deterministic JSON snapshot. The exported payload contains no local file paths.
    @discardableResult
    public func export(_ snapshot: DiagnosticsSnapshot, to destinationURL: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encodedSnapshot(snapshot).write(to: destinationURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
        return destinationURL
    }
}

public extension UpdateRuntimeIdentity {
    static func current(applicationVersion: DottedVersion) -> Self {
        let system = OperatingSystemSnapshot.current()
        return Self(
            platform: .macOS,
            architecture: system.architecture,
            applicationVersion: applicationVersion,
            kernelVersion: DottedVersion(parsing: system.kernelVersion)
                ?? DottedVersion(components: [0])
        )
    }
}
