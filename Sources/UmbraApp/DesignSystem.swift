import AppKit
import SwiftUI

enum UmbraLayout {
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24
    static let space8: CGFloat = 32
    static let space12: CGFloat = 48

    static let compactControl: CGFloat = 32
    static let control: CGFloat = 38
    static let applicationTileWidth: CGFloat = 168
    static let artworkAspectRatio: CGFloat = 3.0 / 4.0
    static let cornerSmall: CGFloat = 6
    static let cornerMedium: CGFloat = 8
    static let accessibilityBorderWidth: CGFloat = 1
    static let readableWidth: CGFloat = 680
    static let settingsWidth: CGFloat = 760
    static let settingsLabelWidth: CGFloat = 260
    static let settingsControlWidth: CGFloat = 360
    static let settingsRowSpacing: CGFloat = 16
    static let settingsSectionSpacing: CGFloat = 24
    static let macOSControlHeight: CGFloat = 24
    static let settingsMinimumHeight: CGFloat = 180
    static let settingsMaximumHeight: CGFloat = 620
    static let streamOverlayMaximumWidth: CGFloat = 360
    static let hostDetailsWidth: CGFloat = 520
    static let hostDetailsMetadataHeight: CGFloat = 140
    /// Compact, noninteractive telemetry drawn directly over streamed video.
    static let streamOverlayFontSize: CGFloat = 12

    static func settingsWindowHeight(contentHeight: CGFloat?) -> CGFloat {
        guard let contentHeight, contentHeight.isFinite, contentHeight > 0 else {
            return settingsMinimumHeight
        }
        // The Settings scene owns its titlebar and tab chrome. This value is
        // strictly the SwiftUI content viewport, so adding chrome here leaves
        // a matching band of dead space below every compact pane.
        let measured = ceil(contentHeight)
        return min(max(measured, settingsMinimumHeight), settingsMaximumHeight)
    }
}

/// Solid antialiased glyphs remain readable over video without an outline or panel.
enum StreamOverlayStyle {
    static let text = NSColor.white
    static var textShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        return shadow
    }
}

enum UmbraSymbol {
    static let host = "display"
    static let application = "square.grid.2x2"
    static let running = "play.circle.fill"
    static let offline = "wifi.slash"
    static let unpaired = "lock.open"
    static let addHost = "plus"
    static let refresh = "arrow.clockwise"
    static let settings = "gearshape"
    static let details = "info.circle"
    static let wake = "power"
    static let test = "network"
    static let launch = "play.fill"
    static let resume = "play.circle"
    static let quit = "stop.fill"
    static let directLaunch = "bolt.fill"
    static let hidden = "eye.slash"
}

struct StatusLabel: View {
    enum Tone {
        case neutral
        case active
        case warning
        case failure

        var color: Color {
            switch self {
            case .neutral: .secondary
            case .active: .green
            case .warning: .orange
            case .failure: .red
            }
        }
    }

    let title: String
    let symbol: String
    let tone: Tone

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tone.color)
            .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: UmbraLayout.readableWidth)
        .padding(UmbraLayout.space8)
    }
}

struct LoadingStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: UmbraLayout.space4) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.title3.weight(.semibold))
            if !message.isEmpty {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: UmbraLayout.readableWidth)
        .padding(UmbraLayout.space8)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let message: String?
    let isEnabled: Bool
    let disabledReason: String?
    @ViewBuilder let control: Control

    init(
        _ title: String,
        message: String? = nil,
        isEnabled: Bool = true,
        disabledReason: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.message = message
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .top, spacing: UmbraLayout.settingsRowSpacing) {
            Text(title)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .frame(
                    width: UmbraLayout.settingsLabelWidth,
                    alignment: .trailing
                )
                .frame(minHeight: UmbraLayout.macOSControlHeight, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: UmbraLayout.space1) {
                control
                    .frame(
                        maxWidth: UmbraLayout.settingsControlWidth,
                        minHeight: UmbraLayout.macOSControlHeight,
                        alignment: .leading
                    )
                    .disabled(!isEnabled)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isEnabled, let disabledReason {
                    Text(disabledReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Unavailable. \(disabledReason)")
                }
            }
            .frame(width: UmbraLayout.settingsControlWidth, alignment: .leading)
        }
        .controlSize(.small)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraLayout.space3) {
            Text(title)
                .font(.headline)
                .padding(.leading, UmbraLayout.settingsLabelWidth + UmbraLayout.settingsRowSpacing)
            VStack(alignment: .leading, spacing: UmbraLayout.space3) {
                content
            }
        }
    }
}

struct CompactMenuPicker<Option: Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let optionLabel: (Option) -> String
    var width: CGFloat = 230

    var body: some View {
        AppKitMenuPicker(
            title: title,
            options: options,
            selection: $selection,
            optionLabel: optionLabel
        )
        .frame(width: width, height: UmbraLayout.macOSControlHeight)
    }
}

private struct AppKitMenuPicker<Option: Hashable>: NSViewRepresentable {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let optionLabel: (Option) -> String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.bezelStyle = .rounded
        picker.controlSize = .small
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.selectionChanged(_:))
        picker.cell?.lineBreakMode = .byTruncatingMiddle
        update(picker)
        return picker
    }

    func updateNSView(_ picker: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        update(picker)
    }

    private func update(_ picker: NSPopUpButton) {
        let titles = options.map(optionLabel)
        if picker.itemTitles != titles {
            picker.removeAllItems()
            picker.addItems(withTitles: titles)
        }
        if let selectedIndex = options.firstIndex(of: selection) {
            picker.selectItem(at: selectedIndex)
        }
        picker.setAccessibilityLabel(title)
        picker.setAccessibilityValue(optionLabel(selection))
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: AppKitMenuPicker

        init(parent: AppKitMenuPicker) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard index >= 0,
                  parent.options.indices.contains(index)
            else { return }
            parent.selection = parent.options[index]
        }
    }
}

struct CompactSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let accessibilityLabel: String
    let accessibilityValue: (Double) -> String

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.controlSize = .mini
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.setAccessibilityValue(accessibilityValue(value))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.altIncrementValue = step
        if abs(slider.doubleValue - value) > .ulpOfOne {
            slider.doubleValue = value
        }
        slider.setAccessibilityValue(accessibilityValue(value))
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let step = max(sender.altIncrementValue, .ulpOfOne)
            value.wrappedValue = (sender.doubleValue / step).rounded() * step
        }
    }
}

struct CompactIntegerStepper: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let accessibilityLabel: String
    let accessibilityValue: (Int) -> String

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSStepper {
        let stepper = NSStepper(frame: .zero)
        stepper.controlSize = .small
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = context.coordinator
        stepper.action = #selector(Coordinator.valueChanged(_:))
        update(stepper)
        return stepper
    }

    func updateNSView(_ stepper: NSStepper, context: Context) {
        context.coordinator.value = $value
        update(stepper)
    }

    private func update(_ stepper: NSStepper) {
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        if stepper.integerValue != value {
            stepper.integerValue = value
        }
        stepper.setAccessibilityLabel(accessibilityLabel)
        stepper.setAccessibilityValue(accessibilityValue(value))
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Int>

        init(value: Binding<Int>) {
            self.value = value
        }

        @objc func valueChanged(_ sender: NSStepper) {
            value.wrappedValue = sender.integerValue
        }
    }
}

struct CompactTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityHint: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.controlSize = .small
        field.placeholderString = placeholder
        field.alignment = .right
        field.delegate = context.coordinator
        update(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        update(field)
    }

    private func update(_ field: NSTextField) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityHelp(accessibilityHint)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
