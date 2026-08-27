import UmbraCore

/// Parses Moonlight-compatible arguments without performing I/O or terminating the process.
public struct UmbraCLIParser: Sendable {
    public var applicationName: String
    public var version: String
    public var defaultStreamingPreferences: StreamingPreferences

    public init(
        applicationName: String = "umbra",
        version: String = "0.1.0",
        defaultStreamingPreferences: StreamingPreferences = .default
    ) {
        self.applicationName = applicationName
        self.version = version
        self.defaultStreamingPreferences = defaultStreamingPreferences
    }

    /// Parses arguments that do not include the executable path.
    public func parse(arguments: [String]) -> CLIParseResult {
        let tokenized = tokenize(arguments)
        let topic = helpTopic(for: tokenized.positionals.first) ?? .global

        if let error = tokenized.errors.first {
            return usageError(error, topic: topic)
        }
        if !tokenized.unknownOptions.isEmpty {
            return usageError(
                "Unknown options: \(tokenized.unknownOptions.joined(separator: ", "))",
                topic: topic
            )
        }

        guard let action = tokenized.positionals.first else {
            if tokenized.hasOption("help") {
                return helpResult(for: .global)
            }
            if tokenized.hasOption("version") {
                return versionResult()
            }
            return .ready(command: .launchApplication, warnings: [])
        }

        guard let commandTopic = helpTopic(for: action) else {
            return usageError("Invalid action: \(action)", topic: .global)
        }

        let disallowed = tokenized.options
            .map(\.name)
            .filter { !allowedOptions(for: commandTopic).contains($0) }
        if !disallowed.isEmpty {
            return usageError(
                "Unknown options: \(uniqued(disallowed).joined(separator: ", "))",
                topic: commandTopic
            )
        }

        if tokenized.hasOption("help") {
            return helpResult(for: commandTopic)
        }
        if tokenized.hasOption("version") {
            return versionResult()
        }

        let operands = Array(tokenized.positionals.dropFirst())
        switch commandTopic {
        case .global:
            return usageError("Invalid action: \(action)", topic: .global)
        case .recoverStorage:
            return parseRecoverStorage(operands: operands)
        case .list:
            return parseList(operands: operands, tokenized: tokenized)
        case .pair:
            return parsePair(operands: operands, tokenized: tokenized)
        case .stream:
            return parseStream(operands: operands, tokenized: tokenized)
        case .quit:
            return parseQuit(operands: operands)
        }
    }

    /// Parses `CommandLine.arguments`, dropping the executable path before parsing.
    public func parseProcessArguments(_ processArguments: [String]) -> CLIParseResult {
        parse(arguments: Array(processArguments.dropFirst()))
    }
}

private extension UmbraCLIParser {
    enum OptionKind {
        case flag
        case value
    }

    struct OptionDescriptor {
        var name: String
        var kind: OptionKind
    }

    struct ParsedOption: Equatable {
        var name: String
        var value: String?
    }

    struct TokenizedArguments {
        var options: [ParsedOption] = []
        var positionals: [String] = []
        var unknownOptions: [String] = []
        var errors: [String] = []

        func hasOption(_ name: String) -> Bool {
            options.contains { $0.name == name }
        }

        func lastOption(_ name: String) -> ParsedOption? {
            options.last { $0.name == name }
        }

        func lastOption(named names: Set<String>) -> ParsedOption? {
            options.last { names.contains($0.name) }
        }
    }

    static var optionDescriptors: [String: OptionDescriptor] {
        var descriptors: [String: OptionDescriptor] = [:]

        func flag(_ names: String...) {
            for name in names {
                descriptors[name] = OptionDescriptor(name: name, kind: .flag)
            }
        }

        func value(_ names: String...) {
            for name in names {
                descriptors[name] = OptionDescriptor(name: name, kind: .value)
            }
        }

        flag(
            "help", "version", "csv", "verbose", "720", "1080", "1440", "4K",
            "quit-running-app"
        )
        value(
            "pin", "resolution", "fps", "bitrate", "packet-size", "display-mode",
            "audio-config", "capture-system-keys", "video-codec", "video-decoder"
        )

        for toggle in Self.toggleOptionNames {
            flag(toggle, "no-\(toggle)")
        }
        return descriptors
    }

