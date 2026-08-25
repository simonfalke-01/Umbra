import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OperationRail: View {
    let operation: OperationPresentation
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: UmbraLayout.space3) {
            if let progress = operation.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: UmbraLayout.space1) {
                Text(operation.title)
                    .font(.callout.weight(.semibold))
                Text(operation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if operation.isCancellable {
                Button("Cancel", action: cancel)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, UmbraLayout.space4)
        .padding(.vertical, UmbraLayout.space3)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

struct AddHostSheet: View {
    private enum PairingMethod: Hashable {
        case invitation
        case legacy
    }

    private enum Field: Hashable {
        case invitation
        case address
    }

    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var pairingMethod: PairingMethod
    @State private var invitation: String
    @State private var address = ""
    @State private var port = ""
    @State private var isImportingInvitation = false
    @State private var isApplyingStoreInvitation = false
    @State private var importError: String?
    @StateObject private var importCoordinator: SecurePairingInvitationImportCoordinator
    @FocusState private var focusedField: Field?

    init(store: AppStore) {
        self.store = store
        _pairingMethod = State(initialValue: .invitation)
        _invitation = State(initialValue: store.pendingSecureInvitation)
        _importCoordinator = StateObject(
            wrappedValue: SecurePairingInvitationImportCoordinator()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraLayout.space6) {
            Text("Add Host")
                .font(.title2.weight(.semibold))

            Picker("Pairing method", selection: $pairingMethod) {
                Text("Lumen Invitation").tag(PairingMethod.invitation)
                Text("Moonlight PIN").tag(PairingMethod.legacy)
            }
            .pickerStyle(.segmented)
            .disabled(securePairingInProgress)

            Group {
                switch pairingMethod {
                case .invitation:
                    invitationFields
                case .legacy:
                    legacyFields
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(securePairingInProgress)

            HStack {
                Spacer()
                if pairingMethod == .invitation, store.operation?.kind == .pairing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Pairing in progress")
                    Button("Cancel Pairing") {
                        store.cancelCurrentOperation()
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(primaryActionTitle, action: performPrimaryAction)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(primaryActionDisabled)
                }
            }
        }
        .padding(UmbraLayout.space6)
        .frame(width: 520)
        .onAppear {
            focusedField = pairingMethod == .invitation ? .invitation : .address
        }
        .onChange(of: pairingMethod) { _, method in
            importCoordinator.invalidate()
            importError = nil
            if !isApplyingStoreInvitation {
                store.clearSecurePairingError()
            }
            focusedField = method == .invitation ? .invitation : .address
        }
        .onChange(of: invitation) {
            importCoordinator.invalidate()
            importError = nil
            if isApplyingStoreInvitation {
                isApplyingStoreInvitation = false
                return
            }
            store.clearSecurePairingError()
        }
        .onChange(of: store.pendingSecureInvitation) { _, replacement in
            guard invitation != replacement else { return }
            importCoordinator.invalidate()
            isApplyingStoreInvitation = true
            pairingMethod = .invitation
            invitation = replacement
            importError = nil
            focusedField = .invitation
        }
        .onChange(of: importCoordinator.completion) { _, completion in
            guard let completion, importCoordinator.owns(completion.token) else { return }
            switch completion.outcome {
            case let .success(importedInvitation):
                invitation = importedInvitation
                focusedField = .invitation
            case let .failure(message):
                importError = message
            }
        }
        .onDisappear {
            importCoordinator.invalidate()
        }
        .fileImporter(
            isPresented: $isImportingInvitation,
            allowedContentTypes: [.plainText, .image],
            allowsMultipleSelection: false,
            onCompletion: importInvitation
        )
    }

    private var invitationFields: some View {
        VStack(alignment: .leading, spacing: UmbraLayout.space2) {
            Text("Invitation")
                .font(.callout.weight(.medium))

            HStack(alignment: .firstTextBaseline, spacing: UmbraLayout.space2) {
                TextField(
                    "Lumen invitation",
                    text: $invitation,
                    prompt: Text("umbra://pair/v3#…")
                )
                .focused($focusedField, equals: .invitation)
                .textContentType(.URL)
                .accessibilityHint("Paste the invitation generated by Lumen")

                Button("Paste", action: pasteInvitation)
                Button("Import…") { isImportingInvitation = true }
                    .help("Import a text invitation or QR code image")
                    .accessibilityHint("Choose a text invitation or QR code image")
            }

            if let error = importError ?? store.securePairingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Pairing error: \(error)")
            }
        }
    }

    private var legacyFields: some View {
        Form {
            TextField(
                "Host name or IP address",
                text: $address,
                prompt: Text("gaming-pc.local or 192.168.1.25")
            )
            .focused($focusedField, equals: .address)
            .textContentType(.URL)
            TextField("Port (optional)", text: $port, prompt: Text("Default"))
                .frame(maxWidth: 160)
        }
        .formStyle(.grouped)
    }

    private var primaryActionTitle: String {
        pairingMethod == .invitation ? "Pair Securely" : "Add Host"
    }

    private var securePairingInProgress: Bool {
        pairingMethod == .invitation && store.operation?.kind == .pairing
    }

    private var primaryActionDisabled: Bool {
        switch pairingMethod {
        case .invitation:
            invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .legacy:
            address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func performPrimaryAction() {
        switch pairingMethod {
        case .invitation:
            store.pairSecureHost(invitationURI: invitation)
        case .legacy:
            store.addHost(address: address, portText: port)
        }
    }

    private func pasteInvitation() {
        importCoordinator.invalidate()
        guard let pasted = NSPasteboard.general.string(forType: .string),
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            importError = "The clipboard does not contain a Lumen invitation."
            return
        }
        invitation = pasted
        focusedField = .invitation
    }

    private func importInvitation(_ result: Result<[URL], Error>) {
        do {
            let url = try result.get().first
            guard let url else { return }
            importError = nil
            importCoordinator.start(url: url)
        } catch {
            importCoordinator.invalidate()
            importError = SecurePairingInvitationImportError.unreadable.localizedDescription
        }
    }
}

struct PairHostSheet: View {
    let host: HostDisplayModel
    let pin: String
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var started = false

    var body: some View {
        VStack(spacing: UmbraLayout.space6) {
            Image(systemName: "lock.open.display")
                .font(.system(size: 44, weight: .light))
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: UmbraLayout.space2) {
                Text("Pair with \(host.name)")
                    .font(.title2.weight(.semibold))
                Text("Enter this PIN on the host. If the host runs Sunshine, enter it in the Sunshine web interface.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(pin)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .textSelection(.enabled)
                .accessibilityLabel("Pairing PIN \(pin.map(String.init).joined(separator: " "))")

            if store.operation?.kind == .pairing {
                ProgressView("Waiting for host confirmation…")
                    .controlSize(.small)

                Button("Cancel Pairing") {
                    store.cancelCurrentOperation()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            } else {
                VStack(spacing: UmbraLayout.space2) {
                    Text("Pairing stopped.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: UmbraLayout.space2) {
                        Button("Cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("Try Again") {
                            store.performPairing(hostID: host.id, pin: pin)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(UmbraLayout.space8)
        .frame(width: 440)
        .onAppear {
            guard !started else { return }
            started = true
            store.performPairing(hostID: host.id, pin: pin)
        }
    }
}

struct RenameHostSheet: View {
    let host: HostDisplayModel
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(host: HostDisplayModel, store: AppStore) {
        self.host = host
        self.store = store
        _name = State(initialValue: host.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraLayout.space6) {
            VStack(alignment: .leading, spacing: UmbraLayout.space2) {
                Text("Rename Host")
                    .font(.title2.weight(.semibold))
                Text("Choose the name shown in Umbra. This does not rename the host computer itself.")
                    .foregroundStyle(.secondary)
            }

            TextField("Host name", text: $name)
                .focused($nameFocused)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { store.rename(host, to: name) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == host.name)
            }
        }
        .padding(UmbraLayout.space6)
        .frame(width: 440)
        .onAppear {
            nameFocused = true
        }
    }
}

struct HostDetailsSheet: View {
    let host: HostDisplayModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraLayout.space6) {
            VStack(alignment: .leading, spacing: UmbraLayout.space2) {
                Text(host.name)
                    .font(.title2.weight(.semibold))
                StatusLabel(
                    title: host.status.label,
                    symbol: host.status == .online ? "checkmark.circle" : UmbraSymbol.offline,
                    tone: host.status == .online ? .active : .neutral
                )
            }

            ScrollView {
                Text(host.details.isEmpty ? "The host did not provide additional details." : host.details)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(UmbraLayout.space6)
        .frame(width: 520, height: 360)
    }
}

struct NetworkResultSheet: View {
    let result: NetworkTestOutcome
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: UmbraLayout.space6) {
            Image(systemName: result.symbol)
                .font(.system(size: 44, weight: .light))
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: UmbraLayout.space2) {
                Text(result.title)
                    .font(.title2.weight(.semibold))
                Text(result.message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(UmbraLayout.space8)
        .frame(width: 500)
    }
}
