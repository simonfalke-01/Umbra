import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Decodes Lumen's intra-only BC1 stream on the GPU.
///
/// Each access unit is one AV1 padding OBU whose payload is a 16-byte header followed by BC1
/// blocks in row-major order. The Mac GPU samples BC1 natively, so decoding is a texture upload
/// and one compute pass that expands the blocks into a BGRA frame for the existing renderer.
public final class BC1MetalDecoder: @unchecked Sendable {
    public enum DecoderError: Error {
        case metalUnavailable
        case invalidDimensions
    }

    /// Bytes before the first block: "LBC1", width, height, block bytes, reserved.
    static let headerBytes = 16
    static let magic: [UInt8] = Array("LBC1".utf8)

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let pixelBufferPool: CVPixelBufferPool
    /// One block texture per admissible in-flight frame. Admission keeps fewer than this many
    /// frames in flight, so the slot reused next has always finished its compute pass.
    private let blockTextures: [MTLTexture]
    private var nextBlockTexture = 0
    private let width: Int
    private let height: Int
    private let blockBytes: Int
    private weak var renderer: (any MetalVideoRendering)?
    private let lock = NSLock()
    private var outcomeHandler: (@Sendable (VideoDecodeOutcome) -> Void)?
    private var running = false
    private var inFlight = 0
    private let maximumInFlight: Int

    public init(renderer: any MetalVideoRendering, width: Int, height: Int, maximumOutstandingFrames: Int) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw DecoderError.invalidDimensions
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              device.supportsBCTextureCompression,
              let queue = device.makeCommandQueue()
        else { throw DecoderError.metalUnavailable }
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let function = library.makeFunction(name: "expand_bc1") else { throw DecoderError.metalUnavailable }
        pipeline = try device.makeComputePipelineState(function: function)

        let paddedWidth = (width + 3) & ~3
        let paddedHeight = (height + 3) & ~3
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bc1_rgba,
            width: paddedWidth,
            height: paddedHeight,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let blockTextures = (0..<max(1, maximumOutstandingFrames)).compactMap { _ in
            device.makeTexture(descriptor: descriptor)
        }
        guard blockTextures.count == max(1, maximumOutstandingFrames) else {
            throw DecoderError.metalUnavailable
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw DecoderError.metalUnavailable
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            nil,
            [kCVPixelBufferPoolMinimumBufferCountKey: maximumOutstandingFrames + 3] as CFDictionary,
            attributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool else { throw DecoderError.metalUnavailable }

        self.device = device
        self.queue = queue
        self.textureCache = cache
        self.pixelBufferPool = pool
        self.blockTextures = blockTextures
        self.width = width
        self.height = height
        self.blockBytes = (paddedWidth / 4) * (paddedHeight / 4) * 8
        self.renderer = renderer
        self.maximumInFlight = max(1, maximumOutstandingFrames)
    }

    public func installDecodeOutcomeHandler(_ handler: @escaping @Sendable (VideoDecodeOutcome) -> Void) {
        lock.withLock { outcomeHandler = handler }
    }

    public func start() {
        lock.withLock { running = true }
    }

