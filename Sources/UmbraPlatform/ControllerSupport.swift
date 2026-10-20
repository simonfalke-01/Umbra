import Foundation

public enum ControllerOutputCommand: Equatable, Sendable {
    case rumble(lowFrequency: UInt16, highFrequency: UInt16)
    case triggerRumble(left: UInt16, right: UInt16)
    case led(red: UInt8, green: UInt8, blue: UInt8)
    case adaptiveTriggers(left: AdaptiveTriggerEffect, right: AdaptiveTriggerEffect)
}

public enum AdaptiveTriggerEffect: Equatable, Sendable {
    case off
    case feedback(startPosition: Float, strength: Float)
    case weapon(startPosition: Float, endPosition: Float, strength: Float)
    case vibration(startPosition: Float, amplitude: Float, frequency: Float)

    public var isValid: Bool {
        switch self {
        case .off:
            return true
        case .feedback(let start, let strength):
            return (0...1).contains(start) && (0...1).contains(strength)
        case .weapon(let start, let end, let strength):
            return (0...1).contains(start) && (0...1).contains(end) && start < end && (0...1).contains(strength)
        case .vibration(let start, let amplitude, let frequency):
            return (0...1).contains(start) && (0...1).contains(amplitude) && (0...1).contains(frequency)
        }
    }
}

public enum ControllerOutputResult: Equatable, Sendable {
    case applied
    case controllerNotConnected
    case unsupported
    case invalidCommand
    case failed(String)
}

@MainActor
public protocol ControllerOutputServicing: AnyObject {
    func send(_ command: ControllerOutputCommand, toPlayer playerIndex: UInt8) -> ControllerOutputResult
}

public struct ControllerStateSample: Equatable, Sendable {
    public var buttons: ControllerButtonMask
    public var leftTrigger: Float
    public var rightTrigger: Float
    public var leftStickX: Float
    public var leftStickY: Float
    public var rightStickX: Float
    public var rightStickY: Float

    public init(
        buttons: ControllerButtonMask = [],
        leftTrigger: Float = 0,
        rightTrigger: Float = 0,
        leftStickX: Float = 0,
        leftStickY: Float = 0,
        rightStickX: Float = 0,
        rightStickY: Float = 0
    ) {
        self.buttons = buttons
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
    }
}

public enum ControllerLocalAction: Equatable, Sendable {
    case disconnect
    case toggleStatistics
    case mouseModeChanged(Bool)
}

enum ControllerInteractionOutput: Equatable, Sendable {
    case hostState(ControllerStateSample)
    case mouseButton(MouseButtonPacket)
    case scroll(ScrollPacket)
    case localAction(ControllerLocalAction)
}

/// Owns timing and edge-sensitive behavior for one physical controller. The
/// raw sample remains independent from the state visible to the host so a
/// controller used as a mouse cannot leak held controls through merged mode.
struct ControllerInteractionStateMachine: Sendable {
    static let mouseModeLongPressDuration: TimeInterval = 0.750
    static let mousePollingInterval: TimeInterval = 0.050

    private(set) var rawSample = ControllerStateSample()
    private(set) var hostSample = ControllerStateSample()
    private(set) var mouseModeActive = false
    private(set) var mouseButtonsDown: Set<MouseButton> = []

    private var startDownAt: TimeInterval?
    private var suppressedChord: ControllerButtonMask?

    private static let disconnectChord: ControllerButtonMask = [
        .start, .back, .leftShoulder, .rightShoulder,
    ]
    private static let statisticsChord: ControllerButtonMask = [
        .back, .leftShoulder, .rightShoulder, .x,
    ]
    private static let mouseButtonMappings: [(ControllerButtonMask, MouseButton)] = [
        (.a, .left),
        (.b, .right),
        (.x, .middle),
        (.leftShoulder, .back),
        (.rightShoulder, .forward),
    ]

    init() {}

