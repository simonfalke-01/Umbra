import Foundation
import UmbraOpus

public struct ClientMicrophoneGenerationDescriptor: Equatable, Sendable {
    public let sessionID: Data
    public let salt: Data
    public let serverPort: UInt16
    public let clientPort: UInt16
    public let remoteAddress: String
    public let rikey: Data

    public init(
        sessionID: Data,
        salt: Data,
        serverPort: UInt16,
        clientPort: UInt16,
        remoteAddress: String,
        rikey: Data
    ) {
        self.sessionID = sessionID
        self.salt = salt
        self.serverPort = serverPort
        self.clientPort = clientPort
        self.remoteAddress = remoteAddress
        self.rikey = rikey
    }
}

public protocol ClientMicrophoneForwarding: AnyObject, Sendable {
    var clientPort: UInt16 { get }
    func begin(
        generation: ClientMicrophoneGenerationDescriptor,
        warningHandler: @escaping @Sendable (String) -> Void
    ) throws
    func finish()
    func invalidate()
}

public protocol ClientMicrophonePreparing: Sendable {
    func prepare(host: String) async throws -> any ClientMicrophoneForwarding
    func prepare(
        host: String,
        deviceUID: String?
    ) async throws -> any ClientMicrophoneForwarding
}

public extension ClientMicrophonePreparing {
    func prepare(
        host: String,
        deviceUID _: String?
    ) async throws -> any ClientMicrophoneForwarding {
        try await prepare(host: host)
    }
}

public struct SystemClientMicrophonePreparer: ClientMicrophonePreparing, Sendable {
    private let authorization: any ClientMicrophoneAuthorizing
    private let captureFactory: any ClientMicrophoneCaptureCreating

    public init(
        authorization: any ClientMicrophoneAuthorizing = SystemClientMicrophoneAuthorization(),
        captureFactory: any ClientMicrophoneCaptureCreating = AudioQueueMicrophoneCaptureFactory()
    ) {
        self.authorization = authorization
        self.captureFactory = captureFactory
    }

    public func prepare(host: String) async throws -> any ClientMicrophoneForwarding {
        try await prepare(host: host, deviceUID: nil)
    }

    public func prepare(
        host _: String,
        deviceUID: String?
    ) async throws -> any ClientMicrophoneForwarding {
        let status = await authorization.requestAuthorization()
        guard status.permitsCapture else {
            throw ClientMicrophonePreparationError.permissionDenied(status)
        }
        return try ClientMicrophoneForwarder(
            sender: ConnectedMicrophoneUDPSender(),
            capture: captureFactory.makeCapture(deviceUID: deviceUID)
        )
    }
}

protocol MonoMicrophonePacketEncoding: AnyObject, Sendable {
    func encode(samples: [Float]) throws -> [UInt8]
    func isInDTX() throws -> Bool
    func reset() throws
    func close()
}

extension MonoOpusEncoder: MonoMicrophonePacketEncoding {}

/// Owns one transactional microphone generation. Start and teardown are
/// barriers: a stop racing with capture creation cannot publish a running queue
/// or retain generation key material after either call returns.
public final class ClientMicrophoneForwarder: ClientMicrophoneForwarding, @unchecked Sendable {
    enum LifecycleState: Equatable {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    private typealias Warning = (handler: (@Sendable (String) -> Void)?, message: String)

    private let lifecycle = NSCondition()
    private let sender: ConnectedMicrophoneUDPSender
    private let capture: any ClientMicrophoneCapturing
    private let encoderFactory: @Sendable () throws -> any MonoMicrophonePacketEncoding
    private var lifecycleState: LifecycleState = .idle
    private var stopRequestedWhileStarting = false
    private var sendEndWhenStartStops = true
    private var pendingStartFailure: Error?
    private var encoder: (any MonoMicrophonePacketEncoding)?
    private var transmitter: MicrophoneDatagramTransmitter?
    private var warningHandler: (@Sendable (String) -> Void)?

    public var clientPort: UInt16 { sender.localPort }

