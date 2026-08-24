import AVFAudio
import COpus
import Foundation
import UmbraMedia

public enum OpusDecoderError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedAudioConfiguration(Int32)
    case channelCountMismatch(expected: Int, actual: Int)
    case unsupportedSampleRate(Int)
    case invalidStreamCount(Int)
    case invalidCoupledStreamCount(streamCount: Int, coupledStreamCount: Int)
    case invalidSamplesPerFrame(samples: Int, sampleRate: Int)
    case mappingTooShort(expected: Int, actual: Int)
    case invalidMapping(channel: Int, value: UInt8, codedChannelCount: Int)
    case packetTooLarge(maximum: Int, actual: Int)
    case notConfigured
    case notRunning
    case rendererUnavailable
    case decoderCreationFailed(code: Int32, message: String)
    case decodingFailed(code: Int32, message: String)
    case resetFailed(code: Int32, message: String)
    case channelLayoutUnavailable(AudioOutputLayout)
    case pcmBufferAllocationFailed(frameCount: Int)
    case pcmStorageUnavailable
    case invalidDecodedFrameLength(Int)
    case unexpected(String)

    public var description: String {
        switch self {
        case let .unsupportedAudioConfiguration(configuration):
            "Unsupported Moonlight audio configuration: \(configuration)"
        case let .channelCountMismatch(expected, actual):
            "Audio configuration requires \(expected) channels, but Opus negotiated \(actual)"
        case let .unsupportedSampleRate(sampleRate):
            "Unsupported Opus sample rate: \(sampleRate) Hz"
        case let .invalidStreamCount(count):
            "Invalid Opus stream count: \(count)"
        case let .invalidCoupledStreamCount(streamCount, coupledStreamCount):
            "Invalid Opus coupled stream count \(coupledStreamCount) for \(streamCount) streams"
        case let .invalidSamplesPerFrame(samples, sampleRate):
            "Invalid Opus frame size \(samples) at \(sampleRate) Hz"
        case let .mappingTooShort(expected, actual):
            "Opus channel mapping has \(actual) entries; \(expected) are required"
        case let .invalidMapping(channel, value, codedChannelCount):
            "Opus channel \(channel) maps to \(value), but only \(codedChannelCount) coded channels exist"
        case let .packetTooLarge(maximum, actual):
            "Opus packet is \(actual) bytes; Moonlight packets are limited to \(maximum) bytes"
        case .notConfigured:
            "The Opus decoder is not configured"
        case .notRunning:
            "The Opus decoder is not running"
        case .rendererUnavailable:
            "No audio renderer is attached to the Opus decoder"
        case let .decoderCreationFailed(code, message):
            "Opus decoder creation failed (\(code)): \(message)"
        case let .decodingFailed(code, message):
            "Opus packet decoding failed (\(code)): \(message)"
        case let .resetFailed(code, message):
            "Opus decoder reset failed (\(code)): \(message)"
        case let .channelLayoutUnavailable(layout):
            "Core Audio channel layout is unavailable for \(layout.rawValue)"
        case let .pcmBufferAllocationFailed(frameCount):
            "Core Audio could not allocate a \(frameCount)-frame PCM buffer"
        case .pcmStorageUnavailable:
            "Core Audio did not expose Float32 channel storage"
        case let .invalidDecodedFrameLength(frameCount):
            "Opus returned an invalid decoded frame length: \(frameCount)"
        case let .unexpected(message):
            "Unexpected Opus pipeline failure: \(message)"
        }
    }
}

/// An owned Float32 PCM frame in Moonlight's interleaved channel order.
///
/// Channels are FL, FR for stereo; FL, FR, C, LFE, rear-L, rear-R for 5.1;
/// and FL, FR, C, LFE, rear-L, rear-R, side-L, side-R for 7.1.
public struct InterleavedPCMFrame: Sendable, Equatable {
    public let sampleRate: Double
    public let layout: AudioOutputLayout
    public let frameLength: Int
    public let samples: [Float]

    public var channelCount: Int { Int(layout.channelCount) }

    init(sampleRate: Double, layout: AudioOutputLayout, frameLength: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.layout = layout
        self.frameLength = frameLength
        self.samples = samples
    }

    /// Copies interleaved decoder output into the non-interleaved Float32
/// layout consumed by the native AudioQueue renderer.
    public func makeAudioBuffer() throws -> AVAudioPCMBuffer {
        guard frameLength >= 0, samples.count == frameLength * channelCount else {
            throw OpusDecoderError.invalidDecodedFrameLength(frameLength)
        }
        guard let channelLayout = AVAudioChannelLayout(layoutTag: layout.coreAudioLayoutTag) else {
            throw OpusDecoderError.channelLayoutUnavailable(layout)
        }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: channelLayout
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameLength)
        ) else {
            throw OpusDecoderError.pcmBufferAllocationFailed(frameCount: frameLength)
        }
        guard let channels = buffer.floatChannelData else {
            throw OpusDecoderError.pcmStorageUnavailable
        }

        buffer.frameLength = AVAudioFrameCount(frameLength)
        for channel in 0..<channelCount {
            let destination = channels[channel]
            for frame in 0..<frameLength {
                destination[frame] = samples[(frame * channelCount) + channel]
            }
        }
        return buffer
    }
}

