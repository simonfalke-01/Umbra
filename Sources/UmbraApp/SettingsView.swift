import AppKit
import Combine
import SwiftUI
import UmbraCore
import UmbraMicrophone
import UmbraPlatform

enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case video
    case audio
    case input
    case gamepad
    case advanced

}

private enum ResolutionPreset: String, CaseIterable, Identifiable {
    case native
    case nativeExcludingNotch
    case p720
    case p1080
    case p1440
    case p4K
    case custom

    var id: Self { self }
    var label: String {
        switch self {
        case .native: "Native"
        case .nativeExcludingNotch: "Native (Excluding Notch)"
        case .p720: "720p (1280 × 720)"
        case .p1080: "1080p (1920 × 1080)"
        case .p1440: "1440p (2560 × 1440)"
        case .p4K: "4K (3840 × 2160)"
        case .custom: "Custom"
        }
    }

    var dimensions: (width: Int, height: Int)? {
        switch self {
        case .native, .nativeExcludingNotch: nil
        case .p720: (1_280, 720)
        case .p1080: (1_920, 1_080)
        case .p1440: (2_560, 1_440)
        case .p4K: (3_840, 2_160)
        case .custom: nil
        }
    }
}

private enum FrameRatePreset: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60
    case custom = -1

    var id: Self { self }
    var label: String {
        switch self {
        case .fps30: "30 FPS"
        case .fps60: "60 FPS"
        case .custom: "Custom"
        }
    }
}

private enum ActiveVideoEditor: Int, Identifiable {
    case customResolution
    case customFrameRate

    var id: Self { self }
}

struct UmbraSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @State private var selection: SettingsTab
    @State private var paneHeights: [SettingsTab: CGFloat] = [:]
    private let hdrDisplaySupportResolver: HDRDisplaySupportResolver
    private let microphonePermissionEnvironment: MicrophonePermissionEnvironment
    private let systemShortcutPermissionEnvironment: SystemShortcutPermissionEnvironment

    init(
        preferences: PreferencesStore,
        initialSelection: SettingsTab? = nil,
        hdrDisplaySupportResolver: HDRDisplaySupportResolver = .system,
        microphonePermissionEnvironment: MicrophonePermissionEnvironment = .system,
        systemShortcutPermissionEnvironment: SystemShortcutPermissionEnvironment = .system
    ) {
        self.preferences = preferences
        self.hdrDisplaySupportResolver = hdrDisplaySupportResolver
        self.microphonePermissionEnvironment = microphonePermissionEnvironment
        self.systemShortcutPermissionEnvironment = systemShortcutPermissionEnvironment
        _selection = State(initialValue: initialSelection ?? preferences.selectedSettingsTab)
    }

    private var targetSize: CGSize {
        CGSize(
            width: UmbraLayout.settingsWidth,
            height: UmbraLayout.settingsWindowHeight(contentHeight: paneHeights[selection])
        )
    }

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView(preferences: preferences)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            VideoSettingsView(
                preferences: preferences,
                hdrDisplaySupportResolver: hdrDisplaySupportResolver
            )
                .tabItem { Label("Video", systemImage: "display") }
                .tag(SettingsTab.video)

            AudioSettingsView(
                preferences: preferences,
                microphonePermissionEnvironment: microphonePermissionEnvironment
            )
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
                .tag(SettingsTab.audio)

            InputSettingsView(
                preferences: preferences,
                systemShortcutPermissionEnvironment: systemShortcutPermissionEnvironment
            )
                .tabItem { Label("Input", systemImage: "keyboard") }
                .tag(SettingsTab.input)

            ControllerSettingsView(preferences: preferences)
                .tabItem { Label("Controller", systemImage: "gamecontroller") }
                .tag(SettingsTab.gamepad)

            AdvancedSettingsView(preferences: preferences)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.advanced)
        }
        .frame(
            width: targetSize.width,
            height: targetSize.height
        )
        .background(SettingsWindowSizer(contentSize: targetSize))
        .onChange(of: selection) { _, tab in
            preferences.updateSelectedSettingsTab(tab)
        }
        .alert(
            "Settings Error",
            isPresented: Binding(
                get: { preferences.persistenceErrorMessage != nil },
                set: { if !$0 { preferences.clearPersistenceError() } }
            )
        ) {
            Button("OK") { preferences.clearPersistenceError() }
        } message: {
            Text(preferences.persistenceErrorMessage ?? "Umbra could not save these settings.")
        }
        .onPreferenceChange(SettingsPaneHeightPreferenceKey.self) { measured in
            for (tab, height) in measured where height.isFinite && height > 0 {
                let normalizedHeight = ceil(height)
                guard abs((paneHeights[tab] ?? 0) - normalizedHeight) > 0.5 else {
                    continue
                }
                paneHeights[tab] = normalizedHeight
            }
        }
    }
}

private struct SettingsWindowSizer: NSViewRepresentable {
    let contentSize: CGSize

    func makeCoordinator() -> SettingsWindowSizingController {
        SettingsWindowSizingController(contentSize: contentSize)
    }

    func makeNSView(context: Context) -> SettingsWindowSizingView {
        let view = SettingsWindowSizingView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ view: SettingsWindowSizingView, context: Context) {
        context.coordinator.update(contentSize: contentSize)
        context.coordinator.attach(to: view.window)
    }
}

@MainActor
final class SettingsWindowSizingController {
    private var contentSize: CGSize
    private weak var window: NSWindow?

    init(contentSize: CGSize) {
        self.contentSize = contentSize
    }

    func update(contentSize: CGSize) {
        guard abs(self.contentSize.width - contentSize.width) > 0.5
                || abs(self.contentSize.height - contentSize.height) > 0.5 else {
            return
        }
        self.contentSize = contentSize
        applyLatestSize()
    }

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        self.window = window
        applyLatestSize()
    }

    private func applyLatestSize() {
        guard let window else { return }
        let currentSize = window.contentLayoutRect.size
        let sizeChanged = abs(currentSize.width - contentSize.width) > 0.5
            || abs(currentSize.height - contentSize.height) > 0.5

        if sizeChanged {
            let currentFrame = window.frame
            var targetFrame = window.frameRect(
                forContentRect: CGRect(origin: .zero, size: contentSize)
            )
            targetFrame.origin = CGPoint(
                x: currentFrame.minX,
                y: currentFrame.maxY - targetFrame.height
            )
            window.setFrame(targetFrame, display: true)
        }
        window.styleMask.remove(.resizable)
    }
}

