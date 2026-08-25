import Foundation
import UmbraMicrophone
import UmbraOpus
import UmbraProtocolV3
import UmbraQUICTransport

public struct ProtocolV3InputAcknowledgement: Sendable, Equatable {
    public let hostReceiveTimeMicroseconds: UInt64
    public let appliedStateSequence: UInt64
    public let appliedEdgeID: UInt64
    public let receivedEdgeBitmap: UInt64
    public let capturedFrameID: UInt64
}

public enum ProtocolV3InputResynchronizationReason: UInt8, Sendable {
    case edgePressure = 1
    case hostReset = 2
    case authorityTransfer = 3
}

public struct ProtocolV3InputResynchronization: Sendable, Equatable {
    public let expectedEdgeID: UInt64
    public let reason: ProtocolV3InputResynchronizationReason
}

public enum ProtocolV3ControllerFeedbackCommand: Sendable, Equatable {
    case rumble(lowFrequency: UInt16, highFrequency: UInt16)
    case triggerRumble(left: UInt16, right: UInt16)
    case motionState(type: UInt8, reportRateHz: UInt16)
    case led(red: UInt8, green: UInt8, blue: UInt8)
    case adaptiveTriggers(flags: UInt8, leftType: UInt8, rightType: UInt8, left: Data, right: Data)
}

public struct ProtocolV3ControllerFeedback: Sendable, Equatable {
    public let inputGeneration: UInt32
    public let controllerGeneration: UInt32
    public let controller: UInt8
    public let command: ProtocolV3ControllerFeedbackCommand
}

struct ProtocolV3RTTTelemetry: Sendable, Equatable {
    let generation: UInt64
    let smoothedMicroseconds: UInt32
    let minimumMicroseconds: UInt32
    let variationMicroseconds: UInt32
}

public enum ProtocolV3SessionMediaError: Error, Equatable, Sendable {
    case inactive
    case invalidInput
    case inputPressure
    case invalidConfiguration
    case microphoneUnavailable
}

public struct ProtocolV3TransportStatistics: Equatable, Sendable {
    public let usableDatagramPayloadBytes: Int
    public let pathChangeCount: UInt64
    public let sendFailureCount: UInt64
    public let smoothedRTTMicroseconds: UInt32?
    public let minimumRTTMicroseconds: UInt32?
    public let rttVariationMicroseconds: UInt32?
    public let abuseCounters: QUICAbuseCounters?
}

public struct ProtocolV3SessionStatistics: Equatable, Sendable {
    public let media: ProtocolV3MediaStatistics
    public let transport: ProtocolV3TransportStatistics
    public let terminalMediaFailures: UInt64
}

public protocol ProtocolV3SessionMediaControlling: AnyObject, Sendable {
    @discardableResult
    func sendControlRequest(
        type: UInt16,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws -> UInt64
    func sendControlResponse(
        type: UInt16,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue],
        isError: Bool
    ) throws
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
    )
}

public extension ProtocolV3SessionMediaControlling {
    func sendControlResponse(
        type: UInt16,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws {
        try sendControlResponse(
            type: type,
            requestID: requestID,
            fields: fields,
            isError: false
        )
    }
}

extension ProtocolV3ClientControlSession: ProtocolV3SessionMediaControlling {}

/// Owns all modern-v3 media/input callbacks after START. The coordinator is
/// intentionally separate from the legacy Moonlight session and uses only the
/// authenticated QUIC control session and native media adapters.
public final class ProtocolV3SessionMediaCoordinator: @unchecked Sendable {
    public typealias InputACKHandler = @Sendable (ProtocolV3InputAcknowledgement) -> Void
    public typealias InputResyncHandler = @Sendable (ProtocolV3InputResynchronization) -> Void
    public typealias ControllerFeedbackHandler = @Sendable (ProtocolV3ControllerFeedback) -> Void
    public typealias FailureHandler = @Sendable (Error) -> Void
    public typealias StatisticsHandler = @Sendable (ProtocolV3SessionStatistics) -> Void

