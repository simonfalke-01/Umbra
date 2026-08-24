import AVFAudio
import XCTest
@testable import UmbraMedia

final class AudioQueueBufferingPolicyTests: XCTestCase {
    func testBufferingPolicyConvertsDurationsToWholeFrames() {
        let latency = AudioQueueBufferingPolicy(configuration: PCMRendererConfiguration(
            sampleRate: 48_000,
            outputBufferDuration: 0.005,
            minimumPreRollDuration: 0.010
        ))
        XCTAssertEqual(latency.bufferPoolCount, 3)
        XCTAssertEqual(latency.queueBufferFrames, 240)
        XCTAssertEqual(latency.minimumPreRollFrames, 480)

        let nonIntegralRate = AudioQueueBufferingPolicy(configuration: PCMRendererConfiguration(
            sampleRate: 44_100,
            outputBufferDuration: 0.005,
            minimumPreRollDuration: 0.010
        ))
        XCTAssertEqual(nonIntegralRate.queueBufferFrames, 221)
        XCTAssertEqual(nonIntegralRate.minimumPreRollFrames, 441)
    }

    func testRebufferRequiresTwoLatencyQuantaBeforeRealPCMResumes() throws {
        let ring = OutputSampleRing(
            frameCapacity: 960,
            packetCapacity: 8,
            channelCount: 2,
            metadataCount: 3,
            minimumPreRollFrames: 480
        )
        ring.activateForTesting()

        XCTAssertEqual(ring.write(try makePCMBuffer(frames: 240, channels: 2, value: 1)), 1)
        XCTAssertEqual(ring.fillForTesting(sampleCount: 480), [Float](repeating: 0, count: 480))
        XCTAssertEqual(ring.snapshot.queuedPackets, 1)

        XCTAssertEqual(ring.write(try makePCMBuffer(frames: 240, channels: 2, value: 2)), 1)
        XCTAssertEqual(Set(ring.fillForTesting(sampleCount: 480)), [1])
        XCTAssertEqual(Set(ring.fillForTesting(sampleCount: 480)), [2])
        XCTAssertEqual(ring.fillForTesting(sampleCount: 480), [Float](repeating: 0, count: 480))
        XCTAssertEqual(ring.snapshot.rebufferCount, 1)
        XCTAssertEqual(ring.write(try makePCMBuffer(frames: 240, channels: 2, value: 3)), 1)
        XCTAssertEqual(ring.fillForTesting(sampleCount: 480), [Float](repeating: 0, count: 480))
        XCTAssertEqual(ring.write(try makePCMBuffer(frames: 240, channels: 2, value: 4)), 1)
        XCTAssertEqual(Set(ring.fillForTesting(sampleCount: 480)), [3])
        XCTAssertEqual(ring.snapshot.rebufferCount, 1)
    }

    func testArbitraryMultichannelPacketSpansPhysicalBuffersWithoutPaddingOrLoss() throws {
        let ring = OutputSampleRing(
            frameCapacity: 960,
            packetCapacity: 4,
            channelCount: 6,
            metadataCount: 3,
            minimumPreRollFrames: 240
        )
        ring.activateForTesting()
        let firstChannelValues = (0..<6).map { Float(7 + $0) }
        let secondChannelValues = (0..<6).map { Float(17 + $0) }
        XCTAssertEqual(ring.write(try makePCMBuffer(
            frames: 360,
            channels: 6,
            channelValues: firstChannelValues
        )), 1)

        XCTAssertEqual(Set(ring.fillForTesting(sampleCount: 240 * 6)), Set(firstChannelValues))
        XCTAssertEqual(ring.snapshot.queuedPackets, 1)
        XCTAssertEqual(ring.snapshot.scheduledPackets, 0)

        XCTAssertEqual(ring.write(try makePCMBuffer(
            frames: 120,
            channels: 6,
            channelValues: secondChannelValues
        )), 1)
        let secondQuantum = ring.fillForTesting(sampleCount: 240 * 6)
        XCTAssertEqual(Set(secondQuantum.prefix(120 * 6)), Set(firstChannelValues))
        XCTAssertEqual(Set(secondQuantum.suffix(120 * 6)), Set(secondChannelValues))
        XCTAssertEqual(ring.snapshot.queuedPackets, 0)
        XCTAssertEqual(ring.snapshot.scheduledPackets, 2)

        ring.completeForTesting()
        XCTAssertEqual(ring.snapshot.playedPackets, 2)
        XCTAssertEqual(ring.snapshot.scheduledPackets, 0)
        XCTAssertEqual(ring.snapshot.renderedSilenceSamples, 0)
    }

    private func makePCMBuffer(
        frames: AVAudioFrameCount,
        channels: AVAudioChannelCount,
        value: Float = 0,
        channelValues: [Float]? = nil
    ) throws -> AVAudioPCMBuffer {
        let outputLayout: AudioOutputLayout = switch channels {
        case 2: .stereo
        case 6: .surround51
        case 8: .surround71
        default: throw XCTSkip("Unsupported test channel count: \(channels)")
        }
        let channelLayout = try XCTUnwrap(
            AVAudioChannelLayout(layoutTag: outputLayout.coreAudioLayoutTag)
        )
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: channelLayout
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        if let channelValues {
            XCTAssertEqual(channelValues.count, Int(channels))
        }
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                channelData[channel][frame] = channelValues?[channel] ?? value
            }
        }
        return buffer
    }
}