@MainActor
private final class SettingsWindowSizingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private struct SettingsPane<Content: View>: View {
    let tab: SettingsTab
    @ViewBuilder let content: Content

    init(tab: SettingsTab, @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: UmbraLayout.settingsSectionSpacing) {
                content
            }
            .padding(.horizontal, UmbraLayout.space6)
            .padding(.vertical, UmbraLayout.space4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SettingsPaneHeightPreferenceKey.self,
                        value: [tab: proxy.size.height]
                    )
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SettingsPaneHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [SettingsTab: CGFloat] = [:]

    static func reduce(
        value: inout [SettingsTab: CGFloat],
        nextValue: () -> [SettingsTab: CGFloat]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var preferences: PreferencesStore

    private var languageSelection: Binding<AppLocaleOption> {
        let options = UmbraLocalization.languageOptions
        return Binding(
            get: {
                options.first(where: {
                    $0.preference == preferences.appLocalePreference
                }) ?? options[0]
            },
            set: { preferences.updateAppLocalePreference($0.preference) }
        )
    }

    var body: some View {
        SettingsPane(tab: .general) {
            SettingsSection("Host") {
                PreferenceToggle(
                    "Optimize game settings for streaming",
                    binding: preferences.binding(for: \.gameOptimizations)
                )
                PreferenceToggle(
                    "Quit app on host after ending stream",
                    message: "The host closes the streamed app when the stream ends. Unsaved progress may be lost.",
                    binding: preferences.binding(for: \.quitAppAfter)
                )
            }

            SettingsSection("Interface") {
                SettingsRow("Main window") {
                    CompactMenuPicker(
                        title: "Main window",
                        options: UIDisplayMode.mainWindowChoices,
                        selection: preferences.binding(for: \.uiDisplayMode),
                        optionLabel: \.label
                    )
                }

                if UmbraLocalization.showsLanguageSetting {
                    SettingsRow(
                        UmbraLocalization.string("Language"),
                        message: UmbraLocalization.string(
                            "Changes take effect after you relaunch Umbra."
                        )
                    ) {
                        CompactMenuPicker(
                            title: UmbraLocalization.string("Language"),
                            options: UmbraLocalization.languageOptions,
                            selection: languageSelection,
                            optionLabel: \.label
                        )
                    }
                }

                PreferenceToggle("Show connection quality warnings", binding: preferences.binding(for: \.connectionWarnings))
                PreferenceToggle(
                    "Share activity with Discord",
                    message: "Shows the streamed app in your Discord status.",
                    binding: preferences.binding(for: \.richPresence)
                )
                PreferenceToggle(
                    "Keep the display awake while streaming",
                    message: "Prevents the screen saver and display sleep during an active stream.",
                    binding: preferences.binding(for: \.keepAwake)
                )
            }
        }
    }
}

private struct VideoSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    let hdrDisplaySupportResolver: HDRDisplaySupportResolver
    @State private var activeEditor: ActiveVideoEditor?
    @State private var customResolutionWidthText = ""
    @State private var customResolutionHeightText = ""
    @State private var customFrameRateText = ""

    private var resolution: ResolutionPreset {
        switch preferences.settings.displayResolutionPolicy {
        case .native: return .native
        case .nativeExcludingNotch: return .nativeExcludingNotch
        case .configured: break
        }
        return switch (preferences.settings.width, preferences.settings.height) {
        case (1_280, 720): .p720
        case (1_920, 1_080): .p1080
        case (2_560, 1_440): .p1440
        case (3_840, 2_160): .p4K
        default: .custom
        }
    }

    private var frameRate: FrameRatePreset {
        guard preferences.settings.frameRateDenominator == 1 else { return .custom }
        return FrameRatePreset(rawValue: preferences.settings.fps) ?? .custom
    }

    private var frameRateText: String {
        let numerator = preferences.settings.frameRateNumerator
        let denominator = preferences.settings.frameRateDenominator
        return denominator == 1 ? String(numerator) : "\(numerator)/\(denominator)"
    }

    private var customFrameRateLabel: String {
        guard preferences.settings.frameRateDenominator != 1 else {
            return "\(preferences.settings.frameRateNumerator) FPS"
        }
        let decimal = preferences.settings.exactFrameRate.formatted(
            .number.precision(.fractionLength(2...3))
        )
        return "\(decimal) FPS (\(frameRateText))"
    }

    private var bitrateMbps: Binding<Double> {
        Binding(
            get: { Double(preferences.settings.bitrateKbps) / 1_000 },
            set: { value in
                preferences.updateBitrateFromContinuousControl(
                    Int((value * 1_000).rounded())
                )
            }
        )
    }

    private var bitrateMaximumMbps: Double {
        guard !preferences.settings.unlockBitrate else { return 500 }
        return max(
            150,
            preferences.settings.autoAdjustBitrate
                ? Double(preferences.settings.bitrateKbps) / 1_000
                : 150
        )
    }

    private var hdrAvailable: Bool {
        hdrDisplaySupportResolver.supportsHDR(
            for: preferences.settings.displaySelection,
            uiScreen: NSApp.keyWindow?.screen
        )
    }