    private struct MicrophoneConfiguration {
        let generation: UInt32
        let frameSamples: UInt16
        let layout: UInt8
        let streams: UInt8
        let coupledStreams: UInt8
        let mapping: [UInt8]
        let bitrate: UInt32
    }

    private var control: any ProtocolV3SessionMediaControlling
    private let media: ProtocolV3MediaPipelineAdapter
    private let microphoneCapture: (any ClientMicrophoneCapturing)?
    private let microphoneEncoderFactory: @Sendable (Int32) throws -> MonoOpusEncoder
    private let inputACKHandler: InputACKHandler
    private let inputResyncHandler: InputResyncHandler
    private let controllerFeedbackHandler: ControllerFeedbackHandler
    private let failureHandler: FailureHandler
    private let statisticsHandler: StatisticsHandler
    private let lock = NSLock()
    private var sessionID: Data?
    private var microphoneConfiguration: MicrophoneConfiguration?
    private var microphoneEncoder: MonoOpusEncoder?
    private var microphoneSamplePosition: UInt64 = 0
    private var microphoneDiscontinuity = false
    private var stopped = false
    private var usableDatagramPayloadBytes = 0
    private var pathChangeCount: UInt64 = 0
    private var sendFailureCount: UInt64 = 0
    private var lastRTTTelemetryGeneration: UInt64 = 0
    private var smoothedRTTMicroseconds: UInt32?
    private var minimumRTTMicroseconds: UInt32?
    private var rttVariationMicroseconds: UInt32?
    private var abuseCounters: QUICAbuseCounters?
    private var terminalMediaFailures: UInt64 = 0
    private var terminalFailurePropagated = false
    private var lastStatisticsPublishNanoseconds: UInt64 = 0

    public init(
        control: any ProtocolV3SessionMediaControlling,
        media: ProtocolV3MediaPipelineAdapter,
        microphoneCapture: (any ClientMicrophoneCapturing)? = nil,
        microphoneEncoderFactory: @escaping @Sendable (Int32) throws -> MonoOpusEncoder = {
            try MonoOpusEncoder(bitrate: $0)
        },
        inputACKHandler: @escaping InputACKHandler = { _ in },
        inputResyncHandler: @escaping InputResyncHandler = { _ in },
        controllerFeedbackHandler: @escaping ControllerFeedbackHandler = { _ in },
        failureHandler: @escaping FailureHandler = { _ in },
        statisticsHandler: @escaping StatisticsHandler = { _ in }
    ) {
        self.control = control
        self.media = media
        self.microphoneCapture = microphoneCapture
        self.microphoneEncoderFactory = microphoneEncoderFactory
        self.inputACKHandler = inputACKHandler
        self.inputResyncHandler = inputResyncHandler
        self.controllerFeedbackHandler = controllerFeedbackHandler
        self.failureHandler = failureHandler
        self.statisticsHandler = statisticsHandler
        media.installVideoFeedbackHandler { [weak self] feedback in
            self?.sendVideoFeedback(feedback)
        }
    }

    public func handle(_ event: ProtocolV3ClientEvent) {
        do {
            if case let .transport(transportEvent) = event {
                recordTransportEvent(transportEvent)
            }
            switch event {
            case let .startAccepted(sessionID, _):
                try begin(sessionID: sessionID)
            case let .controlMessage(type, requestID, fields):
                try handleControl(type: type, requestID: requestID, fields: fields)
            case let .transport(.inbound(message)) where message.lane != .control:
                try handleDatagram(message)
            case let .transport(.sendDisposition(disposition)):
                handleDisposition(disposition)
            case .failed:
                suspendForReconnect()
            case .transport(.mediaSessionEnded):
                stopAndCleanUp(sendMicrophoneEnd: false)
            default:
                break
            }
            publishStatistics()
        } catch {
            propagateTerminalFailure(error)
        }
    }

