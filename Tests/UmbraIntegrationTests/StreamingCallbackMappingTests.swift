import Foundation
import XCTest
@testable import UmbraStreaming

final class StreamingCallbackMappingTests: XCTestCase {
    func testVideoSetupMapsNegotiatedFormatAndReturnValue() {
        let video = RecordingStreamingVideoDecoder(configurationResult: false)
        let harness = StreamingCallbackTestHarness(videoDecoder: video, audioDecoder: RecordingStreamingAudioDecoder())

        let result = harness.videoSetup(
            codecMask: 0x0200,
            width: 2_560,
            height: 1_440,
            redrawRate: 120,
            flags: 0x1234
        )

        XCTAssertEqual(result, -1)
        XCTAssertEqual(video.format?.codecMask, 0x0200)
        XCTAssertEqual(video.format?.width, 2_560)
        XCTAssertEqual(video.format?.height, 1_440)
        XCTAssertEqual(video.format?.redrawRate, 120)
        XCTAssertEqual(video.format?.flags, 0x1234)
    }

    func testVideoFrameTakesOwnedBytesAndMapsMetadata() {
        let video = RecordingStreamingVideoDecoder(frameResult: .requestKeyFrame)
        let harness = StreamingCallbackTestHarness(videoDecoder: video, audioDecoder: RecordingStreamingAudioDecoder())
        var borrowedBytes = [UInt8](repeating: 0xCC, count: 4_096)
        borrowedBytes.replaceSubrange(0..<6, with: [0, 0, 1, 0x65, 0xAA, 0xBB])
        let expectedBytes = Data(borrowedBytes)

        let result = harness.videoFrame(
            data: &borrowedBytes,
            frameNumber: 42,
            frameType: 1,
            hostProcessingLatencyTenthsOfMillisecond: 91,
            receiveTimeMicroseconds: 1_001,
            enqueueTimeMicroseconds: 1_002,
            presentationTimeMicroseconds: 1_003,
            rtpTimestamp: 90_090,
            isHDR: true,
            colorSpace: 2
        )
        borrowedBytes[4] = 0

        XCTAssertEqual(result, -1)
        XCTAssertEqual(video.frame?.data, expectedBytes)
        XCTAssertEqual(video.frameDataAddress, harness.lastVideoFrameAllocationAddress)
        XCTAssertEqual(video.frame?.frameNumber, 42)
        XCTAssertEqual(video.frame?.isKeyFrame, true)
        XCTAssertEqual(video.frame?.hostProcessingLatencyTenthsOfMillisecond, 91)
        XCTAssertEqual(video.frame?.receiveTimeMicroseconds, 1_001)
        XCTAssertEqual(video.frame?.enqueueTimeMicroseconds, 1_002)
        XCTAssertEqual(video.frame?.presentationTimeMicroseconds, 1_003)
        XCTAssertEqual(video.frame?.rtpTimestamp, 90_090)
        XCTAssertEqual(video.frame?.isHDR, true)
        XCTAssertEqual(video.frame?.colorSpace, 2)
    }

    func testPreparedVideoFramePreservesFinalStorageAndPayloadFormat() {
        let video = RecordingStreamingVideoDecoder()
        let harness = StreamingCallbackTestHarness(
            videoDecoder: video,
            audioDecoder: RecordingStreamingAudioDecoder()
        )
        var bytes = [UInt8](repeating: 0xA5, count: 4_096)
        bytes.replaceSubrange(0..<11, with: [0, 0, 0, 2, 0x67, 0x64, 0, 0, 0, 1, 0x65])

        XCTAssertEqual(harness.preparedVideoFrame(
            data: &bytes,
            payloadFormat: .videoToolboxLengthPrefixed,
            frameNumber: 43,
            frameType: 1
        ), 0)
        XCTAssertEqual(video.frame?.payloadFormat, .videoToolboxLengthPrefixed)
        XCTAssertEqual(video.frameDataAddress, harness.lastVideoFrameAllocationAddress)
        XCTAssertEqual(video.frame?.data, Data(bytes))
    }

    func testVideoLifecycleMapsStartStopAndCleanup() {
        let video = RecordingStreamingVideoDecoder()
        let harness = StreamingCallbackTestHarness(videoDecoder: video, audioDecoder: RecordingStreamingAudioDecoder())

        harness.videoStart()
        harness.videoStop()
        harness.videoCleanup()

        XCTAssertEqual(video.lifecycle, [.start, .stop, .cleanup])
    }