    private var displaySelections: [DisplaySelection] {
        var values: [DisplaySelection] = [.automatic]
        values.append(contentsOf: NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return .specific(number.uint32Value)
        })
        if case .specific = preferences.settings.displaySelection,
           !values.contains(preferences.settings.displaySelection) {
            values.append(preferences.settings.displaySelection)
        }
        return values
    }

    var body: some View {
        SettingsPane(tab: .video) {
            SettingsSection("Resolution and frame rate") {
                SettingsRow("Display", message: "Automatic uses the display containing Umbra when the stream starts.") {
                    CompactMenuPicker(
                        title: "Display",
                        options: displaySelections,
                        selection: preferences.binding(for: \.displaySelection),
                        optionLabel: displayLabel,
                        width: 320
                    )
                }

                SettingsRow("Resolution", message: "Values above the host, display, decoder, or network limit may cause errors or stutter.") {
                    CompactMenuPicker(
                        title: "Resolution",
                        options: ResolutionPreset.allCases,
                        selection: resolutionBinding,
                        optionLabel: \.label
                    )
                }

                if resolution == .custom {
                    SettingsRow("Custom resolution", message: "The host may not change its display resolution automatically.") {
                        CustomResolutionControl(preferences: preferences)
                    }
                }

                SettingsRow("Frame rate") {
                    CompactMenuPicker(
                        title: "Frame rate",
                        options: FrameRatePreset.allCases,
                        selection: frameRateBinding,
                        optionLabel: \.label
                    )
                }

                if frameRate == .custom {
                    SettingsRow("Custom frame rate") {
                        Button(customFrameRateLabel, action: editCustomFrameRate)
                            .controlSize(.small)
                            .monospacedDigit()
                            .accessibilityLabel("Edit custom frame rate")
                            .accessibilityValue(customFrameRateLabel)
                    }
                }
            }

            SettingsSection("Streaming") {
                SettingsRow("Streaming mode") {
                    StreamOptimizationModePicker(preferences: preferences)
                }

                SettingsRow("Video bitrate", message: "Lower values help slower connections; higher values can improve image quality.") {
                    VStack(alignment: .leading, spacing: UmbraLayout.space2) {
                        HStack {
                            CompactSlider(
                                value: bitrateMbps,
                                range: 1...bitrateMaximumMbps,
                                step: 0.5,
                                accessibilityLabel: "Video bitrate",
                                accessibilityValue: { "\($0.formatted(.number.precision(.fractionLength(1)))) megabits per second" }
                            )
                            .frame(width: 180)
                            Text("\(bitrateMbps.wrappedValue, specifier: "%.1f") Mbps")
                                .monospacedDigit()
                                .frame(width: 82, alignment: .trailing)
                        }
                        if !preferences.settings.autoAdjustBitrate {
                            Button("Use Default") { preferences.resetBitrateToDefault() }
                                .controlSize(.small)
                        }
                    }
                }

                SettingsRow("Display mode", message: "Borderless Windowed integrates best with macOS Spaces; Fullscreen may reduce overhead.") {
                    CompactMenuPicker(
                        title: "Display mode",
                        options: WindowMode.streamChoices,
                        selection: preferences.binding(for: \.windowMode),
                        optionLabel: \.label
                    )
                }

                HDRPreferenceToggle(
                    preferences: preferences,
                    hdrAvailable: hdrAvailable
                )

                SettingsRow(
                    "HDR transfer",
                    isEnabled: preferences.settings.enableHDR
                ) {
                    CompactMenuPicker(
                        title: "HDR transfer",
                        options: HDRTransferPreference.macOSChoices,
                        selection: preferences.binding(for: \.hdrTransferPreference),
                        optionLabel: \.label
                    )
                }
            }
        }
        .sheet(item: $activeEditor) { editor in
            switch editor {
            case .customResolution:
                CustomResolutionEditor(
                    widthText: $customResolutionWidthText,
                    heightText: $customResolutionHeightText,
                    onCancel: { activeEditor = nil },
                    onApply: { width, height in
                        preferences.updateConfiguredResolution(width: width, height: height)
                        activeEditor = nil
                    }
                )
            case .customFrameRate:
                CustomFrameRateEditor(
                    text: $customFrameRateText,
                    onCancel: { activeEditor = nil },
                    onApply: { numerator, denominator in
                        preferences.updateFrameRate(
                            numerator: numerator,
                            denominator: denominator
                        )
                        activeEditor = nil
                    }
                )
            }
        }
    }

    private var resolutionBinding: Binding<ResolutionPreset> {
        Binding(
            get: { resolution },
            set: { preset in
                switch preset {
                case .native:
                    preferences.update {
                        $0.displayResolutionPolicy = .native
                    }
                case .nativeExcludingNotch:
                    preferences.update {
                        $0.displayResolutionPolicy = .nativeExcludingNotch
                    }
                case .custom:
                    customResolutionWidthText = String(preferences.settings.width)
                    customResolutionHeightText = String(preferences.settings.height)
                    activeEditor = .customResolution
                case .p720, .p1080, .p1440, .p4K:
                    guard let dimensions = preset.dimensions else { return }
                    preferences.updateConfiguredResolution(
                        width: dimensions.width,
                        height: dimensions.height
                    )
                }
            }
        )
    }

    private func displayLabel(_ selection: DisplaySelection) -> String {
        switch selection {
        case .automatic:
            return "Automatic"
        case let .specific(displayID):
            guard let screen = NSScreen.screens.first(where: { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }) else {
                return "Unavailable Display"
            }
            let sameNameScreens = NSScreen.screens.filter { $0.localizedName == screen.localizedName }
            guard sameNameScreens.count > 1,
                  let duplicateIndex = sameNameScreens.firstIndex(where: { $0 === screen })
            else {
                return screen.localizedName
            }
            return "\(screen.localizedName) \(duplicateIndex + 1)"
        }
    }

    private var frameRateBinding: Binding<FrameRatePreset> {
        Binding(
            get: { frameRate },
            set: { preset in
                if preset == .custom {
                    editCustomFrameRate()
                } else {
                    preferences.updateFrameRate(preset.rawValue)
                }
            }
        )
    }

    private func editCustomFrameRate() {
        customFrameRateText = frameRateText
        activeEditor = .customFrameRate
    }
}

struct StreamOptimizationModePicker: View {
    @ObservedObject var preferences: PreferencesStore

    private var selection: Binding<StreamOptimizationMode> {
        Binding(
            get: { preferences.settings.optimizationMode },
            set: { preferences.updateOptimizationMode($0) }
        )
    }

    var body: some View {
        NativeStreamOptimizationModeControl(selection: selection)
        .frame(width: UmbraLayout.settingsControlWidth)
    }
}