    public init(
        sender: ConnectedMicrophoneUDPSender,
        capture: any ClientMicrophoneCapturing
    ) {
        self.sender = sender
        self.capture = capture
        self.encoderFactory = { try MonoOpusEncoder() }
    }

    init(
        sender: ConnectedMicrophoneUDPSender,
        capture: any ClientMicrophoneCapturing,
        encoderFactory: @escaping @Sendable () throws -> any MonoMicrophonePacketEncoding
    ) {
        self.sender = sender
        self.capture = capture
        self.encoderFactory = encoderFactory
    }

    deinit { invalidate() }

    public func begin(
        generation descriptor: ClientMicrophoneGenerationDescriptor,
        warningHandler: @escaping @Sendable (String) -> Void
    ) throws {
        let credentials: MicrophoneSetupCredentials
        do {
            credentials = MicrophoneSetupCredentials(
                sessionID: try MicrophoneSessionID(bytes: Array(descriptor.sessionID)),
                salt: try MicrophoneSalt(bytes: Array(descriptor.salt))
            )
        } catch {
            throw ClientMicrophonePreparationError.invalidGeneration
        }
        guard descriptor.clientPort == clientPort,
              descriptor.serverPort > 0,
              !descriptor.remoteAddress.isEmpty,
              descriptor.rikey.count == 16 else {
            throw ClientMicrophonePreparationError.invalidGeneration
        }

        lifecycle.lock()
        guard lifecycleState == .idle else {
            lifecycle.unlock()
            throw ClientMicrophonePreparationError.alreadyStarted
        }
        lifecycleState = .starting
        stopRequestedWhileStarting = false
        sendEndWhenStartStops = true
        pendingStartFailure = nil
        self.warningHandler = warningHandler
        lifecycle.unlock()

        do {
            try sender.connect(
                remoteAddress: descriptor.remoteAddress,
                serverPort: descriptor.serverPort
            )
            let encoder = try encoderFactory()
            let generation = try MicrophoneGeneration(
                credentials: credentials,
                rikey: Array(descriptor.rikey)
            )
            let transmitter = MicrophoneDatagramTransmitter(
                generation: generation,
                sender: sender
            )
            lifecycle.withLock {
                self.encoder = encoder
                self.transmitter = transmitter
            }
            try throwIfStartWasStopped()
            try transmitter.start()
            try throwIfStartWasStopped()
            try capture.start(
                frameHandler: { [weak self] frame in self?.process(frame) },
                discontinuityHandler: { [weak self] in self?.processDiscontinuity() },
                failureHandler: { [weak self] error in self?.processCaptureFailure(error) }
            )
            try throwIfStartWasStopped()

            lifecycle.lock()
            if let pendingStartFailure {
                lifecycle.unlock()
                throw pendingStartFailure
            }
            if stopRequestedWhileStarting {
                lifecycle.unlock()
                throw AudioQueueMicrophoneCaptureError.startCancelled
            }
            lifecycleState = .running
            lifecycle.broadcast()
            lifecycle.unlock()
        } catch {
            let warning = finishFailedStart()
            if let warning { warning.handler?(warning.message) }
            if error is AudioQueueMicrophoneCaptureError {
                throw ClientMicrophonePreparationError.captureFailed(error.localizedDescription)
            }
            throw error
        }
    }

    public func finish() {
        stop(sendEnd: true)
    }

    public func invalidate() {
        stop(sendEnd: false)
    }

    private func stop(sendEnd: Bool) {
        lifecycle.lock()
        switch lifecycleState {
        case .starting:
            stopRequestedWhileStarting = true
            if !sendEnd { sendEndWhenStartStops = false }
            lifecycle.unlock()
            capture.stop()
            lifecycle.lock()
            while lifecycleState == .starting || lifecycleState == .stopping {
                lifecycle.wait()
            }
            lifecycle.unlock()
        case .running:
            lifecycleState = .stopping
            let warning = releaseGenerationLocked(sendEnd: sendEnd, baseError: nil)
            lifecycle.unlock()
            finishStoppedResources(warning: warning)
        case .stopping:
            while lifecycleState == .stopping { lifecycle.wait() }
            lifecycle.unlock()
        case .idle, .stopped:
            lifecycleState = .stopped
            lifecycle.broadcast()
            lifecycle.unlock()
            capture.stop()
            sender.close()
        }
    }

