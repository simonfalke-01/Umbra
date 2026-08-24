import Darwin
import Foundation
import XCTest
@testable import UmbraMicrophone

final class MicrophoneCaptureAndAuthorizationTests: XCTestCase {
    func testRingBuildsOnlyExactTwentyMillisecondFramesOffCallback() throws {
        let ring = MicrophoneSampleRing(capacity: 1_920)
        ring.reset(accepting: true)
        let first = [Float](repeating: 0.25, count: 480)
        let second = [Float](repeating: -0.5, count: 480)

        first.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(ring.take(), .empty)
        second.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }

        guard case let .frame(frame) = ring.take() else {
            return XCTFail("Expected one complete frame")
        }
        XCTAssertEqual(frame.count, 960)
        XCTAssertEqual(Array(frame.prefix(480)), first)
        XCTAssertEqual(Array(frame.suffix(480)), second)
        XCTAssertEqual(ring.take(), .empty)
    }

    func testOverflowDropsPartialTimelineAndPublishesResetBarrierFirst() {
        let ring = MicrophoneSampleRing(capacity: 960)
        ring.reset(accepting: true)
        let frame = [Float](repeating: 1, count: 960)
        let extra: [Float] = [2]
        frame.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
        extra.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }

        XCTAssertEqual(ring.take(), .discontinuity)
        XCTAssertEqual(ring.take(), .empty)
    }

    func testTerminalCaptureFailureStopsAcceptanceAndPrecedesBufferedAudio() {
        let ring = MicrophoneSampleRing(capacity: 1_920)
        ring.reset(accepting: true)
        let frame = [Float](repeating: 1, count: 960)
        frame.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }

        ring.markTerminalFailure()

        XCTAssertFalse(ring.isAccepting)
        XCTAssertEqual(ring.take(), .failure)
    }

    func testAtomicSPSCHandoffPreservesEveryFrameInOrder() {
        let frameCount = 300
        let ring = MicrophoneSampleRing(capacity: 960 * frameCount)
        ring.reset(accepting: true)
        let produced = DispatchGroup()
        let consumed = DispatchGroup()
        let values = LockedFloatValues()

        produced.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            for frameIndex in 0..<frameCount {
                let frame = [Float](repeating: Float(frameIndex), count: 960)
                frame.withUnsafeBufferPointer {
                    _ = ring.writeForTesting($0.baseAddress!, count: $0.count)
                }
            }
            produced.leave()
        }

        consumed.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            while values.count < frameCount {
                if case let .frame(frame) = ring.take() {
                    values.append(frame[0])
                } else {
                    Thread.sleep(forTimeInterval: 0.000_1)
                }
            }
            consumed.leave()
        }

        XCTAssertEqual(produced.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(consumed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(values.values, (0..<frameCount).map(Float.init))
    }

    func testDeniedPermissionNeverCreatesCaptureOrSocketPreparation() async {
        let authorization = FakeAuthorization(status: .denied)
        let captureFactory = CountingCaptureFactory()
        let preparer = SystemClientMicrophonePreparer(
            authorization: authorization,
            captureFactory: captureFactory
        )

        do {
            _ = try await preparer.prepare(host: "127.0.0.1")
            XCTFail("Denied permission unexpectedly prepared microphone forwarding")
        } catch {
            XCTAssertEqual(
                error as? ClientMicrophonePreparationError,
                .permissionDenied(.denied)
            )
        }
        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertEqual(captureFactory.makeCount, 0)
    }

    func testTerminalCaptureFailureImmediatelyStopsCaptureAndSocketOwnership() throws {
        let endpoint = try UDPTestEndpoint()
        defer { endpoint.close() }
        let sender = try ConnectedMicrophoneUDPSender(host: "127.0.0.1")
        let capture = ControllableCapture()
        let forwarder = ClientMicrophoneForwarder(sender: sender, capture: capture)
        let warnings = LockedStringValues()
        try forwarder.begin(
            generation: ClientMicrophoneGenerationDescriptor(
                sessionID: Data(repeating: 0x11, count: 16),
                salt: Data(repeating: 0x22, count: 16),
                serverPort: endpoint.port,
                clientPort: sender.localPort,
                remoteAddress: "127.0.0.1",
                rikey: Data(0..<16)
            ),
            warningHandler: { warnings.append($0) }
        )

        capture.fail(TestCaptureError.stopped)

        XCTAssertTrue(capture.stopped)
        XCTAssertEqual(warnings.values.count, 1)
        XCTAssertTrue(warnings.values[0].contains("Microphone forwarding stopped"))
        forwarder.finish()
        XCTAssertTrue(capture.stopped, "Final teardown remains idempotent after failure cleanup.")
    }

    func testCaptureStopRacingResourceCreationDisposesCreatedQueueBeforeBothReturn() throws {
        let resource = RecordingAudioQueueResource()
        let factory = BarrierAudioQueueResourceFactory(resource: resource)
        let capture = AudioQueueMicrophoneCapture(resourceFactory: factory)
        let startResult = LockedResult()
        let startGroup = DispatchGroup()
        startGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { startGroup.leave() }
            do {
                try capture.start(frameHandler: { _ in }, discontinuityHandler: {}, failureHandler: { _ in })
                startResult.set(nil)
            } catch {
                startResult.set(error)
            }
        }
        XCTAssertEqual(factory.waitUntilCreationStarted(), .success)

        let stopGroup = DispatchGroup()
        stopGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            capture.stop()
            stopGroup.leave()
        }
        XCTAssertEqual(stopGroup.wait(timeout: .now() + 0.02), .timedOut)
        factory.releaseCreation()

        XCTAssertEqual(startGroup.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(stopGroup.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(startResult.error as? AudioQueueMicrophoneCaptureError, .startCancelled)
        XCTAssertEqual(resource.startCount, 0)
        XCTAssertEqual(resource.disposeCount, 1)
        XCTAssertEqual(capture.lifecycleStateForTesting, .stopped)
    }

    func testCaptureCreatesAndDisposesFreshResourceAcrossTwoSessions() throws {
        let factory = RecordingAudioQueueResourceFactory()
        let capture = AudioQueueMicrophoneCapture(resourceFactory: factory)

        for _ in 0..<2 {
            try capture.start(frameHandler: { _ in }, discontinuityHandler: {}, failureHandler: { _ in })
            XCTAssertEqual(capture.lifecycleStateForTesting, .running)
            capture.stop()
            XCTAssertEqual(capture.lifecycleStateForTesting, .stopped)
        }

        XCTAssertEqual(factory.resources.count, 2)
        XCTAssertEqual(factory.resources.map(\.startCount), [1, 1])
        XCTAssertEqual(factory.resources.map(\.disposeCount), [1, 1])
    }

    func testForwarderFinishRacingCaptureStartIsABarrierAndSendsEnd() throws {
        let endpoint = try UDPTestEndpoint()
        defer { endpoint.close() }
        let sender = try ConnectedMicrophoneUDPSender(host: "::1")
        let capture = BarrierCapture()
        let forwarder = ClientMicrophoneForwarder(sender: sender, capture: capture)
        let descriptor = Self.descriptor(
            clientPort: sender.localPort,
            serverPort: endpoint.port,
            remoteAddress: "127.0.0.1"
        )
        let beginResult = LockedResult()
        let beginGroup = DispatchGroup()
        beginGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { beginGroup.leave() }
            do {
                try forwarder.begin(
                    generation: descriptor,
                    warningHandler: { _ in }
                )
                beginResult.set(nil)
            } catch {
                beginResult.set(error)
            }
        }
        XCTAssertEqual(capture.waitUntilStartEntered(), .success)

        let finishGroup = DispatchGroup()
        finishGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            forwarder.finish()
            finishGroup.leave()
        }

        XCTAssertEqual(beginGroup.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finishGroup.wait(timeout: .now() + 2), .success)
        XCTAssertNotNil(beginResult.error)
        XCTAssertTrue(capture.stopped)
        XCTAssertEqual(forwarder.lifecycleStateForTesting, .stopped)
        XCTAssertEqual(try endpoint.receive().type, .hello)
        XCTAssertEqual(try endpoint.receive().type, .end)
    }

    func testEndFailureWarnsAndStillClosesCaptureAndForwarder() throws {
        let endpoint = try UDPTestEndpoint()
        defer { endpoint.close() }
        let sender = try ConnectedMicrophoneUDPSender()
        let capture = ControllableCapture()
        let forwarder = ClientMicrophoneForwarder(sender: sender, capture: capture)
        let warnings = LockedStringValues()
        try forwarder.begin(
            generation: Self.descriptor(
                clientPort: sender.localPort,
                serverPort: endpoint.port,
                remoteAddress: "127.0.0.1"
            ),
            warningHandler: { warnings.append($0) }
        )
        _ = try endpoint.receive()

        sender.close()
        forwarder.finish()

        XCTAssertTrue(capture.stopped)
        XCTAssertEqual(forwarder.lifecycleStateForTesting, .stopped)
        XCTAssertEqual(warnings.values.count, 1)
        XCTAssertTrue(warnings.values[0].contains("END could not be sent"))
    }

    func testOpusDTXStateSendsAuthenticatedProtocolSilence() throws {
        let endpoint = try UDPTestEndpoint()
        defer { endpoint.close() }
        let sender = try ConnectedMicrophoneUDPSender()
        let capture = ControllableCapture()
        let encoder = ForcedDTXEncoder()
        let forwarder = ClientMicrophoneForwarder(
            sender: sender,
            capture: capture,
            encoderFactory: { encoder }
        )
        try forwarder.begin(
            generation: Self.descriptor(
                clientPort: sender.localPort,
                serverPort: endpoint.port,
                remoteAddress: "127.0.0.1"
            ),
            warningHandler: { _ in }
        )
        _ = try endpoint.receive()

        capture.emit(ClientMicrophonePCMFrame(samples: [Float](repeating: 0.25, count: 960)))
        let silence = try endpoint.receive()

        XCTAssertEqual(silence.type, .audio)
        XCTAssertEqual(silence.flags, LMC1Datagram.silenceFlag)
        XCTAssertTrue(silence.ciphertext.isEmpty)
        forwarder.finish()
    }

    func testSelectedNumericPeerOverridesPreparationHostnameAndKeepsClientPort() throws {
        let endpoint = try UDPTestEndpoint()
        defer { endpoint.close() }
        let sender = try ConnectedMicrophoneUDPSender(host: "::1")
        let originalPort = sender.localPort
        XCTAssertTrue(sender.preparedAddressFamiliesForTesting.contains(AF_INET))
        let capture = ControllableCapture()
        let forwarder = ClientMicrophoneForwarder(sender: sender, capture: capture)

        try forwarder.begin(
            generation: Self.descriptor(
                clientPort: originalPort,
                serverPort: endpoint.port,
                remoteAddress: "127.0.0.1"
            ),
            warningHandler: { _ in }
        )

        XCTAssertEqual(sender.localPort, originalPort)
        XCTAssertEqual(try endpoint.receive().type, .hello)
        forwarder.finish()
    }

    func testTwoForwardingSessionsOwnFreshGenerationCaptureAndSocketState() throws {
        let endpoint = try UDPTestEndpoint()
        defer { endpoint.close() }

        for sessionIndex in 0..<2 {
            let sender = try ConnectedMicrophoneUDPSender()
            let capture = ControllableCapture()
            let forwarder = ClientMicrophoneForwarder(sender: sender, capture: capture)
            var descriptor = Self.descriptor(
                clientPort: sender.localPort,
                serverPort: endpoint.port,
                remoteAddress: "127.0.0.1"
            )
            descriptor = ClientMicrophoneGenerationDescriptor(
                sessionID: Data(repeating: UInt8(0x11 + sessionIndex), count: 16),
                salt: descriptor.salt,
                serverPort: descriptor.serverPort,
                clientPort: descriptor.clientPort,
                remoteAddress: descriptor.remoteAddress,
                rikey: descriptor.rikey
            )
            try forwarder.begin(generation: descriptor, warningHandler: { _ in })
            let hello = try endpoint.receive()
            forwarder.finish()
            let end = try endpoint.receive()

            XCTAssertEqual(hello.packetSequence, 0)
            XCTAssertEqual(end.packetSequence, 1)
            XCTAssertTrue(capture.stopped)
            XCTAssertEqual(forwarder.lifecycleStateForTesting, .stopped)
        }
    }

    private static func descriptor(
        clientPort: UInt16,
        serverPort: UInt16,
        remoteAddress: String
    ) -> ClientMicrophoneGenerationDescriptor {
        ClientMicrophoneGenerationDescriptor(
            sessionID: Data(repeating: 0x11, count: 16),
            salt: Data(repeating: 0x22, count: 16),
            serverPort: serverPort,
            clientPort: clientPort,
            remoteAddress: remoteAddress,
            rikey: Data(0..<16)
        )
    }
}

