import Foundation
import XCTest
@testable import UmbraMedia

final class VideoAccessUnitCaptureTests: XCTestCase {
    func testCaptureIsDisabledWithoutExplicitTemporaryDirectory() {
        XCTAssertNil(VideoAccessUnitCapture.fromEnvironment([:]))
        XCTAssertThrowsError(try VideoAccessUnitCapture(directoryPath: "/var/tmp/umbra-au"))
    }

    func testCaptureWritesOnlyFirstKeyAndThreeDeltasWithPrivateMetadata() throws {
        let root = "/tmp/UmbraAUCaptureTests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let capture = try VideoAccessUnitCapture(directoryPath: root)
        let keyAnnexB = Data([0, 0, 0, 1, 0x26, 0x01, 0xAA])
        let keyLengthPrefixed = Data([0, 0, 0, 3, 0x26, 0x01, 0xAA])
        let deltaAnnexB = Data([0, 0, 1, 0x02, 0x01, 0xBB])
        let deltaLengthPrefixed = Data([0, 0, 0, 3, 0x02, 0x01, 0xBB])

        capture.capture(
            frame: frame(id: 0, isKeyFrame: false),
            codec: .hevc,
            annexB: deltaAnnexB,
            lengthPrefixed: deltaLengthPrefixed
        )
        capture.capture(
            frame: frame(id: 1, isKeyFrame: true),
            codec: .hevc,
            annexB: keyAnnexB,
            lengthPrefixed: keyLengthPrefixed
        )
        for frameID in 2...5 {
            capture.capture(
                frame: frame(id: frameID, isKeyFrame: false),
                codec: .hevc,
                annexB: deltaAnnexB,
                lengthPrefixed: deltaLengthPrefixed
            )
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: root).sorted()
        XCTAssertEqual(files.count, 12)
        XCTAssertEqual(files.filter { $0.hasSuffix(".json") }.count, 4)
        XCTAssertFalse(files.contains { $0.contains("frame-0") || $0.contains("frame-5") })

        let metadataFiles = files.filter { $0.hasSuffix(".json") }
        let metadata = try metadataFiles.map {
            try JSONDecoder().decode(
                VideoAccessUnitCapture.Metadata.self,
                from: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent($0))
            )
        }.sorted { $0.captureIndex < $1.captureIndex }
        XCTAssertEqual(metadata.map(\.frameID), [1, 2, 3, 4])
        XCTAssertEqual(metadata.map(\.isKeyFrame), [true, false, false, false])
        XCTAssertEqual(metadata.first?.preConversionNALUnits.first?.startCodeLength, 4)
        XCTAssertEqual(metadata.first?.postConversionNALUnits.first?.lengthFieldOffset, 0)
        XCTAssertEqual(metadata.first?.preConversionNALUnits.first?.nalType, 19)
        XCTAssertEqual(metadata.last?.preConversionNALUnits.first?.nalType, 1)
        XCTAssertTrue(metadata.allSatisfy {
            $0.preConversionSHA256.count == 64 && $0.postConversionSHA256.count == 64
        })

        let attributes = try FileManager.default.attributesOfItem(
            atPath: URL(fileURLWithPath: root).appendingPathComponent(files[0]).path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    private func frame(id: Int, isKeyFrame: Bool) -> CompressedVideoFrame {
        CompressedVideoFrame(
            data: Data([1]),
            frameNumber: id,
            isKeyFrame: isKeyFrame,
            hostProcessingLatencyTenthsOfMillisecond: 12,
            receiveTimeMicroseconds: UInt64(id * 10),
            enqueueTimeMicroseconds: UInt64(id * 10 + 1),
            presentationTimeMicroseconds: UInt64(id * 10 + 2),
            isHDR: false,
            hostCaptureTimeMicroseconds: UInt64(id * 10 + 3),
            appliedInputStateSequence: UInt64(id),
            appliedInputEdgeID: UInt64(id + 1),
            videoConfigurationGeneration: 1
        )
    }
}