private struct NativeStreamOptimizationModeControl: NSViewRepresentable {
    @Binding var selection: StreamOptimizationMode

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: StreamOptimizationMode.allCases.map(\.label),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentStyle = .automatic
        control.controlSize = .small
        control.setAccessibilityLabel(UmbraLocalization.string("Streaming mode"))
        control.setAccessibilityHelp(
            UmbraLocalization.string("Choose Lowest Latency or Best Quality.")
        )
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = StreamOptimizationMode.allCases.firstIndex(of: selection) ?? 0
        for (index, mode) in StreamOptimizationMode.allCases.enumerated() {
            control.setLabel(mode.label, forSegment: index)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<StreamOptimizationMode>

        init(selection: Binding<StreamOptimizationMode>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard StreamOptimizationMode.allCases.indices.contains(sender.selectedSegment) else {
                return
            }
            selection.wrappedValue = StreamOptimizationMode.allCases[sender.selectedSegment]
        }
    }
}

private struct CustomResolutionEditor: View {
    @Binding var widthText: String
    @Binding var heightText: String
    let onCancel: () -> Void
    let onApply: (Int, Int) -> Void
    @FocusState private var focusedField: Field?

    private enum Field {
        case width
        case height
    }

    private var dimensions: (width: Int, height: Int)? {
        guard let width = Int(widthText),
              let height = Int(heightText),
              (StreamingPreferences.minimumStreamWidth...StreamingPreferences.maximumStreamWidth).contains(width),
              width.isMultiple(of: 2),
              (StreamingPreferences.minimumStreamHeight...StreamingPreferences.maximumStreamHeight).contains(height),
              height.isMultiple(of: 2)
        else {
            return nil
        }
        return (width, height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraLayout.space4) {
            Text("Custom Resolution")
                .font(.headline)
            Text("Enter even dimensions from 320–7,680 wide and 200–4,320 high.")
                .foregroundStyle(.secondary)

            HStack(spacing: UmbraLayout.space2) {
                CompactTextField(
                    text: $widthText,
                    placeholder: "Width",
                    accessibilityLabel: "Custom resolution width",
                    accessibilityHint: "Enter an even width from 320 to 7,680 pixels."
                )
                    .frame(width: 120)
                    .focused($focusedField, equals: .width)
                Text("×")
                    .foregroundStyle(.secondary)
                CompactTextField(
                    text: $heightText,
                    placeholder: "Height",
                    accessibilityLabel: "Custom resolution height",
                    accessibilityHint: "Enter an even height from 200 to 4,320 pixels."
                )
                    .frame(width: 120)
                    .focused($focusedField, equals: .height)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: applyIfValid)
                    .keyboardShortcut(.defaultAction)
                    .disabled(dimensions == nil)
            }
        }
        .padding(UmbraLayout.space6)
        .frame(width: 400)
        .onAppear { focusedField = .width }
    }

    private func applyIfValid() {
        guard let dimensions else { return }
        onApply(dimensions.width, dimensions.height)
    }
}

struct CustomResolutionControl: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        HStack(spacing: UmbraLayout.space2) {
            HStack(spacing: UmbraLayout.space2) {
                Text("\(preferences.settings.width)")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
                CompactIntegerStepper(
                    value: widthBinding,
                    range: StreamingPreferences.minimumStreamWidth...StreamingPreferences.maximumStreamWidth,
                    accessibilityLabel: "Custom resolution width",
                    accessibilityValue: { "\($0) pixels" }
                )
            }
            Text("×").foregroundStyle(.secondary)
            HStack(spacing: UmbraLayout.space2) {
                Text("\(preferences.settings.height)")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
                CompactIntegerStepper(
                    value: heightBinding,
                    range: StreamingPreferences.minimumStreamHeight...StreamingPreferences.maximumStreamHeight,
                    accessibilityLabel: "Custom resolution height",
                    accessibilityValue: { "\($0) pixels" }
                )
            }
        }
    }

    private var widthBinding: Binding<Int> {
        Binding(
            get: { preferences.settings.width },
            set: {
                let width = normalizedEvenDimension(
                    $0,
                    previous: preferences.settings.width,
                    range: StreamingPreferences.minimumStreamWidth...StreamingPreferences.maximumStreamWidth
                )
                preferences.updateConfiguredResolution(
                    width: width,
                    height: preferences.settings.height
                )
            }
        )
    }

    private var heightBinding: Binding<Int> {
        Binding(
            get: { preferences.settings.height },
            set: {
                let height = normalizedEvenDimension(
                    $0,
                    previous: preferences.settings.height,
                    range: StreamingPreferences.minimumStreamHeight...StreamingPreferences.maximumStreamHeight
                )
                preferences.updateConfiguredResolution(
                    width: preferences.settings.width,
                    height: height
                )
            }
        )
    }

    private func normalizedEvenDimension(
        _ value: Int,
        previous: Int,
        range: ClosedRange<Int>
    ) -> Int {
        guard !value.isMultiple(of: 2) else { return value }
        return value > previous ? min(value + 1, range.upperBound) : max(value - 1, range.lowerBound)
    }
}

struct CustomFrameRateValue: Equatable {
    let numerator: Int
    let denominator: Int

    init?(text: String) {
        let components = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count),
              let numerator = Int(components[0].trimmingCharacters(in: .whitespaces)),
              let denominator = components.count == 1
                ? 1
                : Int(components[1].trimmingCharacters(in: .whitespaces)),
              StreamingPreferences.isSupportedFrameRate(
                  numerator: numerator,
                  denominator: denominator
              ) else {
            return nil
        }
        self.numerator = numerator
        self.denominator = denominator
    }
}

private struct CustomFrameRateEditor: View {
    @Binding var text: String
    let onCancel: () -> Void
    let onApply: (Int, Int) -> Void
    @FocusState private var fieldFocused: Bool

    private var value: CustomFrameRateValue? { CustomFrameRateValue(text: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraLayout.space4) {
            Text("Custom Frame Rate")
                .font(.headline)
            Text("Enter 10–480 FPS as a whole number or exact fraction, such as 60000/1001.")
                .foregroundStyle(.secondary)

            CompactTextField(
                text: $text,
                placeholder: "60 or 60000/1001",
                accessibilityLabel: "Custom frame rate",
                accessibilityHint: "Enter 10 to 480 FPS as a whole number or fraction."
            )
                .frame(width: 200)
                .focused($fieldFocused)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let value { onApply(value.numerator, value.denominator) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(value == nil)
            }
        }
        .padding(UmbraLayout.space6)
        .frame(width: 400)
        .onAppear { fieldFocused = true }
    }
}

