import SwiftUI

struct HostBrowserView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Group {
            switch store.hostsState {
            case .idle, .loading:
                LoadingStateView(
                    title: "Finding Hosts",
                    message: store.preferences.settings.enableMDNS
                        ? "Searching the local network for compatible hosts..."
                        : "Loading saved hosts..."
                )
            case let .failed(message):
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "Hosts Unavailable",
                    message: message,
                    actionTitle: "Try Again",
                    action: store.refreshHosts
                )
            case let .loaded(hosts) where hosts.isEmpty:
                EmptyStateView(
                    symbol: store.preferences.settings.enableMDNS ? "display.and.arrow.down" : "display.badge.plus",
                    title: "No Hosts Found",
                    message: store.preferences.settings.enableMDNS
                        ? "No compatible host is currently visible on the local network. You can add one by address."
                        : "Automatic discovery is disabled. Add a host by name or IP address.",
                    actionTitle: "Add Host",
                    action: store.showAddHost
                )
            case let .loaded(hosts):
                HostTableView(
                    hosts: hosts,
                    selectedHostID: $store.focusedHostID,
                    performAction: store.performHostBrowserAction
                )
            }
        }
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let host = store.focusedHost,
                   let action = HostBrowserPresentation(host: host).defaultAction {
                    Button(action.title, systemImage: action.symbol) {
                        store.performHostBrowserAction(action, for: host)
                    }
                    .help(action.title)
                }

                Button(action: store.refreshHosts) {
                    Label("Refresh Hosts", systemImage: UmbraSymbol.refresh)
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh host status")

                Button(action: store.showAddHost) {
                    Label("Add Host", systemImage: UmbraSymbol.addHost)
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a host manually")
            }
        }
    }
}