    func testHDRModeCopiesSunshineStaticMetadataBeforePublishingEvent() {
        let video = RecordingStreamingVideoDecoder()
        let events = LockedStreamingRecorder<StreamingEvent>()
        let harness = StreamingCallbackTestHarness(
            videoDecoder: video,
            audioDecoder: RecordingStreamingAudioDecoder(),
            eventHandler: { events.append($0) }
        )
        let metadata = StreamingHDRMetadata(
            redX: 35_400,
            redY: 14_600,
            greenX: 8_500,
            greenY: 39_850,
            blueX: 6_550,
            blueY: 2_300,
            whiteX: 15_635,
            whiteY: 16_450,
            maximumDisplayLuminanceNits: 1_000,
            minimumDisplayLuminanceTenThousandthsOfNit: 50,
            maximumContentLightLevelNits: 900,
            maximumFrameAverageLightLevelNits: 400,
            maximumFullFrameLuminanceNits: 600
        )

        harness.hdrMode(enabled: true, metadata: metadata)

        XCTAssertEqual(video.hdrMode?.enabled, true)
        XCTAssertEqual(video.hdrMode?.metadata, metadata)
        XCTAssertEqual(events.values, [.hdrMode(enabled: true, metadata: metadata)])
    }

    func testClientMicrophoneGenerationCopiesOwnedNegotiationValues() {
        let events = LockedStreamingRecorder<StreamingEvent>()
        let harness = StreamingCallbackTestHarness(
            videoDecoder: RecordingStreamingVideoDecoder(),
            audioDecoder: RecordingStreamingAudioDecoder(),
            eventHandler: { events.append($0) }
        )
        let generation = StreamingClientMicrophoneGeneration(
            sessionID: Data((0..<16).map(UInt8.init)),
            salt: Data((16..<32).map(UInt8.init)),
            serverPort: 48_012,
            clientPort: 55_000,
            remoteAddress: "fe80::1234%7"
        )

        harness.clientMicrophoneGeneration(generation)

        XCTAssertEqual(events.values, [.clientMicrophoneGeneration(generation)])
    }

    func testClientMicrophoneNegotiationIsOptInWithNoImplicitPort() {
        var configuration = StreamingConfiguration(address: "127.0.0.1", serverAppVersion: "7.1.431.0")
        XCTAssertFalse(configuration.clientMicrophoneRequested)
        XCTAssertEqual(configuration.clientMicrophoneClientPort, 0)

        configuration.clientMicrophoneRequested = true
        configuration.clientMicrophoneClientPort = 55_000
        XCTAssertTrue(configuration.clientMicrophoneRequested)
        XCTAssertEqual(configuration.clientMicrophoneClientPort, 55_000)
    }

    func testAudioInitMapsOpusFormatAndReturnValue() {
        let audio = RecordingStreamingAudioDecoder(configurationResult: false)
        let harness = StreamingCallbackTestHarness(videoDecoder: RecordingStreamingVideoDecoder(), audioDecoder: audio)

        let result = harness.audioInit(
            audioConfiguration: 0x063F_08CA,
            sampleRate: 48_000,
            channelCount: 8,
            streamCount: 5,
            coupledStreamCount: 3,
            samplesPerFrame: 240,
            mapping: [0, 1, 4, 5, 2, 3, 6, 7],
            flags: 0x55
        )

        XCTAssertEqual(result, -1)
        XCTAssertEqual(audio.format?.audioConfiguration, 0x063F_08CA)
        XCTAssertEqual(audio.format?.sampleRate, 48_000)
        XCTAssertEqual(audio.format?.channelCount, 8)
        XCTAssertEqual(audio.format?.streamCount, 5)
        XCTAssertEqual(audio.format?.coupledStreamCount, 3)
        XCTAssertEqual(audio.format?.samplesPerFrame, 240)
        XCTAssertEqual(audio.format?.mapping, [0, 1, 4, 5, 2, 3, 6, 7])
        XCTAssertEqual(audio.format?.flags, 0x55)
    }

    func testAudioPacketCopiesBorrowedBytes() {
        let audio = RecordingStreamingAudioDecoder()
        let harness = StreamingCallbackTestHarness(videoDecoder: RecordingStreamingVideoDecoder(), audioDecoder: audio)
        var borrowedBytes: [UInt8] = [0xF8, 0xFF, 0xFE, 1, 2]

        harness.audioPacket(data: &borrowedBytes)
        borrowedBytes[3] = 0

        XCTAssertEqual(audio.packet?.data, Data([0xF8, 0xFF, 0xFE, 1, 2]))
    }