    static let toggleOptionNames: [String] = [
        "vsync",
        "multi-controller",
        "quit-after",
        "absolute-mouse",
        "mouse-buttons-swap",
        "touchscreen-trackpad",
        "game-optimization",
        "audio-on-host",
        "frame-pacing",
        "mute-on-focus-loss",
        "background-gamepad",
        "reverse-scroll-direction",
        "swap-gamepad-buttons",
        "keep-awake",
        "performance-overlay",
        "hdr",
    ]

    func tokenize(_ arguments: [String]) -> TokenizedArguments {
        var result = TokenizedArguments()
        var index = 0
        var optionsEnded = false

        while index < arguments.count {
            let argument = arguments[index]
            if optionsEnded || argument == "-" || !argument.hasPrefix("-") {
                result.positionals.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                optionsEnded = true
                index += 1
                continue
            }

            let dashCount = argument.hasPrefix("--") ? 2 : 1
            let optionText = String(argument.dropFirst(dashCount))
            let pieces = optionText.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let suppliedName = String(pieces[0])
            let attachedValue = pieces.count == 2 ? String(pieces[1]) : nil
            let resolvedName: String
            switch suppliedName {
            case "h": resolvedName = "help"
            case "v": resolvedName = "version"
            default: resolvedName = suppliedName
            }

            guard let descriptor = Self.optionDescriptors[resolvedName] else {
                result.unknownOptions.append(suppliedName)
                index += 1
                continue
            }

            switch descriptor.kind {
            case .flag:
                if attachedValue != nil {
                    result.errors.append("Option --\(resolvedName) does not take a value")
                } else {
                    result.options.append(
                        ParsedOption(name: descriptor.name, value: nil)
                    )
                }
            case .value:
                if let attachedValue {
                    if attachedValue.isEmpty {
                        result.errors.append("Missing value after --\(resolvedName)")
                    } else {
                        result.options.append(
                            ParsedOption(name: descriptor.name, value: attachedValue)
                        )
                    }
                } else if index + 1 < arguments.count,
                          !isRecognizedOption(arguments[index + 1]) {
                    index += 1
                    result.options.append(
                        ParsedOption(name: descriptor.name, value: arguments[index])
                    )
                } else {
                    result.errors.append("Missing value after --\(resolvedName)")
                }
            }

            index += 1
        }
        return result
    }

    func isRecognizedOption(_ argument: String) -> Bool {
        guard argument != "-", argument.hasPrefix("-") else { return false }
        if argument == "--" { return true }
        let dashCount = argument.hasPrefix("--") ? 2 : 1
        let body = argument.dropFirst(dashCount)
        let suppliedName = body.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
        let resolvedName: String
        switch suppliedName {
        case "h": resolvedName = "help"
        case "v": resolvedName = "version"
        default: resolvedName = suppliedName
        }
        return Self.optionDescriptors[resolvedName] != nil
    }

    func allowedOptions(for topic: CLIHelpTopic) -> Set<String> {
        let common: Set<String> = ["help", "version"]
        switch topic {
        case .global:
            return common
        case .recoverStorage:
            return common
        case .list:
            return common.union(["csv", "verbose"])
        case .pair:
            return common.union(["pin"])
        case .quit:
            return common
        case .stream:
            var stream = Set([
                "720", "1080", "1440", "4K", "resolution", "fps", "bitrate",
                "packet-size", "display-mode", "audio-config", "capture-system-keys",
                "video-codec", "video-decoder", "quit-running-app",
            ])
            for toggle in Self.toggleOptionNames {
                stream.insert(toggle)
                stream.insert("no-\(toggle)")
            }
            return common.union(stream)
        }
    }

