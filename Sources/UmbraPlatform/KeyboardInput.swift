import AppKit
import Foundation

public enum StreamingShortcutAction: CaseIterable, Equatable, Sendable {
    case quitStream
    case toggleInputCapture
    case toggleFullscreen
    case toggleStatistics
    case togglePointerMode
    case toggleCursorVisibility
    case minimize
    case pasteClipboardText
    case togglePointerRegionLock
    case quitStreamAndApplication
    case toggleSystemShortcutCapture
}

public struct StreamingShortcutBinding: Equatable, Sendable {
    public var action: StreamingShortcutAction
    public var character: Character
    public var physicalKeyCode: UInt16
    public var enabled: Bool

    public init(action: StreamingShortcutAction, character: Character, physicalKeyCode: UInt16, enabled: Bool = true) {
        self.action = action
        self.character = character
        self.physicalKeyCode = physicalKeyCode
        self.enabled = enabled
    }

    /// GameStream-compatible Ctrl+Option+Shift shortcut defaults.
    public static let gameStreamDefaults: [Self] = [
        .init(action: .quitStream, character: "q", physicalKeyCode: 12),
        .init(action: .toggleInputCapture, character: "z", physicalKeyCode: 6),
        .init(action: .toggleFullscreen, character: "x", physicalKeyCode: 7),
        .init(action: .toggleStatistics, character: "s", physicalKeyCode: 1),
        .init(action: .togglePointerMode, character: "m", physicalKeyCode: 46),
        .init(action: .toggleCursorVisibility, character: "c", physicalKeyCode: 8),
        .init(action: .minimize, character: "d", physicalKeyCode: 2),
        .init(action: .pasteClipboardText, character: "v", physicalKeyCode: 9),
        .init(action: .togglePointerRegionLock, character: "l", physicalKeyCode: 37),
        .init(action: .quitStreamAndApplication, character: "e", physicalKeyCode: 14),
        .init(action: .toggleSystemShortcutCapture, character: "k", physicalKeyCode: 40),
    ]
}

public struct ShortcutChordDetector: Sendable {
    public var bindings: [StreamingShortcutBinding]

    public init(bindings: [StreamingShortcutBinding] = StreamingShortcutBinding.gameStreamDefaults) {
        self.bindings = bindings
    }

    public func match(
        character: Character?,
        physicalKeyCode: UInt16,
        modifiers: KeyboardModifierMask,
        isRepeat: Bool
    ) -> StreamingShortcutAction? {
        guard !isRepeat,
              modifiers.contains([.control, .option, .shift])
        else { return nil }

        // Match the character first for Latin layouts, then the physical position.
        // This mirrors GameStream and prevents a character match from colliding with
        // another shortcut's physical key on non-QWERTY layouts.
        if let character {
            let folded = Character(String(character).lowercased())
            if let binding = bindings.first(where: { $0.enabled && $0.character == folded }) {
                return binding.action
            }
        }

        return bindings.first(where: { $0.enabled && $0.physicalKeyCode == physicalKeyCode })?.action
    }
}

public enum KeyboardTranslation: Equatable, Sendable {
    case packet(KeyboardPacket)
    case shortcut(StreamingShortcutAction)
    case ignored
}

public struct MacKeyboardEvent: Equatable, Sendable {
    public var keyCode: UInt16
    public var action: KeyAction
    public var modifiers: KeyboardModifierMask
    public var characterIgnoringModifiers: Character?
    public var isRepeat: Bool

    public init(
        keyCode: UInt16,
        action: KeyAction,
        modifiers: KeyboardModifierMask,
        characterIgnoringModifiers: Character? = nil,
        isRepeat: Bool = false
    ) {
        self.keyCode = keyCode
        self.action = action
        self.modifiers = modifiers
        self.characterIgnoringModifiers = characterIgnoringModifiers
        self.isRepeat = isRepeat
    }
}

public struct MacKeyboardTranslator: Sendable {
    private struct KeyMapping: Sendable {
        var virtualKey: UInt16
        var flags: UInt8 = 0
    }

    public var shortcuts: ShortcutChordDetector

    public init(shortcuts: ShortcutChordDetector = .init()) {
        self.shortcuts = shortcuts
    }

    public func translate(_ event: MacKeyboardEvent, capturesCommandKey: Bool) -> KeyboardTranslation {
        if event.action == .down,
           let shortcut = shortcuts.match(
            character: event.characterIgnoringModifiers,
            physicalKeyCode: event.keyCode,
            modifiers: event.modifiers,
            isRepeat: event.isRepeat
           ) {
            return .shortcut(shortcut)
        }

        // GameStream intentionally discards repeat-down events. The host owns repeat.
        guard !event.isRepeat else { return .ignored }
        guard let mapping = Self.keyMapping(
            forMacKeyCode: event.keyCode,
            characterIgnoringModifiers: event.characterIgnoringModifiers
        ) else { return .ignored }
        let key = mapping.virtualKey

        if (key == 0x5B || key == 0x5C), !capturesCommandKey {
            return .ignored
        }

        var modifiers = event.modifiers
        if !capturesCommandKey {
            modifiers.remove(.command)
        }
        return .packet(.init(
            virtualKey: key,
            action: event.action,
            modifiers: modifiers,
            isExtended: Self.isWindowsExtendedKey(macKeyCode: event.keyCode),
            flags: mapping.flags
        ))
    }

