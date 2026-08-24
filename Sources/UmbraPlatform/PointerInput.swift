import AppKit
import CoreGraphics
import Foundation

public enum WindowPresentation: Equatable, Sendable {
    case windowed
    case borderlessFullscreen
    case nativeFullscreen
}

public enum PointerRegionLockPolicy: Equatable, Sendable {
    case automatic
    case enabled
    case disabled
}

public struct PointerCaptureState: Equatable, Sendable {
    public var mode: PointerMode
    public var captureRequested: Bool
    public var windowFocused: Bool
    public var windowPresentation: WindowPresentation
    public var displayCount: Int
    public var regionLockPolicy: PointerRegionLockPolicy
    public var cursorVisibleInAbsoluteMode: Bool

    public init(
        mode: PointerMode = .relative,
        captureRequested: Bool = false,
        windowFocused: Bool = false,
        windowPresentation: WindowPresentation = .windowed,
        displayCount: Int = 1,
        regionLockPolicy: PointerRegionLockPolicy = .automatic,
        cursorVisibleInAbsoluteMode: Bool = false
    ) {
        self.mode = mode
        self.captureRequested = captureRequested
        self.windowFocused = windowFocused
        self.windowPresentation = windowPresentation
        self.displayCount = max(displayCount, 1)
        self.regionLockPolicy = regionLockPolicy
        self.cursorVisibleInAbsoluteMode = cursorVisibleInAbsoluteMode
    }

    public var isCaptured: Bool { captureRequested && windowFocused }
    public var usesRelativePointer: Bool { isCaptured && mode == .relative }
    public var shouldHideCursor: Bool {
        isCaptured && (mode == .relative || !cursorVisibleInAbsoluteMode)
    }

    public var locksPointerToVideoRegion: Bool {
        guard isCaptured, mode == .absolute else { return false }
        switch regionLockPolicy {
        case .enabled: return true
        case .disabled: return false
        case .automatic:
            // The capture driver clamps in the primary display's Quartz space.
            // Avoid an incorrect region on secondary displays until it can use
            // the active screen's global display bounds.
            guard displayCount == 1 else { return false }
            return windowPresentation == .nativeFullscreen ||
                windowPresentation == .borderlessFullscreen
        }
    }
}

public enum PointerCaptureEvent: Equatable, Sendable {
    case requestCapture(Bool)
    case focusChanged(Bool)
    case pointerModeChanged(PointerMode)
    case presentationChanged(WindowPresentation, displayCount: Int)
    case toggleRegionLock
    case resetRegionLockToAutomatic
    case toggleCursorVisibility
}

public struct PointerCaptureStateMachine: Sendable {
    public private(set) var state: PointerCaptureState

    public init(state: PointerCaptureState = .init()) {
        self.state = state
    }

    @discardableResult
    public mutating func handle(_ event: PointerCaptureEvent) -> PointerCaptureState {
        switch event {
        case .requestCapture(let active):
            state.captureRequested = active
        case .focusChanged(let focused):
            state.windowFocused = focused
        case .pointerModeChanged(let mode):
            state.mode = mode
        case .presentationChanged(let presentation, let displayCount):
            state.windowPresentation = presentation
            state.displayCount = max(displayCount, 1)
        case .toggleRegionLock:
            state.regionLockPolicy = state.locksPointerToVideoRegion ? .disabled : .enabled
        case .resetRegionLockToAutomatic:
            state.regionLockPolicy = .automatic
        case .toggleCursorVisibility:
            state.cursorVisibleInAbsoluteMode.toggle()
        }
        return state
    }
}

public struct VirtualTrackpadConfiguration: Equatable, Sendable {
    /// Host/stream dimensions used to scale normalized touch deltas. This must
    /// not be the local window size or pointer speed changes with window size.
    public var referenceSize: CGSize
    public var tapMaximumDuration: TimeInterval
    public var dragActivationDelay: TimeInterval
    public var clickReleaseDelay: TimeInterval
    public var movementDeadZone: CGFloat

