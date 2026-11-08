import Darwin
import Foundation
import SystemConfiguration

/// Local interface carrying the LSP media socket to one host address.
///
/// Interfaces that reach the host directly (its IPv4 or IPv6 subnet, or the link-local scope
/// it answered on) are ranked wired, then Wi-Fi, then everything else. The socket is pinned to
/// the best of them only when it outranks the interface the OS would route through; otherwise
/// the OS route is used unchanged, so a ranking mistake can cost a retry but never a connection.
public struct LSPNetworkPath: Equatable, Sendable {
    /// Interface classes, best first.
    public enum Kind: Int, Comparable, Sendable {
        /// Ethernet, USB or Thunderbolt Ethernet, and Thunderbolt Bridge.
        case wired
        case wifi
        case other
        /// Tunnels; never pinned, so a VPN is only used when it is the OS route.
        case vpn

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .wired: "wired"
            case .wifi: "Wi-Fi"
            case .other: "other"
            case .vpn: "VPN"
            }
        }
    }

    public var interfaceName: String
    public var interfaceIndex: UInt32
    public var kind: Kind
    /// Whether the socket is pinned to this interface instead of following the OS route.
    public var bound: Bool

    /// Interface index for `LSPTransportEndpoint`, zero when the OS route is used.
    public var boundInterfaceIndex: UInt16 {
        bound ? UInt16(clamping: interfaceIndex) : 0
    }

    /// Paths to try for `address`, in order: the pinned better-ranked interface when one beats
    /// the OS route, then the OS route itself. Empty when nothing local can be determined.
    public static func attempts(to address: String) -> [LSPNetworkPath] {
        let interfaces = LocalInterface.snapshot()
        guard let target = Target(resolving: address) else { return [] }
        let reaching = interfaces.filter { $0.reaches(target) }
        let routed = osRouteInterfaceName(to: target).flatMap { name in
            interfaces.first { $0.name == name }
        }
        var attempts: [LSPNetworkPath] = []
        if let best = reaching.min(by: { $0.kind < $1.kind }),
           best.kind <= .wifi,
           best.name != routed?.name,
           routed.map({ best.kind < $0.kind }) ?? true {
            attempts.append(best.path(bound: true))
        }
        if let routed {
            attempts.append(routed.path(bound: false))
        } else if attempts.isEmpty, let best = reaching.min(by: { $0.kind < $1.kind }) {
            attempts.append(best.path(bound: false))
        }
        return attempts
    }

    /// Stable-sorts numeric addresses by the best interface class that reaches them directly;
    /// addresses nothing reaches directly (routed, NAT loopback, names) keep their order last.
    public static func ranked(_ endpoints: [LSPHostEndpoint]) -> [LSPHostEndpoint] {
        let interfaces = LocalInterface.snapshot()
        func rank(_ endpoint: LSPHostEndpoint) -> Int {
            guard let target = Target(numeric: endpoint.address) else { return Int.max }
            return interfaces.filter { $0.reaches(target) }.map(\.kind.rawValue).min() ?? Int.max
        }
        return endpoints.enumerated()
            .map { (rank: rank($0.element), offset: $0.offset, endpoint: $0.element) }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.endpoint)
    }

    /// Whether `name` is still an up, running interface with an address.
    public static func interfaceIsAvailable(_ name: String) -> Bool {
        LocalInterface.snapshot().contains { $0.name == name }
    }

    /// Interface the kernel would route `target` through, read from a connected UDP socket's
    /// source address. UDP connect only selects a route; it sends nothing.
    private static func osRouteInterfaceName(to target: Target) -> String? {
        let descriptor = socket(target.family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var remote = target.socketAddress(port: 9)
        let remoteLength = socklen_t(remote.ss_len)
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, remoteLength)
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0, let source = Target(socketAddress: local) else { return nil }
        return LocalInterface.snapshot().first { $0.owns(source) }?.name
    }
}

/// Numeric IPv4 or scoped IPv6 address.
private enum Target {
    case ipv4(in_addr_t)
    case ipv6(in6_addr, scope: UInt32)

    var family: Int32 {
        switch self {
        case .ipv4: AF_INET
        case .ipv6: AF_INET6
        }
    }

    init?(numeric address: String) {
        let parts = address.split(separator: "%", maxSplits: 1).map(String.init)
        guard let literal = parts.first else { return nil }
        var ipv4 = in_addr()
        if parts.count == 1, inet_pton(AF_INET, literal, &ipv4) == 1 {
            self = .ipv4(ipv4.s_addr)
            return
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, literal, &ipv6) == 1 else { return nil }
        let scope = parts.count == 2 ? (UInt32(parts[1]) ?? if_nametoindex(parts[1])) : 0
        self = .ipv6(ipv6, scope: scope)
    }

    /// Numeric literal, or the first address a name resolves to (the order the core tries).
    init?(resolving address: String) {
        if let numeric = Target(numeric: address) {
            self = numeric
            return
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &results) == 0, let first = results else { return nil }
        defer { freeaddrinfo(results) }
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { destination in
            destination.copyBytes(from: UnsafeRawBufferPointer(
                start: first.pointee.ai_addr,
                count: min(Int(first.pointee.ai_addrlen), MemoryLayout<sockaddr_storage>.size)
            ))
        }
        guard let resolved = Target(socketAddress: storage) else { return nil }
        self = resolved
    }