private final class LockedFloatValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    var values: [Float] { lock.withLock { storage } }
    var count: Int { lock.withLock { storage.count } }
    func append(_ value: Float) { lock.withLock { storage.append(value) } }
}

private final class FakeAuthorization: ClientMicrophoneAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private let storedStatus: ClientMicrophoneAuthorizationStatus
    private var storedRequestCount = 0

    init(status: ClientMicrophoneAuthorizationStatus) {
        storedStatus = status
    }

    var requestCount: Int { lock.withLock { storedRequestCount } }
    func status() -> ClientMicrophoneAuthorizationStatus { storedStatus }
    func requestAuthorization() async -> ClientMicrophoneAuthorizationStatus {
        lock.withLock { storedRequestCount += 1 }
        return storedStatus
    }
}

private final class CountingCaptureFactory: ClientMicrophoneCaptureCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedMakeCount = 0
    var makeCount: Int { lock.withLock { storedMakeCount } }

    func makeCapture() -> any ClientMicrophoneCapturing {
        lock.withLock { storedMakeCount += 1 }
        return UnusedCapture()
    }
}

private final class UnusedCapture: ClientMicrophoneCapturing, @unchecked Sendable {
    func start(
        frameHandler: @escaping @Sendable (ClientMicrophonePCMFrame) -> Void,
        discontinuityHandler: @escaping @Sendable () -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws {}
    func stop() {}
}

private enum TestCaptureError: Error {
    case stopped
}

private final class ControllableCapture: ClientMicrophoneCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var frameHandler: (@Sendable (ClientMicrophonePCMFrame) -> Void)?
    private var storedStopped = false

