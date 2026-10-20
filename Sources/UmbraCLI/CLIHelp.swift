public enum CLIHelpTopic: String, CaseIterable, Equatable, Sendable {
    case global
    case recoverStorage = "recover-storage"
    case list
    case pair
    case stream
    case quit
    case attach
    case stop
    case telemetry
}

/// Stable, dependency-free help text for the GameStream-compatible CLI surface.
public enum CLIHelp {
    public static func text(for topic: CLIHelpTopic, applicationName: String = "umbra") -> String {
        return switch topic {
        case .global:
            """
            Usage: \(applicationName) [options] <action>

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
            See '\(applicationName) <action> --help' for help for a specific action.
            """
        case .recoverStorage:
            """
            Usage: \(applicationName) recover-storage [options]

            Recover from Umbra storage that macOS no longer permits the app to read.

            This moves the entire Umbra Application Support directory to a uniquely named sibling
            backup without reading or deleting its contents. Saved hosts, pairing identities,
            protocol trust, preferences, and cached state will be absent on the next normal launch,
            which creates fresh storage and requires hosts to be paired again. The command prints
            the exact backup path so the previous storage remains recoverable.

            Options:
              -h, --help      Display this help text
              -v, --version   Display version information
            """
        case .list:
            """
            Usage: \(applicationName) list [options] <host>

            List the available apps on the given host.

            Arguments:
              host            Host computer name, UUID, or IP address

            Options:
              -csv, --csv         Print as CSV with additional information
              -verbose, --verbose Display connection progress
              --protocol <legacy|lsp>
                                  Select GameStream or LSP explicitly
              --lsp-host-id <uuid> Select an exact persisted LSP host
              --lsp-telemetry     Include an LSP telemetry snapshot
              -h, --help          Display this help text
              -v, --version       Display version information
            """
        case .pair:
            """
            Usage: \(applicationName) pair [options] <host>

            Pair with the specified host.

            Arguments:
              host            Host computer name, UUID, or IP address

            Options:
              -pin, --pin <pin>   Use a predefined 4-digit pairing PIN
              --protocol <legacy|lsp>
                                  LSP generates and displays its own six-digit PIN
              --lsp-host-id <uuid> Select an exact discovered LSP host
              --lsp-permissions <browse,start,input,microphone,stop,quit,controller-output,clipboard>
                                  Request an explicit LSP permission set
              --lsp-microphone <off|optional|required>
              -h, --help          Display this help text
              -v, --version       Display version information
            """
        case .stream:
            """
            Usage: \(applicationName) stream [options] <host> <app>

            Start directly streaming a given app.

            Arguments:
              host                            Host computer name, UUID, or IP address
              app                             App to stream

            Resolution and video options:
              -720, --720                     Use 1280x720 resolution
              -1080, --1080                   Use 1920x1080 resolution
              -1440, --1440                   Use 2560x1440 resolution
              -4K, --4K                       Use 3840x2160 resolution
              -resolution, --resolution <WxH> Use a custom resolution
              -fps, --fps <fps>               Specify frames per second
              -bitrate, --bitrate <kbps>      Specify bitrate in Kbps
              -packet-size, --packet-size <n> Specify video packet size
              -display-mode, --display-mode <fullscreen|windowed|borderless>
              -video-codec, --video-codec <auto|H.264|HEVC|AV1>
              -video-decoder, --video-decoder <auto|software|hardware>

            Audio and input options:
              -audio-config, --audio-config <stereo|5.1-surround|7.1-surround>
              -capture-system-keys, --capture-system-keys <never|fullscreen|always>
              -lsp-profile, --lsp-profile <adaptive|competition>
              -lsp-capacity-mbps, --lsp-capacity-mbps <mbps>
              -lsp-pointer-rate, --lsp-pointer-rate <125...16000>
              -lsp-controller-rate, --lsp-controller-rate <125...2000>
              -lsp-sensor-rate, --lsp-sensor-rate <125...4000>
              -lsp-reconciliation-rate, --lsp-reconciliation-rate <50...1000>
              --protocol <legacy|lsp>          Select the transport explicitly
              --lsp-host-id <uuid>             Select an exact persisted LSP host
              --lsp-microphone <off|optional|required>
              --lsp-telemetry                  Print telemetry after startup

            Boolean options (prefix with no- to disable):
              vsync, multi-controller, quit-after, absolute-mouse
              mouse-buttons-swap, touchscreen-trackpad, game-optimization
              audio-on-host, frame-pacing, mute-on-focus-loss, background-gamepad
              reverse-scroll-direction, swap-gamepad-buttons, keep-awake
              performance-overlay, hdr

            For LSP streams, performance-overlay includes native transport,
            media, path-MTU, authentication, drop, and reconnect statistics.

            General options:
              -quit-running-app, --quit-running-app
                                              Quit a different running app before launch
              --resume                        Attach to the selected running application intent
              -h, --help                      Display this help text
              -v, --version                   Display version information
            """
        case .quit:
            """
            Usage: \(applicationName) quit [options] <host>

            Quit the currently running app on the given host.

            Arguments:
              host            Host computer name, UUID, or IP address

            Options:
              --protocol <legacy|lsp>
                                  Select GameStream or LSP explicitly
              --lsp-host-id <uuid> Select an exact persisted LSP host
              --lsp-telemetry     Include an LSP telemetry snapshot
              -h, --help      Display this help text
              -v, --version   Display version information
            """
        case .attach:
            lspLifecycleHelp(action: "attach", summary: "Reattach an existing authenticated LSP stream.", applicationName: applicationName)
        case .stop:
            lspLifecycleHelp(action: "stop", summary: "Stop an owned LSP stream and await its authenticated response.", applicationName: applicationName)
        case .telemetry:
            lspLifecycleHelp(action: "telemetry", summary: "Print the current low-rate LSP telemetry snapshot.", applicationName: applicationName)
        }
    }

    private static func lspLifecycleHelp(action: String, summary: String, applicationName: String) -> String {
        """
        Usage: \(applicationName) \(action) [options] <host>

        \(summary)

        Options:
          --protocol lsp             Required explicit protocol selection
          --lsp-host-id <uuid>       Select an exact persisted LSP host ID
          --lsp-telemetry            Include telemetry after the operation
          -h, --help                 Display this help text
          -v, --version              Display version information
        """
    }
}
