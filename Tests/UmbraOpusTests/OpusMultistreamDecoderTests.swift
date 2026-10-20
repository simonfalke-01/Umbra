import AVFAudio
import COpus
import Foundation
import UmbraMedia
import UmbraOpus
import XCTest

final class OpusMultistreamDecoderTests: XCTestCase {
    func testEncoderGeneratedStereoPacketDecodesToOwnedFloatAndCoreAudioBuffer() throws {
        let decoder = OpusMultistreamDecoder()
        try decoder.configureThrowing(format: .gameStreamStereo)
        decoder.start()

        let frame = try decoder.decode(packet: CompressedAudioPacket(data: try makeStereoPacket()))

        XCTAssertEqual(frame.sampleRate, 48_000)
        XCTAssertEqual(frame.layout, .stereo)
        XCTAssertEqual(frame.frameLength, 480)
        XCTAssertEqual(frame.samples.count, 960)
        XCTAssertGreaterThan(frame.samples.map(abs).max() ?? 0, 0.01)

        let buffer = try frame.makeAudioBuffer()
        XCTAssertEqual(buffer.frameLength, 480)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(buffer.format.isInterleaved)
        XCTAssertEqual(buffer.format.channelLayout?.layoutTag, kAudioChannelLayoutTag_Stereo)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for sample in [0, 137, 479] {
            XCTAssertEqual(channels[0][sample], frame.samples[sample * 2])
            XCTAssertEqual(channels[1][sample], frame.samples[(sample * 2) + 1])
        }
    }

    func testSubmitDeliversRealDecodedBufferToRenderer() throws {
        let renderer = RecordingAudioRenderer()
        let decoder = OpusMultistreamDecoder(renderer: renderer)
        try decoder.configureThrowing(format: .gameStreamStereo)
        decoder.start()

        decoder.submit(packet: CompressedAudioPacket(data: try makeStereoPacket()))

        let buffer = try XCTUnwrap(renderer.buffers.first)
        XCTAssertEqual(buffer.frameLength, 480)
        XCTAssertGreaterThan(bufferMagnitude(buffer), 0.01)
        XCTAssertNil(decoder.lastError)
    }

    func testGameStreamStereoFivePointOneAndSevenPointOneLayoutsConfigure() throws {
        let decoder = OpusMultistreamDecoder()
        for format in [
            OpusStreamFormat.gameStreamStereo,
            .gameStreamFivePointOne,
            .gameStreamSevenPointOne,
        ] {
            try decoder.configureThrowing(format: format)
            XCTAssertEqual(decoder.currentFormat, format)
            XCTAssertFalse(decoder.isRunning)
        }
    }

    func testConfigurationRejectsMismatchedLayoutAndInvalidMapping() throws {
        let decoder = OpusMultistreamDecoder()
        let mismatched = OpusStreamFormat(
            audioConfiguration: AudioOutputLayout.surround51.audioConfiguration,
            sampleRate: 48_000,
            channelCount: 2,
            streamCount: 1,
            coupledStreamCount: 1,
            samplesPerFrame: 480,
            mapping: [0, 1]
        )
        XCTAssertThrowsError(try decoder.configureThrowing(format: mismatched)) { error in
            XCTAssertEqual(error as? OpusDecoderError, .channelCountMismatch(expected: 6, actual: 2))
        }

        let invalidMapping = OpusStreamFormat(
            audioConfiguration: AudioOutputLayout.stereo.audioConfiguration,
            sampleRate: 48_000,
            channelCount: 2,
            streamCount: 1,
            coupledStreamCount: 1,
            samplesPerFrame: 480,
            mapping: [0, 2]
        )
        XCTAssertThrowsError(try decoder.configureThrowing(format: invalidMapping)) { error in
            XCTAssertEqual(
                error as? OpusDecoderError,
                .invalidMapping(channel: 1, value: 2, codedChannelCount: 2)
            )
        }
    }

