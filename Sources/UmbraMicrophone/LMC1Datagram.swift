import Foundation

public enum LMC1PacketType: UInt8, CaseIterable, Sendable {
    case hello = 1
    case audio = 2
    case reset = 3
    case end = 4
}

public enum LMC1DatagramError: Error, Equatable, Sendable {
    case truncatedHeader
    case invalidMagic
    case invalidType(UInt8)
    case invalidFlags(UInt8)
    case invalidTypeFlags
    case invalidHeaderLength(UInt16)
    case ciphertextTooLarge(Int)
    case nonzeroReserved
    case incorrectDatagramLength(expected: Int, actual: Int)
    case controlPacketHasCiphertext
    case audioPacketMissingCiphertext
    case silencePacketHasCiphertext
}

/// One strictly validated version-one LMC1 datagram.
public struct LMC1Datagram: Equatable, Sendable {
    public static let fixedHeaderByteCount = 40
    public static let authenticationTagByteCount = 16
    public static let maximumCiphertextByteCount = 1_275
    public static let minimumDatagramByteCount = 56
    public static let maximumDatagramByteCount = 1_331
    public static let silenceFlag: UInt8 = 0x01

    public let bytes: [UInt8]
    public let type: LMC1PacketType
    public let flags: UInt8
    public let sessionID: MicrophoneSessionID
    public let packetSequence: UInt64
    public let timestamp48kHz: UInt32
    public let ciphertext: [UInt8]
    public let authenticationTag: [UInt8]

    public var authenticatedHeader: [UInt8] {
        Array(bytes[..<Self.fixedHeaderByteCount])
    }

    public init(validating bytes: [UInt8]) throws {
        guard bytes.count >= Self.fixedHeaderByteCount else {
            throw LMC1DatagramError.truncatedHeader
        }
        guard bytes[0...3].elementsEqual([0x4c, 0x4d, 0x43, 0x31]) else {
            throw LMC1DatagramError.invalidMagic
        }
        guard let type = LMC1PacketType(rawValue: bytes[4]) else {
            throw LMC1DatagramError.invalidType(bytes[4])
        }

        let flags = bytes[5]
        guard flags & ~Self.silenceFlag == 0 else {
            throw LMC1DatagramError.invalidFlags(flags)
        }
        guard type == .audio || flags == 0 else {
            throw LMC1DatagramError.invalidTypeFlags
        }

        let headerLength = Self.readUInt16(bytes, at: 6)
        guard headerLength == Self.fixedHeaderByteCount else {
            throw LMC1DatagramError.invalidHeaderLength(headerLength)
        }

        let ciphertextByteCount = Int(Self.readUInt16(bytes, at: 36))
        guard ciphertextByteCount <= Self.maximumCiphertextByteCount else {
            throw LMC1DatagramError.ciphertextTooLarge(ciphertextByteCount)
        }
        guard bytes[38] == 0, bytes[39] == 0 else {
            throw LMC1DatagramError.nonzeroReserved
        }

        let expectedByteCount = Self.minimumDatagramByteCount + ciphertextByteCount
        guard bytes.count == expectedByteCount else {
            throw LMC1DatagramError.incorrectDatagramLength(
                expected: expectedByteCount,
                actual: bytes.count
            )
        }

        let isSilence = flags & Self.silenceFlag != 0
        if type != .audio, ciphertextByteCount != 0 {
            throw LMC1DatagramError.controlPacketHasCiphertext
        }
        if type == .audio, !isSilence, ciphertextByteCount == 0 {
            throw LMC1DatagramError.audioPacketMissingCiphertext
        }
        if type == .audio, isSilence, ciphertextByteCount != 0 {
            throw LMC1DatagramError.silencePacketHasCiphertext
        }

        self.bytes = bytes
        self.type = type
        self.flags = flags
        sessionID = try MicrophoneSessionID(bytes: Array(bytes[8..<24]))
        packetSequence = Self.readUInt64(bytes, at: 24)
        timestamp48kHz = Self.readUInt32(bytes, at: 32)
        ciphertext = Array(bytes[40..<(40 + ciphertextByteCount)])
        authenticationTag = Array(bytes[(40 + ciphertextByteCount)..<expectedByteCount])
    }

    static func header(
        type: LMC1PacketType,
        flags: UInt8,
        sessionID: MicrophoneSessionID,
        packetSequence: UInt64,
        timestamp48kHz: UInt32,
        plaintextByteCount: Int
    ) -> [UInt8] {
        var header = [UInt8]()
        header.reserveCapacity(fixedHeaderByteCount)
        header.append(contentsOf: [0x4c, 0x4d, 0x43, 0x31])
        header.append(type.rawValue)
        header.append(flags)
        header.appendUInt16(UInt16(fixedHeaderByteCount))
        header.append(contentsOf: sessionID.bytes)
        header.appendUInt64(packetSequence)
        header.appendUInt32(timestamp48kHz)
        header.appendUInt16(UInt16(plaintextByteCount))
        header.append(contentsOf: [0, 0])
        return header
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var result: UInt32 = 0
        for byte in bytes[offset..<(offset + 4)] {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for byte in bytes[offset..<(offset + 8)] {
            result = (result << 8) | UInt64(byte)
        }
        return result
    }
}

private extension Array where Element == UInt8 {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}
