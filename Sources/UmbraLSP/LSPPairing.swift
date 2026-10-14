import CryptoKit
import Foundation
import Security
import UmbraLSPTransport

/// Resolved PIN-capable LSP host accepted from provisional mDNS metadata.
public struct LSPDiscoveredPairingHost: Equatable, Sendable, Identifiable {
    public var hostID: UUID
    public var serverSPKISHA256: Data
    public var port: UInt16
    public var host: String
    public var name: String
    public var capabilities: String
    public var domain: String
    public var interfaceName: String?
    public var discoveryChangeToken: UInt64
    public var discoveryServiceID: String
    /// Lowercase GameStream unique ID the same host advertises, when present.
    public var legacyHostID: String? = nil

    public var id: UUID { hostID }

    public var endpoint: LSPTransportEndpoint {
        LSPTransportEndpoint(host: host, port: port, serverSPKISHA256: serverSPKISHA256)
    }

    /// Uppercase SHA-256 SPKI digest grouped for human comparison.
    public var provisionalSPKIFingerprint: String {
        let hex = serverSPKISHA256.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 8).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(8, hex.count - offset))
            return String(hex[start..<end])
        }.joined(separator: " ")
    }
}

/// User-visible pairing state; the PIN must never enter logs, URLs, arguments, or persistence.
public struct LSPPairingPrompt: Equatable, Sendable {
    public var host: LSPDiscoveredPairingHost
    public var pin: String
    public var expiresAtUTCSeconds: UInt64
    public var requestedPermissions: LSPPermission
    public var effectivePermissions: LSPPermission
}

/// Bounded object reference carried in an application image-path field.
public struct LSPObjectReference: Equatable, Sendable {
    public var objectID: UUID
    public var length: UInt32
    public var sha256: Data

    public static func decode(_ value: String) -> Self? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        let uuidText = parts.count > 1 ? String(parts[1]) : ""
        guard parts.count == 4,
              parts[0] == "lsp-object-v1",
              uuidText == uuidText.lowercased(),
              uuidText.count == 36,
              let objectID = UUID(uuidString: uuidText),
              let length = UInt32(parts[2]),
              length > 0,
              length <= 16 * 1_024 * 1_024,
              parts[3].count == 64,
              parts[3].allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else { return nil }
        var digest = Data(capacity: 32)
        var index = parts[3].startIndex
        for _ in 0..<32 {
            let end = parts[3].index(index, offsetBy: 2)
            guard let byte = UInt8(parts[3][index..<end], radix: 16) else { return nil }
            digest.append(byte)
            index = end
        }
        guard digest.contains(where: { $0 != 0 }) else { return nil }
        return .init(objectID: objectID, length: length, sha256: digest)
    }
}

/// Stable LSP-only client application identity used for pairing and reconnect auth.
public struct LSPClientIdentity: Codable, Equatable, Sendable {
    public var clientID: UUID
    public var privateKeyRawRepresentation: Data

    public init(clientID: UUID = UUID(), privateKeyRawRepresentation: Data) throws {
        guard privateKeyRawRepresentation.count == 32 else {
            throw DeterministicCBORError.malformed
        }
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRawRepresentation)
        self.clientID = clientID
        self.privateKeyRawRepresentation = privateKeyRawRepresentation
    }

    public static func generate() -> Self {
        let key = Curve25519.Signing.PrivateKey()
        return try! Self(privateKeyRawRepresentation: key.rawRepresentation)
    }

    var privateKey: Curve25519.Signing.PrivateKey {
        get throws {
            try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRawRepresentation)
        }
    }

    public var publicKeyRawRepresentation: Data {
        get throws {
            try privateKey.publicKey.rawRepresentation
        }
    }
}

enum LSPSecureRandom {
    static func bytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { destination in
            SecRandomCopyBytes(kSecRandomDefault, destination.count, destination.baseAddress!)
        }
        guard status == errSecSuccess, bytes.contains(where: { $0 != 0 }) else {
            throw LSPTransportError.internalFailure
        }
        return bytes
    }
}
