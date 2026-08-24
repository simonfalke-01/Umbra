import Foundation

/// The only microphone capability understood by protocol version one.
public enum MicrophoneCapability: Equatable, Sendable {
    case version1
}

/// Exact RTSP/SDP constants and strict DESCRIBE capability parsing.
public enum MicrophoneNegotiation {
    public static let setupStreamIdentifier = "streamid=lumen-mic/1/0"

    public static let describeCapabilitySDP =
        "a=x-lumen-mic.version:1\r\n" +
        "a=x-lumen-mic.codec:opus\r\n" +
        "a=x-lumen-mic.sampleRate:48000\r\n" +
        "a=x-lumen-mic.channels:1\r\n" +
        "a=x-lumen-mic.packetDurationMs:20\r\n" +
        "a=x-lumen-mic.crypto:aes-256-gcm\r\n" +
        "a=x-lumen-mic.fec:opus-inband\r\n"

    public static let announceSelectionSDP =
        "a=x-lumen-mic.enabled:1\r\n" +
        "a=x-lumen-mic.version:1\r\n" +
        "a=x-lumen-mic.codec:opus\r\n" +
        "a=x-lumen-mic.sampleRate:48000\r\n" +
        "a=x-lumen-mic.channels:1\r\n" +
        "a=x-lumen-mic.packetDurationMs:20\r\n" +
        "a=x-lumen-mic.fec:opus-inband\r\n"

    private static let requiredDescribeAttributes: [String: String] = [
        "x-lumen-mic.version": "1",
        "x-lumen-mic.codec": "opus",
        "x-lumen-mic.sampleRate": "48000",
        "x-lumen-mic.channels": "1",
        "x-lumen-mic.packetDurationMs": "20",
        "x-lumen-mic.crypto": "aes-256-gcm",
        "x-lumen-mic.fec": "opus-inband",
    ]

    /// Returns version one only when every microphone attribute is present once and exact.
    /// Other SDP attributes are ignored. Any unknown, duplicate, malformed, or changed
    /// `x-lumen-mic.*` attribute makes the extension unsupported.
    public static func parseDescribeCapability(from sdp: String) -> MicrophoneCapability? {
        var attributes: [String: String] = [:]
        let normalizedSDP = sdp.replacingOccurrences(of: "\r\n", with: "\n")

        for line in normalizedSDP.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.starts(with: "a=x-lumen-mic.") else { continue }

            let attribute = line.dropFirst(2)
            guard let separator = attribute.firstIndex(of: ":") else { return nil }
            let name = String(attribute[..<separator])
            let valueStart = attribute.index(after: separator)
            let value = String(attribute[valueStart...])

            guard requiredDescribeAttributes[name] == value,
                  attributes.updateValue(value, forKey: name) == nil else {
                return nil
            }
        }

        guard attributes == requiredDescribeAttributes else { return nil }
        return .version1
    }
}

public enum MicrophoneCredentialError: Error, Equatable, Sendable {
    case missingSessionHeader
    case duplicateSessionHeader
    case missingSaltHeader
    case duplicateSaltHeader
    case invalidSessionHex
    case invalidSaltHex
    case invalidSessionByteCount(Int)
    case invalidSaltByteCount(Int)
}

public struct MicrophoneSessionID: Equatable, Hashable, Sendable {
    public static let byteCount = 16
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw MicrophoneCredentialError.invalidSessionByteCount(bytes.count)
        }
        self.bytes = bytes
    }

    public init(lowercaseHex: String) throws {
        guard let bytes = StrictLowercaseHex.decode16(lowercaseHex) else {
            throw MicrophoneCredentialError.invalidSessionHex
        }
        self.bytes = bytes
    }
}

public struct MicrophoneSalt: Equatable, Hashable, Sendable {
    public static let byteCount = 16
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw MicrophoneCredentialError.invalidSaltByteCount(bytes.count)
        }
        self.bytes = bytes
    }

    public init(lowercaseHex: String) throws {
        guard let bytes = StrictLowercaseHex.decode16(lowercaseHex) else {
            throw MicrophoneCredentialError.invalidSaltHex
        }
        self.bytes = bytes
    }
}

/// Strictly decoded values returned by one successful microphone SETUP response.
public struct MicrophoneSetupCredentials: Equatable, Sendable {
    public let sessionID: MicrophoneSessionID
    public let salt: MicrophoneSalt

    public init(sessionHeaderValues: [String], saltHeaderValues: [String]) throws {
        guard !sessionHeaderValues.isEmpty else {
            throw MicrophoneCredentialError.missingSessionHeader
        }
        guard sessionHeaderValues.count == 1 else {
            throw MicrophoneCredentialError.duplicateSessionHeader
        }
        guard !saltHeaderValues.isEmpty else {
            throw MicrophoneCredentialError.missingSaltHeader
        }
        guard saltHeaderValues.count == 1 else {
            throw MicrophoneCredentialError.duplicateSaltHeader
        }

        sessionID = try MicrophoneSessionID(lowercaseHex: sessionHeaderValues[0])
        salt = try MicrophoneSalt(lowercaseHex: saltHeaderValues[0])
    }

    public init(sessionID: MicrophoneSessionID, salt: MicrophoneSalt) {
        self.sessionID = sessionID
        self.salt = salt
    }
}

private enum StrictLowercaseHex {
    static func decode16(_ value: String) -> [UInt8]? {
        guard value.utf8.count == 32 else { return nil }
        let characters = Array(value.utf8)
        var output = [UInt8]()
        output.reserveCapacity(16)

        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let high = nibble(characters[index]),
                  let low = nibble(characters[index + 1]) else {
                return nil
            }
            output.append((high << 4) | low)
        }
        return output
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case 48...57:
            character - 48
        case 97...102:
            character - 97 + 10
        default:
            nil
        }
    }
}