    mutating func update(
        _ sample: ControllerStateSample,
        at time: TimeInterval,
        gamepadMouseEnabled: Bool
    ) -> [ControllerInteractionOutput] {
        let previousButtons = rawSample.buttons
        rawSample = sample

        if let chord = suppressedChord {
            var outputs: [ControllerInteractionOutput] = []
            var filtered = sample
            filtered.buttons.subtract(chord)
            appendHostState(filtered, to: &outputs)
            if sample.buttons.isDisjoint(with: chord) {
                suppressedChord = nil
            }
            return outputs
        }

        if sample.buttons == Self.disconnectChord {
            return recognizeChord(Self.disconnectChord, action: .disconnect)
        }
        if sample.buttons == Self.statisticsChord {
            return recognizeChord(Self.statisticsChord, action: .toggleStatistics)
        }

        let pressed = sample.buttons.subtracting(previousButtons)
        let released = previousButtons.subtracting(sample.buttons)
        if pressed.contains(.start) {
            startDownAt = time
        }

        if mouseModeActive {
            if released.contains(.start),
               let startDownAt,
               time - startDownAt >= Self.mouseModeLongPressDuration {
                self.startDownAt = nil
                var outputs = releaseMouseButtons()
                mouseModeActive = false
                forceHostState(sample, to: &outputs)
                outputs.append(.localAction(.mouseModeChanged(false)))
                return outputs
            }
            if released.contains(.start) { startDownAt = nil }

            var outputs: [ControllerInteractionOutput] = []
            for (buttonMask, mouseButton) in Self.mouseButtonMappings {
                if pressed.contains(buttonMask), mouseButtonsDown.insert(mouseButton).inserted {
                    outputs.append(.mouseButton(.init(button: mouseButton, action: .down)))
                }
                if released.contains(buttonMask), mouseButtonsDown.remove(mouseButton) != nil {
                    outputs.append(.mouseButton(.init(button: mouseButton, action: .up)))
                }
            }
            if pressed.contains(.dpadUp) {
                outputs.append(.scroll(.init(axis: .vertical, delta: 120)))
            }
            if pressed.contains(.dpadDown) {
                outputs.append(.scroll(.init(axis: .vertical, delta: -120)))
            }
            if pressed.contains(.dpadRight) {
                outputs.append(.scroll(.init(axis: .horizontal, delta: 120)))
            }
            if pressed.contains(.dpadLeft) {
                outputs.append(.scroll(.init(axis: .horizontal, delta: -120)))
            }
            return outputs
        }

        if released.contains(.start), let startDownAt {
            self.startDownAt = nil
            if gamepadMouseEnabled,
                time - startDownAt >= Self.mouseModeLongPressDuration {
                var outputs: [ControllerInteractionOutput] = []
                forceHostState(.init(), to: &outputs)
                mouseModeActive = true
                outputs.append(.localAction(.mouseModeChanged(true)))
                return outputs
            }
        }

        var outputs: [ControllerInteractionOutput] = []
        appendHostState(sample, to: &outputs)
        return outputs
    }

    func mouseMovement() -> MouseMovePacket? {
        guard mouseModeActive else { return nil }
        let leftX = Int(ControllerStateMapper.axis(rawSample.leftStickX))
        let leftY = Int(ControllerStateMapper.axis(rawSample.leftStickY))
        let rightX = Int(ControllerStateMapper.axis(rawSample.rightStickX))
        let rightY = Int(ControllerStateMapper.axis(rawSample.rightStickY))
        let useLeft = abs(leftX) + abs(leftY) > abs(rightX) + abs(rightY)
        let rawX = useLeft ? leftX : rightX
        let rawY = -(useLeft ? leftY : rightY)
        let deltaX = Self.mouseDelta(rawX)
        let deltaY = Self.mouseDelta(rawY)
        guard deltaX != 0 || deltaY != 0 else { return nil }
        return .relative(deltaX: deltaX, deltaY: deltaY)
    }

    mutating func reset() -> [ControllerInteractionOutput] {
        var outputs = releaseMouseButtons()
        let wasMouseModeActive = mouseModeActive
        rawSample = .init()
        startDownAt = nil
        suppressedChord = nil
        mouseModeActive = false
        appendHostState(.init(), to: &outputs)
        if wasMouseModeActive {
            outputs.append(.localAction(.mouseModeChanged(false)))
        }
        return outputs
    }