    public func stopAndCleanUp(sendMicrophoneEnd: Bool) {
        let resources = lock.withLock { () -> (Data?, MicrophoneConfiguration?, MonoOpusEncoder?) in
            guard !stopped else { return (nil, nil, nil) }
            stopped = true
            let values = (sessionID, microphoneConfiguration, microphoneEncoder)
            sessionID = nil
            microphoneConfiguration = nil
            microphoneEncoder = nil
            resetRTTTelemetryLocked()
            return values
        }
        if sendMicrophoneEnd, let sessionID = resources.0, let configuration = resources.1 {
            sendMicrophonePacket(
                sessionID: sessionID,
                configuration: configuration,
                opus: Data(),
                flags: 0x04
            )
        }
        microphoneCapture?.stop()
        resources.2?.close()
        media.stopAndCleanUp()
    }

    public func statistics() -> ProtocolV3SessionStatistics {
        let transport = lock.withLock {
            (
                ProtocolV3TransportStatistics(
                    usableDatagramPayloadBytes: usableDatagramPayloadBytes,
                    pathChangeCount: pathChangeCount,
                    sendFailureCount: sendFailureCount,
                    smoothedRTTMicroseconds: smoothedRTTMicroseconds,
                    minimumRTTMicroseconds: minimumRTTMicroseconds,
                    rttVariationMicroseconds: rttVariationMicroseconds,
                    abuseCounters: abuseCounters
                ),
                terminalMediaFailures
            )
        }
        return ProtocolV3SessionStatistics(
            media: media.statistics(),
            transport: transport.0,
            terminalMediaFailures: transport.1
        )
    }

    public func suspendForReconnect() {
        let encoder = lock.withLock { () -> MonoOpusEncoder? in
            guard !stopped else { return nil }
            stopped = true
            sessionID = nil
            resetRTTTelemetryLocked()
            let encoder = microphoneEncoder
            microphoneEncoder = nil
            return encoder
        }
        microphoneCapture?.stop()
        encoder?.close()
        media.suspendForReconnect()
    }

    public func rebind(
        control: any ProtocolV3SessionMediaControlling,
        sessionID: Data
    ) throws {
        guard sessionID.count == 16, sessionID.contains(where: { $0 != 0 }) else {
            throw ProtocolV3SessionMediaError.invalidConfiguration
        }
        let configuration = try lock.withLock { () -> MicrophoneConfiguration? in
            guard stopped else { throw ProtocolV3SessionMediaError.inactive }
            self.control = control
            self.sessionID = sessionID
            stopped = false
            terminalFailurePropagated = false
            resetRTTTelemetryLocked()
            return microphoneConfiguration
        }
        guard let configuration, let capture = microphoneCapture else { return }
        guard let encoderBitrate = Int32(exactly: configuration.bitrate) else {
            throw ProtocolV3SessionMediaError.invalidConfiguration
        }
        let encoder = try microphoneEncoderFactory(encoderBitrate)
        lock.withLock { microphoneEncoder = encoder }
        do {
            try capture.start(
                frameHandler: { [weak self] frame in self?.encodeMicrophone(frame) },
                discontinuityHandler: { [weak self] in self?.markMicrophoneDiscontinuity() },
                failureHandler: { [weak self] error in self?.microphoneFailed(error) }
            )
            _ = configuration
        } catch {
            encoder.close()
            lock.withLock { microphoneEncoder = nil }
            throw error
        }
    }

    private func begin(sessionID: Data) throws {
        guard sessionID.count == 16, sessionID.contains(where: { $0 != 0 }) else {
            throw ProtocolV3SessionMediaError.invalidConfiguration
        }
        try lock.withLock {
            guard self.sessionID == nil, !stopped else { throw ProtocolV3SessionMediaError.inactive }
            self.sessionID = sessionID
            resetRTTTelemetryLocked()
        }
    }

