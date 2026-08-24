import Foundation

public struct PointerPreferences: Equatable, Sendable {
    public var mode: PointerMode
    public var swapPrimaryAndSecondaryButtons: Bool
    public var reverseScrollDirection: Bool
    public var clampAcceleratedScroll: Bool

    public init(
        mode: PointerMode = .relative,
        swapPrimaryAndSecondaryButtons: Bool = false,
        reverseScrollDirection: Bool = false,
        clampAcceleratedScroll: Bool = true
    ) {
        self.mode = mode
        self.swapPrimaryAndSecondaryButtons = swapPrimaryAndSecondaryButtons
        self.reverseScrollDirection = reverseScrollDirection
        self.clampAcceleratedScroll = clampAcceleratedScroll
    }
}

public enum PointerMode: Equatable, Sendable {
    case relative
    case absolute
}

public struct MouseInputMapper: Sendable {
    public var preferences: PointerPreferences

    public init(preferences: PointerPreferences) {
        self.preferences = preferences
    }

    public func mapButton(number: Int) -> MouseButton? {
        let mapped: MouseButton?
        switch number {
        case 0: mapped = .left
        case 1: mapped = .right
        case 2: mapped = .middle
        case 3: mapped = .back
        case 4: mapped = .forward
        default: mapped = nil
        }

        guard preferences.swapPrimaryAndSecondaryButtons else { return mapped }
        switch mapped {
        case .left: return .right
        case .right: return .left
        default: return mapped
        }
    }

    public func mapScroll(deltaX: Double, deltaY: Double) -> [ScrollPacket] {
        let direction = preferences.reverseScrollDirection ? -1.0 : 1.0
        return [
            scrollPacket(axis: .vertical, value: deltaY * direction),
            scrollPacket(axis: .horizontal, value: deltaX * direction),
        ].compactMap { $0 }
    }

    private func scrollPacket(axis: ScrollAxis, value: Double) -> ScrollPacket? {
        guard value != 0, value.isFinite else { return nil }
        let clamped = preferences.clampAcceleratedScroll ? min(max(value, -1), 1) : value
        let wheelUnits = min(max((clamped * 120).rounded(), Double(Int16.min)), Double(Int16.max))
        return ScrollPacket(axis: axis, delta: Int16(wheelUnits))
    }
}

public enum ClipboardTextNormalizer {
    /// Moonlight sends UTF-8 text to a Windows host. Collapsing CRLF avoids the host
    /// interpreting a single source line ending as two line breaks.
    public static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
