import AudioToolbox
import CryptoKit
import Foundation
import XCTest
import UmbraCore
import UmbraNetworking
import UmbraServices
import UmbraStreaming
@testable import UmbraIntegration
@testable import UmbraMedia
import UmbraProtocolV3
@testable import UmbraQUICTransport

final class ProtocolV3AudioCompositionTests: XCTestCase {
    private static let fixtureSHA256 = "34d30f842b14ef5fec2cee4570dacb38487d8d19dc4ab090cbc563e3f6d6cea7"

    func testLumenScheduledDatagramsReachRealOpusAndAudioQueueRenderer() throws {
        let loaded = try loadFixture()
        XCTAssertEqual(loaded.fixture.schema, "lumen-protocol-v3-audio-datagram/1")
        XCTAssertEqual(sha256(loaded.data), Self.fixtureSHA256)
        XCTAssertEqual(loaded.fixture.captureTimeMicroseconds, 123_456_789)
        XCTAssertEqual(loaded.fixture.connectionId, 1)
        XCTAssertEqual(loaded.fixture.maximumDatagramBytes, 1_152)
        XCTAssertEqual(loaded.fixture.profile, "quality")
        XCTAssertFalse(loaded.fixture.fullDatagramArtifactPortable)
        XCTAssertFalse(loaded.fixture.fullDatagramArtifactNote.isEmpty)
        XCTAssertEqual(loaded.fixture.vectors.map(\.name), ["stereo", "surround51", "surround71"])
        let sessionID = try Data(fixtureHex: loaded.fixture.sessionIdHex)

        for vector in loaded.fixture.vectors {
            let environment = try FixtureEnvironment(fixture: loaded.fixture, vector: vector)
            XCTAssertEqual(environment.hardware.enqueueCount, 3, vector.name)

            let rawDatagram = try Data(fixtureHex: vector.scheduledDatagramHex)
            let scheduledPrefix = try Data(fixtureHex: vector.scheduledPrefixHex)
            let headerSize = Int(read(UInt16.self, rawDatagram, at: 8))
            XCTAssertEqual(headerSize, 44, vector.name)
            XCTAssertEqual(rawDatagram.count, vector.totalBytes, vector.name)
            XCTAssertEqual(rawDatagram.count, headerSize + 48 + vector.opusBytes, vector.name)
            XCTAssertEqual(Data(rawDatagram.prefix(scheduledPrefix.count)), scheduledPrefix, vector.name)
            XCTAssertEqual(Data(rawDatagram[12..<28]), sessionID, vector.name)
            XCTAssertEqual(rawDatagram[5], vector.parsed.channel, vector.name)
            XCTAssertEqual(rawDatagram[6], vector.parsed.kind, vector.name)
            XCTAssertEqual(read(UInt64.self, rawDatagram, at: 28), vector.parsed.sequence, vector.name)
            XCTAssertEqual(read(UInt64.self, rawDatagram, at: 36), vector.parsed.objectId, vector.name)
            XCTAssertEqual(
                read(UInt64.self, rawDatagram, at: headerSize),
                vector.parsed.captureTimeMicroseconds,
                vector.name
            )
            XCTAssertEqual(vector.parsed.captureTimeMicroseconds, loaded.fixture.captureTimeMicroseconds)
            XCTAssertEqual(
                read(UInt64.self, rawDatagram, at: headerSize + 8),
                vector.parsed.firstSamplePosition,
                vector.name
            )
            XCTAssertEqual(vector.parsed.firstSamplePosition, vector.firstSamplePosition)
            XCTAssertEqual(
                read(UInt32.self, rawDatagram, at: headerSize + 16),
                vector.parsed.audioGeneration,
                vector.name
            )
            XCTAssertEqual(vector.parsed.audioGeneration, vector.audioGeneration)
            XCTAssertEqual(
                read(UInt16.self, rawDatagram, at: headerSize + 20),
                UInt16(vector.parsed.frameSamples),
                vector.name
            )
            XCTAssertEqual(rawDatagram[headerSize + 22], UInt8(vector.parsed.channels), vector.name)
            XCTAssertEqual(rawDatagram[headerSize + 23], vector.parsed.layout, vector.name)
            XCTAssertEqual(rawDatagram[headerSize + 26], UInt8(vector.parsed.streams), vector.name)
            XCTAssertEqual(rawDatagram[headerSize + 27], UInt8(vector.parsed.coupledStreams), vector.name)
            XCTAssertEqual(
                Array(rawDatagram[(headerSize + 28)..<(headerSize + 36)]),
                vector.mapping,
                vector.name
            )
            XCTAssertEqual(
                read(UInt32.self, rawDatagram, at: headerSize + 36),
                vector.parsed.bitrateBps,
                vector.name
            )
            XCTAssertEqual(rawDatagram[headerSize + 25] & 0x02 != 0, vector.discontinuity, vector.name)

            environment.feed(rawDatagram)

            let received = environment.coordinator.statistics().media
            XCTAssertEqual(received.audioPacketsReceived, 1, vector.name)
            XCTAssertEqual(received.audioConcealmentFrames, 0, vector.name)
            XCTAssertEqual(received.audioDiscontinuities, 0, vector.name)
            XCTAssertEqual(received.pendingAudioPackets, 0, vector.name)
            XCTAssertEqual(received.audioRenderer?.enqueuedBuffers, 1, vector.name)

            XCTAssertTrue(environment.renderer.invokeOutputCallbackForTesting(), vector.name)
            let rendered = environment.hardware.latestEnqueuedSamples
            XCTAssertEqual(rendered.count, vector.frameSamples * vector.channels, vector.name)
            XCTAssertTrue(rendered.allSatisfy(\.isFinite), vector.name)
            XCTAssertTrue(environment.renderer.invokeOutputCallbackForTesting(), vector.name)
            let ring = environment.renderer.outputRingSnapshotForTesting
            XCTAssertEqual(ring.callbackCount, 2, vector.name)
            XCTAssertEqual(ring.renderedRealSamples, UInt64(vector.frameSamples * vector.channels), vector.name)
            XCTAssertEqual(ring.playedPackets, 1, vector.name)
            XCTAssertEqual(environment.hardware.enqueueCount, 5, vector.name)
            XCTAssertEqual(environment.coordinator.statistics().media.audioRenderer?.playedBuffers, 1, vector.name)

            environment.stopTwice()
            XCTAssertEqual(environment.hardware.stopCount, 1, vector.name)
            XCTAssertEqual(environment.hardware.disposeCount, 1, vector.name)
            XCTAssertTrue(environment.failures.values.isEmpty, vector.name)
        }
    }