    func helpTopic(for action: String?) -> CLIHelpTopic? {
        guard let action else { return nil }
        switch action.lowercased() {
        case "recover-storage": return .recoverStorage
        case "list": return .list
        case "pair": return .pair
        case "stream": return .stream
        case "quit": return .quit
        default: return nil
        }
    }

    func parseRecoverStorage(operands: [String]) -> CLIParseResult {
        guard operands.isEmpty else {
            return usageError("Unexpected argument: \(operands[0])", topic: .recoverStorage)
        }
        return .ready(command: .recoverStorage, warnings: [])
    }

    func parseList(operands: [String], tokenized: TokenizedArguments) -> CLIParseResult {
        guard let host = operands.first, !host.isEmpty else {
            return usageError("Host not provided", topic: .list)
        }
        guard operands.count == 1 else {
            return usageError("Unexpected argument: \(operands[1])", topic: .list)
        }
        return .ready(
            command: .list(
                ListAppsCommand(
                    host: host,
                    csv: tokenized.hasOption("csv"),
                    verbose: tokenized.hasOption("verbose")
                )
            ),
            warnings: []
        )
    }

    func parsePair(operands: [String], tokenized: TokenizedArguments) -> CLIParseResult {
        guard let host = operands.first, !host.isEmpty else {
            return usageError("Host not provided", topic: .pair)
        }
        guard operands.count == 1 else {
            return usageError("Unexpected argument: \(operands[1])", topic: .pair)
        }

        let pin = tokenized.lastOption("pin")?.value
        if let pin, !isFourDigitPIN(pin) {
            return usageError("PIN must be 4 digits", topic: .pair)
        }
        return .ready(command: .pair(PairHostCommand(host: host, pin: pin)), warnings: [])
    }

    func parseQuit(operands: [String]) -> CLIParseResult {
        guard let host = operands.first, !host.isEmpty else {
            return usageError("Host not provided", topic: .quit)
        }
        guard operands.count == 1 else {
            return usageError("Unexpected argument: \(operands[1])", topic: .quit)
        }
        return .ready(command: .quit(QuitHostCommand(host: host)), warnings: [])
    }

