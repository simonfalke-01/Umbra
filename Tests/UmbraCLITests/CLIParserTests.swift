import XCTest
@testable import UmbraCLI
import UmbraCore

final class CLIParserTests: XCTestCase {
    private let parser = UmbraCLIParser(applicationName: "umbra", version: "9.8.7")

    func testNoArgumentsRequestsNormalApplicationLaunch() throws {
        let parsed = parser.parse(arguments: [])

        XCTAssertEqual(parsed, .ready(command: .launchApplication, warnings: []))
    }

    func testProcessArgumentsDropsExecutablePath() throws {
        let parsed = parser.parseProcessArguments(["/Applications/Umbra.app/Contents/MacOS/Umbra", "quit", "studio"])

        XCTAssertEqual(
            parsed,
            .ready(command: .quit(QuitHostCommand(host: "studio")), warnings: [])
        )
    }

    func testListSupportsSingleDashLongOptions() throws {
        let parsed = parser.parse(arguments: ["-csv", "-verbose", "LiViNg-RoOm", "list"])

        XCTAssertEqual(
            parsed,
            .terminal(
                .failure(
                    "Invalid action: LiViNg-RoOm\n\n" +
                        CLIHelp.text(for: .global, applicationName: "umbra") + "\n"
                )
            )
        )

        let valid = parser.parse(arguments: ["-csv", "-verbose", "list", "LiViNg-RoOm"])
        XCTAssertEqual(
            valid,
            .ready(
                command: .list(
                    ListAppsCommand(host: "LiViNg-RoOm", csv: true, verbose: true)
                ),
                warnings: []
            )
        )
    }

    func testPairAcceptsOptionBeforeActionAndValidatesPIN() throws {
        XCTAssertEqual(
            parser.parse(arguments: ["--pin", "0123", "pair", "10.0.0.2"]),
            .ready(
                command: .pair(PairHostCommand(host: "10.0.0.2", pin: "0123")),
                warnings: []
            )
        )

        assertUsageError(
            parser.parse(arguments: ["pair", "host", "--pin", "12ab"]),
            message: "PIN must be 4 digits",
            topic: .pair
        )
        assertUsageError(
            parser.parse(arguments: ["pair", "host", "--pin", "12345"]),
            message: "PIN must be 4 digits",
            topic: .pair
        )
    }

    func testQuitCommand() throws {
        XCTAssertEqual(
            parser.parse(arguments: ["QuIt", "host-uuid"]),
            .ready(command: .quit(QuitHostCommand(host: "host-uuid")), warnings: [])
        )
    }

    func testRecoverStorageParsesWithoutOperandsAndDocumentsConsequences() throws {
        XCTAssertEqual(
            parser.parse(arguments: ["recover-storage"]),
            .ready(command: .recoverStorage, warnings: [])
        )
        assertUsageError(
            parser.parse(arguments: ["recover-storage", "unexpected"]),
            message: "Unexpected argument: unexpected",
            topic: .recoverStorage
        )
        assertUsageError(
            parser.parse(arguments: ["recover-storage", "--verbose"]),
            message: "Unknown options: verbose",
            topic: .recoverStorage
        )

        let help = CLIHelp.text(for: .recoverStorage, applicationName: "umbra")
        XCTAssertTrue(help.contains("entire Umbra Application Support directory"))
        XCTAssertTrue(help.contains("requires hosts to be paired again"))
        XCTAssertTrue(help.contains("exact backup path"))
    }

