import Foundation

enum HostBrowserActionKind: String, Hashable, Sendable {
    case openApplications
    case pair
    case wake
    case details
    case testNetwork
    case rename
    case remove
}

enum HostBrowserActionRole: Hashable, Sendable {
    case standard
    case destructive
}

struct HostBrowserActionDescriptor: Identifiable, Hashable, Sendable {
    let kind: HostBrowserActionKind
    let title: String
    let compactTitle: String
    let symbol: String
    var role: HostBrowserActionRole = .standard

    init(
        kind: HostBrowserActionKind,
        title: String,
        compactTitle: String? = nil,
        symbol: String,
        role: HostBrowserActionRole = .standard
    ) {
        self.kind = kind
        self.title = title
        self.compactTitle = compactTitle ?? title
        self.symbol = symbol
        self.role = role
    }

    var id: HostBrowserActionKind { kind }
}

struct HostBrowserActionGroup: Identifiable, Hashable, Sendable {
    enum ID: String, Hashable, Sendable {
        case primary
        case management
        case destructive
    }

    let id: ID
    let actions: [HostBrowserActionDescriptor]
}

struct HostBrowserPresentation: Hashable, Sendable {
    let hostID: HostID
    let name: String
    let statusSummary: String
    let statusSymbol: String
    let statusTone: StatusTone
    let defaultAction: HostBrowserActionDescriptor?
    let actionGroups: [HostBrowserActionGroup]

    enum StatusTone: Hashable, Sendable {
        case neutral
        case warning
        case failure
        case checking
    }

    init(host: HostDisplayModel) {
        hostID = host.id
        name = host.name
        let statusPresentation = Self.statusPresentation(for: host)
        statusSummary = statusPresentation.summary
        statusSymbol = statusPresentation.symbol
        statusTone = statusPresentation.tone

        let defaultAction = Self.defaultAction(for: host)
        self.defaultAction = defaultAction

        var primaryActions: [HostBrowserActionDescriptor] = []
        if let defaultAction {
            primaryActions.append(defaultAction)
        }

        var managementActions = [Self.testNetworkAction, Self.renameAction]
        if defaultAction?.kind != .details {
            managementActions.append(Self.detailsAction)
        }

        actionGroups = [
            HostBrowserActionGroup(id: .primary, actions: primaryActions),
            HostBrowserActionGroup(id: .management, actions: managementActions),
            HostBrowserActionGroup(id: .destructive, actions: [Self.removeAction]),
        ].filter { !$0.actions.isEmpty }
    }

    var accessibilityLabel: String { name }
    var accessibilityValue: String { statusSummary }

    var accessibilityHelp: String {
        guard let defaultAction else {
            return "Host status is still being checked."
        }
        let actionTitle = defaultAction.title.trimmingCharacters(
            in: CharacterSet(charactersIn: ". ")
        )
        return "Press to \(actionTitle.lowercased())."
    }

    private static func statusPresentation(
        for host: HostDisplayModel
    ) -> (summary: String, symbol: String, tone: StatusTone) {
        switch host.status {
        case .unknown:
            ("Checking...", "ellipsis.circle", .checking)
        case .offline where host.canWake:
            ("Offline, Can Wake", UmbraSymbol.offline, .neutral)
        case .offline:
            ("Offline", UmbraSymbol.offline, .neutral)
        case .online where !host.isServerSupported:
            (
                [
                    "Unsupported Host",
                    host.hasActiveSession ? "Streaming" : nil,
                    host.isPaired ? nil : "Pair Required",
                ].compactMap { $0 }.joined(separator: ", "),
                "exclamationmark.triangle",
                .failure
            )
        case .online where !host.isPaired && host.hasActiveSession:
            ("Streaming, Pair Required", UmbraSymbol.unpaired, .warning)
        case .online where !host.isPaired:
            host.id.rawValue.hasPrefix("lsp:")
                ? ("LSP Invitation Required", UmbraSymbol.unpaired, .warning)
                : ("Pair Required", UmbraSymbol.unpaired, .warning)
        case .online where host.hasActiveSession:
            ("Streaming", UmbraSymbol.running, .neutral)
        case .online:
            ("Ready", "checkmark.circle", .neutral)
        }
    }

    private static func defaultAction(for host: HostDisplayModel) -> HostBrowserActionDescriptor? {
        switch host.status {
        case .unknown:
            nil
        case .offline where host.canWake:
            wakeAction
        case .offline:
            detailsAction
        case .online where !host.isServerSupported:
            detailsAction
        case .online where !host.isPaired:
            host.id.rawValue.hasPrefix("lsp:") ? detailsAction : pairAction
        case .online:
            openApplicationsAction
        }
    }

    private static let openApplicationsAction = HostBrowserActionDescriptor(
        kind: .openApplications,
        title: "Open Applications",
        compactTitle: "Open Apps",
        symbol: UmbraSymbol.application
    )
    private static let pairAction = HostBrowserActionDescriptor(
        kind: .pair,
        title: "Pair Host...",
        compactTitle: "Pair",
        symbol: UmbraSymbol.unpaired
    )
    private static let wakeAction = HostBrowserActionDescriptor(
        kind: .wake,
        title: "Wake Host",
        compactTitle: "Wake",
        symbol: UmbraSymbol.wake
    )
    private static let detailsAction = HostBrowserActionDescriptor(
        kind: .details,
        title: "Show Details",
        compactTitle: "Details",
        symbol: UmbraSymbol.details
    )
    private static let testNetworkAction = HostBrowserActionDescriptor(
        kind: .testNetwork,
        title: "Test Network...",
        symbol: UmbraSymbol.test
    )
    private static let renameAction = HostBrowserActionDescriptor(
        kind: .rename,
        title: "Rename Host...",
        symbol: "pencil"
    )
    private static let removeAction = HostBrowserActionDescriptor(
        kind: .remove,
        title: "Remove Host...",
        symbol: "trash",
        role: .destructive
    )
}
