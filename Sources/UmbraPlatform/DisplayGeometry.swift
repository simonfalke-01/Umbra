import AppKit
import CoreGraphics
import Foundation

public struct DisplayEdgeInsets: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public init(_ insets: NSEdgeInsets) {
        self.init(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
    }
}

public struct DisplayModeDescriptor: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var isNative: Bool

    public init(width: Int, height: Int, isNative: Bool) {
        self.width = width
        self.height = height
        self.isNative = isNative
    }
}

public struct NativeDisplayGeometry: Equatable, Sendable {
    public var fullPixelSize: CGSize
    public var safePixelSize: CGSize

    public init(fullPixelSize: CGSize, safePixelSize: CGSize) {
        self.fullPixelSize = fullPixelSize
        self.safePixelSize = safePixelSize
    }

    public var hasDisplayCutout: Bool { fullPixelSize != safePixelSize }
}

public enum DisplayGeometry {
    public static func nativeGeometry(
        modes: [DisplayModeDescriptor],
        isBuiltIn: Bool
    ) -> NativeDisplayGeometry? {
        guard let native = modes.first(where: \.isNative) else { return nil }
        let fullSize = CGSize(width: native.width, height: native.height)
        guard isBuiltIn else {
            return NativeDisplayGeometry(fullPixelSize: fullSize, safePixelSize: fullSize)
        }
        let safeHeight = modes
            .filter {
                $0.width == native.width
                    && $0.height < native.height
                    && native.height - $0.height <= 100
            }
            .map(\.height)
            .max() ?? native.height
        return NativeDisplayGeometry(
            fullPixelSize: fullSize,
            safePixelSize: CGSize(width: native.width, height: safeHeight)
        )
    }

    public static func nativeGeometry(for displayID: CGDirectDisplayID) -> NativeDisplayGeometry? {
        guard let displayModes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode]
        else { return nil }
        let nativeFlag = UInt32(kDisplayModeNativeFlag)
        return nativeGeometry(
            modes: displayModes.map {
                DisplayModeDescriptor(
                    width: $0.width,
                    height: $0.height,
                    isNative: $0.ioFlags & nativeFlag != 0
                )
            },
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0
        )
    }

    public static func effectiveRefreshRate(
        currentModeRefreshRate: Double,
        maximumFramesPerSecond: Int
    ) -> Double {
        currentModeRefreshRate > 0
            ? currentModeRefreshRate
            : Double(max(maximumFramesPerSecond, 1))
    }

    public static func nativePixelSize(
        fullPixelSize: CGSize,
        pointSize: CGSize,
        safeAreaInsets: DisplayEdgeInsets,
        excludingDisplayCutouts: Bool
    ) -> CGSize {
        guard excludingDisplayCutouts else { return fullPixelSize }
        let horizontalScale = fullPixelSize.width / max(pointSize.width, 1)
        let verticalScale = fullPixelSize.height / max(pointSize.height, 1)
        let horizontalInsets = max(0, safeAreaInsets.left) + max(0, safeAreaInsets.right)
        let verticalInsets = max(0, safeAreaInsets.top) + max(0, safeAreaInsets.bottom)
        return CGSize(
            width: max(0, fullPixelSize.width - horizontalInsets * horizontalScale),
            height: max(0, fullPixelSize.height - verticalInsets * verticalScale)
        )
    }

    public static func borderlessFrame(
        fullFrame: CGRect,
        safeAreaInsets: DisplayEdgeInsets,
        excludingDisplayCutouts: Bool
    ) -> CGRect {
        guard excludingDisplayCutouts else { return fullFrame }

        let left = max(0, safeAreaInsets.left)
        let right = max(0, safeAreaInsets.right)
        let top = max(0, safeAreaInsets.top)
        let bottom = max(0, safeAreaInsets.bottom)

        return CGRect(
            x: fullFrame.minX + min(left, fullFrame.width),
            y: fullFrame.minY + min(bottom, fullFrame.height),
            width: max(0, fullFrame.width - left - right),
            height: max(0, fullFrame.height - top - bottom)
        )
    }

    @MainActor
    public static func borderlessFrame(for screen: NSScreen, excludingDisplayCutouts: Bool) -> CGRect {
        borderlessFrame(
            fullFrame: screen.frame,
            safeAreaInsets: DisplayEdgeInsets(screen.safeAreaInsets),
            excludingDisplayCutouts: excludingDisplayCutouts
        )
    }
}

/// Resolves a usable display in deterministic priority order while tolerating hot-plug removal.
public enum DisplaySelectionResolver {
    public static func resolve(
        availableDisplayIDs: [CGDirectDisplayID],
        preferredDisplayID: CGDirectDisplayID?,
        currentDisplayID: CGDirectDisplayID?,
        uiDisplayID: CGDirectDisplayID?,
        mainDisplayID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        let available = Set(availableDisplayIDs)
        for candidate in [preferredDisplayID, currentDisplayID, uiDisplayID, mainDisplayID].compactMap({ $0 }) {
            if available.contains(candidate) {
                return candidate
            }
        }
        return availableDisplayIDs.first
    }
}

@MainActor
public enum AppKitDisplaySelection {
    public static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    public static func resolveScreen(
        preferredDisplayID: CGDirectDisplayID?,
        currentScreen: NSScreen?,
        uiScreen: NSScreen?,
        mainScreen: NSScreen? = NSScreen.main,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSScreen? {
        let screensByID = screens.reduce(into: [CGDirectDisplayID: NSScreen]()) { result, screen in
            if let displayID = displayID(for: screen) {
                result[displayID] = screen
            }
        }
        let resolvedID = DisplaySelectionResolver.resolve(
            availableDisplayIDs: screens.compactMap(displayID(for:)),
            preferredDisplayID: preferredDisplayID,
            currentDisplayID: displayID(for: currentScreen),
            uiDisplayID: displayID(for: uiScreen),
            mainDisplayID: displayID(for: mainScreen)
        )
        return resolvedID.flatMap { screensByID[$0] }
    }
}