    public static func modifierMask(from flags: NSEvent.ModifierFlags) -> KeyboardModifierMask {
        var result: KeyboardModifierMask = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    public static func event(from event: NSEvent) -> MacKeyboardEvent? {
        let action: KeyAction
        switch event.type {
        case .keyDown: action = .down
        case .keyUp: action = .up
        default: return nil
        }

        let character = event.charactersIgnoringModifiers?.first
        return .init(
            keyCode: event.keyCode,
            action: action,
            modifiers: modifierMask(from: event.modifierFlags),
            characterIgnoringModifiers: character,
            isRepeat: event.isARepeat
        )
    }

    /// Maps macOS hardware positions to the Windows VK values used by GameStream.
    public static func windowsVirtualKey(forMacKeyCode code: UInt16) -> UInt16? {
        keyMap[code]
    }

    private static func keyMapping(
        forMacKeyCode code: UInt16,
        characterIgnoringModifiers: Character?
    ) -> KeyMapping? {
        if let characterIgnoringModifiers,
           let specialKey = windowsVirtualKey(forSpecialCharacter: characterIgnoringModifiers) {
            return KeyMapping(virtualKey: specialKey)
        }
        guard let virtualKey = keyMap[code] else { return nil }
        return KeyMapping(
            virtualKey: virtualKey,
            flags: nonNormalizedMacKeyCodes.contains(code) ? 0x01 : 0
        )
    }

    /// Maps AppKit function-key characters emitted by PC-style keyboards.
    private static func windowsVirtualKey(forSpecialCharacter character: Character) -> UInt16? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else { return nil }
        return specialKeyMap[Int(scalar.value)]
    }

    private static func isWindowsExtendedKey(macKeyCode: UInt16) -> Bool {
        [54, 61, 62, 76, 110, 114, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(macKeyCode)
    }

    private static let nonNormalizedMacKeyCodes: Set<UInt16> = [93, 94]

    private static let specialKeyMap: [Int: UInt16] = [
        NSEvent.SpecialKey.printScreen.rawValue: 0x2C,
        NSEvent.SpecialKey.scrollLock.rawValue: 0x91,
        NSEvent.SpecialKey.pause.rawValue: 0x13,
        NSEvent.SpecialKey.menu.rawValue: 0x5D,
        NSEvent.SpecialKey.prev.rawValue: 0xA6,
        NSEvent.SpecialKey.next.rawValue: 0xA7,
        NSEvent.SpecialKey.stop.rawValue: 0xA9,
        NSEvent.SpecialKey.find.rawValue: 0xAA,
    ]

    private static let keyMap: [UInt16: UInt16] = [
        // ANSI alphabet and digits, mapped by physical QWERTY position.
        0: 0x41, 1: 0x53, 2: 0x44, 3: 0x46, 4: 0x48, 5: 0x47,
        6: 0x5A, 7: 0x58, 8: 0x43, 9: 0x56, 11: 0x42, 12: 0x51,
        13: 0x57, 14: 0x45, 15: 0x52, 16: 0x59, 17: 0x54, 18: 0x31,
        19: 0x32, 20: 0x33, 21: 0x34, 22: 0x36, 23: 0x35, 25: 0x39,
        26: 0x37, 28: 0x38, 29: 0x30, 31: 0x4F, 32: 0x55, 34: 0x49,
        35: 0x50, 37: 0x4C, 38: 0x4A, 40: 0x4B, 45: 0x4E, 46: 0x4D,

        // ANSI punctuation.
        24: 0xBB, 27: 0xBD, 30: 0xDD, 33: 0xDB, 39: 0xDE,
        41: 0xBA, 42: 0xDC, 43: 0xBC, 44: 0xBF, 47: 0xBE, 50: 0xC0,
        10: 0xE2,

        // Editing and modifiers.
        36: 0x0D, 48: 0x09, 49: 0x20, 51: 0x08, 53: 0x1B,
        54: 0x5C, 55: 0x5B, 56: 0xA0, 57: 0x14, 58: 0xA4,
        59: 0xA2, 60: 0xA1, 61: 0xA5, 62: 0xA3,

        // Numeric keypad.
        65: 0x6E, 67: 0x6A, 69: 0x6B, 71: 0x90, 75: 0x6F,
        76: 0x0D, 78: 0x6D, 81: 0xBB, 82: 0x60, 83: 0x61,
        84: 0x62, 85: 0x63, 86: 0x64, 87: 0x65, 88: 0x66,
        89: 0x67, 91: 0x68, 92: 0x69, 95: 0x6C,

        // JIS layout keys. Yen and underscore carry the host's non-normalized
        // flag so the host doesn't rewrite these physical positions.
        93: 0xDC, 94: 0xE2, 102: 0x1D, 104: 0x1C,

        // Function keys.
        122: 0x70, 120: 0x71, 99: 0x72, 118: 0x73, 96: 0x74,
        97: 0x75, 98: 0x76, 100: 0x77, 101: 0x78, 109: 0x79,
        103: 0x7A, 111: 0x7B, 105: 0x7C, 107: 0x7D, 113: 0x7E,
        106: 0x7F, 64: 0x80, 79: 0x81, 80: 0x82,

        // Contextual Menu / Application key.
        110: 0x5D,

        // Navigation.
        114: 0x2D, 115: 0x24, 116: 0x21, 117: 0x2E,
        119: 0x23, 121: 0x22, 123: 0x25, 124: 0x27,
        125: 0x28, 126: 0x26,
    ]
}

@MainActor
public final class AppKitKeyboardInputAdapter {
    private struct HeldKey {
        var isExtended: Bool
        var flags: UInt8
    }

