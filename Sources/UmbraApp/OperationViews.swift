import SwiftUI

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
    private enum Field: Hashable {
        case address
    }

    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var port = ""
    @FocusState private var focusedField: Field?

    init(store: AppStore) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraLayout.space6) {
            Text("Add GameStream Host")
                .font(.title2.weight(.semibold))

            legacyFields
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    store.addHost(address: address, portText: port)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(UmbraLayout.space6)
        .frame(width: 520)
        .onAppear {
            focusedField = .address
        }
    }

    private var legacyFields: some View {
        Form {
            TextField(
                "Host name or IP address",
                text: $address,
                prompt: Text("gaming-pc.local or 192.168.1.20")
            )
            .focused($focusedField, equals: .address)
            .textContentType(.URL)
            TextField("Port (optional)", text: $port, prompt: Text("Default"))
                .frame(maxWidth: 160)
            Text("LSP hosts appear automatically when discovered on the local network.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
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
                Text(pairingTitle)
                    .font(.title2.weight(.semibold))
                Text(instructions)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(pin)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .textSelection(.enabled)
                .accessibilityLabel("Pairing PIN \(pin.map(String.init).joined(separator: " "))")

            if let fingerprint = store.pairingPreparations[host.id]?.provisionalSPKIFingerprint {
                VStack(spacing: UmbraLayout.space1) {
                    Text("Provisional host key fingerprint")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                    Text("Compare this value with Lumen before approving the PIN.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let preparation = store.pairingPreparations[host.id],
               !preparation.effectivePermissions.isEmpty {
                VStack(alignment: .leading, spacing: UmbraLayout.space1) {
                    Text("Permissions Lumen will grant")
                        .font(.caption.weight(.semibold))
                    Text(preparation.effectivePermissions.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if preparation.effectivePermissions != preparation.requestedPermissions {
                        Text("Lumen reduced the requested permission set. You can re-pair after changing host policy.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                            if host.id.rawValue.hasPrefix("lsp:") {
                                dismiss()
                                store.beginPairing(host)
                            } else {
                                store.performPairing(hostID: host.id, pin: pin)
                            }
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

    private var instructions: String {
        if host.id.rawValue.hasPrefix("lsp:") {
            return "Discovery name (unverified): \(host.name)\nEnter this six-digit PIN in the Lumen admin panel. The PIN expires after two minutes."
        }
        return "Enter this PIN in the Sunshine web interface."
    }

    private var pairingTitle: String {
        host.id.rawValue.hasPrefix("lsp:") ? "Pair with discovered Lumen host" : "Pair with \(host.name)"
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
    @ObservedObject var store: AppStore
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
                if host.id.rawValue.hasPrefix("lsp:") {
                    Button(host.isPaired ? "Re-pair…" : "Pair…") {
                        dismiss()
                        store.beginPairing(host)
                    }
                }
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