    var stopped: Bool { lock.withLock { storedStopped } }

    func start(
        frameHandler: @escaping @Sendable (ClientMicrophonePCMFrame) -> Void,
        discontinuityHandler: @escaping @Sendable () -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        lock.withLock {
            self.frameHandler = frameHandler
            self.failureHandler = failureHandler
            storedStopped = false
        }
    }

    func stop() {
        lock.withLock {
            storedStopped = true
            frameHandler = nil
            failureHandler = nil
        }
    }

    func fail(_ error: Error) {
        lock.withLock { failureHandler }?(error)
    }

    func emit(_ frame: ClientMicrophonePCMFrame) {
        lock.withLock { frameHandler }?(frame)
    }
}

private final class LockedStringValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    var error: Error? { lock.withLock { storedError } }
    func set(_ error: Error?) { lock.withLock { storedError = error } }
}

private final class RecordingAudioQueueResource: AudioQueueInputResource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedStartCount = 0
    private var storedDisposeCount = 0
    var startCount: Int { lock.withLock { storedStartCount } }
    var disposeCount: Int { lock.withLock { storedDisposeCount } }
    func start() throws { lock.withLock { storedStartCount += 1 } }
    func stopAndDispose() {
        lock.withLock {
            if storedDisposeCount == 0 { storedDisposeCount = 1 }
        }
    }
}