    func testPacketAndLifecycleErrorsAreExplicit() throws {
        let decoder = OpusMultistreamDecoder()
        XCTAssertThrowsError(try decoder.decode(packet: CompressedAudioPacket(data: Data()))) { error in
            XCTAssertEqual(error as? OpusDecoderError, .notConfigured)
        }

        try decoder.configureThrowing(format: .gameStreamStereo)
        XCTAssertThrowsError(try decoder.decode(packet: CompressedAudioPacket(data: Data()))) { error in
            XCTAssertEqual(error as? OpusDecoderError, .notRunning)
        }

        decoder.start()
        let oversized = Data(repeating: 0, count: OpusMultistreamDecoder.maximumGameStreamPacketSize + 1)
        XCTAssertThrowsError(try decoder.decode(packet: CompressedAudioPacket(data: oversized))) { error in
            XCTAssertEqual(
                error as? OpusDecoderError,
                .packetTooLarge(
                    maximum: OpusMultistreamDecoder.maximumGameStreamPacketSize,
                    actual: oversized.count
                )
            )
        }

        decoder.cleanUp()
        XCTAssertNil(decoder.currentFormat)
        XCTAssertFalse(decoder.isRunning)
    }

    func testMalformedOpusPacketReportsLibopusError() throws {
        let decoder = OpusMultistreamDecoder()
        try decoder.configureThrowing(format: .gameStreamStereo)
        decoder.start()

        XCTAssertThrowsError(
            try decoder.decode(packet: CompressedAudioPacket(data: Data([0x03])))
        ) { error in
            guard case let .decodingFailed(code, message) = error as? OpusDecoderError else {
                return XCTFail("Expected libopus decoding failure, got \(error)")
            }
            XCTAssertEqual(code, Int32(OPUS_INVALID_PACKET))
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testEmptyPacketUsesLibopusPacketLossConcealmentAndResetIsDeterministic() throws {
        let decoder = OpusMultistreamDecoder()
        try decoder.configureThrowing(format: .gameStreamStereo)
        decoder.start()
        let packet = CompressedAudioPacket(data: try makeStereoPacket())

        let first = try decoder.decode(packet: packet)
        _ = try decoder.decode(packet: CompressedAudioPacket(data: Data()))
        try decoder.reset()
        let afterReset = try decoder.decode(packet: packet)

        XCTAssertEqual(first, afterReset)
    }

    func testSustainedOpusDecodingWithPLCKeepsStereoSignalContinuous() throws {
        let decoder = OpusMultistreamDecoder()
        try decoder.configureThrowing(format: .gameStreamStereo)
        decoder.start()
        let packets = try makeStereoPackets(count: 100)
        let lostPacketIndices: Set<Int> = [7, 16, 44, 73]
        var decodedChannels = Array(repeating: [Float](), count: 2)

        for (packetIndex, packet) in packets.enumerated() {
            let data = lostPacketIndices.contains(packetIndex) ? Data() : packet
            let frame = try decoder.decode(packet: CompressedAudioPacket(data: data))

            XCTAssertEqual(frame.frameLength, 480)
            for sampleIndex in stride(from: 0, to: frame.samples.count, by: 2) {
                decodedChannels[0].append(frame.samples[sampleIndex])
                decodedChannels[1].append(frame.samples[sampleIndex + 1])
            }
        }

        XCTAssertEqual(decodedChannels[0].count, 48_000)
        XCTAssertGreaterThan(rootMeanSquare(decodedChannels[0]), 0.10)
        XCTAssertGreaterThan(rootMeanSquare(decodedChannels[1]), 0.05)
        XCTAssertGreaterThan(
            abs(rootMeanSquare(decodedChannels[0]) - rootMeanSquare(decodedChannels[1])),
            0.05
        )
        for packet in packets.indices {
            let packetSamples = Array(decodedChannels[0][(packet * 480)..<((packet + 1) * 480)])
            XCTAssertGreaterThan(
                rootMeanSquare(packetSamples),
                0.01,
                "Packet window \(packet) unexpectedly decoded as silence"
            )
        }
        for boundary in stride(from: 480, to: decodedChannels[0].count, by: 480) {
            XCTAssertLessThan(
                abs(decodedChannels[0][boundary] - decodedChannels[0][boundary - 1]),
                0.25,
                "Discontinuity at decoded packet boundary \(boundary / 480)"
            )
        }
        XCTAssertNil(decoder.lastError)
    }

}

private final class RecordingAudioRenderer: AudioEngineRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AVAudioPCMBuffer] = []

