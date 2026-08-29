import AppKit
import Combine
import Foundation
import UmbraAWDL

@MainActor
final class AWDLHelperSettingsModel: ObservableObject {
    @Published private(set) var status: AWDLHelperRegistrationStatus
    @Published private(set) var registrationWasAttempted: Bool
    @Published var errorMessage: String?

    private let manager: AWDLHelperRegistrationManager

    init(manager: AWDLHelperRegistrationManager = AWDLHelperRegistrationManager()) {
        self.manager = manager
        status = manager.status
        registrationWasAttempted = manager.registrationWasAttempted
    }

    func refresh() {
        status = manager.status
        registrationWasAttempted = manager.registrationWasAttempted
    }

    func requestRegistration() {
        do {
            status = try manager.requestRegistrationOnce()
            registrationWasAttempted = true
        } catch {
            registrationWasAttempted = manager.registrationWasAttempted
            status = manager.status
            errorMessage = error.localizedDescription
        }
    }

    func openApprovalSettings() {
        manager.openApprovalSettings()
    }

    var title: String {
        switch status {
        case .enabled: "Installed"
        case .requiresApproval: "Approval Required"
        case .notRegistered where registrationWasAttempted: "Unavailable"
        case .notRegistered: "Not Installed"
        case .notFound: "Missing From App"
        }
    }

    var detail: String {
        switch status {
        case .enabled:
            "The root helper is approved. Stream lifecycle commands use authenticated XPC without prompts."
        case .requiresApproval:
            "Approve Umbra’s background item in Login Items. Umbra will not request authorization during a stream."
        case .notRegistered where registrationWasAttempted:
            "Registration was already requested once for this helper version. "
                + "Install a newer notarized Umbra build to retry."
        case .notRegistered:
            "Install once before streaming. macOS requires an administrator to approve the launch daemon."
        case .notFound:
            "This Umbra bundle does not contain the packaged AWDL helper."
        }
    }
}
