import Foundation

struct HostID: Hashable, Codable, Identifiable, Sendable {
    let rawValue: String

    init(_ rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }
}

enum HostConnectionStatus: String, Codable, Sendable {
    case online
    case offline
    case unknown

    var label: String {
        switch self {
        case .online: "Online"
        case .offline: "Offline"
        case .unknown: "Checking status"
        }
    }
}

struct HostDisplayModel: Identifiable, Hashable, Sendable {
    let id: HostID
    var name: String
    var status: HostConnectionStatus
    var isPaired: Bool
    var hasActiveSession: Bool
    var runningApplicationID: ApplicationID? = nil
    var canWake: Bool
    var isServerSupported: Bool
    var details: String

    var canBrowseApplications: Bool {
        status == .online && isPaired && isServerSupported
    }
}

struct ApplicationID: Hashable, Codable, Identifiable, Sendable {
    let rawValue: Int

    init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    var id: Int { rawValue }
}

struct ApplicationDisplayModel: Identifiable, Hashable, Sendable {
    let id: ApplicationID
    let hostID: HostID
    var name: String
    var artworkURL: URL?
    var isRunning: Bool
    var isHidden: Bool
    var isDirectLaunch: Bool
}

struct ApplicationBrowserContext: Equatable, Sendable {
    var hostID: HostID
    var filter: String
    var showsHiddenApplications: Bool
    var selectedApplicationID: ApplicationID?
    var scrollPositionID: ApplicationID?
}

struct HostEndpointInput: Hashable, Sendable {
    var address: String
    var port: Int?
}

struct PairingRequest: Hashable, Sendable {
    let hostID: HostID
    let pin: String
}

struct PairingPreparation: Hashable, Sendable {
    let pin: String
    let provisionalSPKIFingerprint: String?
    let requestedPermissions: [String]
    let effectivePermissions: [String]
}

enum NetworkTestOutcome: Hashable, Sendable {
    case clear
    case blocked(ports: [String])
    case unavailable

    var title: String {
        switch self {
        case .clear: "Network Looks Ready"
        case .blocked: "Connection May Be Blocked"
        case .unavailable: "Network Test Unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .clear: "checkmark.circle"
        case .blocked: "exclamationmark.triangle"
        case .unavailable: "network.slash"
        }
    }

    var message: String {
        switch self {
        case .clear:
            "This network does not appear to block the ports Umbra needs. If connecting still fails, check the host firewall."
        case let .blocked(ports):
            "This network appears to block required streaming ports: \(ports.joined(separator: ", ")). Streaming over the internet may not work on this connection."
        case .unavailable:
            "No connection-testing server could be reached. Check the internet connection and try again later."
        }
    }
}

enum LoadingState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(message: String)
}

struct PresentedFailure: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    var recovery: PresentedFailureRecovery? = nil
}

enum PresentedFailureRecovery: Equatable {
    case reconnect(hostID: HostID, applicationID: ApplicationID)
}

enum OperationKind: Equatable {
    case addingHost
    case pairing
    case waking
    case testing
    case connecting
    case quitting
    case updating
}

struct OperationPresentation: Equatable {
    let kind: OperationKind
    let title: String
    let message: String
    var progress: Double?
    var isCancellable: Bool
}

enum PresentedSheet: Identifiable, Equatable {
    case addHost
    case pair(HostID, pin: String)
    case rename(HostID)
    case details(HostID)
    case networkResult(NetworkTestOutcome)

    var id: String {
        switch self {
        case .addHost: "add-host"
        case let .pair(id, _): "pair-\(id.rawValue)"
        case let .rename(id): "rename-\(id.rawValue)"
        case let .details(id): "details-\(id.rawValue)"
        case .networkResult: "network-result"
        }
    }
}

enum PresentedConfirmation: Identifiable, Equatable {
    case deleteHost(HostID)
    case quitApplication(ApplicationID)
    case replaceRunningApplication(current: ApplicationID, next: ApplicationID)

    var id: String {
        switch self {
        case let .deleteHost(id): "delete-host-\(id.rawValue)"
        case let .quitApplication(id): "quit-app-\(id.rawValue)"
        case let .replaceRunningApplication(current, next): "replace-app-\(current.rawValue)-\(next.rawValue)"
        }
    }
}