    static func mouseDelta(_ rawValue: Int) -> Int16 {
        let scaled = pow(Double(rawValue) / 32_766 * 4, 3)
        let adjusted = abs(scaled) > 2 ? scaled - 2 : 0
        return Int16(clamping: Int(adjusted))
    }

    private mutating func recognizeChord(
        _ chord: ControllerButtonMask,
        action: ControllerLocalAction
    ) -> [ControllerInteractionOutput] {
        startDownAt = nil
        suppressedChord = chord
        var outputs = releaseMouseButtons()
        forceHostState(.init(), to: &outputs)
        outputs.append(.localAction(action))
        return outputs
    }

    private mutating func releaseMouseButtons() -> [ControllerInteractionOutput] {
        var outputs: [ControllerInteractionOutput] = []
        for button in MouseButton.allCases where mouseButtonsDown.remove(button) != nil {
            outputs.append(.mouseButton(.init(button: button, action: .up)))
        }
        return outputs
    }

    private mutating func appendHostState(
        _ sample: ControllerStateSample,
        to outputs: inout [ControllerInteractionOutput]
    ) {
        guard sample != hostSample else { return }
        hostSample = sample
        outputs.append(.hostState(sample))
    }

    private mutating func forceHostState(
        _ sample: ControllerStateSample,
        to outputs: inout [ControllerInteractionOutput]
    ) {
        hostSample = sample
        outputs.append(.hostState(sample))
    }
}

public enum ControllerStateMapper {
    public static func packet(
        sample: ControllerStateSample,
        playerIndex: UInt8,
        activeControllerMask: UInt16
    ) -> ControllerPacket {
        .init(
            playerIndex: playerIndex,
            activeControllerMask: activeControllerMask,
            buttons: sample.buttons,
            leftTrigger: trigger(sample.leftTrigger),
            rightTrigger: trigger(sample.rightTrigger),
            leftStickX: axis(sample.leftStickX),
            leftStickY: axis(sample.leftStickY),
            rightStickX: axis(sample.rightStickX),
            rightStickY: axis(sample.rightStickY)
        )
    }

    public static func axis(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, -1), 1)
        if clamped <= -1 { return Int16.min }
        return Int16((clamped * Float(Int16.max)).rounded())
    }

    public static func trigger(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((min(max(value, 0), 1) * 255).rounded())
    }
}

/// Combines physical controllers into the client's single-controller mode.
/// Samples are evaluated in connection order so equal-magnitude stick input has
/// a deterministic winner instead of depending on dictionary iteration order.
public enum ControllerStateMerger {
    public static func merge<S: Sequence>(_ samples: S) -> ControllerStateSample
    where S.Element == ControllerStateSample {
        var merged = ControllerStateSample()

        for sample in samples {
            merged.buttons.formUnion(sample.buttons)
            if sample.leftTrigger.isFinite {
                merged.leftTrigger = max(merged.leftTrigger, sample.leftTrigger)
            }
            if sample.rightTrigger.isFinite {
                merged.rightTrigger = max(merged.rightTrigger, sample.rightTrigger)
            }

            if isStrongerStick(
                candidateX: sample.leftStickX,
                candidateY: sample.leftStickY,
                currentX: merged.leftStickX,
                currentY: merged.leftStickY
            ) {
                merged.leftStickX = sample.leftStickX
                merged.leftStickY = sample.leftStickY
            }

            if isStrongerStick(
                candidateX: sample.rightStickX,
                candidateY: sample.rightStickY,
                currentX: merged.rightStickX,
                currentY: merged.rightStickY
            ) {
                merged.rightStickX = sample.rightStickX
                merged.rightStickY = sample.rightStickY
            }
        }

        return merged
    }

    private static func isStrongerStick(
        candidateX: Float,
        candidateY: Float,
        currentX: Float,
        currentY: Float
    ) -> Bool {
        guard candidateX.isFinite, candidateY.isFinite else { return false }
        return abs(candidateX) > abs(currentX) || abs(candidateY) > abs(currentY)
    }
}

