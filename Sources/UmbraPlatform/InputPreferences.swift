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
    private var verticalWheelRemainder: Double = 0
    private var horizontalWheelRemainder: Double = 0

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

    public mutating func mapScroll(deltaX: Double, deltaY: Double) -> [ScrollPacket] {
        let direction = preferences.reverseScrollDirection ? -1.0 : 1.0
        return [
            Self.scrollPacket(
                axis: .vertical,
                value: deltaY * direction,
                clampAcceleratedScroll: preferences.clampAcceleratedScroll,
                remainder: &verticalWheelRemainder
            ),
            Self.scrollPacket(
                axis: .horizontal,
                value: deltaX * direction,
                clampAcceleratedScroll: preferences.clampAcceleratedScroll,
                remainder: &horizontalWheelRemainder
            ),
        ].compactMap { $0 }
    }

    public mutating func resetScrollRemainders() {
        verticalWheelRemainder = 0
        horizontalWheelRemainder = 0
    }

    private static func scrollPacket(
        axis: ScrollAxis,
        value: Double,
        clampAcceleratedScroll: Bool,
        remainder: inout Double
    ) -> ScrollPacket? {
        guard value.isFinite else {
            remainder = 0
            return nil
        }
        guard value != 0 else { return nil }
        let clamped = clampAcceleratedScroll ? min(max(value, -1), 1) : value
        let total = clamped * 120 + remainder
        let whole = total.rounded(.towardZero)
        let wheelUnits = min(max(whole, Double(Int16.min)), Double(Int16.max))
        remainder = whole == wheelUnits ? total - wheelUnits : 0
        guard wheelUnits != 0 else { return nil }
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