    var buffers: [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func enqueue(_ buffer: DecodedAudioBuffer) {
        lock.lock()
        storage.append(buffer.buffer)
        lock.unlock()
    }

    func flush() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}

private extension OpusStreamFormat {
    static let gameStreamStereo = OpusStreamFormat(
        audioConfiguration: AudioOutputLayout.stereo.audioConfiguration,
        sampleRate: 48_000,
        channelCount: 2,
        streamCount: 1,
        coupledStreamCount: 1,
        samplesPerFrame: 480,
        mapping: [0, 1, 0, 0, 0, 0, 0, 0]
    )

    static let gameStreamFivePointOne = OpusStreamFormat(
        audioConfiguration: AudioOutputLayout.surround51.audioConfiguration,
        sampleRate: 48_000,
        channelCount: 6,
        streamCount: 4,
        coupledStreamCount: 2,
        samplesPerFrame: 480,
        mapping: [0, 4, 1, 5, 2, 3, 0, 0]
    )

    static let gameStreamSevenPointOne = OpusStreamFormat(
        audioConfiguration: AudioOutputLayout.surround71.audioConfiguration,
        sampleRate: 48_000,
        channelCount: 8,
        streamCount: 4,
        coupledStreamCount: 4,
        samplesPerFrame: 480,
        mapping: [0, 1, 2, 3, 4, 5, 6, 7]
    )
}

private func makeStereoPacket() throws -> Data {
    try XCTUnwrap(makeStereoPackets(count: 1).first)
}

private func makeStereoPackets(count: Int) throws -> [Data] {
    var error: Int32 = Int32(OPUS_OK)
    guard let encoder = opus_encoder_create(48_000, 2, OPUS_APPLICATION_AUDIO, &error), error == OPUS_OK else {
        throw OpusDecoderError.decoderCreationFailed(code: error, message: "Test Opus encoder creation failed")
    }
    defer { opus_encoder_destroy(encoder) }

    let frameCount = 480
    return try (0..<count).map { packetIndex in
        var input = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let time = Float((packetIndex * frameCount) + frame) / 48_000
            input[frame * 2] = 0.65 * sin(2 * .pi * 440 * time)
            input[(frame * 2) + 1] = 0.35 * sin(2 * .pi * 660 * time)
        }
        var encoded = [UInt8](repeating: 0, count: OpusMultistreamDecoder.maximumGameStreamPacketSize)
        let length = input.withUnsafeBufferPointer { pcm in
            encoded.withUnsafeMutableBufferPointer { output in
                opus_encode_float(
                    encoder,
                    pcm.baseAddress!,
                    Int32(frameCount),
                    output.baseAddress!,
                    Int32(output.count)
                )
            }
        }
        guard length > 0 else {
            throw OpusDecoderError.decodingFailed(code: Int32(length), message: "Test Opus encoding failed")
        }
        return Data(encoded.prefix(Int(length)))
    }
}

private func bufferMagnitude(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channels = buffer.floatChannelData else { return 0 }
    var maximum: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
            maximum = max(maximum, abs(channels[channel][frame]))
        }
    }
    return maximum
}

private func rootMeanSquare(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(0.0) { $0 + Double($1 * $1) }
    return Float(sqrt(sum / Double(samples.count)))
}

private func waitUntil(
    timeout: TimeInterval = 1,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.001)
    }
    return condition()
}
