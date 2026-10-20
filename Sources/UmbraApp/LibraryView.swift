import AppKit
import SwiftUI

/// Hosts with the expanded host's applications directly beneath it.
///
/// One host is open at a time, matching the store's single application catalog. Arrow keys
/// move a keyboard cursor through hosts and application tiles; the cursor is drawn only after
/// keyboard use, so pointer clicks never leave a focus ring behind.
struct LibraryView: View {
    @ObservedObject var store: AppStore
    @FocusState private var libraryFocused: Bool
    @State private var cursor: LibraryCursor?
    @State private var keyboardNavigating = false
    @State private var shelfColumns = 1

    var body: some View {
        Group {
            switch store.hostsState {
            case .idle, .loading:
                LoadingStateView(title: "Finding hosts", message: "")
            case let .failed(message):
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "Couldn’t load hosts",
                    message: message,
                    actionTitle: "Try Again",
                    action: store.refreshHosts
                )
            case let .loaded(hosts) where hosts.isEmpty:
                EmptyStateView(
                    symbol: "display",
                    title: "No hosts",
                    message: "",
                    actionTitle: "Add Host",
                    action: store.showAddHost
                )
            case let .loaded(hosts):
                library(hosts)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Umbra")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: refresh) {
                    Label("Refresh", systemImage: UmbraSymbol.refresh)
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh")

                Button(action: store.showAddHost) {
                    Label("Add Host", systemImage: UmbraSymbol.addHost)
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("Add Host")
            }
        }
    }