/// Thread-safe native decoder for the Opus multistream configuration supplied
/// by moonlight-common-c.
public final class OpusMultistreamDecoder: AudioDecoding, AudioDiscontinuityHandling, @unchecked Sendable {
    public static let maximumMoonlightPacketSize = 1_400

    private struct Configuration {
        let streamFormat: OpusStreamFormat
        let layout: AudioOutputLayout
        let mapping: [UInt8]
    }

    private struct State {
        var configuration: Configuration?
        var decoder: OpaquePointer?
        var isRunning = false
        var lastError: OpusDecoderError?
    }

    private let renderer: (any AudioEngineRendering)?
    private let lock = NSLock()
    private var state = State()

    /// Creates a decoder that pushes owned `AVAudioPCMBuffer` values to a renderer.
    public init(renderer: any AudioEngineRendering) {
        self.renderer = renderer
    }

    /// Creates a direct decoder. Use `decode(packet:)` to consume its owned PCM output.
    public init() {
        renderer = nil
    }

    deinit {
        lock.lock()
        let decoder = state.decoder
        state.decoder = nil
        state.configuration = nil
        state.isRunning = false
        lock.unlock()
        if let decoder {
            opus_multistream_decoder_destroy(decoder)
        }
    }

    public var lastError: OpusDecoderError? {
        lock.lock()
        defer { lock.unlock() }
        return state.lastError
    }

    public var currentFormat: OpusStreamFormat? {
        lock.lock()
        defer { lock.unlock() }
        return state.configuration?.streamFormat
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.isRunning
    }

    public func configure(format: OpusStreamFormat) -> Bool {
        do {
            try configureThrowing(format: format)
            return true
        } catch let error as OpusDecoderError {
            setError(error)
            return false
        } catch {
            setError(.unexpected(error.localizedDescription))
            return false
        }
    }

    public func configureThrowing(format: OpusStreamFormat) throws {
        let configuration = try Self.validate(format: format)
        var opusError: Int32 = Int32(OPUS_OK)
        let newDecoder = configuration.mapping.withUnsafeBufferPointer { mapping in
            opus_multistream_decoder_create(
                Int32(format.sampleRate),
                Int32(format.channelCount),
                Int32(format.streamCount),
                Int32(format.coupledStreamCount),
                mapping.baseAddress!,
                &opusError
            )
        }
        guard let newDecoder, opusError == OPUS_OK else {
            if let newDecoder {
                opus_multistream_decoder_destroy(newDecoder)
            }
            throw OpusDecoderError.decoderCreationFailed(
                code: opusError,
                message: opusMessage(opusError)
            )
        }

        lock.lock()
        let oldDecoder = state.decoder
        state.decoder = newDecoder
        state.configuration = configuration
        state.isRunning = false
        state.lastError = nil
        renderer?.flush()
        lock.unlock()

        if let oldDecoder {
            opus_multistream_decoder_destroy(oldDecoder)
        }
    }

    public func start() {
        lock.lock()
        guard state.decoder != nil, state.configuration != nil else {
            state.lastError = .notConfigured
            lock.unlock()
            return
        }
        state.isRunning = true
        state.lastError = nil
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        state.isRunning = false
        if let decoder = state.decoder {
            let result = Int32(umbra_opus_multistream_decoder_reset(decoder))
            state.lastError = result == OPUS_OK
                ? nil
                : .resetFailed(code: result, message: opusMessage(result))
        } else {
            state.lastError = nil
        }
        renderer?.flush()
        lock.unlock()
    }

    public func cleanUp() {
        lock.lock()
        state.isRunning = false
        let decoder = state.decoder
        state.decoder = nil
        state.configuration = nil
        state.lastError = nil
        renderer?.flush()
        lock.unlock()

        if let decoder {
            opus_multistream_decoder_destroy(decoder)
        }
    }