    private func loadFixture() throws -> (fixture: AudioDatagramFixture, data: Data) {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "lumen_protocol_v3_audio_datagrams_4e2f9537",
            withExtension: "json"
        ))
        let data = try Data(contentsOf: url)
        return (try JSONDecoder().decode(AudioDatagramFixture.self, from: data), data)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func read<T: FixedWidthInteger>(_ type: T.Type, _ data: Data, at offset: Int) -> T {
        data[offset..<(offset + MemoryLayout<T>.size)].reduce(0) { ($0 << 8) | T($1) }
    }
}

private final class FixtureEnvironment {
    let hardware: FixtureAudioQueueHardware
    let renderer: AudioQueuePCMRenderer
    let coordinator: ProtocolV3SessionMediaCoordinator
    let failures = FixtureFailureRecorder()

    private let network: FixtureQUICNetworkAdapter
    private let core: QUICTransportCore
    private var stopped = false

    init(
        fixture: AudioDatagramFixture,
        vector: AudioDatagramFixture.Vector
    ) throws {
        let layout = try Self.layout(channels: vector.channels)
        hardware = FixtureAudioQueueHardware()
        renderer = AudioQueuePCMRenderer(
            configuration: PCMRendererConfiguration(
                sampleRate: Double(vector.sampleRate),
                layout: layout,
                maximumQueuedBuffers: 8,
                maximumQueuedDuration: 0.050,
                outputBufferDuration: 0.005,
                minimumPreRollDuration: 0.005,
                muteWhileInactive: false
            ),
            operations: hardware.makeOperations(),
            outputThreadFactory: { [hardware] _ in
                FixtureAudioQueueOutputThread(queue: hardware.queue)
            }
        )
        let provider = AppleStreamingMediaProvider(
            capabilities: Self.capabilities(channels: vector.channels),
            renderer: FixtureVideoRenderer(),
            audioRenderer: renderer
        )
        let pipeline = try provider.makePipeline(for: Self.bootstrap(vector: vector))
        let sessionID = try Data(fixtureHex: fixture.sessionIdHex)
        let selection = Self.startResponse(sessionID: sessionID, vector: vector)
        let media = try ProtocolV3MediaPipelineAdapter(
            pipeline: pipeline,
            mode: .quality,
            startResponseFields: selection
        )
        coordinator = ProtocolV3SessionMediaCoordinator(
            control: FixtureMediaControl(),
            media: media,
            failureHandler: { [failures] in failures.append($0) }
        )
        coordinator.handle(.startAccepted(sessionID: sessionID, fields: selection))
        coordinator.handle(.controlMessage(
            type: 0x0142,
            requestID: 2,
            fields: [
                1: .bytes(sessionID),
                2: .unsigned(UInt64(vector.audioGeneration)),
                3: selection[12]!,
                4: .unsigned(vector.firstSamplePosition),
            ]
        ))

        network = FixtureQUICNetworkAdapter()
        core = try QUICTransportCore(
            configuration: QUICTransportConfiguration(
                endpoint: .init(host: "127.0.0.1", port: 48_030),
                expectedLeafSPKISHA256: Data(repeating: 0, count: 32),
                mode: .quality
            ),
            adapter: network
        )
        let ready = DispatchSemaphore(value: 0)
        core.eventHandler = { [coordinator] event in
            if case .stateChanged(.ready) = event {
                ready.signal()
            }
            coordinator.handle(.transport(event))
        }
        core.authenticationHandler = { _ in }
        try core.start()
        network.emit(.peerVerificationStarted)
        network.emit(.peerVerified(Data(repeating: 0, count: 32)))
        network.emit(.ready(
            alpn: QUICTransportConfiguration.applicationProtocol,
            usableDatagramByteCount: fixture.maximumDatagramBytes
        ))
        core.applicationHelloDidComplete(success: true)
        core.applicationAuthenticationDidComplete(success: true)
        guard ready.wait(timeout: .now() + 1) == .success else {
            throw FixtureCompositionError.transportDidNotBecomeReady
        }
        try core.setActiveSessionID(sessionID)
        guard failures.values.isEmpty else {
            throw FixtureCompositionError.mediaConfigurationFailed
        }
    }

