import SwiftUI

struct ApplicationBrowserView: View {
    @ObservedObject var store: AppStore

    private var selectedApplication: ApplicationDisplayModel? {
        store.selectedVisibleApplication
    }

    var body: some View {
        Group {
            switch store.applicationsState {
            case .idle, .loading:
                LoadingStateView(title: "Loading Applications", message: "")
            case let .failed(message):
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "Apps Unavailable",
                    message: message,
                    actionTitle: "Try Again",
                    action: store.loadApplications
                )
            case .loaded:
                if store.visibleApplications.isEmpty {
                    EmptyStateView(
                        symbol: emptyStateSymbol,
                        title: emptyStateTitle,
                        message: emptyStateMessage,
                        actionTitle: emptyStateActionTitle,
                        action: emptyStateAction
                    )
                } else {
                    ApplicationCollectionView(
                        applications: store.visibleApplications,
                        selectedApplicationID: $store.selectedApplicationID,
                        scrollPositionID: $store.applicationScrollPositionID,
                        onActivate: store.launch,
                        onRequestQuit: store.requestQuit,
                        onToggleDirectLaunch: store.toggleDirectLaunch,
                        onToggleHidden: store.toggleHidden
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .loaded = store.applicationsState {
                if let warning = store.applicationCatalogWarning {
                    ApplicationCatalogWarningRail(message: warning, store: store)
                }
            }
        }
        .navigationTitle(store.selectedHost?.name ?? "Applications")
        .searchable(text: $store.applicationFilter, placement: .toolbar, prompt: "Search Apps")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: store.closeApplications) {
                    Label("Back to Hosts", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Hosts")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if let selectedApplication {
                    Button(
                        selectedApplication.isRunning ? "Resume" : "Launch",
                        systemImage: selectedApplication.isRunning ? UmbraSymbol.resume : UmbraSymbol.launch
                    ) {
                        store.launch(selectedApplication)
                    }
                    .help(selectedApplication.isRunning ? "Resume selected app" : "Launch selected app")

                }

                Button(action: store.loadApplications) {
                    Label("Refresh Apps", systemImage: UmbraSymbol.refresh)
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh application library")
            }
        }
    }

    private var trimmedFilter: String {
        store.applicationFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptyStateSymbol: String {
        if !trimmedFilter.isEmpty { return "magnifyingglass" }
        return store.applications.contains(where: \.isHidden) ? UmbraSymbol.hidden : "rectangle.stack"
    }

    private var emptyStateTitle: String {
        trimmedFilter.isEmpty ? "No Apps to Show" : "No Results"
    }

    private var emptyStateMessage: String {
        if !trimmedFilter.isEmpty {
            return "No applications match “\(trimmedFilter)”."
        }
        if store.applications.contains(where: \.isHidden) {
            return "This host has hidden apps. Show them to review or restore their visibility."
        }
        return "The host did not return any streamable applications."
    }

    private var emptyStateActionTitle: String? {
        if !trimmedFilter.isEmpty { return "Clear Search" }
        return store.applications.contains(where: \.isHidden) ? "Show Hidden Apps" : nil
    }

    private var emptyStateAction: (() -> Void)? {
        if !trimmedFilter.isEmpty { return { store.applicationFilter = "" } }
        return store.applications.contains(where: \.isHidden)
            ? { store.showHiddenApplications = true }
            : nil
    }

}

private struct ApplicationCatalogWarningRail: View {
    let message: String
    @ObservedObject var store: AppStore

    var body: some View {
        HStack(spacing: UmbraLayout.space3) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Refresh", action: store.loadApplications)
                .buttonStyle(.borderless)

            Button("Dismiss", systemImage: "xmark", action: store.dismissApplicationCatalogWarning)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Dismiss application refresh warning")
        }
        .padding(.horizontal, UmbraLayout.space6)
        .padding(.vertical, UmbraLayout.space3)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
