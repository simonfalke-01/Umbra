import Foundation
import XCTest
@testable import UmbraDiagnostics

final class UpdateManifestTests: XCTestCase {
    private let runtime = UpdateRuntimeIdentity(
        platform: .macOS,
        architecture: .arm64,
        applicationVersion: DottedVersion(parsing: "1.4")!,
        kernelVersion: DottedVersion(parsing: "23.6.0")!
    )

    func testDottedVersionsCompareMissingComponentsAsZero() {
        XCTAssertEqual(DottedVersion(parsing: "1.2"), DottedVersion(parsing: "1.2.0.0"))
        XCTAssertLessThan(DottedVersion(parsing: "1.2.9")!, DottedVersion(parsing: "1.3")!)
        XCTAssertNil(DottedVersion(parsing: "1.2-beta"))
    }

    func testSelectsNewestPlatformArchitectureAndKernelCompatibleEntry() throws {
        let checker = UpdateManifestChecker(
            configuration: .init(manifestURL: URL(string: "https://updates.example/umbra.json")!),
            runtime: runtime
        )
        let data = Data(
            """
            [
              {"platform":"windows","arch":"amd64","version":"99.0","browser_url":"https://example.com/windows"},
              {"platform":"osx","arch":"arm64","version":false,"browser_url":"https://example.com/malformed"},
              {"platform":"osx","arch":"x86_64","version":"9.0","browser_url":"https://example.com/x86"},
              {"platform":"osx","arch":"arm64","version":"3.0","kernel_version_at_least":"24.0","browser_url":"https://example.com/new-kernel"},
              {"platform":"osx","arch":"arm64","version":"1.5","browser_url":"https://example.com/1.5"},
              {"platform":"osx","arch":"arm64","version":"2.0.0","kernel_version_at_least":"23.0","browser_url":"https://example.com/2.0"}
            ]
            """.utf8
        )

        XCTAssertEqual(
            try checker.evaluate(manifestData: data),
            .updateAvailable(
                UpdateNotification(
                    version: DottedVersion(parsing: "2.0")!,
                    browserURL: URL(string: "https://example.com/2.0")!
                )
            )
        )
    }

    func testEqualOrOlderManifestIsUpToDate() throws {
        let checker = UpdateManifestChecker(
            configuration: .noPublishedChannel,
            runtime: runtime
        )
        let data = Data(
            """
            [{"platform":"osx","arch":"arm64","version":"1.4.0","browser_url":"https://example.com/download"}]
            """.utf8
        )
        XCTAssertEqual(
            try checker.evaluate(manifestData: data),
            .upToDate(latestVersion: DottedVersion(parsing: "1.4")!)
        )
    }

    func testDefaultConfigurationIsHonestlyDisabled() async throws {
        let checker = UpdateManifestChecker(runtime: runtime)
        let result = try await checker.check { _ in
            XCTFail("A disabled checker must not load a manifest")
            return Data()
        }
        XCTAssertEqual(
            result,
            .disabled(reason: "Umbra does not publish an update manifest yet.")
        )
    }

    func testRejectsInsecureManifestAndNotificationURLs() async throws {
        let insecureManifest = UpdateManifestChecker(
            configuration: .init(manifestURL: URL(string: "http://updates.example/umbra.json")!),
            runtime: runtime
        )
        do {
            _ = try await insecureManifest.check { _ in Data() }
            XCTFail("Expected insecure manifest URL to be rejected")
        } catch {
            XCTAssertEqual(
                error as? UpdateManifestError,
                .insecureManifestURL(URL(string: "http://updates.example/umbra.json")!)
            )
        }

        let insecureNotification = UpdateManifestChecker(runtime: runtime)
        let data = Data(
            """
            [{"platform":"osx","arch":"arm64","version":"2.0","browser_url":"http://example.com/download"}]
            """.utf8
        )
        XCTAssertThrowsError(try insecureNotification.evaluate(manifestData: data)) { error in
            XCTAssertEqual(
                error as? UpdateManifestError,
                .insecureBrowserURL(URL(string: "http://example.com/download")!)
            )
        }
    }
}
