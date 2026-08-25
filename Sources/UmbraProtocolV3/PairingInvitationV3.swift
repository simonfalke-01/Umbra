import CryptoKit
import Foundation

public struct ProtocolV3PairingInvitation: Equatable, Sendable {
    public static let uriPrefix = "umbra://pair/v3#"
    public static let fixedHeaderBytes = 172

    public let rawBytes: Data
    public let invitationID: Data
    public let invitationToken: Data
    public let hostID: Data
    public let tlsSPKIHash: Data
    public let hostPublicKey: Data
    public let issueUnixSeconds: UInt64
    public let expiryUnixSeconds: UInt64
    public let capabilities: UInt64
    public let hostname: String
    public let port: UInt16
    public let hostnameIsIPLiteral: Bool

    public var sha256: Data { Data(SHA256.hash(data: rawBytes)) }

    public static func decode(uri: String, nowUnixSeconds: UInt64) throws -> Self {
        guard uri.hasPrefix(uriPrefix) else { throw ProtocolV3WireError.invalidField("v3 invitation URI") }
        let fragment = String(uri.dropFirst(uriPrefix.count))
        guard !fragment.isEmpty, fragment.utf8.count <= 567,
              !fragment.contains("="),
              fragment.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) ||
                      (48...57).contains($0) || $0 == 45 || $0 == 95
              })
        else { throw ProtocolV3WireError.invalidField("v3 invitation base64url") }
        var base64 = fragment.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let raw = Data(base64Encoded: base64),
              raw.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "") == fragment
        else { throw ProtocolV3WireError.invalidField("non-normalized v3 invitation base64url") }
        return try decode(raw, nowUnixSeconds: nowUnixSeconds)
    }

    public static func decode(_ data: Data, nowUnixSeconds: UInt64) throws -> Self {
        guard data.count >= fixedHeaderBytes,
              data.prefix(4) == Data("ULI3".utf8),
              data[4] == 1,
              data[5] & ~UInt8(1) == 0,
              readUInt16(data, 6) == fixedHeaderBytes,
              Int(readUInt16(data, 8)) == data.count,
              readUInt16(data, 10) != 0,
              readUInt16(data, 12) == 3,
              readUInt16(data, 14) == 3,
              readUInt16(data, 170) == 0
        else { throw ProtocolV3WireError.invalidField("v3 invitation header") }
        let hostnameLength = Int(readUInt16(data, 168))
        guard (1...253).contains(hostnameLength), data.count == fixedHeaderBytes + hostnameLength,
              let hostname = String(data: data.suffix(hostnameLength), encoding: .ascii),
              hostname.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }),
              hostname == hostname.lowercased(), !hostname.hasSuffix(".")
        else { throw ProtocolV3WireError.invalidField("v3 invitation hostname") }
        let invitationID = data[16..<32]
        let invitationToken = data[32..<64]
        let hostID = data[64..<80]
        let spki = data[80..<112]
        let hostPublicKey = data[112..<144]
        let issue = readUInt64(data, 144)
        let expiry = readUInt64(data, 152)
        guard invitationID.contains(where: { $0 != 0 }), invitationToken.contains(where: { $0 != 0 }),
              hostID.contains(where: { $0 != 0 }), spki.contains(where: { $0 != 0 }),
              hostPublicKey.contains(where: { $0 != 0 }),
              Data(SHA256.hash(data: Data(hostPublicKey)).prefix(16)) == hostID
        else { throw ProtocolV3WireError.invalidField("v3 invitation identity") }
        guard issue <= nowUnixSeconds else {
            throw ProtocolV3WireError.invalidField("v3 invitation not active")
        }
        guard expiry >= nowUnixSeconds else {
            throw ProtocolV3WireError.invalidField("v3 invitation expired")
        }
        guard expiry >= issue, expiry - issue <= 300 else {
            throw ProtocolV3WireError.invalidField("v3 invitation lifetime")
        }
        return Self(
            rawBytes: data,
            invitationID: Data(invitationID),
            invitationToken: Data(invitationToken),
            hostID: Data(hostID),
            tlsSPKIHash: Data(spki),
            hostPublicKey: Data(hostPublicKey),
            issueUnixSeconds: issue,
            expiryUnixSeconds: expiry,
            capabilities: readUInt64(data, 160),
            hostname: hostname,
            port: readUInt16(data, 10),
            hostnameIsIPLiteral: data[5] & 1 != 0
        )
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        data[offset..<(offset + 2)].reduce(0) { ($0 << 8) | UInt16($1) }
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

public struct ProtocolV3TrustRecord: Codable, Equatable, Sendable {
    public let hostID: Data
    public let hostPublicKey: Data
    public let tlsSPKIHash: Data
    public let clientID: Data
    public let grantedPermissions: UInt64
    public let pairingGeneration: UInt64
    public let minimumProtocol: UInt16
    public let legacyFallbackAllowed: Bool

    public init(
        hostID: Data,
        hostPublicKey: Data,
        tlsSPKIHash: Data,
        clientID: Data,
        grantedPermissions: UInt64,
        pairingGeneration: UInt64
    ) throws {
        guard hostID.count == 16, hostPublicKey.count == 32, tlsSPKIHash.count == 32,
              clientID.count == 16, grantedPermissions != 0,
              grantedPermissions & ~UInt64(0xff) == 0, pairingGeneration != 0,
              Data(SHA256.hash(data: hostPublicKey).prefix(16)) == hostID
        else { throw ProtocolV3WireError.invalidField("v3 trust record") }
        self.hostID = hostID
        self.hostPublicKey = hostPublicKey
        self.tlsSPKIHash = tlsSPKIHash
        self.clientID = clientID
        self.grantedPermissions = grantedPermissions
        self.pairingGeneration = pairingGeneration
        minimumProtocol = 3
        legacyFallbackAllowed = false
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hostID, hostPublicKey, tlsSPKIHash, clientID, grantedPermissions
        case pairingGeneration, minimumProtocol, legacyFallbackAllowed
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let untyped = try decoder.container(keyedBy: AnyKey.self)
        guard Set(untyped.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw ProtocolV3WireError.invalidField("v3 trust record schema")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minimumProtocol = try container.decode(UInt16.self, forKey: .minimumProtocol)
        let legacyFallbackAllowed = try container.decode(Bool.self, forKey: .legacyFallbackAllowed)
        guard minimumProtocol == 3, !legacyFallbackAllowed else {
            throw ProtocolV3WireError.invalidField("v3 downgrade policy")
        }
        try self.init(
            hostID: container.decode(Data.self, forKey: .hostID),
            hostPublicKey: container.decode(Data.self, forKey: .hostPublicKey),
            tlsSPKIHash: container.decode(Data.self, forKey: .tlsSPKIHash),
            clientID: container.decode(Data.self, forKey: .clientID),
            grantedPermissions: container.decode(UInt64.self, forKey: .grantedPermissions),
            pairingGeneration: container.decode(UInt64.self, forKey: .pairingGeneration)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostID, forKey: .hostID)
        try container.encode(hostPublicKey, forKey: .hostPublicKey)
        try container.encode(tlsSPKIHash, forKey: .tlsSPKIHash)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(grantedPermissions, forKey: .grantedPermissions)
        try container.encode(pairingGeneration, forKey: .pairingGeneration)
        try container.encode(minimumProtocol, forKey: .minimumProtocol)
        try container.encode(legacyFallbackAllowed, forKey: .legacyFallbackAllowed)
    }
}