private final class RecordingAudioQueueResourceFactory: AudioQueueInputResourceCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedResources: [RecordingAudioQueueResource] = []
    var resources: [RecordingAudioQueueResource] { lock.withLock { storedResources } }
    func makeResource(owner: AudioQueueMicrophoneCapture) throws -> any AudioQueueInputResource {
        let resource = RecordingAudioQueueResource()
        lock.withLock { storedResources.append(resource) }
        return resource
    }
}

private final class BarrierAudioQueueResourceFactory: AudioQueueInputResourceCreating, @unchecked Sendable {
    private let resource: RecordingAudioQueueResource
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    init(resource: RecordingAudioQueueResource) { self.resource = resource }
    func makeResource(owner: AudioQueueMicrophoneCapture) throws -> any AudioQueueInputResource {
        entered.signal()
        release.wait()
        return resource
    }
    func waitUntilCreationStarted() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 2)
    }
    func releaseCreation() { release.signal() }
}

private final class BarrierCapture: ClientMicrophoneCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var storedStopped = false
    var stopped: Bool { lock.withLock { storedStopped } }

    func start(
        frameHandler: @escaping @Sendable (ClientMicrophonePCMFrame) -> Void,
        discontinuityHandler: @escaping @Sendable () -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        entered.signal()
        release.wait()
    }

    func stop() {
        lock.withLock { storedStopped = true }
        release.signal()
    }

    func waitUntilStartEntered() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 2)
    }
}

private final class ForcedDTXEncoder: MonoMicrophonePacketEncoding, @unchecked Sendable {
    func encode(samples: [Float]) throws -> [UInt8] { [0xF8] }
    func isInDTX() throws -> Bool { true }
    func reset() throws {}
    func close() {}
}

private final class UDPTestEndpoint {
    let descriptor: Int32
    let port: UInt16

    init() throws {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(socketDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        descriptor = socketDescriptor
        port = UInt16(bigEndian: bound.sin_port)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    func receive() throws -> LMC1Datagram {
        var bytes = [UInt8](repeating: 0, count: LMC1Datagram.maximumDatagramByteCount)
        let count = bytes.withUnsafeMutableBytes {
            Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard count >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        bytes.removeSubrange(count..<bytes.count)
        return try LMC1Datagram(validating: bytes)
    }

    func close() {
        Darwin.close(descriptor)
    }
}
