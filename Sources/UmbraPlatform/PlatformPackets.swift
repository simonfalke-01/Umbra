import Foundation

/// Packets emitted by the platform layer. UmbraStreaming can consume these without
/// depending on AppKit or GameController types.
public enum PlatformInputPacket: Equatable, Sendable {
    case keyboard(KeyboardPacket)
    case mouseMove(MouseMovePacket)
    case mouseButton(MouseButtonPacket)
    case scroll(ScrollPacket)
    case touch(TouchPacket)
    case text(String)
    case controller(ControllerPacket)
    case controllerArrival(ControllerArrivalPacket)
    case controllerBattery(ControllerBatteryPacket)
    case controllerMotion(ControllerMotionPacket)
    case controllerTouch(ControllerTouchPacket)
}

public enum TouchPhase: UInt8, Equatable, Sendable {
    case began = 1
    case ended = 2
    case moved = 3
    case cancelled = 4
}

public struct TouchPacket: Equatable, Sendable {
    public var pointerID: UInt32
    public var phase: TouchPhase
    public var x: Float
    public var y: Float
    public var pressure: Float

    public init(pointerID: UInt32, phase: TouchPhase, x: Float, y: Float, pressure: Float) {
        self.pointerID = pointerID
        self.phase = phase
        self.x = x
        self.y = y
        self.pressure = pressure
    }
}

public protocol PlatformInputPacketSink: AnyObject {
    func platformInputDidProduce(_ packet: PlatformInputPacket)
}

public enum KeyAction: Equatable, Sendable {
    case down
    case up
}

public struct KeyboardModifierMask: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
}

public struct KeyboardPacket: Equatable, Sendable {
    /// Windows virtual-key code expected by the Moonlight input protocol.
    public var virtualKey: UInt16
    public var action: KeyAction
    public var modifiers: KeyboardModifierMask
    public var isExtended: Bool
    /// Sunshine keyboard-event flags. Most keys use zero; international keys
    /// that must bypass host-side layout normalization use bit 0.
    public var flags: UInt8

    public init(
        virtualKey: UInt16,
        action: KeyAction,
        modifiers: KeyboardModifierMask,
        isExtended: Bool,
        flags: UInt8 = 0
    ) {
        self.virtualKey = virtualKey
        self.action = action
        self.modifiers = modifiers
        self.isExtended = isExtended
        self.flags = flags
    }
}

public enum MouseMovePacket: Equatable, Sendable {
    case relative(deltaX: Int16, deltaY: Int16)
    case absolute(x: Int16, y: Int16, referenceWidth: Int16, referenceHeight: Int16)
}

public enum MouseButton: UInt8, CaseIterable, Equatable, Hashable, Sendable {
    case left = 1
    case middle = 2
    case right = 3
    case back = 4
    case forward = 5
}

public struct MouseButtonPacket: Equatable, Sendable {
    public var button: MouseButton
    public var action: KeyAction

    public init(button: MouseButton, action: KeyAction) {
        self.button = button
        self.action = action
    }
}

public enum ScrollAxis: Equatable, Sendable {
    case vertical
    case horizontal
}

public struct ScrollPacket: Equatable, Sendable {
    /// Windows WHEEL_DELTA-compatible units. One detent is 120.
    public var axis: ScrollAxis
    public var delta: Int16

    public init(axis: ScrollAxis, delta: Int16) {
        self.axis = axis
        self.delta = delta
    }
}

public struct ControllerButtonMask: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let a = Self(rawValue: 1 << 0)
    public static let b = Self(rawValue: 1 << 1)
    public static let x = Self(rawValue: 1 << 2)
    public static let y = Self(rawValue: 1 << 3)
    public static let back = Self(rawValue: 1 << 4)
    public static let guide = Self(rawValue: 1 << 5)
    public static let start = Self(rawValue: 1 << 6)
    public static let leftStick = Self(rawValue: 1 << 7)
    public static let rightStick = Self(rawValue: 1 << 8)
    public static let leftShoulder = Self(rawValue: 1 << 9)
    public static let rightShoulder = Self(rawValue: 1 << 10)
    public static let dpadUp = Self(rawValue: 1 << 11)
    public static let dpadDown = Self(rawValue: 1 << 12)
    public static let dpadLeft = Self(rawValue: 1 << 13)
    public static let dpadRight = Self(rawValue: 1 << 14)
    public static let misc = Self(rawValue: 1 << 15)
    public static let paddle1 = Self(rawValue: 1 << 16)
    public static let paddle2 = Self(rawValue: 1 << 17)
    public static let paddle3 = Self(rawValue: 1 << 18)
    public static let paddle4 = Self(rawValue: 1 << 19)
    public static let touchpad = Self(rawValue: 1 << 20)
}