    func testStreamParsesCompleteGameStreamOptionSurface() throws {
        let parsed = parser.parse(arguments: [
            "stream",
            "--resolution=3440X1440",
            "-fps", "120",
            "--bitrate", "200000",
            "-packet-size=1400",
            "--display-mode", "BORDERLESS",
            "-audio-config", "7.1-SURROUND",
            "--no-vsync",
            "-no-multi-controller",
            "--quit-after",
            "-absolute-mouse",
            "--mouse-buttons-swap",
            "-touchscreen-trackpad",
            "--no-game-optimization",
            "-audio-on-host",
            "--frame-pacing",
            "-mute-on-focus-loss",
            "--background-gamepad",
            "-reverse-scroll-direction",
            "--swap-gamepad-buttons",
            "--quit-running-app",
            "-no-keep-awake",
            "--performance-overlay",
            "-hdr",
            "-capture-system-keys", "ALWAYS",
            "--video-codec", "hevc",
            "-video-decoder", "HARDWARE",
            "gaming-pc",
            "Steam Big Picture",
        ])

        guard case let .ready(.stream(command), warnings) = parsed else {
            return XCTFail("Expected a ready stream command, got \(parsed)")
        }
        XCTAssertEqual(command.host, "gaming-pc")
        XCTAssertEqual(command.applicationName, "Steam Big Picture")
        XCTAssertTrue(warnings.isEmpty)

        let preferences = command.preferences
        XCTAssertEqual(preferences.width, 3_440)
        XCTAssertEqual(preferences.height, 1_440)
        XCTAssertEqual(preferences.fps, 120)
        XCTAssertEqual(preferences.bitrateKbps, 200_000)
        XCTAssertFalse(preferences.autoAdjustBitrate)
        XCTAssertTrue(preferences.unlockBitrate)
        XCTAssertEqual(preferences.packetSize, 1_400)
        XCTAssertEqual(preferences.windowMode, .fullscreenDesktop)
        XCTAssertEqual(preferences.audioConfiguration, .surround71)
        XCTAssertFalse(preferences.enableVSync)
        XCTAssertFalse(preferences.multiController)
        XCTAssertTrue(preferences.quitAppAfter)
        XCTAssertTrue(preferences.absoluteMouseMode)
        XCTAssertTrue(preferences.swapMouseButtons)
        XCTAssertFalse(preferences.absoluteTouchMode)
        XCTAssertFalse(preferences.gameOptimizations)
        XCTAssertTrue(preferences.playAudioOnHost)
        XCTAssertTrue(preferences.framePacing)
        XCTAssertTrue(preferences.muteOnFocusLoss)
        XCTAssertTrue(preferences.backgroundGamepad)
        XCTAssertTrue(preferences.reverseScrollDirection)
        XCTAssertTrue(preferences.swapFaceButtons)
        XCTAssertTrue(command.quitRunningApplication)
        XCTAssertFalse(preferences.keepAwake)
        XCTAssertTrue(preferences.showPerformanceOverlay)
        XCTAssertTrue(preferences.enableHDR)
        XCTAssertFalse(preferences.enableYUV444)
        XCTAssertEqual(preferences.captureSystemKeysMode, .always)
        XCTAssertEqual(preferences.videoCodecPreference, .hevc)
        XCTAssertEqual(preferences.videoDecoderPreference, .hardware)
    }

    func testStreamParsesExplicitLSPCompetitionAndHighInputRates() {
        let parsed = parser.parse(arguments: [
            "stream", "--protocol", "lsp", "--lsp-profile", "competition",
            "--lsp-capacity-mbps", "2500",
            "--lsp-pointer-rate", "16000",
            "--lsp-controller-rate", "2000",
            "--lsp-sensor-rate", "4000",
            "--lsp-reconciliation-rate", "1000",
            "host", "app",
        ])
        guard case let .ready(.stream(command), _) = parsed else {
            return XCTFail("Expected an LSP-configured stream command")
        }
        XCTAssertEqual(command.preferences.lspNetworkProfile, .competitionLAN)
        XCTAssertEqual(command.preferences.lspCompetitionCapacityMbps, 2_500)
        XCTAssertEqual(command.preferences.lspPointerRate, 16_000)
        XCTAssertEqual(command.preferences.lspControllerRate, 2_000)
        XCTAssertEqual(command.preferences.lspSensorRate, 4_000)
        XCTAssertEqual(command.preferences.lspReconciliationRate, 1_000)

        assertUsageError(
            parser.parse(arguments: ["stream", "--protocol", "lsp", "--lsp-profile", "competition", "host", "app"]),
            message: "--lsp-profile competition requires --lsp-capacity-mbps",
            topic: .stream
        )
    }

