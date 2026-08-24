import Foundation
import UmbraMedia
import UmbraProtocolV3
import UmbraQUICTransport
import UmbraStreaming

public enum ProtocolV3MediaPipelineError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidDatagram(String)
    case decoderRejectedConfiguration
}

public struct ProtocolV3VideoFeedback: Equatable, Sendable {
    public let affectedFrameID: UInt64
    public let lastReassembledFrameID: UInt64
    public let lastDecodedFrameID: UInt64
    public let action: UInt8
    public let deadlineMissMicroseconds: UInt32
}

public struct ProtocolV3MediaStatistics: Equatable, Sendable {
    public let videoPipeline: MediaPipelineStatistics?
    public let audioRenderer: AudioRendererStatistics?
    public let videoFragmentsReceived: UInt64
    public let videoFramesReassembled: UInt64
    public let videoFramesSubmitted: UInt64
    public let videoFramesDecoded: UInt64
    public let videoFramesDropped: UInt64
    public let videoFeedbackSent: UInt64
    public let audioPacketsReceived: UInt64
    public let audioConcealmentFrames: UInt64
    public let audioDiscontinuities: UInt64
    public let pendingAudioPackets: Int
}

struct ProtocolV3VideoFragment {
    let frameID: UInt64
    let frameSize: Int
    let fragmentOffset: Int
    let fragmentIndex: Int
    let fragmentCount: Int
    let captureTimeMicroseconds: UInt64
    let encoderCompleteDeltaMicroseconds: UInt32
    let appliedInputStateSequence: UInt64
    let appliedInputEdgeID: UInt64
    let videoGeneration: UInt32
    let codecID: UInt8
    let matrix: UInt8
    let bitDepth: UInt8
    let flags: UInt8
    let bytes: Data
    let receivedAtNanoseconds: UInt64
}

struct ProtocolV3ReassembledVideoFrame {
    let frameID: UInt64
    let data: Data
    let captureTimeMicroseconds: UInt64
    let encoderCompleteDeltaMicroseconds: UInt32
    let appliedInputStateSequence: UInt64
    let appliedInputEdgeID: UInt64
    let videoGeneration: UInt32
    let matrix: UInt8
    let flags: UInt8
    let receivedAtNanoseconds: UInt64
}

struct ProtocolV3VideoReassemblyUpdate {
    var readyFrames: [ProtocolV3ReassembledVideoFrame] = []
    var lostFrameIDs: [UInt64] = []
    var reassembledFrameID: UInt64?
    var requestedKeyFrameID: UInt64?

    mutating func appendLost(_ frameIDs: some Sequence<UInt64>) {
        for frameID in frameIDs where !lostFrameIDs.contains(frameID) {
            lostFrameIDs.append(frameID)
        }
    }
}

private final class ProtocolV3VideoFrameStorage {
    let byteCount: Int
    private var allocation: UnsafeMutableRawPointer?

    init(byteCount: Int) {
        self.byteCount = byteCount
        allocation = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
    }

    deinit {
        allocation?.deallocate()
    }

    var address: UInt {
        allocation.map(UInt.init(bitPattern:)) ?? 0
    }

    func write(_ bytes: Data, at offset: Int) {
        guard let allocation else { preconditionFailure("video frame storage already transferred") }
        bytes.withUnsafeBytes { source in
            guard let sourceAddress = source.baseAddress else { return }
            allocation.advanced(by: offset).copyMemory(from: sourceAddress, byteCount: source.count)
        }
    }

    func transferToData() -> Data {
        guard let allocation else { preconditionFailure("video frame storage already transferred") }
        self.allocation = nil
        return Data(
            bytesNoCopy: allocation,
            count: byteCount,
            deallocator: .custom { pointer, _ in pointer.deallocate() }
        )
    }
}

private final class ProtocolV3VideoAssembly {
    let byteCount: Int
    let fragmentCount: Int
    let captureTimeMicroseconds: UInt64
    let encoderCompleteDeltaMicroseconds: UInt32
    let appliedInputStateSequence: UInt64
    let appliedInputEdgeID: UInt64
    let videoGeneration: UInt32
    let codecID: UInt8
    let matrix: UInt8
    let bitDepth: UInt8
    let flags: UInt8
    let firstReceiveTimeNanoseconds: UInt64
    private let storage: ProtocolV3VideoFrameStorage
    private(set) var receivedRanges: [Int: Range<Int>] = [:]
    private(set) var completionReceiveTimeNanoseconds: UInt64?

    init(_ fragment: ProtocolV3VideoFragment) {
        byteCount = fragment.frameSize
        fragmentCount = fragment.fragmentCount
        captureTimeMicroseconds = fragment.captureTimeMicroseconds
        encoderCompleteDeltaMicroseconds = fragment.encoderCompleteDeltaMicroseconds
        appliedInputStateSequence = fragment.appliedInputStateSequence
        appliedInputEdgeID = fragment.appliedInputEdgeID
        videoGeneration = fragment.videoGeneration
        codecID = fragment.codecID
        matrix = fragment.matrix
        bitDepth = fragment.bitDepth
        flags = fragment.flags
        firstReceiveTimeNanoseconds = fragment.receivedAtNanoseconds
        storage = ProtocolV3VideoFrameStorage(byteCount: fragment.frameSize)
    }

    var isComplete: Bool {
        completionReceiveTimeNanoseconds != nil
    }

    var storageAddress: UInt {
        storage.address
    }

