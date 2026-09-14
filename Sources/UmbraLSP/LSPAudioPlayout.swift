import Dispatch
import Darwin
import Foundation
import UmbraMedia
import UmbraOpus
import UmbraLSPTransport

/// Production Opus multistream decoder and AudioQueue playout owner for one LSP association.
public final class LSPAudioPlayout: @unchecked Sendable {
    private struct Pipeline {
        var configuration: LSPNativeAudioConfiguration
        var renderer: AudioQueuePCMRenderer
        var decoder: OpusMultistreamDecoder
    }

    private let lock = NSLock()
    private let decodeQueue = DispatchQueue(label: "app.umbra.lsp-audio", qos: .userInteractive)
    private var pipeline: Pipeline?
    private var pendingPacket: LSPAudioPacket?
    private var expectedSequence: UInt16?
    private var lastDecodedTimestamp: UInt32?
    private var latestTiming: LSPAudioTiming?
    private var frameDuration: TimeInterval = 0.010
    private var receiveTimes: [UInt64: UInt64] = [:]
    private var receiveToDecode = LSPFixedDurationWindow()
    private var decodeAndRenderEnqueue = LSPFixedDurationWindow()

    /// Builds and starts the real decoder/renderer before native packet admission is ACKed.
    public func configure(_ configuration: LSPNativeAudioConfiguration) throws {
        let layout: AudioOutputLayout = switch configuration.channels {
        case 2: .stereo
        case 6: .surround51
        case 8: .surround71
        default: throw LSPTransportError.invalidConfiguration
        }
        let frameDuration = Double(configuration.frameSamples) / 48_000.0
        let renderer = AudioQueuePCMRenderer(configuration: PCMRendererConfiguration(
            sampleRate: 48_000,
            layout: layout,
            maximumQueuedBuffers: 16,
            maximumQueuedDuration: max(frameDuration * 4.0, 0.020),
            outputBufferDuration: frameDuration,
            minimumPreRollDuration: frameDuration,
            rebufferPreRollDuration: frameDuration * 2.0,
            muteWhileInactive: true
        ))
        let decoder = OpusMultistreamDecoder(renderer: renderer)
        try decoder.configureThrowing(format: OpusStreamFormat(
            audioConfiguration: layout.audioConfiguration,
            sampleRate: 48_000,
            channelCount: Int(configuration.channels),
            streamCount: Int(configuration.streams),
            coupledStreamCount: Int(configuration.coupledStreams),
            samplesPerFrame: Int(configuration.frameSamples),
            mapping: configuration.mapping
        ))
        try renderer.start()
        decoder.start()

        let old = lock.withLock { () -> Pipeline? in
            defer { pipeline = Pipeline(configuration: configuration, renderer: renderer, decoder: decoder) }
            return pipeline
        }
        decodeQueue.sync {
            pendingPacket = nil
            expectedSequence = nil
            lastDecodedTimestamp = nil
            receiveTimes.removeAll(keepingCapacity: true)
            self.frameDuration = frameDuration
        }
        old?.decoder.stop()
        _ = old?.renderer.stop()
    }

    /// Queues one complete native-authenticated Opus packet for decode and AudioQueue playout.
    public func submit(_ packet: LSPAudioPacket) {
        let receiveTime = Self.monotonicMicroseconds()
        decodeQueue.async { [weak self] in
            guard let self else { return }
            let decoder = lock.withLock { () -> OpusMultistreamDecoder? in
                guard let pipeline,
                      pipeline.configuration.audioGeneration == packet.audioGeneration,
                      pipeline.configuration.audioSSRC == packet.ssrc
                else { return nil }
                return pipeline.decoder
            }
            guard let decoder else { return }
            if self.receiveTimes.count >= 64 {
                self.receiveTimes.removeAll(keepingCapacity: true)
                self.lock.withLock { self.receiveToDecode.drop() }
            }
            self.receiveTimes[Self.packetKey(packet)] = receiveTime
            process(packet, decoder: decoder)
        }
    }

    /// Retains the latest authenticated NTP-to-48-kHz sender-report relation.
    public func receiveTiming(_ timing: LSPAudioTiming) {
        lock.withLock {
            guard let pipeline,
                  pipeline.configuration.audioGeneration == timing.audioGeneration,
                  pipeline.configuration.audioSSRC == timing.ssrc
            else { return }
            latestTiming = timing
        }
    }

    /// Stops decoder and AudioQueue ownership for a retired association.
    public func stop() {
        decodeQueue.sync {
            pendingPacket = nil
            expectedSequence = nil
            lastDecodedTimestamp = nil
            receiveTimes.removeAll(keepingCapacity: true)
        }
        let old = lock.withLock { () -> Pipeline? in
            defer { pipeline = nil }
            return pipeline
        }
        old?.decoder.stop()
        _ = old?.renderer.stop()
    }

