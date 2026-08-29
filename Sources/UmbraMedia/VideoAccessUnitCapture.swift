import CryptoKit
import Foundation

final class VideoAccessUnitCapture: @unchecked Sendable {
    static let environmentKey = "UMBRA_AU_CAPTURE_DIR"

    struct NALMetadata: Codable, Equatable {
        let index: Int
        let startCodeOffset: Int?
        let startCodeLength: Int?
        let lengthFieldOffset: Int?
        let payloadOffset: Int
        let payloadLength: Int
        let nalType: UInt8
    }

    struct Metadata: Codable, Equatable {
        let captureIndex: Int
        let frameID: Int
        let codec: String
        let isKeyFrame: Bool
        let requiresIndependentDecode: Bool
        let isHDR: Bool
        let preConversionByteCount: Int
        let postConversionByteCount: Int
        let preConversionSHA256: String
        let postConversionSHA256: String
        let hostCaptureTimeMicroseconds: UInt64
        let receiveTimeMicroseconds: UInt64
        let enqueueTimeMicroseconds: UInt64
        let presentationTimeMicroseconds: UInt64
        let appliedInputStateSequence: UInt64
        let appliedInputEdgeID: UInt64
        let videoConfigurationGeneration: UInt32
        let preConversionNALUnits: [NALMetadata]
        let postConversionNALUnits: [NALMetadata]
    }

    private let directoryURL: URL
    private let lock = NSLock()
    private var capturedKeyFrame = false
    private var capturedDeltaCount = 0
    private var nextCaptureIndex = 0

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VideoAccessUnitCapture? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        return try? VideoAccessUnitCapture(directoryPath: path)
    }

    init(directoryPath: String) throws {
        let candidate = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
        guard Self.isLocalTemporaryPath(candidate.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.createDirectory(
            at: candidate,
            withIntermediateDirectories: true
        )
        let resolved = candidate.resolvingSymlinksInPath()
        guard Self.isLocalTemporaryPath(resolved.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: resolved.path
        )
        directoryURL = resolved
    }

    func capture(
        frame: CompressedVideoFrame,
        codec: VideoCodec,
        annexB: Data,
        lengthPrefixed: Data
    ) {
        let reservation = lock.withLock { () -> (index: Int, kind: String)? in
            if !capturedKeyFrame {
                guard frame.isKeyFrame else { return nil }
                capturedKeyFrame = true
            } else {
                guard !frame.isKeyFrame, capturedDeltaCount < 3 else { return nil }
                capturedDeltaCount += 1
            }
            defer { nextCaptureIndex += 1 }
            return (nextCaptureIndex, frame.isKeyFrame ? "key" : "delta")
        }
        guard let reservation else { return }

        do {
            let prefix = String(
                format: "capture-%02d-frame-%d-%@",
                reservation.index,
                frame.frameNumber,
                reservation.kind
            )
            let metadata = Metadata(
                captureIndex: reservation.index,
                frameID: frame.frameNumber,
                codec: String(describing: codec),
                isKeyFrame: frame.isKeyFrame,
                requiresIndependentDecode: frame.requiresIndependentDecode,
                isHDR: frame.isHDR,
                preConversionByteCount: annexB.count,
                postConversionByteCount: lengthPrefixed.count,
                preConversionSHA256: Self.sha256(annexB),
                postConversionSHA256: Self.sha256(lengthPrefixed),
                hostCaptureTimeMicroseconds: frame.hostCaptureTimeMicroseconds,
                receiveTimeMicroseconds: frame.receiveTimeMicroseconds,
                enqueueTimeMicroseconds: frame.enqueueTimeMicroseconds,
                presentationTimeMicroseconds: frame.presentationTimeMicroseconds,
                appliedInputStateSequence: frame.appliedInputStateSequence,
                appliedInputEdgeID: frame.appliedInputEdgeID,
                videoConfigurationGeneration: frame.videoConfigurationGeneration,
                preConversionNALUnits: try Self.annexBNALMetadata(annexB, codec: codec),
                postConversionNALUnits: try Self.lengthPrefixedNALMetadata(
                    lengthPrefixed,
                    codec: codec
                )
            )
            try write(annexB, named: "\(prefix)-pre.annexb")
            try write(lengthPrefixed, named: "\(prefix)-post.length-prefixed")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try write(encoder.encode(metadata), named: "\(prefix).json")
        } catch {
            // Diagnostic capture must never alter or terminate media delivery.
        }
    }

    private func write(_ data: Data, named name: String) throws {
        let url = directoryURL.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func isLocalTemporaryPath(_ path: String) -> Bool {
        path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func nalType(codec: VideoCodec, header: UInt8) -> UInt8 {
        switch codec {
        case .h264: header & 0x1F
        case .hevc: (header >> 1) & 0x3F
        case .av1: header >> 3
        }
    }

    private static func annexBNALMetadata(
        _ data: Data,
        codec: VideoCodec
    ) throws -> [NALMetadata] {
        try data.withUnsafeBytes { bytes in
            guard var current = nextStartCode(in: bytes, startingAt: 0) else {
                throw VideoDecoderError.invalidAccessUnit
            }
            for index in 0..<current.offset where bytes[index] != 0 {
                throw VideoDecoderError.invalidAccessUnit
            }
            var result: [NALMetadata] = []
            while true {
                let payloadOffset = current.offset + current.length
                let next = nextStartCode(in: bytes, startingAt: payloadOffset)
                var payloadEnd = next?.offset ?? bytes.count
                while payloadEnd > payloadOffset, bytes[payloadEnd - 1] == 0 {
                    payloadEnd -= 1
                }
                guard payloadOffset < payloadEnd else {
                    throw VideoDecoderError.invalidAccessUnit
                }
                result.append(NALMetadata(
                    index: result.count,
                    startCodeOffset: current.offset,
                    startCodeLength: current.length,
                    lengthFieldOffset: nil,
                    payloadOffset: payloadOffset,
                    payloadLength: payloadEnd - payloadOffset,
                    nalType: nalType(codec: codec, header: bytes[payloadOffset])
                ))
                guard let next else { return result }
                current = next
            }
        }
    }

    private static func lengthPrefixedNALMetadata(
        _ data: Data,
        codec: VideoCodec
    ) throws -> [NALMetadata] {
        try data.withUnsafeBytes { bytes in
            var result: [NALMetadata] = []
            var offset = 0
            while offset < bytes.count {
                guard bytes.count - offset >= 4 else {
                    throw VideoDecoderError.invalidAccessUnit
                }
                let lengthFieldOffset = offset
                let length = Int(UInt32(bytes[offset]) << 24
                    | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8
                    | UInt32(bytes[offset + 3]))
                offset += 4
                guard length > 0, length <= bytes.count - offset else {
                    throw VideoDecoderError.invalidAccessUnit
                }
                result.append(NALMetadata(
                    index: result.count,
                    startCodeOffset: nil,
                    startCodeLength: nil,
                    lengthFieldOffset: lengthFieldOffset,
                    payloadOffset: offset,
                    payloadLength: length,
                    nalType: nalType(codec: codec, header: bytes[offset])
                ))
                offset += length
            }
            return result
        }
    }

    private static func nextStartCode(
        in bytes: UnsafeRawBufferPointer,
        startingAt start: Int
    ) -> (offset: Int, length: Int)? {
        var index = start
        while index <= bytes.count - 3 {
            if index <= bytes.count - 4,
               bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 0,
               bytes[index + 3] == 1 {
                return (index, 4)
            }
            if bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 1 {
                return (index, 3)
            }
            index += 1
        }
        return nil
    }
}