    func append(_ fragment: ProtocolV3VideoFragment) throws -> Bool {
        guard byteCount == fragment.frameSize,
              fragmentCount == fragment.fragmentCount,
              captureTimeMicroseconds == fragment.captureTimeMicroseconds,
              encoderCompleteDeltaMicroseconds == fragment.encoderCompleteDeltaMicroseconds,
              codecID == fragment.codecID,
              matrix == fragment.matrix,
              bitDepth == fragment.bitDepth,
              flags == fragment.flags,
              appliedInputStateSequence == fragment.appliedInputStateSequence,
              appliedInputEdgeID == fragment.appliedInputEdgeID,
              videoGeneration == fragment.videoGeneration,
              receivedRanges[fragment.fragmentIndex] == nil,
              !isComplete else {
            throw ProtocolV3MediaPipelineError.invalidDatagram("video assembly")
        }
        let range = fragment.fragmentOffset..<(fragment.fragmentOffset + fragment.bytes.count)
        guard !receivedRanges.values.contains(where: { $0.overlaps(range) }) else {
            throw ProtocolV3MediaPipelineError.invalidDatagram("overlapping video fragments")
        }
        storage.write(fragment.bytes, at: fragment.fragmentOffset)
        receivedRanges[fragment.fragmentIndex] = range
        guard receivedRanges.count == fragmentCount else { return false }
        let ranges = receivedRanges.values.sorted { $0.lowerBound < $1.lowerBound }
        guard ranges.first?.lowerBound == 0,
              ranges.last?.upperBound == byteCount,
              zip(ranges, ranges.dropFirst()).allSatisfy({ $0.upperBound == $1.lowerBound }) else {
            throw ProtocolV3MediaPipelineError.invalidDatagram("gapped video frame")
        }
        completionReceiveTimeNanoseconds = fragment.receivedAtNanoseconds
        return true
    }

    func takeFrame(frameID: UInt64) -> ProtocolV3ReassembledVideoFrame {
        guard let completionReceiveTimeNanoseconds else {
            preconditionFailure("incomplete video frame handoff")
        }
        return ProtocolV3ReassembledVideoFrame(
            frameID: frameID,
            data: storage.transferToData(),
            captureTimeMicroseconds: captureTimeMicroseconds,
            encoderCompleteDeltaMicroseconds: encoderCompleteDeltaMicroseconds,
            appliedInputStateSequence: appliedInputStateSequence,
            appliedInputEdgeID: appliedInputEdgeID,
            videoGeneration: videoGeneration,
            matrix: matrix,
            flags: flags,
            receivedAtNanoseconds: completionReceiveTimeNanoseconds
        )
    }
}

/// Bounded frame reassembly and dependency ordering shared by the production
/// QUIC receive path and its direct state-machine tests.
final class ProtocolV3VideoReassembler {
    private let mode: QUICOptimizationMode
    private var assemblies: [UInt64: ProtocolV3VideoAssembly] = [:]
    private var highestObservedFrameID: UInt64 = 0
    private var latestReleasedFrameID: UInt64 = 0
    private var qualityNeedsKeyFrame = false
    private var qualityGapStartedAtNanoseconds: UInt64?

    init(mode: QUICOptimizationMode) {
        self.mode = mode
    }

    var pendingFrameIDs: [UInt64] {
        assemblies.keys.sorted()
    }

    var requiresKeyFrame: Bool {
        qualityNeedsKeyFrame
    }

    func storageAddress(frameID: UInt64) -> UInt? {
        assemblies[frameID]?.storageAddress
    }

    func resetForConfiguration() {
        assemblies.removeAll(keepingCapacity: true)
        highestObservedFrameID = 0
        latestReleasedFrameID = 0
        qualityNeedsKeyFrame = false
        qualityGapStartedAtNanoseconds = nil
    }

    func suspendForReconnect() {
        assemblies.removeAll(keepingCapacity: true)
        qualityGapStartedAtNanoseconds = nil
    }

    func removeAll() {
        assemblies.removeAll()
        qualityGapStartedAtNanoseconds = nil
    }

    func requireKeyFrame() -> [UInt64] {
        let lost = pendingFrameIDs
        assemblies.removeAll(keepingCapacity: true)
        qualityGapStartedAtNanoseconds = nil
        qualityNeedsKeyFrame = mode == .quality
        return lost
    }

    func accept(
        _ fragment: ProtocolV3VideoFragment,
        framesPerSecond: Int
    ) throws -> ProtocolV3VideoReassemblyUpdate {
        guard fragment.frameID > 0,
              fragment.frameSize > 0, fragment.frameSize <= 67_108_864,
              fragment.fragmentCount > 0, fragment.fragmentCount <= Int(UInt16.max),
              fragment.fragmentIndex >= 0,
              fragment.fragmentIndex < fragment.fragmentCount,
              fragment.fragmentOffset >= 0,
              !fragment.bytes.isEmpty,
              fragment.fragmentOffset <= fragment.frameSize,
              fragment.bytes.count <= fragment.frameSize - fragment.fragmentOffset else {
            throw ProtocolV3MediaPipelineError.invalidDatagram("video fragment")
        }
        var update = ProtocolV3VideoReassemblyUpdate()
        if mode == .quality {
            expireQualityBlocker(
                nowNanoseconds: fragment.receivedAtNanoseconds,
                framesPerSecond: framesPerSecond,
                update: &update
            )
        }

        let alreadyPresent = assemblies[fragment.frameID] != nil
        if !alreadyPresent {
            guard fragment.frameID > latestReleasedFrameID else { return update }
            if mode == .latency {
                guard fragment.frameID >= highestObservedFrameID else { return update }
                highestObservedFrameID = max(highestObservedFrameID, fragment.frameID)
                update.appendLost(assemblies.keys.filter { $0 != fragment.frameID })
                assemblies = assemblies.filter { $0.key == fragment.frameID }
            } else {
                highestObservedFrameID = max(highestObservedFrameID, fragment.frameID)
                if fragment.flags & 0x01 != 0 {
                    let superseded = assemblies.keys.filter { $0 < fragment.frameID }
                    update.appendLost(superseded)
                    for frameID in superseded {
                        assemblies.removeValue(forKey: frameID)
                    }
                } else if qualityNeedsKeyFrame {
                    return update
                }
                if assemblies.count >= 2 {
                    if fragment.flags & 0x01 != 0 {
                        update.appendLost(assemblies.keys)
                        assemblies.removeAll(keepingCapacity: true)
                        qualityGapStartedAtNanoseconds = nil
                    } else {
                        transitionToQualityRecovery(affectedFrameID: fragment.frameID, update: &update)
                        return update
                    }
                }
            }
            assemblies[fragment.frameID] = ProtocolV3VideoAssembly(fragment)
        }

        guard let assembly = assemblies[fragment.frameID] else { return update }
        if try assembly.append(fragment) {
            update.reassembledFrameID = fragment.frameID
        }
        if mode == .latency {
            if assembly.isComplete {
                assemblies.removeValue(forKey: fragment.frameID)
                latestReleasedFrameID = fragment.frameID
                update.readyFrames = [assembly.takeFrame(frameID: fragment.frameID)]
            }
            return update
        }

        drainQualityFrames(nowNanoseconds: fragment.receivedAtNanoseconds, update: &update)
        return update
    }

