import AppKit
import Foundation
import UmbraLSP
import UmbraLSPTransport

/// Focused-window AppKit fallback feeding allocation-free records into CLSPCore.
@MainActor
final class LSPAppKitInputCapture {
    var failureHandler: (@MainActor @Sendable (Error) -> Void)?

    private var monitor: Any?
    private var session: LSPClientSession?
    private var nativeCapture: LSPAppleInputCapture?
    private var activationObservers: [NSObjectProtocol] = []
    private var appKitActive = false
    private var priorMouseCoalescing = true
    private var heldKeys: Set<UInt16> = []
    private var heldPointerButtons: Set<UInt16> = []
    private var verticalScrollRemainder = 0.0
    private var horizontalScrollRemainder = 0.0
    private var pointerXRemainder = 0.0
    private var pointerYRemainder = 0.0

    /// Disables AppKit mouse coalescing and begins focused-window capture.
    func start(session: LSPClientSession) {
        do {
            try transfer(to: session)
        } catch {
            failureHandler?(error)
        }
    }

    /// Synchronously quiesces prior capture and transfers physical ownership.
    func transfer(to session: LSPClientSession) throws {
        stop()
        self.session = session
        let center = NotificationCenter.default
        activationObservers = [
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopSources() }
            },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.startSources() }
            },
        ]
        try startSourcesThrowing()
    }

    /// Pauses all capture, neutralizes held state, commits text, then restarts with a fresh baseline.
    func performTextCommit(_ operation: () async throws -> Void) async throws {
        guard session != nil else { throw LSPTransportError.invalidState }
        stopSources()
        do {
            try await operation()
            try session?.restartInputBaseline()
            try startSourcesThrowing()
        } catch {
            try? session?.restartInputBaseline()
            try? startSourcesThrowing()
            throw error
        }
    }

    private func startSources() {
        do {
            try startSourcesThrowing()
        } catch {
            failureHandler?(error)
        }
    }

    private func startSourcesThrowing() throws {
        guard nativeCapture == nil, monitor == nil, let session, NSApp.isActive else { return }
        do {
            nativeCapture = try session.startAppleInputCapture()
            return
        } catch LSPTransportError.inputPermissionDenied, LSPTransportError.inputUnavailable {
            // Native start quiesces completely before returning, so AppKit now
            // becomes the sole keyboard/pointer owner.
        } catch {
            throw error
        }
        priorMouseCoalescing = NSEvent.isMouseCoalescingEnabled
        NSEvent.isMouseCoalescingEnabled = false
        appKitActive = true
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .scrollWheel,
            .keyDown,
            .keyUp,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    /// Emits releases, neutralizes native authority, restores coalescing, and removes callbacks.
    func stop() {
        stopSources()
        let center = NotificationCenter.default
        for observer in activationObservers {
            center.removeObserver(observer)
        }
        activationObservers.removeAll(keepingCapacity: true)
        self.session = nil
    }

    private func stopSources() {
        if let nativeCapture {
            nativeCapture.stop()
            self.nativeCapture = nil
            try? session?.neutralizeInput()
        }
        guard appKitActive, let session else { return }
        let timestamp = Self.monotonicMicroseconds()
        for usage in heldKeys.sorted() {
            try? session.submitInputEdge(
                sampleTimeMicroseconds: timestamp,
                controlID: usage,
                kind: .keyUp
            )
        }
        for button in heldPointerButtons.sorted() {
            try? session.submitInputEdge(
                sampleTimeMicroseconds: timestamp,
                controlID: button,
                kind: .pointerButtonUp
            )
        }
        try? session.neutralizeInput()
        heldKeys.removeAll(keepingCapacity: true)
        heldPointerButtons.removeAll(keepingCapacity: true)
        verticalScrollRemainder = 0
        horizontalScrollRemainder = 0
        pointerXRemainder = 0
        pointerYRemainder = 0
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        NSEvent.isMouseCoalescingEnabled = priorMouseCoalescing
        appKitActive = false
    }

    private func handle(_ event: NSEvent) {
        guard let session else { return }
        let timestamp = max(1, UInt64(event.timestamp * 1_000_000))
        do {
            switch event.type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                try submitPointer(session, event: event, timestamp: timestamp)
            case .scrollWheel:
                try submitScroll(session, event: event, timestamp: timestamp)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                let button = UInt16(event.buttonNumber + 1)
                guard button <= 5, heldPointerButtons.insert(button).inserted else { return }
                try session.submitInputEdge(
                    sampleTimeMicroseconds: timestamp,
                    controlID: button,
                    kind: .pointerButtonDown
                )
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                let button = UInt16(event.buttonNumber + 1)
                guard button <= 5, heldPointerButtons.remove(button) != nil else { return }
                try session.submitInputEdge(
                    sampleTimeMicroseconds: timestamp,
                    controlID: button,
                    kind: .pointerButtonUp
                )
            case .keyDown:
                guard !event.isARepeat, let usage = Self.hidUsage(for: event.keyCode), heldKeys.insert(usage).inserted else {
                    return
                }
                try session.submitInputEdge(
                    sampleTimeMicroseconds: timestamp,
                    controlID: usage,
                    kind: .keyDown
                )
            case .keyUp:
                guard let usage = Self.hidUsage(for: event.keyCode), heldKeys.remove(usage) != nil else { return }
                try session.submitInputEdge(
                    sampleTimeMicroseconds: timestamp,
                    controlID: usage,
                    kind: .keyUp
                )
            default:
                break
            }
        } catch {
            failureHandler?(error)
        }
    }

    private func submitPointer(
        _ session: LSPClientSession,
        event: NSEvent,
        timestamp: UInt64
    ) throws {
        pointerXRemainder += event.deltaX
        pointerYRemainder += event.deltaY
        let x = Int64(pointerXRemainder.rounded(.towardZero))
        let y = Int64(pointerYRemainder.rounded(.towardZero))
        pointerXRemainder -= Double(x)
        pointerYRemainder -= Double(y)
        guard x != 0 || y != 0 else { return }
        try session.submitPointer(sampleTimeMicroseconds: timestamp, deltaX: x, deltaY: y)
    }

    private func submitScroll(
        _ session: LSPClientSession,
        event: NSEvent,
        timestamp: UInt64
    ) throws {
        verticalScrollRemainder += event.scrollingDeltaY
        horizontalScrollRemainder += event.scrollingDeltaX
        let vertical = Int64(verticalScrollRemainder.rounded(.towardZero))
        let horizontal = Int64(horizontalScrollRemainder.rounded(.towardZero))
        verticalScrollRemainder -= Double(vertical)
        horizontalScrollRemainder -= Double(horizontal)
        guard vertical != 0 || horizontal != 0 else { return }
        try session.submitPointer(
            sampleTimeMicroseconds: timestamp,
            deltaX: 0,
            deltaY: 0,
            verticalScroll: vertical,
            horizontalScroll: horizontal
        )
    }

    private static func monotonicMicroseconds() -> UInt64 {
        max(1, UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000))
    }

    /// Converts macOS virtual key codes to USB HID keyboard-page usages.
    private static func hidUsage(for keyCode: UInt16) -> UInt16? {
        switch keyCode {
        case 0: 0x04; case 11: 0x05; case 8: 0x06; case 2: 0x07
        case 14: 0x08; case 3: 0x09; case 5: 0x0A; case 4: 0x0B
        case 34: 0x0C; case 38: 0x0D; case 40: 0x0E; case 37: 0x0F
        case 46: 0x10; case 45: 0x11; case 31: 0x12; case 35: 0x13
        case 12: 0x14; case 15: 0x15; case 1: 0x16; case 17: 0x17
        case 32: 0x18; case 9: 0x19; case 13: 0x1A; case 7: 0x1B
        case 16: 0x1C; case 6: 0x1D
        case 18: 0x1E; case 19: 0x1F; case 20: 0x20; case 21: 0x21
        case 23: 0x22; case 22: 0x23; case 26: 0x24; case 28: 0x25
        case 25: 0x26; case 29: 0x27
        case 36: 0x28; case 53: 0x29; case 51: 0x2A; case 48: 0x2B
        case 49: 0x2C; case 27: 0x2D; case 24: 0x2E; case 33: 0x2F
        case 30: 0x30; case 42: 0x31; case 41: 0x33; case 39: 0x34
        case 43: 0x36; case 47: 0x37; case 44: 0x38
        case 122: 0x3A; case 120: 0x3B; case 99: 0x3C; case 118: 0x3D
        case 96: 0x3E; case 97: 0x3F; case 98: 0x40; case 100: 0x41
        case 101: 0x42; case 109: 0x43; case 103: 0x44; case 111: 0x45
        case 123: 0x50; case 124: 0x4F; case 125: 0x51; case 126: 0x52
        case 56: 0xE1; case 60: 0xE5; case 59: 0xE0; case 62: 0xE4
        case 58: 0xE2; case 61: 0xE6; case 55: 0xE3; case 54: 0xE7
        default: nil
        }
    }
}
