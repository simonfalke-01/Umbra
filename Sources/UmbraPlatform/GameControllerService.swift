import CoreHaptics
import Foundation
@preconcurrency import GameController

struct ControllerHapticLeaseRegistry: Sendable {
    private var nextLease: UInt64 = 0
    private var leases: [UInt8: UInt64] = [:]

    mutating func start(for playerIndex: UInt8) -> UInt64 {
        nextLease &+= 1
        leases[playerIndex] = nextLease
        return nextLease
    }

    mutating func cancel(for playerIndex: UInt8) {
        leases[playerIndex] = nil
    }

    func isCurrent(_ lease: UInt64, for playerIndex: UInt8) -> Bool {
        leases[playerIndex] == lease
    }
}

@MainActor
public final class AppleGameControllerService: ControllerOutputServicing {
    static let maximumHapticDuration: TimeInterval = 30

    public weak var sink: PlatformInputPacketSink? {
        didSet {
            guard oldValue !== sink else { return }
            if let oldValue { releaseAllInputs(to: oldValue) }
            announcedMergedMetadata = nil
            guard sink != nil else { return }
            let orderedControllers = entries.values
                .sorted { $0.slotIndex < $1.slotIndex }
                .map(\.controller)
            if multiControllerEnabled {
                for controller in orderedControllers { announceConnection(controller) }
            } else {
                announceMergedConnection()
            }
        }
    }
    /// Set before `start()`. Matches the client's single-vs-multi-controller preference.
    public var multiControllerEnabled = true {
        didSet {
            guard oldValue != multiControllerEnabled else { return }
            remapConnectedControllers()
        }
    }
    public var swapFaceButtons = false
    public var gamepadMouseEnabled = false
    public var allowsBackgroundInput = false {
        didSet {
            if !observers.isEmpty {
                GCController.shouldMonitorBackgroundEvents = allowsBackgroundInput
            }
            if oldValue, !allowsBackgroundInput, !applicationActive {
                releaseAllInputs()
            }
        }
    }
    public var navigationMode: ControllerNavigationMode = .directional
    public var navigationHandler: ((ControllerNavigationEvent) -> Void)?
    public var localActionHandler: ((ControllerLocalAction) -> Void)?

    private struct Entry {
        var controller: GCController
        var slotIndex: UInt8
        var playerIndex: UInt8
        var lastBattery: ControllerBatteryPacket?
        var interaction = ControllerInteractionStateMachine()
        var navigation = ControllerNavigationStateMachine()
        var touchLifecycle = ControllerTouchLifecycle()
    }

    private var registry = ControllerSlotRegistry<ObjectIdentifier>()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var observers: [NSObjectProtocol] = []
    private var hapticPlayers: [UInt8: [any CHHapticPatternPlayer]] = [:]
    private var hapticEngines: [UInt8: [CHHapticEngine]] = [:]
    private var hapticTimeoutTasks: [UInt8: Task<Void, Never>] = [:]
    private var hapticLeases = ControllerHapticLeaseRegistry()
    private var reportsMotion = false
    private var applicationActive = true
    private var mousePollingTimer: Timer?
    private var navigationRepeatTimer: Timer?
    private var announcedMergedMetadata: ControllerMetadata?
    public private(set) var feedbackSessionActive = false

    public init() {}

