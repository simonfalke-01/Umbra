import AppKit
import SwiftUI
import UmbraMicrophone
import XCTest
@testable import UmbraApp

@MainActor
final class SettingsSnapshotTests: XCTestCase {
    private struct Appearance {
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
        let appKitName: NSAppearance.Name
        let name: String
    }

    private struct RenderedSettings {
        let representation: NSBitmapImageRep
        let height: CGFloat
        let windowIsResizable: Bool
        let verticalScrollMetrics: [ScrollMetrics]
    }

    private struct ScrollMetrics {
        let viewportWidth: CGFloat
        let documentWidth: CGFloat
        let viewportHeight: CGFloat
        let documentHeight: CGFloat
        let canScrollVertically: Bool

        var overflowsHorizontally: Bool {
            documentWidth > viewportWidth + 1
        }

        var overflowsVertically: Bool {
            documentHeight > viewportHeight + 1
        }
    }

    func testEverySettingsTabRendersAtIntrinsicOrScrollableWindowSize() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)

        var measuredHeights: [SettingsTab: CGFloat] = [:]
        for tab in SettingsTab.allCases {
            let appearances = [
                Appearance(scheme: .light, contrast: .standard, appKitName: .aqua, name: "light"),
                Appearance(scheme: .light, contrast: .increased, appKitName: .accessibilityHighContrastAqua, name: "light-increased-contrast"),
                Appearance(scheme: .dark, contrast: .standard, appKitName: .darkAqua, name: "dark"),
                Appearance(scheme: .dark, contrast: .increased, appKitName: .accessibilityHighContrastDarkAqua, name: "dark-increased-contrast"),
            ]
            var renderedPNGs: [String: Data] = [:]
            for appearance in appearances {
                let rendered = try render(
                    tab: tab,
                    appearance: appearance,
                    preferences: preferences
                )
                let representation = rendered.representation
                XCTAssertEqual(representation.size.width, UmbraLayout.settingsWidth)
                XCTAssertEqual(representation.size.height, rendered.height)
                let expectedScale = CGFloat(representation.pixelsWide) / UmbraLayout.settingsWidth
                XCTAssertEqual(
                    representation.pixelsHigh,
                    Int((rendered.height * expectedScale).rounded())
                )
                XCTAssertGreaterThanOrEqual(rendered.height, UmbraLayout.settingsMinimumHeight)
                XCTAssertLessThanOrEqual(rendered.height, UmbraLayout.settingsMaximumHeight)
                XCTAssertFalse(rendered.windowIsResizable)
                XCTAssertFalse(rendered.verticalScrollMetrics.isEmpty)
                for metrics in rendered.verticalScrollMetrics {
                    if metrics.overflowsVertically {
                        XCTAssertTrue(
                            metrics.canScrollVertically,
                            "An intrinsically tall pane must scroll inside the Settings viewport."
                        )
                    } else {
                        XCTAssertEqual(
                            metrics.viewportHeight,
                            metrics.documentHeight,
                            accuracy: 1,
                            "A compact pane must not retain an empty scroll viewport below its content."
                        )
                    }
                }
                if let existing = measuredHeights[tab] {
                    XCTAssertEqual(existing, rendered.height, accuracy: 1)
                } else {
                    measuredHeights[tab] = rendered.height
                }
                renderedPNGs[appearance.name] = try pngData(representation)
                try writeSnapshotIfRequested(representation, tab: tab, appearance: appearance)
            }
            XCTAssertNotEqual(renderedPNGs["light"], renderedPNGs["light-increased-contrast"])
            XCTAssertNotEqual(renderedPNGs["dark"], renderedPNGs["dark-increased-contrast"])
        }
        XCTAssertLessThan(try XCTUnwrap(measuredHeights[.audio]), try XCTUnwrap(measuredHeights[.video]))
        XCTAssertLessThan(try XCTUnwrap(measuredHeights[.audio]), try XCTUnwrap(measuredHeights[.advanced]))
    }

    func testExpandedVideoSettingsUseIntrinsicHeightWithoutEmptyScrollSpace() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update {
            $0.displayResolutionPolicy = .configured
            $0.width = 3_841
            $0.height = 2_161
            $0.setFrameRate(numerator: 60_000, denominator: 1_001)
            $0.autoAdjustBitrate = false
            $0.enableVSync = false
            $0.enableHDR = true
            $0.hdrTransferPreference = .hlg
        }

        let appearances = [
            Appearance(scheme: .light, contrast: .standard, appKitName: .aqua, name: "light-expanded"),
            Appearance(scheme: .light, contrast: .increased, appKitName: .accessibilityHighContrastAqua, name: "light-expanded-increased-contrast"),
            Appearance(scheme: .dark, contrast: .standard, appKitName: .darkAqua, name: "dark-expanded"),
            Appearance(scheme: .dark, contrast: .increased, appKitName: .accessibilityHighContrastDarkAqua, name: "dark-expanded-increased-contrast"),
        ]

        for appearance in appearances {
            let rendered = try render(
                tab: .video,
                appearance: appearance,
                preferences: preferences
            )
            XCTAssertLessThan(rendered.height, UmbraLayout.settingsMaximumHeight)
            XCTAssertFalse(
                rendered.verticalScrollMetrics.contains { $0.overflowsVertically },
                "The simplified video pane must not retain an unnecessary scroll viewport."
            )
            for metrics in rendered.verticalScrollMetrics {
                XCTAssertEqual(metrics.viewportHeight, metrics.documentHeight, accuracy: 1)
            }
            try writeSnapshotIfRequested(rendered.representation, tab: .video, appearance: appearance)
        }
    }

    func testEveryMicrophonePermissionStateRendersWithoutOverflow() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        let appearances = [
            Appearance(
                scheme: .light,
                contrast: .standard,
                appKitName: .aqua,
                name: "light"
            ),
            Appearance(
                scheme: .light,
                contrast: .increased,
                appKitName: .accessibilityHighContrastAqua,
                name: "light-increased-contrast"
            ),
            Appearance(
                scheme: .dark,
                contrast: .standard,
                appKitName: .darkAqua,
                name: "dark"
            ),
            Appearance(
                scheme: .dark,
                contrast: .increased,
                appKitName: .accessibilityHighContrastDarkAqua,
                name: "dark-increased-contrast"
            ),
        ]
        let states: [(
            name: String,
            state: MicrophonePermissionPresentationState,
            preferenceEnabled: Bool
        )] = [
            ("off", .notDetermined, false),
            ("requesting", .requesting, true),
            ("authorized", .authorized, true),
            ("denied", .denied, false),
            ("restricted", .restricted, false),
        ]
        var standardHeights: [String: CGFloat] = [:]

        for state in states {
            preferences.update(\.clientMicrophoneEnabled, to: state.preferenceEnabled)
            var renderedPNGs: [String: Data] = [:]
            for appearance in appearances {
                let authorizer = SnapshotMicrophoneAuthorizer(
                    status: authorizationStatus(for: state.state)
                )
                let rendered = try render(
                    tab: .audio,
                    appearance: Appearance(
                        scheme: appearance.scheme,
                        contrast: appearance.contrast,
                        appKitName: appearance.appKitName,
                        name: "\(appearance.name)-microphone-\(state.name)"
                    ),
                    preferences: preferences,
                    microphonePermissionEnvironment: MicrophonePermissionEnvironment(
                        authorizer: authorizer,
                        initialState: state.state,
                        applicationNotifications: NotificationCenter(),
                        openMicrophoneSettings: {}
                    )
                )
                XCTAssertLessThanOrEqual(rendered.height, UmbraLayout.settingsMaximumHeight)
                XCTAssertFalse(rendered.windowIsResizable)
                XCTAssertFalse(
                    rendered.verticalScrollMetrics.contains { $0.overflowsHorizontally },
                    "The \(state.name) microphone state must not create horizontal overflow."
                )
                if appearance.contrast == .standard {
                    standardHeights[state.name] = rendered.height
                }
                renderedPNGs[appearance.name] = try pngData(rendered.representation)
                try writeSnapshotIfRequested(
                    rendered.representation,
                    tab: .audio,
                    appearance: Appearance(
                        scheme: appearance.scheme,
                        contrast: appearance.contrast,
                        appKitName: appearance.appKitName,
                        name: "\(appearance.name)-microphone-\(state.name)"
                    )
                )
            }
            XCTAssertNotEqual(
                renderedPNGs["light"],
                renderedPNGs["light-increased-contrast"]
            )
            XCTAssertNotEqual(
                renderedPNGs["dark"],
                renderedPNGs["dark-increased-contrast"]
            )
        }

        let offHeight = try XCTUnwrap(standardHeights["off"])
        let authorizedHeight = try XCTUnwrap(standardHeights["authorized"])
        XCTAssertEqual(offHeight, authorizedHeight, accuracy: 1)
        XCTAssertGreaterThan(try XCTUnwrap(standardHeights["requesting"]), authorizedHeight)
        XCTAssertGreaterThan(try XCTUnwrap(standardHeights["denied"]), authorizedHeight)
        XCTAssertGreaterThan(try XCTUnwrap(standardHeights["restricted"]), authorizedHeight)
    }

    func testSettingsHeightClampsInvalidAndOversizedMeasurements() {
        XCTAssertEqual(
            UmbraLayout.settingsWindowHeight(contentHeight: nil),
            UmbraLayout.settingsMinimumHeight
        )
        XCTAssertEqual(
            UmbraLayout.settingsWindowHeight(contentHeight: .nan),
            UmbraLayout.settingsMinimumHeight
        )
        XCTAssertEqual(
            UmbraLayout.settingsWindowHeight(contentHeight: 1),
            UmbraLayout.settingsMinimumHeight
        )
        XCTAssertEqual(
            UmbraLayout.settingsWindowHeight(contentHeight: 10_000),
            UmbraLayout.settingsMaximumHeight
        )
    }

    func testSettingsRowGrowsForLongAccessibilitySizedLabel() {
        let view = SettingsRow(
            "A longer localized settings label\nthat needs a second line\nwithout clipping"
        ) {
            Text("Value")
        }
        .environment(\.dynamicTypeSize, .accessibility2)
        .frame(width: UmbraLayout.settingsWidth)
        let hostingView = NSHostingView(rootView: view)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, UmbraLayout.macOSControlHeight)
    }

    func testDisabledSettingsRowMakesDependencyReasonVisibleWithoutChangingWidth() {
        let enabledView = NSHostingView(rootView: SettingsRow("Frame pacing") {
            Toggle("", isOn: .constant(false)).labelsHidden()
        })
        let disabledView = NSHostingView(rootView: SettingsRow(
            "Frame pacing",
            isEnabled: false,
            disabledReason: "Turn on vertical sync to use frame pacing."
        ) {
            Toggle("", isOn: .constant(false)).labelsHidden()
        })

        enabledView.layoutSubtreeIfNeeded()
        disabledView.layoutSubtreeIfNeeded()

        XCTAssertEqual(enabledView.fittingSize.width, disabledView.fittingSize.width, accuracy: 0.5)
        XCTAssertGreaterThan(disabledView.fittingSize.height, enabledView.fittingSize.height)
    }

    func testWindowSizerCoalescesLatestSizeAndPreservesTopEdge() {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: UmbraLayout.settingsWidth, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let originalTopEdge = window.frame.maxY
        let controller = SettingsWindowSizingController(
            contentSize: CGSize(width: UmbraLayout.settingsWidth, height: 400)
        )
        controller.attach(to: window)
        controller.update(
            contentSize: CGSize(width: UmbraLayout.settingsWidth, height: 519)
        )
        controller.update(
            contentSize: CGSize(width: UmbraLayout.settingsWidth, height: 190)
        )

        XCTAssertEqual(window.contentLayoutRect.width, UmbraLayout.settingsWidth, accuracy: 0.5)
        XCTAssertEqual(window.contentLayoutRect.height, 190, accuracy: 0.5)
        XCTAssertEqual(window.frame.maxY, originalTopEdge, accuracy: 0.5)
        XCTAssertFalse(window.styleMask.contains(.resizable))

        controller.update(
            contentSize: CGSize(width: UmbraLayout.settingsWidth, height: 517)
        )

        XCTAssertEqual(window.contentLayoutRect.height, 517, accuracy: 0.5)
        XCTAssertEqual(window.frame.maxY, originalTopEdge, accuracy: 0.5)
    }

    func testWindowSizerRapidReplacementAndDetachCannotApplyStaleSize() {
        let firstWindow = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: UmbraLayout.settingsWidth, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: CGRect(x: 600, y: 200, width: UmbraLayout.settingsWidth, height: 450),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let firstTopEdge = firstWindow.frame.maxY
        let secondTopEdge = secondWindow.frame.maxY
        let controller = SettingsWindowSizingController(
            contentSize: CGSize(width: UmbraLayout.settingsWidth, height: 400)
        )

        controller.attach(to: firstWindow)
        controller.update(contentSize: CGSize(width: UmbraLayout.settingsWidth, height: 519))
        controller.update(contentSize: CGSize(width: UmbraLayout.settingsWidth, height: 191))
        controller.attach(to: nil)
        let detachedFirstFrame = firstWindow.frame

        controller.update(contentSize: CGSize(width: UmbraLayout.settingsWidth, height: 333))
        controller.attach(to: secondWindow)
        controller.update(contentSize: CGSize(width: UmbraLayout.settingsWidth, height: 521))
        controller.update(contentSize: CGSize(width: UmbraLayout.settingsWidth, height: 205))

        XCTAssertEqual(firstWindow.frame, detachedFirstFrame)
        XCTAssertEqual(firstWindow.contentLayoutRect.height, 191, accuracy: 0.5)
        XCTAssertEqual(firstWindow.frame.maxY, firstTopEdge, accuracy: 0.5)
        XCTAssertFalse(firstWindow.styleMask.contains(.resizable))
        XCTAssertEqual(secondWindow.contentLayoutRect.height, 205, accuracy: 0.5)
        XCTAssertEqual(secondWindow.frame.maxY, secondTopEdge, accuracy: 0.5)
        XCTAssertFalse(secondWindow.styleMask.contains(.resizable))

        controller.attach(to: nil)
        let detachedSecondFrame = secondWindow.frame
        controller.update(contentSize: CGSize(width: UmbraLayout.settingsWidth, height: 490))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertEqual(firstWindow.frame, detachedFirstFrame)
        XCTAssertEqual(secondWindow.frame, detachedSecondFrame)
    }

    private func render(
        tab: SettingsTab,
        appearance: Appearance,
        preferences: PreferencesStore,
        microphonePermissionEnvironment: MicrophonePermissionEnvironment? = nil
    ) throws -> RenderedSettings {
        let resolvedMicrophoneEnvironment = microphonePermissionEnvironment
            ?? MicrophonePermissionEnvironment(
                authorizer: SnapshotMicrophoneAuthorizer(status: .authorized),
                initialState: .authorized,
                applicationNotifications: NotificationCenter(),
                openMicrophoneSettings: {}
            )
        let view = ZStack {
            Color(nsColor: .windowBackgroundColor)
            UmbraSettingsView(
                preferences: preferences,
                initialSelection: tab,
                microphonePermissionEnvironment: resolvedMicrophoneEnvironment
            )
        }
        .environment(\.colorScheme, appearance.scheme)
        .environment(\._colorSchemeContrast, appearance.contrast)
        let hostingView = NSHostingView(rootView: view)
        let initialSize = CGSize(
            width: UmbraLayout.settingsWidth,
            height: UmbraLayout.settingsMaximumHeight
        )
        hostingView.frame = CGRect(origin: .zero, size: initialSize)
        hostingView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance.appKitName)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        var settledSizes: [CGSize] = []
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            hostingView.layoutSubtreeIfNeeded()
            if let size = window.contentView?.bounds.size {
                settledSizes.append(size)
            }
        }

        let size = try XCTUnwrap(window.contentView?.bounds.size)
        for settledSize in settledSizes.suffix(3) {
            XCTAssertEqual(settledSize.width, size.width, accuracy: 0.5)
            XCTAssertEqual(settledSize.height, size.height, accuracy: 0.5)
        }
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        XCTAssertEqual(size.width, UmbraLayout.settingsWidth, accuracy: 1)
        guard hostingView.bounds.size == size else {
            throw SnapshotError.geometryMismatch(actual: hostingView.bounds.size, expected: size)
        }

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw SnapshotError.bitmapUnavailable
        }
        representation.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let scrollMetrics = descendants(of: hostingView, type: NSScrollView.self)
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.height > 0 }
            .compactMap { scrollView -> ScrollMetrics? in
                guard let documentView = scrollView.documentView else { return nil }
                let initialOrigin = scrollView.contentView.bounds.origin
                let maximumOffset = max(
                    documentView.bounds.height - scrollView.contentView.bounds.height,
                    0
                )
                scrollView.contentView.scroll(
                    to: CGPoint(x: initialOrigin.x, y: maximumOffset)
                )
                scrollView.reflectScrolledClipView(scrollView.contentView)
                let scrolledOrigin = scrollView.contentView.bounds.origin
                scrollView.contentView.scroll(to: initialOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                return ScrollMetrics(
                    viewportWidth: scrollView.contentView.bounds.width,
                    documentWidth: documentView.bounds.width,
                    viewportHeight: scrollView.contentView.bounds.height,
                    documentHeight: documentView.bounds.height,
                    canScrollVertically: abs(scrolledOrigin.y - initialOrigin.y) > 1
                )
            }
        return RenderedSettings(
            representation: representation,
            height: size.height,
            windowIsResizable: window.styleMask.contains(.resizable),
            verticalScrollMetrics: scrollMetrics
        )
    }

    private func descendants<T: NSView>(of view: NSView, type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            (subview as? T).map { [$0] } ?? []
                + descendants(of: subview, type: type)
        }
    }

    private func writeSnapshotIfRequested(
        _ representation: NSBitmapImageRep,
        tab: SettingsTab,
        appearance: Appearance
    ) throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["UMBRA_UI_SNAPSHOT_DIR"] else {
            return
        }
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try pngData(representation)
        try png.write(to: directory.appendingPathComponent("settings-\(tab.rawValue)-\(appearance.name).png"))
    }

    private func pngData(_ representation: NSBitmapImageRep) throws -> Data {
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngUnavailable
        }
        return png
    }

    private func authorizationStatus(
        for state: MicrophonePermissionPresentationState
    ) -> ClientMicrophoneAuthorizationStatus {
        switch state {
        case .notDetermined, .requesting:
            .notDetermined
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        }
    }
}

private enum SnapshotError: Error {
    case bitmapUnavailable
    case pngUnavailable
    case geometryMismatch(actual: CGSize, expected: CGSize)
}

private struct SnapshotMicrophoneAuthorizer: ClientMicrophoneAuthorizing {
    let storedStatus: ClientMicrophoneAuthorizationStatus

    init(status: ClientMicrophoneAuthorizationStatus) {
        storedStatus = status
    }

    func status() -> ClientMicrophoneAuthorizationStatus {
        storedStatus
    }

    func requestAuthorization() async -> ClientMicrophoneAuthorizationStatus {
        storedStatus
    }
}
