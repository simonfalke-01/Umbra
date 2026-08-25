import Foundation
import UmbraPlatform
import UmbraProtocolV3
import UmbraQUICTransport

public enum ProtocolV3InputError: Error, Equatable, Sendable {
    case closed
    case invalidCommand
    case sequenceExhausted
    case edgeWindowPressure
}

/// Builds v3 state-format-2 snapshots and repeats unacknowledged ordered edge
/// IDs until the host's authenticated input ACK advances past them.
public final class ProtocolV3InputStateSender: @unchecked Sendable {
    private struct Edge {
        let id: UInt64
        let time: UInt64
        let kind: UInt8
        let device: UInt8
        let code: UInt16
        let value: Int32
        let auxiliary: UInt32

        var encoded: Data {
            var data = Data()
            data.appendInteger(id)
            data.appendInteger(time)
            data.append(kind)
            data.append(device)
            data.appendInteger(code)
            data.appendInteger(UInt32(bitPattern: value))
            data.appendInteger(auxiliary)
            data.appendInteger(UInt32(0))
            return data
        }
    }

    private struct ControllerState {
        var type: UInt8 = 5
        var flags: UInt16 = 0
        var buttons: UInt64 = 0
        var leftTrigger: UInt16 = 0
        var rightTrigger: UInt16 = 0
        var leftX: Int16 = 0
        var leftY: Int16 = 0
        var rightX: Int16 = 0
        var rightY: Int16 = 0
        var gyro = (Int32(0), Int32(0), Int32(0))
        var acceleration = (Int32(0), Int32(0), Int32(0))
        var battery: UInt16 = .max
        var batteryState: UInt8 = 0
        var supportedButtons: UInt32 = 0

        func encoded(id: UInt8) -> Data {
            var data = Data()
            data.append(id)
            data.append(type)
            data.appendInteger(flags)
            data.appendInteger(buttons)
            data.appendInteger(leftTrigger)
            data.appendInteger(rightTrigger)
            for value in [leftX, leftY, rightX, rightY] {
                data.appendInteger(UInt16(bitPattern: value))
            }
            for value in [gyro.0, gyro.1, gyro.2, acceleration.0, acceleration.1, acceleration.2] {
                data.appendInteger(UInt32(bitPattern: value))
            }
            data.appendInteger(battery)
            data.append(batteryState)
            data.append(0)
            data.appendInteger(supportedButtons)
            data.appendInteger(UInt64(0))
            return data
        }
    }

    private struct TouchState {
        var phase: UInt8
        var x: Float
        var y: Float
        var pressure: Float

        func encoded(id: UInt32) -> Data {
            var data = Data()
            data.appendInteger(id)
            data.append(phase)
            data.append(1)
            data.appendInteger(Self.q16(pressure))
            data.appendInteger(Self.q32(x))
            data.appendInteger(Self.q32(y))
            data.appendInteger(UInt16(0))
            data.appendInteger(UInt16(0))
            data.appendInteger(UInt16(0))
            data.appendInteger(UInt16(0))
            data.appendInteger(UInt32(0))
            data.appendInteger(UInt32(0))
            return data
        }

        private static func q16(_ value: Float) -> UInt16 {
            UInt16(clamping: Int((min(max(value, 0), 1) * Float(UInt16.max)).rounded()))
        }

        private static func q32(_ value: Float) -> UInt32 {
            UInt32(clamping: UInt64((Double(min(max(value, 0), 1)) * Double(UInt32.max)).rounded()))
        }
    }

    private let session: any ProtocolV3SessionMediaControlling
    private let sessionID: Data
    private let mode: QUICOptimizationMode
    private let failureHandler: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var inputGeneration: UInt32
    private var stateSequence: UInt64 = 0
    private var nextEdgeID: UInt64 = 1
    private var lastAcknowledgedEdgeID: UInt64 = 0
    private var edges: [Edge] = []
    private var keyboard = Data(repeating: 0, count: 32)
    private var mouseButtons: UInt32 = 0
    private var relativeX: Int64 = 0
    private var relativeY: Int64 = 0
    private var verticalWheel: Int64 = 0
    private var horizontalWheel: Int64 = 0
    private var absoluteX: UInt32 = 0
    private var absoluteY: UInt32 = 0
    private var usesAbsolutePointer: Bool
    private var controllers: [UInt8: ControllerState] = [:]
    private var controllerGenerations: [UInt8: UInt32] = [:]
    private var touches: [UInt32: TouchState] = [:]
    private var initialBaseline = true
    private var closed = false
    private var failureReported = false
    private var retryTask: Task<Void, Never>?
    private var nextCompositionID: UInt64 = 1
    private var nextTextOperationID: UInt64 = 1