    public func start() {
        guard observers.isEmpty else { return }
        GCController.shouldMonitorBackgroundEvents = allowsBackgroundInput
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.connect(controller) }
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.disconnect(controller) }
        })
        // Allocate all initially attached controllers before announcing any of
        // them so every arrival carries the complete initial active mask.
        let initialControllers = GCController.controllers()
        let registeredControllers = initialControllers.filter(register)
        if multiControllerEnabled {
            for controller in registeredControllers { announceConnection(controller) }
        } else {
            announceMergedConnection()
        }
    }

    public func stop() {
        releaseAllInputs()
        endFeedbackSession()
        mousePollingTimer?.invalidate()
        mousePollingTimer = nil
        navigationRepeatTimer?.invalidate()
        navigationRepeatTimer = nil
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        for id in entries.keys {
            guard var entry = entries[id] else { continue }
            endActiveTouches(in: &entry)
            clearHandlers(on: entry.controller)
        }
        entries.removeAll()
        registry = .init()
        announcedMergedMetadata = nil
    }

    /// Keeps remote controller state synchronized when GameController pauses
    /// foreground-only monitoring. On activation, re-sample every attached
    /// controller because held controls may not generate a new edge.
    public func setApplicationActive(_ active: Bool) {
        guard applicationActive != active else { return }
        applicationActive = active
        guard !allowsBackgroundInput else { return }
        if active {
            let orderedControllers = entries.values
                .sorted { $0.slotIndex < $1.slotIndex }
                .map(\.controller)
            for controller in orderedControllers { emitState(for: controller) }
        } else {
            releaseAllInputs()
        }
    }

    public func setMotionReportingEnabled(_ enabled: Bool) {
        reportsMotion = enabled
        for entry in entries.values { configureMotion(for: entry.controller, enabled: enabled) }
    }

    public func releaseAllInputs() {
        releaseAllInputs(to: sink)
    }

    /// Opens the device-feedback boundary for an attached streaming input sink.
    /// Feedback received outside this boundary is ignored so a late native
    /// callback cannot restart a motor or trigger effect after stream teardown.
    public func beginFeedbackSession() {
        feedbackSessionActive = true
    }

    /// Closes the feedback boundary and restores every connected controller to
    /// a neutral state. This is deliberately separate from input release:
    /// haptics, adaptive triggers, and LEDs are device output state.
    public func endFeedbackSession() {
        feedbackSessionActive = false
        neutralizeFeedback()
    }

    public func send(_ command: ControllerOutputCommand, toPlayer playerIndex: UInt8) -> ControllerOutputResult {
        guard feedbackSessionActive else {
            return .failed("Controller feedback session is inactive.")
        }
        guard let controller = entry(forPlayer: playerIndex)?.controller else { return .controllerNotConnected }
        return apply(command, to: controller, playerIndex: playerIndex)
    }

    private func apply(
        _ command: ControllerOutputCommand,
        to controller: GCController,
        playerIndex: UInt8
    ) -> ControllerOutputResult {
        switch command {
        case .rumble(let lowFrequency, let highFrequency):
            return playHaptics(
                controller: controller,
                playerIndex: playerIndex,
                values: [
                    (locality: .leftHandle, intensity: Float(lowFrequency) / Float(UInt16.max), sharpness: 0),
                    (locality: .rightHandle, intensity: Float(highFrequency) / Float(UInt16.max), sharpness: 1),
                ]
            )

        case .triggerRumble(let left, let right):
            return playHaptics(
                controller: controller,
                playerIndex: playerIndex,
                values: [
                    (locality: .leftTrigger, intensity: Float(left) / Float(UInt16.max), sharpness: 0.5),
                    (locality: .rightTrigger, intensity: Float(right) / Float(UInt16.max), sharpness: 0.5),
                ]
            )

        case .led(let red, let green, let blue):
            guard let light = controller.light else { return .unsupported }
            light.color = GCColor(
                red: Float(red) / 255,
                green: Float(green) / 255,
                blue: Float(blue) / 255
            )
            return .applied

        case .adaptiveTriggers(let left, let right):
            guard left.isValid, right.isValid else { return .invalidCommand }
            guard let gamepad = controller.extendedGamepad as? GCDualSenseGamepad else { return .unsupported }
            apply(left, to: gamepad.leftTrigger)
            apply(right, to: gamepad.rightTrigger)
            return .applied
        }
    }

    private func connect(_ controller: GCController) {
        guard register(controller) else { return }
        announceConnection(controller)
    }

    private func register(_ controller: GCController) -> Bool {
        let id = ObjectIdentifier(controller)
        guard entries[id] == nil, let allocatedIndex = registry.insert(id) else { return false }
        let playerIndex = ControllerPlayerAssignment.playerIndex(
            slotIndex: allocatedIndex,
            multiControllerEnabled: multiControllerEnabled
        )
        entries[id] = Entry(controller: controller, slotIndex: allocatedIndex, playerIndex: playerIndex)
        controller.handlerQueue = .main
        assignFrameworkPlayerIndex(allocatedIndex, to: controller)
        installHandlers(on: controller)
        return true
    }

    private func announceConnection(_ controller: GCController) {
        guard multiControllerEnabled else {
            announceMergedConnection()
            return
        }
        guard let entry = entries[ObjectIdentifier(controller)] else { return }
        sink?.platformInputDidProduce(.controllerArrival(.init(
            playerIndex: entry.playerIndex,
            activeControllerMask: registry.activeMask,
            family: family(for: controller),
            supportedButtons: supportedButtons(for: controller),
            capabilities: capabilities(for: controller),
            vendorName: controller.vendorName,
            productCategory: controller.productCategory
        )))
        emitState(for: controller, forceHostState: true)
        emitBattery(for: controller, force: true)
    }

    private func announceMergedConnection() {
        let orderedEntries = entries.values.sorted { $0.slotIndex < $1.slotIndex }
        let metadata = ControllerMetadataMerger.merge(orderedEntries.map {
            ControllerMetadata(
                family: family(for: $0.controller),
                supportedButtons: supportedButtons(for: $0.controller),
                capabilities: capabilities(for: $0.controller)
            )
        })
        switch ControllerMetadataRebindPlanner.action(from: announcedMergedMetadata, to: metadata) {
        case .stateOnly:
            emitMergedState()
            return
        case .departure:
            emitMergedState()
            announcedMergedMetadata = nil
            return
        case .arrival:
            break
        }
        guard let metadata else { return }
        sink?.platformInputDidProduce(.controllerArrival(.init(
            playerIndex: 0,
            activeControllerMask: 1,
            family: metadata.family,
            supportedButtons: metadata.supportedButtons,
            capabilities: metadata.capabilities,
            vendorName: nil,
            productCategory: "Merged controllers"
        )))
        announcedMergedMetadata = metadata
        emitMergedState()
        for entry in orderedEntries { emitBattery(for: entry.controller, force: true) }
    }

    private func remapConnectedControllers() {
        let orderedIDs = entries.keys.sorted {
            (entries[$0]?.slotIndex ?? .max) < (entries[$1]?.slotIndex ?? .max)
        }
        neutralizeFeedback()
        if !orderedIDs.isEmpty {
            sink?.platformInputDidProduce(.controller(ControllerStateMapper.packet(
                sample: .init(),
                playerIndex: 0,
                activeControllerMask: 0
            )))
        }
        announcedMergedMetadata = nil
        for id in orderedIDs {
            guard var entry = entries[id] else { continue }
            entry.playerIndex = ControllerPlayerAssignment.playerIndex(
                slotIndex: entry.slotIndex,
                multiControllerEnabled: multiControllerEnabled
            )
            entries[id] = entry
        }
        if multiControllerEnabled {
            for id in orderedIDs {
                guard let controller = entries[id]?.controller else { continue }
                announceConnection(controller)
            }
        } else {
            announceMergedConnection()
        }
    }

    private func disconnect(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard var entry = entries[id] else { return }
        endActiveTouches(in: &entry)
        for output in entry.interaction.reset() {
            forwardResetOutput(output, to: sink)
        }
        neutralizeFeedback(for: controller, playerIndex: entry.playerIndex)
        entries.removeValue(forKey: id)
        clearHandlers(on: controller)
        _ = registry.remove(id)
        if multiControllerEnabled {
            sink?.platformInputDidProduce(.controller(.init(
                playerIndex: entry.playerIndex,
                activeControllerMask: registry.activeMask,
                buttons: [],
                leftTrigger: 0,
                rightTrigger: 0,
                leftStickX: 0,
                leftStickY: 0,
                rightStickX: 0,
                rightStickY: 0
            )))
        } else {
            announceMergedConnection()
        }
        synchronizeMousePollingTimer()
        synchronizeNavigationRepeatTimer()
    }

    private func installHandlers(on controller: GCController) {
        controller.extendedGamepad?.valueChangedHandler = { [weak self, weak controller] _, _ in
            guard let controller else { return }
            MainActor.assumeIsolated { self?.emitState(for: controller) }
        }
        installTouchpadHandlers(on: controller)
        configureMotion(for: controller, enabled: reportsMotion)
    }

    private func clearHandlers(on controller: GCController) {
        controller.extendedGamepad?.valueChangedHandler = nil
        controller.motion?.valueChangedHandler = nil
        for touchpad in physicalTouchpads(for: controller) {
            touchpad.touchDown = nil
            touchpad.touchMoved = nil
            touchpad.touchUp = nil
        }
        if let dualShock = controller.extendedGamepad as? GCDualShockGamepad {
            dualShock.touchpadPrimary.valueChangedHandler = nil
            dualShock.touchpadSecondary.valueChangedHandler = nil
        }
        if let dualSense = controller.extendedGamepad as? GCDualSenseGamepad {
            dualSense.touchpadPrimary.valueChangedHandler = nil
            dualSense.touchpadSecondary.valueChangedHandler = nil
        }
    }

    private func emitState(for controller: GCController, forceHostState: Bool = false) {
        guard applicationActive || allowsBackgroundInput,
              let gamepad = controller.extendedGamepad,
              let entry = entries[ObjectIdentifier(controller)]
        else { return }

        var buttons: ControllerButtonMask = []
        let a = swapFaceButtons ? gamepad.buttonB : gamepad.buttonA
        let b = swapFaceButtons ? gamepad.buttonA : gamepad.buttonB
        let x = swapFaceButtons ? gamepad.buttonY : gamepad.buttonX
        let y = swapFaceButtons ? gamepad.buttonX : gamepad.buttonY
        insert(a, .a, into: &buttons)
        insert(b, .b, into: &buttons)
        insert(x, .x, into: &buttons)
        insert(y, .y, into: &buttons)
        insert(gamepad.leftShoulder, .leftShoulder, into: &buttons)
        insert(gamepad.rightShoulder, .rightShoulder, into: &buttons)
        insert(gamepad.buttonMenu, .start, into: &buttons)
        if let button = gamepad.buttonOptions { insert(button, .back, into: &buttons) }
        if let button = gamepad.buttonHome { insert(button, .guide, into: &buttons) }
        if let button = gamepad.leftThumbstickButton { insert(button, .leftStick, into: &buttons) }
        if let button = gamepad.rightThumbstickButton { insert(button, .rightStick, into: &buttons) }
        insert(gamepad.dpad.up, .dpadUp, into: &buttons)
        insert(gamepad.dpad.down, .dpadDown, into: &buttons)
        insert(gamepad.dpad.left, .dpadLeft, into: &buttons)
        insert(gamepad.dpad.right, .dpadRight, into: &buttons)

        if let dualShock = gamepad as? GCDualShockGamepad {
            insert(dualShock.touchpadButton, .touchpad, into: &buttons)
        } else if let dualSense = gamepad as? GCDualSenseGamepad {
            insert(dualSense.touchpadButton, .touchpad, into: &buttons)
        }

        let sample = ControllerStateSample(
            buttons: buttons,
            leftTrigger: gamepad.leftTrigger.value,
            rightTrigger: gamepad.rightTrigger.value,
            leftStickX: gamepad.leftThumbstick.xAxis.value,
            leftStickY: gamepad.leftThumbstick.yAxis.value,
            rightStickX: gamepad.rightThumbstick.xAxis.value,
            rightStickY: gamepad.rightThumbstick.yAxis.value
        )
        var updatedEntry = entry
        let now = ProcessInfo.processInfo.systemUptime
        let interactionOutputs = updatedEntry.interaction.update(
            sample,
            at: now,
            gamepadMouseEnabled: gamepadMouseEnabled
        )
        let navigationEvents = updatedEntry.navigation.events(
            for: sample,
            at: now,
            mode: navigationMode
        )
        entries[ObjectIdentifier(controller)] = updatedEntry
        for event in navigationEvents { navigationHandler?(event) }
        let emittedHostState = interactionOutputs.contains {
            if case .hostState = $0 { return true }
            return false
        }
        for output in interactionOutputs {
            forward(output, playerIndex: entry.playerIndex)
        }
        if forceHostState, !emittedHostState {
            emitHostState(updatedEntry.interaction.hostSample, playerIndex: entry.playerIndex)
        }
        synchronizeMousePollingTimer()
        synchronizeNavigationRepeatTimer()
        emitBattery(for: controller)
    }

    private func emitMergedState(to target: PlatformInputPacketSink? = nil) {
        let samples = entries.values
            .sorted { $0.slotIndex < $1.slotIndex }
            .map(\.interaction.hostSample)
        let merged = ControllerStateMerger.merge(samples)
        (target ?? sink)?.platformInputDidProduce(.controller(ControllerStateMapper.packet(
            sample: merged,
            playerIndex: 0,
            activeControllerMask: entries.isEmpty ? 0 : 1
        )))
    }

    private func forward(_ output: ControllerInteractionOutput, playerIndex: UInt8) {
        switch output {
        case .hostState(let sample):
            emitHostState(sample, playerIndex: playerIndex)
        case .mouseButton(let packet):
            sink?.platformInputDidProduce(.mouseButton(packet))
        case .scroll(let packet):
            sink?.platformInputDidProduce(.scroll(packet))
        case .localAction(let action):
            localActionHandler?(action)
        }
    }

    private func emitHostState(_ sample: ControllerStateSample, playerIndex: UInt8) {
        if multiControllerEnabled {
            sink?.platformInputDidProduce(.controller(ControllerStateMapper.packet(
                sample: sample,
                playerIndex: playerIndex,
                activeControllerMask: registry.activeMask
            )))
        } else {
            emitMergedState()
        }
    }

    private func synchronizeMousePollingTimer() {
        let shouldPoll = entries.values.contains { $0.interaction.mouseModeActive }
        if shouldPoll, mousePollingTimer == nil {
            let timer = Timer(timeInterval: ControllerInteractionStateMachine.mousePollingInterval, repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.pollMouseMovement() }
            }
            RunLoop.main.add(timer, forMode: .common)
            mousePollingTimer = timer
        } else if !shouldPoll {
            mousePollingTimer?.invalidate()
            mousePollingTimer = nil
        }
    }

    private func pollMouseMovement() {
        for entry in entries.values.sorted(by: { $0.slotIndex < $1.slotIndex }) {
            guard let movement = entry.interaction.mouseMovement() else { continue }
            sink?.platformInputDidProduce(.mouseMove(movement))
        }
    }

    private func synchronizeNavigationRepeatTimer() {
        let shouldRepeat = entries.values.contains { $0.navigation.hasPendingAnalogRepeat }
        if shouldRepeat, navigationRepeatTimer == nil {
            let timer = Timer(
                timeInterval: ControllerNavigationStateMachine.defaultAnalogRepeatInterval,
                repeats: true
            ) { [weak self] timer in
                guard self != nil else {
                    timer.invalidate()
                    return
                }
                MainActor.assumeIsolated { self?.pollNavigationRepeats() }
            }
            RunLoop.main.add(timer, forMode: .common)
            navigationRepeatTimer = timer
        } else if !shouldRepeat {
            navigationRepeatTimer?.invalidate()
            navigationRepeatTimer = nil
        }
    }

    private func pollNavigationRepeats() {
        let now = ProcessInfo.processInfo.systemUptime
        let orderedIDs = entries.keys.sorted {
            (entries[$0]?.slotIndex ?? .max) < (entries[$1]?.slotIndex ?? .max)
        }
        for id in orderedIDs {
            guard var entry = entries[id] else { continue }
            let events = entry.navigation.repeatedAnalogEvents(at: now, mode: navigationMode)
            entries[id] = entry
            for event in events { navigationHandler?(event) }
        }
        synchronizeNavigationRepeatTimer()
    }

    private func emitBattery(for controller: GCController, force: Bool = false) {
        let id = ObjectIdentifier(controller)
        guard var entry = entries[id], let battery = controller.battery else { return }
        let state: ControllerBatteryState
        switch battery.batteryState {
        case .discharging: state = .discharging
        case .charging: state = .charging
        case .full: state = .full
        default: state = .unknown
        }
        let level = battery.batteryLevel.isFinite
            ? UInt8((min(max(battery.batteryLevel, 0), 1) * 100).rounded())
            : nil
        let packet = ControllerBatteryPacket(playerIndex: entry.playerIndex, state: state, percentage: level)
        guard force || packet != entry.lastBattery else { return }
        entry.lastBattery = packet
        entries[id] = entry
        sink?.platformInputDidProduce(.controllerBattery(packet))
    }

    private func configureMotion(for controller: GCController, enabled: Bool) {
        guard let motion = controller.motion else { return }
        if motion.sensorsRequireManualActivation { motion.sensorsActive = enabled }
        motion.valueChangedHandler = enabled ? { [weak self, weak controller] motion in
            guard let controller else { return }
            let acceleration = motion.acceleration
            let rotation = motion.rotationRate
            Task { @MainActor [weak self] in
                guard let self,
                      self.applicationActive || self.allowsBackgroundInput,
                      let entry = self.entries[ObjectIdentifier(controller)]
                else { return }
                self.sink?.platformInputDidProduce(.controllerMotion(.init(
                    playerIndex: entry.playerIndex,
                    kind: .accelerometer,
                    x: Float(acceleration.x), y: Float(acceleration.y), z: Float(acceleration.z)
                )))
                if motion.hasRotationRate {
                    let radiansToDegrees = Float(180 / Double.pi)
                    self.sink?.platformInputDidProduce(.controllerMotion(.init(
                        playerIndex: entry.playerIndex,
                        kind: .gyroscope,
                        x: Float(rotation.x) * radiansToDegrees,
                        y: Float(rotation.y) * radiansToDegrees,
                        z: Float(rotation.z) * radiansToDegrees
                    )))
                }
            }
        } : nil
    }

    private func installTouchpadHandlers(on controller: GCController) {
        let physicalTouchpads = physicalTouchpads(for: controller)
        if !physicalTouchpads.isEmpty {
            for (index, touchpad) in physicalTouchpads.enumerated() {
                installLifecycleHandlers(
                    on: touchpad,
                    controller: controller,
                    touchpadIndex: UInt8(clamping: index)
                )
            }
            return
        }

        func installLegacy(_ pad: GCControllerDirectionPad, fingerIndex: UInt8) {
            pad.valueChangedHandler = { [weak self, weak controller] _, x, y in
                guard let controller else { return }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.applicationActive || self.allowsBackgroundInput,
                          let entry = self.entries[ObjectIdentifier(controller)]
                    else { return }
                    // DualShock/DualSense's legacy extended profile exposes only
                    // coordinates. Do not fabricate contact begin/end or pressure.
                    let event = ControllerTouchContactEvent(
                        id: .init(touchpadIndex: 0, fingerIndex: fingerIndex),
                        phase: .moved,
                        x: x,
                        y: y,
                        pressure: 0
                    )
                    self.sink?.platformInputDidProduce(.controllerTouch(
                        ControllerTouchMapper.packet(playerIndex: entry.playerIndex, event: event)
                    ))
                }
            }
        }

        if let gamepad = controller.extendedGamepad as? GCDualSenseGamepad {
            installLegacy(gamepad.touchpadPrimary, fingerIndex: 0)
            installLegacy(gamepad.touchpadSecondary, fingerIndex: 1)
        } else if let gamepad = controller.extendedGamepad as? GCDualShockGamepad {
            installLegacy(gamepad.touchpadPrimary, fingerIndex: 0)
            installLegacy(gamepad.touchpadSecondary, fingerIndex: 1)
        }
    }

    private func installLifecycleHandlers(
        on touchpad: GCControllerTouchpad,
        controller: GCController,
        touchpadIndex: UInt8
    ) {
        touchpad.reportsAbsoluteTouchSurfaceValues = true
        touchpad.touchDown = { [weak self, weak controller] _, x, y, _, _ in
            guard let controller else { return }
            Task { @MainActor [weak self] in
                self?.emitTrackedTouch(
                    for: controller,
                    touchpadIndex: touchpadIndex,
                    phase: .began,
                    x: x,
                    y: y
                )
            }
        }
        touchpad.touchMoved = { [weak self, weak controller] _, x, y, _, _ in
            guard let controller else { return }
            Task { @MainActor [weak self] in
                self?.emitTrackedTouch(
                    for: controller,
                    touchpadIndex: touchpadIndex,
                    phase: .moved,
                    x: x,
                    y: y
                )
            }
        }
        touchpad.touchUp = { [weak self, weak controller] _, x, y, _, _ in
            guard let controller else { return }
            Task { @MainActor [weak self] in
                self?.emitTrackedTouch(
                    for: controller,
                    touchpadIndex: touchpadIndex,
                    phase: .ended,
                    x: x,
                    y: y
                )
            }
        }
    }

    private func emitTrackedTouch(
        for controller: GCController,
        touchpadIndex: UInt8,
        phase: ControllerTouchPhase,
        x: Float,
        y: Float
    ) {
        guard applicationActive || allowsBackgroundInput else { return }
        let id = ObjectIdentifier(controller)
        guard var entry = entries[id] else { return }
        let event = ControllerTouchContactEvent(
            id: .init(touchpadIndex: touchpadIndex, fingerIndex: 0),
            phase: phase,
            x: x,
            y: y,
            pressure: 0
        )
        let lifecycleEvents = entry.touchLifecycle.handle(event)
        entries[id] = entry
        for lifecycleEvent in lifecycleEvents {
            sink?.platformInputDidProduce(.controllerTouch(
                ControllerTouchMapper.packet(playerIndex: entry.playerIndex, event: lifecycleEvent)
            ))
        }
    }

    private func endActiveTouches(in entry: inout Entry, to target: PlatformInputPacketSink? = nil) {
        let target = target ?? sink
        for event in entry.touchLifecycle.endAllContacts() {
            target?.platformInputDidProduce(.controllerTouch(
                ControllerTouchMapper.packet(playerIndex: entry.playerIndex, event: event)
            ))
        }
    }

    private func releaseAllInputs(to target: PlatformInputPacketSink?) {
        guard !entries.isEmpty else { return }
        let target = target ?? sink
        let orderedIDs = entries.keys.sorted {
            (entries[$0]?.slotIndex ?? .max) < (entries[$1]?.slotIndex ?? .max)
        }
        for id in orderedIDs {
            guard var entry = entries[id] else { continue }
            endActiveTouches(in: &entry, to: target)
            for output in entry.interaction.reset() {
                forwardResetOutput(output, to: target)
            }
            entry.navigation.reset()
            entries[id] = entry
        }
        synchronizeMousePollingTimer()
        synchronizeNavigationRepeatTimer()
        for packet in Self.neutralControllerPackets(
            playerIndices: orderedIDs.compactMap { entries[$0]?.playerIndex },
            multiControllerEnabled: multiControllerEnabled,
            activeControllerMask: registry.activeMask
        ) {
            target?.platformInputDidProduce(.controller(packet))
        }
    }

    private func forwardResetOutput(
        _ output: ControllerInteractionOutput,
        to target: PlatformInputPacketSink?
    ) {
        switch output {
        case .hostState:
            break
        case .mouseButton(let packet):
            target?.platformInputDidProduce(.mouseButton(packet))
        case .scroll(let packet):
            target?.platformInputDidProduce(.scroll(packet))
        case .localAction(let action):
            localActionHandler?(action)
        }
    }

    static func neutralControllerPackets(
        playerIndices: [UInt8],
        multiControllerEnabled: Bool,
        activeControllerMask: UInt16
    ) -> [ControllerPacket] {
        guard !playerIndices.isEmpty else { return [] }
        if multiControllerEnabled {
            return playerIndices.map {
                ControllerStateMapper.packet(
                    sample: .init(),
                    playerIndex: $0,
                    activeControllerMask: activeControllerMask
                )
            }
        }
        return [ControllerStateMapper.packet(
            sample: .init(),
            playerIndex: 0,
            activeControllerMask: 1
        )]
    }

    /// Complete output reset shared by stream finish/cancel, sink replacement,
    /// service shutdown, controller remapping, and physical device removal.
    static let feedbackNeutralizationCommands: [ControllerOutputCommand] = [
        .rumble(lowFrequency: 0, highFrequency: 0),
        .triggerRumble(left: 0, right: 0),
        .adaptiveTriggers(left: .off, right: .off),
        .led(red: 0, green: 0, blue: 0),
    ]

    private func physicalTouchpads(for controller: GCController) -> [GCControllerTouchpad] {
        var seen: Set<ObjectIdentifier> = []
        return controller.physicalInputProfile.touchpads
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .compactMap { _, touchpad in
                let id = ObjectIdentifier(touchpad)
                guard seen.insert(id).inserted else { return nil }
                return touchpad
            }
    }

    private func supportedButtons(for controller: GCController) -> ControllerButtonMask {
        guard let gamepad = controller.extendedGamepad else { return [] }
        var buttons: ControllerButtonMask = [
            .a, .b, .x, .y, .leftShoulder, .rightShoulder,
            .start, .dpadUp, .dpadDown, .dpadLeft, .dpadRight,
        ]
        if gamepad.buttonOptions != nil { buttons.insert(.back) }
        if gamepad.buttonHome != nil { buttons.insert(.guide) }
        if gamepad.leftThumbstickButton != nil { buttons.insert(.leftStick) }
        if gamepad.rightThumbstickButton != nil { buttons.insert(.rightStick) }
        if !physicalTouchpads(for: controller).isEmpty ||
            gamepad is GCDualShockGamepad || gamepad is GCDualSenseGamepad {
            buttons.insert(.touchpad)
        }
        return buttons
    }

    private func capabilities(for controller: GCController) -> ControllerCapabilities {
        var result: ControllerCapabilities = []
        if controller.extendedGamepad != nil { result.insert(.analogTriggers) }
        if let haptics = controller.haptics {
            result.insert(.rumble)
            if haptics.supportedLocalities.contains(.leftTrigger) ||
                haptics.supportedLocalities.contains(.rightTrigger) {
                result.insert(.triggerRumble)
            }
        }
        let touchpadCount = physicalTouchpads(for: controller).count
        if touchpadCount > 0 ||
            controller.extendedGamepad is GCDualShockGamepad ||
            controller.extendedGamepad is GCDualSenseGamepad {
            result.insert(.touchpad)
        }
        if touchpadCount > 1 {
            result.insert(.dualTouchpad)
        }
        if let motion = controller.motion {
            result.insert(.accelerometer)
            if motion.hasRotationRate { result.insert(.gyroscope) }
        }
        if controller.battery != nil { result.insert(.battery) }
        if controller.light != nil { result.insert(.rgbLED) }
        if controller.extendedGamepad is GCDualSenseGamepad { result.insert(.adaptiveTriggers) }
        return result
    }

    private func family(for controller: GCController) -> ControllerFamily {
        let category = controller.productCategory.lowercased()
        if category.contains("xbox") { return .xbox }
        if category.contains("dualshock") || category.contains("dualsense") || category.contains("playstation") {
            return .playStation
        }
        if category.contains("switch") || category.contains("joy-con") { return .nintendo }
        return .unknown
    }

    private func entry(forPlayer playerIndex: UInt8) -> Entry? {
        guard let slotIndex = Self.feedbackSlot(
            forPlayer: playerIndex,
            assignments: entries.values.map { ($0.slotIndex, $0.playerIndex) }
        ) else { return nil }
        return entries.values.first { $0.slotIndex == slotIndex }
    }

    static func feedbackSlot(
        forPlayer playerIndex: UInt8,
        assignments: [(slotIndex: UInt8, playerIndex: UInt8)]
    ) -> UInt8? {
        assignments.lazy
            .filter { $0.playerIndex == playerIndex }
            .map(\.slotIndex)
            .min()
    }

    private func assignFrameworkPlayerIndex(_ index: UInt8, to controller: GCController) {
        switch index {
        case 0: controller.playerIndex = .index1
        case 1: controller.playerIndex = .index2
        case 2: controller.playerIndex = .index3
        case 3: controller.playerIndex = .index4
        default: controller.playerIndex = .indexUnset
        }
    }

    private func insert(_ button: GCControllerButtonInput, _ mask: ControllerButtonMask, into buttons: inout ControllerButtonMask) {
        if button.isPressed { buttons.insert(mask) }
    }

    private func apply(_ effect: AdaptiveTriggerEffect, to trigger: GCDualSenseAdaptiveTrigger) {
        switch effect {
        case .off:
            trigger.setModeOff()
        case .feedback(let start, let strength):
            trigger.setModeFeedbackWithStartPosition(start, resistiveStrength: strength)
        case .weapon(let start, let end, let strength):
            trigger.setModeWeaponWithStartPosition(start, endPosition: end, resistiveStrength: strength)
        case .vibration(let start, let amplitude, let frequency):
            trigger.setModeVibrationWithStartPosition(start, amplitude: amplitude, frequency: frequency)
        }
    }

    private func neutralizeFeedback() {
        let orderedEntries = entries.values.sorted { $0.slotIndex < $1.slotIndex }
        for entry in orderedEntries {
            neutralizeFeedback(for: entry.controller, playerIndex: entry.playerIndex)
        }
        // Handles partially-created engines whose controller disappeared before
        // it could be matched to a current registry entry.
        stopHaptics()
    }

    private func neutralizeFeedback(for controller: GCController, playerIndex: UInt8) {
        stopHaptics(for: playerIndex)
        for command in Self.feedbackNeutralizationCommands {
            _ = apply(command, to: controller, playerIndex: playerIndex)
        }
    }

    private func playHaptics(
        controller: GCController,
        playerIndex: UInt8,
        values: [(locality: GCHapticsLocality, intensity: Float, sharpness: Float)]
    ) -> ControllerOutputResult {
        guard let haptics = controller.haptics else { return .unsupported }
        let nonZeroValues = values.filter { $0.intensity > 0 }
        stopHaptics(for: playerIndex)
        guard !nonZeroValues.isEmpty else { return .applied }

        do {
            var engines: [CHHapticEngine] = []
            var players: [any CHHapticPatternPlayer] = []
            for value in nonZeroValues {
                guard haptics.supportedLocalities.contains(value.locality),
                      let engine = haptics.createEngine(withLocality: value.locality)
                else { continue }
                try engine.start()
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        .init(parameterID: .hapticIntensity, value: value.intensity),
                        .init(parameterID: .hapticSharpness, value: value.sharpness),
                    ],
                    relativeTime: 0,
                    duration: Self.maximumHapticDuration
                )
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: 0)
                engines.append(engine)
                players.append(player)
            }
            guard !players.isEmpty else { return .unsupported }
            hapticEngines[playerIndex] = engines
            hapticPlayers[playerIndex] = players
            let lease = hapticLeases.start(for: playerIndex)
            hapticTimeoutTasks[playerIndex] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Self.maximumHapticDuration))
                } catch {
                    return
                }
                guard let self, self.hapticLeases.isCurrent(lease, for: playerIndex) else { return }
                self.stopHaptics(for: playerIndex)
            }
            return .applied
        } catch {
            stopHaptics(for: playerIndex)
            return .failed(error.localizedDescription)
        }
    }

    private func stopHaptics(for playerIndex: UInt8) {
        hapticTimeoutTasks.removeValue(forKey: playerIndex)?.cancel()
        hapticLeases.cancel(for: playerIndex)
        for player in hapticPlayers.removeValue(forKey: playerIndex) ?? [] {
            try? player.stop(atTime: 0)
        }
        for engine in hapticEngines.removeValue(forKey: playerIndex) ?? [] { engine.stop() }
    }

    private func stopHaptics() {
        let playerIndices = Set(hapticEngines.keys).union(hapticTimeoutTasks.keys)
        for playerIndex in playerIndices { stopHaptics(for: playerIndex) }
    }
}
