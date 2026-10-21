import Darwin
import Foundation
import UmbraLSPTransport
import UmbraMedia

/// Hardware-only VideoToolbox and Metal boundary for one LSP video generation.
public final class LSPVideoPipeline: @unchecked Sendable {
    private struct FrameState {
        var recoveryEpoch: UInt32
        var independent: Bool
        var receiveTimeMicroseconds: UInt64
        var submitTimeMicroseconds: UInt64
        var enqueueTimeMicroseconds: UInt64?
        var reporting: Bool
    }

    private struct State {
        var configuration: LSPVideoConfigurationRequest?
        var decoder: (any LSPFrameDecoding)?
        var outstanding: [UInt64: FrameState] = [:]
        var pendingCommits: Set<UInt64> = []
        var enqueueTimes: [UInt64: UInt64] = [:]
        var active = false
        var terminal = false
        var accessUnitsReceived: UInt64 = 0
        var hostEncoderDuration = LSPFixedDurationWindow()
        var receiveToSubmit = LSPFixedDurationWindow()
        var submitToDecode = LSPFixedDurationWindow()
        var receiveToMetalEnqueue = LSPFixedDurationWindow()
        var metalEnqueueToCommit = LSPFixedDurationWindow()
    }

    private let transport: LSPTransport
    private let renderer: any MetalVideoRendering
    // Native feedback takes the transport mutex. Keep that work off both the
    // VideoToolbox callback and the Metal presentation thread. Native frame
    // credits bound the pending reports; release them only after reporting.
    private let feedbackQueue = DispatchQueue(label: "app.umbra.lsp-video-feedback", qos: .userInteractive)
    private let lock = NSLock()
    private var state = State()
    private var failureHandler: (@Sendable (LSPTransportError) -> Void)?
    // A frame that never gets a decode outcome holds a decoder credit forever.
    // Once every credit leaks, the host withholds video and no new frame arrives
    // to trigger cleanup, so expiry must run on a timer.
    private let outstandingExpiry: DispatchSourceTimer
    private static let outstandingFrameTimeoutMicroseconds: UInt64 = 1_000_000

    public init(transport: LSPTransport, renderer: any MetalVideoRendering) {
        self.transport = transport
        self.renderer = renderer
        outstandingExpiry = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        transport.setVideoAccessUnitHandler { [weak self] frame in
            self?.submit(frame)
        }
        outstandingExpiry.setEventHandler { [weak self] in
            self?.expireStaleOutstandingFrames()
        }
        outstandingExpiry.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        outstandingExpiry.resume()
    }

    deinit {
        outstandingExpiry.cancel()
    }

    public func setFailureHandler(_ handler: (@Sendable (LSPTransportError) -> Void)?) {
        lock.withLock { failureHandler = handler }
    }