    public weak var sink: PlatformInputPacketSink?
    public var onShortcut: ((StreamingShortcutAction) -> Void)?
    public var capturesCommandKey = false {
        didSet {
            if oldValue != capturesCommandKey { releaseAllKeys() }
        }
    }
    public var translator: MacKeyboardTranslator
    private var modifierKeysDown: Set<UInt16> = []
    private var heldKeys: [UInt16: HeldKey] = [:]

    public init(translator: MacKeyboardTranslator = .init()) {
        self.translator = translator
    }

    /// Returns true when the event is consumed by Umbra.
    @discardableResult
    public func handle(_ event: NSEvent) -> Bool {
        // AppKit reports Caps Lock as a latch-style flagsChanged event rather than
        // a conventional down/up pair. Emit a complete press so the host never
        // retains VK_CAPITAL as a stuck key.
        if event.type == .flagsChanged, event.keyCode == 57 {
            let modifiers = MacKeyboardTranslator.modifierMask(from: event.modifierFlags)
            for action: KeyAction in [.down, .up] {
                if case .packet(let packet) = translator.translate(
                    .init(keyCode: 57, action: action, modifiers: modifiers),
                    capturesCommandKey: capturesCommandKey
                ) {
                    emit(packet)
                }
            }
            return true
        }

        let input: MacKeyboardEvent?
        if event.type == .flagsChanged {
            let wasDown = modifierKeysDown.contains(event.keyCode)
            if wasDown { modifierKeysDown.remove(event.keyCode) }
            else { modifierKeysDown.insert(event.keyCode) }
            input = .init(
                keyCode: event.keyCode,
                action: wasDown ? .up : .down,
                modifiers: MacKeyboardTranslator.modifierMask(from: event.modifierFlags),
                characterIgnoringModifiers: nil,
                isRepeat: false
            )
        } else {
            input = MacKeyboardTranslator.event(from: event)
        }
        guard let input else { return false }
        switch translator.translate(input, capturesCommandKey: capturesCommandKey) {
        case .packet(let packet):
            emit(packet)
            return true
        case .shortcut(let shortcut):
            onShortcut?(shortcut)
            return true
        case .ignored:
            return false
        }
    }

    /// Handles an event owned by the dedicated stream responder. Unmapped and
    /// repeat-down events are deliberately consumed instead of falling through
    /// to `NSResponder.keyDown`, which plays the macOS alert sound.
    public func consumeInStreamView(_ event: NSEvent) {
        _ = handle(event)
    }

    public func releaseAllKeys() {
        let pressed = heldKeys.sorted { $0.key < $1.key }
        heldKeys.removeAll()
        modifierKeysDown.removeAll()
        for (virtualKey, heldKey) in pressed {
            sink?.platformInputDidProduce(.keyboard(KeyboardPacket(
                virtualKey: virtualKey,
                action: .up,
                modifiers: [],
                isExtended: heldKey.isExtended,
                flags: heldKey.flags
            )))
        }
    }

    private func emit(_ packet: KeyboardPacket) {
        switch packet.action {
        case .down:
            heldKeys[packet.virtualKey] = HeldKey(
                isExtended: packet.isExtended,
                flags: packet.flags
            )
        case .up: heldKeys.removeValue(forKey: packet.virtualKey)
        }
        sink?.platformInputDidProduce(.keyboard(packet))
    }
}
