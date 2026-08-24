import Foundation

public struct NVIDIAServerCompatibilityPolicy: Equatable, Sendable {
    public static let bundledMaximumVersion = "99.99.99.99"

    private let maximumSupportedVersion: DottedVersion

    public init?(maximumSupportedVersion: String = Self.bundledMaximumVersion) {
        guard let parsed = DottedVersion(maximumSupportedVersion) else { return nil }
        self.maximumSupportedVersion = parsed
    }

    public func isSupported(isNVIDIAServerSoftware: Bool, gfeVersion: String?) -> Bool {
        guard isNVIDIAServerSoftware else { return true }
        guard let gfeVersion, let parsed = DottedVersion(gfeVersion) else { return true }
        return parsed <= maximumSupportedVersion
    }
}

private struct DottedVersion: Comparable, Equatable, Sendable {
    let components: [Int]

    init?(_ value: String) {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return nil }
        var components: [Int] = []
        components.reserveCapacity(4)
        for part in parts {
            guard let component = Int(part), component >= 0 else { return nil }
            components.append(component)
        }
        while components.count < 4 { components.append(0) }
        self.components = components
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