struct AudioSettingsView: View {
    private struct MicrophoneChoice: Hashable {
        let uid: String?
        let title: String
    }

    @ObservedObject var preferences: PreferencesStore
    @StateObject private var microphonePermission: MicrophonePermissionSettingsModel
    @State private var microphoneDevices: [ClientMicrophoneDevice] = []
    private let microphonePermissionEnvironment: MicrophonePermissionEnvironment

    init(
        preferences: PreferencesStore,
        microphonePermissionEnvironment: MicrophonePermissionEnvironment = .system
    ) {
        self.preferences = preferences
        self.microphonePermissionEnvironment = microphonePermissionEnvironment
        _microphonePermission = StateObject(
            wrappedValue: microphonePermissionEnvironment.permissionModel
        )
    }

    private var clientMicrophoneBinding: Binding<Bool> {
        Binding(
            get: { preferences.settings.clientMicrophoneEnabled },
            set: { enabled in
                if !enabled {
                    preferences.update(\.clientMicrophoneRequired, to: false)
                }
                preferences.update(\.clientMicrophoneEnabled, to: enabled)
                guard enabled else { return }
                Task { @MainActor in
                    let status = await microphonePermission.requestAuthorization()
                    guard preferences.settings.clientMicrophoneEnabled else { return }
                    if !status.permitsCapture {
                        preferences.update(\.clientMicrophoneRequired, to: false)
                        preferences.update(\.clientMicrophoneEnabled, to: false)
                    }
                }
            }
        )
    }

    private var microphoneChoices: [MicrophoneChoice] {
        var choices = [MicrophoneChoice(
            uid: nil,
            title: UmbraLocalization.string("System Default")
        )]
        choices.append(contentsOf: microphoneDevices.map {
            MicrophoneChoice(uid: $0.uid, title: $0.name)
        })
        if let selectedUID = preferences.settings.clientMicrophoneDeviceUID,
           !microphoneDevices.contains(where: { $0.uid == selectedUID }) {
            choices.append(MicrophoneChoice(
                uid: selectedUID,
                title: UmbraLocalization.string("Unavailable Microphone")
            ))
        }
        return choices
    }

    private var microphoneChoiceBinding: Binding<MicrophoneChoice> {
        Binding(
            get: {
                microphoneChoices.first {
                    $0.uid == preferences.settings.clientMicrophoneDeviceUID
                } ?? microphoneChoices[0]
            },
            set: { choice in
                preferences.update(\.clientMicrophoneDeviceUID, to: choice.uid)
            }
        )
    }

    private var selectedMicrophoneIsUnavailable: Bool {
        guard let selectedUID = preferences.settings.clientMicrophoneDeviceUID else { return false }
        return !microphoneDevices.contains { $0.uid == selectedUID }
    }

    var body: some View {
        SettingsPane(tab: .audio) {
            SettingsSection("Audio") {
                SettingsRow("Speaker layout") {
                    CompactMenuPicker(
                        title: "Speaker layout",
                        options: AudioConfiguration.allCases,
                        selection: preferences.binding(for: \.audioConfiguration),
                        optionLabel: \.label
                    )
                }
                PreferenceToggle(
                    "Mute host speakers while streaming",
                    message: "Restart an app already running on the host for this change to take effect.",
                    binding: Binding(
                        get: { !preferences.settings.playAudioOnHost },
                        set: { preferences.update(\.playAudioOnHost, to: !$0) }
                    )
                )
                PreferenceToggle(
                    "Mute stream in the background",
                    message: "Mutes streamed audio while another app is active.",
                    binding: preferences.binding(for: \.muteOnFocusLoss)
                )
                PreferenceToggle(
                    UmbraLocalization.string("Use Mac microphone on host"),
                    message: UmbraLocalization.string(
                        "Makes this Mac’s microphone available to compatible Lumen hosts. macOS asks for permission when enabled."
                    ),
                    binding: clientMicrophoneBinding
                )
                SettingsRow(
                    UmbraLocalization.string("Microphone"),
                    message: selectedMicrophoneIsUnavailable
                        ? UmbraLocalization.string(
                            "The selected microphone is disconnected. Reconnect it or choose another input."
                        )
                        : nil
                ) {
                    CompactMenuPicker(
                        title: UmbraLocalization.string("Microphone"),
                        options: microphoneChoices,
                        selection: microphoneChoiceBinding,
                        optionLabel: \.title
                    )
                }
                PreferenceToggle(
                    UmbraLocalization.string("Require microphone for streaming"),
                    message: UmbraLocalization.string(
                        "Fails stream startup instead of continuing without microphone forwarding."
                    ),
                    binding: preferences.binding(for: \.clientMicrophoneRequired)
                )
                .disabled(!preferences.settings.clientMicrophoneEnabled)
                microphoneAuthorizationState
            }
        }
        .onReceive(
            microphonePermissionEnvironment.applicationNotifications.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            _ = microphonePermission.refreshAuthorization()
            refreshMicrophoneDevices()
        }
        .onAppear { refreshMicrophoneDevices() }
    }

