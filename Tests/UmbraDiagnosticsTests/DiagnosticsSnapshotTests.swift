import Foundation
import XCTest
@testable import UmbraDiagnostics

final class DiagnosticsSnapshotTests: XCTestCase {
    func testCapabilityDTOsAndSnapshotRoundTrip() throws {
        let snapshot = fixtureSnapshot()
        let data = try DiagnosticsExporter().encodedSnapshot(snapshot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(DiagnosticsSnapshot.self, from: data), snapshot)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(NSUserName()))
        XCTAssertFalse(text.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func testExportWritesPrivateDeterministicJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraDiagnosticsExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        let exporter = DiagnosticsExporter()

        XCTAssertEqual(try exporter.export(fixtureSnapshot(), to: destination), destination)
        let data = try Data(contentsOf: destination)
        XCTAssertEqual(data, try exporter.encodedSnapshot(fixtureSnapshot()))
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    private func fixtureSnapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            application: ApplicationBuildInfo(name: "Umbra", version: "1.0", build: "42"),
            operatingSystem: OperatingSystemSnapshot(
                name: "macOS",
                version: "14.6.1",
                kernelVersion: "23.6.0",
                architecture: .arm64
            ),
            decoderCapabilities: DecoderCapabilityInventory(decoders: [
                DecoderCapability(codec: .h264, hardwareDecodeSupported: true),
                DecoderCapability(codec: .hevc, hardwareDecodeSupported: true),
                DecoderCapability(codec: .av1, hardwareDecodeSupported: false),
            ]),
            displayCapabilities: DisplayCapabilityInventory(displays: [
                DisplayCapability(
                    index: 0,
                    isMain: true,
                    isBuiltIn: true,
                    pixelWidth: 3024,
                    pixelHeight: 1964,
                    pointWidth: 1512,
                    pointHeight: 982,
                    backingScaleFactor: 2,
                    maximumFramesPerSecond: 120,
                    supportsExtendedDynamicRange: true,
                    maximumExtendedDynamicRangeHeadroom: 1.6,
                    colorSpaceName: "Display P3"
                ),
            ]),
            supportLogs: [SupportLogDescriptor(fileName: "Umbra-1-test.log", byteCount: 512)]
        )
    }
}