    private func handleControl(
        type: UInt16,
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws {
        switch type {
        case 0x0140:
            do {
                let capacity = try media.configureVideo(fields: fields)
                try control.sendControlResponse(type: 0x0141, requestID: requestID, fields: [
                    1: .unsigned(0), 2: fields[1]!, 3: fields[2]!, 4: .unsigned(UInt64(capacity)),
                ], isError: false)
            } catch {
                try? control.sendControlResponse(type: 0x0141, requestID: requestID, fields: [
                    1: .unsigned(1), 2: fields[1] ?? .null, 3: fields[2] ?? .unsigned(0),
                    4: .unsigned(1),
                ], isError: true)
                throw error
            }
        case 0x0142:
            do {
                try media.configureAudio(fields: fields)
                try control.sendControlResponse(type: 0x0143, requestID: requestID, fields: [
                    1: .unsigned(0), 2: fields[1]!, 3: fields[2]!,
                ], isError: false)
            } catch {
                try? control.sendControlResponse(type: 0x0143, requestID: requestID, fields: [
                    1: .unsigned(1), 2: fields[1] ?? .null, 3: fields[2] ?? .unsigned(0),
                ], isError: true)
                throw error
            }
        case 0x0144:
            try configureMicrophone(requestID: requestID, fields: fields)
        case 0x0133:
            stopAndCleanUp(sendMicrophoneEnd: false)
        default:
            break
        }
    }

    private func handleDatagram(_ message: QUICInboundMessage) throws {
        switch (message.datagramChannel, message.datagramKind) {
        case (1?, 2?):
            guard message.payload.count == 48 else { throw ProtocolV3SessionMediaError.invalidInput }
            let acknowledgement = ProtocolV3InputAcknowledgement(
                hostReceiveTimeMicroseconds: Self.readUInt64(message.payload, 0),
                appliedStateSequence: Self.readUInt64(message.payload, 8),
                appliedEdgeID: Self.readUInt64(message.payload, 16),
                receivedEdgeBitmap: Self.readUInt64(message.payload, 24),
                capturedFrameID: Self.readUInt64(message.payload, 32)
            )
            guard Self.readUInt64(message.payload, 40) == 0 else {
                throw ProtocolV3SessionMediaError.invalidInput
            }
            inputACKHandler(acknowledgement)
        case (1?, 3?):
            guard message.payload.count == 16,
                  let reason = ProtocolV3InputResynchronizationReason(rawValue: message.payload[8]),
                  message.payload.dropFirst(9).allSatisfy({ $0 == 0 }) else {
                throw ProtocolV3SessionMediaError.invalidInput
            }
            inputResyncHandler(.init(expectedEdgeID: Self.readUInt64(message.payload, 0), reason: reason))
        case (1?, 4?):
            try handleControllerFeedback(message)
        case (2?, 1?), (3?, 1?):
            try media.handle(message)
        case (5?, 1?):
            try handleRTTTelemetry(message)
        default:
            throw ProtocolV3MediaPipelineError.invalidDatagram("interactive route")
        }
    }

    private func handleControllerFeedback(_ message: QUICInboundMessage) throws {
        controllerFeedbackHandler(try Self.decodeControllerFeedback(message))
    }

    private func handleRTTTelemetry(_ message: QUICInboundMessage) throws {
        let telemetry = try Self.decodeRTTTelemetry(message)
        lock.withLock {
            guard telemetry.generation > lastRTTTelemetryGeneration else { return }
            lastRTTTelemetryGeneration = telemetry.generation
            smoothedRTTMicroseconds = telemetry.smoothedMicroseconds
            minimumRTTMicroseconds = telemetry.minimumMicroseconds
            rttVariationMicroseconds = telemetry.variationMicroseconds
        }
    }

    static func decodeRTTTelemetry(
        _ message: QUICInboundMessage
    ) throws -> ProtocolV3RTTTelemetry {
        let payload = message.payload
        guard message.datagramChannel == 5, message.datagramKind == 1,
              payload.count == 24,
              let semanticSequence = message.semanticSequence,
              let objectID = message.objectID else {
            throw ProtocolV3SessionMediaError.invalidInput
        }
        let generation = Self.readUInt64(payload, 0)
        let smoothed = Self.readUInt32(payload, 8)
        let minimum = Self.readUInt32(payload, 12)
        let variation = Self.readUInt32(payload, 16)
        guard generation != 0,
              semanticSequence == generation,
              objectID == generation,
              (1...1_000_000).contains(smoothed),
              (1...smoothed).contains(minimum),
              variation <= 1_000_000,
              Self.readUInt32(payload, 20) == 0 else {
            throw ProtocolV3SessionMediaError.invalidInput
        }
        return ProtocolV3RTTTelemetry(
            generation: generation,
            smoothedMicroseconds: smoothed,
            minimumMicroseconds: minimum,
            variationMicroseconds: variation
        )
    }

    private func resetRTTTelemetryLocked() {
        lastRTTTelemetryGeneration = 0
        smoothedRTTMicroseconds = nil
        minimumRTTMicroseconds = nil
        rttVariationMicroseconds = nil
    }

    static func decodeControllerFeedback(
        _ message: QUICInboundMessage
    ) throws -> ProtocolV3ControllerFeedback {
        let payload = message.payload
        guard message.datagramChannel == 1, message.datagramKind == 4,
              payload.count == 40 else { throw ProtocolV3SessionMediaError.invalidInput }
        let inputGeneration = Self.readUInt32(payload, 0)
        let controllerGeneration = Self.readUInt32(payload, 4)
        let controller = payload[8]
        let commandID = payload[9]
        let valueLength = Int(Self.readUInt16(payload, 10))
        guard inputGeneration != 0,
              message.objectID == UInt64(inputGeneration),
              controllerGeneration != 0,
              controller < 16,
              payload[36..<40].allSatisfy({ $0 == 0 }) else {
            throw ProtocolV3SessionMediaError.invalidInput
        }
        let command: ProtocolV3ControllerFeedbackCommand
        switch commandID {
        case 1, 2:
            guard valueLength == 4, payload[16..<36].allSatisfy({ $0 == 0 }) else {
                throw ProtocolV3SessionMediaError.invalidInput
            }
            let low = Self.readUInt16(payload, 12)
            let high = Self.readUInt16(payload, 14)
            command = commandID == 1
                ? .rumble(lowFrequency: low, highFrequency: high)
                : .triggerRumble(left: low, right: high)
        case 3:
            guard valueLength == 4, (1...2).contains(payload[12]), payload[13] == 0,
                  Self.readUInt16(payload, 14) <= 2_000,
                  payload[16..<36].allSatisfy({ $0 == 0 }) else {
                throw ProtocolV3SessionMediaError.invalidInput
            }
            command = .motionState(type: payload[12], reportRateHz: Self.readUInt16(payload, 14))
        case 4:
            guard valueLength == 3, payload[15..<36].allSatisfy({ $0 == 0 }) else {
                throw ProtocolV3SessionMediaError.invalidInput
            }
            command = .led(red: payload[12], green: payload[13], blue: payload[14])
        case 5:
            guard valueLength == 24, payload[12] & ~UInt8(0x0C) == 0, payload[15] == 0 else {
                throw ProtocolV3SessionMediaError.invalidInput
            }
            command = .adaptiveTriggers(
                flags: payload[12],
                leftType: payload[13],
                rightType: payload[14],
                left: payload.subdata(in: 16..<26),
                right: payload.subdata(in: 26..<36)
            )
        default:
            throw ProtocolV3SessionMediaError.invalidInput
        }
        return .init(
            inputGeneration: inputGeneration,
            controllerGeneration: controllerGeneration,
            controller: controller,
            command: command
        )
    }

    private func handleDisposition(_ disposition: QUICSendDisposition) {
        guard disposition.lane == .inputEdge, !lock.withLock({ stopped }) else { return }
        switch disposition.outcome {
        case .submittedToNetwork:
            return
        default:
            propagateTerminalFailure(ProtocolV3SessionMediaError.inputPressure)
        }
    }

    private func configureMicrophone(
        requestID: UInt64,
        fields: [UInt64: ProtocolV3CBORValue]
    ) throws {
        try media.validateMicrophoneConfiguration(fields: fields)
        guard Set(fields.keys) == Set(1...4),
              let generationRaw = fields[2]?.unsignedValue,
              let generation = UInt32(exactly: generationRaw), generation != 0,
              fields[4]?.unsignedValue != nil else {
            throw ProtocolV3SessionMediaError.invalidConfiguration
        }
        guard case let .map(tuple) = fields[3] else {
            if fields[3] == .null {
                microphoneCapture?.stop()
                lock.withLock {
                    microphoneEncoder?.close()
                    microphoneEncoder = nil
                    microphoneConfiguration = nil
                }
                try control.sendControlResponse(type: 0x0145, requestID: requestID, fields: [
                    1: .unsigned(0), 2: fields[1]!, 3: fields[2]!,
                ], isError: false)
                return
            }
            throw ProtocolV3SessionMediaError.invalidConfiguration
        }
        guard let capture = microphoneCapture,
              tuple[1]?.unsignedValue == 1,
              tuple[2]?.unsignedValue == 48_000,
              tuple[3]?.unsignedValue == 1,
              let samples = tuple[4]?.unsignedValue, samples == 960,
              let layout = tuple[5]?.unsignedValue.flatMap(UInt8.init(exactly:)),
              tuple[6]?.unsignedValue == 1,
              tuple[7]?.unsignedValue == 0,
              tuple[8]?.bytesValue == Data([0]),
              let bitrate = tuple[9]?.unsignedValue.flatMap(UInt32.init(exactly:)) else {
            try? control.sendControlResponse(type: 0x0145, requestID: requestID, fields: [
                1: .unsigned(1), 2: fields[1] ?? .null, 3: fields[2] ?? .unsigned(0),
            ], isError: true)
            throw ProtocolV3SessionMediaError.microphoneUnavailable
        }
        let configuration = MicrophoneConfiguration(
            generation: generation,
            frameSamples: UInt16(samples),
            layout: layout,
            streams: 1,
            coupledStreams: 0,
            mapping: [0],
            bitrate: bitrate
        )
        guard let encoderBitrate = Int32(exactly: bitrate) else {
            throw ProtocolV3SessionMediaError.invalidConfiguration
        }
        let encoder = try microphoneEncoderFactory(encoderBitrate)
        lock.withLock {
            microphoneEncoder?.close()
            microphoneEncoder = encoder
            microphoneConfiguration = configuration
            microphoneSamplePosition = fields[4]?.unsignedValue ?? 0
            microphoneDiscontinuity = false
        }
        do {
            try capture.start(
                frameHandler: { [weak self] frame in self?.encodeMicrophone(frame) },
                discontinuityHandler: { [weak self] in self?.markMicrophoneDiscontinuity() },
                failureHandler: { [weak self] error in self?.microphoneFailed(error) }
            )
            try control.sendControlResponse(type: 0x0145, requestID: requestID, fields: [
                1: .unsigned(0), 2: fields[1]!, 3: fields[2]!,
            ], isError: false)
        } catch {
            capture.stop()
            encoder.close()
            lock.withLock {
                microphoneEncoder = nil
                microphoneConfiguration = nil
            }
            throw error
        }
    }

    private func encodeMicrophone(_ frame: ClientMicrophonePCMFrame) {
        do {
            let state = try lock.withLock { () -> (Data, MicrophoneConfiguration, MonoOpusEncoder, UInt64, Bool) in
                guard !stopped, let sessionID, let configuration = microphoneConfiguration,
                      let encoder = microphoneEncoder else {
                    throw ProtocolV3SessionMediaError.inactive
                }
                let position = microphoneSamplePosition
                microphoneSamplePosition += UInt64(configuration.frameSamples)
                let discontinuity = microphoneDiscontinuity
                microphoneDiscontinuity = false
                return (sessionID, configuration, encoder, position, discontinuity)
            }
            let encoded = try state.2.encode(samples: frame.samples)
            let dtx = try encoded.isEmpty || state.2.isInDTX()
            sendMicrophonePacket(
                sessionID: state.0,
                configuration: state.1,
                opus: dtx ? Data() : Data(encoded),
                flags: (dtx ? 0x01 : 0) | (state.4 ? 0x02 : 0),
                samplePosition: state.3
            )
        } catch {
            microphoneFailed(error)
        }
    }

    private func markMicrophoneDiscontinuity() {
        do {
            try lock.withLock {
                try microphoneEncoder?.reset()
                microphoneDiscontinuity = true
            }
        } catch {
            microphoneFailed(error)
        }
    }

    private func microphoneFailed(_ error: Error) {
        propagateTerminalFailure(error)
    }

    private func sendMicrophonePacket(
        sessionID: Data,
        configuration: MicrophoneConfiguration,
        opus: Data,
        flags: UInt8,
        samplePosition: UInt64? = nil
    ) {
        let position = samplePosition ?? lock.withLock { microphoneSamplePosition }
        var payload = Data()
        Self.append(Self.monotonicMicroseconds(), to: &payload)
        Self.append(position, to: &payload)
        Self.append(configuration.generation, to: &payload)
        Self.append(configuration.frameSamples, to: &payload)
        payload.append(1)
        payload.append(configuration.layout)
        payload.append(1)
        payload.append(flags)
        payload.append(configuration.streams)
        payload.append(configuration.coupledStreams)
        payload.append(contentsOf: configuration.mapping)
        payload.append(Data(repeating: 0xFF, count: 8 - configuration.mapping.count))
        Self.append(configuration.bitrate, to: &payload)
        Self.append(UInt64(0), to: &payload)
        payload.append(opus)
        control.sendDatagram(
            lane: .microphone,
            sessionID: sessionID,
            channel: 4,
            kind: 1,
            flags: 0,
            objectID: position,
            payload: payload,
            deadlineNanoseconds: nil,
            supersessionKey: nil
        )
    }

    private func sendVideoFeedback(_ feedback: ProtocolV3VideoFeedback) {
        guard let sessionID = lock.withLock({ stopped ? nil : self.sessionID }) else { return }
        var payload = Data()
        Self.append(feedback.lastReassembledFrameID, to: &payload)
        Self.append(feedback.lastDecodedFrameID, to: &payload)
        payload.append(feedback.action)
        payload.append(0)
        Self.append(UInt16(0), to: &payload)
        Self.append(feedback.deadlineMissMicroseconds, to: &payload)
        Self.append(UInt64(0), to: &payload)
        control.sendDatagram(
            lane: .video,
            sessionID: sessionID,
            channel: 2,
            kind: 3,
            flags: 0,
            objectID: feedback.affectedFrameID,
            payload: payload,
            deadlineNanoseconds: nil,
            supersessionKey: feedback.affectedFrameID
        )
    }

    private static func monotonicMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000
    }