    public func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let decoder = state.decoder else {
            state.lastError = .notConfigured
            throw OpusDecoderError.notConfigured
        }
        let result = Int32(umbra_opus_multistream_decoder_reset(decoder))
        guard result == OPUS_OK else {
            let error = OpusDecoderError.resetFailed(code: result, message: opusMessage(result))
            state.lastError = error
            throw error
        }
        state.lastError = nil
        renderer?.flush()
    }

    public func resetForDiscontinuity() throws {
        try reset()
    }

    /// Synchronously decodes one owned packet. Empty packets intentionally invoke
    /// libopus packet-loss concealment, matching moonlight-common-c semantics.
    public func decode(packet: CompressedAudioPacket) throws -> InterleavedPCMFrame {
        lock.lock()
        defer { lock.unlock() }
        do {
            let frame = try decodeLocked(packet: packet)
            state.lastError = nil
            return frame
        } catch let error as OpusDecoderError {
            state.lastError = error
            throw error
        }
    }

    public func submit(packet: CompressedAudioPacket) {
        lock.lock()
        guard let renderer else {
            state.lastError = .rendererUnavailable
            lock.unlock()
            return
        }
        do {
            let frame = try decodeLocked(packet: packet)
            let buffer = try frame.makeAudioBuffer()
            // Keeping the lifecycle lock through enqueue means stop/cleanup cannot
            // return while a decoded buffer is still crossing into the renderer.
            renderer.enqueue(DecodedAudioBuffer(buffer: buffer))
            state.lastError = nil
        } catch let error as OpusDecoderError {
            state.lastError = error
        } catch {
            state.lastError = .unexpected(error.localizedDescription)
        }
        lock.unlock()
    }

    private func decodeLocked(packet: CompressedAudioPacket) throws -> InterleavedPCMFrame {
        guard let decoder = state.decoder, let configuration = state.configuration else {
            throw OpusDecoderError.notConfigured
        }
        guard state.isRunning else {
            throw OpusDecoderError.notRunning
        }
        guard packet.data.count <= Self.maximumMoonlightPacketSize else {
            throw OpusDecoderError.packetTooLarge(
                maximum: Self.maximumMoonlightPacketSize,
                actual: packet.data.count
            )
        }

        let channelCount = configuration.streamFormat.channelCount
        let frameCapacity = configuration.streamFormat.samplesPerFrame
        var samples = [Float](repeating: 0, count: frameCapacity * channelCount)
        let decodedFrames = samples.withUnsafeMutableBufferPointer { output in
            if packet.data.isEmpty {
                return opus_multistream_decode_float(
                    decoder,
                    nil,
                    0,
                    output.baseAddress!,
                    Int32(frameCapacity),
                    0
                )
            }
            return packet.data.withUnsafeBytes { packetBytes in
                opus_multistream_decode_float(
                    decoder,
                    packetBytes.bindMemory(to: UInt8.self).baseAddress,
                    Int32(packet.data.count),
                    output.baseAddress!,
                    Int32(frameCapacity),
                    0
                )
            }
        }

        guard decodedFrames >= 0 else {
            let code = Int32(decodedFrames)
            throw OpusDecoderError.decodingFailed(code: code, message: opusMessage(code))
        }
        let decodedFrameCount = Int(decodedFrames)
        guard decodedFrameCount <= frameCapacity else {
            throw OpusDecoderError.invalidDecodedFrameLength(decodedFrameCount)
        }
        samples.removeSubrange((decodedFrameCount * channelCount)..<samples.count)
        return InterleavedPCMFrame(
            sampleRate: Double(configuration.streamFormat.sampleRate),
            layout: configuration.layout,
            frameLength: decodedFrameCount,
            samples: samples
        )
    }

    private static func validate(format: OpusStreamFormat) throws -> Configuration {
        guard let layout = AudioOutputLayout(audioConfiguration: format.audioConfiguration) else {
            throw OpusDecoderError.unsupportedAudioConfiguration(format.audioConfiguration)
        }
        let expectedChannels = Int(layout.channelCount)
        guard format.channelCount == expectedChannels else {
            throw OpusDecoderError.channelCountMismatch(
                expected: expectedChannels,
                actual: format.channelCount
            )
        }
        guard [8_000, 12_000, 16_000, 24_000, 48_000].contains(format.sampleRate) else {
            throw OpusDecoderError.unsupportedSampleRate(format.sampleRate)
        }
        guard (1...255).contains(format.streamCount) else {
            throw OpusDecoderError.invalidStreamCount(format.streamCount)
        }
        guard format.coupledStreamCount >= 0,
              format.coupledStreamCount <= format.streamCount,
              format.streamCount + format.coupledStreamCount <= 255 else {
            throw OpusDecoderError.invalidCoupledStreamCount(
                streamCount: format.streamCount,
                coupledStreamCount: format.coupledStreamCount
            )
        }

        let minimumFrameSize = format.sampleRate / 400 // 2.5 ms
        let maximumFrameSize = format.sampleRate * 120 / 1_000
        guard format.samplesPerFrame >= minimumFrameSize,
              format.samplesPerFrame <= maximumFrameSize,
              format.samplesPerFrame.isMultiple(of: minimumFrameSize) else {
            throw OpusDecoderError.invalidSamplesPerFrame(
                samples: format.samplesPerFrame,
                sampleRate: format.sampleRate
            )
        }
        guard format.mapping.count >= format.channelCount else {
            throw OpusDecoderError.mappingTooShort(
                expected: format.channelCount,
                actual: format.mapping.count
            )
        }

        let codedChannelCount = format.streamCount + format.coupledStreamCount
        let mapping = Array(format.mapping.prefix(format.channelCount))
        for (channel, value) in mapping.enumerated()
        where value != 255 && Int(value) >= codedChannelCount {
            throw OpusDecoderError.invalidMapping(
                channel: channel,
                value: value,
                codedChannelCount: codedChannelCount
            )
        }
        return Configuration(streamFormat: format, layout: layout, mapping: mapping)
    }

    private func setError(_ error: OpusDecoderError) {
        lock.lock()
        state.lastError = error
        lock.unlock()
    }
}

private func opusMessage(_ code: Int32) -> String {
    guard let message = opus_strerror(code) else { return "Unknown libopus error" }
    return String(cString: message)
}
