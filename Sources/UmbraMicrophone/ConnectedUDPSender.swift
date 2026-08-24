import Darwin
import Foundation

/// Pre-binds the same UDP client port in both address families, then connects
/// only the socket matching MoonlightCommon's selected numeric RTSP peer.
public final class ConnectedMicrophoneUDPSender: MicrophoneDatagramSending, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptorsByFamily: [Int32: Int32]
    private var activeDescriptor: Int32 = -1
    public let localPort: UInt16

    public convenience init(host _: String) throws {
        try self.init()
    }

    public init() throws {
        var descriptors: [Int32: Int32] = [:]
        var selectedPort: UInt16?

        if let ipv6 = try? Self.makeBoundSocket(family: AF_INET6, port: 0) {
            descriptors[AF_INET6] = ipv6.descriptor
            selectedPort = ipv6.port
        }
        if let port = selectedPort {
            if let ipv4 = try? Self.makeBoundSocket(family: AF_INET, port: port) {
                descriptors[AF_INET] = ipv4.descriptor
            }
        } else if let ipv4 = try? Self.makeBoundSocket(family: AF_INET, port: 0) {
            descriptors[AF_INET] = ipv4.descriptor
            selectedPort = ipv4.port
            if let ipv6 = try? Self.makeBoundSocket(family: AF_INET6, port: ipv4.port) {
                descriptors[AF_INET6] = ipv6.descriptor
            }
        }

        guard let selectedPort, !descriptors.isEmpty else {
            throw ClientMicrophonePreparationError.socketBindingFailed(errno)
        }
        guard selectedPort > 0, selectedPort < UInt16.max else {
            descriptors.values.forEach { Darwin.close($0) }
            throw ClientMicrophonePreparationError.invalidClientPort
        }
        descriptorsByFamily = descriptors
        localPort = selectedPort
    }

    deinit { close() }

    public func connect(remoteAddress: String, serverPort: UInt16) throws {
        try lock.withLock {
            guard activeDescriptor < 0 else { return }
            let resolved = try Self.numericAddress(remoteAddress, port: serverPort)
            var descriptor = descriptorsByFamily[resolved.family]
            if descriptor == nil {
                let rebound = try Self.makeBoundSocket(family: resolved.family, port: localPort)
                descriptor = rebound.descriptor
                descriptorsByFamily[resolved.family] = rebound.descriptor
            }
            guard let descriptor else {
                throw ClientMicrophonePreparationError.socketCreationFailed(EAFNOSUPPORT)
            }
            let result = resolved.storage.withUnsafeBytes { bytes in
                Darwin.connect(
                    descriptor,
                    bytes.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                    resolved.length
                )
            }
            guard result == 0 else {
                throw ClientMicrophonePreparationError.socketConnectionFailed(errno)
            }
            activeDescriptor = descriptor
            let unusedFamilies = descriptorsByFamily.keys.filter { $0 != resolved.family }
            for family in unusedFamilies {
                if let unusedDescriptor = descriptorsByFamily.removeValue(forKey: family) {
                    Darwin.close(unusedDescriptor)
                }
            }
        }
    }

    public func send(_ datagram: LMC1Datagram) throws {
        try lock.withLock {
            guard activeDescriptor >= 0 else {
                throw ClientMicrophonePreparationError.socketConnectionFailed(ENOTCONN)
            }
            let sent = datagram.bytes.withUnsafeBytes { bytes in
                Darwin.send(activeDescriptor, bytes.baseAddress, bytes.count, 0)
            }
            guard sent == datagram.bytes.count else {
                throw ClientMicrophonePreparationError.socketConnectionFailed(errno)
            }
        }
    }

    public func close() {
        let descriptors = lock.withLock { () -> Set<Int32> in
            let values = Set(descriptorsByFamily.values).union(
                activeDescriptor >= 0 ? [activeDescriptor] : []
            )
            descriptorsByFamily.removeAll()
            activeDescriptor = -1
            return values
        }
        descriptors.forEach { Darwin.close($0) }
    }

    var preparedAddressFamiliesForTesting: Set<Int32> {
        lock.withLock { Set(descriptorsByFamily.keys) }
    }

    private static func makeBoundSocket(
        family: Int32,
        port: UInt16
    ) throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw ClientMicrophonePreparationError.socketCreationFailed(errno)
        }
        do {
            if family == AF_INET6 {
                var ipv6Only: Int32 = 1
                guard setsockopt(
                    descriptor,
                    IPPROTO_IPV6,
                    IPV6_V6ONLY,
                    &ipv6Only,
                    socklen_t(MemoryLayout<Int32>.size)
                ) == 0 else {
                    throw ClientMicrophonePreparationError.socketBindingFailed(errno)
                }
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = port.bigEndian
                address.sin6_addr = in6addr_any
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
                guard result == 0 else {
                    throw ClientMicrophonePreparationError.socketBindingFailed(errno)
                }
            } else if family == AF_INET {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr = in_addr(s_addr: INADDR_ANY)
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard result == 0 else {
                    throw ClientMicrophonePreparationError.socketBindingFailed(errno)
                }
            } else {
                throw ClientMicrophonePreparationError.socketCreationFailed(EAFNOSUPPORT)
            }
            return (descriptor, try boundPort(descriptor: descriptor, family: family))
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func boundPort(descriptor: Int32, family: Int32) throws -> UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else {
            throw ClientMicrophonePreparationError.socketNameQueryFailed(errno)
        }
        if family == AF_INET6 {
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin6_port)
                }
            }
        }
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt16(bigEndian: $0.pointee.sin_port)
            }
        }
    }

    private struct ResolvedNumericAddress {
        let family: Int32
        let storage: Data
        let length: socklen_t
    }

    private static func numericAddress(
        _ address: String,
        port: UInt16
    ) throws -> ResolvedNumericAddress {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST | AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = String(port).withCString { service in
            getaddrinfo(address, service, &hints, &result)
        }
        guard status == 0, let result else {
            throw ClientMicrophonePreparationError.noUsableHostAddress
        }
        defer { freeaddrinfo(result) }
        guard result.pointee.ai_family == AF_INET || result.pointee.ai_family == AF_INET6 else {
            throw ClientMicrophonePreparationError.noUsableHostAddress
        }
        return ResolvedNumericAddress(
            family: result.pointee.ai_family,
            storage: Data(bytes: result.pointee.ai_addr, count: Int(result.pointee.ai_addrlen)),
            length: result.pointee.ai_addrlen
        )
    }
}
