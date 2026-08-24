import Foundation
import XCTest
@testable import UmbraMicrophone

final class MicrophoneCryptoAndGenerationTests: XCTestCase {
    func testHKDFMatchesLumenGoldenVector() throws {
        let material = try MicrophoneKeyDerivation.derive(
            rikey: Array(0x00...0x0f),
            salt: try MicrophoneSalt(bytes: Array(0x10...0x1f))
        )
        let derived = material.withKeyAndNoncePrefix { key, prefix in
            Array(key) + Array(prefix)
        }

        XCTAssertEqual(
            derived,
            try bytes("63eae5272007ab73b70698467c3a84b2e74c8835b80d64284984d526bc162f478c2f9bf2")
        )
        XCTAssertEqual(MicrophoneKeyDerivation.information.count, 41)
        XCTAssertThrowsError(
            try MicrophoneKeyDerivation.derive(
                rikey: Array(0x00...0x0e),
                salt: try MicrophoneSalt(bytes: Array(0x10...0x1f))
            )
        ) { XCTAssertEqual($0 as? MicrophoneCryptoError, .invalidRIKeyByteCount(15)) }
    }

    func testHKDFCleansPRKWhenBlockOneHMACThrows() throws {
        var cleanups: [(MicrophoneKeyDerivation.CleanupStage, [UInt8])] = []

        XCTAssertThrowsError(
            try deriveWithInjectedHMACFailure(at: .expandBlock1) { stage, bytes in
                cleanups.append((stage, bytes))
            }
        ) { XCTAssertTrue($0 is InjectedHMACError) }

        XCTAssertEqual(cleanups.map(\.0), [.pseudorandomKey])
        assertEveryCleanupWasZeroed(cleanups)
    }

    func testHKDFCleansEveryCompletedIntermediateWhenBlockTwoHMACThrows() throws {
        var cleanups: [(MicrophoneKeyDerivation.CleanupStage, [UInt8])] = []

        XCTAssertThrowsError(
            try deriveWithInjectedHMACFailure(at: .expandBlock2) { stage, bytes in
                cleanups.append((stage, bytes))
            }
        ) { XCTAssertTrue($0 is InjectedHMACError) }

        XCTAssertEqual(cleanups.map(\.0), [.secondInput, .firstBlock, .pseudorandomKey])
        assertEveryCleanupWasZeroed(cleanups)
    }

    func testHELLOAndAUDIOPacketsMatchIndependentGoldenVectorsAndDecrypt() throws {
        let generation = try makeGeneration()
        let hello = try generation.hello()
        XCTAssertEqual(
            hello.bytes,
            try bytes(
                "4c4d433101000028202122232425262728292a2b2c2d2e2f" +
                    "00000000000000000000000000000000" +
                    "b302cac8b25fe7b957fcc42d4e4b1d8d"
            )
        )
        XCTAssertEqual(try decrypt(hello), [])

        let audio = try generation.audio(opusPacket: [0xde, 0xad, 0xbe, 0xef])
        XCTAssertEqual(
            audio.bytes,
            try bytes(
                "4c4d433102000028202122232425262728292a2b2c2d2e2f" +
                    "00000000000000010000000000040000" +
                    "5b488ea54a3f7e03f3e7fa52baa79d9243666d02"
            )
        )
        XCTAssertEqual(try decrypt(audio), [0xde, 0xad, 0xbe, 0xef])
    }

