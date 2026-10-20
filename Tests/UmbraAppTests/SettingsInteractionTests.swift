import AppKit
import SwiftUI
import UmbraCore
import UmbraMicrophone
import UmbraPlatform
import XCTest
@testable import UmbraApp

@MainActor
final class SettingsInteractionTests: XCTestCase {
    func testStreamingModePickerUsesTwoNativeChoicesAndAppliesTheSelectedProfile() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        let hostingView = NSHostingView(
            rootView: StreamOptimizationModePicker(preferences: preferences)
        )
        hostingView.frame = CGRect(x: 0, y: 0, width: 360, height: 40)
        settle(hostingView)

        let control = try XCTUnwrap(
            descendants(of: hostingView, type: NSSegmentedControl.self).first
        )
        XCTAssertEqual(control.segmentCount, 2)
        XCTAssertEqual(control.label(forSegment: 0), "Lowest Latency")
        XCTAssertEqual(control.label(forSegment: 1), "Best Quality")
        XCTAssertEqual(control.accessibilityLabel(), "Streaming mode")
        XCTAssertEqual(
            control.accessibilityHelp(),
            "Choose Lowest Latency or Best Quality."
        )

        control.selectedSegment = 0
        let action = try XCTUnwrap(control.action)
        XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control))
        settle(hostingView)

        XCTAssertEqual(preferences.settings.optimizationMode, .latency)
        XCTAssertFalse(preferences.settings.enableVSync)
        XCTAssertFalse(preferences.settings.framePacing)
    }

    func testLowLevelPresentationOverridesAppearOnlyInAdvancedSettings() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)

        let videoView = NSHostingView(rootView: UmbraSettingsView(
            preferences: preferences,
            initialSelection: .video
        ))
        videoView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: UmbraLayout.settingsWidth,
                height: UmbraLayout.settingsMaximumHeight
            )
        )
        settle(videoView)
        XCTAssertFalse(
            descendants(of: videoView, type: NSSwitch.self).contains {
                $0.accessibilityLabel() == "Vertical sync"
                    || $0.accessibilityLabel() == "Frame pacing"
            }
        )

        let advancedView = NSHostingView(rootView: UmbraSettingsView(
            preferences: preferences,
            initialSelection: .advanced
        ))
        advancedView.frame = videoView.frame
        settle(advancedView)
        let overrideLabels = Set(
            descendants(of: advancedView, type: NSSwitch.self)
                .compactMap { $0.accessibilityLabel() }
        )
        XCTAssertTrue(overrideLabels.contains("Vertical sync"))
        XCTAssertTrue(overrideLabels.contains("Frame pacing"))
    }

    func testSelectingCustomResolutionOpensEditorWithoutChangingPersistedDimensions() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.updateConfiguredResolution(width: 1_920, height: 1_080)

        let hostingView = NSHostingView(rootView: UmbraSettingsView(
            preferences: preferences,
            initialSelection: .video
        ))
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: UmbraLayout.settingsWidth,
                height: UmbraLayout.settingsMaximumHeight
            )
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        defer { window.close() }
        window.orderBack(nil)
        settle(hostingView)

        let resolutionPicker = try XCTUnwrap(
            descendants(of: hostingView, type: NSPopUpButton.self).first {
                $0.accessibilityLabel() == "Resolution"
            }
        )
        resolutionPicker.selectItem(withTitle: "Custom")
        let action = try XCTUnwrap(resolutionPicker.action)
        XCTAssertTrue(NSApp.sendAction(
            action,
            to: resolutionPicker.target,
            from: resolutionPicker
        ))
        settle(hostingView)

        let sheet = try XCTUnwrap(window.attachedSheet)
        let sheetContentView = try XCTUnwrap(sheet.contentView)
        settle(sheetContentView)
        XCTAssertEqual(preferences.settings.width, 1_920)
        XCTAssertEqual(preferences.settings.height, 1_080)
        XCTAssertEqual(preferences.settings.displayResolutionPolicy, .configured)
        XCTAssertNotNil(
            descendants(of: sheetContentView, type: NSTextField.self).first {
                $0.accessibilityLabel() == "Custom resolution width"
            }
        )
        XCTAssertNotNil(
            descendants(of: sheetContentView, type: NSTextField.self).first {
                $0.accessibilityLabel() == "Custom resolution height"
            }
        )
    }

    func testCustomFrameRateEditorOffersExactFractionWithoutDuplicateSheets() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.updateFrameRate(60)

        let hostingView = NSHostingView(rootView: UmbraSettingsView(
            preferences: preferences,
            initialSelection: .video
        ))
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: UmbraLayout.settingsWidth,
                height: UmbraLayout.settingsMaximumHeight
            )
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        defer { window.close() }
        window.orderBack(nil)
        settle(hostingView)

        let frameRatePicker = try XCTUnwrap(
            descendants(of: hostingView, type: NSPopUpButton.self).first {
                $0.accessibilityLabel() == "Frame rate"
            }
        )
        frameRatePicker.selectItem(withTitle: "Custom")
        let action = try XCTUnwrap(frameRatePicker.action)
        XCTAssertTrue(NSApp.sendAction(
            action,
            to: frameRatePicker.target,
            from: frameRatePicker
        ))
        settle(hostingView)

        let sheet = try XCTUnwrap(window.attachedSheet)
        frameRatePicker.selectItem(withTitle: "Custom")
        XCTAssertTrue(NSApp.sendAction(action, to: frameRatePicker.target, from: frameRatePicker))
        settle(hostingView)
        XCTAssertEqual(window.sheets.count, 1)
        XCTAssertEqual(preferences.settings.fps, 60)

        let sheetContentView = try XCTUnwrap(sheet.contentView)
        let frameRateField = try XCTUnwrap(
            descendants(of: sheetContentView, type: NSTextField.self).first {
                $0.accessibilityLabel() == "Custom frame rate"
            }
        )
        XCTAssertEqual(frameRateField.placeholderString, "60 or 60000/1001")
        XCTAssertEqual(frameRateField.stringValue, "60")
        XCTAssertEqual(preferences.settings.fps, 60)
    }

    func testCustomFrameRateParserAcceptsExactFractionAndRejectsInvalidValues() {
        for (text, numerator, denominator) in [
            ("10", 10, 1),
            ("120", 120, 1),
            ("60000/1001", 60_000, 1_001),
            ("480", 480, 1),
            ("480000000/1000000", 480_000_000, 1_000_000),
        ] {
            let value = CustomFrameRateValue(text: text)
            XCTAssertEqual(value?.numerator, numerator, text)
            XCTAssertEqual(value?.denominator, denominator, text)
        }

        for text in [
            "0",
            "1",
            "9",
            "481",
            "60000/0",
            "9223372036854775807/1",
            "120/1/1",
            "not-a-rate",
        ] {
            XCTAssertNil(CustomFrameRateValue(text: text), text)
        }
    }

    func testResetAllSynchronizesPacketSizeFieldText() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update(\.packetSize, to: 1_392)
        let hostingView = NSHostingView(rootView: PacketSizeField(preferences: preferences))
        hostingView.frame = CGRect(x: 0, y: 0, width: 240, height: 80)
        settle(hostingView)

        let packetSizeField = try XCTUnwrap(
            descendants(of: hostingView, type: NSTextField.self).first {
                $0.placeholderString == "Automatic"
            }
        )
        XCTAssertEqual(packetSizeField.stringValue, "1392")

        preferences.resetAll()
        settle(hostingView)

        XCTAssertEqual(packetSizeField.stringValue, "")
        XCTAssertEqual(packetSizeField.accessibilityLabel(), "Network packet size")
    }

    func testCustomResolutionAndPacketSizeFieldsHaveExplicitAccessibilityNames() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.updateConfiguredResolution(width: 3_841, height: 2_161)
        let resolutionView = NSHostingView(rootView: CustomResolutionControl(preferences: preferences))
        resolutionView.frame = CGRect(x: 0, y: 0, width: 360, height: 40)
        settle(resolutionView)
        let stepperLabels = Set(
            descendants(of: resolutionView, type: NSStepper.self)
                .compactMap { $0.accessibilityLabel() }
        )
        XCTAssertTrue(stepperLabels.contains("Custom resolution width"))
        XCTAssertTrue(stepperLabels.contains("Custom resolution height"))

        let packetSizeView = NSHostingView(rootView: PacketSizeField(preferences: preferences))
        packetSizeView.frame = CGRect(x: 0, y: 0, width: 240, height: 80)
        settle(packetSizeView)
        let packetSizeField = try XCTUnwrap(
            descendants(of: packetSizeView, type: NSTextField.self).first {
                $0.accessibilityLabel() == "Network packet size"
            }
        )
        XCTAssertTrue(packetSizeField.accessibilityHelp()?.contains("Automatic") == true)
    }

    func testFramePacingDisabledStateExplainsVSyncDependency() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update(\.enableVSync, to: false)

        let toggle = PreferenceToggle(
            "Frame pacing",
            message: "Reduces micro-stutter by delaying frames that arrive early.",
            binding: .constant(false),
            enabled: false,
            disabledReason: "Turn on vertical sync to use frame pacing."
        )
        XCTAssertTrue(toggle.accessibilityHint.contains("vertical sync"))
        XCTAssertTrue(toggle.accessibilityHint.contains("micro-stutter"))
    }

    func testControllerSettingsUseMacPlatformLanguageWithoutImplementationLabels() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        let hostingView = NSHostingView(rootView: UmbraSettingsView(
            preferences: preferences,
            initialSelection: .gamepad
        ))
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: UmbraLayout.settingsWidth,
                height: UmbraLayout.settingsMaximumHeight
            )
        )
        settle(hostingView)

        let switchLabels = Set(
            descendants(of: hostingView, type: NSSwitch.self)
                .compactMap { $0.accessibilityLabel() }
        )
        XCTAssertTrue(switchLabels.contains("Keep one controller connected"))
        XCTAssertTrue(switchLabels.contains("Allow controller input in the background"))
        XCTAssertFalse(switchLabels.contains { $0.contains("Gamepad #1") })
        XCTAssertFalse(switchLabels.contains { $0.contains("Accept gamepad input") })
    }

    func testPersistedHDRCanBeTurnedOffWithoutAnHDRCapableDisplay() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update(\.enableHDR, to: true)
        let hostingView = NSHostingView(rootView: HDRPreferenceToggle(
            preferences: preferences,
            hdrAvailable: false
        ))
        hostingView.frame = CGRect(x: 0, y: 0, width: UmbraLayout.settingsWidth, height: 96)
        settle(hostingView)

        let hdrControl = try XCTUnwrap(
            descendants(of: hostingView, type: NSControl.self).first {
                $0.accessibilityLabel() == "HDR"
            }
        )
        XCTAssertTrue(hdrControl.isEnabled)

        let hdrSwitch = try XCTUnwrap(hdrControl as? NSSwitch)
        hdrSwitch.performClick(nil)
        settle(hostingView)

        XCTAssertFalse(preferences.settings.enableHDR)
        let updatedControl = try XCTUnwrap(
            descendants(of: hostingView, type: NSControl.self).first {
                $0.accessibilityLabel() == "HDR"
            }
        )
        XCTAssertFalse(updatedControl.isEnabled)
    }

    func testHDRTransferPickerUsesNativeOptionsAndPersistsSelection() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update(\.enableHDR, to: true)
        let hostingView = NSHostingView(rootView: UmbraSettingsView(
            preferences: preferences,
            initialSelection: .video,
            hdrDisplaySupportResolver: HDRDisplaySupportResolver { _, _ in true }
        ))
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: UmbraLayout.settingsWidth,
                height: UmbraLayout.settingsMaximumHeight
            )
        )
        settle(hostingView)

        let picker = try XCTUnwrap(
            descendants(of: hostingView, type: NSPopUpButton.self).first {
                $0.accessibilityLabel() == "HDR transfer"
            }
        )
        XCTAssertEqual(picker.itemTitles, ["Auto", "PQ", "HLG"])
        XCTAssertEqual(picker.accessibilityValue() as? String, "Auto")
        XCTAssertTrue(picker.isEnabled)

        picker.selectItem(withTitle: "HLG")
        let action = try XCTUnwrap(picker.action)
        XCTAssertTrue(NSApp.sendAction(action, to: picker.target, from: picker))
        settle(hostingView)

        XCTAssertEqual(preferences.settings.hdrTransferPreference, .hlg)
        XCTAssertEqual(
            PreferencesStore(defaults: defaults).settings.hdrTransferPreference,
            .hlg
        )

        preferences.update(\.enableHDR, to: false)
        settle(hostingView)
        XCTAssertFalse(picker.isEnabled)
        XCTAssertEqual(picker.titleOfSelectedItem, "HLG")
    }

    func testAdvancedSettingsPreservesStoredYUV444IntentUntilCapabilityIsProven() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var stored = StreamingPreferences.default
        stored.enableYUV444 = true
        stored.bitrateKbps = StreamingPreferences.defaultBitrateKbps(
            width: stored.width,
            height: stored.height,
            fps: stored.fps,
            yuv444: true
        )
        defaults.set(try JSONEncoder().encode(stored), forKey: "Umbra.streamingPreferences")
        let preferences = PreferencesStore(defaults: defaults)
        let hostingView = NSHostingView(rootView: UmbraSettingsView(
            preferences: preferences,
            initialSelection: .advanced
        ))
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: UmbraLayout.settingsWidth,
                height: UmbraLayout.settingsMaximumHeight
            )
        )
        settle(hostingView)

        XCTAssertFalse(
            descendants(of: hostingView, type: NSControl.self).contains {
                $0.accessibilityLabel() == "Enable YUV 4:4:4"
            }
        )
        XCTAssertTrue(preferences.settings.enableYUV444)
        XCTAssertEqual(preferences.settings.bitrateKbps, 20_000)
    }

    func testGeneralSettingsDoesNotExposeConfigurationWarningToggle() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        let hostingView = NSHostingView(rootView: UmbraSettingsView(
            preferences: preferences,
            initialSelection: .general
        ))
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: UmbraLayout.settingsWidth,
                height: UmbraLayout.settingsMaximumHeight
            )
        )
        settle(hostingView)

        XCTAssertFalse(
            descendants(of: hostingView, type: NSControl.self).contains {
                $0.accessibilityLabel() == "Show configuration warnings"
            }
        )
    }

    func testAdvancedRendererPickerReflectsNormalizedStoredSelection() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var stored = StreamingPreferences.default
        stored.rendererPreference = .vulkan
        defaults.set(try JSONEncoder().encode(stored), forKey: "Umbra.streamingPreferences")
        let preferences = PreferencesStore(defaults: defaults)
        let hostingView = NSHostingView(rootView: UmbraSettingsView(
            preferences: preferences,
            initialSelection: .advanced
        ))
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: UmbraLayout.settingsWidth,
                height: UmbraLayout.settingsMaximumHeight
            )
        )
        settle(hostingView)

        let rendererPicker = try XCTUnwrap(
            descendants(of: hostingView, type: NSPopUpButton.self).first {
                $0.accessibilityLabel() == "Renderer"
            }
        )
        XCTAssertEqual(rendererPicker.titleOfSelectedItem, "Automatic")
        XCTAssertNil(rendererPicker.item(withTitle: "Vulkan"))
        XCTAssertNotNil(rendererPicker.item(withTitle: "System Renderer"))
    }

    func testDisplayModePickerExposesAndSelectsNativeFullscreen() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        let hostingView = NSHostingView(rootView: UmbraSettingsView(
            preferences: preferences,
            initialSelection: .video
        ))
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: UmbraLayout.settingsWidth,
                height: UmbraLayout.settingsMaximumHeight
            )
        )
        settle(hostingView)

        let displayModePicker = try XCTUnwrap(
            descendants(of: hostingView, type: NSPopUpButton.self).first {
                $0.accessibilityLabel() == "Window mode"
            }
        )
        XCTAssertEqual(displayModePicker.itemTitles, [
            "Windowed",
            "Borderless Windowed",
            "Fullscreen",
        ])

        displayModePicker.selectItem(withTitle: "Fullscreen")
        let action = try XCTUnwrap(displayModePicker.action)
        XCTAssertTrue(NSApp.sendAction(
            action,
            to: displayModePicker.target,
            from: displayModePicker
        ))
        settle(hostingView)

        XCTAssertEqual(preferences.settings.windowMode, .fullscreen)
        XCTAssertEqual(displayModePicker.titleOfSelectedItem, "Fullscreen")
    }

    func testMicrophoneEnableRequestsOnceAndAuthorizedPreferenceStaysOn() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        let authorizer = FakeMicrophoneAuthorizer(
            status: .notDetermined,
            requestResult: .authorized
        )
        let permissionModel = MicrophonePermissionSettingsModel(authorizer: authorizer)
        let permissionEnvironment = MicrophonePermissionEnvironment(
            permissionModel: permissionModel,
            applicationNotifications: NotificationCenter(),
            openMicrophoneSettings: {}
        )
        let hostingView = NSHostingView(rootView: AudioSettingsView(
            preferences: preferences,
            microphonePermissionEnvironment: permissionEnvironment
        ))
        hostingView.frame = CGRect(
            x: 0,
            y: 0,
            width: UmbraLayout.settingsWidth,
            height: UmbraLayout.settingsMaximumHeight
        )
        settle(hostingView)

        let microphoneSwitch = try XCTUnwrap(
            descendants(of: hostingView, type: NSSwitch.self).first {
                $0.accessibilityLabel() == "Use Mac microphone on host"
            }
        )
        XCTAssertEqual(microphoneSwitch.accessibilityRole(), .button)
        XCTAssertEqual(microphoneSwitch.accessibilitySubrole(), .switch)
        XCTAssertTrue(microphoneSwitch.acceptsFirstResponder)

        microphoneSwitch.performClick(nil)
        settle(hostingView)

        XCTAssertTrue(preferences.settings.clientMicrophoneEnabled)
        XCTAssertEqual(microphoneSwitch.state, .on)
        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(permissionModel.presentationState, .authorized)

        let requiredSwitch = try XCTUnwrap(
            descendants(of: hostingView, type: NSSwitch.self).first {
                $0.accessibilityLabel() == "Require microphone for streaming"
            }
        )
        XCTAssertTrue(requiredSwitch.isEnabled)
        requiredSwitch.performClick(nil)
        settle(hostingView)
        XCTAssertTrue(preferences.settings.clientMicrophoneRequired)

        let authorizedSwitch = try XCTUnwrap(
            descendants(of: hostingView, type: NSSwitch.self).first {
                $0.accessibilityLabel() == "Use Mac microphone on host"
            }
        )
        authorizedSwitch.performClick(nil)
        settle(hostingView)
        XCTAssertFalse(preferences.settings.clientMicrophoneEnabled)
        XCTAssertFalse(preferences.settings.clientMicrophoneRequired)
        XCTAssertEqual(authorizer.requestCount, 1)

        let disabledSwitch = try XCTUnwrap(
            descendants(of: hostingView, type: NSSwitch.self).first {
                $0.accessibilityLabel() == "Use Mac microphone on host"
            }
        )
        disabledSwitch.performClick(nil)
        settle(hostingView)
        XCTAssertTrue(preferences.settings.clientMicrophoneEnabled)
        XCTAssertEqual(authorizer.requestCount, 1)
    }

    func testMicrophoneDeniedReturnsSwitchOffAndOffersSpecificRecoveryAction() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        let authorizer = FakeMicrophoneAuthorizer(
            status: .notDetermined,
            requestResult: .denied
        )
        var openSettingsCount = 0
        let permissionModel = MicrophonePermissionSettingsModel(authorizer: authorizer)
        let permissionEnvironment = MicrophonePermissionEnvironment(
            permissionModel: permissionModel,
            applicationNotifications: NotificationCenter(),
            openMicrophoneSettings: { openSettingsCount += 1 }
        )
        let hostingView = NSHostingView(rootView: AudioSettingsView(
            preferences: preferences,
            microphonePermissionEnvironment: permissionEnvironment
        ))
        hostingView.frame = CGRect(
            x: 0,
            y: 0,
            width: UmbraLayout.settingsWidth,
            height: UmbraLayout.settingsMaximumHeight
        )
        settle(hostingView)

        let microphoneSwitch = try XCTUnwrap(
            descendants(of: hostingView, type: NSSwitch.self).first {
                $0.accessibilityLabel() == "Use Mac microphone on host"
            }
        )
        microphoneSwitch.performClick(nil)
        settle(hostingView)

        XCTAssertFalse(preferences.settings.clientMicrophoneEnabled)
        XCTAssertEqual(microphoneSwitch.state, .off)
        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(permissionModel.presentationState, .denied)
        XCTAssertEqual(
            MicrophonePermissionSettingsCopy.openSettingsTitle,
            "Open Microphone Settings"
        )
        XCTAssertEqual(
            MicrophonePermissionSettingsCopy.openSettingsAccessibilityHelp,
            "Opens Microphone settings in System Settings."
        )
        permissionEnvironment.openMicrophoneSettings()
        XCTAssertEqual(openSettingsCount, 1)

        let deniedSwitch = try XCTUnwrap(
            descendants(of: hostingView, type: NSSwitch.self).first {
                $0.accessibilityLabel() == "Use Mac microphone on host"
            }
        )
        deniedSwitch.performClick(nil)
        settle(hostingView)
        XCTAssertFalse(preferences.settings.clientMicrophoneEnabled)
        XCTAssertEqual(authorizer.requestCount, 1)
    }

    func testRestrictedMicrophoneNeverPromptsAndKeepsPreferenceOff() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        let authorizer = FakeMicrophoneAuthorizer(
            status: .restricted,
            requestResult: .restricted
        )
        let permissionModel = MicrophonePermissionSettingsModel(authorizer: authorizer)
        let hostingView = NSHostingView(rootView: AudioSettingsView(
            preferences: preferences,
            microphonePermissionEnvironment: MicrophonePermissionEnvironment(
                permissionModel: permissionModel,
                applicationNotifications: NotificationCenter(),
                openMicrophoneSettings: {}
            )
        ))
        hostingView.frame = CGRect(
            x: 0,
            y: 0,
            width: UmbraLayout.settingsWidth,
            height: UmbraLayout.settingsMaximumHeight
        )
        settle(hostingView)

        let microphoneSwitch = try XCTUnwrap(
            descendants(of: hostingView, type: NSSwitch.self).first {
                $0.accessibilityLabel() == "Use Mac microphone on host"
            }
        )
        microphoneSwitch.performClick(nil)
        settle(hostingView)

        XCTAssertFalse(preferences.settings.clientMicrophoneEnabled)
        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(permissionModel.presentationState, .restricted)
    }

    func testMicrophonePermissionRefreshesWhenApplicationBecomesActive() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        let authorizer = FakeMicrophoneAuthorizer(
            status: .denied,
            requestResult: .denied
        )
        let notifications = NotificationCenter()
        let permissionModel = MicrophonePermissionSettingsModel(authorizer: authorizer)
        let hostingView = NSHostingView(rootView: AudioSettingsView(
            preferences: preferences,
            microphonePermissionEnvironment: MicrophonePermissionEnvironment(
                permissionModel: permissionModel,
                applicationNotifications: notifications,
                openMicrophoneSettings: {}
            )
        ))
        hostingView.frame = CGRect(
            x: 0,
            y: 0,
            width: UmbraLayout.settingsWidth,
            height: UmbraLayout.settingsMaximumHeight
        )
        settle(hostingView)
        XCTAssertEqual(permissionModel.presentationState, .denied)

        authorizer.setStatus(.authorized)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        settle(hostingView)
        XCTAssertEqual(permissionModel.presentationState, .authorized)

        preferences.update(\.clientMicrophoneEnabled, to: true)
        preferences.update(\.clientMicrophoneRequired, to: true)
        authorizer.setStatus(.denied)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        settle(hostingView)
        XCTAssertTrue(preferences.settings.clientMicrophoneEnabled)
        XCTAssertTrue(preferences.settings.clientMicrophoneRequired)
        XCTAssertEqual(permissionModel.presentationState, .denied)
    }

    func testMicrophonePermissionModelCoalescesConcurrentRequests() async {
        let authorizer = FakeMicrophoneAuthorizer(
            status: .notDetermined,
            requestResult: .authorized,
            requestDelayNanoseconds: 30_000_000
        )
        let model = MicrophonePermissionSettingsModel(authorizer: authorizer)

        let firstRequest = Task { await model.requestAuthorization() }
        await Task.yield()
        let secondRequest = Task { await model.requestAuthorization() }
        await Task.yield()

        XCTAssertEqual(model.presentationState, .requesting)
        XCTAssertEqual(authorizer.requestCount, 1)
        let firstStatus = await firstRequest.value
        let secondStatus = await secondRequest.value
        XCTAssertEqual(firstStatus, .authorized)
        XCTAssertEqual(secondStatus, .authorized)
        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(model.presentationState, .authorized)
    }

    func testSystemShortcutPermissionRefreshReadsBothLivePermissions() {
        let probe = FakeSystemShortcutPermissionProbe(
            snapshot: .init(
                inputMonitoringGranted: false,
                accessibilityGranted: false,
                isAppSandboxed: false
            )
        )
        let model = probe.makeModel()

        XCTAssertEqual(model.snapshot.missingPermissions, [.inputMonitoring, .accessibility])
        probe.snapshot.inputMonitoringGranted = true
        model.refresh()
        XCTAssertEqual(model.snapshot.missingPermissions, [.accessibility])
        probe.snapshot.accessibilityGranted = true
        model.refresh()

        XCTAssertTrue(model.snapshot.missingPermissions.isEmpty)
        XCTAssertEqual(probe.snapshotReadCount, 3)
    }

    func testSystemShortcutPermissionRequestOnlyPromptsForMissingPermissions() {
        let probe = FakeSystemShortcutPermissionProbe(
            snapshot: .init(
                inputMonitoringGranted: false,
                accessibilityGranted: true,
                isAppSandboxed: false
            )
        )
        let model = probe.makeModel()

        model.requestMissingPermissions()

        XCTAssertEqual(probe.inputMonitoringRequestCount, 1)
        XCTAssertEqual(probe.accessibilityRequestCount, 0)
        XCTAssertTrue(model.snapshot.missingPermissions.isEmpty)
    }

    func testInputSettingsRemovesHelperCopyAndRefreshesPermissionsOnActivation() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update(\.captureSystemKeysMode, to: .always)
        let notifications = NotificationCenter()
        let probe = FakeSystemShortcutPermissionProbe(
            snapshot: .init(
                inputMonitoringGranted: false,
                accessibilityGranted: false,
                isAppSandboxed: false
            )
        )
        let model = probe.makeModel()
        let hostingView = NSHostingView(rootView: InputSettingsView(
            preferences: preferences,
            systemShortcutPermissionEnvironment: .init(
                permissionModel: model,
                applicationNotifications: notifications
            )
        ))
        hostingView.frame = CGRect(
            x: 0,
            y: 0,
            width: UmbraLayout.settingsWidth,
            height: UmbraLayout.settingsMaximumHeight
        )
        settle(hostingView)

        let renderedCopy = descendants(of: hostingView, type: NSTextField.self)
            .map(\.stringValue)
            .joined(separator: " ")
        XCTAssertFalse(renderedCopy.contains(
            "Only system shortcuts need Input Monitoring and Accessibility."
        ))

        probe.snapshot.inputMonitoringGranted = true
        probe.snapshot.accessibilityGranted = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        settle(hostingView)
        XCTAssertTrue(model.snapshot.missingPermissions.isEmpty)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func descendants<View: NSView>(
        of root: NSView?,
        type: View.Type
    ) -> [View] {
        guard let root else { return [] }
        var matches = (root as? View).map { [$0] } ?? []
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: subview, type: type))
        }
        return matches
    }
}

