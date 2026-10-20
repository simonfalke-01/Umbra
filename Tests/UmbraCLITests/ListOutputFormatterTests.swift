import XCTest
@testable import UmbraCLI
import UmbraCore

final class ListOutputFormatterTests: XCTestCase {
    private let applications = [
        StreamApplication(
            id: 17,
            name: "Game, \"Deluxe\"",
            hdrSupported: true,
            isAppCollectorGame: false,
            isHidden: false,
            supportsDirectLaunch: true
        ),
        StreamApplication(
            id: 42,
            name: "Desktop",
            hdrSupported: false,
            isAppCollectorGame: true,
            isHidden: true,
            supportsDirectLaunch: false
        ),
    ]

    func testPlainListGoldenFormatting() throws {
        XCTAssertEqual(
            CLIListOutputFormatter.format(
                applications: applications,
                command: ListAppsCommand(host: "host")
            ),
            """
            Game, "Deluxe"
            Desktop

            """
        )
    }

    func testCSVListGoldenFormattingAndEscaping() throws {
        let output = CLIListOutputFormatter.format(
            applications: applications,
            command: ListAppsCommand(host: "host", csv: true),
            boxArtURLs: [
                17: "https://example.test/art,17.png",
                42: "https://example.test/\"desktop\".png",
            ]
        )

        XCTAssertEqual(
            output,
            #"""
            Name, ID, HDR Support, App Collection Game, Hidden, Direct Launch, Boxart URL
            "Game, ""Deluxe""",17,true,false,false,true,"https://example.test/art,17.png"
            "Desktop",42,false,true,true,false,"https://example.test/""desktop"".png"

            """#
        )
    }

    func testEmptyFormatsAreDeterministic() throws {
        XCTAssertEqual(
            CLIListOutputFormatter.format(
                applications: [],
                command: ListAppsCommand(host: "host")
            ),
            ""
        )
        XCTAssertEqual(
            CLIListOutputFormatter.format(
                applications: [],
                command: ListAppsCommand(host: "host", csv: true)
            ),
            CLIListOutputFormatter.csvHeader + "\n"
        )
    }

    func testVerboseProgressGoldenFormatting() throws {
        let verbose = ListAppsCommand(host: "host", verbose: true)
        XCTAssertEqual(
            CLIListOutputFormatter.verboseMessage(for: .establishingConnection, command: verbose),
            "Establishing connection to PC...\n"
        )
        XCTAssertEqual(
            CLIListOutputFormatter.verboseMessage(for: .loadingApplications, command: verbose),
            "Loading app list...\n"
        )

        let quiet = ListAppsCommand(host: "host")
        XCTAssertEqual(
            CLIListOutputFormatter.verboseMessage(for: .establishingConnection, command: quiet),
            ""
        )
    }

    func testExecutionResultFactoriesPreserveGameStreamExitContracts() throws {
        XCTAssertEqual(CLIExecutionResult.success("ok\n").exitCode, 0)
        XCTAssertEqual(CLIExecutionResult.failure("failed\n").exitCode, 1)
        XCTAssertEqual(CLIExecutionResult.hostUnavailable("offline\n").exitCode, -1)
        XCTAssertEqual(CLIExecutionResult.success("ok\n").standardOutput, "ok\n")
        XCTAssertEqual(CLIExecutionResult.failure("failed\n").standardError, "failed\n")
    }
}