    func testGenerationAdvancesEverySequenceAndOnlyAudioTimelinePacketsAdvanceTimestamp() throws {
        let generation = try makeGeneration()
        XCTAssertEqual(try generation.hello().packetSequence, 0)

        let audio = try generation.audio(opusPacket: [1])
        XCTAssertEqual(audio.packetSequence, 1)
        XCTAssertEqual(audio.timestamp48kHz, 0)

        let silence = try generation.silence()
        XCTAssertEqual(silence.packetSequence, 2)
        XCTAssertEqual(silence.timestamp48kHz, 960)
        XCTAssertEqual(silence.flags, LMC1Datagram.silenceFlag)
        XCTAssertEqual(try decrypt(silence), [])

        let reset = try generation.reset()
        XCTAssertEqual(reset.packetSequence, 3)
        XCTAssertEqual(reset.timestamp48kHz, 1_920)

        let end = try generation.end()
        XCTAssertEqual(end.packetSequence, 4)
        XCTAssertEqual(end.timestamp48kHz, 1_920)
        XCTAssertEqual(generation.state, .ended)
        XCTAssertNil(generation.nextPacketSequence)
        XCTAssertThrowsError(try generation.silence()) {
            XCTAssertEqual($0 as? MicrophoneGenerationError, .generationClosed(.ended))
        }
    }

    func testGenerationRejectsInvalidOrderingAndPayloadBoundsWithoutConsumingSequence() throws {
        let generation = try makeGeneration()
        XCTAssertThrowsError(try generation.audio(opusPacket: [1])) {
            XCTAssertEqual($0 as? MicrophoneGenerationError, .helloRequired)
        }
        XCTAssertEqual(generation.nextPacketSequence, 0)

        _ = try generation.hello()
        XCTAssertThrowsError(try generation.hello()) {
            XCTAssertEqual($0 as? MicrophoneGenerationError, .helloAlreadySent)
        }
        XCTAssertThrowsError(try generation.audio(opusPacket: [])) {
            XCTAssertEqual($0 as? MicrophoneGenerationError, .emptyOpusPacket)
        }
        XCTAssertThrowsError(
            try generation.audio(
                opusPacket: [UInt8](repeating: 0, count: LMC1Datagram.maximumCiphertextByteCount + 1)
            )
        ) {
            XCTAssertEqual(
                $0 as? MicrophoneGenerationError,
                .opusPacketTooLarge(LMC1Datagram.maximumCiphertextByteCount + 1)
            )
        }
        XCTAssertEqual(generation.nextPacketSequence, 1)
        XCTAssertEqual(generation.timestamp48kHz, 0)
    }

    func testTimestampWrapsAndSequenceExhaustionNeverReusesANonce() throws {
        let wrapping = try MicrophoneGeneration(
            credentials: credentials(),
            rikey: Array(0x00...0x0f),
            initialSequence: 0,
            initialTimestamp48kHz: UInt32.max - 959
        )
        _ = try wrapping.hello()
        let finalTimelinePacket = try wrapping.audio(opusPacket: [1])
        XCTAssertEqual(finalTimelinePacket.timestamp48kHz, UInt32.max - 959)
        XCTAssertEqual(wrapping.timestamp48kHz, 0)

        let exhausting = try MicrophoneGeneration(
            credentials: credentials(),
            rikey: Array(0x00...0x0f),
            initialSequence: UInt64.max,
            initialTimestamp48kHz: 0
        )
        let last = try exhausting.hello()
        XCTAssertEqual(last.packetSequence, UInt64.max)
        XCTAssertEqual(exhausting.state, .exhausted)
        XCTAssertNil(exhausting.nextPacketSequence)
        XCTAssertThrowsError(try exhausting.audio(opusPacket: [1])) {
            XCTAssertEqual($0 as? MicrophoneGenerationError, .generationClosed(.exhausted))
        }
    }

    func testTransmitterPreservesOrderAndInvalidatesAfterLocalSendFailure() throws {
        let sender = RecordingSender()
        let generation = try makeGeneration()
        let transmitter = MicrophoneDatagramTransmitter(generation: generation, sender: sender)

        try transmitter.start()
        try transmitter.sendAudio(opusPacket: [1, 2])
        try transmitter.sendSilence()
        XCTAssertEqual(sender.datagrams.map(\.packetSequence), [0, 1, 2])

        sender.shouldFail = true
        XCTAssertThrowsError(try transmitter.reset())
        XCTAssertEqual(generation.state, .invalidated)
        XCTAssertNil(generation.nextPacketSequence)
    }

