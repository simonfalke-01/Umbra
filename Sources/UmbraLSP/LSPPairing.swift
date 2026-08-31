import CryptoKit
import Foundation
import Security
import UmbraLSPTransport

/// Exact version-one invitation decoded from `umbra://pair/lsp1#...`.
public struct LSPPairingInvitation: Equatable, Sendable {
    public var hostID: UUID
    public var hostIdentityKey: Data
    public var serverSPKISHA256: Data
    public var port: UInt16
    public var host: String
    public var invitationID: UUID
    public var invitationSecret: Data
    public var expiresAtUTCSeconds: UInt64
    public var offeredPermissions: LSPPermission

    public var endpoint: LSPTransportEndpoint {
        LSPTransportEndpoint(host: host, port: port, serverSPKISHA256: serverSPKISHA256)
    }

    public var isExpired: Bool {
        UInt64(Date().timeIntervalSince1970) >= expiresAtUTCSeconds
    }

    public static func decode(uri: String) throws -> Self {
        let prefix = "umbra://pair/lsp1#"
        guard uri.hasPrefix(prefix), uri.utf8.count <= 2_048 else {
            throw DeterministicCBORError.malformed
        }
        let fragment = String(uri.dropFirst(prefix.count))
        guard !fragment.isEmpty, !fragment.contains("="), fragment.count % 4 != 1 else {
            throw DeterministicCBORError.nonCanonical
        }
        let standard = fragment.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let encoded = Data(base64Encoded: padded),
              encoded.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "") == fragment
        else {
            throw DeterministicCBORError.nonCanonical
        }
        let fields = try DeterministicCBOR.exactMap(
            DeterministicCBOR.decode(encoded),
            count: 10
        )
        guard case .unsigned(1) = fields[0],
              case .bytes(let hostIDBytes) = fields[1],
              case .bytes(let hostIdentityKey) = fields[2], hostIdentityKey.count == 32,
              case .bytes(let spki) = fields[3], spki.count == 32,
              case .unsigned(let encodedPort) = fields[4], encodedPort > 0, encodedPort <= UInt16.max,
              case .text(let host) = fields[5], !host.isEmpty, host.utf8.count <= 255,
              !host.utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F }),
              case .bytes(let invitationIDBytes) = fields[6],
              case .bytes(let invitationSecret) = fields[7], invitationSecret.count == 32,
              case .unsigned(let expiration) = fields[8], expiration > 0,
              case .unsigned(let permissionMask) = fields[9], permissionMask <= UInt32.max
        else {
            throw DeterministicCBORError.malformed
        }
        let permissions = LSPPermission(rawValue: UInt32(permissionMask))
        guard permissions.subtracting(.allKnown).isEmpty,
              hostIdentityKey.contains(where: { $0 != 0 }),
              spki.contains(where: { $0 != 0 }),
              invitationSecret.contains(where: { $0 != 0 })
        else {
            throw DeterministicCBORError.malformed
        }
        return Self(
            hostID: try LSPControlWire.uuid(hostIDBytes),
            hostIdentityKey: hostIdentityKey,
            serverSPKISHA256: spki,
            port: UInt16(encodedPort),
            host: host,
            invitationID: try LSPControlWire.uuid(invitationIDBytes),
            invitationSecret: invitationSecret,
            expiresAtUTCSeconds: expiration,
            offeredPermissions: permissions
        )
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