    private func process(_ frame: ClientMicrophonePCMFrame) {
        var warning: Warning?
        lifecycle.lock()
        guard lifecycleState == .running, let encoder, let transmitter else {
            lifecycle.unlock()
            return
        }
        do {
            if frame.samples.allSatisfy({ abs($0) <= 0.000_01 }) {
                try transmitter.sendSilence()
            } else {
                let packet = try encoder.encode(samples: frame.samples)
                let shouldSendSilence = packet.isEmpty ? true : try encoder.isInDTX()
                if shouldSendSilence {
                    try transmitter.sendSilence()
                } else {
                    try transmitter.sendAudio(opusPacket: packet)
                }
            }
        } catch {
            lifecycleState = .stopping
            warning = releaseGenerationLocked(sendEnd: true, baseError: error)
        }
        lifecycle.unlock()
        if warning != nil { finishStoppedResources(warning: warning) }
    }

    private func processDiscontinuity() {
        var warning: Warning?
        lifecycle.lock()
        guard lifecycleState == .running, let encoder, let transmitter else {
            lifecycle.unlock()
            return
        }
        do {
            try encoder.reset()
            try transmitter.reset()
        } catch {
            lifecycleState = .stopping
            warning = releaseGenerationLocked(sendEnd: true, baseError: error)
        }
        lifecycle.unlock()
        if warning != nil { finishStoppedResources(warning: warning) }
    }

    private func processCaptureFailure(_ error: Error) {
        lifecycle.lock()
        if lifecycleState == .starting {
            pendingStartFailure = error
            stopRequestedWhileStarting = true
            lifecycle.unlock()
            return
        }
        guard lifecycleState == .running else {
            lifecycle.unlock()
            return
        }
        lifecycleState = .stopping
        let warning = releaseGenerationLocked(sendEnd: true, baseError: error)
        lifecycle.unlock()
        finishStoppedResources(warning: warning)
    }

    private func throwIfStartWasStopped() throws {
        try lifecycle.withLock {
            if let pendingStartFailure { throw pendingStartFailure }
            if stopRequestedWhileStarting {
                throw AudioQueueMicrophoneCaptureError.startCancelled
            }
        }
    }

    private func finishFailedStart() -> Warning? {
        lifecycle.lock()
        lifecycleState = .stopping
        let warning = releaseGenerationLocked(
            sendEnd: sendEndWhenStartStops,
            baseError: nil
        )
        lifecycle.unlock()
        capture.stop()
        sender.close()
        completeStopped()
        return warning
    }

    private func releaseGenerationLocked(sendEnd: Bool, baseError: Error?) -> Warning? {
        var messages: [String] = []
        if let baseError {
            messages.append("Microphone forwarding stopped: \(baseError.localizedDescription)")
        }
        if sendEnd, transmitter?.generation.state == .active {
            do {
                try transmitter?.end()
            } catch {
                messages.append("Microphone END could not be sent: \(error.localizedDescription)")
                transmitter?.invalidate()
            }
        } else {
            transmitter?.invalidate()
        }
        encoder?.close()
        encoder = nil
        transmitter = nil
        let handler = warningHandler
        warningHandler = nil
        guard !messages.isEmpty else { return nil }
        return (handler, messages.joined(separator: " "))
    }

    private func finishStoppedResources(warning: Warning?) {
        capture.stop()
        sender.close()
        completeStopped()
        if let warning { warning.handler?(warning.message) }
    }

    private func completeStopped() {
        lifecycle.lock()
        lifecycleState = .stopped
        pendingStartFailure = nil
        lifecycle.broadcast()
        lifecycle.unlock()
    }

    var lifecycleStateForTesting: LifecycleState {
        lifecycle.withLock { lifecycleState }
    }
}

private extension NSCondition {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
