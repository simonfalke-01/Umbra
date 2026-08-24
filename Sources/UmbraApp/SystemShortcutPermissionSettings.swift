import AppKit
import Combine
import UmbraPlatform

@MainActor
struct SystemShortcutPermissionEnvironment {
    let permissionModel: SystemShortcutPermissionSettingsModel
    let applicationNotifications: NotificationCenter

    init(
        snapshotReader: @escaping () -> SystemShortcutPermissionSnapshot,
        requestInputMonitoring: @escaping () -> Bool,
        requestAccessibility: @escaping (_ showPrompt: Bool) -> Void,
        applicationNotifications: NotificationCenter = .default
    ) {
        permissionModel = SystemShortcutPermissionSettingsModel(
            snapshotReader: snapshotReader,
            requestInputMonitoring: requestInputMonitoring,
            requestAccessibility: requestAccessibility
        )
        self.applicationNotifications = applicationNotifications
    }

    init(
        permissionModel: SystemShortcutPermissionSettingsModel,
        applicationNotifications: NotificationCenter = .default
    ) {
        self.permissionModel = permissionModel
        self.applicationNotifications = applicationNotifications
    }

    static var system: Self {
        Self(
            snapshotReader: SystemShortcutCapturePermissionReader.snapshot,
            requestInputMonitoring: SystemShortcutCapturePermissionReader.requestInputMonitoring,
            requestAccessibility: SystemShortcutCapturePermissionReader.requestAccessibility
        )
    }
}

@MainActor
final class SystemShortcutPermissionSettingsModel: ObservableObject {
    @Published private(set) var snapshot: SystemShortcutPermissionSnapshot

    private let snapshotReader: () -> SystemShortcutPermissionSnapshot
    private let requestInputMonitoring: () -> Bool
    private let requestAccessibility: (_ showPrompt: Bool) -> Void

    init(
        snapshotReader: @escaping () -> SystemShortcutPermissionSnapshot,
        requestInputMonitoring: @escaping () -> Bool,
        requestAccessibility: @escaping (_ showPrompt: Bool) -> Void
    ) {
        self.snapshotReader = snapshotReader
        self.requestInputMonitoring = requestInputMonitoring
        self.requestAccessibility = requestAccessibility
        snapshot = snapshotReader()
    }

    func refresh() {
        snapshot = snapshotReader()
    }

    func requestMissingPermissions() {
        if !snapshot.inputMonitoringGranted {
            _ = requestInputMonitoring()
        }
        if !snapshot.accessibilityGranted {
            requestAccessibility(true)
        }
        refresh()
    }
}