    deinit {
        if !stopped {
            coordinator.stopAndCleanUp(sendMicrophoneEnd: false)
        }
        core.cancel()
    }

    func feed(_ rawDatagram: Data) {
        network.emit(.datagram(rawDatagram))
    }

    func stopTwice() {
        coordinator.stopAndCleanUp(sendMicrophoneEnd: false)
        coordinator.stopAndCleanUp(sendMicrophoneEnd: false)
        stopped = true
    }

    private static func layout(channels: Int) throws -> AudioOutputLayout {
        switch channels {
        case 2: .stereo
        case 6: .surround51
        case 8: .surround71
        default: throw FixtureCompositionError.unsupportedChannels
        }
    }

    private static func audioConfiguration(channels: Int) throws -> AudioConfiguration {
        switch channels {
        case 2: .stereo
        case 6: .surround51
        case 8: .surround71
        default: throw FixtureCompositionError.unsupportedChannels
        }
    }

    private static func capabilities(channels: Int) -> AppleStreamingCapabilities {
        AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: false,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: UInt32(channels)
        )
    }

    private static func bootstrap(vector: AudioDatagramFixture.Vector) throws -> StreamBootstrap {
        var preferences = StreamingPreferences.default
        preferences.audioConfiguration = try audioConfiguration(channels: vector.channels)
        preferences.optimizationMode = .quality
        preferences.muteOnFocusLoss = false
        var host = StreamHost(
            uuid: "fixture-host",
            name: "Fixture Host",
            activeAddress: NetworkEndpoint(hostname: "127.0.0.1"),
            activeAddressReachability: .lan,
            gfeVersion: "3.28",
            appVersion: "7.1.431",
            codecSupport: HostCodecSupport(rawValue: 0x201)
        )
        let application = StreamApplication(id: 7, name: "Fixture")
        host.applications = [application]
        return StreamBootstrap(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            host: host,
            application: application,
            preferences: preferences,
            rtspSessionURL: URL(string: "rtsp://127.0.0.1/session"),
            remoteInputCredentials: try RemoteInputCredentials(
                key: Data(0..<16),
                initializationVector: Data(16..<32)
            )
        )
    }

    private static func startResponse(
        sessionID: Data,
        vector: AudioDatagramFixture.Vector
    ) -> [UInt64: ProtocolV3CBORValue] {
        let video: [UInt64: ProtocolV3CBORValue] = [
            1: .unsigned(1), 2: .unsigned(1), 3: .unsigned(8), 4: .unsigned(1),
            5: .unsigned(1), 6: .unsigned(1), 7: .unsigned(1), 8: .unsigned(0),
            9: .unsigned(0), 10: .unsigned(1),
        ]
        let audio: [UInt64: ProtocolV3CBORValue] = [
            1: .unsigned(1),
            2: .unsigned(UInt64(vector.sampleRate)),
            3: .unsigned(UInt64(vector.channels)),
            4: .unsigned(UInt64(vector.frameSamples)),
            5: .unsigned(UInt64(vector.layout)),
            6: .unsigned(UInt64(vector.streams)),
            7: .unsigned(UInt64(vector.coupledStreams)),
            8: .bytes(Data(vector.mapping.prefix(vector.channels))),
            9: .unsigned(UInt64(vector.bitrateBps)),
        ]
        let presentation: [UInt64: ProtocolV3CBORValue] = [
            1: .unsigned(3), 2: .unsigned(2), 3: .unsigned(0), 4: .unsigned(0),
            5: .unsigned(250_000),
        ]
        return [
            3: .bytes(sessionID), 5: .map(video), 6: .unsigned(1_920), 7: .unsigned(1_080),
            8: .unsigned(60), 9: .unsigned(1), 11: .unsigned(1_152), 12: .map(audio),
            13: .null, 14: .unsigned(1), 15: .unsigned(UInt64(vector.audioGeneration)),
            16: .unsigned(1), 18: .map(presentation), 23: .null,
        ]
    }
}

