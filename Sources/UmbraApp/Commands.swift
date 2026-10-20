import AppKit
import SwiftUI
import UmbraDiagnostics
import UniformTypeIdentifiers

struct UmbraCommandActions {
    var addHost: (() -> Void)?
    var refresh: (() -> Void)?
    var back: (() -> Void)?
    var hostCommandGroups: [UmbraHostCommandGroup] = []
    var showHiddenApplications: (() -> Void)?
    var hiddenApplicationsShown = false
    var cancelOperation: (() -> Void)?
}

struct UmbraHostCommandGroup: Identifiable {
    let id: HostBrowserActionGroup.ID
    let commands: [UmbraHostCommand]
}

struct UmbraHostCommand: Identifiable {
    let descriptor: HostBrowserActionDescriptor
    let perform: () -> Void

    var id: HostBrowserActionKind { descriptor.id }
}

private struct UmbraCommandActionsKey: FocusedValueKey {
    typealias Value = UmbraCommandActions
}

extension FocusedValues {
    var umbraCommandActions: UmbraCommandActions? {
        get { self[UmbraCommandActionsKey.self] }
        set { self[UmbraCommandActionsKey.self] = newValue }
    }
}

struct UmbraCommands: Commands {
    @FocusedValue(\.umbraCommandActions) private var actions
    let supportLog: SupportLog?

    init(supportLog: SupportLog? = nil) {
        self.supportLog = supportLog
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(UmbraLocalization.string("Add Host...")) { actions?.addHost?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions?.addHost == nil)
        }

        CommandGroup(after: .saveItem) {
            Button(UmbraLocalization.string("Refresh")) { actions?.refresh?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions?.refresh == nil)
        }

        CommandMenu(UmbraLocalization.string("Host")) {
            if actions?.hostCommandGroups.isEmpty != false {
                Button(UmbraLocalization.string("No Host Selected")) {}
                    .disabled(true)
            }
            ForEach(
                Array((actions?.hostCommandGroups ?? []).enumerated()),
                id: \.element.id
            ) { index, group in
                if index > 0 {
                    Divider()
                }
                ForEach(group.commands) { command in
                    if command.descriptor.role == .destructive {
                        Button(role: .destructive, action: command.perform) {
                            Label(command.descriptor.title, systemImage: command.descriptor.symbol)
                        }
                    } else {
                        Button(action: command.perform) {
                            Label(command.descriptor.title, systemImage: command.descriptor.symbol)
                        }
                    }
                }
            }
        }

        CommandMenu(UmbraLocalization.string("Navigate")) {
            Button(UmbraLocalization.string("Back to Hosts")) { actions?.back?() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions?.back == nil)
            Divider()
            Button(
                UmbraLocalization.string(
                    actions?.hiddenApplicationsShown == true ? "Hide Hidden Apps" : "Show Hidden Apps"
                )
            ) {
                actions?.showHiddenApplications?()
            }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(actions?.showHiddenApplications == nil)
        }

        CommandMenu(UmbraLocalization.string("Stream")) {
            Button(UmbraLocalization.string("Cancel Current Operation")) { actions?.cancelOperation?() }
                .keyboardShortcut(.cancelAction)
                .disabled(actions?.cancelOperation == nil)
        }

        CommandGroup(replacing: .help) {
            Button(UmbraLocalization.string("Export Diagnostics...")) {
                exportDiagnostics()
            }
            Divider()
            Button(UmbraLocalization.string("Umbra Setup Guide")) {
                open("https://github.com/simonfalke-01/Lumen/blob/main/docs/getting_started.md")
            }
            Button(UmbraLocalization.string("Troubleshooting")) {
                open("https://github.com/simonfalke-01/Lumen/blob/main/docs/troubleshooting.md")
            }
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = UmbraLocalization.string("Export Umbra Diagnostics")
        panel.message = UmbraLocalization.string("Choose where to save a privacy-safe diagnostics snapshot.")
        panel.prompt = UmbraLocalization.string("Export")
        panel.nameFieldStringValue = UmbraLocalization.string("Umbra Diagnostics.json")
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true

        panel.begin { [supportLog] response in
            guard response == .OK, let destinationURL = panel.url else { return }
            do {
                let snapshot = DiagnosticsSnapshot.capture(logger: supportLog)
                try DiagnosticsExporter().export(snapshot, to: destinationURL)
                supportLog?.record(
                    source: "Application",
                    level: .info,
                    message: "Exported a diagnostics snapshot selected by the user."
                )
            } catch {
                supportLog?.record(
                    source: "Application",
                    level: .error,
                    message: "Diagnostics export failed: \(error.localizedDescription)"
                )
                presentDiagnosticsExportFailure(error)
            }
        }
    }

    private func presentDiagnosticsExportFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = UmbraLocalization.string("Diagnostics Couldn’t Be Exported")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: UmbraLocalization.string("OK"))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