    func testAudioPacketPreservesPacketLossConcealment() {
        let audio = RecordingStreamingAudioDecoder()
        let harness = StreamingCallbackTestHarness(
            videoDecoder: RecordingStreamingVideoDecoder(),
            audioDecoder: audio
        )
        var missingPacket: [UInt8] = []

        harness.audioPacket(data: &missingPacket)

        XCTAssertEqual(audio.packet?.data, Data())
    }

    func testAudioLifecycleMapsStartStopAndCleanup() {
        let audio = RecordingStreamingAudioDecoder()
        let harness = StreamingCallbackTestHarness(videoDecoder: RecordingStreamingVideoDecoder(), audioDecoder: audio)

        harness.audioStart()
        harness.audioStop()
        harness.audioCleanup()

        XCTAssertEqual(audio.lifecycle, [.start, .stop, .cleanup])
    }

    func testTerminationMapsEventAndCompletesSignal() async {
        let events = LockedStreamingRecorder<StreamingEvent>()
        let harness = StreamingCallbackTestHarness(
            videoDecoder: RecordingStreamingVideoDecoder(),
            audioDecoder: RecordingStreamingAudioDecoder(),
            eventHandler: { events.append($0) }
        )

        harness.connectionTerminated(code: -77)
        let code = await harness.waitForTermination()

        XCTAssertEqual(events.values, [.connectionTerminated(code: -77)])
        XCTAssertEqual(code, -77)
    }
}

private enum StreamingLifecycleCall: Equatable {
    case start
    case stop
    case cleanup
}

private final class RecordingStreamingVideoDecoder: VideoDecoding, HDRMetadataReceiving, @unchecked Sendable {
    private let lock = NSLock()
    private let configurationResult: Bool
    private let frameResult: VideoFrameDisposition
    private var storedFormat: VideoStreamFormat?
    private var storedFrame: CompressedVideoFrame?
    private var storedFrameDataAddress: UInt?
    private var storedLifecycle: [StreamingLifecycleCall] = []
    private var storedHDRMode: (enabled: Bool, metadata: StreamingHDRMetadata?)?

    init(configurationResult: Bool = true, frameResult: VideoFrameDisposition = .accepted) {
        self.configurationResult = configurationResult
        self.frameResult = frameResult
    }

    var format: VideoStreamFormat? { lock.withLock { storedFormat } }
    var frame: CompressedVideoFrame? { lock.withLock { storedFrame } }
    var frameDataAddress: UInt? { lock.withLock { storedFrameDataAddress } }
    var lifecycle: [StreamingLifecycleCall] { lock.withLock { storedLifecycle } }
    var hdrMode: (enabled: Bool, metadata: StreamingHDRMetadata?)? { lock.withLock { storedHDRMode } }

    func configure(format: VideoStreamFormat) -> Bool {
        lock.withLock { storedFormat = format }
        return configurationResult
    }

    func start() { lock.withLock { storedLifecycle.append(.start) } }
    func stop() { lock.withLock { storedLifecycle.append(.stop) } }
    func cleanUp() { lock.withLock { storedLifecycle.append(.cleanup) } }
    func setHDRMode(enabled: Bool, metadata: StreamingHDRMetadata?) {
        lock.withLock { storedHDRMode = (enabled, metadata) }
    }

    func submit(frame: CompressedVideoFrame) -> VideoFrameDisposition {
        let address = frame.data.withUnsafeBytes { bytes in
            bytes.baseAddress.map(UInt.init(bitPattern:))
        }
        lock.withLock {
            storedFrame = frame
            storedFrameDataAddress = address
        }
        return frameResult
    }
}

private final class RecordingStreamingAudioDecoder: AudioDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private let configurationResult: Bool
    private var storedFormat: OpusStreamFormat?
    private var storedPacket: CompressedAudioPacket?
    private var storedLifecycle: [StreamingLifecycleCall] = []

    init(configurationResult: Bool = true) {
        self.configurationResult = configurationResult
    }

    var format: OpusStreamFormat? { lock.withLock { storedFormat } }
    var packet: CompressedAudioPacket? { lock.withLock { storedPacket } }
    var lifecycle: [StreamingLifecycleCall] { lock.withLock { storedLifecycle } }

    func configure(format: OpusStreamFormat) -> Bool {
        lock.withLock { storedFormat = format }
        return configurationResult
    }

    func start() { lock.withLock { storedLifecycle.append(.start) } }
    func stop() { lock.withLock { storedLifecycle.append(.stop) } }
    func cleanUp() { lock.withLock { storedLifecycle.append(.cleanup) } }
    func submit(packet: CompressedAudioPacket) { lock.withLock { storedPacket = packet } }
}

private final class LockedStreamingRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] { lock.withLock { storage } }
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
}
