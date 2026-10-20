import Foundation
import UmbraCore

public enum ListProgressPhase: Equatable, Sendable {
    case establishingConnection
    case loadingApplications
}

/// Formatting used by the client's `list` command, isolated from networking and process I/O.
public enum CLIListOutputFormatter {
    public static let csvHeader =
        "Name, ID, HDR Support, App Collection Game, Hidden, Direct Launch, Boxart URL"

    public static func format(
        applications: [StreamApplication],
        command: ListAppsCommand,
        boxArtURLs: [Int: String] = [:]
    ) -> String {
        if command.csv {
            return formatCSV(applications: applications, boxArtURLs: boxArtURLs)
        }
        return applications.map(\.name).joined(separator: "\n") + (applications.isEmpty ? "" : "\n")
    }

    public static func verboseMessage(
        for phase: ListProgressPhase,
        command: ListAppsCommand
    ) -> String {
        guard command.verbose else { return "" }
        switch phase {
        case .establishingConnection:
            return "Establishing connection to PC...\n"
        case .loadingApplications:
            return "Loading app list...\n"
        }
    }

    private static func formatCSV(
        applications: [StreamApplication],
        boxArtURLs: [Int: String]
    ) -> String {
        var rows = [csvHeader]
        rows.reserveCapacity(applications.count + 1)

        for application in applications {
            rows.append([
                quote(application.name),
                String(application.id),
                bool(application.hdrSupported),
                bool(application.isAppCollectorGame),
                bool(application.isHidden),
                bool(application.supportsDirectLaunch),
                quote(boxArtURLs[application.id] ?? ""),
            ].joined(separator: ","))
        }

        return rows.joined(separator: "\n") + "\n"
    }

    private static func bool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
