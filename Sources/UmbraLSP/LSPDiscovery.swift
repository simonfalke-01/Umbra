import Dispatch
import Foundation
import UmbraNetworking

/// Creates native LSP discovery without altering legacy GameStream browsing.
public enum LSPDiscovery {
    /// Creates a Bonjour browser for `_lumen-stream._udp.local.`.
    ///
    /// - Parameter queue: Private browser and retry queue.
    /// - Returns: A discovery owner that emits only native LSP services.
    public static func makeBonjourBrowser(
        queue: DispatchQueue = DispatchQueue(label: "app.umbra.lsp-bonjour-discovery")
    ) -> NetworkBonjourDiscovery {
        NetworkBonjourDiscovery(serviceProtocol: .lumenStreamingProtocol, queue: queue)
    }

    /// Accepts only a resolved LSP/1 SRV endpoint with matching PIN-capable metadata.
    public static func pairingHost(
        from service: DiscoveredHostService,
        resolvedEndpoint: ResolvedBonjourServiceEndpoint
    ) -> LSPDiscoveredPairingHost? {
        guard service.name == resolvedEndpoint.serviceName,
              service.type == resolvedEndpoint.serviceType,
              service.domain == resolvedEndpoint.domain,
              service.changeToken == resolvedEndpoint.changeToken,
              service.type == "_lumen-stream._udp",
              service.txtRecord["v"] == "1",
              service.txtRecord["pair"] == "pin1",
              let id = service.txtRecord["id"],
              let hostID = uuid(fromLowercaseHex: id),
              let spkiHex = service.txtRecord["spki"],
              let spki = data(fromLowercaseHex: spkiHex, expectedBytes: 32),
              !resolvedEndpoint.targetHost.isEmpty,
              resolvedEndpoint.port != 0 else { return nil }
        return .init(
            hostID: hostID,
            serverSPKISHA256: spki,
            port: resolvedEndpoint.port,
            host: resolvedEndpoint.targetHost,
            name: service.name,
            capabilities: service.txtRecord["caps"] ?? "",
            domain: service.domain,
            interfaceName: resolvedEndpoint.interfaceName,
            discoveryChangeToken: service.changeToken,
            discoveryServiceID: service.id,
            legacyHostID: service.txtRecord["gs"].flatMap { UUID(uuidString: $0) }?.uuidString.lowercased()
        )
    }

    private static func uuid(fromLowercaseHex value: String) -> UUID? {
        guard let bytes = data(fromLowercaseHex: value, expectedBytes: 16) else { return nil }
        return try? LSPControlWire.uuid(bytes)
    }

    private static func data(fromLowercaseHex value: String, expectedBytes: Int) -> Data? {
        guard value.count == expectedBytes * 2,
              value.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else { return nil }
        var result = Data(capacity: expectedBytes)
        var index = value.startIndex
        for _ in 0..<expectedBytes {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            result.append(byte)
            index = end
        }
        return result
    }
}