    private func recordTransportEvent(_ event: QUICTransportEvent) {
        lock.withLock {
            switch event {
            case let .negotiated(parameters):
                usableDatagramPayloadBytes = parameters.usableDatagramPayloadSize
            case let .datagramCapacityChanged(_, payloadByteCount):
                usableDatagramPayloadBytes = payloadByteCount
            case .pathChanged:
                pathChangeCount += 1
            case let .abuseCounters(counters):
                abuseCounters = counters
            case let .sendDisposition(disposition):
                switch disposition.outcome {
                case .submittedToNetwork, .superseded:
                    break
                default:
                    sendFailureCount += 1
                }
            default:
                break
            }
        }
    }

    private func publishStatistics(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldPublish = lock.withLock { () -> Bool in
            guard force || now >= lastStatisticsPublishNanoseconds + 1_000_000_000 else {
                return false
            }
            lastStatisticsPublishNanoseconds = now
            return true
        }
        if shouldPublish { statisticsHandler(statistics()) }
    }

    private func propagateTerminalFailure(_ error: Error) {
        let state = lock.withLock { () -> ((any ProtocolV3SessionMediaControlling)?, Data?, Bool) in
            guard !terminalFailurePropagated else { return (nil, nil, false) }
            terminalFailurePropagated = true
            terminalMediaFailures += 1
            return (stopped ? nil : control, stopped ? nil : sessionID, true)
        }
        guard state.2 else { return }
        if let control = state.0, let sessionID = state.1,
           let stopIntent = try? ProtocolV3ClientIdentity.secureRandomBytes(count: 16) {
            _ = try? control.sendControlRequest(
                type: 0x0130,
                fields: [
                    1: .bytes(sessionID),
                    2: .unsigned(0),
                    3: .unsigned(3),
                    4: .bytes(stopIntent),
                ]
            )
        }
        failureHandler(error)
        stopAndCleanUp(sendMicrophoneEnd: false)
        publishStatistics(force: true)
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        data[offset..<(offset + 2)].reduce(0) { ($0 << 8) | UInt16($1) }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}