    private func library(_ hosts: [HostDisplayModel]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hosts) { host in
                        HostRow(
                            host: host,
                            isExpanded: store.selectedHostID == host.id,
                            isCursor: keyboardNavigating && cursor == .host(host.id),
                            activate: { activate(host) },
                            perform: { store.performHostBrowserAction($0, for: host) }
                        )
                        .id(LibraryCursor.host(host.id))

                        if store.selectedHostID == host.id {
                            ApplicationShelf(
                                store: store,
                                cursor: keyboardNavigating ? cursor : nil,
                                columns: $shelfColumns,
                                pointerSelected: { application in
                                    keyboardNavigating = false
                                    cursor = .application(host.id, application.id)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, UmbraLayout.space3)
                .padding(.vertical, UmbraLayout.space2)
            }
            .onChange(of: cursor) { _, cursor in
                guard keyboardNavigating, let cursor else { return }
                withAnimation(.easeOut(duration: UmbraMotion.fast)) {
                    proxy.scrollTo(cursor)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($libraryFocused)
        .onAppear { libraryFocused = true }
        .onMoveCommand { direction in
            keyboardNavigating = true
            move(direction, hosts: hosts)
        }
        .onKeyPress(.return) { activateCursor(hosts: hosts) }
        .onKeyPress(.space) { activateCursor(hosts: hosts) }
        .onExitCommand {
            guard let selected = store.selectedHostID else { return }
            store.closeApplications()
            cursor = .host(selected)
        }
    }

    private func refresh() {
        store.selectedHostID == nil ? store.refreshHosts() : store.loadApplications()
    }

    /// A ready host toggles open; any other host runs its one available action (pair, wake, details).
    private func activate(_ host: HostDisplayModel) {
        cursor = .host(host.id)
        guard let action = HostBrowserPresentation(host: host).defaultAction else { return }
        if action.kind == .openApplications {
            store.selectedHostID == host.id ? store.closeApplications() : store.openApplications(for: host)
        } else {
            store.performHostBrowserAction(action, for: host)
        }
    }

    private var shelfApplications: [ApplicationDisplayModel] {
        guard case .loaded = store.applicationsState else { return [] }
        return store.visibleApplications
    }

    private func move(_ direction: MoveCommandDirection, hosts: [HostDisplayModel]) {
        guard let current = cursor, hosts.contains(where: { $0.id == current.hostID }) else {
            cursor = hosts.first.map { .host($0.id) }
            return
        }
        let applications = shelfApplications
        let hostIndex = hosts.firstIndex { $0.id == current.hostID } ?? 0
        let columns = max(shelfColumns, 1)
        switch (current, direction) {
        case let (.host(id), .down):
            if store.selectedHostID == id, let first = applications.first {
                cursor = .application(id, first.id)
            } else if hostIndex + 1 < hosts.count {
                cursor = .host(hosts[hostIndex + 1].id)
            }
        case (.host, .up):
            guard hostIndex > 0 else { return }
            let previous = hosts[hostIndex - 1]
            if store.selectedHostID == previous.id, let last = applications.last {
                cursor = .application(previous.id, last.id)
            } else {
                cursor = .host(previous.id)
            }
        case let (.host(id), .right):
            guard let host = hosts.first(where: { $0.id == id }) else { return }
            if store.selectedHostID == id, let first = applications.first {
                cursor = .application(id, first.id)
            } else if store.selectedHostID != id {
                activate(host)
            }
        case let (.host(id), .left):
            if store.selectedHostID == id { store.closeApplications() }
        case let (.application(hostID, applicationID), _):
            guard let index = applications.firstIndex(where: { $0.id == applicationID }) else {
                cursor = .host(hostID)
                return
            }
            switch direction {
            case .right where index + 1 < applications.count:
                cursor = .application(hostID, applications[index + 1].id)
            case .left where index % columns != 0:
                cursor = .application(hostID, applications[index - 1].id)
            case .left:
                cursor = .host(hostID)
            case .down where index + columns < applications.count:
                cursor = .application(hostID, applications[index + columns].id)
            case .down where hostIndex + 1 < hosts.count:
                cursor = .host(hosts[hostIndex + 1].id)
            case .up where index >= columns:
                cursor = .application(hostID, applications[index - columns].id)
            case .up:
                cursor = .host(hostID)
            default:
                break
            }
        @unknown default:
            break
        }
    }

    private func activateCursor(hosts: [HostDisplayModel]) -> KeyPress.Result {
        switch cursor {
        case let .host(id):
            guard let host = hosts.first(where: { $0.id == id }) else { return .ignored }
            activate(host)
            return .handled
        case let .application(_, applicationID):
            guard let application = shelfApplications.first(where: { $0.id == applicationID }) else {
                return .ignored
            }
            store.launch(application)
            return .handled
        case nil:
            return .ignored
        }
    }
}

enum LibraryCursor: Hashable {
    case host(HostID)
    case application(HostID, ApplicationID)

    var hostID: HostID {
        switch self {
        case let .host(id), let .application(id, _): id
        }
    }
}

// MARK: - Host row

private struct HostRow: View {
    let host: HostDisplayModel
    let isExpanded: Bool
    let isCursor: Bool
    let activate: () -> Void
    let perform: (HostBrowserActionDescriptor) -> Void

    @State private var hovering = false

    private var presentation: HostBrowserPresentation { HostBrowserPresentation(host: host) }

    /// Status is shown only when it changes what the user can do, and never repeats an
    /// action button beside it.
    private var status: String? {
        switch host.status {
        case .online where host.isPaired && host.isServerSupported && !host.hasActiveSession:
            nil
        case .offline:
            "Offline"
        default:
            presentation.statusSummary
        }
    }

    private var expandable: Bool { presentation.defaultAction?.kind == .openApplications }

    var body: some View {
        HStack(spacing: UmbraLayout.space3) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(expandable ? 1 : 0)
                .frame(width: UmbraLayout.disclosureWidth)
                .accessibilityHidden(true)

            Image(systemName: UmbraSymbol.host)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: UmbraLayout.hostSymbolWidth)
                .accessibilityHidden(true)

            Text(host.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            if let status {
                Text(status)
                    .foregroundStyle(statusStyle)
                    .lineLimit(1)
            }

            Spacer(minLength: UmbraLayout.space2)

            if let action = presentation.defaultAction, action.kind == .pair || action.kind == .wake {
                Button(action.compactTitle) { perform(action) }
                    .controlSize(.small)
            }

            HostActionsMenu(presentation: presentation, perform: perform)
        }
        .padding(.horizontal, UmbraLayout.space2)
        .frame(height: UmbraLayout.hostRowHeight)
        .contentShape(Rectangle())
        .background(rowFill, in: RoundedRectangle(cornerRadius: UmbraLayout.cornerMedium))
        .overlay {
            if isCursor {
                RoundedRectangle(cornerRadius: UmbraLayout.cornerMedium)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture(perform: activate)
        .contextMenu { HostActionsMenuItems(presentation: presentation, perform: perform) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(host.name)
        .accessibilityValue(presentation.statusSummary)
        .accessibilityAction(named: Text(isExpanded ? "Collapse" : "Expand"), activate)
    }

    private var rowFill: AnyShapeStyle {
        hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
    }

    private var statusStyle: AnyShapeStyle {
        switch presentation.statusTone {
        case .failure: AnyShapeStyle(Color(nsColor: .systemRed))
        case .warning: AnyShapeStyle(Color(nsColor: .systemOrange))
        case .neutral, .checking: AnyShapeStyle(.secondary)
        }
    }
}

private struct HostActionsMenu: View {
    let presentation: HostBrowserPresentation
    let perform: (HostBrowserActionDescriptor) -> Void

    var body: some View {
        Menu {
            HostActionsMenuItems(presentation: presentation, perform: perform)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: UmbraLayout.compactControl, height: UmbraLayout.compactControl)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Host Actions")
        .accessibilityLabel("Host Actions")
    }
}

private struct HostActionsMenuItems: View {
    let presentation: HostBrowserPresentation
    let perform: (HostBrowserActionDescriptor) -> Void

    var body: some View {
        ForEach(Array(presentation.actionGroups.enumerated()), id: \.element.id) { index, group in
            if index > 0 { Divider() }
            ForEach(group.actions) { action in
                Button(role: action.role == .destructive ? .destructive : nil) {
                    perform(action)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                }
            }
        }
    }
}

// MARK: - Application shelf

private struct ApplicationShelf: View {
    @ObservedObject var store: AppStore
    let cursor: LibraryCursor?
    @Binding var columns: Int
    let pointerSelected: (ApplicationDisplayModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraLayout.space3) {
            if let warning = store.applicationCatalogWarning {
                HStack(spacing: UmbraLayout.space2) {
                    Text(warning).foregroundStyle(.secondary)
                    Button("Dismiss", action: store.dismissApplicationCatalogWarning)
                        .buttonStyle(.link)
                }
            }
            content
        }
        .padding(.leading, UmbraLayout.shelfIndent)
        .padding(.top, UmbraLayout.space1)
        .padding(.bottom, UmbraLayout.space4)
    }

    @ViewBuilder
    private var content: some View {
        switch store.applicationsState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(height: UmbraLayout.applicationTileHeight, alignment: .leading)
        case let .failed(message):
            HStack(spacing: UmbraLayout.space2) {
                Text(message).foregroundStyle(.secondary)
                Button("Try Again", action: store.loadApplications)
            }
        case .loaded where store.visibleApplications.isEmpty:
            HStack(spacing: UmbraLayout.space2) {
                Text("No apps").foregroundStyle(.secondary)
                if store.applications.contains(where: \.isHidden) {
                    Button("Show Hidden Apps") { store.showHiddenApplications = true }
                        .buttonStyle(.link)
                }
            }
        case .loaded:
            GeometryReader { proxy in
                let available = max(proxy.size.width, UmbraLayout.applicationTileWidth)
                let count = max(
                    1,
                    Int((available + UmbraLayout.space3) / (UmbraLayout.applicationTileWidth + UmbraLayout.space3))
                )
                Color.clear.onAppear { columns = count }.onChange(of: count) { _, value in columns = value }
            }
            .frame(height: 0)

            LazyVGrid(
                columns: [GridItem(
                    .adaptive(minimum: UmbraLayout.applicationTileWidth, maximum: UmbraLayout.applicationTileWidth),
                    spacing: UmbraLayout.space3,
                    alignment: .top
                )],
                alignment: .leading,
                spacing: UmbraLayout.space4
            ) {
                ForEach(store.visibleApplications) { application in
                    ApplicationTile(
                        application: application,
                        isCursor: cursor == .application(application.hostID, application.id),
                        launch: {
                            pointerSelected(application)
                            store.launch(application)
                        },
                        store: store
                    )
                    .id(LibraryCursor.application(application.hostID, application.id))
                }
            }
        }
    }
}

private struct ApplicationTile: View {
    let application: ApplicationDisplayModel
    let isCursor: Bool
    let launch: () -> Void
    @ObservedObject var store: AppStore

    @State private var hovering = false

    var body: some View {
        VStack(spacing: UmbraLayout.space2) {
            ApplicationIcon(application: application)
                .frame(width: UmbraLayout.applicationIconSize, height: UmbraLayout.applicationIconSize)
                .clipShape(RoundedRectangle(cornerRadius: UmbraLayout.cornerIcon))
                .overlay {
                    RoundedRectangle(cornerRadius: UmbraLayout.cornerIcon)
                        .fill(.primary.opacity(hovering ? 0.06 : 0))
                }
                .overlay {
                    if isCursor {
                        RoundedRectangle(cornerRadius: UmbraLayout.cornerIcon + 3)
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                            .padding(-3)
                    }
                }

            VStack(spacing: 0) {
                Text(application.name)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if application.isRunning {
                    Text("Running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: UmbraLayout.applicationTileWidth)
        }
        .opacity(application.isHidden ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: launch)
        .contextMenu {
            Button(application.isRunning ? "Resume" : "Launch", action: launch)
            if application.isRunning {
                Button("Quit…") { store.requestQuit(application) }
            }
            Divider()
            Toggle("Launch Automatically", isOn: Binding(
                get: { application.isDirectLaunch },
                set: { _ in store.toggleDirectLaunch(application) }
            ))
            .disabled(application.isHidden)
            Toggle("Hide", isOn: Binding(
                get: { application.isHidden },
                set: { _ in store.toggleHidden(application) }
            ))
            .disabled(!application.isHidden && (application.isRunning || application.isDirectLaunch))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(application.name)
        .accessibilityValue(application.isRunning ? "Running" : "")
        .accessibilityAction(named: Text(application.isRunning ? "Resume" : "Launch"), launch)
    }
}

/// Host artwork when the user configured an image; otherwise a quiet symbol for the app kind.
struct ApplicationIcon: View {
    let application: ApplicationDisplayModel

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            symbol
            // Loaded artwork covers the symbol; a missing or failed image leaves it visible.
            if let url = application.artworkURL, url.isFileURL {
                ArtworkImage(url: url)
            }
        }
    }

    @ViewBuilder
    private var symbol: some View {
        switch application.kind {
        case .desktop:
            Image(systemName: "display").font(.system(size: 26, weight: .regular)).foregroundStyle(.secondary)
        case .steam:
            Image(systemName: "gamecontroller").font(.system(size: 26, weight: .regular)).foregroundStyle(.secondary)
        case .program:
            Text(application.name.first.map { String($0).uppercased() } ?? "")
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ArtworkImage: View {
    let url: URL
    @State private var image: NSImage?

    init(url: URL) {
        self.url = url
        _image = State(initialValue: ArtworkImageCache.shared.image(for: url))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            if let cached = ArtworkImageCache.shared.image(for: url) {
                image = cached
                return
            }
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled, let data, let decoded = NSImage(data: data) else { return }
            ArtworkImageCache.shared.insert(decoded, for: url)
            image = decoded
        }
    }
}

@MainActor
final class ArtworkImageCache {
    static let shared = ArtworkImageCache()
    private let storage = NSCache<NSURL, NSImage>()

    private init() {
        storage.countLimit = 256
    }

    func image(for url: URL) -> NSImage? {
        storage.object(forKey: url as NSURL)
    }

    func insert(_ image: NSImage, for url: URL) {
        storage.setObject(image, forKey: url as NSURL)
    }
}
