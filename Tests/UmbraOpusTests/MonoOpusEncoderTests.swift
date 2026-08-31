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
