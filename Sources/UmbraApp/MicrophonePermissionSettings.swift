import AppKit
import Combine
import Foundation
import UmbraMicrophone

enum MicrophonePermissionPresentationState: Equatable {
    case notDetermined
    case requesting
    case authorized
    case denied
    case restricted

    init(authorizationStatus: ClientMicrophoneAuthorizationStatus) {
        switch authorizationStatus {
        case .notDetermined:
            self = .notDetermined
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        }
    }
}

enum MicrophonePermissionSettingsCopy {
    static var openSettingsTitle: String {
        UmbraLocalization.string("Open Microphone Settings")
    }

    static var openSettingsAccessibilityHelp: String {
        UmbraLocalization.string("Opens Microphone settings in System Settings.")
    }
}

@MainActor
struct MicrophonePermissionEnvironment {
    let permissionModel: MicrophonePermissionSettingsModel
    let applicationNotifications: NotificationCenter
    let openMicrophoneSettings: () -> Void
    let availableInputDevices: () -> [ClientMicrophoneDevice]

    init(
        authorizer: any ClientMicrophoneAuthorizing,
        initialState: MicrophonePermissionPresentationState? = nil,
        applicationNotifications: NotificationCenter = .default,
        availableInputDevices: @escaping () -> [ClientMicrophoneDevice] = {
            SystemClientMicrophoneDevices.availableDevices()
        },
        openMicrophoneSettings: @escaping () -> Void
    ) {
        permissionModel = MicrophonePermissionSettingsModel(
            authorizer: authorizer,
            initialState: initialState
        )
        self.applicationNotifications = applicationNotifications
        self.availableInputDevices = availableInputDevices
        self.openMicrophoneSettings = openMicrophoneSettings
    }

    init(
        permissionModel: MicrophonePermissionSettingsModel,
        applicationNotifications: NotificationCenter = .default,
        availableInputDevices: @escaping () -> [ClientMicrophoneDevice] = {
            SystemClientMicrophoneDevices.availableDevices()
        },
        openMicrophoneSettings: @escaping () -> Void
    ) {
        self.permissionModel = permissionModel
        self.applicationNotifications = applicationNotifications
        self.availableInputDevices = availableInputDevices
        self.openMicrophoneSettings = openMicrophoneSettings
    }

    static var system: Self {
        Self(
            authorizer: SystemClientMicrophoneAuthorization(),
            openMicrophoneSettings: {
                guard let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                ) else { return }
                NSWorkspace.shared.open(url)
            }
        )
    }
}

@MainActor
final class MicrophonePermissionSettingsModel: ObservableObject {
    @Published private(set) var presentationState: MicrophonePermissionPresentationState

    private let authorizer: any ClientMicrophoneAuthorizing
    private var requestTask: Task<ClientMicrophoneAuthorizationStatus, Never>?

    init(
        authorizer: any ClientMicrophoneAuthorizing,
        initialState: MicrophonePermissionPresentationState? = nil
    ) {
        self.authorizer = authorizer
        presentationState = initialState
            ?? MicrophonePermissionPresentationState(
                authorizationStatus: authorizer.status()
            )
    }

    func requestAuthorization() async -> ClientMicrophoneAuthorizationStatus {
        if let requestTask {
            return await requestTask.value
        }

        let currentStatus = authorizer.status()
        guard currentStatus == .notDetermined else {
            presentationState = MicrophonePermissionPresentationState(
                authorizationStatus: currentStatus
            )
            return currentStatus
        }

        presentationState = .requesting
        let requestTask = Task { await authorizer.requestAuthorization() }
        self.requestTask = requestTask
        let resolvedStatus = await requestTask.value
        self.requestTask = nil
        presentationState = MicrophonePermissionPresentationState(
            authorizationStatus: resolvedStatus
        )
        return resolvedStatus
    }

    @discardableResult
    func refreshAuthorization() -> ClientMicrophoneAuthorizationStatus? {
        guard requestTask == nil else { return nil }
        let status = authorizer.status()
        presentationState = MicrophonePermissionPresentationState(
            authorizationStatus: status
        )
        return status
    }
}