    public init(
        referenceSize: CGSize,
        tapMaximumDuration: TimeInterval = 0.25,
        dragActivationDelay: TimeInterval = 0.65,
        clickReleaseDelay: TimeInterval = 0.1,
        movementDeadZone: CGFloat = 0.01
    ) {
        self.referenceSize = referenceSize
        self.tapMaximumDuration = max(tapMaximumDuration, 0)
        self.dragActivationDelay = max(dragActivationDelay, 0)
        self.clickReleaseDelay = max(clickReleaseDelay, 0)
        self.movementDeadZone = max(movementDeadZone, 0)
    }
}

public struct VirtualTrackpadTouchEvent: Equatable, Sendable {
    public var pointerID: UInt32
    public var phase: TouchPhase
    /// Normalized top-left-origin position. Values outside 0...1 remain valid
    /// while a contact continues beyond the view boundary.
    public var normalizedPosition: CGPoint
    public var timestamp: TimeInterval

    public init(
        pointerID: UInt32,
        phase: TouchPhase,
        normalizedPosition: CGPoint,
        timestamp: TimeInterval
    ) {
        self.pointerID = pointerID
        self.phase = phase
        self.normalizedPosition = normalizedPosition
        self.timestamp = timestamp
    }
}

/// Pure gesture state for Moonlight-compatible virtual-trackpad input.
/// One finger moves/clicks, two fingers right-click, and a stationary hold
/// begins a left/right drag. Timed releases are exposed through `advance(to:)`
/// so callers can drive the state with their normal event/timer loop.
public struct VirtualTrackpadStateMachine: Sendable {
    private struct Contact: Sendable {
        var pointerID: UInt32
        var slot: UInt8
        var initialPosition: CGPoint
        var lastPosition: CGPoint
        var beganAt: TimeInterval
        var tapEligible: Bool
    }

    private struct PendingClickRelease: Sendable {
        var button: MouseButton
        var deadline: TimeInterval
    }

    public var configuration: VirtualTrackpadConfiguration
    private var contacts: [UInt32: Contact] = [:]
    private var dragDeadline: TimeInterval?
    private var heldDragButton: MouseButton?
    private var pendingClickReleases: [PendingClickRelease] = []

    public init(configuration: VirtualTrackpadConfiguration) {
        self.configuration = configuration
    }

    public var activeContactIDs: [UInt32] {
        contacts.values.sorted { $0.slot < $1.slot }.map(\.pointerID)
    }

    public var activeDragButton: MouseButton? { heldDragButton }
    public var pendingDragActivationTime: TimeInterval? { dragDeadline }
    public var nextScheduledEventTime: TimeInterval? {
        ([dragDeadline] + pendingClickReleases.map(\.deadline)).compactMap { $0 }.min()
    }

    public mutating func handle(_ event: VirtualTrackpadTouchEvent) -> [PlatformInputPacket] {
        guard event.timestamp.isFinite,
              event.normalizedPosition.x.isFinite,
              event.normalizedPosition.y.isFinite
        else { return [] }

        var packets = advance(to: event.timestamp)
        switch event.phase {
        case .began:
            guard contacts[event.pointerID] == nil,
                  let slot = firstFreeSlot()
            else { return packets }
            contacts[event.pointerID] = Contact(
                pointerID: event.pointerID,
                slot: slot,
                initialPosition: event.normalizedPosition,
                lastPosition: event.normalizedPosition,
                beganAt: event.timestamp,
                tapEligible: true
            )
            dragDeadline = event.timestamp + configuration.dragActivationDelay

        case .moved:
            guard var contact = contacts[event.pointerID] else { return packets }
            let delta = CGPoint(
                x: event.normalizedPosition.x - contact.lastPosition.x,
                y: event.normalizedPosition.y - contact.lastPosition.y
            )
            contact.lastPosition = event.normalizedPosition
            let distance = hypot(
                event.normalizedPosition.x - contact.initialPosition.x,
                event.normalizedPosition.y - contact.initialPosition.y
            )
            if distance > configuration.movementDeadZone {
                contact.tapEligible = false
                dragDeadline = nil
            }
            contacts[event.pointerID] = contact

            if contact.slot == 0 {
                let deltaX = Self.int16(delta.x * configuration.referenceSize.width)
                let deltaY = Self.int16(delta.y * configuration.referenceSize.height)
                if deltaX != 0 || deltaY != 0 {
                    packets.append(.mouseMove(.relative(deltaX: deltaX, deltaY: deltaY)))
                }
            }

        case .ended:
            packets.append(contentsOf: finishContact(event.pointerID, at: event.timestamp, cancelled: false))

        case .cancelled:
            packets.append(contentsOf: finishContact(event.pointerID, at: event.timestamp, cancelled: true))
        }
        return packets
    }

