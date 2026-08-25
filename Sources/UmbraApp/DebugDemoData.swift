#if DEBUG
import Foundation

@MainActor
final class DemoUmbraClientService: UmbraClientServicing {
    func setEventHandler(_ handler: (@MainActor @Sendable (UmbraClientEvent) -> Void)?) {}
    private let onlineID = HostID("debug-online-host")
    private let offlineID = HostID("debug-offline-host")
    private var hosts: [HostDisplayModel]
    private var apps: [ApplicationDisplayModel]

    init(
        artworkURLs: [Int: URL] = [:],
        applications: [ApplicationDisplayModel]? = nil
    ) {
        hosts = [
            HostDisplayModel(
                id: onlineID,
                name: "Studio Mac",
                status: .online,
                isPaired: true,
                hasActiveSession: true,
                runningApplicationID: ApplicationID(2),
                canWake: true,
                isServerSupported: true,
                details: "Status: Online\nPairing: Paired\nGPU: Apple M4 Max\nAddress: studio-mac.local"
            ),
            HostDisplayModel(
                id: offlineID,
                name: "Living Room Host",
                status: .offline,
                isPaired: true,
                hasActiveSession: false,
                canWake: true,
                isServerSupported: true,
                details: "Status: Offline\nPairing: Paired\nAddress: 192.0.2.25"
            ),
        ]
        let defaultApplications = [
            ApplicationDisplayModel(id: ApplicationID(1), hostID: onlineID, name: "Desktop", artworkURL: artworkURLs[1], isRunning: false, isHidden: false, isDirectLaunch: true),
            ApplicationDisplayModel(id: ApplicationID(2), hostID: onlineID, name: "Media Center", artworkURL: artworkURLs[2], isRunning: true, isHidden: false, isDirectLaunch: false),
            ApplicationDisplayModel(id: ApplicationID(3), hostID: onlineID, name: "Hidden Utility", artworkURL: nil, isRunning: false, isHidden: true, isDirectLaunch: false),
            ApplicationDisplayModel(id: ApplicationID(4), hostID: onlineID, name: "Creative Workspace", artworkURL: artworkURLs[4], isRunning: false, isHidden: false, isDirectLaunch: false),
            ApplicationDisplayModel(id: ApplicationID(5), hostID: onlineID, name: "Game Library", artworkURL: artworkURLs[5], isRunning: false, isHidden: false, isDirectLaunch: false),
            ApplicationDisplayModel(id: ApplicationID(6), hostID: onlineID, name: "A Very Long Application Name", artworkURL: nil, isRunning: false, isHidden: false, isDirectLaunch: false),
            ApplicationDisplayModel(id: ApplicationID(7), hostID: onlineID, name: "リモートデスクトップ", artworkURL: nil, isRunning: false, isHidden: false, isDirectLaunch: false),
            ApplicationDisplayModel(id: ApplicationID(8), hostID: onlineID, name: "Remote Workspace", artworkURL: artworkURLs[8], isRunning: false, isHidden: false, isDirectLaunch: false),
        ]
        apps = applications ?? defaultApplications
    }

    func discoverHosts() async throws -> [HostDisplayModel] { hosts }
    func addHost(_ endpoint: HostEndpointInput) async throws -> HostDisplayModel { throw UmbraClientServiceError.unavailable("Demo data does not perform network actions.") }
    func pairSecureHost(invitationURI: String) async throws -> HostDisplayModel { throw UmbraClientServiceError.unavailable("Demo data does not perform secure pairing.") }
    func pairHost(_ request: PairingRequest) async throws -> HostDisplayModel { throw UmbraClientServiceError.unavailable("Demo data does not perform pairing.") }
    func cancelPairing(hostID: HostID) async {}
    func renameHost(id: HostID, name: String) async throws -> HostDisplayModel {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { throw UmbraClientServiceError.unavailable("Host missing") }
        hosts[index].name = name
        return hosts[index]
    }
    func deleteHost(id: HostID) async throws { hosts.removeAll { $0.id == id } }
    func wakeHost(id: HostID) async throws -> HostDisplayModel { throw UmbraClientServiceError.unavailable("Demo data does not send Wake-on-LAN packets.") }
    func testNetwork(for id: HostID) async throws -> NetworkTestOutcome { .unavailable }
    func applications(for id: HostID, includeHidden: Bool) async throws -> [ApplicationDisplayModel] { apps }
    func launchApplication(id: ApplicationID, on hostID: HostID, resume: Bool) async throws { throw UmbraClientServiceError.unavailable("Demo data does not launch streams.") }
    func quitApplication(id: ApplicationID, on hostID: HostID) async throws { throw UmbraClientServiceError.unavailable("Demo data does not control host apps.") }
    func setApplicationHidden(id: ApplicationID, on hostID: HostID, hidden: Bool) async throws {}
    func setDirectLaunch(id: ApplicationID, on hostID: HostID, enabled: Bool) async throws {}
}
#endif