    @ViewBuilder
    private var microphoneAuthorizationState: some View {
        switch microphonePermission.presentationState {
        case .notDetermined, .authorized:
            EmptyView()
        case .requesting:
            SettingsRow(UmbraLocalization.string("Microphone access")) {
                HStack(spacing: UmbraLayout.space2) {
                    ProgressView()
                        .controlSize(.small)
                    Text(UmbraLocalization.string("Requesting Access..."))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        case .denied:
            SettingsRow(
                UmbraLocalization.string("Microphone access"),
                message: UmbraLocalization.string(
                    "Allow Umbra to use the microphone in Privacy & Security settings, then return to Umbra."
                )
            ) {
                HStack(spacing: UmbraLayout.space3) {
                    StatusLabel(
                        title: UmbraLocalization.string("Not Allowed"),
                        symbol: "xmark.circle.fill",
                        tone: .failure
                    )
                    Button(MicrophonePermissionSettingsCopy.openSettingsTitle) {
                        microphonePermissionEnvironment.openMicrophoneSettings()
                    }
                    .accessibilityHint(
                        MicrophonePermissionSettingsCopy.openSettingsAccessibilityHelp
                    )
                }
            }
        case .restricted:
            SettingsRow(
                UmbraLocalization.string("Microphone access"),
                message: UmbraLocalization.string(
                    "Microphone access is restricted by Screen Time or device management."
                )
            ) {
                StatusLabel(
                    title: UmbraLocalization.string("Restricted"),
                    symbol: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
        }
    }

    private func refreshMicrophoneDevices() {
        microphoneDevices = microphonePermissionEnvironment.availableInputDevices()
    }
}

struct InputSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @StateObject private var shortcutPermissionModel: SystemShortcutPermissionSettingsModel
    private let systemShortcutPermissionEnvironment: SystemShortcutPermissionEnvironment

    init(
        preferences: PreferencesStore,
        systemShortcutPermissionEnvironment: SystemShortcutPermissionEnvironment = .system
    ) {
        self.preferences = preferences
        self.systemShortcutPermissionEnvironment = systemShortcutPermissionEnvironment
        _shortcutPermissionModel = StateObject(
            wrappedValue: systemShortcutPermissionEnvironment.permissionModel
        )
    }

    var body: some View {
        SettingsPane(tab: .input) {
            SettingsSection("Mouse and keyboard") {
                PreferenceToggle(
                    "Use absolute mouse mode",
                    message: "Uses absolute pointer input without capturing the local cursor. Most games require relative mouse mode.",
                    binding: preferences.binding(for: \.absoluteMouseMode)
                )
                SettingsRow("Capture system keyboard shortcuts", message: "Sends shortcuts such as Command-Tab to the host.") {
                    CompactMenuPicker(
                        title: "Capture system keyboard shortcuts",
                        options: CaptureSystemKeysMode.allCases,
                        selection: preferences.binding(for: \.captureSystemKeysMode),
                        optionLabel: \.label
                    )
                }
                if preferences.settings.captureSystemKeysMode != .off {
                    SettingsRow("System shortcut access") {
                        if shortcutPermissionModel.snapshot.isAppSandboxed {
                            StatusLabel(
                                title: "Unavailable in App Sandbox",
                                symbol: "xmark.circle",
                                tone: .failure
                            )
                        } else {
                            HStack(spacing: UmbraLayout.space3) {
                                shortcutPermissionStatus(
                                    "Input Monitoring",
                                    granted: shortcutPermissionModel.snapshot.inputMonitoringGranted
                                )
                                shortcutPermissionStatus(
                                    "Accessibility",
                                    granted: shortcutPermissionModel.snapshot.accessibilityGranted
                                )
                                if !shortcutPermissionModel.snapshot.missingPermissions.isEmpty {
                                    Button("Request...") {
                                        shortcutPermissionModel.requestMissingPermissions()
                                    }
                                }
                                Button("Refresh") {
                                    shortcutPermissionModel.refresh()
                                }
                            }
                        }
                    }
                }
                PreferenceToggle(
                    "Use touchscreen as a virtual trackpad",
                    message: "When disabled, touch input directly controls the remote pointer.",
                    binding: Binding(
                        get: { !preferences.settings.absoluteTouchMode },
                        set: { preferences.update(\.absoluteTouchMode, to: !$0) }
                    )
                )
                PreferenceToggle("Swap left and right mouse buttons", binding: preferences.binding(for: \.swapMouseButtons))
                PreferenceToggle("Reverse mouse scrolling direction", binding: preferences.binding(for: \.reverseScrollDirection))
            }
        }
        .onAppear {
            shortcutPermissionModel.refresh()
        }
        .onReceive(
            systemShortcutPermissionEnvironment.applicationNotifications.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            shortcutPermissionModel.refresh()
        }
    }

    private func shortcutPermissionStatus(_ title: String, granted: Bool) -> some View {
        StatusLabel(
            title: title,
            symbol: granted ? "checkmark.circle" : "exclamationmark.triangle",
            tone: granted ? .neutral : .warning
        )
        .accessibilityLabel("\(title): \(granted ? "Allowed" : "Required")")
    }
}

private struct ControllerSettingsView: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        SettingsPane(tab: .gamepad) {
            SettingsSection("Controller") {
                PreferenceToggle(
                    "Swap A/B and X/Y buttons",
                    message: "Uses a Nintendo-style face-button layout.",
                    binding: preferences.binding(for: \.swapFaceButtons)
                )
                PreferenceToggle(
                    "Keep one controller connected",
                    message: "Presents a controller to the host even when none is connected to this Mac.",
                    binding: Binding(
                        get: { !preferences.settings.multiController },
                        set: { preferences.update(\.multiController, to: !$0) }
                    )
                )
                PreferenceToggle(
                    "Use controller as mouse while holding Menu",
                    binding: preferences.binding(for: \.gamepadMouse)
                )
                PreferenceToggle(
                    "Allow controller input in the background",
                    message: "Sends controller input while another app is active.",
                    binding: preferences.binding(for: \.backgroundGamepad)
                )
            }
        }
    }
}

private struct AdvancedSettingsView: View {
    private enum AWDLStatus {
        case checking
        case enabled
        case disabled
        case unavailable
        case failed

        var label: String {
            switch self {
            case .checking: "Checking…"
            case .enabled: "Enabled"
            case .disabled: "Disabled"
            case .unavailable: "Unavailable"
            case .failed: "Couldn’t Check"
            }
        }
    }

    @ObservedObject var preferences: PreferencesStore
    @State private var showsResetConfirmation = false
    @State private var awdlStatus: AWDLStatus = .checking
    @State private var awdlHelperStatus: AWDLHelperRegistrationStatus = .notRegistered
    @State private var awdlHelperError: String?