public struct ControllerMetadata: Equatable, Sendable {
    public var family: ControllerFamily
    public var supportedButtons: ControllerButtonMask
    public var capabilities: ControllerCapabilities

    public init(
        family: ControllerFamily,
        supportedButtons: ControllerButtonMask,
        capabilities: ControllerCapabilities
    ) {
        self.family = family
        self.supportedButtons = supportedButtons
        self.capabilities = capabilities
    }
}

/// Produces one stable virtual-controller description for merged player one.
/// Conflicting physical families become unknown and supported input buttons are
/// combined. Output capabilities stay bound to the lowest-slot controller,
/// which is also the deterministic merged feedback owner. Once announced, the
/// virtual metadata stays stable until every merged controller disconnects so
/// heterogeneous hot-plug cannot create an unorderable metadata rebind.
public enum ControllerMetadataMerger {
    public static func merge<S: Sequence>(_ values: S) -> ControllerMetadata?
    where S.Element == ControllerMetadata {
        var iterator = values.makeIterator()
        guard let first = iterator.next() else { return nil }
        var merged = first
        while let value = iterator.next() {
            if value.family != merged.family { merged.family = .unknown }
            merged.supportedButtons.formUnion(value.supportedButtons)
        }
        return merged
    }
}

public enum ControllerMetadataRebindAction: Equatable, Sendable {
    case stateOnly
    case arrival(ControllerMetadata)
    case departure
}

public enum ControllerMetadataRebindPlanner {
    public static func action(
        from previous: ControllerMetadata?,
        to next: ControllerMetadata?
    ) -> ControllerMetadataRebindAction {
        if previous != nil, next != nil { return .stateOnly }
        return switch (previous, next) {
        case (nil, .some(let next)):
            .arrival(next)
        case (.some, nil):
            .departure
        case (.some, .some):
            .stateOnly
        case (nil, nil):
            .stateOnly
        }
    }
}

public enum ControllerPlayerAssignment {
    public static func playerIndex(slotIndex: UInt8, multiControllerEnabled: Bool) -> UInt8 {
        multiControllerEnabled ? slotIndex : 0
    }
}

public enum ControllerNavigationMode: Equatable, Sendable {
    /// D-pad up/down move directionally, suitable for grids and application lists.
    case directional
    /// D-pad up/down traverse focus, suitable for settings and form controls.
    case focusTraversal
}

public enum ControllerNavigationDirection: Equatable, Sendable {
    case up
    case down
    case left
    case right
}

/// Framework-neutral UI actions produced from controller state. AppKit or
/// SwiftUI code can translate these into focus/key commands without importing
/// GameController into the application UI.
public enum ControllerNavigationEvent: Equatable, Sendable {
    case move(ControllerNavigationDirection)
    case focusPrevious
    case focusNext
    case activate
    case cancel
    case showContextMenu
    case showSettings
}

/// Edge- and repeat-aware mapper matching the client's controller UI navigation.
public struct ControllerNavigationStateMachine: Sendable {
    public static let defaultAnalogRepeatInterval: TimeInterval = 0.15

    public var analogThreshold: Float
    public var analogRepeatInterval: TimeInterval

    private var previousButtons: ControllerButtonMask = []
    private var heldAnalogDirection: ControllerNavigationDirection?
    private var nextAnalogRepeatTime: TimeInterval?

    public init(
        analogThreshold: Float = 30_000 / Float(Int16.max),
        analogRepeatInterval: TimeInterval = Self.defaultAnalogRepeatInterval
    ) {
        self.analogThreshold = min(max(analogThreshold, 0), 1)
        self.analogRepeatInterval = max(analogRepeatInterval, 0.01)
    }

    var hasPendingAnalogRepeat: Bool {
        heldAnalogDirection != nil
    }

    public mutating func events(
        for sample: ControllerStateSample,
        at time: TimeInterval,
        mode: ControllerNavigationMode
    ) -> [ControllerNavigationEvent] {
        var events = buttonEvents(for: sample.buttons, mode: mode)
        previousButtons = sample.buttons

        let direction = analogDirection(for: sample)
        if direction != heldAnalogDirection {
            heldAnalogDirection = direction
            nextAnalogRepeatTime = direction == nil ? nil : time + analogRepeatInterval
            if let direction { events.append(navigationEvent(for: direction, mode: mode)) }
        } else {
            events.append(contentsOf: repeatedAnalogEvents(at: time, mode: mode))
        }

        return events
    }

