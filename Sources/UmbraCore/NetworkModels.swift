import Foundation

public struct ModelValidationError: Error, Equatable, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    public let field: String
    public let reason: String

    public init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }

    public var description: String { "\(field): \(reason)" }
    public var errorDescription: String? { description }
}

public struct NetworkEndpoint: Codable, Hashable, Sendable {
    public static let defaultHTTPPort: UInt16 = 47_989
    public static let defaultHTTPSPort: UInt16 = 47_984

    public var hostname: String
    public var port: UInt16

    public init(hostname: String, port: UInt16 = NetworkEndpoint.defaultHTTPPort) {
        self.hostname = hostname
        self.port = port
    }

    public var displayName: String {
        hostname.contains(":") ? "[\(hostname)]:\(port)" : "\(hostname):\(port)"
    }

    public func validate() throws {
        guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError(field: "hostname", reason: "must not be empty")
        }
        guard port != 0 else {
            throw ModelValidationError(field: "port", reason: "must be between 1 and 65535")
        }
    }
}

public struct DisplayMode: Codable, Hashable, Sendable, Comparable {
    public var width: Int
    public var height: Int
    public var refreshRate: Int

    public init(width: Int, height: Int, refreshRate: Int) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
    }

    public static func < (lhs: DisplayMode, rhs: DisplayMode) -> Bool {
        let lhsScore = Int64(lhs.width) * Int64(lhs.height) * Int64(lhs.refreshRate)
        let rhsScore = Int64(rhs.width) * Int64(rhs.height) * Int64(rhs.refreshRate)
        return lhsScore < rhsScore
    }

    public func validate() throws {
        guard (256...8_192).contains(width) else {
            throw ModelValidationError(field: "displayMode.width", reason: "must be between 256 and 8192")
        }
        guard (256...8_192).contains(height) else {
            throw ModelValidationError(field: "displayMode.height", reason: "must be between 256 and 8192")
        }
        guard (1...9_999).contains(refreshRate) else {
            throw ModelValidationError(field: "displayMode.refreshRate", reason: "must be between 1 and 9999")
        }
    }
}
