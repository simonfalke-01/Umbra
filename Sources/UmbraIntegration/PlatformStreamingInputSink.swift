import Foundation
import UmbraPlatform

@MainActor
public protocol PlatformInputSinkInstalling: AnyObject, Sendable {
    func installInputSink(_ sink: (any PlatformInputPacketSink)?)
}

extension AppleGameControllerService: PlatformInputSinkInstalling {
    public func installInputSink(_ sink: (any PlatformInputPacketSink)?) {
        self.sink = sink
    }
}

extension AppKitKeyboardInputAdapter: PlatformInputSinkInstalling {
    public func installInputSink(_ sink: (any PlatformInputPacketSink)?) {
        self.sink = sink
    }
}

extension AppKitPointerInputAdapter: PlatformInputSinkInstalling {
    public func installInputSink(_ sink: (any PlatformInputPacketSink)?) {
        self.sink = sink
    }
}

@MainActor
public final class CompositePlatformInputSinkInstaller: PlatformInputSinkInstalling {
    private let installers: [any PlatformInputSinkInstalling]

    public init(_ installers: [any PlatformInputSinkInstalling]) {
        self.installers = installers
    }

    public func installInputSink(_ sink: (any PlatformInputPacketSink)?) {
        for installer in installers { installer.installInputSink(sink) }
    }
}

public enum StreamInputCommand: Equatable, Sendable {
    case keyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8)
    case mouseMove(deltaX: Int16, deltaY: Int16)
    case mousePosition(x: Int16, y: Int16, referenceWidth: Int16, referenceHeight: Int16)
    case mouseButton(action: Int8, button: Int32)
    case scroll(vertical: Int16, horizontal: Int16)
    case touch(pointerID: UInt32, eventType: UInt8, x: Float, y: Float, pressure: Float)
    case text(String)
    case controller(
        number: Int16,
        activeMask: Int16,
        buttons: Int32,
        leftTrigger: UInt8,
        rightTrigger: UInt8,
        leftStickX: Int16,
        leftStickY: Int16,
        rightStickX: Int16,
        rightStickY: Int16
    )
    case controllerArrival(
        number: UInt8,
        activeMask: UInt16,
        type: UInt8,
        supportedButtons: UInt32,
        capabilities: UInt16
    )
    case controllerTouch(
        number: UInt8,
        eventType: UInt8,
        touchpadIndex: UInt8,
        pointerID: UInt32,
        x: Float,
        y: Float,
        pressure: Float
    )
    case controllerMotion(number: UInt8, type: UInt8, x: Float, y: Float, z: Float)
    case controllerBattery(number: UInt8, state: UInt8, percentage: UInt8)
}

public protocol IntegrationUptimeProviding: Sendable {
    func uptime() -> TimeInterval
}

public struct SystemIntegrationUptimeProvider: IntegrationUptimeProviding, Sendable {
    public init() {}
    public func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Shared host-requested controller motion policy. Output callbacks update the
/// requested rate and the packet sink enforces it before crossing into C.
public final class ControllerMotionPolicy: @unchecked Sendable {
    private struct Key: Hashable {
        let player: UInt8
        let type: UInt8
    }

    private struct Sample: Equatable {
        let x: Float
        let y: Float
        let z: Float
    }

    private struct State {
        var reportRates: [Key: UInt16] = [:]
        var lastReportTimes: [Key: TimeInterval] = [:]
        var lastSamples: [Key: Sample] = [:]
    }

    private let lock = NSLock()
    private var state = State()

    public init() {}

    public func setReportRate(_ reportRateHz: UInt16, player: UInt8, motionType: UInt8) {
        lock.withLock {
            let key = Key(player: player, type: motionType)
            state.reportRates[key] = reportRateHz
            if reportRateHz == 0 {
                state.lastReportTimes[key] = nil
                state.lastSamples[key] = nil
            }
        }
    }

    public func reset() {
        lock.withLock { state = State() }
    }

