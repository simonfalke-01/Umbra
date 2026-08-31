import COpus
import Foundation

public enum MonoOpusEncoderError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidFrameLength(Int)
    case creationFailed(code: Int32, message: String)
    case configurationFailed(code: Int32, message: String)
    case encodingFailed(code: Int32, message: String)
    case resetFailed(code: Int32, message: String)
    case closed

    public var description: String {
        switch self {
        case let .invalidFrameLength(count):
            "Mono Opus input must contain exactly 960 samples; received \(count)"
        case let .creationFailed(code, message):
            "Opus encoder creation failed (\(code)): \(message)"
        case let .configurationFailed(code, message):
            "Opus encoder configuration failed (\(code)): \(message)"
        case let .encodingFailed(code, message):
            "Opus encoding failed (\(code)): \(message)"
        case let .resetFailed(code, message):
            "Opus encoder reset failed (\(code)): \(message)"
        case .closed:
            "The Opus encoder is closed"
        }
    }
}

/// Low-delay version-one microphone encoder: 48 kHz, mono, and one 20 ms frame.
public final class MonoOpusEncoder: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public let bitrate: Int32
        public let inbandFECEnabled: Bool
        public let packetLossPercentage: Int32
        public let dtxEnabled: Bool
    }
    public static let sampleRate: Int32 = 48_000
    public static let samplesPerFrame = 960
    public static let maximumPacketByteCount = 1_275
    public static let defaultBitrate: Int32 = 64_000
    public static let defaultPacketLossPercentage: Int32 = 10

    private let lock = NSLock()
    private var encoder: OpaquePointer?

    public init(
        bitrate: Int32 = defaultBitrate,
        packetLossPercentage: Int32 = defaultPacketLossPercentage,
        inbandFECEnabled: Bool = true,
        dtxEnabled: Bool = true
    ) throws {
        var result = Int32(OPUS_OK)
        guard let encoder = opus_encoder_create(
            Self.sampleRate,
            1,
            Int32(OPUS_APPLICATION_VOIP),
            &result
        ), result == OPUS_OK else {
            throw MonoOpusEncoderError.creationFailed(code: result, message: opusMessage(result))
        }
        self.encoder = encoder

        let controls = [
            Int32(umbra_opus_encoder_set_bitrate(encoder, bitrate)),
            Int32(umbra_opus_encoder_set_inband_fec(encoder, inbandFECEnabled ? 1 : 0)),
            Int32(umbra_opus_encoder_set_packet_loss_percentage(encoder, packetLossPercentage)),
            Int32(umbra_opus_encoder_set_dtx(encoder, dtxEnabled ? 1 : 0)),
        ]
        if let failure = controls.first(where: { $0 != OPUS_OK }) {
            opus_encoder_destroy(encoder)
            self.encoder = nil
            throw MonoOpusEncoderError.configurationFailed(
                code: failure,
                message: opusMessage(failure)
            )
        }
    }

    deinit {
        close()
    }

    public func encode(samples: [Float]) throws -> [UInt8] {
        guard samples.count == Self.samplesPerFrame else {
            throw MonoOpusEncoderError.invalidFrameLength(samples.count)
        }
        return try lock.withLock {
            guard let encoder else { throw MonoOpusEncoderError.closed }
            var packet = [UInt8](repeating: 0, count: Self.maximumPacketByteCount)
            let encodedByteCount = samples.withUnsafeBufferPointer { input in
                packet.withUnsafeMutableBufferPointer { output in
                    opus_encode_float(
                        encoder,
                        input.baseAddress!,
                        Int32(Self.samplesPerFrame),
                        output.baseAddress!,
                        Int32(Self.maximumPacketByteCount)
                    )
                }
            }
            guard encodedByteCount >= 0 else {
                let code = Int32(encodedByteCount)
                throw MonoOpusEncoderError.encodingFailed(code: code, message: opusMessage(code))
            }
            packet.removeSubrange(Int(encodedByteCount)..<packet.count)
            return packet
        }
    }

    public func reset() throws {
        try lock.withLock {
            guard let encoder else { throw MonoOpusEncoderError.closed }
            let result = Int32(umbra_opus_encoder_reset(encoder))
            guard result == OPUS_OK else {
                throw MonoOpusEncoderError.resetFailed(code: result, message: opusMessage(result))
            }
        }
    }

    public func configuration() throws -> Configuration {
        try lock.withLock {
            guard let encoder else { throw MonoOpusEncoderError.closed }
            var bitrate: Int32 = 0
            var fec: Int32 = 0
            var packetLoss: Int32 = 0
            var dtx: Int32 = 0
            let controls = [
                Int32(umbra_opus_encoder_get_bitrate(encoder, &bitrate)),
                Int32(umbra_opus_encoder_get_inband_fec(encoder, &fec)),
                Int32(umbra_opus_encoder_get_packet_loss_percentage(encoder, &packetLoss)),
                Int32(umbra_opus_encoder_get_dtx(encoder, &dtx)),
            ]
            if let failure = controls.first(where: { $0 != OPUS_OK }) {
                throw MonoOpusEncoderError.configurationFailed(
                    code: failure,
                    message: opusMessage(failure)
                )
            }
            return Configuration(
                bitrate: bitrate,
                inbandFECEnabled: fec != 0,
                packetLossPercentage: packetLoss,
                dtxEnabled: dtx != 0
            )
        }
    }

    /// Returns libopus's state after the most recent encode. Protocol callers
    /// send authenticated LMC1 SILENCE instead of forwarding a DTX payload.
    public func isInDTX() throws -> Bool {
        try lock.withLock {
            guard let encoder else { throw MonoOpusEncoderError.closed }
            var inDTX: Int32 = 0
            let result = Int32(umbra_opus_encoder_get_in_dtx(encoder, &inDTX))
            guard result == OPUS_OK else {
                throw MonoOpusEncoderError.configurationFailed(
                    code: result,
                    message: opusMessage(result)
                )
            }
            return inDTX != 0
        }
    }

    public func close() {
        let encoder = lock.withLock { () -> OpaquePointer? in
            defer { self.encoder = nil }
            return self.encoder
        }
        if let encoder { opus_encoder_destroy(encoder) }
    }
}

private func opusMessage(_ code: Int32) -> String {
    guard let pointer = opus_strerror(code) else { return "Unknown libopus error" }
    return String(cString: pointer)
}
