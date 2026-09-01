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
