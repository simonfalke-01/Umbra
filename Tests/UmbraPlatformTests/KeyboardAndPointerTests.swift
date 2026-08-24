import AppKit
import CoreGraphics
import XCTest
@testable import UmbraPlatform

final class KeyboardAndPointerTests: XCTestCase {
    @MainActor
    func testFocusLossReleasesEveryForwardedKey() throws {
        let sink = RecordingPlatformInputSink()
        let keyboard = AppKitKeyboardInputAdapter()
        keyboard.sink = sink
        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        XCTAssertTrue(keyboard.handle(keyDown))
        keyboard.releaseAllKeys()

        XCTAssertEqual(sink.packets, [
            .keyboard(.init(virtualKey: 0x41, action: .down, modifiers: [], isExtended: false)),
            .keyboard(.init(virtualKey: 0x41, action: .up, modifiers: [], isExtended: false)),
        ])
    }

    @MainActor
    func testFocusLossPreservesInternationalKeyboardFlagsOnRelease() throws {
        let sink = RecordingPlatformInputSink()
        let keyboard = AppKitKeyboardInputAdapter()
        keyboard.sink = sink
        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "¥",
            charactersIgnoringModifiers: "¥",
            isARepeat: false,
            keyCode: 93
        ))

        XCTAssertTrue(keyboard.handle(keyDown))
        keyboard.releaseAllKeys()

        XCTAssertEqual(sink.packets, [
            .keyboard(.init(
                virtualKey: 0xDC,
                action: .down,
                modifiers: [],
                isExtended: false,
                flags: 0x01
            )),
            .keyboard(.init(
                virtualKey: 0xDC,
                action: .up,
                modifiers: [],
                isExtended: false,
                flags: 0x01
            )),
        ])
    }

    func testKeyboardUsesPhysicalQWERTYPosition() {
        let translator = MacKeyboardTranslator()
        let result = translator.translate(.init(
            keyCode: 0,
            action: .down,
            modifiers: [.shift],
            characterIgnoringModifiers: "q"
        ), capturesCommandKey: false)

        XCTAssertEqual(result, .packet(.init(
            virtualKey: 0x41,
            action: .down,
            modifiers: [.shift],
            isExtended: false
        )))
    }

    func testShortcutMatchesCharacterBeforePhysicalPosition() {
        let detector = ShortcutChordDetector()
        let result = detector.match(
            character: "q",
            physicalKeyCode: 6,
            modifiers: [.control, .option, .shift],
            isRepeat: false
        )
        XCTAssertEqual(result, .quitStream)
    }

    func testShortcutFallsBackToPhysicalPosition() {
        let result = ShortcutChordDetector().match(
            character: "ж",
            physicalKeyCode: 7,
            modifiers: [.control, .option, .shift],
            isRepeat: false
        )
        XCTAssertEqual(result, .toggleFullscreen)
    }

    func testShortcutRequiresChordAndIgnoresRepeat() {
        let detector = ShortcutChordDetector()
        XCTAssertNil(detector.match(character: "q", physicalKeyCode: 12, modifiers: [.control, .shift], isRepeat: false))
        XCTAssertNil(detector.match(character: "q", physicalKeyCode: 12, modifiers: [.control, .option, .shift], isRepeat: true))
    }

    func testRelativeMouseDeltasAccumulateSubpixelMotionWithoutJitterLoss() {
        var accumulator = RelativeMouseDeltaAccumulator()

        XCTAssertNil(accumulator.consume(deltaX: 0.25, deltaY: -0.25))
        XCTAssertNil(accumulator.consume(deltaX: 0.25, deltaY: -0.25))
        XCTAssertNil(accumulator.consume(deltaX: 0.25, deltaY: -0.25))
        let accumulated = accumulator.consume(deltaX: 0.25, deltaY: -0.25)
        XCTAssertEqual(accumulated?.x, 1)
        XCTAssertEqual(accumulated?.y, -1)

        accumulator.reset()
        XCTAssertNil(accumulator.consume(deltaX: 0.75, deltaY: 0))
        XCTAssertEqual(accumulator.consume(deltaX: 0.75, deltaY: 0)?.x, 1)
    }

    func testCommandKeyIsSuppressedWithoutSystemCapture() {
        let event = MacKeyboardEvent(keyCode: 55, action: .down, modifiers: [.command])
        XCTAssertEqual(MacKeyboardTranslator().translate(event, capturesCommandKey: false), .ignored)
        XCTAssertEqual(
            MacKeyboardTranslator().translate(event, capturesCommandKey: true),
            .packet(.init(virtualKey: 0x5B, action: .down, modifiers: [.command], isExtended: false))
        )
    }

    func testMoonlightSpecialAndInternationalKeyboardMappings() {
        let translator = MacKeyboardTranslator()
        let physicalMappings: [(UInt16, UInt16, UInt8)] = [
            (10, 0xE2, 0),    // ISO section / non-US backslash
            (93, 0xDC, 0x01), // JIS Yen / International3
            (94, 0xE2, 0x01), // JIS underscore / International1
            (95, 0x6C, 0),    // JIS keypad comma / separator
            (102, 0x1D, 0),   // JIS Eisu / non-convert
            (104, 0x1C, 0),   // JIS Kana / convert
            (110, 0x5D, 0),   // Contextual Menu / Application
        ]

        for (macKeyCode, virtualKey, flags) in physicalMappings {
            XCTAssertEqual(
                translator.translate(
                    .init(keyCode: macKeyCode, action: .down, modifiers: []),
                    capturesCommandKey: false
                ),
                .packet(.init(
                    virtualKey: virtualKey,
                    action: .down,
                    modifiers: [],
                    isExtended: macKeyCode == 110,
                    flags: flags
                )),
                "macOS key code \(macKeyCode)"
            )
        }
    }

    func testAppKitFunctionCharactersMapPrintScreenMenuAndBrowserKeys() throws {
        let translator = MacKeyboardTranslator()
        let specialMappings: [(NSEvent.SpecialKey, UInt16)] = [
            (.printScreen, 0x2C),
            (.menu, 0x5D),
            (.prev, 0xA6),
            (.next, 0xA7),
            (.stop, 0xA9),
            (.find, 0xAA),
        ]

        for (specialKey, virtualKey) in specialMappings {
            let scalar = try XCTUnwrap(UnicodeScalar(specialKey.rawValue))
            XCTAssertEqual(
                translator.translate(
                    .init(
                        keyCode: 105,
                        action: .down,
                        modifiers: [],
                        characterIgnoringModifiers: Character(scalar)
                    ),
                    capturesCommandKey: false
                ),
                .packet(.init(
                    virtualKey: virtualKey,
                    action: .down,
                    modifiers: [],
                    isExtended: false
                )),
                "AppKit special key \(specialKey.rawValue)"
            )
        }
    }

    @MainActor
    func testNSWindowRoutesOrdinaryKeysAndConsumesRepeatWithoutFallback() throws {
        _ = NSApplication.shared
        let sink = RecordingPlatformInputSink()
        let keyboard = AppKitKeyboardInputAdapter()
        keyboard.sink = sink
        let view = KeyboardRoutingView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        view.keyboard = keyboard
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertTrue(window.firstResponder === view)

        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        let keyUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0.1,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        let repeatedKeyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0.05,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: true,
            keyCode: 0
        ))
        let unmappedKeyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0.075,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 200
        ))

        window.sendEvent(keyDown)
        window.sendEvent(repeatedKeyDown)
        window.sendEvent(unmappedKeyDown)
        window.sendEvent(keyUp)

        XCTAssertEqual(sink.packets, [
            .keyboard(.init(virtualKey: 0x41, action: .down, modifiers: [], isExtended: false)),
            .keyboard(.init(virtualKey: 0x41, action: .up, modifiers: [], isExtended: false)),
        ])
    }

    @MainActor
    func testCaptureLossReleasesEveryForwardedMouseButton() throws {
        let sink = RecordingPlatformInputSink()
        let pointer = AppKitPointerInputAdapter(
            geometry: .init(
                contentSize: CGSize(width: 100, height: 100),
                videoSize: CGSize(width: 100, height: 100)
            )
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        pointer.sink = sink
        pointer.isCaptureActive = true
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 50, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        XCTAssertTrue(pointer.handle(mouseDown, in: view))
        pointer.isCaptureActive = false

        XCTAssertEqual(sink.packets, [
            .mouseButton(.init(button: .left, action: .down)),
            .mouseButton(.init(button: .left, action: .up)),
        ])
    }

    @MainActor
    func testCapturedPrimaryAndSecondaryClicksForwardBalancedButtonEvents() throws {
        let sink = RecordingPlatformInputSink()
        let pointer = AppKitPointerInputAdapter(
            geometry: .init(
                contentSize: CGSize(width: 100, height: 100),
                videoSize: CGSize(width: 100, height: 100)
            )
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        pointer.sink = sink
        pointer.isCaptureActive = true

        for type in [
            NSEvent.EventType.leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
        ] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: NSPoint(x: 50, y: 50),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0
            ))
            XCTAssertTrue(pointer.handle(event, in: view))
        }

        XCTAssertEqual(sink.packets, [
            .mouseButton(.init(button: .left, action: .down)),
            .mouseButton(.init(button: .left, action: .up)),
            .mouseButton(.init(button: .right, action: .down)),
            .mouseButton(.init(button: .right, action: .up)),
        ])
    }

    @MainActor
    func testSinkDetachmentReleasesForwardedMouseButtonToPreviousSink() throws {
        let sink = RecordingPlatformInputSink()
        let pointer = AppKitPointerInputAdapter(
            geometry: .init(
                contentSize: CGSize(width: 100, height: 100),
                videoSize: CGSize(width: 100, height: 100)
            )
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        pointer.sink = sink
        pointer.isCaptureActive = true
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 50, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        XCTAssertTrue(pointer.handle(mouseDown, in: view))
        pointer.sink = nil

        XCTAssertEqual(sink.packets, [
            .mouseButton(.init(button: .left, action: .down)),
            .mouseButton(.init(button: .left, action: .up)),
        ])
    }

    func testMouseButtonSwap() {
        let mapper = MouseInputMapper(preferences: .init(swapPrimaryAndSecondaryButtons: true))
        XCTAssertEqual(mapper.mapButton(number: 0), .right)
        XCTAssertEqual(mapper.mapButton(number: 1), .left)
        XCTAssertEqual(mapper.mapButton(number: 2), .middle)
        XCTAssertNil(mapper.mapButton(number: 9))
    }

    func testScrollClampsMacAccelerationAndReverses() {
        let mapper = MouseInputMapper(preferences: .init(
            reverseScrollDirection: true,
            clampAcceleratedScroll: true
        ))
        XCTAssertEqual(mapper.mapScroll(deltaX: -0.5, deltaY: 10), [
            .init(axis: .vertical, delta: -120),
            .init(axis: .horizontal, delta: 60),
        ])
    }

    func testVideoGeometryLetterboxesAndClampsAbsolutePosition() {
        let geometry = VideoGeometry(
            contentSize: .init(width: 1000, height: 1000),
            videoSize: .init(width: 1920, height: 1080)
        )
        XCTAssertEqual(geometry.videoRect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(geometry.videoRect.origin.y, 218.75, accuracy: 0.001)
        XCTAssertEqual(geometry.videoRect.height, 562.5, accuracy: 0.001)
        XCTAssertEqual(
            geometry.absolutePacket(for: .init(x: -100, y: 1000), flippedCoordinates: false),
            .absolute(x: 0, y: 0, referenceWidth: 1000, referenceHeight: 563)
        )
    }

    func testVideoGeometryAspectFillCropsSourceAndUsesTheWholeDestination() {
        let geometry = VideoGeometry(
            contentSize: CGSize(width: 1_000, height: 1_000),
            videoSize: CGSize(width: 1_920, height: 1_080),
            scalingMode: .aspectFill
        )
        XCTAssertEqual(geometry.videoRect, CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
        XCTAssertEqual(
            geometry.normalizedVideoPosition(for: CGPoint(x: 0, y: 0), flippedCoordinates: true),
            CGPoint(x: 0.21875, y: 0)
        )
        XCTAssertEqual(
            geometry.normalizedVideoPosition(for: CGPoint(x: 1_000, y: 1_000), flippedCoordinates: true),
            CGPoint(x: 0.78125, y: 1)
        )
        XCTAssertEqual(
            geometry.absolutePacket(for: CGPoint(x: 0, y: 0), flippedCoordinates: true),
            .absolute(x: 420, y: 0, referenceWidth: 1_920, referenceHeight: 1_080)
        )
    }

    func testPointerCaptureAutomaticRegionLockPolicy() {
        var machine = PointerCaptureStateMachine(state: .init(
            mode: .absolute,
            captureRequested: true,
            windowFocused: true,
            windowPresentation: .borderlessFullscreen,
            displayCount: 2
        ))
        XCTAssertFalse(machine.state.locksPointerToVideoRegion)
        machine.handle(.presentationChanged(.nativeFullscreen, displayCount: 2))
        XCTAssertFalse(machine.state.locksPointerToVideoRegion)
        machine.handle(.presentationChanged(.nativeFullscreen, displayCount: 1))
        XCTAssertTrue(machine.state.locksPointerToVideoRegion)
        machine.handle(.toggleRegionLock)
        XCTAssertFalse(machine.state.locksPointerToVideoRegion)
        machine.handle(.presentationChanged(.nativeFullscreen, displayCount: 1))
        XCTAssertFalse(machine.state.locksPointerToVideoRegion, "manual policy survives presentation changes")
        machine.handle(.resetRegionLockToAutomatic)
        XCTAssertTrue(machine.state.locksPointerToVideoRegion)
    }

    func testPointerCaptureRequiresFocus() {
        var machine = PointerCaptureStateMachine()
        machine.handle(.requestCapture(true))
        XCTAssertFalse(machine.state.isCaptured)
        machine.handle(.focusChanged(true))
        XCTAssertTrue(machine.state.isCaptured)
        XCTAssertTrue(machine.state.usesRelativePointer)
        machine.handle(.pointerModeChanged(.absolute))
        XCTAssertFalse(machine.state.usesRelativePointer)
        machine.handle(.requestCapture(false))
        machine.handle(.focusChanged(false))

        machine.handle(.pointerModeChanged(.relative))
        machine.handle(.focusChanged(true))
        machine.handle(.requestCapture(true))
        XCTAssertTrue(
            machine.state.usesRelativePointer,
            "A relative session after an absolute session must re-enable relative capture."
        )
    }

    func testVirtualTrackpadScalesPrimaryFingerMotionToStreamGeometry() {
        var trackpad = VirtualTrackpadStateMachine(configuration: .init(
            referenceSize: .init(width: 1920, height: 1080)
        ))
        XCTAssertEqual(trackpad.handle(.init(
            pointerID: 1,
            phase: .began,
            normalizedPosition: .init(x: 0.5, y: 0.5),
            timestamp: 0
        )), [])
        XCTAssertEqual(trackpad.handle(.init(
            pointerID: 1,
            phase: .moved,
            normalizedPosition: .init(x: 0.51, y: 0.52),
            timestamp: 0.1
        )), [
            .mouseMove(.relative(deltaX: 19, deltaY: 22)),
        ])
    }

    func testVirtualTrackpadTapUsesTimedClickReleaseAndMovementCancelsTap() {
        var trackpad = VirtualTrackpadStateMachine(configuration: .init(
            referenceSize: .init(width: 1920, height: 1080)
        ))
        _ = trackpad.handle(.init(
            pointerID: 1,
            phase: .began,
            normalizedPosition: .init(x: 0.5, y: 0.5),
            timestamp: 0
        ))
        XCTAssertEqual(trackpad.handle(.init(
            pointerID: 1,
            phase: .ended,
            normalizedPosition: .init(x: 0.5, y: 0.5),
            timestamp: 0.1
        )), [
            .mouseButton(.init(button: .left, action: .down)),
        ])
        XCTAssertEqual(trackpad.advance(to: 0.19), [])
        XCTAssertEqual(trackpad.advance(to: 0.2), [
            .mouseButton(.init(button: .left, action: .up)),
        ])

        _ = trackpad.handle(.init(
            pointerID: 2,
            phase: .began,
            normalizedPosition: .init(x: 0.25, y: 0.25),
            timestamp: 1
        ))
        _ = trackpad.handle(.init(
            pointerID: 2,
            phase: .moved,
            normalizedPosition: .init(x: 0.3, y: 0.25),
            timestamp: 1.05
        ))
        XCTAssertEqual(trackpad.handle(.init(
            pointerID: 2,
            phase: .ended,
            normalizedPosition: .init(x: 0.3, y: 0.25),
            timestamp: 1.1
        )), [])
    }

    func testVirtualTrackpadTwoFingerTapRightClicksOnlyOnce() {
        var trackpad = VirtualTrackpadStateMachine(configuration: .init(
            referenceSize: .init(width: 2560, height: 1440)
        ))
        _ = trackpad.handle(.init(
            pointerID: 10,
            phase: .began,
            normalizedPosition: .init(x: 0.4, y: 0.4),
            timestamp: 0
        ))
        _ = trackpad.handle(.init(
            pointerID: 11,
            phase: .began,
            normalizedPosition: .init(x: 0.6, y: 0.4),
            timestamp: 0.01
        ))
        XCTAssertEqual(trackpad.handle(.init(
            pointerID: 11,
            phase: .ended,
            normalizedPosition: .init(x: 0.6, y: 0.4),
            timestamp: 0.1
        )), [
            .mouseButton(.init(button: .right, action: .down)),
        ])
        XCTAssertEqual(trackpad.handle(.init(
            pointerID: 10,
            phase: .ended,
            normalizedPosition: .init(x: 0.4, y: 0.4),
            timestamp: 0.15
        )), [])
        XCTAssertEqual(trackpad.advance(to: 0.2), [
            .mouseButton(.init(button: .right, action: .up)),
        ])
    }

    func testVirtualTrackpadHoldDragsAndCancelCannotLeaveButtonPressed() {
        var trackpad = VirtualTrackpadStateMachine(configuration: .init(
            referenceSize: .init(width: 1000, height: 1000)
        ))
        _ = trackpad.handle(.init(
            pointerID: 1,
            phase: .began,
            normalizedPosition: .init(x: 0.5, y: 0.5),
            timestamp: 0
        ))
        XCTAssertEqual(trackpad.advance(to: 0.65), [
            .mouseButton(.init(button: .left, action: .down)),
        ])
        XCTAssertEqual(trackpad.activeDragButton, .left)
        XCTAssertEqual(trackpad.handle(.init(
            pointerID: 1,
            phase: .cancelled,
            normalizedPosition: .init(x: 0.5, y: 0.5),
            timestamp: 0.7
        )), [
            .mouseButton(.init(button: .left, action: .up)),
        ])
        XCTAssertNil(trackpad.activeDragButton)
        XCTAssertEqual(trackpad.activeContactIDs, [])
    }

    func testVirtualTrackpadCancelAllReleasesPendingTap() {
        var trackpad = VirtualTrackpadStateMachine(configuration: .init(
            referenceSize: .init(width: 1000, height: 1000)
        ))
        _ = trackpad.handle(.init(
            pointerID: 1,
            phase: .began,
            normalizedPosition: .init(x: 0.5, y: 0.5),
            timestamp: 0
        ))
        XCTAssertEqual(trackpad.handle(.init(
            pointerID: 1,
            phase: .ended,
            normalizedPosition: .init(x: 0.5, y: 0.5),
            timestamp: 0.05
        )), [
            .mouseButton(.init(button: .left, action: .down)),
        ])
        XCTAssertEqual(trackpad.cancelAllContacts(at: 0.1), [
            .mouseButton(.init(button: .left, action: .up)),
        ])
        XCTAssertEqual(trackpad.advance(to: 1), [])
    }

    func testVirtualTrackpadSecondaryFingerNeverMovesPointerAndThirdContactIsIgnored() {
        var trackpad = VirtualTrackpadStateMachine(configuration: .init(
            referenceSize: .init(width: 1000, height: 1000)
        ))
        _ = trackpad.handle(.init(
            pointerID: 1,
            phase: .began,
            normalizedPosition: .init(x: 0.2, y: 0.2),
            timestamp: 0
        ))
        _ = trackpad.handle(.init(
            pointerID: 2,
            phase: .began,
            normalizedPosition: .init(x: 0.8, y: 0.8),
            timestamp: 0.01
        ))
        XCTAssertEqual(trackpad.handle(.init(
            pointerID: 2,
            phase: .moved,
            normalizedPosition: .init(x: 0.9, y: 0.9),
            timestamp: 0.02
        )), [])
        XCTAssertEqual(trackpad.handle(.init(
            pointerID: 3,
            phase: .began,
            normalizedPosition: .init(x: 0.5, y: 0.5),
            timestamp: 0.03
        )), [])
        XCTAssertEqual(trackpad.activeContactIDs, [1, 2])
    }
}

private final class RecordingPlatformInputSink: PlatformInputPacketSink {
    private(set) var packets: [PlatformInputPacket] = []
    func platformInputDidProduce(_ packet: PlatformInputPacket) { packets.append(packet) }
}

@MainActor
private final class KeyboardRoutingView: NSView {
    weak var keyboard: AppKitKeyboardInputAdapter?

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        keyboard?.consumeInStreamView(event)
    }
    override func keyUp(with event: NSEvent) {
        keyboard?.consumeInStreamView(event)
    }
}
