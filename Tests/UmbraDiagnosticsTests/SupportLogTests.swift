import Foundation
import XCTest
@testable import UmbraDiagnostics

final class SupportLogTests: XCTestCase {
    func testParityDefaultsAreTenMiBAndTenFiles() {
        let configuration = SupportLogConfiguration(directoryURL: temporaryDirectory())
        XCTAssertEqual(configuration.maximumFileSize, 10 * 1024 * 1024)
        XCTAssertEqual(configuration.retainedFileCount, 10)
    }

    func testRedactsSessionSecretsFromSwiftAndNativeCallbacks() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = try SupportLog(
            configuration: .init(directoryURL: directory),
            now: { now },
            identifier: "callbacks"
        )

        let swiftSink = SupportLogCallbacks.swift(logger: logger, source: "Network")
        swiftSink(.info, "launch?rikey=0123ABC&rikeyid=-42&mode=stream")

        let nativeContext = SupportLogCallbackContext(logger: logger)
        "native &RIKEY=secret_value&RIKEYID=9001".withCString { message in
            SupportLogCallbacks.native(nativeContext.opaquePointer, 4, message)
        }
        logger.flush()

        let contents = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("0123ABC"))
        XCTAssertFalse(contents.contains("secret_value"))
        XCTAssertFalse(contents.contains("9001"))
        XCTAssertTrue(contents.contains("rikey=REDACTED"))
        XCTAssertTrue(contents.contains("rikeyid=REDACTED"))
        XCTAssertTrue(contents.localizedCaseInsensitiveContains("RIKEY=REDACTED"))
        XCTAssertTrue(contents.contains("[Network]"))
        XCTAssertTrue(contents.contains("[Native]"))

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: logger.fileURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLogNeverExceedsConfiguredLimit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = try SupportLog(
            configuration: .init(
                directoryURL: directory,
                maximumFileSize: 96,
                retainedFileCount: 10
            ),
            now: { Date(timeIntervalSince1970: 0) },
            identifier: "limit"
        )

        logger.record(source: "Test", level: .info, message: String(repeating: "x", count: 1_000))
        logger.record(source: "Test", level: .critical, message: "must not exceed the cap")
        logger.flush()

        let values = try logger.fileURL.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(try XCTUnwrap(values.fileSize), 96)
        let contents = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("Log size limit reached!"))
    }

    func testRetainsOnlyNewestConfiguredLogFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for index in 0..<3 {
            let url = directory.appendingPathComponent("Umbra-old-\(index).log")
            try Data("old \(index)".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: url.path
            )
        }

        let logger = try SupportLog(
            configuration: .init(
                directoryURL: directory,
                maximumFileSize: 1024,
                retainedFileCount: 2
            ),
            now: { Date(timeIntervalSince1970: 100) },
            identifier: "current"
        )
        let files = logger.availableLogFiles()

        XCTAssertEqual(files.count, 2)
        let currentPath = logger.fileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(files.contains { $0.resolvingSymlinksInPath().path == currentPath })
        XCTAssertTrue(files.contains { $0.lastPathComponent == "Umbra-old-2.log" })
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
    }
}