    /// Advances held-stick repeat timing without requiring another controller
    /// value-change callback. The platform timer calls this while an analog
    /// direction remains held.
    mutating func repeatedAnalogEvents(
        at time: TimeInterval,
        mode: ControllerNavigationMode
    ) -> [ControllerNavigationEvent] {
        guard let direction = heldAnalogDirection,
              let repeatTime = nextAnalogRepeatTime,
              time >= repeatTime
        else { return [] }
        nextAnalogRepeatTime = time + analogRepeatInterval
        return [navigationEvent(for: direction, mode: mode)]
    }

    mutating func reset() {
        previousButtons = []
        heldAnalogDirection = nil
        nextAnalogRepeatTime = nil
    }

    private func buttonEvents(
        for buttons: ControllerButtonMask,
        mode: ControllerNavigationMode
    ) -> [ControllerNavigationEvent] {
        let pressed = ControllerButtonMask(rawValue: buttons.rawValue & ~previousButtons.rawValue)
        var events: [ControllerNavigationEvent] = []
        if pressed.contains(.dpadUp) { events.append(navigationEvent(for: .up, mode: mode)) }
        if pressed.contains(.dpadDown) { events.append(navigationEvent(for: .down, mode: mode)) }
        if pressed.contains(.dpadLeft) { events.append(.move(.left)) }
        if pressed.contains(.dpadRight) { events.append(.move(.right)) }
        if pressed.contains(.a) { events.append(.activate) }
        if pressed.contains(.b) { events.append(.cancel) }
        if pressed.contains(.x) { events.append(.showContextMenu) }
        if pressed.contains(.y) || pressed.contains(.start) { events.append(.showSettings) }
        return events
    }

    private func analogDirection(for sample: ControllerStateSample) -> ControllerNavigationDirection? {
        guard sample.leftStickX.isFinite, sample.leftStickY.isFinite else { return nil }
        if sample.leftStickY > analogThreshold { return .up }
        if sample.leftStickY < -analogThreshold { return .down }
        if sample.leftStickX < -analogThreshold { return .left }
        if sample.leftStickX > analogThreshold { return .right }
        return nil
    }

    private func navigationEvent(
        for direction: ControllerNavigationDirection,
        mode: ControllerNavigationMode
    ) -> ControllerNavigationEvent {
        switch (direction, mode) {
        case (.up, .focusTraversal): return .focusPrevious
        case (.down, .focusTraversal): return .focusNext
        default: return .move(direction)
        }
    }
}

public struct ControllerTouchContactID: Hashable, Equatable, Sendable, Comparable {
    public var touchpadIndex: UInt8
    public var fingerIndex: UInt8

    public init(touchpadIndex: UInt8, fingerIndex: UInt8) {
        self.touchpadIndex = touchpadIndex
        self.fingerIndex = fingerIndex
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.touchpadIndex, lhs.fingerIndex) < (rhs.touchpadIndex, rhs.fingerIndex)
    }
}

public struct ControllerTouchContactEvent: Equatable, Sendable {
    public var id: ControllerTouchContactID
    public var phase: ControllerTouchPhase
    public var x: Float
    public var y: Float
    public var pressure: Float

    public init(
        id: ControllerTouchContactID,
        phase: ControllerTouchPhase,
        x: Float,
        y: Float,
        pressure: Float
    ) {
        self.id = id
        self.phase = phase
        self.x = x
        self.y = y
        self.pressure = pressure
    }
}

/// Repairs lifecycle discontinuities from controllers connected mid-contact and
/// guarantees active contacts are ended during hot-unplug.
public struct ControllerTouchLifecycle: Sendable {
    private var activeContacts: [ControllerTouchContactID: ControllerTouchContactEvent] = [:]

    public init() {}

    public var activeContactIDs: [ControllerTouchContactID] {
        activeContacts.keys.sorted()
    }

