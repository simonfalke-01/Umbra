import Foundation

public struct DottedVersion: Codable, Hashable, Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    public init?(parsing value: String) {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              pieces.allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        components = Self.normalized(pieces.compactMap { Int($0) })
    }

    public init(components: [Int]) {
        precondition(!components.isEmpty && components.allSatisfy { $0 >= 0 })
        self.components = Self.normalized(components)
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: DottedVersion, rhs: DottedVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let parsed = Self(parsing: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a dot-separated numeric version"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func normalized(_ components: [Int]) -> [Int] {
        var result = components
        while result.count > 1, result.last == 0 {
            result.removeLast()
        }
        return result
    }
}

public enum UpdatePlatform: Codable, Hashable, Sendable {
    case macOS
    case other(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = value == "osx" ? .macOS : .other(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .macOS: try container.encode("osx")
        case let .other(value): try container.encode(value)
        }
    }
}

public enum UpdateArchitecture: Codable, Hashable, Sendable {
    case arm64
    case x86_64
    case other(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "arm64": self = .arm64
        case "x86_64": self = .x86_64
        case let value: self = .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .arm64: try container.encode("arm64")
        case .x86_64: try container.encode("x86_64")
        case let .other(value): try container.encode(value)
        }
    }

    public static var current: Self {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        #error("UmbraDiagnostics supports macOS arm64 and x86_64 builds only")
        #endif
    }
}

public struct UpdateRuntimeIdentity: Codable, Hashable, Sendable {
    public var platform: UpdatePlatform
    public var architecture: UpdateArchitecture
    public var applicationVersion: DottedVersion
    public var kernelVersion: DottedVersion

    public init(
        platform: UpdatePlatform,
        architecture: UpdateArchitecture,
        applicationVersion: DottedVersion,
        kernelVersion: DottedVersion
    ) {
        self.platform = platform
        self.architecture = architecture
        self.applicationVersion = applicationVersion
        self.kernelVersion = kernelVersion
    }
}

public struct UpdateManifestEntry: Codable, Hashable, Sendable {
    public var platform: UpdatePlatform
    public var architecture: UpdateArchitecture
    public var version: DottedVersion
    public var browserURL: URL
    public var minimumKernelVersion: DottedVersion?

    enum CodingKeys: String, CodingKey {
        case platform
        case architecture = "arch"
        case version
        case browserURL = "browser_url"
        case minimumKernelVersion = "kernel_version_at_least"
    }

    public init(
        platform: UpdatePlatform,
        architecture: UpdateArchitecture,
        version: DottedVersion,
        browserURL: URL,
        minimumKernelVersion: DottedVersion? = nil
    ) {
        self.platform = platform
        self.architecture = architecture
        self.version = version
        self.browserURL = browserURL
        self.minimumKernelVersion = minimumKernelVersion
    }
}

public struct UpdateCheckerConfiguration: Codable, Hashable, Sendable {
    public static let noPublishedChannel = Self(
        manifestURL: nil,
        disabledReason: "Umbra does not publish an update manifest yet."
    )

    public var manifestURL: URL?
    public var disabledReason: String?

    public init(manifestURL: URL, disabledReason: String? = nil) {
        self.manifestURL = manifestURL
        self.disabledReason = disabledReason
    }

    public init(manifestURL: URL?, disabledReason: String?) {
        self.manifestURL = manifestURL
        self.disabledReason = disabledReason
    }
}

public struct UpdateNotification: Codable, Hashable, Sendable {
    public var version: DottedVersion
    public var browserURL: URL

    public init(version: DottedVersion, browserURL: URL) {
        self.version = version
        self.browserURL = browserURL
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case disabled(reason: String)
    case noCompatibleEntry
    case upToDate(latestVersion: DottedVersion)
    case updateAvailable(UpdateNotification)
}

public enum UpdateManifestError: Error, Equatable {
    case insecureManifestURL(URL)
    case unsuccessfulHTTPStatus(Int)
    case insecureBrowserURL(URL)
}

/// Notification-only update checker. It returns a browser URL and never downloads or installs code.
public struct UpdateManifestChecker: Sendable {
    public var configuration: UpdateCheckerConfiguration
    public var runtime: UpdateRuntimeIdentity

    public init(
        configuration: UpdateCheckerConfiguration = .noPublishedChannel,
        runtime: UpdateRuntimeIdentity
    ) {
        self.configuration = configuration
        self.runtime = runtime
    }

    public func check() async throws -> UpdateCheckResult {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }

        return try await check { url in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            if let responseURL = response.url,
               responseURL.scheme?.lowercased() != "https" {
                throw UpdateManifestError.insecureManifestURL(responseURL)
            }
            if let response = response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw UpdateManifestError.unsuccessfulHTTPStatus(response.statusCode)
            }
            return data
        }
    }

    public func check(
        loading: @Sendable (URL) async throws -> Data
    ) async throws -> UpdateCheckResult {
        guard let manifestURL = configuration.manifestURL else {
            return .disabled(
                reason: configuration.disabledReason
                    ?? "Update checks are disabled because no manifest URL is configured."
            )
        }
        guard manifestURL.scheme?.lowercased() == "https" else {
            throw UpdateManifestError.insecureManifestURL(manifestURL)
        }
        let manifestData = try await loading(manifestURL)
        return try evaluate(manifestData: manifestData)
    }

    public func evaluate(manifestData: Data) throws -> UpdateCheckResult {
        let entries = try JSONDecoder().decode(LossyUpdateManifest.self, from: manifestData).entries
        let compatibleEntries = entries.filter { entry in
            guard entry.platform == runtime.platform,
                  entry.architecture == runtime.architecture else {
                return false
            }
            return entry.minimumKernelVersion.map { runtime.kernelVersion >= $0 } ?? true
        }

        guard let latest = compatibleEntries.max(by: { $0.version < $1.version }) else {
            return .noCompatibleEntry
        }
        guard latest.browserURL.scheme?.lowercased() == "https" else {
            throw UpdateManifestError.insecureBrowserURL(latest.browserURL)
        }
        guard runtime.applicationVersion < latest.version else {
            return .upToDate(latestVersion: latest.version)
        }
        return .updateAvailable(
            UpdateNotification(version: latest.version, browserURL: latest.browserURL)
        )
    }
}

private struct LossyUpdateManifest: Decodable {
    var entries: [UpdateManifestEntry]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var entries: [UpdateManifestEntry] = []
        while !container.isAtEnd {
            let entryDecoder = try container.superDecoder()
            if let entry = try? UpdateManifestEntry(from: entryDecoder) {
                entries.append(entry)
            }
        }
        self.entries = entries
    }
}
