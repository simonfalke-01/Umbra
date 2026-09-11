import SwiftUI

struct RootView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        NavigationStack {
            Group {
                if store.selectedHostID == nil {
                    HostBrowserView(store: store)
                } else {
                    ApplicationBrowserView(store: store)
                }
            }
        }
        .background(MainWindowConfigurator(mode: store.preferences.settings.uiDisplayMode))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let operation = store.operation {
                OperationRail(operation: operation, cancel: store.cancelCurrentOperation)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .sheet(item: $store.presentedSheet) { sheet in
            sheetContent(sheet)
        }
        .alert(item: $store.failure) { failure in
            if let recovery = failure.recovery {
                Alert(
                    title: Text(failure.title),
                    message: Text(failure.message),
                    primaryButton: .default(Text("Reconnect")) {
                        store.performRecovery(recovery)
                    },
                    secondaryButton: .cancel(Text("Dismiss"))
                )
            } else {
                Alert(
                    title: Text(failure.title),
                    message: Text(failure.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { store.confirmation != nil },
                set: { if !$0 { store.confirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: store.confirmation
        ) { confirmation in
            Button(confirmationActionTitle(confirmation), role: .destructive) {
                store.confirm(confirmation)
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmationMessage(confirmation))
        }
        .focusedSceneValue(\.umbraCommandActions, commandActions)
        .onAppear(perform: store.start)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: PresentedSheet) -> some View {
        switch sheet {
        case .addHost:
            AddHostSheet(store: store)
        case let .pair(id, pin):
            if let host = store.host(id: id) {
                PairHostSheet(host: host, pin: pin, store: store)
            } else {
                EmptyStateView(symbol: "questionmark.display", title: "Host Missing", message: "This host is no longer available.")
            }
        case let .rename(id):
            if let host = store.host(id: id) {
                RenameHostSheet(host: host, store: store)
            }
        case let .details(id):
            if let host = store.host(id: id) {
                HostDetailsSheet(host: host, store: store)
            }
        case let .networkResult(result):
            NetworkResultSheet(result: result)
        }
    }

    private var confirmationTitle: String {
        guard let confirmation = store.confirmation else { return "Confirm Action" }
        switch confirmation {
        case .deleteHost: return "Remove Host?"
        case .quitApplication, .replaceRunningApplication: return "Quit Running App?"
        }
    }

    private func confirmationActionTitle(_ confirmation: PresentedConfirmation) -> String {
        switch confirmation {
        case .deleteHost: "Remove Host"
        case .quitApplication: "Quit App"
        case .replaceRunningApplication: "Quit and Launch"
        }
    }

    private func confirmationMessage(_ confirmation: PresentedConfirmation) -> String {
        switch confirmation {
        case let .deleteHost(id):
            "Umbra will remove \(store.host(id: id)?.name ?? "this host") and its saved pairing information."
        case let .quitApplication(id):
            "\(store.application(id: id)?.name ?? "The running app") will close on the host. Unsaved progress will be lost."
        case let .replaceRunningApplication(current, next):
            "\(store.application(id: current)?.name ?? "The running app") must close before \(store.application(id: next)?.name ?? "the selected app") can launch. Unsaved progress will be lost."
        }
    }

    private var commandActions: UmbraCommandActions {
        let refresh: () -> Void = store.selectedHostID == nil
            ? { store.refreshHosts() }
            : { store.loadApplications() }
        let back: (() -> Void)? = store.selectedHostID == nil ? nil : { store.closeApplications() }
        let hostCommandGroups: [UmbraHostCommandGroup]
        if store.selectedHostID == nil, let host = store.focusedHost {
            hostCommandGroups = HostBrowserPresentation(host: host).actionGroups.map { group in
                UmbraHostCommandGroup(
                    id: group.id,
                    commands: group.actions.map { action in
                        UmbraHostCommand(descriptor: action) {
                            store.performHostBrowserAction(action, for: host)
                        }
                    }
                )
            }
        } else {
            hostCommandGroups = []
        }
        let showHidden: (() -> Void)? = store.selectedHostID == nil ? nil : { store.showHiddenApplications.toggle() }
        let cancel: (() -> Void)? = store.operation?.isCancellable == true ? { store.cancelCurrentOperation() } : nil
        return UmbraCommandActions(
            addHost: { store.showAddHost() },
            refresh: refresh,
            back: back,
            hostCommandGroups: hostCommandGroups,
            showHiddenApplications: showHidden,
            hiddenApplicationsShown: store.showHiddenApplications,
            cancelOperation: cancel
        )
    }
}
