import Foundation
import UmbraLSPTransport
import UmbraMedia

/// Hardware-only VideoToolbox and Metal boundary for one LSP video generation.
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
        var terminal = false
    }

    private let transport: LSPTransport
    private let renderer: any MetalVideoRendering
    private let lock = NSLock()
    private var state = State()
    private var failureHandler: (@Sendable (LSPTransportError) -> Void)?

    public init(transport: LSPTransport, renderer: any MetalVideoRendering) {
        self.transport = transport
        self.renderer = renderer
        transport.setVideoAccessUnitHandler { [weak self] frame in
            self?.submit(frame)
        }
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
            state.terminal = false
            return old
        }
        old?.stop()
        old?.cleanUp()
        return true
    }

    /// Transfers renderer reporting only after VIDEO_CONFIG_ACK was submitted.
    public func activate() throws {
        renderer.setMailboxDropNewest(false)
        renderer.installCommandCommitHandler { [weak self] frameNumber in
            self?.reportCommit(frameNumber: frameNumber)
        }
        renderer.installFrameDropHandler { [weak self] frameNumber, reason in
            self?.rendererDropped(frameNumber: frameNumber, reason: reason)
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
            renderer.installFrameDropHandler { _, _ in }
            renderer.setMailboxDropNewest(false)
            throw error
        }
    }

    /// Stops publication, drains VT callbacks, flushes mailbox ownership, and releases frame handles.
    public func stop() {
        transport.setVideoAccessUnitHandler(nil)
        let decoder = lock.withLock { () -> VideoToolboxDecoder? in
            defer { state = State() }
            return state.decoder
        }
        decoder?.stop()
        decoder?.cleanUp()
        renderer.installCommandCommitHandler { _ in }
        renderer.installFrameDropHandler { _, _ in }
        renderer.flush()
        renderer.setMailboxDropNewest(false)
    }

    public func disablePublication() {
        transport.setVideoAccessUnitHandler(nil)
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
        transport.setVideoAccessUnitHandler(nil)
        let decoder = lock.withLock { () -> VideoToolboxDecoder? in
            defer { state = State() }
            return state.decoder
        }
        guard let decoder else { return }
        decoder.stop()
        decoder.cleanUp()
        renderer.flush()
    }

    private func submit(_ frame: LSPEncodedVideoAccessUnit) {
        let ticket = lock.withLock { () -> (VideoToolboxDecoder, LSPNativeVideoConfiguration)? in
            guard let request = state.configuration,
                  state.active,
                  request.nativeConfiguration.videoGeneration == frame.videoGeneration,
                  request.nativeConfiguration.codec == frame.codec,
                  request.nativeConfiguration.payloadFormat == frame.payloadFormat.rawValue,
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
            data: frame.encodedAccessUnit,
            payloadFormat: Self.mediaPayloadFormat(frame.payloadFormat),
            frameNumber: Int(frame.frameID),
            isKeyFrame: frame.independent,
            requiresIndependentDecode: frame.independent,
            receiveTimeMicroseconds: frame.receiveTimeMicroseconds,
            enqueueTimeMicroseconds: frame.receiveTimeMicroseconds,
            presentationTimeMicroseconds: frame.captureTimeMicroseconds,
            rtpTimestamp: frame.rtpTimestamp,
            isHDR: ticket.1.transferCharacteristics != 1,
            colorSpace: ticket.1.colorPrimaries == 9 ? VideoColorSpace.rec2020.rawValue : VideoColorSpace.rec709.rawValue,
            isFullRange: ticket.1.fullRange,
            hostCaptureTimeMicroseconds: frame.captureTimeMicroseconds,
            appliedInputStateSequence: frame.inputStateSequence,
            appliedInputEdgeID: frame.inputEdgeID,
            videoConfigurationGeneration: frame.videoGeneration
        ))
        if disposition == .capacityDropped {
            finish(frameID: frame.frameID, status: .surfaceExhausted)
            fail(.resourceExhausted)
        } else if disposition == .requestKeyFrame {
            finish(frameID: frame.frameID, status: frame.independent ? .unrecoverableError : .recoverableError)
            fail(.internalFailure)
        }
    }

    private func decoded(_ outcome: VideoDecodeOutcome) {
        switch outcome {
        case .decoded(let frameNumber): finish(frameID: UInt64(frameNumber), status: .ready)
        case .failed(let frameNumber):
            let independent = lock.withLock { state.outstanding[UInt64(frameNumber)]?.independent ?? false }
            finish(frameID: UInt64(frameNumber), status: independent ? .unrecoverableError : .recoverableError)
            fail(.internalFailure)
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
                do {
                    try transport.reportVideoCommit(
                        videoGeneration: report.0,
                        frameID: frameID,
                        mailboxOccupancy: 0
                    )
                } catch {
                    fail((error as? LSPTransportError) ?? .internalFailure)
                }
            }
        } catch {
            _ = lock.withLock { state.pendingCommits.remove(frameID) }
            fail((error as? LSPTransportError) ?? .internalFailure)
        }
    }

    private func reportDrop(_ frame: LSPEncodedVideoAccessUnit, status: LSPVideoDecodeStatus) {
        let credit = lock.withLock { () -> UInt8 in
            guard let configuration = state.configuration?.nativeConfiguration else { return 0 }
            return UInt8(max(0, Int(configuration.decoderSurfaces) - state.outstanding.count))
        }
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
            fail((error as? LSPTransportError) ?? .internalFailure)
        }
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
        do {
            try transport.reportVideoCommit(
                videoGeneration: result.0,
                frameID: frameID,
                mailboxOccupancy: 0
            )
        } catch {
            fail((error as? LSPTransportError) ?? .internalFailure)
        }
    }

    private func rendererDropped(frameNumber: Int, reason: MetalFrameDropReason) {
        if let frameID = UInt64(exactly: frameNumber) {
            _ = lock.withLock { state.pendingCommits.remove(frameID) }
        }
        if reason != .mailboxEviction {
            fail(reason == .rendererUnavailable ? .invalidState : .resourceExhausted)
        }
    }

    private func fail(_ error: LSPTransportError) {
        let handler = lock.withLock { () -> (@Sendable (LSPTransportError) -> Void)? in
            guard !state.terminal else { return nil }
            state.terminal = true
            state.active = false
            return failureHandler
        }
        handler?(error)
    }

    private static func codecMask(_ configuration: LSPNativeVideoConfiguration) throws -> Int32 {
        switch (configuration.codec, configuration.profile, configuration.pixelFormat) {
        case (1, 1, 1): MoonlightVideoFormat.h264.rawValue
        case (1, 2, 3): MoonlightVideoFormat.h264High8YUV444.rawValue
        case (2, 3, 1): MoonlightVideoFormat.hevc.rawValue
        case (2, 4, 2): MoonlightVideoFormat.hevcMain10.rawValue
        case (2, 5, 3): MoonlightVideoFormat.hevcRext8YUV444.rawValue
        case (2, 5, 4): MoonlightVideoFormat.hevcRext10YUV444.rawValue
        case (3, 6, 1): MoonlightVideoFormat.av1Main8.rawValue
        case (3, 6, 2): MoonlightVideoFormat.av1Main10.rawValue
        case (3, 7, 3): MoonlightVideoFormat.av1High8YUV444.rawValue
        case (3, 7, 4): MoonlightVideoFormat.av1High10YUV444.rawValue
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
