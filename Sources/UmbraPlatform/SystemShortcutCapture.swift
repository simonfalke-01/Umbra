@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public enum SystemShortcutCaptureMode: Equatable, Sendable {
    case off
    case fullscreenOnly
    case always
}

public enum SystemShortcutCapturePermission: Hashable, Sendable {
    case inputMonitoring
    case accessibility
}

public struct SystemShortcutPermissionSnapshot: Equatable, Sendable {
    public var inputMonitoringGranted: Bool
    public var accessibilityGranted: Bool
    public var isAppSandboxed: Bool

    public init(inputMonitoringGranted: Bool, accessibilityGranted: Bool, isAppSandboxed: Bool) {
        self.inputMonitoringGranted = inputMonitoringGranted
        self.accessibilityGranted = accessibilityGranted
        self.isAppSandboxed = isAppSandboxed
    }

    public var missingPermissions: Set<SystemShortcutCapturePermission> {
        var result: Set<SystemShortcutCapturePermission> = []
        if !inputMonitoringGranted { result.insert(.inputMonitoring) }
        if !accessibilityGranted { result.insert(.accessibility) }
        return result
    }
}

public enum SystemShortcutCaptureStatus: Equatable, Sendable {
    case disabled
    case inactive
    case permissionRequired(Set<SystemShortcutCapturePermission>)
    case unavailableInAppSandbox
    /// Permissions allow a public CGEventTap-based driver to be started.
    case ready
    case active
    case driverFailed
}

public struct SystemShortcutCaptureState: Equatable, Sendable {
    public var mode: SystemShortcutCaptureMode
    public var windowFocused: Bool
    public var presentation: WindowPresentation
    public var permissions: SystemShortcutPermissionSnapshot

    public init(
        mode: SystemShortcutCaptureMode = .off,
        windowFocused: Bool = false,
        presentation: WindowPresentation = .windowed,
        permissions: SystemShortcutPermissionSnapshot
    ) {
        self.mode = mode
        self.windowFocused = windowFocused
        self.presentation = presentation
        self.permissions = permissions
    }

    public var shouldCapture: Bool {
        guard windowFocused else { return false }
        switch mode {
        case .off: return false
        case .always: return true
        case .fullscreenOnly: return presentation != .windowed
        }
    }

    public var readiness: SystemShortcutCaptureStatus {
        guard mode != .off else { return .disabled }
        guard shouldCapture else { return .inactive }
        guard !permissions.isAppSandboxed else { return .unavailableInAppSandbox }
        let missing = permissions.missingPermissions
        guard missing.isEmpty else { return .permissionRequired(missing) }
        return .ready
    }
}

public enum SystemShortcutCapturePermissionReader {
    public static func snapshot() -> SystemShortcutPermissionSnapshot {
        .init(
            inputMonitoringGranted: CGPreflightListenEventAccess(),
            accessibilityGranted: AXIsProcessTrusted(),
            isAppSandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        )
    }

    /// Requests are deliberately separate from status reads so callers control when
    /// macOS presents privacy prompts.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    public static func requestAccessibility(showPrompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: showPrompt] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

@MainActor
public protocol SystemShortcutCaptureDriving: AnyObject {
    /// Starts/stops a CGEventTap or another explicitly supported implementation.
    /// Returning false must leave the driver inactive.
    func setCaptureEnabled(_ enabled: Bool) -> Bool
}

@MainActor
public final class UnavailableSystemShortcutCaptureDriver: SystemShortcutCaptureDriving {
    public init() {}
    public func setCaptureEnabled(_ enabled: Bool) -> Bool { !enabled }
}

/// Public-API system shortcut capture for non-sandboxed Developer ID builds.
/// It never requests privacy permission; callers decide when to present macOS prompts.
@MainActor
public final class CGEventTapSystemShortcutCaptureDriver: SystemShortcutCaptureDriving {
    public typealias EventHandler = @MainActor @Sendable (NSEvent) -> Bool

    private let eventHandler: EventHandler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init(eventHandler: @escaping EventHandler) {
        self.eventHandler = eventHandler
    }

    public func setCaptureEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            stop()
            return true
        }
        guard eventTap == nil,
              CGPreflightListenEventAccess(),
              AXIsProcessTrusted()
        else { return eventTap != nil }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let driver = Unmanaged<CGEventTapSystemShortcutCaptureDriver>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = driver.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard let appEvent = NSEvent(cgEvent: event) else {
                    return Unmanaged.passUnretained(event)
                }
                let consumed = MainActor.assumeIsolated { driver.eventHandler(appEvent) }
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
    }
}

@MainActor
public final class SystemShortcutCaptureCoordinator {
    public private(set) var state: SystemShortcutCaptureState
    public private(set) var status: SystemShortcutCaptureStatus
    public var onStatusChanged: ((SystemShortcutCaptureStatus) -> Void)?

    private let driver: SystemShortcutCaptureDriving

    public init(state: SystemShortcutCaptureState, driver: SystemShortcutCaptureDriving) {
        self.state = state
        self.driver = driver
        status = state.readiness
    }

    public func update(
        mode: SystemShortcutCaptureMode? = nil,
        windowFocused: Bool? = nil,
        presentation: WindowPresentation? = nil,
        permissions: SystemShortcutPermissionSnapshot? = nil
    ) {
        if let mode { state.mode = mode }
        if let windowFocused { state.windowFocused = windowFocused }
        if let presentation { state.presentation = presentation }
        if let permissions { state.permissions = permissions }
        apply()
    }

    private func apply() {
        let readiness = state.readiness
        let newStatus: SystemShortcutCaptureStatus
        if readiness == .ready {
            newStatus = driver.setCaptureEnabled(true) ? .active : .driverFailed
        } else {
            _ = driver.setCaptureEnabled(false)
            newStatus = readiness
        }
        guard newStatus != status else { return }
        status = newStatus
        onStatusChanged?(newStatus)
    }
}