    public mutating func advance(to time: TimeInterval) -> [PlatformInputPacket] {
        guard time.isFinite else { return [] }
        var packets: [PlatformInputPacket] = []

        let dueReleases = pendingClickReleases
            .filter { time >= $0.deadline }
            .sorted { lhs, rhs in
                if lhs.deadline != rhs.deadline { return lhs.deadline < rhs.deadline }
                return lhs.button.rawValue < rhs.button.rawValue
            }
        if !dueReleases.isEmpty {
            let dueButtons = Set(dueReleases.map { $0.button.rawValue })
            pendingClickReleases.removeAll { dueButtons.contains($0.button.rawValue) && time >= $0.deadline }
            packets.append(contentsOf: dueReleases.map {
                .mouseButton(.init(button: $0.button, action: .up))
            })
        }

        if let deadline = dragDeadline,
           time >= deadline,
           heldDragButton == nil,
           !contacts.isEmpty,
           contacts.values.allSatisfy(\.tapEligible) {
            let button: MouseButton = contacts.count == 2 ? .right : .left
            heldDragButton = button
            dragDeadline = nil
            packets.append(.mouseButton(.init(button: button, action: .down)))
        }
        return packets
    }

    public mutating func cancelAllContacts(at time: TimeInterval) -> [PlatformInputPacket] {
        var packets = advance(to: time)
        contacts.removeAll()
        dragDeadline = nil
        if let button = heldDragButton {
            heldDragButton = nil
            packets.append(.mouseButton(.init(button: button, action: .up)))
        }
        let pendingButtons = pendingClickReleases
            .map(\.button)
            .sorted { $0.rawValue < $1.rawValue }
        pendingClickReleases.removeAll()
        packets.append(contentsOf: pendingButtons.map {
            .mouseButton(.init(button: $0, action: .up))
        })
        return packets
    }

    private mutating func finishContact(
        _ pointerID: UInt32,
        at time: TimeInterval,
        cancelled: Bool
    ) -> [PlatformInputPacket] {
        guard let contact = contacts[pointerID] else { return [] }
        let contactCount = contacts.count
        dragDeadline = nil
        var packets: [PlatformInputPacket] = []

        if let button = heldDragButton {
            heldDragButton = nil
            packets.append(.mouseButton(.init(button: button, action: .up)))
        } else if !cancelled,
                  contact.tapEligible,
                  time >= contact.beganAt,
                  time - contact.beganAt < configuration.tapMaximumDuration {
            if contactCount == 2 {
                packets.append(contentsOf: beginClick(.right, at: time))
                for id in contacts.keys where id != pointerID {
                    contacts[id]?.tapEligible = false
                }
            } else {
                packets.append(contentsOf: beginClick(.left, at: time))
            }
        }

        contacts.removeValue(forKey: pointerID)
        return packets
    }

    private mutating func beginClick(_ button: MouseButton, at time: TimeInterval) -> [PlatformInputPacket] {
        pendingClickReleases.removeAll { $0.button == button }
        pendingClickReleases.append(.init(
            button: button,
            deadline: time + configuration.clickReleaseDelay
        ))
        return [.mouseButton(.init(button: button, action: .down))]
    }

