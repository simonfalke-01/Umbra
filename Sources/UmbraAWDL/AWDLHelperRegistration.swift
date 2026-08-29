import Foundation
import ServiceManagement

public enum AWDLHelperRegistrationStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

public protocol AWDLHelperCapabilityChecking: Sendable {
    func requireEnabled() throws
}

public struct SystemAWDLHelperCapabilityChecker: AWDLHelperCapabilityChecking, Sendable {
    public init() {}

    public func requireEnabled() throws {
        let status = SMAppService.daemon(
            plistName: AWDLHelperContract.launchDaemonPlistName
        ).status
        guard status == .enabled else {
            let reason = switch status {
            case .notRegistered: "the helper is not registered"
            case .requiresApproval: "approval is required or was revoked"
            case .notFound: "the helper is missing from this app bundle"
            case .enabled: "the helper is unavailable"
            @unknown default: "the helper registration state is unknown"
            }
            throw AWDLHelperError.unavailable(reason)
        }
    }
}

@MainActor
public protocol AWDLAppServiceRegistering: AnyObject {
    var status: AWDLHelperRegistrationStatus { get }
    func register() throws
}

@MainActor
public final class SystemAWDLAppService: AWDLAppServiceRegistering {
    private let service: SMAppService

    public init() {
        service = .daemon(plistName: AWDLHelperContract.launchDaemonPlistName)
    }

    public var status: AWDLHelperRegistrationStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func register() throws {
        try service.register()
    }
}

@MainActor
public final class AWDLHelperRegistrationManager {
    public static let registrationAttemptedKey = "AWDLHelperRegistrationAttempted"

    private let service: any AWDLAppServiceRegistering
    private let defaults: UserDefaults
    private let registrationAttemptKey: String

    public init(
        service: any AWDLAppServiceRegistering = SystemAWDLAppService(),
        defaults: UserDefaults = .standard,
        registrationGeneration: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
    ) {
        self.service = service
        self.defaults = defaults
        registrationAttemptKey = Self.registrationAttemptedKey
            + "." + registrationGeneration
    }

    public var status: AWDLHelperRegistrationStatus { service.status }
    public var registrationWasAttempted: Bool {
        defaults.bool(forKey: registrationAttemptKey)
    }

    @discardableResult
    public func requestRegistrationOnce() throws -> AWDLHelperRegistrationStatus {
        guard !registrationWasAttempted else {
            throw AWDLHelperError.registrationAlreadyAttempted
        }
        // Persist before crossing the authorization boundary. A thrown or denied
        // registration never turns a later stream/app launch into another prompt.
        defaults.set(true, forKey: registrationAttemptKey)
        try service.register()
        return service.status
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