    func testResolutionPresetsAndLastOccurrenceWins() throws {
        let presets: [(String, Int, Int)] = [
            ("720", 1_280, 720),
            ("1080", 1_920, 1_080),
            ("1440", 2_560, 1_440),
            ("4K", 3_840, 2_160),
        ]

        for (option, width, height) in presets {
            let parsed = parser.parse(arguments: ["stream", "--\(option)", "host", "app"])
            guard case let .ready(.stream(command), _) = parsed else {
                return XCTFail("Expected preset \(option) to parse")
            }
            XCTAssertEqual(command.preferences.width, width)
            XCTAssertEqual(command.preferences.height, height)
        }

        let parsed = parser.parse(arguments: [
            "stream", "--720", "--4K", "--resolution", "1600x900", "host", "app",
        ])
        guard case let .ready(.stream(command), _) = parsed else {
            return XCTFail("Expected stream command")
        }
        XCTAssertEqual(command.preferences.width, 1_600)
        XCTAssertEqual(command.preferences.height, 900)
    }

    func testBooleanToggleLastOccurrenceWins() throws {
        let parsed = parser.parse(arguments: [
            "stream", "--no-vsync", "--vsync", "--hdr", "--no-hdr", "host", "app",
        ])
        guard case let .ready(.stream(command), _) = parsed else {
            return XCTFail("Expected stream command")
        }
        XCTAssertTrue(command.preferences.enableVSync)
        XCTAssertFalse(command.preferences.enableHDR)
    }

    func testDerivedBitrateUsesFinalResolutionAndFPS() throws {
        let parsed = parser.parse(arguments: [
            "stream", "--1080", "--fps", "60", "host", "app",
        ])
        guard case let .ready(.stream(command), _) = parsed else {
            return XCTFail("Expected stream command")
        }

        XCTAssertEqual(
            command.preferences.bitrateKbps,
            StreamingPreferences.defaultBitrateKbps(
                width: 1_920,
                height: 1_080,
                fps: 60,
                yuv444: false
            )
        )
    }

    func testOutOfRecommendedRangeFPSAndBitrateProduceWarnings() throws {
        let parsed = parser.parse(arguments: [
            "stream", "--fps", "481", "--bitrate", "500001", "host", "app",
        ])
        guard case let .ready(.stream(command), warnings) = parsed else {
            return XCTFail("Expected stream command")
        }

        XCTAssertEqual(command.preferences.fps, 481)
        XCTAssertEqual(command.preferences.bitrateKbps, 500_001)
        XCTAssertEqual(warnings, [
            "FPS is out of the supported range (10 - 480 FPS). Performance may suffer!",
            "Bitrate is out of the supported range (500 - 500000 Kbps). Performance may suffer!",
        ])
    }

    func testStreamNumericValidationErrorsAreStable() throws {
        assertUsageError(
            parser.parse(arguments: ["stream", "--fps", "sixty", "host", "app"]),
            message: "Invalid fps value: sixty",
            topic: .stream
        )
        assertUsageError(
            parser.parse(arguments: ["stream", "--bitrate", "fast", "host", "app"]),
            message: "Invalid bitrate value: fast",
            topic: .stream
        )
        assertUsageError(
            parser.parse(arguments: ["stream", "--packet-size", "1023", "host", "app"]),
            message: "Packet size must be at least 1024 bytes",
            topic: .stream
        )
        assertUsageError(
            parser.parse(arguments: ["stream", "--resolution", "1920-1080", "host", "app"]),
            message: "Invalid resolution format: 1920-1080",
            topic: .stream
        )
    }

