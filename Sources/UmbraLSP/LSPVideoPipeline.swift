import Foundation
import UmbraLSPTransport
import UmbraMedia

/// Hardware-only SDR VideoToolbox and Metal boundary for one LSP video generation.
public final class LSPVideoPipeline: @unchecked Sendable {
    private struct FrameState {
        var recoveryEpoch: UInt32
        var independent: Bool
    }

    private struct State {
        var configuration: LSPVideoConfigurationRequest?
        var decoder: VideoToolboxDecoder?
        var outstanding: [UInt64: FrameState] = [:]
        var pendingCommits: Set<UInt64> = []
        var active = false
    }

    private let transport: LSPTransport
    private let renderer: any MetalVideoRendering
    private let lock = NSLock()
    private var state = State()

    public init(transport: LSPTransport, renderer: any MetalVideoRendering) {
        self.transport = transport
        self.renderer = renderer
        transport.setVideoFrameHandler { [weak self] frame in
            self?.submit(frame)
        }
    }

    /// Builds the real hardware decoder before native admission and VIDEO_CONFIG_ACK.
    /// Duplicate authenticated configuration returns without rebuilding.
    @discardableResult
    public func configure(_ request: LSPVideoConfigurationRequest) throws -> Bool {
        if lock.withLock({ state.configuration == request }) { return false }
        let native = request.nativeConfiguration
        let codecMask: Int32 = native.codec == 2 ? 0x0100 : 0x0001
        var initialization = Data()
        for parameterSet in request.parameterSets {
            initialization.append(contentsOf: [0, 0, 0, 1])
            initialization.append(parameterSet)
        }
        let decoder = VideoToolboxDecoder(
            renderer: renderer,
            policy: .hardwareOnly,
            maximumOutstandingFrames: Int(native.decoderSurfaces),
            capacityPolicy: .dropNewestWhenFull,
            capacityOverflowBehavior: .dropWithoutRecovery
        )
        try decoder.configureThrowing(format: VideoStreamFormat(
            codecMask: codecMask,
            width: Int(native.width),
            height: Int(native.height),
            redrawRate: max(1, Int((Double(native.refreshNumerator) / Double(native.refreshDenominator)).rounded()))
        ))
        decoder.setHDRMode(enabled: false, metadata: nil)
        try decoder.prepareCodecInitializationThrowing(initialization, payloadFormat: .annexB)
        decoder.installDecodeOutcomeHandler { [weak self] outcome in self?.decoded(outcome) }
        decoder.start()
        do {
            try transport.configureVideo(native)
        } catch {
            decoder.stop()
            decoder.cleanUp()
            throw error
        }
        let old = lock.withLock { () -> VideoToolboxDecoder? in
            let old = state.decoder
            state.configuration = request
            state.decoder = decoder
            state.outstanding.removeAll(keepingCapacity: true)
            state.pendingCommits.removeAll(keepingCapacity: true)
            state.active = false
            return old
        }
        old?.stop()
        old?.cleanUp()
        return true
    }

    /// Transfers renderer reporting only after VIDEO_CONFIG_ACK was submitted.
    public func activate() throws {
        renderer.setMailboxDropNewest(true)
        renderer.installCommandCommitHandler { [weak self] frameNumber in
            self?.reportCommit(frameNumber: frameNumber)
        }
        lock.withLock { state.active = true }
        do {
            guard let generation = lock.withLock({ state.configuration?.nativeConfiguration.videoGeneration }) else {
                throw LSPTransportError.invalidState
            }
            try transport.activateVideo(videoGeneration: generation)
        } catch {
            lock.withLock { state.active = false }
            renderer.installCommandCommitHandler { _ in }
            renderer.setMailboxDropNewest(false)
            throw error
        }
    }

    /// Stops publication, drains VT callbacks, flushes mailbox ownership, and releases frame handles.
    public func stop() {
        transport.setVideoFrameHandler(nil)
        let decoder = lock.withLock { () -> VideoToolboxDecoder? in
            defer { state = State() }
            return state.decoder
        }
        decoder?.stop()
        decoder?.cleanUp()
        renderer.installCommandCommitHandler { _ in }
        renderer.flush()
        renderer.setMailboxDropNewest(false)
    }

    public func disablePublication() {
        transport.setVideoFrameHandler(nil)
    }

    public func abortConfiguration() {
        let decoder = lock.withLock { () -> VideoToolboxDecoder? in
            defer { state = State() }
            return state.decoder
        }
        decoder?.stop()
        decoder?.cleanUp()
    }

    public func retireAfterHandoff() {
        transport.setVideoFrameHandler(nil)
        let decoder = lock.withLock { () -> VideoToolboxDecoder? in
            defer { state = State() }
            return state.decoder
        }
        guard let decoder else { return }
        decoder.stop()
        decoder.cleanUp()
        renderer.flush()
    }