    var body: some View {
        SettingsPane(tab: .advanced) {
            SettingsSection("Video pipeline") {
                SettingsRow("Video decoder") {
                    CompactMenuPicker(
                        title: "Video decoder",
                        options: VideoDecoderPreference.allCases,
                        selection: preferences.binding(for: \.videoDecoderPreference),
                        optionLabel: \.label,
                        width: 250
                    )
                }
                SettingsRow("Video codec") {
                    CompactMenuPicker(
                        title: "Video codec",
                        options: VideoCodecPreference.macOSChoices,
                        selection: preferences.binding(for: \.videoCodecPreference),
                        optionLabel: \.label,
                        width: 250
                    )
                }
                SettingsRow("Renderer") {
                    CompactMenuPicker(
                        title: "Renderer",
                        options: RendererPreference.macOSChoices,
                        selection: preferences.binding(for: \.rendererPreference),
                        optionLabel: \.label,
                        width: 250
                    )
                }
                PreferenceToggle(
                    "Vertical sync",
                    message: "Matches presentation to the display. Turning it off may show tearing.",
                    binding: preferences.binding(for: \.enableVSync)
                )
                PreferenceToggle(
                    "Frame pacing",
                    message: "Uses display timing to reduce uneven frame delivery.",
                    binding: preferences.binding(for: \.framePacing),
                    enabled: preferences.settings.enableVSync,
                    disabledReason: "Turn on vertical sync to use frame pacing."
                )
                PreferenceToggle(
                    "Allow bitrates above 150 Mbps",
                    message: "Allows very high bitrates on compatible hosts. Use a wired network.",
                    binding: Binding(
                        get: { preferences.settings.unlockBitrate },
                        set: { enabled in
                            preferences.setBitrateLimitUnlocked(enabled)
                        }
                    )
                )
            }

            SettingsSection("Network and diagnostics") {
                SettingsRow("Network packet size", message: "Automatic is recommended. Custom values must be between 1,024 and 65,507 bytes.") {
                    PacketSizeField(preferences: preferences)
                }
                PreferenceToggle(
                    "Find hosts on the local network",
                    binding: preferences.binding(for: \.enableMDNS)
                )
                PreferenceToggle(
                    "Check for blocked connections",
                    message: "Runs connection checks when a host cannot be reached.",
                    binding: preferences.binding(for: \.detectNetworkBlocking)
                )
                SettingsRow(
                    "AWDL interface",
                    message: "Current Apple Wireless Direct Link state on this Mac."
                ) {
                    Text(awdlStatus.label)
                        .foregroundStyle(.secondary)
                }
                SettingsRow(
                    "AWDL network helper",
                    message: awdlHelperError ?? awdlHelperMessage
                ) {
                    HStack(spacing: UmbraLayout.space2) {
                        Text(awdlHelperLabel)
                            .foregroundStyle(.secondary)
                        if awdlHelperStatus != .enabled {
                            Button(awdlHelperActionLabel, action: setupAWDLHelper)
                        }
                    }
                }
                PreferenceToggle(
                    "Disable AWDL while streaming",
                    message: "Uses the approved helper without prompting, then restores AWDL when streaming ends. While active, AirDrop, Sidecar, and peer-to-peer AirPlay are unavailable.",
                    binding: preferences.binding(for: \.disableAWDLWhileStreaming),
                    enabled: awdlHelperStatus == .enabled || preferences.settings.disableAWDLWhileStreaming,
                    disabledReason: "Set up and approve Umbra's restricted network helper first."
                )
                PreferenceToggle(
                    "Show performance overlay",
                    message: "Displays real-time stream performance information over the video.",
                    binding: preferences.binding(for: \.showPerformanceOverlay)
                )
            }

            SettingsSection("Lumen Streaming Protocol") {
                SettingsRow(
                    "Network profile",
                    message: "Adaptive is safe on ordinary networks. Competition requires an explicit wired-link capacity ceiling."
                ) {
                    Picker("Network profile", selection: Binding(
                        get: { preferences.settings.lspNetworkProfile },
                        set: { profile in
                            if profile == .competitionLAN,
                               preferences.settings.lspCompetitionCapacityMbps == 0 {
                                preferences.update(\.lspCompetitionCapacityMbps, to: 1_000)
                            }
                            preferences.update(\.lspNetworkProfile, to: profile)
                        }
                    )) {
                        Text("Adaptive low latency").tag(LSPNetworkProfilePreference.adaptiveLowLatency)
                        Text("Competition LAN").tag(LSPNetworkProfilePreference.competitionLAN)
                    }
                    .frame(width: 220)
                }
                SettingsRow("Competition capacity") {
                    Stepper(
                        "\(preferences.settings.lspCompetitionCapacityMbps) Mbps",
                        value: preferences.binding(for: \.lspCompetitionCapacityMbps),
                        in: 1...100_000,
                        step: 100
                    )
                    .frame(width: 220)
                }
                .disabled(preferences.settings.lspNetworkProfile != .competitionLAN)
                LSPRateSettingsRows(preferences: preferences)
                PreferenceToggle(
                    "Request microphone permission when pairing",
                    message: "Re-pair an existing host to change its granted permissions.",
                    binding: preferences.binding(for: \.lspPairMicrophonePermission)
                )
                PreferenceToggle(
                    "Request application quit permission when pairing",
                    message: "Lets Umbra quit only the application that its own stream started.",
                    binding: preferences.binding(for: \.lspPairQuitPermission)
                )
            }

            SettingsSection("Defaults") {
                SettingsRow(
                    "Umbra settings",
                    message: "Returns streaming, input, audio, and interface preferences to their defaults."
                ) {
                    Button("Restore Defaults...", role: .destructive) {
                        showsResetConfirmation = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Restore Default Settings?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) {
                preferences.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .task {
            refreshAWDLHelperStatus()
            await refreshAWDLStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAWDLHelperStatus()
            Task { await refreshAWDLStatus() }
        }
    }

    private func refreshAWDLStatus() async {
        do {
            switch try await SystemAWDLInterfaceCommandExecutor().currentState() {
            case .up: awdlStatus = .enabled
            case .down: awdlStatus = .disabled
            case .unavailable: awdlStatus = .unavailable
            }
        } catch {
            awdlStatus = .failed
        }
    }

    private var awdlHelperLabel: String {
        switch awdlHelperStatus {
        case .notRegistered: "Not Set Up"
        case .enabled: "Ready"
        case .requiresApproval: "Needs Approval"
        case .notFound: "Not Available"
        }
    }

    private var awdlHelperActionLabel: String {
        awdlHelperStatus == .requiresApproval ? "Open Login Items" : "Set Up…"
    }

    private var awdlHelperMessage: String {
        switch awdlHelperStatus {
        case .notRegistered:
            "One-time setup installs a signed helper restricted to enabling and disabling awdl0."
        case .enabled:
            "Approved. Stream startup, reconnects, and later Umbra launches require no administrator prompt."
        case .requiresApproval:
            "Allow Umbra's helper once in Login Items, then return here."
        case .notFound:
            "This Umbra package does not contain its signed network helper."
        }
    }

    private func refreshAWDLHelperStatus() {
        awdlHelperStatus = AWDLHelperRegistration().status()
        if awdlHelperStatus == .enabled { awdlHelperError = nil }
    }

    private func setupAWDLHelper() {
        let registration = AWDLHelperRegistration()
        do {
            if awdlHelperStatus == .requiresApproval {
                registration.openApprovalSettings()
            } else {
                awdlHelperStatus = try registration.register()
                if awdlHelperStatus == .requiresApproval {
                    registration.openApprovalSettings()
                }
            }
            awdlHelperError = nil
        } catch {
            awdlHelperStatus = registration.status()
            awdlHelperError = error.localizedDescription
        }
    }
}

private struct LSPRateSettingsRows: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        SettingsRow("Pointer network rate") {
            Stepper(
                "\(preferences.settings.lspPointerRate) Hz",
                value: preferences.binding(for: \.lspPointerRate),
                in: 125...16_000,
                step: 125
            ).frame(width: 220)
        }
        SettingsRow("Controller state rate") {
            Stepper(
                "\(preferences.settings.lspControllerRate) Hz",
                value: preferences.binding(for: \.lspControllerRate),
                in: 125...2_000,
                step: 125
            ).frame(width: 220)
        }
        SettingsRow("Controller sensor rate") {
            Stepper(
                "\(preferences.settings.lspSensorRate) Hz",
                value: preferences.binding(for: \.lspSensorRate),
                in: 125...4_000,
                step: 125
            ).frame(width: 220)
        }
        SettingsRow("Input reconciliation rate") {
            Stepper(
                "\(preferences.settings.lspReconciliationRate) Hz",
                value: preferences.binding(for: \.lspReconciliationRate),
                in: 50...1_000,
                step: 50
            ).frame(width: 220)
        }
    }
}

struct PacketSizeField: View {
    @ObservedObject var preferences: PreferencesStore
    @State private var text: String

    init(preferences: PreferencesStore) {
        self.preferences = preferences
        _text = State(initialValue: preferences.settings.packetSize == 0
            ? ""
            : String(preferences.settings.packetSize))
    }

    private var parsedValue: Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        guard let value = Int(trimmed), (1_024...65_507).contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraLayout.space1) {
            HStack(spacing: UmbraLayout.space2) {
                CompactTextField(
                    text: $text,
                    placeholder: "Automatic",
                    accessibilityLabel: "Network packet size",
                    accessibilityHint: "Enter 1,024 to 65,507 bytes, or leave blank for Automatic."
                )
                    .frame(width: 112)
                    .onChange(of: text) { _, _ in
                        if let parsedValue { preferences.update(\.packetSize, to: parsedValue) }
                    }
                if let parsedValue, parsedValue != 0 {
                    Text("bytes")
                        .foregroundStyle(.secondary)
                }
            }
            if !text.isEmpty, parsedValue == nil {
                Text("Enter 1,024 to 65,507, or clear the field for Automatic.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: preferences.settings.packetSize) { _, packetSize in
            guard parsedValue != packetSize else { return }
            text = packetSize == 0 ? "" : String(packetSize)
        }
    }
}

struct PreferenceToggle: View {
    let title: String
    let message: String?
    let binding: Binding<Bool>
    let enabled: Bool
    let disabledReason: String?

    init(
        _ title: String,
        message: String? = nil,
        binding: Binding<Bool>,
        enabled: Bool = true,
        disabledReason: String? = nil
    ) {
        self.title = title
        self.message = message
        self.binding = binding
        self.enabled = enabled
        self.disabledReason = disabledReason
    }

    var body: some View {
        SettingsRow(
            title,
            message: message,
            isEnabled: enabled,
            disabledReason: disabledReason
        ) {
            NativePreferenceSwitch(
                isOn: binding,
                accessibilityLabel: title,
                accessibilityHelp: accessibilityHint
            )
        }
    }

    var accessibilityHint: String {
        [message, enabled ? nil : disabledReason]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

struct HDRPreferenceToggle: View {
    @ObservedObject var preferences: PreferencesStore
    let hdrAvailable: Bool

    var body: some View {
        PreferenceToggle(
            "Enable HDR",
            message: hdrAvailable ? nil : "No HDR-capable display is currently available.",
            binding: preferences.binding(for: \.enableHDR),
            enabled: hdrAvailable || preferences.settings.enableHDR,
            disabledReason: "Connect or select an HDR-capable display to enable HDR."
        )
    }
}

private struct NativePreferenceSwitch: NSViewRepresentable {
    @Binding var isOn: Bool
    let accessibilityLabel: String
    let accessibilityHelp: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn)
    }

    func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        control.target = context.coordinator
        control.action = #selector(Coordinator.valueChanged(_:))
        return control
    }

    func updateNSView(_ control: NSSwitch, context: Context) {
        context.coordinator.isOn = $isOn
        control.state = isOn ? .on : .off
        control.isEnabled = isEnabled
        control.setAccessibilityLabel(accessibilityLabel)
        control.setAccessibilityHelp(accessibilityHelp.isEmpty ? nil : accessibilityHelp)
    }

    @MainActor
    final class Coordinator: NSObject {
        var isOn: Binding<Bool>

        init(isOn: Binding<Bool>) {
            self.isOn = isOn
        }

        @objc func valueChanged(_ sender: NSSwitch) {
            isOn.wrappedValue = sender.state == .on
        }
    }
}
