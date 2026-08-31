import Dispatch
import Foundation
import UmbraMicrophone
import UmbraOpus
import UmbraLSPTransport

/// Real AudioQueue capture and mono Opus encoder feeding CLSPCore's RTP/SRTP sender.
public final class LSPMicrophoneUplink: @unchecked Sendable {
    private struct Pipeline {
        var configuration: LSPNativeMicrophoneConfiguration
        var capture: AudioQueueMicrophoneCapture
        var encoder: MonoOpusEncoder
    }

    private let lock = NSLock()
    private let controlQueue = DispatchQueue(label: "app.umbra.lsp-microphone-control", qos: .userInitiated)
    private var pipeline: Pipeline?
    private var failureHandler: (@Sendable (Error) -> Void)?

    /// Prepares native mapping, encoder, and live capture before MICROPHONE_CONFIG_ACK.
    public func configure(
        _ configuration: LSPNativeMicrophoneConfiguration,
        transport: LSPTransport,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        let encoder = try MonoOpusEncoder(
            bitrate: Int32(configuration.bitrate),
            inbandFECEnabled: configuration.inbandFEC,
            dtxEnabled: configuration.dtx
        )
        let capture = AudioQueueMicrophoneCapture()
        try transport.configureMicrophone(configuration)
        do {
            try capture.start(
                frameHandler: { [weak self, encoder, transport] frame in
                    guard self != nil else { return }
                    do {
                        let packet = try encoder.encode(samples: frame.samples)
                        guard !packet.isEmpty else { return }
                        try transport.submitMicrophonePacket(Data(packet))
                    } catch LSPTransportError.resourceExhausted {
                        try? transport.markMicrophoneDiscontinuity()
                    } catch {
                        try? transport.stopMicrophone()
                        self?.scheduleFailure(error)
                    }
                },
                discontinuityHandler: { [encoder, transport] in
                    try? encoder.reset()
                    try? transport.markMicrophoneDiscontinuity()
                },
                failureHandler: { [weak self, transport] error in
                    try? transport.stopMicrophone()
                    self?.scheduleFailure(error)
                }
            )
        } catch {
            try? transport.stopMicrophone()
            encoder.close()
            throw error
        }

        let old = lock.withLock { () -> Pipeline? in
            self.failureHandler = failureHandler
            defer { pipeline = Pipeline(configuration: configuration, capture: capture, encoder: encoder) }
            return pipeline
        }
        old?.capture.stop()
        old?.encoder.close()
    }

    /// Stops capture first, then prevents and clears all native stale packets.
    public func stop(transport: LSPTransport) {
        let old = lock.withLock { () -> Pipeline? in
            defer {
                pipeline = nil
                failureHandler = nil
            }
            return pipeline
        }
        old?.capture.stop()
        old?.encoder.close()
        try? transport.stopMicrophone()
    }

    public func isConfigured(for generation: UInt32) -> Bool {
        lock.withLock { pipeline?.configuration.microphoneGeneration == generation }
    }

    private func scheduleFailure(_ error: Error) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            let callback = lock.withLock { failureHandler }
            callback?(error)
        }
    }
}