    func parseStream(operands: [String], tokenized: TokenizedArguments) -> CLIParseResult {
        guard let host = operands.first, !host.isEmpty else {
            return usageError("Host not provided", topic: .stream)
        }
        guard operands.count >= 2, !operands[1].isEmpty else {
            return usageError("App not provided", topic: .stream)
        }
        guard operands.count == 2 else {
            return usageError("Unexpected argument: \(operands[2])", topic: .stream)
        }

        var preferences = defaultStreamingPreferences
        var warnings: [String] = []
        var shouldRecalculateBitrate = false

        let resolutionNames: Set<String> = ["720", "1080", "1440", "4K", "resolution"]
        if let resolutionOption = tokenized.lastOption(named: resolutionNames) {
            shouldRecalculateBitrate = true
            switch resolutionOption.name {
            case "720":
                (preferences.width, preferences.height) = (1_280, 720)
            case "1080":
                (preferences.width, preferences.height) = (1_920, 1_080)
            case "1440":
                (preferences.width, preferences.height) = (2_560, 1_440)
            case "4K":
                (preferences.width, preferences.height) = (3_840, 2_160)
            case "resolution":
                guard let value = resolutionOption.value,
                      let resolution = parseResolution(value) else {
                    return usageError(
                        "Invalid resolution format: \(resolutionOption.value ?? "")",
                        topic: .stream
                    )
                }
                (preferences.width, preferences.height) = resolution
            default:
                break
            }
        }

        if let option = tokenized.lastOption("fps") {
            guard let value = parseInteger(option) else {
                return usageError("Invalid fps value: \(option.value ?? "")", topic: .stream)
            }
            preferences.fps = value
            shouldRecalculateBitrate = true
            if !(10...480).contains(value) {
                warnings.append(
                    "FPS is out of the supported range (10 - 480 FPS). Performance may suffer!"
                )
            }
        }

        if let option = tokenized.lastOption("packet-size") {
            guard let value = parseInteger(option) else {
                return usageError(
                    "Invalid packet-size value: \(option.value ?? "")",
                    topic: .stream
                )
            }
            guard value >= 1_024 else {
                return usageError("Packet size must be at least 1024 bytes", topic: .stream)
            }
            preferences.packetSize = value
        }

        if let option = tokenized.lastOption("display-mode") {
            guard let value = option.value else {
                return usageError("Missing value after --display-mode", topic: .stream)
            }
            switch value.lowercased() {
            case "fullscreen": preferences.windowMode = .fullscreen
            case "windowed": preferences.windowMode = .windowed
            case "borderless": preferences.windowMode = .fullscreenDesktop
            default:
                return invalidChoice(name: "display-mode", value: value)
            }
        }

        if let option = tokenized.lastOption("audio-config") {
            guard let value = option.value else {
                return usageError("Missing value after --audio-config", topic: .stream)
            }
            switch value.lowercased() {
            case "stereo": preferences.audioConfiguration = .stereo
            case "5.1-surround": preferences.audioConfiguration = .surround51
            case "7.1-surround": preferences.audioConfiguration = .surround71
            default:
                return invalidChoice(name: "audio-config", value: value)
            }
        }

        preferences.enableVSync = toggle("vsync", in: tokenized, default: preferences.enableVSync)
        preferences.multiController = toggle(
            "multi-controller", in: tokenized, default: preferences.multiController
        )
        preferences.quitAppAfter = toggle(
            "quit-after", in: tokenized, default: preferences.quitAppAfter
        )
        preferences.absoluteMouseMode = toggle(
            "absolute-mouse", in: tokenized, default: preferences.absoluteMouseMode
        )
        preferences.swapMouseButtons = toggle(
            "mouse-buttons-swap", in: tokenized, default: preferences.swapMouseButtons
        )
        let trackpadMode = toggle(
            "touchscreen-trackpad", in: tokenized, default: !preferences.absoluteTouchMode
        )
        preferences.absoluteTouchMode = !trackpadMode
        preferences.gameOptimizations = toggle(
            "game-optimization", in: tokenized, default: preferences.gameOptimizations
        )
        preferences.playAudioOnHost = toggle(
            "audio-on-host", in: tokenized, default: preferences.playAudioOnHost
        )
        preferences.framePacing = toggle(
            "frame-pacing", in: tokenized, default: preferences.framePacing
        )
        preferences.muteOnFocusLoss = toggle(
            "mute-on-focus-loss", in: tokenized, default: preferences.muteOnFocusLoss
        )
        preferences.backgroundGamepad = toggle(
            "background-gamepad", in: tokenized, default: preferences.backgroundGamepad
        )
        preferences.reverseScrollDirection = toggle(
            "reverse-scroll-direction", in: tokenized, default: preferences.reverseScrollDirection
        )
        preferences.swapFaceButtons = toggle(
            "swap-gamepad-buttons", in: tokenized, default: preferences.swapFaceButtons
        )
        preferences.keepAwake = toggle(
            "keep-awake", in: tokenized, default: preferences.keepAwake
        )
        preferences.showPerformanceOverlay = toggle(
            "performance-overlay", in: tokenized, default: preferences.showPerformanceOverlay
        )
        preferences.enableHDR = toggle("hdr", in: tokenized, default: preferences.enableHDR)

        if let option = tokenized.lastOption("capture-system-keys") {
            guard let value = option.value else {
                return usageError("Missing value after --capture-system-keys", topic: .stream)
            }
            switch value.lowercased() {
            case "never": preferences.captureSystemKeysMode = .off
            case "fullscreen": preferences.captureSystemKeysMode = .fullscreen
            case "always": preferences.captureSystemKeysMode = .always
            default:
                return invalidChoice(name: "capture-system-keys", value: value)
            }
        }

        if let option = tokenized.lastOption("video-codec") {
            guard let value = option.value else {
                return usageError("Missing value after --video-codec", topic: .stream)
            }
            switch value.lowercased() {
            case "auto": preferences.videoCodecPreference = .automatic
            case "h.264": preferences.videoCodecPreference = .h264
            case "hevc": preferences.videoCodecPreference = .hevc
            case "av1": preferences.videoCodecPreference = .av1
            default:
                return invalidChoice(name: "video-codec", value: value)
            }
        }

        if let option = tokenized.lastOption("video-decoder") {
            guard let value = option.value else {
                return usageError("Missing value after --video-decoder", topic: .stream)
            }
            switch value.lowercased() {
            case "auto": preferences.videoDecoderPreference = .automatic
            case "software": preferences.videoDecoderPreference = .software
            case "hardware": preferences.videoDecoderPreference = .hardware
            default:
                return invalidChoice(name: "video-decoder", value: value)
            }
        }

        if let option = tokenized.lastOption("bitrate") {
            guard let value = parseInteger(option) else {
                return usageError("Invalid bitrate value: \(option.value ?? "")", topic: .stream)
            }
            preferences.bitrateKbps = value
            preferences.autoAdjustBitrate = false
            if value > 150_000 {
                preferences.unlockBitrate = true
            }
            if !(500...500_000).contains(value) {
                warnings.append(
                    "Bitrate is out of the supported range (500 - 500000 Kbps). Performance may suffer!"
                )
            }
        } else if shouldRecalculateBitrate {
            preferences.bitrateKbps = StreamingPreferences.defaultBitrateKbps(
                width: preferences.width,
                height: preferences.height,
                fps: preferences.exactFrameRate,
                yuv444: preferences.enableYUV444
            )
        }

        return .ready(
            command: .stream(
                StreamAppCommand(
                    host: host,
                    applicationName: operands[1],
                    preferences: preferences,
                    quitRunningApplication: tokenized.hasOption("quit-running-app")
                )
            ),
            warnings: warnings
        )
    }