    func testStreamChoiceValidationErrorsAreCaseInsensitiveAndStable() throws {
        let invalidChoices = [
            ("display-mode", "floating"),
            ("audio-config", "mono"),
            ("capture-system-keys", "sometimes"),
            ("video-codec", "vp9"),
            ("video-decoder", "magic"),
        ]

        for (name, value) in invalidChoices {
            assertUsageError(
                parser.parse(arguments: ["stream", "--\(name)", value, "host", "app"]),
                message: "Invalid \(name) choice: \(value)",
                topic: .stream
            )
        }
    }

    func testMissingOperandsUnknownOptionsAndExtraArgumentsAreErrors() throws {
        assertUsageError(
            parser.parse(arguments: ["list"]),
            message: "Host not provided",
            topic: .list
        )
        assertUsageError(
            parser.parse(arguments: ["stream", "host"]),
            message: "App not provided",
            topic: .stream
        )
        assertUsageError(
            parser.parse(arguments: ["quit", "host", "extra"]),
            message: "Unexpected argument: extra",
            topic: .quit
        )
        assertUsageError(
            parser.parse(arguments: ["list", "--bogus", "host"]),
            message: "Unknown options: bogus",
            topic: .list
        )
        assertUsageError(
            parser.parse(arguments: ["list", "--hdr", "host"]),
            message: "Unknown options: hdr",
            topic: .list
        )
        assertUsageError(
            parser.parse(arguments: ["frobnicate"]),
            message: "Invalid action: frobnicate",
            topic: .global
        )
    }

    func testMissingOptionValueDoesNotConsumeFollowingRecognizedOption() throws {
        assertUsageError(
            parser.parse(arguments: ["stream", "host", "app", "--fps", "--hdr"]),
            message: "Missing value after --fps",
            topic: .stream
        )
    }

    func testDoubleDashEndsOptionParsing() throws {
        XCTAssertEqual(
            parser.parse(arguments: ["quit", "--", "-workstation"]),
            .ready(command: .quit(QuitHostCommand(host: "-workstation")), warnings: [])
        )
    }

    func testHelpAndVersionReturnSuccessfulTerminalResults() throws {
        XCTAssertEqual(
            parser.parse(arguments: ["--help"]),
            .terminal(
                .success(CLIHelp.text(for: .global, applicationName: "umbra") + "\n")
            )
        )
        XCTAssertEqual(
            parser.parse(arguments: ["stream", "-h"]),
            .terminal(
                .success(CLIHelp.text(for: .stream, applicationName: "umbra") + "\n")
            )
        )
        XCTAssertEqual(
            parser.parse(arguments: ["list", "--version"]),
            .terminal(.success("Umbra 9.8.7\n"))
        )
    }

    func testGlobalHelpGoldenText() throws {
        let expected = """
        Usage: umbra [options] <action>

        Starts Umbra normally if no arguments are given.

        Available actions:
          list            List the available apps on a host
          quit            Quit the currently running app
          stream          Start streaming an app
          pair            Pair a new host
          attach          Reattach an existing LSP stream
          stop            Stop an owned LSP stream
          telemetry       Print an LSP telemetry snapshot
          recover-storage Preserve unreadable storage and reset Umbra on next launch

        Options:
          -h, --help      Display this help text
          -v, --version   Display version information

        Long options may be written with one or two dashes.
        See 'umbra <action> --help' for help for a specific action.
        """

        XCTAssertEqual(CLIHelp.text(for: .global, applicationName: "umbra"), expected)
    }

    func testUsageErrorGoldenResultContract() throws {
        let parsed = parser.parse(arguments: ["list", "--bogus", "host"])
        let expectedError =
            "Unknown options: bogus\n\n" +
            CLIHelp.text(for: .list, applicationName: "umbra") + "\n"

        XCTAssertEqual(
            parsed,
            .terminal(
                CLIExecutionResult(
                    exitCode: CLIExitCode.failure.rawValue,
                    standardError: expectedError
                )
            )
        )
        XCTAssertFalse(try XCTUnwrap(parsed.terminalResult).succeeded)
    }

