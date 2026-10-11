import Dispatch
import Darwin
import Foundation
import UmbraMedia
import UmbraOpus
import UmbraLSPTransport

struct LSPAudioSequenceState {
    struct PendingToken: Equatable {
        fileprivate let epoch: UInt64
    }

    enum Action: Equatable {
        case reset
        case conceal
        case decode(LSPAudioPacket)
        case discard(LSPAudioPacket)
        case schedule(PendingToken)
    }

    private(set) var expectedSequence: UInt16?
    private(set) var pendingPacket: LSPAudioPacket?
    private var pendingEpoch: UInt64 = 0

    mutating func invalidate() {
        pendingEpoch &+= 1
        expectedSequence = nil
        pendingPacket = nil
    }

    mutating func submit(
        _ packet: LSPAudioPacket,
        maximumConcealedFrames: Int
    ) -> [Action] {
        let concealmentLimit = max(0, maximumConcealedFrames)
        guard let expected = expectedSequence else {
            expectedSequence = packet.sequenceNumber &+ 1
            return packet.marker ? [.reset, .decode(packet)] : [.decode(packet)]
        }

        let incomingDistance = packet.sequenceNumber &- expected
        guard incomingDistance <= 0x7FFF,
              pendingPacket?.sequenceNumber != packet.sequenceNumber
        else { return [.discard(packet)] }

        if packet.marker {
            var actions = pendingPacket.map { [Action.discard($0)] } ?? []
            invalidatePending()
            expectedSequence = packet.sequenceNumber &+ 1
            actions.append(contentsOf: [.reset, .decode(packet)])
            return actions
        }

        if let pending = pendingPacket {
            if incomingDistance == 0 {
                invalidatePending()
                expectedSequence = pending.sequenceNumber &+ 1
                return [.decode(packet), .decode(pending)]
            }
            let missingFrames = Int(incomingDistance) - 1
            guard missingFrames <= concealmentLimit else {
                invalidatePending()
                expectedSequence = packet.sequenceNumber &+ 1
                return [.discard(pending), .reset, .decode(packet)]
            }
            invalidatePending()
            expectedSequence = packet.sequenceNumber &+ 1
            return [.conceal, .decode(pending)]
                + Array(repeating: .conceal, count: missingFrames - 1)
                + [.decode(packet)]
        }

        if incomingDistance == 0 {
            expectedSequence = packet.sequenceNumber &+ 1
            return [.decode(packet)]
        }
        if incomingDistance == 1 {
            return [hold(packet)]
        }
        guard Int(incomingDistance) <= concealmentLimit else {
            expectedSequence = packet.sequenceNumber &+ 1
            return [.reset, .decode(packet)]
        }
        expectedSequence = packet.sequenceNumber &+ 1
        return Array(repeating: .conceal, count: Int(incomingDistance)) + [.decode(packet)]
    }

    mutating func expire(_ token: PendingToken) -> [Action] {
        guard token.epoch == pendingEpoch,
              let pending = pendingPacket,
              let expected = expectedSequence
        else { return [] }

        guard pending.sequenceNumber &- expected == 1 else { return [] }
        invalidatePending()
        expectedSequence = pending.sequenceNumber &+ 1
        return [.conceal, .decode(pending)]
    }

    private mutating func hold(_ packet: LSPAudioPacket) -> Action {
        pendingEpoch &+= 1
        pendingPacket = packet
        return .schedule(PendingToken(epoch: pendingEpoch))
    }

    private mutating func invalidatePending() {
        pendingEpoch &+= 1
        pendingPacket = nil
    }
}

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
    private var sequenceState = LSPAudioSequenceState()
    private var lastDecodedTimestamp: UInt32?
    private var latestTiming: LSPAudioTiming?
    private var frameDuration: TimeInterval = 0.010
    private var maximumConcealedFrames = 4
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
            minimumPreRollDuration: frameDuration * 2.0,
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

        let old = decodeQueue.sync { () -> Pipeline? in
            sequenceState.invalidate()
            lastDecodedTimestamp = nil
            receiveTimes.removeAll(keepingCapacity: true)
            self.frameDuration = frameDuration
            maximumConcealedFrames = max(1, 1_920 / Int(configuration.frameSamples))
            return lock.withLock {
                defer {
                    pipeline = Pipeline(
                        configuration: configuration,
                        renderer: renderer,
                        decoder: decoder
                    )
                }
                return pipeline
            }
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
        let old = decodeQueue.sync { () -> Pipeline? in
            sequenceState.invalidate()
            lastDecodedTimestamp = nil
            receiveTimes.removeAll(keepingCapacity: true)
            return lock.withLock {
                defer { pipeline = nil }
                return pipeline
            }
        }
        old?.decoder.stop()
        _ = old?.renderer.stop()
    }

    private func process(_ packet: LSPAudioPacket, decoder: OpusMultistreamDecoder) {
        perform(
            sequenceState.submit(packet, maximumConcealedFrames: maximumConcealedFrames),
            decoder: decoder
        )
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
                audioAcceptedPackets: statistics?.enqueuedBuffers,
                audioPlayedPackets: statistics?.playedBuffers,
                audioDroppedPackets: statistics?.droppedBuffers,
                audioRejectedPackets: statistics?.rejectedBuffers,
                audioCallbackCount: statistics?.callbackCount,
                audioCallbackError: statistics?.callbackError,
                audioNonSilentPackets: statistics?.nonSilentAcceptedPackets,
                audioQueuedMilliseconds: statistics?.queuedDurationMilliseconds,
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

    private func perform(
        _ actions: [LSPAudioSequenceState.Action],
        decoder: OpusMultistreamDecoder
    ) {
        for action in actions {
            switch action {
            case .reset:
                try? decoder.resetForDiscontinuity()
                lastDecodedTimestamp = nil
            case .conceal:
                decoder.submit(packet: CompressedAudioPacket(data: Data()))
            case let .decode(packet):
                decode(packet, with: decoder)
            case let .discard(packet):
                receiveTimes.removeValue(forKey: Self.packetKey(packet))
            case let .schedule(token):
                decodeQueue.asyncAfter(deadline: .now() + frameDuration) { [weak self, decoder] in
                    guard let self,
                          lock.withLock({ pipeline?.decoder === decoder })
                    else { return }
                    perform(sequenceState.expire(token), decoder: decoder)
                }
            }
        }
    }
}