    private func firstFreeSlot() -> UInt8? {
        let used = Set(contacts.values.map(\.slot))
        return (UInt8(0)...UInt8(1)).first { !used.contains($0) }
    }

    private static func int16(_ value: CGFloat) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(min(max(value.rounded(), CGFloat(Int16.min)), CGFloat(Int16.max)))
    }
}

@MainActor
public protocol PointerCaptureDriving: AnyObject {
    /// Uses CoreGraphics cursor decoupling. Returns false when the OS rejects it.
    func setRelativePointerEnabled(_ enabled: Bool) -> Bool
    func setCursorHidden(_ hidden: Bool)
    func setPointerRegionLock(_ rectInScreen: CGRect?)
}

@MainActor
public final class CoreGraphicsPointerCaptureDriver: PointerCaptureDriving {
    private var cursorHidden = false
    nonisolated(unsafe) private var localMonitor: Any?
    private var lockRect: CGRect?

    public init() {}

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if cursorHidden { NSCursor.unhide() }
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }

    public func setRelativePointerEnabled(_ enabled: Bool) -> Bool {
        CGAssociateMouseAndMouseCursorPosition(boolean_t(enabled ? 0 : 1)) == .success
    }

    public func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        hidden ? NSCursor.hide() : NSCursor.unhide()
    }

    /// AppKit does not expose a native cursor-confinement API. This driver performs
    /// a best-effort software clamp for events delivered to the application. It does
    /// not claim to intercept system-wide events or shortcuts.
    public func setPointerRegionLock(_ rectInScreen: CGRect?) {
        lockRect = rectInScreen
        if rectInScreen == nil {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            localMonitor = nil
            return
        }
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            self?.clampCursorIfNeeded()
            return event
        }
    }

    private func clampCursorIfNeeded() {
        guard let rect = lockRect else { return }
        let location = NSEvent.mouseLocation
        let clamped = CGPoint(
            x: min(max(location.x, rect.minX), rect.maxX),
            y: min(max(location.y, rect.minY), rect.maxY)
        )
        guard clamped != location else { return }

        // NSEvent uses a bottom-left global origin while CGWarp uses a top-left
        // origin on the primary display. This conversion is reliable for the
        // primary display; multi-display automatic locking is intentionally off.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        CGWarpMouseCursorPosition(CGPoint(x: clamped.x, y: primaryHeight - clamped.y))
    }
}

@MainActor
public final class PointerCaptureCoordinator {
    public private(set) var machine: PointerCaptureStateMachine
    public var videoRegionInScreen: CGRect? {
        didSet { apply() }
    }
    public var onStateChanged: ((PointerCaptureState) -> Void)?

    private let driver: PointerCaptureDriving

    public init(
        initialState: PointerCaptureState = .init(),
        driver: PointerCaptureDriving = CoreGraphicsPointerCaptureDriver()
    ) {
        machine = .init(state: initialState)
        self.driver = driver
    }

    public func handle(_ event: PointerCaptureEvent) {
        let oldState = machine.state
        let newState = machine.handle(event)
        apply()
        if oldState != newState { onStateChanged?(newState) }
    }

    private func apply() {
        let state = machine.state
        _ = driver.setRelativePointerEnabled(state.usesRelativePointer)
        // If cursor decoupling is unavailable, hiding preserves the visibility-only
        // capture fallback while relative deltas continue to be delivered.
        driver.setCursorHidden(state.shouldHideCursor)
        driver.setPointerRegionLock(state.locksPointerToVideoRegion ? videoRegionInScreen : nil)
    }
}

public enum VideoScalingMode: Equatable, Sendable {
    case aspectFit
    case aspectFill
}

public struct VideoGeometry: Equatable, Sendable {
    public var contentSize: CGSize
    public var videoSize: CGSize
    public var scalingMode: VideoScalingMode