    public init(
        session: any ProtocolV3SessionMediaControlling,
        sessionID: Data,
        mode: QUICOptimizationMode,
        usesAbsolutePointer: Bool,
        inputGeneration: UInt32 = 1,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) {
        self.session = session
        self.sessionID = sessionID
        self.mode = mode
        self.usesAbsolutePointer = usesAbsolutePointer
        self.inputGeneration = inputGeneration
        self.failureHandler = failureHandler
    }

    deinit { stop() }

    public func start() throws {
        try transmitSnapshot()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(self?.mode == .latency ? 8 : 12))
                } catch {
                    return
                }
                guard let self, self.hasUnacknowledgedEdges else { continue }
                do {
                    try self.transmitSnapshot()
                } catch {
                    self.reportTerminalFailure(error)
                    return
                }
            }
        }
    }

    public func send(_ command: StreamInputCommand) throws {
        if case let .text(text) = command {
            try sendText(text)
            return
        }
        try lock.withLock {
            guard !closed else { throw ProtocolV3InputError.closed }
            let now = Self.monotonicMicroseconds()
            switch command {
            case let .keyboard(keyCode, action, _, _):
                let usage = UInt8(truncatingIfNeeded: keyCode)
                let down = action == 0x03
                guard down || action == 0x04 else { throw ProtocolV3InputError.invalidCommand }
                keyboard[Int(usage) / 8] = down
                    ? keyboard[Int(usage) / 8] | (1 << (usage % 8))
                    : keyboard[Int(usage) / 8] & ~(1 << (usage % 8))
                try appendEdge(time: now, kind: 1, device: 0, code: UInt16(usage), value: down ? 1 : 0)
            case let .mouseMove(deltaX, deltaY):
                usesAbsolutePointer = false
                relativeX = try Self.add(relativeX, Int64(deltaX))
                relativeY = try Self.add(relativeY, Int64(deltaY))
                absoluteX = 0
                absoluteY = 0
            case let .mousePosition(x, y, referenceWidth, referenceHeight):
                guard referenceWidth > 0, referenceHeight > 0 else { throw ProtocolV3InputError.invalidCommand }
                usesAbsolutePointer = true
                relativeX = 0
                relativeY = 0
                absoluteX = Self.q32(Int(x), maximum: Int(referenceWidth))
                absoluteY = Self.q32(Int(y), maximum: Int(referenceHeight))
            case let .mouseButton(action, button):
                guard let code = UInt16(exactly: button), (1...5).contains(code) else {
                    throw ProtocolV3InputError.invalidCommand
                }
                let down = action == 0x07
                guard down || action == 0x08 else { throw ProtocolV3InputError.invalidCommand }
                let bit = UInt32(1) << UInt32(code - 1)
                mouseButtons = down ? mouseButtons | bit : mouseButtons & ~bit
                try appendEdge(time: now, kind: 2, device: 0, code: code, value: down ? 1 : 0)
            case let .scroll(vertical, horizontal):
                verticalWheel = try Self.add(verticalWheel, Int64(vertical))
                horizontalWheel = try Self.add(horizontalWheel, Int64(horizontal))
            case let .touch(pointerID, eventType, x, y, pressure):
                try updateTouch(
                    pointerID: pointerID,
                    eventType: eventType,
                    x: x,
                    y: y,
                    pressure: pressure,
                    time: now
                )
            case let .controller(number, activeMask, buttons, leftTrigger, rightTrigger, leftX, leftY, rightX, rightY):
                guard let id = UInt8(exactly: number), id < 16 else { throw ProtocolV3InputError.invalidCommand }
                var controller = controllers[id] ?? ControllerState()
                let nextButtons = UInt64(UInt32(bitPattern: buttons))
                let changed = controller.buttons ^ nextButtons
                for bit in 0..<32 where changed & (UInt64(1) << bit) != 0 {
                    try appendEdge(
                        time: now, kind: 3, device: id, code: UInt16(bit),
                        value: nextButtons & (UInt64(1) << bit) != 0 ? 1 : 0
                    )
                }
                controller.buttons = nextButtons
                controller.leftTrigger = UInt16(leftTrigger) * 257
                controller.rightTrigger = UInt16(rightTrigger) * 257
                controller.leftX = leftX; controller.leftY = leftY
                controller.rightX = rightX; controller.rightY = rightY
                controllers[id] = controller
                let mask = UInt16(bitPattern: activeMask)
                for existing in controllers.keys where mask & (UInt16(1) << existing) == 0 {
                    controllers[existing] = nil
                }
            case let .controllerArrival(number, _, type, supportedButtons, capabilities):
                guard number < 16 else { throw ProtocolV3InputError.invalidCommand }
                let normalizedType = (1...5).contains(type) ? type : 5
                let normalizedCapabilities = capabilities & 0x01FF
                let normalizedButtons = supportedButtons & 0x003F_FFFF
                if let existing = controllers[number] {
                    guard existing.type == normalizedType,
                          existing.flags == normalizedCapabilities,
                          existing.supportedButtons == normalizedButtons else {
                        throw ProtocolV3InputError.invalidCommand
                    }
                    break
                }
                let generation = try Self.incrementedGeneration(controllerGenerations[number] ?? 0)
                controllerGenerations[number] = generation
                var controller = ControllerState()
                controller.type = normalizedType
                controller.flags = normalizedCapabilities
                controller.supportedButtons = normalizedButtons
                controllers[number] = controller
                try appendEdge(
                    time: now, kind: 4, device: number, code: controller.flags,
                    value: Int32(controller.type), auxiliary: controller.supportedButtons
                )
            case let .controllerTouch(number, eventType, touchpadIndex, pointerID, x, y, pressure):
                guard number < 16, touchpadIndex < 2, pointerID <= 0xFFFF else {
                    throw ProtocolV3InputError.invalidCommand
                }
                let composite = UInt32(number + 1) << 24
                    | UInt32(touchpadIndex) << 16
                    | pointerID
                try updateTouch(
                    pointerID: composite,
                    eventType: eventType,
                    x: x,
                    y: y,
                    pressure: pressure,
                    time: now
                )
            case let .controllerMotion(number, type, x, y, z):
                guard number < 16 else { throw ProtocolV3InputError.invalidCommand }
                var controller = controllers[number] ?? ControllerState()
                let values = (Self.q16_16(x), Self.q16_16(y), Self.q16_16(z))
                if type == 1 {
                    controller.acceleration = values
                    controller.flags |= 0x10
                } else if type == 2 {
                    controller.gyro = values
                    controller.flags |= 0x20
                } else {
                    throw ProtocolV3InputError.invalidCommand
                }
                controllers[number] = controller
            case let .controllerBattery(number, state, percentage):
                guard number < 16 else { throw ProtocolV3InputError.invalidCommand }
                var controller = controllers[number] ?? ControllerState()
                controller.flags |= 0x40
                controller.batteryState = min(state, 5)
                controller.battery = percentage == 0xFF ? .max : min(UInt16(percentage) * 100, 10_000)
                controllers[number] = controller
            case .text:
                break
            }
        }
        try transmitSnapshot()
    }

    public func handleInputAcknowledgement(_ message: QUICInboundMessage) throws {
        guard message.datagramChannel == 1, message.datagramKind == 2,
              message.payload.count == 48 else { throw ProtocolV3InputError.invalidCommand }
        let appliedEdgeID = Self.read(UInt64.self, message.payload, 16)
        acknowledge(appliedEdgeID: appliedEdgeID)
    }

    public func handleInputResynchronization(_ message: QUICInboundMessage) throws {
        guard message.datagramChannel == 1, message.datagramKind == 3,
              message.payload.count == 16 else { throw ProtocolV3InputError.invalidCommand }
        let expected = Self.read(UInt64.self, message.payload, 0)
        try resynchronize(expectedEdgeID: expected)
    }

    public func acknowledge(appliedEdgeID: UInt64) {
        lock.withLock {
            lastAcknowledgedEdgeID = max(lastAcknowledgedEdgeID, appliedEdgeID)
            edges.removeAll { $0.id <= appliedEdgeID }
        }
    }

    public func updateInputGeneration(_ generation: UInt32) throws {
        guard generation != 0 else { throw ProtocolV3InputError.invalidCommand }
        try lock.withLock {
            guard !closed else { throw ProtocolV3InputError.closed }
            inputGeneration = generation
        }
    }

    public func acceptsControllerFeedback(
        inputGeneration: UInt32,
        controller: UInt8,
        controllerGeneration: UInt32
    ) -> Bool {
        lock.withLock {
            !closed && self.inputGeneration == inputGeneration && controllers[controller] != nil
                && controllerGenerations[controller] == controllerGeneration
        }
    }

    public func inputResetStateBlock() throws -> Data {
        try lock.withLock {
            guard !closed else { throw ProtocolV3InputError.closed }
            return stateBlock()
        }
    }

    public func resynchronize(expectedEdgeID: UInt64) throws {
        lock.withLock { edges.removeAll { $0.id < expectedEdgeID } }
        try transmitSnapshot()
    }

    public func stop() {
        retryTask?.cancel()
        retryTask = nil
        lock.withLock {
            closed = true
            edges.removeAll()
            keyboard = Data(repeating: 0, count: 32)
            mouseButtons = 0
            controllers.removeAll()
            controllerGenerations.removeAll()
            touches.removeAll()
        }
    }

    private func reportTerminalFailure(_ error: Error) {
        let shouldReport = lock.withLock { () -> Bool in
            guard !closed, !failureReported else { return false }
            failureReported = true
            closed = true
            edges.removeAll()
            keyboard = Data(repeating: 0, count: 32)
            mouseButtons = 0
            controllers.removeAll()
            controllerGenerations.removeAll()
            touches.removeAll()
            return true
        }
        if shouldReport {
            failureHandler(error)
        }
    }

    private var hasUnacknowledgedEdges: Bool {
        lock.withLock { !closed && !edges.isEmpty }
    }

    private func transmitSnapshot() throws {
        let submission = try lock.withLock { () -> (Data, UInt64, Bool) in
            guard !closed else { throw ProtocolV3InputError.closed }
            guard stateSequence < UInt64.max else { throw ProtocolV3InputError.sequenceExhausted }
            stateSequence += 1
            let stateBlock = stateBlock()
            let maximumEdges = min(64, max(0, (1_108 - 32 - stateBlock.count) / 32))
            let representedEdges = Array(edges.prefix(maximumEdges))
            var payload = Data()
            payload.appendInteger(Self.monotonicMicroseconds())
            payload.appendInteger(representedEdges.last?.id ?? lastAcknowledgedEdgeID)
            payload.appendInteger(UInt16(stateBlock.count))
            payload.appendInteger(UInt16(representedEdges.count))
            payload.appendInteger(UInt16(2))
            payload.appendInteger(UInt16(2))
            payload.appendInteger(UInt64(0))
            payload.append(stateBlock)
            representedEdges.forEach { payload.append($0.encoded) }
            initialBaseline = false
            return (payload, stateSequence, !representedEdges.isEmpty)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        session.sendDatagram(
            lane: submission.2 ? .inputEdge : .inputState,
            sessionID: sessionID,
            channel: 1,
            kind: 1,
            flags: 0,
            objectID: submission.1,
            payload: submission.0,
            deadlineNanoseconds: now + (mode == .latency ? 8_000_000 : 12_000_000),
            supersessionKey: submission.2 ? nil : 1
        )
    }

    private func stateBlock() -> Data {
        var data = Data()
        var flags: UInt32 = usesAbsolutePointer ? 1 : 2
        if initialBaseline { flags |= 4 }
        data.appendInteger(flags)
        data.appendInteger(mouseButtons)
        data.appendInteger(UInt64(bitPattern: relativeX))
        data.appendInteger(UInt64(bitPattern: relativeY))
        data.appendInteger(UInt64(bitPattern: verticalWheel))
        data.appendInteger(UInt64(bitPattern: horizontalWheel))
        data.appendInteger(usesAbsolutePointer ? absoluteX : 0)
        data.appendInteger(usesAbsolutePointer ? absoluteY : 0)
        data.append(keyboard)
        let controllerIDs = controllers.keys.sorted()
        let touchIDs = touches.keys.sorted()
        let controllerMask = controllerIDs.reduce(UInt32(0)) { $0 | (UInt32(1) << $1) }
        data.appendInteger(controllerMask)
        data.append(UInt8(controllerIDs.count))
        data.append(UInt8(touchIDs.count))
        data.append(0)
        data.append(Data(repeating: 0, count: 25))
        controllerIDs.forEach { data.append(controllers[$0]!.encoded(id: $0)) }
        touchIDs.forEach { data.append(touches[$0]!.encoded(id: $0)) }
        return data
    }

    private func appendEdge(
        time: UInt64,
        kind: UInt8,
        device: UInt8,
        code: UInt16,
        value: Int32,
        auxiliary: UInt32 = 0
    ) throws {
        guard nextEdgeID < UInt64.max else { throw ProtocolV3InputError.sequenceExhausted }
        guard edges.count < 512 else { throw ProtocolV3InputError.edgeWindowPressure }
        edges.append(Edge(
            id: nextEdgeID,
            time: time,
            kind: kind,
            device: device,
            code: code,
            value: value,
            auxiliary: auxiliary
        ))
        nextEdgeID += 1
    }

    private func updateTouch(
        pointerID: UInt32,
        eventType: UInt8,
        x: Float,
        y: Float,
        pressure: Float,
        time: UInt64
    ) throws {
        switch eventType {
        case 1:
            touches[pointerID] = TouchState(phase: 2, x: x, y: y, pressure: pressure)
            try appendEdge(time: time, kind: 5, device: 0, code: 2, value: 1, auxiliary: pointerID)
        case 2:
            touches[pointerID] = nil
            try appendEdge(time: time, kind: 5, device: 0, code: 4, value: 0, auxiliary: pointerID)
        case 3:
            touches[pointerID] = TouchState(phase: 3, x: x, y: y, pressure: pressure)
        case 4:
            touches[pointerID] = nil
            try appendEdge(time: time, kind: 5, device: 0, code: 5, value: 0, auxiliary: pointerID)
        default:
            throw ProtocolV3InputError.invalidCommand
        }
    }

    private func sendText(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 4_096,
              text == text.precomposedStringWithCanonicalMapping else {
            throw ProtocolV3InputError.invalidCommand
        }
        let identifiers = try lock.withLock { () -> (UInt64, UInt64, UInt64) in
            guard !closed else { throw ProtocolV3InputError.closed }
            guard nextCompositionID < UInt64.max, nextTextOperationID < UInt64.max - 1 else {
                throw ProtocolV3InputError.sequenceExhausted
            }
            let value = (nextCompositionID, nextTextOperationID, nextTextOperationID + 1)
            nextCompositionID += 1
            nextTextOperationID += 2
            return value
        }
        let scalarCount = UInt64(text.unicodeScalars.count)
        _ = try session.sendControlRequest(type: 0x0122, fields: [
            1: .bytes(sessionID), 2: .unsigned(identifiers.0), 3: .unsigned(identifiers.1),
            4: .unsigned(0), 5: .unsigned(1), 6: .text(text),
            7: .unsigned(scalarCount), 8: .unsigned(0), 9: .null, 10: .unsigned(0),
        ])
        _ = try session.sendControlRequest(type: 0x0122, fields: [
            1: .bytes(sessionID), 2: .unsigned(identifiers.0), 3: .unsigned(identifiers.2),
            4: .unsigned(1), 5: .unsigned(3), 6: .text(text),
            7: .unsigned(scalarCount), 8: .unsigned(0), 9: .null, 10: .unsigned(0),
        ])
    }

    private static func add(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw ProtocolV3InputError.sequenceExhausted }
        return result.partialValue
    }

    private static func incrementedGeneration(_ generation: UInt32) throws -> UInt32 {
        guard generation < UInt32.max else { throw ProtocolV3InputError.sequenceExhausted }
        return generation + 1
    }

    private static func q32(_ value: Int, maximum: Int) -> UInt32 {
        guard maximum > 0 else { return 0 }
        let normalized = min(max(Double(value) / Double(maximum), 0), 1)
        return UInt32(clamping: UInt64((normalized * Double(UInt32.max)).rounded()))
    }

    private static func q16_16(_ value: Float) -> Int32 {
        Int32(clamping: Int64((Double(value) * 65_536).rounded()))
    }

    private static func monotonicMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000
    }

    private static func read<T: FixedWidthInteger>(_ type: T.Type, _ data: Data, _ offset: Int) -> T {
        data[offset..<(offset + MemoryLayout<T>.size)].reduce(T.zero) { ($0 << 8) | T($1) }
    }
}

public final class ProtocolV3PlatformInputSink: PlatformInputPacketSink, @unchecked Sendable {
    private let sender: ProtocolV3InputStateSender
    private let motionPolicy: ControllerMotionPolicy
    private let uptimeProvider: any IntegrationUptimeProviding
    private let failureHandler: @Sendable (Error) -> Void

    public init(
        sender: ProtocolV3InputStateSender,
        motionPolicy: ControllerMotionPolicy,
        uptimeProvider: any IntegrationUptimeProviding = SystemIntegrationUptimeProvider(),
        failureHandler: @escaping @Sendable (Error) -> Void
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
        guard let command = PlatformStreamingInputSink.command(for: packet) else { return }
        do { try sender.send(command) } catch { failureHandler(error) }
    }
}

private extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