    private func assertUsageError(
        _ result: CLIParseResult,
        message: String,
        topic: CLIHelpTopic,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            result,
            .terminal(
                .failure(
                    message + "\n\n" +
                        CLIHelp.text(for: topic, applicationName: "umbra") + "\n"
                )
            ),
            file: file,
            line: line
        )
    }
}

extension CLIParserTests {
    func testLSPStreamRequiresExplicitProtocolAndCarriesNativeOptions() throws {
        let hostID = UUID()
        let result = parser.parse(arguments: [
            "stream", "lumen", "Desktop", "--protocol", "lsp",
            "--lsp-host-id", hostID.uuidString,
            "--lsp-profile", "competition", "--lsp-capacity-mbps", "2500",
            "--lsp-pointer-rate", "8000", "--lsp-controller-rate", "2000",
            "--lsp-sensor-rate", "4000", "--lsp-reconciliation-rate", "1000",
            "--lsp-microphone", "required", "--lsp-telemetry",
        ])
        guard case .ready(.stream(let command), []) = result else {
            return XCTFail("Expected a validated LSP stream command")
        }
        XCTAssertEqual(command.streamingProtocol, .lsp)
        XCTAssertEqual(command.lsp.hostID, hostID)
        XCTAssertEqual(command.lsp.microphone, .required)
        XCTAssertTrue(command.lsp.permissions.contains(.microphone))
        XCTAssertTrue(command.lsp.emitTelemetry)
        XCTAssertEqual(command.preferences.lspCompetitionCapacityMbps, 2_500)
        XCTAssertEqual(command.preferences.lspPointerRate, 8_000)
    }

    func testLSPFlagCannotSilentlySelectOrDowngradeLegacy() {
        let result = parser.parse(arguments: [
            "stream", "lumen", "Desktop", "--lsp-pointer-rate", "8000",
        ])
        guard case .terminal(let terminal) = result else { return XCTFail("Expected usage failure") }
        XCTAssertEqual(terminal.exitCode, CLIExitCode.failure.rawValue)
        XCTAssertTrue(terminal.standardError.contains("Invalid protocol or LSP option"))
    }

    func testLSPPairingRejectsCommandLinePINButLegacyPairingKeepsFourDigits() {
        guard case .terminal(let lsp) = parser.parse(arguments: [
            "pair", "lumen", "--protocol", "lsp", "--pin", "123456",
        ]) else { return XCTFail("Expected LSP PIN rejection") }
        XCTAssertTrue(lsp.standardError.contains("generates a six-digit PIN"))

        XCTAssertEqual(
            parser.parse(arguments: ["pair", "lumen", "--pin", "1234"]).command,
            .pair(PairHostCommand(host: "lumen", pin: "1234"))
        )
    }

    func testAttachStopAndTelemetryAreExplicitLSPCommands() {
        guard case .terminal(let missingProtocol) = parser.parse(arguments: ["attach", "lumen"]) else {
            return XCTFail("Attach must require explicit LSP selection")
        }
        XCTAssertTrue(missingProtocol.standardError.contains("requires --protocol lsp"))
        XCTAssertEqual(
            parser.parse(arguments: ["attach", "lumen", "--protocol", "lsp"]).command,
            .attach(AttachHostCommand(host: "lumen"))
        )
        XCTAssertEqual(
            parser.parse(arguments: ["stop", "lumen", "--protocol", "lsp"]).command,
            .stop(StopHostCommand(host: "lumen"))
        )
        XCTAssertEqual(
            parser.parse(arguments: ["telemetry", "lumen", "--protocol", "lsp"]).command,
            .telemetry(TelemetryHostCommand(host: "lumen"))
        )
    }
}