public struct ControllerPacket: Equatable, Sendable {
    public var playerIndex: UInt8
    public var activeControllerMask: UInt16
    public var buttons: ControllerButtonMask
    public var leftTrigger: UInt8
    public var rightTrigger: UInt8
    public var leftStickX: Int16
    public var leftStickY: Int16
    public var rightStickX: Int16
    public var rightStickY: Int16

    public init(
        playerIndex: UInt8,
        activeControllerMask: UInt16,
        buttons: ControllerButtonMask,
        leftTrigger: UInt8,
        rightTrigger: UInt8,
        leftStickX: Int16,
        leftStickY: Int16,
        rightStickX: Int16,
        rightStickY: Int16
    ) {
        self.playerIndex = playerIndex
        self.activeControllerMask = activeControllerMask
        self.buttons = buttons
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
    }
}

public enum ControllerFamily: Equatable, Sendable {
    case xbox
    case playStation
    case nintendo
    case unknown
}

public struct ControllerCapabilities: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let analogTriggers = Self(rawValue: 1 << 0)
    public static let rumble = Self(rawValue: 1 << 1)
    public static let triggerRumble = Self(rawValue: 1 << 2)
    public static let touchpad = Self(rawValue: 1 << 3)
    public static let dualTouchpad = Self(rawValue: 1 << 4)
    public static let accelerometer = Self(rawValue: 1 << 5)
    public static let gyroscope = Self(rawValue: 1 << 6)
    public static let battery = Self(rawValue: 1 << 7)
    public static let rgbLED = Self(rawValue: 1 << 8)
    public static let adaptiveTriggers = Self(rawValue: 1 << 9)
}

public struct ControllerArrivalPacket: Equatable, Sendable {
    public var playerIndex: UInt8
    public var activeControllerMask: UInt16
    public var family: ControllerFamily
    public var supportedButtons: ControllerButtonMask
    public var capabilities: ControllerCapabilities
    public var vendorName: String?
    public var productCategory: String

    public init(
        playerIndex: UInt8,
        activeControllerMask: UInt16,
        family: ControllerFamily,
        supportedButtons: ControllerButtonMask,
        capabilities: ControllerCapabilities,
        vendorName: String?,
        productCategory: String
    ) {
        self.playerIndex = playerIndex
        self.activeControllerMask = activeControllerMask
        self.family = family
        self.supportedButtons = supportedButtons
        self.capabilities = capabilities
        self.vendorName = vendorName
        self.productCategory = productCategory
    }
}

public enum ControllerBatteryState: Equatable, Sendable {
    case unknown
    case discharging
    case charging
    case full
}

public struct ControllerBatteryPacket: Equatable, Sendable {
    public var playerIndex: UInt8
    public var state: ControllerBatteryState
    /// 0...100, or nil when the framework does not expose a meaningful level.
    public var percentage: UInt8?

    public init(playerIndex: UInt8, state: ControllerBatteryState, percentage: UInt8?) {
        self.playerIndex = playerIndex
        self.state = state
        self.percentage = percentage
    }
}

public enum ControllerMotionKind: Equatable, Sendable {
    case accelerometer
    case gyroscope
}

public struct ControllerMotionPacket: Equatable, Sendable {
    public var playerIndex: UInt8
    public var kind: ControllerMotionKind
    public var x: Float
    public var y: Float
    public var z: Float

    public init(playerIndex: UInt8, kind: ControllerMotionKind, x: Float, y: Float, z: Float) {
        self.playerIndex = playerIndex
        self.kind = kind
        self.x = x
        self.y = y
        self.z = z
    }
}

public enum ControllerTouchPhase: Equatable, Sendable {
    case began
    case moved
    case ended
}

public struct ControllerTouchPacket: Equatable, Sendable {
    public var playerIndex: UInt8
    public var touchpadIndex: UInt8
    public var fingerIndex: UInt8
    public var phase: ControllerTouchPhase
    public var x: Float
    public var y: Float
    public var pressure: Float

    public init(
        playerIndex: UInt8,
        touchpadIndex: UInt8,
        fingerIndex: UInt8,
        phase: ControllerTouchPhase,
        x: Float,
        y: Float,
        pressure: Float
    ) {
        self.playerIndex = playerIndex
        self.touchpadIndex = touchpadIndex
        self.fingerIndex = fingerIndex
        self.phase = phase
        self.x = x
        self.y = y
        self.pressure = pressure
    }
}