    public func cleanUpPreservingRenderer() {
        lock.withLock {
            running = false
            outcomeHandler = nil
        }
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    public func submit(frame: CompressedVideoFrame) -> VideoFrameDisposition {
        let submitTime = VideoLatencyTimestamp(seconds: CACurrentMediaTime(), clockDomain: .clientMediaTime)
        let blockTexture = lock.withLock { () -> MTLTexture? in
            guard running, inFlight < maximumInFlight else { return nil }
            inFlight += 1
            let texture = blockTextures[nextBlockTexture]
            nextBlockTexture = (nextBlockTexture + 1) % blockTextures.count
            return texture
        }
        guard let blockTexture else { return .capacityDropped }

        guard let output = makeOutput(),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(),
              upload(frame.data, into: blockTexture)
        else {
            finish(.failed(frameNumber: frame.frameNumber))
            return .accepted
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(blockTexture, index: 0)
        encoder.setTexture(output.texture, index: 1)
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: threads)
        encoder.endEncoding()

        let metadata = VideoFrameLatencyMetadata(
            receiveTime: Self.uptime(frame.receiveTimeMicroseconds),
            videoToolboxSubmitTime: submitTime,
            hostCaptureTimeMicroseconds: frame.hostCaptureTimeMicroseconds == 0 ? nil : frame.hostCaptureTimeMicroseconds,
            appliedInputStateSequence: frame.appliedInputStateSequence,
            appliedInputEdgeID: frame.appliedInputEdgeID,
            videoConfigurationGeneration: frame.videoConfigurationGeneration
        )
        let frameNumber = frame.frameNumber
        let presentationTime = CMTime(value: CMTimeValue(frame.presentationTimeMicroseconds), timescale: 1_000_000)
        let pixelBuffer = output.pixelBuffer
        let metalTexture = output.metalTexture
        commandBuffer.addCompletedHandler { [weak self] completed in
            withExtendedLifetime(metalTexture) {}
            guard let self else { return }
            guard completed.status == .completed else {
                self.finish(.failed(frameNumber: frameNumber))
                return
            }
            let decodedAt = VideoLatencyTimestamp(seconds: CACurrentMediaTime(), clockDomain: .clientMediaTime)
            if self.lock.withLock({ self.running }) {
                self.renderer?.enqueue(DecodedVideoFrame(
                    imageBuffer: pixelBuffer,
                    presentationTime: presentationTime,
                    frameNumber: frameNumber,
                    color: .rec709SDR,
                    latencyMetadata: metadata.recordingDecodeCompletion(decodedAt)
                ))
            }
            self.finish(.decoded(frameNumber: frameNumber))
        }
        commandBuffer.commit()
        return .accepted
    }

    private func finish(_ outcome: VideoDecodeOutcome) {
        let handler = lock.withLock { () -> (@Sendable (VideoDecodeOutcome) -> Void)? in
            inFlight = max(0, inFlight - 1)
            return outcomeHandler
        }
        handler?(outcome)
    }

    /// Copies the block payload into this frame's BC1 texture before its compute pass is committed.
    private func upload(_ data: Data, into blockTexture: MTLTexture) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let payload = Self.payloadRange(raw) else { return false }
            let bytes = UnsafeRawBufferPointer(rebasing: raw[payload])
            guard bytes.count >= Self.headerBytes + blockBytes,
                  Array(bytes[0..<4]) == Self.magic,
                  Int(Self.readUInt16(bytes, 4)) == width,
                  Int(Self.readUInt16(bytes, 6)) == height,
                  Int(Self.readUInt32(bytes, 8)) == blockBytes,
                  let base = bytes.baseAddress
            else { return false }
            blockTexture.replace(
                region: MTLRegionMake2D(0, 0, blockTexture.width, blockTexture.height),
                mipmapLevel: 0,
                withBytes: base + Self.headerBytes,
                bytesPerRow: (blockTexture.width / 4) * 8
            )
            return true
        }
    }

    private func makeOutput() -> (pixelBuffer: CVPixelBuffer, metalTexture: CVMetalTexture, texture: MTLTexture)? {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        var metalTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &metalTexture
        ) == kCVReturnSuccess,
            let metalTexture,
            let texture = CVMetalTextureGetTexture(metalTexture)
        else { return nil }
        return (pixelBuffer, metalTexture, texture)
    }

    /// Returns the payload of the single padding OBU (type 15) that carries the frame.
    static func payloadRange(_ bytes: UnsafeRawBufferPointer) -> Range<Int>? {
        guard bytes.count >= 2 else { return nil }
        let header = bytes[0]
        guard (header >> 3) & 0x0F == 15, header & 0x81 == 0, header & 0x02 != 0 else { return nil }
        var offset = 1 + (header & 0x04 != 0 ? 1 : 0)
        var size = 0
        var shift = 0
        while true {
            guard offset < bytes.count, shift < 56 else { return nil }
            let byte = bytes[offset]
            offset += 1
            size |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        guard size <= bytes.count - offset else { return nil }
        return offset..<(offset + size)
    }

    private static func readUInt16(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func uptime(_ microseconds: UInt64) -> VideoLatencyTimestamp? {
        guard microseconds > 0 else { return nil }
        return VideoLatencyTimestamp(seconds: Double(microseconds) / 1_000_000, clockDomain: .gameStreamClientUptime)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void expand_bc1(texture2d<float, access::read> blocks [[texture(0)]],
                           texture2d<float, access::write> output [[texture(1)]],
                           uint2 position [[thread_position_in_grid]]) {
        if (position.x >= output.get_width() || position.y >= output.get_height()) { return; }
        output.write(float4(blocks.read(position).rgb, 1.0), position);
    }
    """
}

/// The decoder surface the LSP video pipeline drives, shared by VideoToolbox and BC1 decoding.
public protocol LSPFrameDecoding: AnyObject, Sendable {
    func submit(frame: CompressedVideoFrame) -> VideoFrameDisposition
    func installDecodeOutcomeHandler(_ handler: @escaping @Sendable (VideoDecodeOutcome) -> Void)
    func start()
    func cleanUpPreservingRenderer()
    /// Coarse pipeline counters for the telemetry overlay, when the decoder keeps them.
    func pipelineStatistics() -> MediaPipelineStatistics?
}

extension VideoToolboxDecoder: LSPFrameDecoding {
    public func pipelineStatistics() -> MediaPipelineStatistics? { statistics() }
}

extension BC1MetalDecoder: LSPFrameDecoding {
    public func pipelineStatistics() -> MediaPipelineStatistics? { nil }
}

extension AppleStreamingCapabilities {
    /// Whether this Mac's GPU samples BC1 textures, which the BC1 stream decoder needs.
    public var supportsBC1Textures: Bool {
        hasMetalDevice && (MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression ?? false)
    }
}