    public var hasEnabledMotion: Bool {
        lock.withLock { state.reportRates.values.contains { $0 > 0 } }
    }

    public func shouldForward(_ packet: ControllerMotionPacket, at time: TimeInterval) -> Bool {
        let type = Self.motionType(packet.kind)
        return lock.withLock {
            let key = Key(player: packet.playerIndex, type: type)
            guard let rate = state.reportRates[key], rate > 0 else { return false }
            let sample = Sample(x: packet.x, y: packet.y, z: packet.z)
            guard state.lastSamples[key] != sample else { return false }
            if let lastTime = state.lastReportTimes[key], time < lastTime + (1 / TimeInterval(rate)) {
                return false
            }
            state.lastReportTimes[key] = time
            state.lastSamples[key] = sample
            return true
        }
    }

    static func motionType(_ kind: ControllerMotionKind) -> UInt8 {
        switch kind {
        case .accelerometer: 1
        case .gyroscope: 2
        }
    }
}

/// Direct adapter from AppKit/GameController callbacks to GameStreamCommon's
/// bounded input queue. Submission remains synchronous so input does not wait
/// behind a second client-side queue or an actor hop.
public final class PlatformStreamingInputSink: PlatformInputPacketSink, @unchecked Sendable {
    public typealias FailureHandler = @Sendable (Error) -> Void

    private let sender: any StreamingSessionControlling
    private let motionPolicy: ControllerMotionPolicy
    private let uptimeProvider: any IntegrationUptimeProviding
    private let failureHandler: FailureHandler

    public init(
        sender: any StreamingSessionControlling,
        motionPolicy: ControllerMotionPolicy = ControllerMotionPolicy(),
        uptimeProvider: any IntegrationUptimeProviding = SystemIntegrationUptimeProvider(),
        failureHandler: @escaping FailureHandler = { _ in }
    ) {
        self.sender = sender
        self.motionPolicy = motionPolicy
        self.uptimeProvider = uptimeProvider
        self.failureHandler = failureHandler
    }

    public func platformInputDidProduce(_ packet: PlatformInputPacket) {
        if case let .controllerMotion(motion) = packet,
           !motionPolicy.shouldForward(motion, at: uptimeProvider.uptime()) {
            return
        }
        guard let command = Self.command(for: packet) else { return }
        do {
            try sender.send(command)
        } catch {
            failureHandler(error)
        }
    }