    private func drainQualityFrames(
        nowNanoseconds: UInt64,
        update: inout ProtocolV3VideoReassemblyUpdate
    ) {
        if let keyFrameID = assemblies
            .filter({ $0.value.isComplete && $0.value.flags & 0x01 != 0 })
            .map(\.key)
            .max(),
           let keyFrame = assemblies.removeValue(forKey: keyFrameID) {
            let superseded = assemblies.keys.filter { $0 < keyFrameID }
            update.appendLost(superseded)
            for frameID in superseded {
                assemblies.removeValue(forKey: frameID)
            }
            latestReleasedFrameID = keyFrameID
            qualityNeedsKeyFrame = false
            qualityGapStartedAtNanoseconds = nil
            update.requestedKeyFrameID = nil
            update.readyFrames.append(keyFrame.takeFrame(frameID: keyFrameID))
        }

        while !qualityNeedsKeyFrame {
            guard latestReleasedFrameID < UInt64.max else { break }
            let expectedFrameID = latestReleasedFrameID + 1
            guard let assembly = assemblies[expectedFrameID], assembly.isComplete else { break }
            assemblies.removeValue(forKey: expectedFrameID)
            latestReleasedFrameID = expectedFrameID
            update.readyFrames.append(assembly.takeFrame(frameID: expectedFrameID))
        }

        guard !assemblies.isEmpty else {
            qualityGapStartedAtNanoseconds = nil
            return
        }
        guard latestReleasedFrameID < UInt64.max else {
            qualityGapStartedAtNanoseconds = nil
            return
        }
        let expectedFrameID = latestReleasedFrameID + 1
        if let expected = assemblies[expectedFrameID] {
            qualityGapStartedAtNanoseconds = expected.isComplete
                ? nil
                : expected.firstReceiveTimeNanoseconds
        } else if let firstFuture = assemblies.values.min(by: {
            $0.firstReceiveTimeNanoseconds < $1.firstReceiveTimeNanoseconds
        }) {
            qualityGapStartedAtNanoseconds = min(
                qualityGapStartedAtNanoseconds ?? nowNanoseconds,
                firstFuture.firstReceiveTimeNanoseconds
            )
        }
    }

    private func expireQualityBlocker(
        nowNanoseconds: UInt64,
        framesPerSecond: Int,
        update: inout ProtocolV3VideoReassemblyUpdate
    ) {
        guard let started = qualityGapStartedAtNanoseconds,
              nowNanoseconds >= started,
              nowNanoseconds - started >= Self.qualityWaitNanoseconds(framesPerSecond: framesPerSecond) else {
            return
        }
        transitionToQualityRecovery(
            affectedFrameID: assemblies.keys.min() ?? latestReleasedFrameID,
            update: &update
        )
    }

    private func transitionToQualityRecovery(
        affectedFrameID: UInt64,
        update: inout ProtocolV3VideoReassemblyUpdate
    ) {
        update.appendLost(assemblies.keys)
        assemblies.removeAll(keepingCapacity: true)
        qualityGapStartedAtNanoseconds = nil
        qualityNeedsKeyFrame = true
        update.requestedKeyFrameID = affectedFrameID
    }

    private static func qualityWaitNanoseconds(framesPerSecond: Int) -> UInt64 {
        let framesPerSecond = UInt64(max(1, framesPerSecond))
        let fourFrameIntervals = 4_000_000_000 / framesPerSecond
        return min(250_000_000, max(50_000_000, fourFrameIntervals))
    }
}

/// Owns the protocol-v3 compressed-media boundary after START. QUIC has already
/// authenticated the ULM3 envelope; this adapter still validates the exact
/// configuration generation and bounded object layout before crossing into the
/// existing VideoToolbox/Metal and Opus/AudioQueue pipeline.
public final class ProtocolV3MediaPipelineAdapter: @unchecked Sendable {
    private struct HDRSelection {
        let enabled: Bool
        let hasStaticMetadata: Bool
        let metadata: UmbraStreaming.StreamingHDRMetadata?
    }
    private struct ExpectedSelection {
        let videoTuple: ProtocolV3CBORValue
        let audioTuple: ProtocolV3CBORValue
        let microphoneTuple: ProtocolV3CBORValue
        let hdr: ProtocolV3CBORValue
        let videoGeneration: UInt32
        let audioGeneration: UInt32
        let microphoneGeneration: UInt32
    }

    private struct VideoConfiguration {
        let generation: UInt32
        let format: MoonlightVideoFormat
        let isHDR: Bool
        let hasStaticHDRMetadata: Bool
        let tuple: [UInt64: ProtocolV3CBORValue]
        let width: Int
        let height: Int
        let framesPerSecond: Int
    }

    private struct AudioConfigurationState: Equatable {
        let generation: UInt32
        let format: UmbraStreaming.OpusStreamFormat
        let layout: UInt8
        let bitrate: UInt32
    }

    private struct BufferedAudioPacket {
        let flags: UInt8
        let data: Data
    }

    private let pipeline: StreamingMediaPipeline
    private let mode: QUICOptimizationMode
    private let diagnosticHandler: @Sendable (String) -> Void
    private let firstVideoSubmitHandler: @Sendable () -> Void
    private let expected: ExpectedSelection
    private let videoReassembler: ProtocolV3VideoReassembler
    private let lock = NSLock()
    private let videoDeliveryLock = NSLock()
    private var videoConfiguration: VideoConfiguration?
    private var audioConfiguration: AudioConfigurationState?
    private var lastReassembledVideoFrameID: UInt64 = 0
    private var lastDecodedVideoFrameID: UInt64 = 0
    private var videoFeedbackHandler: (@Sendable (ProtocolV3VideoFeedback) -> Void)?
    private var pendingAudio: [UInt64: BufferedAudioPacket] = [:]
    private var nextAudioSamplePosition: UInt64 = 0
    private var videoFragmentsReceived: UInt64 = 0
    private var videoFramesReassembled: UInt64 = 0
    private var videoFramesSubmitted: UInt64 = 0
    private var videoFramesDecoded: UInt64 = 0
    private var videoFramesDropped: UInt64 = 0
    private var videoFeedbackSent: UInt64 = 0
    private var audioPacketsReceived: UInt64 = 0
    private var audioConcealmentFrames: UInt64 = 0
    private var audioDiscontinuities: UInt64 = 0
    private var stopped = false
    private var reportedFirstVideoSubmit = false