    private func process(_ packet: LSPAudioPacket, decoder: OpusMultistreamDecoder) {
        if packet.marker {
            try? decoder.resetForDiscontinuity()
            expectedSequence = packet.sequenceNumber
            lastDecodedTimestamp = nil
            hold(packet, decoder: decoder)
            return
        }
        guard let expected = expectedSequence else {
            expectedSequence = packet.sequenceNumber
            hold(packet, decoder: decoder)
            return
        }
        guard let pending = pendingPacket else {
            let distance = packet.sequenceNumber &- expected
            guard distance <= 1 else {
                try? decoder.resetForDiscontinuity()
                expectedSequence = packet.sequenceNumber
                lastDecodedTimestamp = nil
                hold(packet, decoder: decoder)
                return
            }
            hold(packet, decoder: decoder)
            return
        }

        let pendingDistance = pending.sequenceNumber &- expected
        let incomingDistance = packet.sequenceNumber &- expected
        if incomingDistance > 0x7FFF || incomingDistance == pendingDistance {
            return
        }
        if pendingDistance == 1, incomingDistance == 0 {
            decode(packet, with: decoder)
            expectedSequence = expected &+ 1
            return
        }
        if pendingDistance == 0 {
            decode(pending, with: decoder)
            let next = expected &+ 1
            expectedSequence = next
            pendingPacket = nil
            let distance = packet.sequenceNumber &- next
            if distance <= 1 {
                hold(packet, decoder: decoder)
            } else if distance <= 0x7FFF {
                try? decoder.resetForDiscontinuity()
                expectedSequence = packet.sequenceNumber
                lastDecodedTimestamp = nil
                hold(packet, decoder: decoder)
            }
            return
        }
        if pendingDistance == 1, incomingDistance > 1, incomingDistance <= 0x7FFF {
            decoder.submit(packet: CompressedAudioPacket(data: Data()))
            expectedSequence = expected &+ 1
            decode(pending, with: decoder)
            expectedSequence = expected &+ 2
            hold(packet, decoder: decoder)
            return
        }
        try? decoder.resetForDiscontinuity()
        expectedSequence = packet.sequenceNumber
        lastDecodedTimestamp = nil
        hold(packet, decoder: decoder)
    }

    private func decode(_ packet: LSPAudioPacket, with decoder: OpusMultistreamDecoder) {
        let decodeStart = Self.monotonicMicroseconds()
        let receiveTime = receiveTimes.removeValue(forKey: Self.packetKey(packet))
        decoder.submit(packet: CompressedAudioPacket(data: packet.opusPacket))
        let renderEnqueue = Self.monotonicMicroseconds()
        lock.withLock {
            if let receiveTime, decodeStart >= receiveTime {
                receiveToDecode.record(decodeStart - receiveTime)
            } else {
                receiveToDecode.drop()
            }
            if renderEnqueue >= decodeStart {
                decodeAndRenderEnqueue.record(renderEnqueue - decodeStart)
            } else {
                decodeAndRenderEnqueue.drop()
            }
        }
        lastDecodedTimestamp = packet.timestamp
    }

    public func telemetrySnapshot() -> LSPProductTelemetrySnapshot {
        lock.withLock {
            let statistics = pipeline?.renderer.statistics
            return .init(
                completeFrameReceiveToVideoToolboxSubmit: nil,
                videoToolboxSubmitToDecodeCompletion: nil,
                completeFrameReceiveToMetalEnqueue: nil,
                metalEnqueueToCommit: nil,
                metalCommitToCompletion: nil,
                audioReceiveToDecode: receiveToDecode.snapshot(),
                audioDecodeAndRenderEnqueue: decodeAndRenderEnqueue.snapshot(),
                audioUnderruns: statistics?.underrunCount,
                audioRebuffers: statistics?.rebufferCount,
                reconnectDuration: nil
            )
        }
    }

    private static func packetKey(_ packet: LSPAudioPacket) -> UInt64 {
        (UInt64(packet.audioGeneration) << 16) | UInt64(packet.sequenceNumber)
    }

    private static func monotonicMicroseconds() -> UInt64 {
        max(1, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000)
    }

    private func hold(_ packet: LSPAudioPacket, decoder: OpusMultistreamDecoder) {
        pendingPacket = packet
        let generation = packet.audioGeneration
        let sequence = packet.sequenceNumber
        decodeQueue.asyncAfter(deadline: .now() + frameDuration) { [weak self, decoder] in
            guard let self,
                  let pending = pendingPacket,
                  pending.audioGeneration == generation,
                  pending.sequenceNumber == sequence,
                  let expected = expectedSequence
            else { return }
            let distance = pending.sequenceNumber &- expected
            if distance == 1 {
                decoder.submit(packet: CompressedAudioPacket(data: Data()))
                expectedSequence = expected &+ 1
            } else if distance != 0 {
                return
            }
            decode(pending, with: decoder)
            expectedSequence = pending.sequenceNumber &+ 1
            pendingPacket = nil
        }
    }
}
