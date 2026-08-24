import XCTest
@testable import UmbraMicrophone

final class LMC1DatagramTests: XCTestCase {
    func testParsesExactBigEndianHeaderFields() throws {
        let datagram = try LMC1Datagram(
            validating: try bytes(
                "4c4d433102000028101112131415161718191a1b1c1d1e1f" +
                    "01020304050607081122334400040000" +
                    "deadbeef" +
                    "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
            )
        )

        XCTAssertEqual(datagram.bytes.count, 60)
        XCTAssertEqual(datagram.type, .audio)
        XCTAssertEqual(datagram.flags, 0)
        XCTAssertEqual(datagram.sessionID.bytes, Array(0x10...0x1f))
        XCTAssertEqual(datagram.packetSequence, 0x0102_0304_0506_0708)
        XCTAssertEqual(datagram.timestamp48kHz, 0x1122_3344)
        XCTAssertEqual(datagram.ciphertext, [0xde, 0xad, 0xbe, 0xef])
        XCTAssertEqual(datagram.authenticationTag, Array(0xa0...0xaf))
        XCTAssertEqual(LMC1Datagram.minimumDatagramByteCount, 56)
        XCTAssertEqual(LMC1Datagram.maximumDatagramByteCount, 1_331)
    }

    func testRejectsMalformedFramingAndBoundsBeforeAuthentication() throws {
        let hello = try validHello()

        XCTAssertDatagramError(Array(hello.prefix(39)), .truncatedHeader)
        XCTAssertMutatedError(hello, offset: 0, value: 0, .invalidMagic)
        XCTAssertMutatedError(hello, offset: 4, value: 5, .invalidType(5))
        XCTAssertMutatedError(hello, offset: 5, value: 2, .invalidFlags(2))
        XCTAssertMutatedError(hello, offset: 5, value: 1, .invalidTypeFlags)
        XCTAssertMutatedError(hello, offset: 7, value: 39, .invalidHeaderLength(39))

        var oversized = hello
        oversized[36] = 0x04
        oversized[37] = 0xfc
        XCTAssertDatagramError(oversized, .ciphertextTooLarge(1_276))

        XCTAssertMutatedError(hello, offset: 38, value: 1, .nonzeroReserved)
        XCTAssertDatagramError(Array(hello.dropLast()), .incorrectDatagramLength(expected: 56, actual: 55))
        XCTAssertDatagramError(hello + [0], .incorrectDatagramLength(expected: 56, actual: 57))
    }

    func testRejectsInvalidTypePayloadCombinations() throws {
        var audio = try validAudio()
        audio[4] = LMC1PacketType.reset.rawValue
        XCTAssertDatagramError(audio, .controlPacketHasCiphertext)

        var emptyAudio = try validHello()
        emptyAudio[4] = LMC1PacketType.audio.rawValue
        XCTAssertDatagramError(emptyAudio, .audioPacketMissingCiphertext)

        var payloadSilence = try validAudio()
        payloadSilence[5] = LMC1Datagram.silenceFlag
        XCTAssertDatagramError(payloadSilence, .silencePacketHasCiphertext)
    }

    func testAcceptsMaximumCiphertextAndRejectsOneByteBeyondLimit() throws {
        let session = try MicrophoneSessionID(bytes: [UInt8](repeating: 1, count: 16))
        let maximumHeader = LMC1Datagram.header(
            type: .audio,
            flags: 0,
            sessionID: session,
            packetSequence: 0,
            timestamp48kHz: 0,
            plaintextByteCount: LMC1Datagram.maximumCiphertextByteCount
        )
        let maximum = maximumHeader +
            [UInt8](repeating: 0, count: LMC1Datagram.maximumCiphertextByteCount) +
            [UInt8](repeating: 0, count: LMC1Datagram.authenticationTagByteCount)
        XCTAssertNoThrow(try LMC1Datagram(validating: maximum))
        XCTAssertEqual(maximum.count, LMC1Datagram.maximumDatagramByteCount)

        var beyond = maximum
        beyond[36] = 0x04
        beyond[37] = 0xfc
        beyond.append(0)
        XCTAssertDatagramError(beyond, .ciphertextTooLarge(1_276))
    }

    private func validHello() throws -> [UInt8] {
        try bytes(
            "4c4d433101000028202122232425262728292a2b2c2d2e2f" +
                "00000000000000000000000000000000" +
                "b302cac8b25fe7b957fcc42d4e4b1d8d"
        )
    }

    private func validAudio() throws -> [UInt8] {
        try bytes(
            "4c4d433102000028202122232425262728292a2b2c2d2e2f" +
                "00000000000000010000000000040000" +
                "5b488ea54a3f7e03f3e7fa52baa79d9243666d02"
        )
    }

    private func XCTAssertMutatedError(
        _ bytes: [UInt8],
        offset: Int,
        value: UInt8,
        _ expected: LMC1DatagramError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var changed = bytes
        changed[offset] = value
        XCTAssertDatagramError(changed, expected, file: file, line: line)
    }

    private func XCTAssertDatagramError(
        _ bytes: [UInt8],
        _ expected: LMC1DatagramError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try LMC1Datagram(validating: bytes), file: file, line: line) {
            XCTAssertEqual($0 as? LMC1DatagramError, expected, file: file, line: line)
        }
    }
}

private func bytes(_ hexadecimal: String) throws -> [UInt8] {
    guard hexadecimal.count.isMultiple(of: 2) else { throw HexTestError.invalid }
    let characters = Array(hexadecimal.utf8)
    return try stride(from: 0, to: characters.count, by: 2).map { index in
        guard let high = hexNibble(characters[index]), let low = hexNibble(characters[index + 1]) else {
            throw HexTestError.invalid
        }
        return (high << 4) | low
    }
}

private func hexNibble(_ character: UInt8) -> UInt8? {
    switch character {
    case 48...57: character - 48
    case 97...102: character - 97 + 10
    default: nil
    }
}

private enum HexTestError: Error {
    case invalid
}