    /// Builds the real hardware decoder before native admission and VIDEO_CONFIG_ACK.
    /// Duplicate authenticated configuration returns without rebuilding.
    @discardableResult
    public func configure(_ request: LSPVideoConfigurationRequest) throws -> Bool {
        if lock.withLock({ state.configuration == request }) { return false }
        let native = request.nativeConfiguration
        if native.codec == LSPVideoCodec.bc1.rawValue {
            let decoder = try BC1MetalDecoder(
                renderer: renderer,
                width: Int(native.width),
                height: Int(native.height),
                maximumOutstandingFrames: Int(native.decoderSurfaces)
            )
            return try install(decoder, request: request)
        }
        let codecMask = try Self.codecMask(native)
        guard let nativePayloadFormat = LSPVideoPayloadFormat(rawValue: native.payloadFormat) else {
            throw LSPTransportError.invalidConfiguration
        }
        let payloadFormat = Self.mediaPayloadFormat(nativePayloadFormat)
        var initialization = Data()
        switch nativePayloadFormat {
        case .annexB:
            for unit in request.codecConfiguration.units {
                initialization.append(contentsOf: [0, 0, 0, 1])
                initialization.append(unit)
            }
        case .av1LowOverheadOBU:
            guard request.codecConfiguration.units.count == 1 else {
                throw LSPTransportError.invalidConfiguration
            }
            initialization = request.codecConfiguration.units[0]
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
            redrawRate: max(1, Int((Double(native.refreshNumerator) / Double(native.refreshDenominator)).rounded())),
            colorRange: native.fullRange ? .full : .video,
            requiresExactDecodedFormat: true,
            colorPrimariesCode: native.colorPrimaries,
            transferCharacteristicsCode: native.transferCharacteristics,
            matrixCoefficientsCode: native.matrixCoefficients
        ))
        decoder.setHDRMode(
            enabled: native.transferCharacteristics != 1,
            metadata: Self.hdrMetadata(request.hdrMetadata, transfer: native.transferCharacteristics)
        )
        try decoder.prepareCodecInitializationThrowing(initialization, payloadFormat: payloadFormat)
        return try install(decoder, request: request)
    }

    private func install(_ decoder: any LSPFrameDecoding, request: LSPVideoConfigurationRequest) throws -> Bool {
        let native = request.nativeConfiguration
        decoder.installDecodeOutcomeHandler { [weak self] outcome in
            self?.decoded(outcome, videoGeneration: native.videoGeneration)
        }
        decoder.start()
        do {
            try transport.configureVideo(native)
        } catch {
            decoder.cleanUpPreservingRenderer()
            throw error
        }
        let old = lock.withLock { () -> (any LSPFrameDecoding)? in
            let old = state.decoder
            state.configuration = request
            state.decoder = decoder
            state.outstanding.removeAll(keepingCapacity: true)
            state.pendingCommits.removeAll(keepingCapacity: true)
            state.active = false
            state.terminal = false
            return old
        }
        old?.cleanUpPreservingRenderer()
        return true
    }

    /// Transfers renderer reporting only after VIDEO_CONFIG_ACK was submitted.
    public func activate() throws {
        guard let generation = lock.withLock({ state.configuration?.nativeConfiguration.videoGeneration }) else {
            throw LSPTransportError.invalidState
        }
        renderer.setMailboxDropNewest(false)
        renderer.installCommandCommitHandler { [weak self] frameNumber in
            self?.reportCommit(frameNumber: frameNumber, videoGeneration: generation)
        }
        renderer.installFrameDropHandler { [weak self] frameNumber, reason in
            self?.rendererDropped(
                frameNumber: frameNumber,
                reason: reason,
                videoGeneration: generation
            )
        }
        lock.withLock { state.active = true }
        do {
            try transport.activateVideo(videoGeneration: generation)
        } catch {
            lock.withLock { state.active = false }
            renderer.installCommandCommitHandler { _ in }
            renderer.installFrameDropHandler { _, _ in }
            renderer.setMailboxDropNewest(false)
            throw error
        }
    }

    /// Stops publication, drains VT callbacks, flushes mailbox ownership, and releases frame handles.
    public func stop() {
        transport.setVideoAccessUnitHandler(nil)
        let decoder = lock.withLock { () -> (any LSPFrameDecoding)? in
            defer { state = State() }
            return state.decoder
        }
        decoder?.cleanUpPreservingRenderer()
        renderer.installCommandCommitHandler { _ in }
        renderer.installFrameDropHandler { _, _ in }
        renderer.flush()
        renderer.setMailboxDropNewest(false)
    }

    public func disablePublication() {
        transport.setVideoAccessUnitHandler(nil)
    }

    public func abortConfiguration() {
        let decoder = lock.withLock { () -> (any LSPFrameDecoding)? in
            defer { state = State() }
            return state.decoder
        }
        decoder?.cleanUpPreservingRenderer()
    }

    public func retireAfterHandoff() {
        transport.setVideoAccessUnitHandler(nil)
        let decoder = lock.withLock { () -> (any LSPFrameDecoding)? in
            defer { state = State() }
            return state.decoder
        }
        decoder?.cleanUpPreservingRenderer()
    }

    private func submit(_ frame: LSPEncodedVideoAccessUnit) {
        let submitTime = Self.monotonicMicroseconds()
        let ticket = lock.withLock {
            () -> (decoder: any LSPFrameDecoding, native: LSPNativeVideoConfiguration, frameToken: Int)? in
            state.accessUnitsReceived &+= 1
            guard let request = state.configuration,
                  state.active,
                  request.nativeConfiguration.videoGeneration == frame.videoGeneration,
                  request.nativeConfiguration.codec == frame.codec,
                  request.nativeConfiguration.payloadFormat == frame.payloadFormat.rawValue,
                  let decoder = state.decoder else { return nil }
            let native = request.nativeConfiguration
            if let duration = frame.hostEncoderDurationMicroseconds {
                state.hostEncoderDuration.record(UInt64(duration))
            } else {
                state.hostEncoderDuration.drop()
            }
            guard state.outstanding.count < Int(native.decoderSurfaces) else {
                state.receiveToSubmit.drop()
                state.submitToDecode.drop()
                state.receiveToMetalEnqueue.drop()
                state.metalEnqueueToCommit.drop()
                return nil
            }
            if frame.receiveTimeMicroseconds > 0, submitTime >= frame.receiveTimeMicroseconds {
                state.receiveToSubmit.record(submitTime - frame.receiveTimeMicroseconds)
            } else {
                state.receiveToSubmit.drop()
            }
            state.outstanding[frame.frameID] = FrameState(
                recoveryEpoch: frame.recoveryEpoch,
                independent: frame.independent,
                receiveTimeMicroseconds: frame.receiveTimeMicroseconds,
                submitTimeMicroseconds: submitTime,
                enqueueTimeMicroseconds: nil,
                reporting: false
            )
            return (decoder, native, Self.mediaFrameToken(for: frame.frameID))
        }
        guard let ticket else {
            reportDrop(frame, status: .surfaceExhausted)
            return
        }
        let disposition = ticket.decoder.submit(frame: CompressedVideoFrame(
            data: frame.encodedAccessUnit,
            payloadFormat: Self.mediaPayloadFormat(frame.payloadFormat),
            frameNumber: ticket.frameToken,
            isKeyFrame: frame.independent,
            requiresIndependentDecode: frame.independent,
            receiveTimeMicroseconds: frame.receiveTimeMicroseconds,
            enqueueTimeMicroseconds: frame.receiveTimeMicroseconds,
            presentationTimeMicroseconds: frame.captureTimeMicroseconds,
            rtpTimestamp: frame.rtpTimestamp,
            isHDR: ticket.native.transferCharacteristics != 1,
            colorSpace: ticket.native.colorPrimaries == 9 ? VideoColorSpace.rec2020.rawValue :
                ticket.native.matrixCoefficients == 6 ? VideoColorSpace.rec601.rawValue : VideoColorSpace.rec709.rawValue,
            isFullRange: ticket.native.fullRange,
            hostCaptureTimeMicroseconds: frame.captureTimeMicroseconds,
            appliedInputStateSequence: frame.inputStateSequence,
            appliedInputEdgeID: frame.inputEdgeID,
            videoConfigurationGeneration: frame.videoGeneration
        ))
        if disposition == .capacityDropped {
            recordDecodeDrop(frameID: frame.frameID, videoGeneration: frame.videoGeneration)
            finish(
                frameID: frame.frameID,
                status: .surfaceExhausted,
                videoGeneration: frame.videoGeneration
            )
        } else if disposition == .requestKeyFrame {
            recordDecodeDrop(frameID: frame.frameID, videoGeneration: frame.videoGeneration)
            finish(
                frameID: frame.frameID,
                status: frame.independent ? .unrecoverableError : .recoverableError,
                videoGeneration: frame.videoGeneration
            )
        }
    }

    private func decoded(_ outcome: VideoDecodeOutcome, videoGeneration: UInt32) {
        switch outcome {
        case .decoded(let frameNumber):
            let frameID = Self.lspFrameID(from: frameNumber)
            recordDecodeAndEnqueue(frameID: frameID, videoGeneration: videoGeneration)
            finish(frameID: frameID, status: .ready, videoGeneration: videoGeneration)
        case .failed(let frameNumber):
            let frameID = Self.lspFrameID(from: frameNumber)
            recordDecodeDrop(frameID: frameID, videoGeneration: videoGeneration)
            let independent = lock.withLock {
                guard state.active,
                      state.configuration?.nativeConfiguration.videoGeneration == videoGeneration else { return false }
                return state.outstanding[frameID]?.independent ?? false
            }
            finish(
                frameID: frameID,
                status: independent ? .unrecoverableError : .recoverableError,
                videoGeneration: videoGeneration
            )
        }
    }

    private func recordDecodeDrop(frameID: UInt64, videoGeneration: UInt32) {
        lock.withLock {
            guard state.active,
                  state.configuration?.nativeConfiguration.videoGeneration == videoGeneration else { return }
            state.submitToDecode.drop()
            state.receiveToMetalEnqueue.drop()
            state.metalEnqueueToCommit.drop()
            state.enqueueTimes.removeValue(forKey: frameID)
        }
    }

    private func recordDecodeAndEnqueue(frameID: UInt64, videoGeneration: UInt32) {
        let now = Self.monotonicMicroseconds()
        lock.withLock {
            guard state.active,
                  state.configuration?.nativeConfiguration.videoGeneration == videoGeneration,
                  var frame = state.outstanding[frameID] else { return }
            if now >= frame.submitTimeMicroseconds {
                state.submitToDecode.record(now - frame.submitTimeMicroseconds)
            } else {
                state.submitToDecode.drop()
            }
            if frame.receiveTimeMicroseconds > 0, now >= frame.receiveTimeMicroseconds {
                state.receiveToMetalEnqueue.record(now - frame.receiveTimeMicroseconds)
            } else {
                state.receiveToMetalEnqueue.drop()
            }
            frame.enqueueTimeMicroseconds = now
            state.outstanding[frameID] = frame
            if state.pendingCommits.contains(frameID) {
                state.metalEnqueueToCommit.drop()
            } else {
                state.enqueueTimes[frameID] = now
            }
        }
    }

    private func finish(
        frameID: UInt64,
        status: LSPVideoDecodeStatus,
        videoGeneration: UInt32
    ) {
        let report = lock.withLock { () -> (UInt32, FrameState, UInt8)? in
            guard let configuration = state.configuration?.nativeConfiguration,
                  state.active,
                  configuration.videoGeneration == videoGeneration,
                  var frame = state.outstanding[frameID],
                  !frame.reporting else { return nil }
            frame.reporting = true
            state.outstanding[frameID] = frame
            let completedOutstandingCount = state.outstanding.count - 1
            let credit = UInt8(max(0, Int(configuration.decoderSurfaces) - completedOutstandingCount))
            return (configuration.videoGeneration, frame, credit)
        }
        guard let report else { return }
        feedbackQueue.async { [self] in
            guard isActive(videoGeneration: report.0) else { return }
            reportDecode(frameID: frameID, status: status, report: report)
        }
    }

    private func reportDecode(
        frameID: UInt64,
        status: LSPVideoDecodeStatus,
        report: (UInt32, FrameState, UInt8)
    ) {
        do {
            try transport.reportVideoDecode(
                videoGeneration: report.0,
                frameID: frameID,
                recoveryEpoch: report.1.recoveryEpoch,
                status: status,
                availableCredit: report.2,
                mailboxOccupancy: status == .ready ? 1 : 0
            )
            let commitWasPending = lock.withLock { () -> Bool? in
                guard state.active,
                      state.configuration?.nativeConfiguration.videoGeneration == report.0,
                      state.outstanding[frameID]?.reporting == true else { return nil }
                state.outstanding.removeValue(forKey: frameID)
                return state.pendingCommits.remove(frameID) != nil
            }
            if commitWasPending == true {
                do {
                    try transport.reportVideoCommit(
                        videoGeneration: report.0,
                        frameID: frameID,
                        mailboxOccupancy: 0
                    )
                } catch {
                    fail(
                        (error as? LSPTransportError) ?? .internalFailure,
                        videoGeneration: report.0
                    )
                }
            }
        } catch {
            _ = lock.withLock {
                guard state.configuration?.nativeConfiguration.videoGeneration == report.0 else { return false }
                return state.pendingCommits.remove(frameID) != nil
            }
            fail(
                (error as? LSPTransportError) ?? .internalFailure,
                videoGeneration: report.0
            )
        }
    }

    private func reportDrop(_ frame: LSPEncodedVideoAccessUnit, status: LSPVideoDecodeStatus) {
        let credit = lock.withLock { () -> UInt8? in
            guard state.active,
                  let configuration = state.configuration?.nativeConfiguration,
                  configuration.videoGeneration == frame.videoGeneration else { return nil }
            return UInt8(max(0, Int(configuration.decoderSurfaces) - state.outstanding.count))
        }
        guard let credit else { return }
        feedbackQueue.async { [self] in
            guard isActive(videoGeneration: frame.videoGeneration) else { return }
            do {
                try transport.reportVideoDecode(
                    videoGeneration: frame.videoGeneration,
                    frameID: frame.frameID,
                    recoveryEpoch: frame.recoveryEpoch,
                    status: status,
                    availableCredit: credit,
                    mailboxOccupancy: 1
                )
            } catch {
                fail(
                    (error as? LSPTransportError) ?? .internalFailure,
                    videoGeneration: frame.videoGeneration
                )
            }
        }
    }

    private func reportCommit(frameNumber: Int, videoGeneration: UInt32) {
        let commitTime = Self.monotonicMicroseconds()
        let frameID = Self.lspFrameID(from: frameNumber)
        guard let result = lock.withLock({ () -> (UInt32, Bool)? in
            guard state.active,
                  state.configuration?.nativeConfiguration.videoGeneration == videoGeneration else { return nil }
            if state.outstanding[frameID] != nil {
                if let enqueueTime = state.enqueueTimes.removeValue(forKey: frameID) {
                    if commitTime >= enqueueTime {
                        state.metalEnqueueToCommit.record(commitTime - enqueueTime)
                    } else {
                        state.metalEnqueueToCommit.drop()
                    }
                }
                state.pendingCommits.insert(frameID)
                return (videoGeneration, false)
            } else if let enqueueTime = state.enqueueTimes.removeValue(forKey: frameID) {
                if commitTime >= enqueueTime {
                    state.metalEnqueueToCommit.record(commitTime - enqueueTime)
                } else {
                    state.metalEnqueueToCommit.drop()
                }
            } else {
                state.metalEnqueueToCommit.drop()
            }
            return (videoGeneration, true)
        })
        else { return }
        guard result.1 else { return }
        feedbackQueue.async { [self] in
            guard isActive(videoGeneration: result.0) else { return }
            do {
                try transport.reportVideoCommit(
                    videoGeneration: result.0,
                    frameID: frameID,
                    mailboxOccupancy: 0
                )
            } catch {
                fail(
                    (error as? LSPTransportError) ?? .internalFailure,
                    videoGeneration: result.0
                )
            }
        }
    }

    private func isActive(videoGeneration: UInt32) -> Bool {
        lock.withLock {
            state.active && state.configuration?.nativeConfiguration.videoGeneration == videoGeneration
        }
    }

    public func telemetrySnapshot() -> LSPProductTelemetrySnapshot {
        let decoder = lock.withLock { state.decoder }
        let decoderStatistics = decoder?.pipelineStatistics()
        return lock.withLock {
            .init(
                videoDecoderStatistics: decoderStatistics,
                hostEncoderDuration: state.hostEncoderDuration.snapshot(clockDomain: "host-monotonic-duration"),
                completeFrameReceiveToVideoToolboxSubmit: state.receiveToSubmit.snapshot(),
                videoToolboxSubmitToDecodeCompletion: state.submitToDecode.snapshot(),
                completeFrameReceiveToMetalEnqueue: state.receiveToMetalEnqueue.snapshot(),
                metalEnqueueToCommit: state.metalEnqueueToCommit.snapshot(),
                metalCommitToCompletion: nil,
                audioReceiveToDecode: nil,
                audioDecodeAndRenderEnqueue: nil,
                audioUnderruns: nil,
                audioRebuffers: nil,
                reconnectDuration: nil,
                videoAccessUnitsReceived: state.accessUnitsReceived
            )
        }
    }

    private static func monotonicMicroseconds() -> UInt64 {
        max(1, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000)
    }

    private func expireStaleOutstandingFrames() {
        let now = Self.monotonicMicroseconds()
        let expired = lock.withLock { () -> (UInt32, [(UInt64, Bool)])? in
            guard state.active, let generation = state.configuration?.nativeConfiguration.videoGeneration else {
                return nil
            }
            let stale = state.outstanding.compactMap { frameID, frame -> (UInt64, Bool)? in
                guard !frame.reporting, now >= frame.submitTimeMicroseconds,
                      now - frame.submitTimeMicroseconds >= Self.outstandingFrameTimeoutMicroseconds else { return nil }
                return (frameID, frame.independent)
            }
            return stale.isEmpty ? nil : (generation, stale)
        }
        guard let expired else { return }
        for (frameID, independent) in expired.1 {
            recordDecodeDrop(frameID: frameID, videoGeneration: expired.0)
            finish(
                frameID: frameID,
                status: independent ? .unrecoverableError : .recoverableError,
                videoGeneration: expired.0
            )
        }
    }

    private func rendererDropped(
        frameNumber: Int,
        reason: MetalFrameDropReason,
        videoGeneration: UInt32
    ) {
        let frameID = Self.lspFrameID(from: frameNumber)
        lock.withLock {
            guard state.active,
                  state.configuration?.nativeConfiguration.videoGeneration == videoGeneration else { return }
            state.pendingCommits.remove(frameID)
            state.enqueueTimes.removeValue(forKey: frameID)
            state.metalEnqueueToCommit.drop()
        }
        if reason == .rendererUnavailable {
            fail(.invalidState, videoGeneration: videoGeneration)
        }
    }

    private func fail(_ error: LSPTransportError, videoGeneration: UInt32) {
        let handler = lock.withLock { () -> (@Sendable (LSPTransportError) -> Void)? in
            guard state.active,
                  state.configuration?.nativeConfiguration.videoGeneration == videoGeneration,
                  !state.terminal else { return nil }
            state.terminal = true
            state.active = false
            return failureHandler
        }
        handler?(error)
    }

    /// Encodes an opaque LSP frame ID into the signed 64-bit token carried by the media stack.
    static func mediaFrameToken(for frameID: UInt64) -> Int {
        Int(Int64(bitPattern: frameID))
    }

    /// Restores an opaque LSP frame ID from the signed 64-bit token carried by the media stack.
    static func lspFrameID(from mediaFrameToken: Int) -> UInt64 {
        UInt64(bitPattern: Int64(mediaFrameToken))
    }

    private static func codecMask(_ configuration: LSPNativeVideoConfiguration) throws -> Int32 {
        switch (configuration.codec, configuration.profile, configuration.pixelFormat) {
        case (1, 1, 1): GameStreamVideoFormat.h264.rawValue
        case (1, 2, 3): GameStreamVideoFormat.h264High8YUV444.rawValue
        case (2, 3, 1): GameStreamVideoFormat.hevc.rawValue
        case (2, 4, 2): GameStreamVideoFormat.hevcMain10.rawValue
        case (2, 5, 3): GameStreamVideoFormat.hevcRext8YUV444.rawValue
        case (2, 5, 4): GameStreamVideoFormat.hevcRext10YUV444.rawValue
        case (3, 6, 1): GameStreamVideoFormat.av1Main8.rawValue
        case (3, 6, 2): GameStreamVideoFormat.av1Main10.rawValue
        case (3, 7, 3): GameStreamVideoFormat.av1High8YUV444.rawValue
        case (3, 7, 4): GameStreamVideoFormat.av1High10YUV444.rawValue
        default: throw LSPTransportError.invalidConfiguration
        }
    }

    private static func mediaPayloadFormat(_ format: LSPVideoPayloadFormat) -> EncodedVideoPayloadFormat {
        switch format {
        case .annexB: .annexB
        case .av1LowOverheadOBU: .av1LowOverheadOBU
        }
    }

    private static func hdrMetadata(
        _ metadata: LSPVideoHDRMetadata?,
        transfer: UInt8
    ) -> HDRStaticMetadata? {
        guard transfer == 16 || transfer == 18 else { return nil }
        let transferFunction: VideoTransferFunction = transfer == 18 ? .hlg : .pq
        guard let metadata else { return .init(transferFunction: transferFunction) }
        var mastering = Data()
        // SMPTE ST 2086 / HEVC MDCV payload order is green, blue, red, white,
        // maximum luminance, then minimum luminance, all in network byte order.
        for coordinate in [
            metadata.displayPrimaryGreenX, metadata.displayPrimaryGreenY,
            metadata.displayPrimaryBlueX, metadata.displayPrimaryBlueY,
            metadata.displayPrimaryRedX, metadata.displayPrimaryRedY,
            metadata.whitePointX, metadata.whitePointY,
        ] {
            appendUInt16(UInt16(clamping: coordinate), to: &mastering)
        }
        appendUInt32(metadata.maximumDisplayLuminance * 10_000, to: &mastering)
        appendUInt32(metadata.minimumDisplayLuminance, to: &mastering)
        var contentLight: Data?
        if metadata.maximumContentLightLevel != 0 {
            var encoded = Data()
            appendUInt16(UInt16(clamping: metadata.maximumContentLightLevel), to: &encoded)
            appendUInt16(UInt16(clamping: metadata.maximumFrameAverageLightLevel), to: &encoded)
            contentLight = encoded
        }
        return HDRStaticMetadata(
            minimumLuminanceNits: Float(metadata.minimumDisplayLuminance) / 10_000,
            maximumLuminanceNits: Float(metadata.maximumDisplayLuminance),
            maximumContentLightLevelNits: metadata.maximumContentLightLevel == 0
                ? nil : Float(metadata.maximumContentLightLevel),
            maximumFrameAverageLightLevelNits: metadata.maximumFrameAverageLightLevel == 0
                ? nil : Float(metadata.maximumFrameAverageLightLevel),
            maximumFullFrameLuminanceNits: metadata.maximumFullFrameLuminance == 0
                ? nil : Float(metadata.maximumFullFrameLuminance),
            masteringDisplayColorVolume: mastering,
            contentLightLevelInfo: contentLight,
            transferFunction: transferFunction
        )
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
}
