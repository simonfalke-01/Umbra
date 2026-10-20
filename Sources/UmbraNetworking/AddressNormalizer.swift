import Foundation
import Network

public struct AddressNormalizer: Sendable {
    public init() {}

    public func normalize(_ input: String, defaultPort: UInt16 = HostAddress.defaultHTTPPort) throws -> HostAddress {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw UmbraNetworkingError.invalidAddress(input) }

        if value.contains("://") {
            return try parseURL(value, defaultPort: defaultPort)
        }

        if value.first == "[" {
            return try parseURL("gamestream://\(value)", defaultPort: defaultPort)
        }

        // An unescaped IPv6 literal is always interpreted as a host without a port. IPv6 with a
        // port must use standard bracket syntax so the final component is never ambiguous.
        if value.filter({ $0 == ":" }).count > 1 {
            let unscoped = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
            guard IPv6Address(unscoped) != nil else {
                throw UmbraNetworkingError.invalidAddress(input)
            }
            return HostAddress(host: value, port: defaultPort)
        }

        if let separator = value.lastIndex(of: ":") {
            let host = String(value[..<separator])
            let portText = String(value[value.index(after: separator)...])
            guard !host.isEmpty else { throw UmbraNetworkingError.invalidAddress(input) }
            return HostAddress(host: host, port: try parsePort(portText))
        }

        guard isPlausibleHostname(value) else {
            throw UmbraNetworkingError.invalidAddress(input)
        }
        return HostAddress(host: value, port: defaultPort)
    }

    private func parseURL(_ value: String, defaultPort: UInt16) throws -> HostAddress {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["gamestream", "http", "https"].contains(scheme),
              let parsedHost = components.host,
              !parsedHost.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw UmbraNetworkingError.invalidAddress(value)
        }
        let host = parsedHost.hasPrefix("[") && parsedHost.hasSuffix("]")
            ? String(parsedHost.dropFirst().dropLast())
            : parsedHost
        if let port = components.port {
            guard let valid = UInt16(exactly: port), valid != 0 else {
                throw UmbraNetworkingError.invalidPort(String(port))
            }
            return HostAddress(host: host, port: valid)
        }
        return HostAddress(host: host, port: defaultPort)
    }

    private func parsePort(_ value: String) throws -> UInt16 {
        guard let port = UInt16(value), port != 0 else {
            throw UmbraNetworkingError.invalidPort(value)
        }
        return port
    }

    private func isPlausibleHostname(_ value: String) -> Bool {
        !value.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "?" || $0 == "#" })
    }
}