    public init(
        pipeline: StreamingMediaPipeline,
        mode: QUICOptimizationMode,
        startResponseFields: [UInt64: ProtocolV3CBORValue],
        firstVideoSubmitHandler: @escaping @Sendable () -> Void = {},
        diagnosticHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        guard let videoTuple = startResponseFields[5], videoTuple.mapValue != nil,
              let audioTuple = startResponseFields[12], audioTuple.mapValue != nil,
              let microphoneTuple = startResponseFields[13],
              let hdr = startResponseFields[23],
              let videoGeneration = startResponseFields[14]?.unsignedValue.flatMap(UInt32.init(exactly:)),
              let audioGeneration = startResponseFields[15]?.unsignedValue.flatMap(UInt32.init(exactly:)),
              let microphoneGeneration = startResponseFields[16]?.unsignedValue.flatMap(UInt32.init(exactly:)),
              videoGeneration != 0, audioGeneration != 0, microphoneGeneration != 0 else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration("START media selection")
        }
        self.pipeline = pipeline
        self.mode = mode
        videoReassembler = ProtocolV3VideoReassembler(mode: mode)
        self.firstVideoSubmitHandler = firstVideoSubmitHandler
        self.diagnosticHandler = diagnosticHandler
        expected = ExpectedSelection(
            videoTuple: videoTuple,
            audioTuple: audioTuple,
            microphoneTuple: microphoneTuple,
            hdr: hdr,
            videoGeneration: videoGeneration,
            audioGeneration: audioGeneration,
            microphoneGeneration: microphoneGeneration
        )
        guard let outcomeReporter = pipeline.videoDecoder as? any UmbraStreaming.VideoDecodeOutcomeReporting else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration("decoder outcome reporting")
        }
        outcomeReporter.installDecodeOutcomeHandler { [weak self] outcome in
            self?.handleDecodeOutcome(outcome)
        }
    }

    public func installVideoFeedbackHandler(
        _ handler: @escaping @Sendable (ProtocolV3VideoFeedback) -> Void
    ) {
        lock.withLock { videoFeedbackHandler = handler }
    }

    public func statistics() -> ProtocolV3MediaStatistics {
        lock.withLock {
            ProtocolV3MediaStatistics(
                videoPipeline: pipeline.videoStatistics(),
                audioRenderer: pipeline.audioStatistics(),
                videoFragmentsReceived: videoFragmentsReceived,
                videoFramesReassembled: videoFramesReassembled,
                videoFramesSubmitted: videoFramesSubmitted,
                videoFramesDecoded: videoFramesDecoded,
                videoFramesDropped: videoFramesDropped,
                videoFeedbackSent: videoFeedbackSent,
                audioPacketsReceived: audioPacketsReceived,
                audioConcealmentFrames: audioConcealmentFrames,
                audioDiscontinuities: audioDiscontinuities,
                pendingAudioPackets: pendingAudio.count
            )
        }
    }

    /// Applies an authoritative host VIDEO_CONFIG (0x0140) and returns the
    /// decoder capacity advertised in VIDEO_CONFIG_ACK key 4.
    public func configureVideo(fields: [UInt64: ProtocolV3CBORValue]) throws -> Int {
        guard Set(fields.keys) == Set(1...9),
              let generationRaw = fields[2]?.unsignedValue,
              let generation = UInt32(exactly: generationRaw),
              generation > 0,
              let tuple = fields[3]?.mapValue,
              fields[3] == expected.videoTuple,
              generation == expected.videoGeneration,
              let codecInitialization = fields[4]?.bytesValue,
              !codecInitialization.isEmpty,
              codecInitialization.count <= 1_048_576,
              let widthRaw = fields[6]?.unsignedValue,
              let heightRaw = fields[7]?.unsignedValue,
              let width = Int(exactly: widthRaw),
              let height = Int(exactly: heightRaw),
              (320...7_680).contains(width), width.isMultiple(of: 2),
              (200...4_320).contains(height), height.isMultiple(of: 2),
              let refreshNumerator = fields[8]?.unsignedValue,
              let refreshDenominator = fields[9]?.unsignedValue,
              refreshNumerator > 0, refreshDenominator > 0 else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration("video fields")
        }
        let selected = try Self.videoFormat(tuple)
        let hdr = try Self.hdrSelection(fields[5], selectedTuple: tuple, selectedFormat: selected)
        guard fields[5] == expected.hdr else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration("HDR selection mismatch")
        }
        let framesPerSecond = max(1, Int(refreshNumerator / refreshDenominator))
        let capacity = mode == .latency ? 1 : 2
        let accepted = pipeline.videoDecoder.configure(format: .init(
            codecMask: selected.rawValue,
            width: width,
            height: height,
            redrawRate: framesPerSecond,
            flags: 0
        ))
        guard accepted else { throw ProtocolV3MediaPipelineError.decoderRejectedConfiguration }
        (pipeline.videoDecoder as? any UmbraStreaming.HDRMetadataReceiving)?.setHDRMode(
            enabled: hdr.enabled,
            metadata: hdr.metadata
        )
        let initializationFormat: UmbraStreaming.EncodedVideoPayloadFormat = switch selected {
        case .av1Main8, .av1Main10, .av1High8YUV444, .av1High10YUV444:
            .av1LowOverheadOBU
        default:
            .annexB
        }
        guard let initializer = pipeline.videoDecoder as? any UmbraStreaming.VideoCodecInitializationPreparing,
              initializer.prepareCodecInitialization(
                  codecInitialization,
                  payloadFormat: initializationFormat
              ) else {
            throw ProtocolV3MediaPipelineError.decoderRejectedConfiguration
        }
        pipeline.videoDecoder.start()
        try lock.withLock {
            guard !stopped, videoConfiguration == nil else {
                throw ProtocolV3MediaPipelineError.invalidConfiguration("video generation rollback")
            }
            videoConfiguration = VideoConfiguration(
                generation: generation,
                format: selected,
                isHDR: hdr.enabled,
                hasStaticHDRMetadata: hdr.hasStaticMetadata,
                tuple: tuple,
                width: width,
                height: height,
                framesPerSecond: framesPerSecond
            )
            videoReassembler.resetForConfiguration()
        }
        diagnosticHandler(
            "Protocol v3 configured VideoToolbox: format=0x"
                + String(selected.rawValue, radix: 16)
                + ", dimensions=\(width)x\(height), refresh=\(refreshNumerator)/\(refreshDenominator), "
                + "HDR=\(hdr.enabled), reassemblyCapacity=\(capacity)."
        )
        return capacity
    }

    public func configureAudio(fields: [UInt64: ProtocolV3CBORValue]) throws {
        guard Set(fields.keys) == Set(1...4),
              let generationRaw = fields[2]?.unsignedValue,
              let generation = UInt32(exactly: generationRaw),
              generation > 0,
              let tuple = fields[3]?.mapValue,
              fields[3] == expected.audioTuple,
              generation == expected.audioGeneration,
              let discontinuity = fields[4]?.unsignedValue else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration("audio fields")
        }
        let format = try Self.audioFormat(tuple)
        guard pipeline.audioDecoder.configure(format: format) else {
            throw ProtocolV3MediaPipelineError.decoderRejectedConfiguration
        }
        pipeline.audioDecoder.start()
        let layout = try Self.uint8(tuple, key: 5, field: "audio layout")
        let bitrate = try Self.uint32(tuple, key: 9, field: "audio bitrate")
        try lock.withLock {
            guard !stopped, audioConfiguration == nil else {
                throw ProtocolV3MediaPipelineError.invalidConfiguration("audio generation rollback")
            }
            audioConfiguration = AudioConfigurationState(
                generation: generation,
                format: format,
                layout: layout,
                bitrate: bitrate
            )
            pendingAudio.removeAll(keepingCapacity: true)
            nextAudioSamplePosition = discontinuity
        }
        diagnosticHandler(
            "Protocol v3 configured AudioQueue/Opus: channels=\(format.channelCount), "
                + "samplesPerFrame=\(format.samplesPerFrame)."
        )
    }

    public func validateMicrophoneConfiguration(fields: [UInt64: ProtocolV3CBORValue]) throws {
        guard Set(fields.keys) == Set(1...4),
              fields[2]?.unsignedValue == UInt64(expected.microphoneGeneration),
              fields[3] == expected.microphoneTuple else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration("microphone selection mismatch")
        }
    }

    public func handle(_ message: QUICInboundMessage) throws {
        guard !lock.withLock({ stopped }) else { return }
        switch (message.datagramChannel, message.datagramKind, message.lane) {
        case (2?, 1?, .video):
            try receiveVideo(message)
        case (3?, 1?, .audio):
            try receiveAudio(message)
        default:
            throw ProtocolV3MediaPipelineError.invalidDatagram("route")
        }
    }

    public func stopAndCleanUp() {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            videoReassembler.removeAll()
            pendingAudio.removeAll()
            return true
        }
        guard shouldStop else { return }
        pipeline.videoDecoder.stop()
        pipeline.audioDecoder.stop()
        pipeline.cleanUp()
    }

    /// Drops only connection-scoped reorder/reassembly state. Decoder,
    /// AudioQueue, Metal, and acknowledged configurations remain owned for the
    /// bounded ATTACH grace period.
    public func suspendForReconnect() {
        lock.withLock {
            videoReassembler.suspendForReconnect()
            pendingAudio.removeAll(keepingCapacity: true)
        }
    }

    private func receiveVideo(_ message: QUICInboundMessage) throws {
        try videoDeliveryLock.withLock {
            try receiveVideoInOrder(message)
        }
    }

    private func receiveVideoInOrder(_ message: QUICInboundMessage) throws {
        guard let frameID = message.objectID,
              frameID > 0,
              let flags = message.datagramFlags,
              message.payload.count > 64 else {
            throw ProtocolV3MediaPipelineError.invalidDatagram("video envelope")
        }
        let payload = message.payload
        lock.withLock { videoFragmentsReceived += 1 }
        let frameSize = Int(Self.read(UInt32.self, payload, 32))
        let fragmentOffset = Int(Self.read(UInt32.self, payload, 36))
        let fragmentIndex = Int(Self.read(UInt16.self, payload, 40))
        let fragmentCount = Int(Self.read(UInt16.self, payload, 42))
        let codecID = payload[53]
        let matrix = payload[54]
        let bitDepth = payload[55]
        let generation = Self.read(UInt32.self, payload, 56)
        let fragment = payload.dropFirst(64)
        guard frameSize > 0, frameSize <= 67_108_864,
              fragmentCount > 0, fragmentIndex < fragmentCount,
              fragmentOffset >= 0, fragmentOffset + fragment.count <= frameSize,
              let configuration = lock.withLock({ videoConfiguration }),
              generation == configuration.generation,
              codecID == Self.codecID(configuration.format),
              bitDepth == (configuration.format.isTenBit ? 10 : 8),
              configuration.tuple[7]?.unsignedValue == UInt64(matrix),
              (flags & 0x20 != 0) == configuration.hasStaticHDRMetadata else {
            throw ProtocolV3MediaPipelineError.invalidDatagram("video fragment")
        }

        let reassemblyFragment = ProtocolV3VideoFragment(
            frameID: frameID,
            frameSize: frameSize,
            fragmentOffset: fragmentOffset,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            captureTimeMicroseconds: Self.read(UInt64.self, payload, 0),
            encoderCompleteDeltaMicroseconds: Self.read(UInt32.self, payload, 12),
            appliedInputStateSequence: Self.read(UInt64.self, payload, 16),
            appliedInputEdgeID: Self.read(UInt64.self, payload, 24),
            videoGeneration: generation,
            codecID: codecID,
            matrix: matrix,
            bitDepth: bitDepth,
            flags: flags & ~UInt8(0x04),
            bytes: fragment,
            receivedAtNanoseconds: message.receivedAtNanoseconds
        )
        var update = ProtocolV3VideoReassemblyUpdate()
        try lock.withLock {
            guard !stopped else { return }
            update = try videoReassembler.accept(
                reassemblyFragment,
                framesPerSecond: configuration.framesPerSecond
            )
            if let reassembledFrameID = update.reassembledFrameID {
                lastReassembledVideoFrameID = max(lastReassembledVideoFrameID, reassembledFrameID)
                videoFramesReassembled += 1
            }
            videoFramesDropped += UInt64(update.lostFrameIDs.count)
        }
        for lostFrameID in update.lostFrameIDs {
            emitVideoFeedback(affectedFrameID: lostFrameID, action: 2)
        }
        if let requestedKeyFrameID = update.requestedKeyFrameID {
            emitVideoFeedback(affectedFrameID: requestedKeyFrameID, action: 4)
        }
        submitVideoFrames(update.readyFrames, configuration: configuration)
    }

    private func submitVideoFrames(
        _ frames: [ProtocolV3ReassembledVideoFrame],
        configuration: VideoConfiguration
    ) {
        let payloadFormat: UmbraStreaming.EncodedVideoPayloadFormat = switch configuration.format {
        case .av1Main8, .av1Main10, .av1High8YUV444, .av1High10YUV444:
            .av1LowOverheadOBU
        default:
            .annexB
        }
        for (index, frame) in frames.enumerated() {
            let shouldReportFirstSubmit = lock.withLock { () -> Bool in
                guard !reportedFirstVideoSubmit else { return false }
                reportedFirstVideoSubmit = true
                return true
            }
            if shouldReportFirstSubmit { firstVideoSubmitHandler() }
            let disposition = pipeline.videoDecoder.submit(frame: .init(
                data: frame.data,
                payloadFormat: payloadFormat,
                frameNumber: Int(clamping: frame.frameID),
                isKeyFrame: frame.flags & 0x01 != 0,
                hostProcessingLatencyTenthsOfMillisecond: UInt16(
                    clamping: frame.encoderCompleteDeltaMicroseconds / 100
                ),
                receiveTimeMicroseconds: frame.receivedAtNanoseconds / 1_000,
                enqueueTimeMicroseconds: Self.monotonicMicroseconds(),
                presentationTimeMicroseconds: frame.receivedAtNanoseconds / 1_000,
                isHDR: configuration.isHDR,
                colorSpace: Self.bridgeColorSpace(matrix: frame.matrix),
                hostCaptureTimeMicroseconds: frame.captureTimeMicroseconds,
                appliedInputStateSequence: frame.appliedInputStateSequence,
                appliedInputEdgeID: frame.appliedInputEdgeID,
                videoConfigurationGeneration: frame.videoGeneration
            ))
            if disposition == .requestKeyFrame {
                let unsentFrameIDs = frames.dropFirst(index + 1).map(\.frameID)
                let pendingFrameIDs = lock.withLock { () -> [UInt64] in
                    let pending = videoReassembler.requireKeyFrame()
                    videoFramesDropped += UInt64(unsentFrameIDs.count + pending.count)
                    return pending
                }
                for lostFrameID in unsentFrameIDs + pendingFrameIDs {
                    emitVideoFeedback(affectedFrameID: lostFrameID, action: 2)
                }
                diagnosticHandler(
                    "Protocol v3 VideoToolbox requested a key frame after frame \(frame.frameID)."
                )
                emitVideoFeedback(affectedFrameID: frame.frameID, action: 4)
                break
            }
            lock.withLock { videoFramesSubmitted += 1 }
        }
    }

    private func handleDecodeOutcome(_ outcome: UmbraStreaming.VideoDecodeOutcome) {
        switch outcome {
        case let .decoded(frameNumber):
            guard let frameID = UInt64(exactly: frameNumber) else { return }
            lock.withLock {
                lastDecodedVideoFrameID = max(lastDecodedVideoFrameID, frameID)
                videoFramesDecoded += 1
            }
            emitVideoFeedback(affectedFrameID: frameID, action: 1)
        case let .failed(frameNumber):
            guard let frameID = UInt64(exactly: frameNumber) else { return }
            let pendingFrameIDs = lock.withLock { () -> [UInt64] in
                let pending = videoReassembler.requireKeyFrame()
                videoFramesDropped += 1 + UInt64(pending.count)
                return pending
            }
            for pendingFrameID in pendingFrameIDs {
                emitVideoFeedback(affectedFrameID: pendingFrameID, action: 2)
            }
            emitVideoFeedback(affectedFrameID: frameID, action: 4)
        }
    }

    private func emitVideoFeedback(affectedFrameID: UInt64, action: UInt8) {
        let feedback = lock.withLock { () -> (ProtocolV3VideoFeedback, (@Sendable (ProtocolV3VideoFeedback) -> Void)?) in
            (
                ProtocolV3VideoFeedback(
                    affectedFrameID: affectedFrameID,
                    lastReassembledFrameID: lastReassembledVideoFrameID,
                    lastDecodedFrameID: lastDecodedVideoFrameID,
                    action: action,
                    deadlineMissMicroseconds: 0
                ),
                videoFeedbackHandler
            )
        }
        lock.withLock { videoFeedbackSent += 1 }
        feedback.1?(feedback.0)
    }

    private func receiveAudio(_ message: QUICInboundMessage) throws {
        guard let samplePosition = message.objectID,
              message.payload.count >= 48,
              Self.read(UInt64.self, message.payload, 8) == samplePosition else {
            throw ProtocolV3MediaPipelineError.invalidDatagram("audio envelope")
        }
        let payload = message.payload
        lock.withLock { audioPacketsReceived += 1 }
        let generation = Self.read(UInt32.self, payload, 16)
        let flags = payload[25]
        let packet = payload.dropFirst(48)
        guard let configuration = lock.withLock({ audioConfiguration }),
              generation == configuration.generation,
              payload[24] == 1,
              payload[22] == UInt8(configuration.format.channelCount),
              Self.read(UInt16.self, payload, 20) == UInt16(configuration.format.samplesPerFrame),
              payload[23] == configuration.layout,
              payload[26] == UInt8(configuration.format.streamCount),
              payload[27] == UInt8(configuration.format.coupledStreamCount),
              Data(payload[28..<36]) == Data(
                configuration.format.mapping
                    + Array(repeating: 0xFF, count: 8 - configuration.format.mapping.count)
              ),
              Self.read(UInt32.self, payload, 36) == configuration.bitrate,
              Self.read(UInt64.self, payload, 40) == 0,
              samplePosition.isMultiple(of: UInt64(configuration.format.samplesPerFrame)),
              flags & ~UInt8(0x07) == 0 else {
            throw ProtocolV3MediaPipelineError.invalidDatagram("audio generation")
        }
        guard !packet.isEmpty || flags & 0x05 != 0 else {
            throw ProtocolV3MediaPipelineError.invalidDatagram("empty audio")
        }
        if flags & 0x02 != 0 {
            guard let discontinuity = pipeline.audioDecoder as? any UmbraStreaming.AudioDiscontinuityHandling,
                  discontinuity.handleAudioDiscontinuity() else {
                throw ProtocolV3MediaPipelineError.decoderRejectedConfiguration
            }
            lock.withLock { audioDiscontinuities += 1 }
        }
        enum AudioAction {
            case packet(Data)
            case end
        }
        let actions: [AudioAction] = lock.withLock {
            guard !stopped else { return [] }
            let frameSamples = UInt64(configuration.format.samplesPerFrame)
            if flags & 0x02 != 0 {
                pendingAudio.removeAll(keepingCapacity: true)
                nextAudioSamplePosition = samplePosition
            }
            guard samplePosition >= nextAudioSamplePosition else { return [] }
            guard pendingAudio[samplePosition] == nil else { return [] }
            pendingAudio[samplePosition] = BufferedAudioPacket(flags: flags, data: Data(packet))
            let capacity = mode == .latency ? 3 : 6
            var results: [AudioAction] = []
            while true {
                if let next = pendingAudio.removeValue(forKey: nextAudioSamplePosition) {
                    if next.flags & 0x04 != 0 {
                        results.append(.end)
                        pendingAudio.removeAll(keepingCapacity: true)
                        break
                    }
                    // Empty DTX still advances exactly one frame through Opus PLC;
                    // it never removes time from the playback timeline.
                    results.append(.packet(next.data))
                    nextAudioSamplePosition += frameSamples
                    continue
                }
                if pendingAudio.count >= capacity,
                   let firstFuture = pendingAudio.keys.min(),
                   firstFuture > nextAudioSamplePosition {
                    results.append(.packet(Data()))
                    audioConcealmentFrames += 1
                    nextAudioSamplePosition += frameSamples
                    continue
                }
                break
            }
            return results
        }
        for action in actions {
            switch action {
            case let .packet(data):
                pipeline.audioDecoder.submit(packet: .init(data: data))
            case .end:
                pipeline.audioDecoder.stop()
            }
        }
    }

    private static func videoFormat(
        _ tuple: [UInt64: ProtocolV3CBORValue]
    ) throws -> MoonlightVideoFormat {
        guard Set(tuple.keys) == Set(1...10),
              let codec = tuple[1]?.unsignedValue,
              let profile = tuple[2]?.unsignedValue, profile != 0,
              let bitDepth = tuple[3]?.unsignedValue,
              let layout = tuple[4]?.unsignedValue,
              let primaries = tuple[5]?.unsignedValue, primaries <= UInt8.max,
              let transfer = tuple[6]?.unsignedValue, (1...3).contains(transfer),
              let matrix = tuple[7]?.unsignedValue, matrix <= UInt8.max,
              let range = tuple[8]?.unsignedValue, range <= 1,
              let flags = tuple[9]?.unsignedValue, flags & ~UInt64(0x03) == 0,
              let fidelity = tuple[10]?.unsignedValue, (1...3).contains(fidelity),
              [8, 10].contains(bitDepth),
              [1, 2].contains(layout) else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration("codec tuple")
        }
        guard fidelity != 3 || flags & 0x02 != 0 else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration("unproven lossless tuple")
        }
        let format: MoonlightVideoFormat? = switch (codec, bitDepth, layout) {
        case (1, 8, 1): .h264
        case (1, 8, 2): .h264High8YUV444
        case (2, 8, 1): .hevc
        case (2, 10, 1): .hevcMain10
        case (2, 8, 2): .hevcRext8YUV444
        case (2, 10, 2): .hevcRext10YUV444
        case (3, 8, 1): .av1Main8
        case (3, 10, 1): .av1Main10
        case (3, 8, 2): .av1High8YUV444
        case (3, 10, 2): .av1High10YUV444
        default: nil
        }
        guard let format else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration("unsupported codec tuple")
        }
        return format
    }

    private static func hdrSelection(
        _ value: ProtocolV3CBORValue?,
        selectedTuple: [UInt64: ProtocolV3CBORValue],
        selectedFormat: MoonlightVideoFormat
    ) throws -> HDRSelection {
        guard let value else { throw ProtocolV3MediaPipelineError.invalidConfiguration("HDR field") }
        if case .null = value {
            guard selectedTuple[6]?.unsignedValue == 1 else {
                throw ProtocolV3MediaPipelineError.invalidConfiguration("HDR transfer downgrade")
            }
            return HDRSelection(enabled: false, hasStaticMetadata: false, metadata: nil)
        }
        guard let map = value.mapValue,
              Set(map.keys) == Set(1...7),
              let transfer = map[1]?.unsignedValue,
              (2...3).contains(transfer),
              selectedTuple[6]?.unsignedValue == (transfer == 2 ? 16 : 18),
              map[2]?.unsignedValue == selectedTuple[5]?.unsignedValue,
              map[3]?.unsignedValue == selectedTuple[7]?.unsignedValue,
              map[4]?.unsignedValue == selectedTuple[8]?.unsignedValue,
              let bitDepth = map[5]?.unsignedValue,
              bitDepth == UInt64(selectedFormat.isTenBit ? 10 : 8),
              let dynamicMetadata = map[7]?.arrayValue,
              dynamicMetadata.isEmpty else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration("HDR tuple")
        }
        var primaries = [UInt16](repeating: 0, count: 6)
        var white = [UInt16](repeating: 0, count: 2)
        var maximumMastering: UInt32 = 0
        var minimumMastering: UInt32 = 0
        var maxCLL: UInt16 = 0
        var maxFALL: UInt16 = 0
        if map[6] != .null {
            guard let mastering = map[6]?.mapValue,
                  Set(mastering.keys) == Set(1...6),
                  let primaryValues = mastering[1]?.arrayValue,
                  primaryValues.count == 6,
                  let whiteValues = mastering[2]?.arrayValue,
                  whiteValues.count == 2,
                  let maximum = mastering[3]?.unsignedValue.flatMap(UInt32.init(exactly:)),
                  let minimum = mastering[4]?.unsignedValue.flatMap(UInt32.init(exactly:)),
                  minimum <= maximum,
                  let content = mastering[5]?.unsignedValue.flatMap(UInt16.init(exactly:)),
                  let frameAverage = mastering[6]?.unsignedValue.flatMap(UInt16.init(exactly:)) else {
                throw ProtocolV3MediaPipelineError.invalidConfiguration("HDR mastering metadata")
            }
            primaries = try primaryValues.map {
                guard let value = $0.unsignedValue.flatMap(UInt16.init(exactly:)) else {
                    throw ProtocolV3MediaPipelineError.invalidConfiguration("HDR primaries")
                }
                return value
            }
            white = try whiteValues.map {
                guard let value = $0.unsignedValue.flatMap(UInt16.init(exactly:)) else {
                    throw ProtocolV3MediaPipelineError.invalidConfiguration("HDR white point")
                }
                return value
            }
            maximumMastering = maximum
            minimumMastering = minimum
            maxCLL = content
            maxFALL = frameAverage
        }
        let maximumNits = UInt16(clamping: maximumMastering / 10_000)
        return HDRSelection(
            enabled: true,
            hasStaticMetadata: map[6] != .null,
            metadata: .init(
                redX: primaries[0], redY: primaries[1],
                greenX: primaries[2], greenY: primaries[3],
                blueX: primaries[4], blueY: primaries[5],
                whiteX: white[0], whiteY: white[1],
                maximumDisplayLuminanceNits: maximumNits,
                minimumDisplayLuminanceTenThousandthsOfNit: UInt16(clamping: minimumMastering),
                maximumContentLightLevelNits: maxCLL,
                maximumFrameAverageLightLevelNits: maxFALL,
                maximumFullFrameLuminanceNits: maxFALL,
                transfer: transfer == 3 ? .hlg : .pq
            )
        )
    }

    private static func uint8(
        _ map: [UInt64: ProtocolV3CBORValue],
        key: UInt64,
        field: String
    ) throws -> UInt8 {
        guard let value = map[key]?.unsignedValue.flatMap(UInt8.init(exactly:)) else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration(field)
        }
        return value
    }

    private static func uint32(
        _ map: [UInt64: ProtocolV3CBORValue],
        key: UInt64,
        field: String
    ) throws -> UInt32 {
        guard let value = map[key]?.unsignedValue.flatMap(UInt32.init(exactly:)) else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration(field)
        }
        return value
    }

    private static func audioFormat(
        _ tuple: [UInt64: ProtocolV3CBORValue]
    ) throws -> UmbraStreaming.OpusStreamFormat {
        guard Set(tuple.keys) == Set(1...9),
              tuple[1]?.unsignedValue == 1,
              tuple[2]?.unsignedValue == 48_000,
              let channelsRaw = tuple[3]?.unsignedValue,
              let channels = Int(exactly: channelsRaw),
              [2, 6, 8].contains(channels),
              let samplesRaw = tuple[4]?.unsignedValue,
              let samples = Int(exactly: samplesRaw),
              samples > 0,
              let streamsRaw = tuple[6]?.unsignedValue,
              let streams = Int(exactly: streamsRaw),
              let coupledRaw = tuple[7]?.unsignedValue,
              let coupled = Int(exactly: coupledRaw),
              streams > 0, coupled <= streams,
              let mapping = tuple[8]?.bytesValue,
              mapping.count == channels,
              let bitrate = tuple[9]?.unsignedValue,
              bitrate > 0,
              bitrate <= UInt64.max / UInt64(samples),
              bitrate * UInt64(samples) / 48_000 / 8 + 48 <= 1_108 else {
            throw ProtocolV3MediaPipelineError.invalidConfiguration("audio tuple")
        }
        let audioConfiguration: Int32 = switch channels {
        case 2: (0x3 << 16) | (2 << 8) | 0xCA
        case 6: (0x3F << 16) | (6 << 8) | 0xCA
        case 8: (0x63F << 16) | (8 << 8) | 0xCA
        default: preconditionFailure()
        }
        return UmbraStreaming.OpusStreamFormat(
            audioConfiguration: audioConfiguration,
            sampleRate: 48_000,
            channelCount: channels,
            streamCount: streams,
            coupledStreamCount: coupled,
            samplesPerFrame: samples,
            mapping: Array(mapping),
            flags: 0
        )
    }

    private static func codecID(_ format: MoonlightVideoFormat) -> UInt8 {
        switch format {
        case .h264, .h264High8YUV444: 1
        case .hevc, .hevcMain10, .hevcRext8YUV444, .hevcRext10YUV444: 2
        case .av1Main8, .av1Main10, .av1High8YUV444, .av1High10YUV444: 3
        }
    }

    private static func bridgeColorSpace(matrix: UInt8) -> UInt8 {
        switch matrix {
        case 5, 6: 0
        case 9: 2
        default: 1
        }
    }

    private static func read<T: FixedWidthInteger>(
        _ type: T.Type,
        _ data: Data,
        _ offset: Int
    ) -> T {
        data[offset..<(offset + MemoryLayout<T>.size)].reduce(T.zero) {
            ($0 << 8) | T($1)
        }
    }

    private static func monotonicMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000
    }
}