    public mutating func handle(_ event: ControllerTouchContactEvent) -> [ControllerTouchContactEvent] {
        switch event.phase {
        case .began:
            let previous = activeContacts[event.id]
            activeContacts[event.id] = event
            guard let previous else { return [event] }
            return [
                ControllerTouchContactEvent(
                    id: previous.id,
                    phase: .ended,
                    x: previous.x,
                    y: previous.y,
                    pressure: 0
                ),
                event,
            ]
        case .moved:
            if activeContacts[event.id] == nil {
                let began = ControllerTouchContactEvent(
                    id: event.id,
                    phase: .began,
                    x: event.x,
                    y: event.y,
                    pressure: event.pressure
                )
                activeContacts[event.id] = began
                return [began]
            }
            activeContacts[event.id] = event
            return [event]
        case .ended:
            guard activeContacts.removeValue(forKey: event.id) != nil else { return [] }
            var ended = event
            ended.pressure = 0
            return [ended]
        }
    }

    public mutating func endAllContacts() -> [ControllerTouchContactEvent] {
        let events = activeContacts.values
            .sorted { $0.id < $1.id }
            .map { contact in
                ControllerTouchContactEvent(
                    id: contact.id,
                    phase: .ended,
                    x: contact.x,
                    y: contact.y,
                    pressure: 0
                )
            }
        activeContacts.removeAll()
        return events
    }
}

public enum ControllerTouchMapper {
    public static func packet(
        playerIndex: UInt8,
        event: ControllerTouchContactEvent
    ) -> ControllerTouchPacket {
        ControllerTouchPacket(
            playerIndex: playerIndex,
            touchpadIndex: event.id.touchpadIndex,
            fingerIndex: event.id.fingerIndex,
            phase: event.phase,
            x: normalizedAxis(event.x),
            y: 1 - normalizedAxis(event.y),
            pressure: normalizedPressure(event.pressure)
        )
    }

    private static func normalizedAxis(_ value: Float) -> Float {
        guard value.isFinite else { return 0.5 }
        return min(max((value + 1) / 2, 0), 1)
    }

    private static func normalizedPressure(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Deterministic lowest-free-slot allocation matching the client's player ordering.
public struct ControllerSlotRegistry<ID: Hashable & Sendable>: Sendable {
    public let maximumControllerCount: Int
    private var slots: [ID?]

    public init(maximumControllerCount: Int = 16) {
        self.maximumControllerCount = min(max(maximumControllerCount, 1), 16)
        slots = Array(repeating: nil, count: self.maximumControllerCount)
    }

    public var activeMask: UInt16 {
        slots.enumerated().reduce(into: UInt16(0)) { result, pair in
            if pair.element != nil { result |= UInt16(1) << UInt16(pair.offset) }
        }
    }

    public mutating func insert(_ id: ID) -> UInt8? {
        if let existing = index(of: id) { return UInt8(existing) }
        guard let free = slots.firstIndex(where: { $0 == nil }) else { return nil }
        slots[free] = id
        return UInt8(free)
    }

    @discardableResult
    public mutating func remove(_ id: ID) -> UInt8? {
        guard let index = index(of: id) else { return nil }
        slots[index] = nil
        return UInt8(index)
    }

    public func playerIndex(for id: ID) -> UInt8? {
        index(of: id).map(UInt8.init)
    }

    private func index(of id: ID) -> Int? {
        slots.firstIndex { $0 == id }
    }
}

public struct MotionReportGate: Equatable, Sendable {
    public var reportRateHz: UInt16
    private var lastReportTime: TimeInterval?
    private var lastValue: SIMD3<Float>?

    public init(reportRateHz: UInt16 = 0) {
        self.reportRateHz = reportRateHz
    }

    public mutating func shouldReport(value: SIMD3<Float>, at time: TimeInterval) -> Bool {
        guard reportRateHz > 0 else { return false }
        guard value != lastValue else { return false }
        let interval = 1 / TimeInterval(reportRateHz)
        if let lastReportTime, time < lastReportTime + interval { return false }
        self.lastReportTime = time
        lastValue = value
        return true
    }
}