private struct AudioDatagramFixture: Decodable {
    struct Vector: Decodable {
        struct Parsed: Decodable {
            let channel: UInt8
            let kind: UInt8
            let sequence: UInt64
            let objectId: UInt64
            let captureTimeMicroseconds: UInt64
            let firstSamplePosition: UInt64
            let audioGeneration: UInt32
            let frameSamples: Int
            let channels: Int
            let layout: UInt8
            let streams: Int
            let coupledStreams: Int
            let bitrateBps: UInt32
        }

        let name: String
        let audioGeneration: UInt32
        let sampleRate: Int
        let frameSamples: Int
        let channels: Int
        let layout: UInt8
        let streams: Int
        let coupledStreams: Int
        let mapping: [UInt8]
        let bitrateBps: UInt32
        let firstSamplePosition: UInt64
        let discontinuity: Bool
        let opusBytes: Int
        let scheduledDatagramHex: String
        let scheduledPrefixHex: String
        let totalBytes: Int
        let parsed: Parsed
    }

    let schema: String
    let captureTimeMicroseconds: UInt64
    let connectionId: UInt64
    let maximumDatagramBytes: Int
    let profile: String
    let sessionIdHex: String
    let vectors: [Vector]
    let fullDatagramArtifactPortable: Bool
    let fullDatagramArtifactNote: String
}

private enum FixtureCompositionError: Error {
    case invalidHex
    case mediaConfigurationFailed
    case transportDidNotBecomeReady
    case unsupportedChannels
}

private final class FixtureFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var values: [String] { lock.withLock { stored } }
    func append(_ error: Error) { lock.withLock { stored.append(String(describing: error)) } }
}

private final class FixtureMediaControl: ProtocolV3SessionMediaControlling, @unchecked Sendable {
    func sendControlRequest(
        type: UInt16,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws -> UInt64 { 1 }

    func sendControlResponse(
        type: UInt16,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue],
        isError: Bool
    ) throws {}

    func sendDatagram(
        lane: QUICSemanticLane,
        sessionID: Data,
        channel: UInt8,
        kind: UInt8,
        flags: UInt8,
        objectID: UInt64,
        payload: Data,
        deadlineNanoseconds: UInt64?,
        supersessionKey: UInt64?
    ) {}
}

private final class FixtureQUICNetworkAdapter: QUICNetworkAdapter, @unchecked Sendable {
    var eventHandler: (@Sendable (QUICNetworkAdapterEvent) -> Void)?

