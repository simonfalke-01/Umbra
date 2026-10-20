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
    /// Editable native endpoint, separate from presentation text and paired identity.
    var connectionEndpoint: HostEndpointInput? = nil

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

/// What an application launches; chooses the default icon when the host sends no artwork.
enum ApplicationKind: Hashable, Sendable {
    case program
    case desktop
    case steam
}

struct ApplicationDisplayModel: Identifiable, Hashable, Sendable {
    let id: ApplicationID
    let hostID: HostID
    var name: String
    var artworkURL: URL?
    var isRunning: Bool
    var isHidden: Bool
    var isDirectLaunch: Bool
    var kind: ApplicationKind = .program
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

    var id: String {
        switch self {
        case .addHost: "add-host"
        case let .pair(id, _): "pair-\(id.rawValue)"
        case let .rename(id): "rename-\(id.rawValue)"
        case let .details(id): "details-\(id.rawValue)"
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
