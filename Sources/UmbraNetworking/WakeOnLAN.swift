import Foundation
import Network

public struct WakeOnLANTarget: Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public enum WakeOnLAN {
    public static let staticPorts: [UInt16] = [9, 47_009]
    public static let defaultDynamicPorts: [UInt16] = [47_998, 47_999, 48_000, 48_002, 48_010]
    private static let dynamicOffsets: [Int] = [9, 10, 11, 13, 21]

    public static func macAddressBytes(from macAddress: String) throws -> Data {
        let compact = macAddress
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard compact.count == 12, compact.allSatisfy(\.isHexDigit) else {
            throw UmbraNetworkingError.invalidMACAddress(macAddress)
        }

        var bytes = Data(capacity: 6)
        var index = compact.startIndex
        for _ in 0..<6 {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                throw UmbraNetworkingError.invalidMACAddress(macAddress)
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    public static func magicPacket(macAddress: String) throws -> Data {
        let mac = try macAddressBytes(from: macAddress)
        return try magicPacket(macAddress: mac)
    }

    public static func magicPacket(macAddress: Data) throws -> Data {
        guard macAddress.count == 6 else {
            throw UmbraNetworkingError.invalidMACAddress(
                macAddress.map { String(format: "%02x", $0) }.joined(separator: ":")
            )
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(macAddress) }
        return packet
    }

    public static func dynamicPorts(baseHTTPPort: UInt16) -> [UInt16] {
        dynamicOffsets.compactMap { offset in
            let value = Int(baseHTTPPort) + offset
            return UInt16(exactly: value)
        }
    }

    public static func ports(baseHTTPPorts: some Sequence<UInt16>) -> [UInt16] {
        var ports = Set(staticPorts)
        for basePort in baseHTTPPorts {
            ports.formUnion(dynamicPorts(baseHTTPPort: basePort))
        }
        return ports.sorted()
    }

    public static func targets(hosts: some Sequence<HostAddress>, includeGlobalBroadcast: Bool = true) -> [WakeOnLANTarget] {
        var targets = Set<WakeOnLANTarget>()
        var basePorts = Set<UInt16>()
        for host in hosts {
            basePorts.insert(host.port)
            for port in staticPorts + dynamicPorts(baseHTTPPort: host.port) {
                targets.insert(WakeOnLANTarget(host: host.host, port: port))
            }
        }
        if includeGlobalBroadcast {
            for port in ports(baseHTTPPorts: basePorts) {
                targets.insert(WakeOnLANTarget(host: "255.255.255.255", port: port))
            }
        }
        return targets.sorted { lhs, rhs in
            lhs.host == rhs.host ? lhs.port < rhs.port : lhs.host < rhs.host
        }
    }
}

public protocol WakeOnLANSending: Sendable {
    func send(macAddress: Data, to targets: [WakeOnLANTarget]) async -> [WakeOnLANTarget: Result<Void, Error>]
}

public struct NetworkWakeOnLANSender: WakeOnLANSending, Sendable {
    public init() {}

    public func send(
        macAddress: Data,
        to targets: [WakeOnLANTarget]
    ) async -> [WakeOnLANTarget: Result<Void, Error>] {
        let packet: Data
        do {
            packet = try WakeOnLAN.magicPacket(macAddress: macAddress)
        } catch {
            var failures: [WakeOnLANTarget: Result<Void, Error>] = [:]
            for target in targets { failures[target] = .failure(error) }
            return failures
        }
        return await withTaskGroup(of: (WakeOnLANTarget, Result<Void, Error>).self) { group in
            for target in targets {
                group.addTask {
                    do {
                        try await send(packet: packet, to: target)
                        return (target, .success(()))
                    } catch {
                        return (target, .failure(error))
                    }
                }
            }
            var results: [WakeOnLANTarget: Result<Void, Error>] = [:]
            for await (target, result) in group { results[target] = result }
            return results
        }
    }

    private func send(packet: Data, to target: WakeOnLANTarget) async throws {
        guard let port = NWEndpoint.Port(rawValue: target.port) else {
            throw UmbraNetworkingError.invalidPort(String(target.port))
        }
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .udp)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: packet, completion: .contentProcessed { error in
                    connection.cancel()
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
                connection.start(queue: DispatchQueue.global(qos: .utility))
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
