import Foundation
import UmbraCore

enum UmbraClientServiceError: LocalizedError {
    case unavailable(String)
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .invalidInput(message): message
        }
    }
}

enum UmbraClientEvent: Sendable {
    case hosts([HostDisplayModel])
    case applicationCatalogUpdated(hostID: HostID, applications: [ApplicationDisplayModel])
    case applicationCatalogRefreshWarning(hostID: HostID, message: String)
    case sessionPreparing
    case sessionConnecting(SessionStage)
    case sessionStreaming
    case sessionFailed(SessionFailure)
    case sessionEnded
    case sessionWarning(String)
    case sessionDegraded(String)
    case configurationWarnings([String])
}

@MainActor
protocol UmbraClientServicing: AnyObject {
    func setEventHandler(_ handler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?)
    func discoverHosts() async throws -> [HostDisplayModel]
    func addHost(_ endpoint: HostEndpointInput) async throws -> HostDisplayModel
    func preparePairing(hostID: HostID) async throws -> PairingPreparation
    func pairHost(_ request: PairingRequest) async throws -> HostDisplayModel
    func cancelPairing(hostID: HostID) async
    func renameHost(id: HostID, name: String) async throws -> HostDisplayModel
    func updateHostEndpoint(id: HostID, endpoint: HostEndpointInput) async throws -> HostDisplayModel
    func deleteHost(id: HostID) async throws
    func wakeHost(id: HostID) async throws -> HostDisplayModel
    func applications(for id: HostID, includeHidden: Bool) async throws -> [ApplicationDisplayModel]
    func launchApplication(id: ApplicationID, on hostID: HostID, resume: Bool) async throws
    func launchApplication(
        id: ApplicationID,
        on hostID: HostID,
        resume: Bool,
        activationUptime: TimeInterval
    ) async throws
    func disconnectSession() async
    func quitApplication(id: ApplicationID, on hostID: HostID) async throws
    func setApplicationHidden(id: ApplicationID, on hostID: HostID, hidden: Bool) async throws
    func setDirectLaunch(id: ApplicationID, on hostID: HostID, enabled: Bool) async throws
}

extension UmbraClientServicing {
    func updateHostEndpoint(id: HostID, endpoint: HostEndpointInput) async throws -> HostDisplayModel {
        throw UmbraClientServiceError.unavailable("Address editing is only available for paired Lumen hosts.")
    }

    func preparePairing(hostID: HostID) async throws -> PairingPreparation {
        .init(
            pin: String(format: "%04d", Int.random(in: 0...9_999)),
            provisionalSPKIFingerprint: nil,
            requestedPermissions: [],
            effectivePermissions: []
        )
    }

    func launchApplication(
        id: ApplicationID,
        on hostID: HostID,
        resume: Bool,
        activationUptime: TimeInterval
    ) async throws {
        try await launchApplication(id: id, on: hostID, resume: resume)
    }

    func disconnectSession() async {}
}

/// Keeps the UI recoverable if native service composition fails during startup.
/// Every operation reports the failure and never fabricates host or stream state.
@MainActor
final class UnavailableUmbraClientService: UmbraClientServicing {
    private var error: UmbraClientServiceError {
        .unavailable("Umbra could not initialize its native streaming services. No host or stream state was changed.")
    }

    func setEventHandler(_ handler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?) {}
    func discoverHosts() async throws -> [HostDisplayModel] { throw error }
    func addHost(_ endpoint: HostEndpointInput) async throws -> HostDisplayModel { throw error }
    func pairHost(_ request: PairingRequest) async throws -> HostDisplayModel { throw error }
    func cancelPairing(hostID: HostID) async {}
    func renameHost(id: HostID, name: String) async throws -> HostDisplayModel { throw error }
    func deleteHost(id: HostID) async throws { throw error }
    func wakeHost(id: HostID) async throws -> HostDisplayModel { throw error }
    func applications(for id: HostID, includeHidden: Bool) async throws -> [ApplicationDisplayModel] { throw error }
    func launchApplication(id: ApplicationID, on hostID: HostID, resume: Bool) async throws { throw error }
    func quitApplication(id: ApplicationID, on hostID: HostID) async throws { throw error }
    func setApplicationHidden(id: ApplicationID, on hostID: HostID, hidden: Bool) async throws { throw error }
    func setDirectLaunch(id: ApplicationID, on hostID: HostID, enabled: Bool) async throws { throw error }
}