    func testTamperedAADOrTagDoesNotPublishPlaintext() throws {
        let generation = try makeGeneration()
        _ = try generation.hello()
        let audio = try generation.audio(opusPacket: [1, 3, 5, 7, 9])

        var changedHeader = audio.authenticatedHeader
        changedHeader[32] ^= 1
        XCTAssertThrowsError(try decrypt(audio, authenticatedHeader: changedHeader)) {
            XCTAssertEqual($0 as? MicrophoneCryptoError, .authenticationFailed)
        }

        var changedTag = audio.authenticationTag
        changedTag[0] ^= 1
        XCTAssertThrowsError(try decrypt(audio, tag: changedTag)) {
            XCTAssertEqual($0 as? MicrophoneCryptoError, .authenticationFailed)
        }
    }

    private func makeGeneration() throws -> MicrophoneGeneration {
        try MicrophoneGeneration(credentials: credentials(), rikey: Array(0x00...0x0f))
    }

    private func deriveWithInjectedHMACFailure(
        at failingStep: MicrophoneKeyDerivation.HMACStep,
        cleanupObserver: @escaping MicrophoneKeyDerivation.CleanupObserver
    ) throws -> MicrophoneKeyMaterial {
        try MicrophoneKeyDerivation.derive(
            rikey: Array(0x00...0x0f),
            salt: try MicrophoneSalt(bytes: Array(0x10...0x1f)),
            hmac: { step, key, data in
                guard step != failingStep else { throw InjectedHMACError() }
                return try MicrophoneKeyDerivation.hmacSHA256(key: key, data: data)
            },
            cleanupObserver: cleanupObserver
        )
    }

    private func assertEveryCleanupWasZeroed(
        _ cleanups: [(MicrophoneKeyDerivation.CleanupStage, [UInt8])],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (stage, bytes) in cleanups {
            XCTAssertFalse(bytes.isEmpty, "\(stage) cleanup was empty", file: file, line: line)
            XCTAssertTrue(
                bytes.allSatisfy { $0 == 0 },
                "\(stage) retained nonzero secret bytes",
                file: file,
                line: line
            )
        }
    }

    private func credentials() throws -> MicrophoneSetupCredentials {
        MicrophoneSetupCredentials(
            sessionID: try MicrophoneSessionID(bytes: Array(0x20...0x2f)),
            salt: try MicrophoneSalt(bytes: Array(0x10...0x1f))
        )
    }

    private func decrypt(
        _ datagram: LMC1Datagram,
        authenticatedHeader: [UInt8]? = nil,
        tag: [UInt8]? = nil
    ) throws -> [UInt8] {
        let material = try MicrophoneKeyDerivation.derive(
            rikey: Array(0x00...0x0f),
            salt: try MicrophoneSalt(bytes: Array(0x10...0x1f))
        )
        var nonce = try bytes("8c2f9bf2")
        nonce.append(contentsOf: withUnsafeBytes(of: datagram.packetSequence.bigEndian, Array.init))
        return try material.withKeyAndNoncePrefix { key, _ in
            try OpenSSLAESGCM.open(
                ciphertext: datagram.ciphertext,
                tag: tag ?? datagram.authenticationTag,
                authenticatedData: authenticatedHeader ?? datagram.authenticatedHeader,
                key: key,
                nonce: nonce
            )
        }
    }
}

private struct InjectedHMACError: Error {}

private enum RecordingSenderError: Error {
    case rejected
}

private final class RecordingSender: MicrophoneDatagramSending, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDatagrams: [LMC1Datagram] = []
    private var storedShouldFail = false

    var datagrams: [LMC1Datagram] {
        lock.withLock { storedDatagrams }
    }

    var shouldFail: Bool {
        get { lock.withLock { storedShouldFail } }
        set { lock.withLock { storedShouldFail = newValue } }
    }

    func send(_ datagram: LMC1Datagram) throws {
        try lock.withLock {
            if storedShouldFail { throw RecordingSenderError.rejected }
            storedDatagrams.append(datagram)
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