private final class FakeMicrophoneAuthorizer: ClientMicrophoneAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var currentStatus: ClientMicrophoneAuthorizationStatus
    private let requestResult: ClientMicrophoneAuthorizationStatus
    private let requestDelayNanoseconds: UInt64
    private var storedRequestCount = 0

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    init(
        status: ClientMicrophoneAuthorizationStatus,
        requestResult: ClientMicrophoneAuthorizationStatus,
        requestDelayNanoseconds: UInt64 = 0
    ) {
        currentStatus = status
        self.requestResult = requestResult
        self.requestDelayNanoseconds = requestDelayNanoseconds
    }

    func status() -> ClientMicrophoneAuthorizationStatus {
        lock.withLock { currentStatus }
    }

    func requestAuthorization() async -> ClientMicrophoneAuthorizationStatus {
        lock.withLock { storedRequestCount += 1 }
        if requestDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: requestDelayNanoseconds)
        }
        lock.withLock { currentStatus = requestResult }
        return requestResult
    }

    func setStatus(_ status: ClientMicrophoneAuthorizationStatus) {
        lock.withLock { currentStatus = status }
    }
}

@MainActor
private final class FakeSystemShortcutPermissionProbe {
    var snapshot: SystemShortcutPermissionSnapshot
    private(set) var snapshotReadCount = 0
    private(set) var inputMonitoringRequestCount = 0
    private(set) var accessibilityRequestCount = 0

    init(snapshot: SystemShortcutPermissionSnapshot) {
        self.snapshot = snapshot
    }

    func makeModel() -> SystemShortcutPermissionSettingsModel {
        SystemShortcutPermissionSettingsModel(
            snapshotReader: { [unowned self] in
                snapshotReadCount += 1
                return snapshot
            },
            requestInputMonitoring: { [unowned self] in
                inputMonitoringRequestCount += 1
                snapshot.inputMonitoringGranted = true
                return true
            },
            requestAccessibility: { [unowned self] _ in
                accessibilityRequestCount += 1
                snapshot.accessibilityGranted = true
            }
        )
    }
}