    private func submit(_ frame: LSPVideoFrame) {
        let ticket = lock.withLock { () -> (VideoToolboxDecoder, LSPNativeVideoConfiguration)? in
            guard let request = state.configuration,
                  state.active,
                  request.nativeConfiguration.videoGeneration == frame.videoGeneration,
                  request.nativeConfiguration.codec == frame.codec,
                  let decoder = state.decoder else { return nil }
            let native = request.nativeConfiguration
            guard state.outstanding.count < Int(native.decoderSurfaces),
                  let frameNumber = Int(exactly: frame.frameID) else { return nil }
            state.outstanding[frame.frameID] = FrameState(
                recoveryEpoch: frame.recoveryEpoch,
                independent: frame.independent
            )
            _ = frameNumber
            return (decoder, native)
        }
        guard let ticket else {
            reportDrop(frame, status: .surfaceExhausted)
            return
        }
        let disposition = ticket.0.submit(frame: CompressedVideoFrame(
            data: frame.annexBAccessUnit,
            payloadFormat: .annexB,
            frameNumber: Int(frame.frameID),
            isKeyFrame: frame.independent,
            requiresIndependentDecode: frame.independent,
            receiveTimeMicroseconds: frame.receiveTimeMicroseconds,
            enqueueTimeMicroseconds: frame.receiveTimeMicroseconds,
            presentationTimeMicroseconds: frame.captureTimeMicroseconds,
            rtpTimestamp: frame.rtpTimestamp,
            isHDR: false,
            colorSpace: 1,
            isFullRange: false,
            hostCaptureTimeMicroseconds: frame.captureTimeMicroseconds,
            appliedInputStateSequence: frame.inputStateSequence,
            appliedInputEdgeID: frame.inputEdgeID,
            videoConfigurationGeneration: frame.videoGeneration
        ))
        if disposition == .capacityDropped {
            finish(frameID: frame.frameID, status: .surfaceExhausted)
        } else if disposition == .requestKeyFrame {
            finish(frameID: frame.frameID, status: frame.independent ? .unrecoverableError : .recoverableError)
        }
    }

    private func decoded(_ outcome: VideoDecodeOutcome) {
        switch outcome {
        case .decoded(let frameNumber): finish(frameID: UInt64(frameNumber), status: .ready)
        case .failed(let frameNumber):
            let independent = lock.withLock { state.outstanding[UInt64(frameNumber)]?.independent ?? false }
            finish(frameID: UInt64(frameNumber), status: independent ? .unrecoverableError : .recoverableError)
        }
    }

    private func finish(frameID: UInt64, status: LSPVideoDecodeStatus) {
        let report = lock.withLock { () -> (UInt32, FrameState, UInt8)? in
            guard let configuration = state.configuration?.nativeConfiguration,
                  let frame = state.outstanding.removeValue(forKey: frameID) else { return nil }
            let credit = UInt8(max(0, Int(configuration.decoderSurfaces) - state.outstanding.count))
            return (configuration.videoGeneration, frame, credit)
        }
        guard let report else { return }
        do {
            try transport.reportVideoDecode(
                videoGeneration: report.0,
                frameID: frameID,
                recoveryEpoch: report.1.recoveryEpoch,
                status: status,
                availableCredit: report.2,
                mailboxOccupancy: status == .ready ? 1 : 0
            )
            let commitWasPending = lock.withLock { state.pendingCommits.remove(frameID) != nil }
            if commitWasPending {
                try? transport.reportVideoCommit(videoGeneration: report.0, frameID: frameID, mailboxOccupancy: 0)
            }
        } catch {
            _ = lock.withLock { state.pendingCommits.remove(frameID) }
        }
    }

    private func reportDrop(_ frame: LSPVideoFrame, status: LSPVideoDecodeStatus) {
        let credit = lock.withLock { () -> UInt8 in
            guard let configuration = state.configuration?.nativeConfiguration else { return 0 }
            return UInt8(max(0, Int(configuration.decoderSurfaces) - state.outstanding.count))
        }
        try? transport.reportVideoDecode(
            videoGeneration: frame.videoGeneration,
            frameID: frame.frameID,
            recoveryEpoch: frame.recoveryEpoch,
            status: status,
            availableCredit: credit,
            mailboxOccupancy: 1
        )
    }

    private func reportCommit(frameNumber: Int) {
        guard let frameID = UInt64(exactly: frameNumber),
              let result = lock.withLock({ () -> (UInt32, Bool)? in
                  guard let generation = state.configuration?.nativeConfiguration.videoGeneration else { return nil }
                  if state.outstanding[frameID] != nil {
                      state.pendingCommits.insert(frameID)
                      return (generation, false)
                  }
                  return (generation, true)
              })
        else { return }
        guard result.1 else { return }
        try? transport.reportVideoCommit(
            videoGeneration: result.0,
            frameID: frameID,
            mailboxOccupancy: 0
        )
    }
}