    func start(configuration: QUICTransportConfiguration) {}
    func submit(
        _ submission: QUICNetworkSubmission,
        completion: @escaping @Sendable (String?) -> Void
    ) { completion(nil) }
    func setInboundBulkEnabled(_ enabled: Bool) {}
    func decideInboundBulk(requestID: UInt64, objectID: UInt64, accept: Bool) {}
    func cancel() {}

    func emit(_ event: QUICNetworkAdapterEvent) {
        eventHandler?(event)
    }
}

private final class FixtureVideoRenderer: UmbraMedia.MetalVideoRendering, @unchecked Sendable {
    func enqueue(_ frame: UmbraMedia.DecodedVideoFrame) {}
    func flush() {}
}

private final class FixtureAudioQueueOutputThread: AudioQueueOutputThread, @unchecked Sendable {
    private let queue: AudioQueueRef

    init(queue: AudioQueueRef) {
        self.queue = queue
    }

    func createOutput(
        format: AudioStreamBasicDescription,
        userData: UnsafeMutableRawPointer,
        createOutput: @escaping AudioQueueOperations.CreateOutput
    ) -> (OSStatus, AudioQueueRef?) {
        (noErr, queue)
    }

    func promoteThreadAfterSuccessfulStart() -> AudioQueueOutputThreadPromotionResult {
        .applied
    }

    func stop() {}
}

private final class FixtureAudioQueueHardware: @unchecked Sendable {
    private struct BufferStorage {
        let buffer: AudioQueueBufferRef
        let audioData: UnsafeMutableRawPointer
    }

    private let lock = NSLock()
    let queue = AudioQueueRef(bitPattern: 0xA11D10)!
    private var buffers: [BufferStorage] = []
    private var enqueuedSamples: [[Float]] = []
    private var storedStopCount = 0
    private var storedDisposeCount = 0
    private var running = false

    deinit {
        for storage in lock.withLock({ buffers }) {
            storage.buffer.deinitialize(count: 1)
            storage.buffer.deallocate()
            storage.audioData.deallocate()
        }
    }

    var enqueueCount: Int { lock.withLock { enqueuedSamples.count } }
    var latestEnqueuedSamples: [Float] { lock.withLock { enqueuedSamples.last ?? [] } }
    var stopCount: Int { lock.withLock { storedStopCount } }
    var disposeCount: Int { lock.withLock { storedDisposeCount } }

    func makeOperations() -> AudioQueueOperations {
        AudioQueueOperations(
            assignCurrentDefaultOutputDevice: { _ in },
            applyChannelLayout: { _, _ in },
            allocateBuffer: { [self] _, byteCapacity in
                let audioData = UnsafeMutableRawPointer.allocate(
                    byteCount: Int(byteCapacity),
                    alignment: MemoryLayout<Float>.alignment
                )
                let buffer = AudioQueueBufferRef.allocate(capacity: 1)
                buffer.initialize(to: AudioQueueBuffer(
                    mAudioDataBytesCapacity: byteCapacity,
                    mAudioData: audioData,
                    mAudioDataByteSize: 0,
                    mUserData: nil,
                    mPacketDescriptionCapacity: 0,
                    mPacketDescriptions: nil,
                    mPacketDescriptionCount: 0
                ))
                lock.withLock { buffers.append(.init(buffer: buffer, audioData: audioData)) }
                return (noErr, buffer)
            },
            enqueueBuffer: { [self] _, buffer in
                let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
                let samples = Array(UnsafeBufferPointer(
                    start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self),
                    count: count
                ))
                lock.withLock { enqueuedSamples.append(samples) }
                return noErr
            },
            prime: { _, frames in frames = 0; return noErr },
            start: { [self] _ in lock.withLock { running = true }; return noErr },
            isRunning: { [self] _ in lock.withLock { running } },
            reset: { _ in noErr },
            stop: { [self] _ in
                lock.withLock {
                    storedStopCount += 1
                    running = false
                }
                return noErr
            },
            dispose: { [self] _ in
                lock.withLock { storedDisposeCount += 1 }
                return noErr
            },
            setVolume: { _, _ in noErr }
        )
    }
}

private extension Data {
    init(fixtureHex text: String) throws {
        guard text.count.isMultiple(of: 2) else { throw FixtureCompositionError.invalidHex }
        self.init()
        reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else {
                throw FixtureCompositionError.invalidHex
            }
            append(byte)
            index = next
        }
    }
}