    func toggle(_ name: String, in tokenized: TokenizedArguments, default defaultValue: Bool) -> Bool {
        guard let option = tokenized.lastOption(named: [name, "no-\(name)"]) else {
            return defaultValue
        }
        return option.name == name
    }

    func parseInteger(_ option: ParsedOption) -> Int? {
        guard let value = option.value, !value.isEmpty else { return nil }
        return Int(value)
    }

    func parseResolution(_ value: String) -> (Int, Int)? {
        let pieces = value.lowercased().split(
            separator: "x",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard pieces.count == 2,
              pieces[0].allSatisfy({ $0.isNumber }),
              pieces[1].allSatisfy({ $0.isNumber }),
              let width = Int(pieces[0]),
              let height = Int(pieces[1]) else {
            return nil
        }
        return (width, height)
    }

    func isFourDigitPIN(_ value: String) -> Bool {
        value.count == 4 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    func invalidChoice(name: String, value: String) -> CLIParseResult {
        usageError("Invalid \(name) choice: \(value)", topic: .stream)
    }

    func helpResult(for topic: CLIHelpTopic) -> CLIParseResult {
        .terminal(.success(CLIHelp.text(for: topic, applicationName: applicationName) + "\n"))
    }

    func versionResult() -> CLIParseResult {
        .terminal(.success("Umbra \(version)\n"))
    }

    func usageError(_ message: String, topic: CLIHelpTopic) -> CLIParseResult {
        .terminal(
            .failure(
                message + "\n\n" + CLIHelp.text(for: topic, applicationName: applicationName) + "\n"
            )
        )
    }

    func uniqued(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