    public static func command(for packet: PlatformInputPacket) -> StreamInputCommand? {
        switch packet {
        case let .keyboard(packet):
            return .keyboard(
                keyCode: Int16(bitPattern: packet.virtualKey | 0x8000),
                action: packet.action == .down ? 0x03 : 0x04,
                modifiers: Int8(bitPattern: packet.modifiers.rawValue),
                flags: Int8(bitPattern: packet.flags)
            )
        case let .mouseMove(.relative(deltaX, deltaY)):
            return .mouseMove(deltaX: deltaX, deltaY: deltaY)
        case let .mouseMove(.absolute(x, y, referenceWidth, referenceHeight)):
            return .mousePosition(x: x, y: y, referenceWidth: referenceWidth, referenceHeight: referenceHeight)
        case let .mouseButton(packet):
            return .mouseButton(
                action: packet.action == .down ? 0x07 : 0x08,
                button: Int32(packet.button.rawValue)
            )
        case let .scroll(packet):
            switch packet.axis {
            case .vertical: return .scroll(vertical: packet.delta, horizontal: 0)
            case .horizontal: return .scroll(vertical: 0, horizontal: packet.delta)
            }
        case let .touch(packet):
            return .touch(
                pointerID: packet.pointerID,
                eventType: packet.phase.rawValue,
                x: packet.x,
                y: packet.y,
                pressure: packet.pressure
            )
        case let .text(value):
            return value.isEmpty ? nil : .text(value)
        case let .controller(packet):
            return .controller(
                number: Int16(packet.playerIndex),
                activeMask: Int16(bitPattern: packet.activeControllerMask),
                buttons: Int32(bitPattern: controllerButtons(packet.buttons)),
                leftTrigger: packet.leftTrigger,
                rightTrigger: packet.rightTrigger,
                leftStickX: packet.leftStickX,
                leftStickY: packet.leftStickY,
                rightStickX: packet.rightStickX,
                rightStickY: packet.rightStickY
            )
        case let .controllerArrival(packet):
            return .controllerArrival(
                number: packet.playerIndex,
                activeMask: packet.activeControllerMask,
                type: controllerType(packet.family),
                supportedButtons: controllerButtons(packet.supportedButtons),
                capabilities: controllerCapabilities(packet.capabilities)
            )
        case let .controllerBattery(packet):
            return .controllerBattery(
                number: packet.playerIndex,
                state: batteryState(packet.state),
                percentage: packet.percentage ?? 0xFF
            )
        case let .controllerMotion(packet):
            return .controllerMotion(
                number: packet.playerIndex,
                type: ControllerMotionPolicy.motionType(packet.kind),
                x: packet.x,
                y: packet.y,
                z: packet.z
            )
        case let .controllerTouch(packet):
            return .controllerTouch(
                number: packet.playerIndex,
                eventType: touchEventType(packet.phase),
                touchpadIndex: packet.touchpadIndex,
                pointerID: UInt32(packet.touchpadIndex) << 8 | UInt32(packet.fingerIndex),
                x: packet.x,
                y: packet.y,
                pressure: packet.pressure
            )
        }
    }

    public static func controllerButtons(_ buttons: ControllerButtonMask) -> UInt32 {
        var result: UInt32 = 0
        let mappings: [(ControllerButtonMask, UInt32)] = [
            (.a, 0x001000), (.b, 0x002000), (.x, 0x004000), (.y, 0x008000),
            (.dpadUp, 0x000001), (.dpadDown, 0x000002), (.dpadLeft, 0x000004), (.dpadRight, 0x000008),
            (.start, 0x000010), (.back, 0x000020), (.leftStick, 0x000040), (.rightStick, 0x000080),
            (.leftShoulder, 0x000100), (.rightShoulder, 0x000200), (.guide, 0x000400),
            (.paddle1, 0x010000), (.paddle2, 0x020000), (.paddle3, 0x040000), (.paddle4, 0x080000),
            (.touchpad, 0x100000), (.misc, 0x200000),
        ]
        for (source, destination) in mappings where buttons.contains(source) { result |= destination }
        return result
    }

    public static func controllerCapabilities(_ capabilities: ControllerCapabilities) -> UInt16 {
        var result: UInt16 = 0
        let mappings: [(ControllerCapabilities, UInt16)] = [
            (.analogTriggers, 0x001), (.rumble, 0x002), (.triggerRumble, 0x004),
            (.touchpad, 0x008), (.accelerometer, 0x010), (.gyroscope, 0x020),
            (.battery, 0x040), (.rgbLED, 0x080), (.dualTouchpad, 0x100),
            // the GameStream protocol library currently has no advertised adaptive-trigger capability bit.
        ]
        for (source, destination) in mappings where capabilities.contains(source) { result |= destination }
        return result
    }

    private static func controllerType(_ family: ControllerFamily) -> UInt8 {
        switch family {
        case .unknown: 0
        case .xbox: 1
        case .playStation: 2
        case .nintendo: 3
        }
    }

    private static func batteryState(_ state: ControllerBatteryState) -> UInt8 {
        switch state {
        case .unknown: 0
        case .discharging: 2
        case .charging: 3
        case .full: 5
        }
    }

    private static func touchEventType(_ phase: ControllerTouchPhase) -> UInt8 {
        switch phase {
        case .began: 1
        case .ended: 2
        case .moved: 3
        }
    }
}
