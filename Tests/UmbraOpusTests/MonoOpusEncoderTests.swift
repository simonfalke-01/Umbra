import COpus
import UmbraOpus
import XCTest

final class MonoOpusEncoderTests: XCTestCase {
    func testVersionOneEncoderUsesExactFormatAndResiliencyControls() throws {
        let encoder = try MonoOpusEncoder()
        let configuration = try encoder.configuration()

        XCTAssertEqual(MonoOpusEncoder.sampleRate, 48_000)
        XCTAssertEqual(MonoOpusEncoder.samplesPerFrame, 960)
        XCTAssertEqual(MonoOpusEncoder.maximumPacketByteCount, 1_275)
        XCTAssertEqual(configuration.bitrate, 64_000)
        XCTAssertTrue(configuration.inbandFECEnabled)
        XCTAssertEqual(configuration.packetLossPercentage, 10)
        XCTAssertTrue(configuration.dtxEnabled)
    }

    func testLSPSelectionCanDisableFECAndDTXWithoutChangingLegacyDefaults() throws {
        let encoder = try MonoOpusEncoder(inbandFECEnabled: false, dtxEnabled: false)
        let configuration = try encoder.configuration()
        XCTAssertFalse(configuration.inbandFECEnabled)
        XCTAssertFalse(configuration.dtxEnabled)
    }

    func testEncodesOneTwentyMillisecondMonoFrameWithinProtocolCeiling() throws {
        let encoder = try MonoOpusEncoder()
        let samples = (0..<MonoOpusEncoder.samplesPerFrame).map { sample in
            Float(sin(Double(sample) * 2 * .pi * 440 / 48_000)) * 0.25
        }

        let packet = try encoder.encode(samples: samples)

        XCTAssertFalse(packet.isEmpty)
        XCTAssertLessThanOrEqual(packet.count, 1_275)
        XCTAssertEqual(
            packet.withUnsafeBufferPointer {
                opus_packet_get_nb_samples($0.baseAddress!, Int32(packet.count), 48_000)
            },
            960
        )
    }

    func testResetRestoresDeterministicEncoderStateAndCloseIsExplicit() throws {
        let encoder = try MonoOpusEncoder()
        let samples = [Float](repeating: 0.2, count: 960)
        let first = try encoder.encode(samples: samples)
        _ = try encoder.encode(samples: samples)

        try encoder.reset()

        XCTAssertEqual(try encoder.encode(samples: samples), first)
        encoder.close()
        XCTAssertThrowsError(try encoder.encode(samples: samples)) {
            XCTAssertEqual($0 as? MonoOpusEncoderError, .closed)
        }
    }

    func testMicrophoneCodecRoundTripPreservesPitchAndDuration() throws {
        let encoder = try MonoOpusEncoder()
        var error = Int32(OPUS_OK)
        let decoder = try XCTUnwrap(opus_decoder_create(48_000, 1, &error))
        defer { opus_decoder_destroy(decoder) }
        XCTAssertEqual(error, OPUS_OK)

        let frequency = 440.0
        var decoded: [Float] = []
        for frameIndex in 0..<50 {
            let samples = (0..<960).map { sample in
                Float(sin(Double(frameIndex * 960 + sample) * 2 * .pi * frequency / 48_000)) * 0.25
            }
            let packet = try encoder.encode(samples: samples)
            var output = [Float](repeating: 0, count: 960)
            let count = packet.withUnsafeBufferPointer { bytes in
                output.withUnsafeMutableBufferPointer { pcm in
                    opus_decode_float(decoder, bytes.baseAddress!, Int32(bytes.count), pcm.baseAddress!, 960, 0)
                }
            }
            XCTAssertEqual(count, 960)
            decoded.append(contentsOf: output)
        }

        XCTAssertEqual(decoded.count, 48_000, "One second of microphone PCM must remain one second.")
        // Ignore codec startup delay and measure the frequency of the decoded waveform.
        let stableStart = 4_800
        let crossings = (stableStart + 1..<decoded.count).count {
            decoded[$0 - 1] <= 0 && decoded[$0] > 0
        }
        let duration = Double(decoded.count - stableStart) / 48_000
        XCTAssertEqual(Double(crossings) / duration, frequency, accuracy: 2)
    }

    func testRejectsNonProtocolFrameLength() throws {
        let encoder = try MonoOpusEncoder()
        XCTAssertThrowsError(try encoder.encode(samples: [Float](repeating: 0, count: 959))) {
            XCTAssertEqual($0 as? MonoOpusEncoderError, .invalidFrameLength(959))
        }
    }

    func testEncoderPublishesExplicitInDTXStateForProtocolSilenceMapping() throws {
        let encoder = try MonoOpusEncoder()
        var enteredDTX = false
        for _ in 0..<100 {
            _ = try encoder.encode(samples: [Float](repeating: 0, count: 960))
            if try encoder.isInDTX() {
                enteredDTX = true
                break
            }
        }
        XCTAssertTrue(enteredDTX)
    }
}