    init?(socketAddress storage: sockaddr_storage) {
        var storage = storage
        switch Int32(storage.ss_family) {
        case AF_INET:
            let address = withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in.self) }
            self = .ipv4(address.sin_addr.s_addr)
        case AF_INET6:
            let address = withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in6.self) }
            self = .ipv6(address.sin6_addr, scope: address.sin6_scope_id)
        default:
            return nil
        }
    }

    var isLinkLocal: Bool {
        guard case let .ipv6(address, _) = self else { return false }
        return address.__u6_addr.__u6_addr8.0 == 0xFE && address.__u6_addr.__u6_addr8.1 & 0xC0 == 0x80
    }

    func socketAddress(port: UInt16) -> sockaddr_storage {
        var storage = sockaddr_storage()
        switch self {
        case let .ipv4(address):
            var ipv4 = sockaddr_in()
            ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            ipv4.sin_family = sa_family_t(AF_INET)
            ipv4.sin_port = port.bigEndian
            ipv4.sin_addr.s_addr = address
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: ipv4, as: sockaddr_in.self) }
        case let .ipv6(address, scope):
            var ipv6 = sockaddr_in6()
            ipv6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            ipv6.sin6_family = sa_family_t(AF_INET6)
            ipv6.sin6_port = port.bigEndian
            ipv6.sin6_addr = address
            ipv6.sin6_scope_id = scope
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: ipv6, as: sockaddr_in6.self) }
        }
        return storage
    }
}

/// One up, running, non-loopback interface and the subnets it is attached to.
private struct LocalInterface {
    struct Subnet {
        var address: Target
        var mask: Target
    }

    var name: String
    var index: UInt32
    var kind: LSPNetworkPath.Kind
    var subnets: [Subnet]

    func path(bound: Bool) -> LSPNetworkPath {
        LSPNetworkPath(interfaceName: name, interfaceIndex: index, kind: kind, bound: bound)
    }

    /// The host is on one of this interface's subnets, or in its link-local scope.
    func reaches(_ target: Target) -> Bool {
        if target.isLinkLocal {
            guard case let .ipv6(_, scope) = target else { return false }
            return scope == index
        }
        return subnets.contains { subnet in
            switch (target, subnet.address, subnet.mask) {
            case let (.ipv4(host), .ipv4(local), .ipv4(mask)):
                return mask != 0 && host & mask == local & mask
            case let (.ipv6(host, _), .ipv6(local, _), .ipv6(mask, _)):
                guard !subnet.address.isLinkLocal else { return false }
                return withUnsafeBytes(of: host) { hostBytes in
                    withUnsafeBytes(of: local) { localBytes in
                        withUnsafeBytes(of: mask) { maskBytes in
                            maskBytes.contains { $0 != 0 }
                                && (0..<16).allSatisfy { hostBytes[$0] & maskBytes[$0] == localBytes[$0] & maskBytes[$0] }
                        }
                    }
                }
            default:
                return false
            }
        }
    }

    func owns(_ source: Target) -> Bool {
        if source.isLinkLocal {
            guard case let .ipv6(_, scope) = source else { return false }
            return scope == index
        }
        return subnets.contains { subnet in
            switch (source, subnet.address) {
            case let (.ipv4(lhs), .ipv4(rhs)): lhs == rhs
            case let (.ipv6(lhs, _), .ipv6(rhs, _)):
                withUnsafeBytes(of: lhs) { a in withUnsafeBytes(of: rhs) { b in a.elementsEqual(b) } }
            default: false
            }
        }
    }

    static func snapshot() -> [LocalInterface] {
        let types = systemConfigurationTypes()
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var result: [LocalInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, let netmask = entry.pointee.ifa_netmask,
                  let local = target(address, family: Int32(address.pointee.sa_family)),
                  let mask = target(netmask, family: Int32(address.pointee.sa_family)) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let subnet = Subnet(address: local, mask: mask)
            if let index = result.firstIndex(where: { $0.name == name }) {
                result[index].subnets.append(subnet)
            } else {
                result.append(LocalInterface(
                    name: name,
                    index: if_nametoindex(name),
                    kind: classify(name, systemConfigurationType: types[name]),
                    subnets: [subnet]
                ))
            }
        }
        return result
    }

    /// Netmasks may carry no family of their own, so the interface address supplies it.
    private static func target(_ address: UnsafeMutablePointer<sockaddr>, family: Int32) -> Target? {
        guard family == AF_INET || family == AF_INET6 else { return nil }
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { destination in
            destination.copyBytes(from: UnsafeRawBufferPointer(
                start: address,
                count: min(
                    Int(address.pointee.sa_len),
                    family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
                )
            ))
        }
        storage.ss_family = sa_family_t(family)
        return Target(socketAddress: storage)
    }

    /// Tunnels and Apple peer-to-peer links are excluded by name before the SystemConfiguration
    /// type is consulted; only bridges SystemConfiguration lists (Thunderbolt Bridge) are wired.
    private static func classify(_ name: String, systemConfigurationType: String?) -> LSPNetworkPath.Kind {
        if ["utun", "ipsec", "ppp", "tun", "tap"].contains(where: name.hasPrefix) { return .vpn }
        if ["awdl", "llw", "ap", "anpi", "gif", "stf", "nan", "pktap"].contains(where: name.hasPrefix) {
            return .other
        }
        switch systemConfigurationType {
        case String(kSCNetworkInterfaceTypeEthernet), "Bridge": return .wired
        case String(kSCNetworkInterfaceTypeIEEE80211): return .wifi
        default: return .other
        }
    }

    private static func systemConfigurationTypes() -> [String: String] {
        let all = SCNetworkInterfaceCopyAll()
        var types: [String: String] = [:]
        for index in 0..<CFArrayGetCount(all) {
            let interface = unsafeBitCast(CFArrayGetValueAtIndex(all, index), to: SCNetworkInterface.self)
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            types[name] = type
        }
        return types
    }
}