    public init(
        contentSize: CGSize,
        videoSize: CGSize,
        scalingMode: VideoScalingMode = .aspectFit
    ) {
        self.contentSize = contentSize
        self.videoSize = videoSize
        self.scalingMode = scalingMode
    }

    public var videoRect: CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              videoSize.width > 0, videoSize.height > 0
        else { return .zero }
        if scalingMode == .aspectFill {
            return CGRect(origin: .zero, size: contentSize)
        }
        let scale = min(contentSize.width / videoSize.width, contentSize.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: (contentSize.width - size.width) / 2,
            y: (contentSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    public func absolutePacket(for point: CGPoint, flippedCoordinates: Bool) -> MouseMovePacket {
        if scalingMode == .aspectFill {
            let position = normalizedVideoPosition(for: point, flippedCoordinates: flippedCoordinates)
            return .absolute(
                x: Self.int16(position.x * videoSize.width),
                y: Self.int16(position.y * videoSize.height),
                referenceWidth: Self.int16(videoSize.width),
                referenceHeight: Self.int16(videoSize.height)
            )
        }
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else {
            return .absolute(x: 0, y: 0, referenceWidth: 0, referenceHeight: 0)
        }
        let localX = min(max(point.x - rect.minX, 0), rect.width)
        let localY: CGFloat
        if flippedCoordinates {
            localY = min(max(point.y - rect.minY, 0), rect.height)
        } else {
            localY = min(max(rect.maxY - point.y, 0), rect.height)
        }
        return .absolute(
            x: Self.int16(localX),
            y: Self.int16(localY),
            referenceWidth: Self.int16(rect.width),
            referenceHeight: Self.int16(rect.height)
        )
    }

    public func normalizedVideoPosition(
        for point: CGPoint,
        flippedCoordinates: Bool
    ) -> CGPoint {
        guard contentSize.width > 0, contentSize.height > 0,
              videoSize.width > 0, videoSize.height > 0,
              point.x.isFinite, point.y.isFinite
        else { return .zero }

        if scalingMode == .aspectFit {
            let rect = videoRect
            let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
            let rawY = flippedCoordinates
                ? (point.y - rect.minY) / rect.height
                : (rect.maxY - point.y) / rect.height
            return CGPoint(x: x, y: min(max(rawY, 0), 1))
        }

        var x = min(max(point.x / contentSize.width, 0), 1)
        var y = flippedCoordinates
            ? min(max(point.y / contentSize.height, 0), 1)
            : min(max((contentSize.height - point.y) / contentSize.height, 0), 1)
        let sourceAspect = videoSize.width / videoSize.height
        let destinationAspect = contentSize.width / contentSize.height
        if sourceAspect > destinationAspect {
            let visibleWidth = destinationAspect / sourceAspect
            x = ((1 - visibleWidth) / 2) + (x * visibleWidth)
        } else if sourceAspect < destinationAspect {
            let visibleHeight = sourceAspect / destinationAspect
            y = ((1 - visibleHeight) / 2) + (y * visibleHeight)
        }
        return CGPoint(x: x, y: y)
    }

    private static func int16(_ value: CGFloat) -> Int16 {
        Int16(min(max(value.rounded(), CGFloat(Int16.min)), CGFloat(Int16.max)))
    }
}

public struct RelativeMouseDeltaAccumulator: Sendable {
    private var remainderX: CGFloat = 0
    private var remainderY: CGFloat = 0

    public init() {}

    public mutating func consume(
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> (x: Int16, y: Int16)? {
        let x = consumeAxis(deltaX, remainder: &remainderX)
        let y = consumeAxis(deltaY, remainder: &remainderY)
        return x == 0 && y == 0 ? nil : (x, y)
    }

    public mutating func reset() {
        remainderX = 0
        remainderY = 0
    }

    private func consumeAxis(
        _ delta: CGFloat,
        remainder: inout CGFloat
    ) -> Int16 {
        guard delta.isFinite else {
            remainder = 0
            return 0
        }
        let total = delta + remainder
        let whole = total.rounded(.towardZero)
        let clamped = min(max(whole, CGFloat(Int16.min)), CGFloat(Int16.max))
        remainder = total - clamped
        return Int16(clamped)
    }
}

@MainActor
public final class AppKitPointerInputAdapter {
    public weak var sink: PlatformInputPacketSink? {
        didSet {
            if oldValue !== sink {
                releaseAllButtons(to: oldValue)
                relativeMotion.reset()
            }
        }
    }
    public var preferences: PointerPreferences
    public var isCaptureActive = false {
        didSet {
            if oldValue, !isCaptureActive {
                releaseAllButtons()
                relativeMotion.reset()
            }
        }
    }
    public var geometry: VideoGeometry
    public var onCaptureRequested: ((Bool) -> Void)?
    private var heldButtons: Set<MouseButton> = []
    private var relativeMotion = RelativeMouseDeltaAccumulator()

    public init(preferences: PointerPreferences = .init(), geometry: VideoGeometry) {
        self.preferences = preferences
        self.geometry = geometry
    }

    /// Returns true when the event was consumed. A left-button release inside the
    /// video requests recapture without forwarding that release to the host.
    @discardableResult
    public func handle(_ event: NSEvent, in view: NSView) -> Bool {
        let point = view.convert(event.locationInWindow, from: nil)
        let videoRect = geometry.videoRect

        if !isCaptureActive {
            if event.type == .leftMouseUp, videoRect.contains(point) {
                onCaptureRequested?(true)
                return true
            }
            return false
        }

        let mapper = MouseInputMapper(preferences: preferences)
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if preferences.mode == .relative {
                if let delta = relativeMotion.consume(
                    deltaX: event.deltaX,
                    deltaY: event.deltaY
                ) {
                    sink?.platformInputDidProduce(.mouseMove(.relative(
                        deltaX: delta.x,
                        deltaY: delta.y
                    )))
                }
            } else {
                relativeMotion.reset()
                sink?.platformInputDidProduce(.mouseMove(
                    geometry.absolutePacket(for: point, flippedCoordinates: view.isFlipped)
                ))
            }
            return true

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            guard preferences.mode != .absolute || videoRect.contains(point) || Self.isMouseUp(event.type),
                  let button = mapper.mapButton(number: Self.physicalButtonNumber(for: event))
            else { return false }
            let action: KeyAction = Self.isMouseUp(event.type) ? .up : .down
            if action == .down {
                if let sink {
                    heldButtons.insert(button)
                    sink.platformInputDidProduce(.mouseButton(.init(button: button, action: action)))
                }
            } else {
                heldButtons.remove(button)
                sink?.platformInputDidProduce(.mouseButton(.init(button: button, action: action)))
            }
            return true

        case .scrollWheel:
            guard preferences.mode != .absolute || videoRect.contains(point) else { return false }
            for packet in mapper.mapScroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY) {
                sink?.platformInputDidProduce(.scroll(packet))
            }
            return true

        default:
            return false
        }
    }

    /// Releases every physical button forwarded to the host. This is called
    /// before capture or the input sink is lost so remote button state cannot stick.
    public func releaseAllButtons() {
        releaseAllButtons(to: sink)
    }

    private func releaseAllButtons(to target: PlatformInputPacketSink?) {
        let pressed = heldButtons.sorted { $0.rawValue < $1.rawValue }
        heldButtons.removeAll()
        for button in pressed {
            target?.platformInputDidProduce(.mouseButton(.init(button: button, action: .up)))
        }
    }

    private static func isMouseUp(_ type: NSEvent.EventType) -> Bool {
        type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
    }

    private static func physicalButtonNumber(for event: NSEvent) -> Int {
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            0
        case .rightMouseDown, .rightMouseUp:
            1
        default:
            event.buttonNumber
        }
    }

}
