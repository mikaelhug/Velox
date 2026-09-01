import SwiftUI
import VeloxCore

/// The sidebar's Hosts list: this Mac's engine, every configured remote Docker host, and a
/// "+" to add one.
///
/// Same two structural rules as `WorkspacesSection`, for the same reasons: this renders
/// **only** the section (every dialog is attached to the sidebar `List` by `RootView` via
/// `.remoteHostPrompts()`, because presentation modifiers hung off a `Section` are
/// unreliable), and the rows are **not** `List` selection items — clicking one switches
/// which engine the dashboards show, which is not navigation.
struct HostsSection: View {
    @Environment(RemoteHostController.self) private var remotes

    var body: some View {
        Section {
            HostRow(kind: .local, isSelected: remotes.selection.isLocal)
            ForEach(remotes.sortedHosts) { host in
                HostRow(kind: .remote(host), isSelected: remotes.selection.remoteID == host.id)
                    .contextMenu { menu(for: host) }
            }
            if let error = remotes.loadError {
                // `hosts.json` exists but wouldn't parse. Say so rather than present an
                // empty list, which looks exactly like "you never configured anything" —
                // and offer the way out, because a corrupt file fails every mutation,
                // including the delete that would otherwise fix it.
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Start a New List…") { remotes.panel.begin(.resetList) }
                            .font(.caption)
                            .buttonStyle(.link)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack(spacing: 4) {
                Text("Hosts")
                Spacer(minLength: 8)
                AddHostButton { remotes.panel.beginAdd() }
            }
            .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private func menu(for host: RemoteHost) -> some View {
        let state = remotes.capabilities(for: host)
        let panel = remotes.panel

        if !state.isSelected {
            Button("Show This Host") { remotes.select(.remote(host.id)) }
            Divider()
        }
        Button("Connect") { remotes.connect(host) }
            .disabled(!state.canConnect)
        Button("Disconnect") { remotes.disconnect(id: host.id) }
            .disabled(!state.canDisconnect)
        Divider()
        Button("Open SSH Session") { RowActions.openSSH(user: host.user, hostname: host.hostname, port: host.port) }
        Button("Copy SSH Command") {
            RowActions.copy(SSHTunnel.terminalLoginCommand(user: host.user,
                                                           hostname: host.hostname,
                                                           port: host.port))
        }
        Divider()
        Button("Rename…") { panel.begin(.rename(host), suggesting: host.name) }
        Button("Remove…", role: .destructive) { panel.begin(.delete(host)) }
    }
}

/// The "+" in the section header. Same shape as `WorkspacesSection`'s, for the same reason:
/// a bare `Image` in a `.plain` button is a ~10pt hit target that reads as decoration.
private struct AddHostButton: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .frame(width: 13, height: 13)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovering && isEnabled ? AnyShapeStyle(.quaternary)
                                                    : AnyShapeStyle(.clear)))
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help("Add a remote Docker host")
    }
}

/// One host row: a button, not a navigation item (see `HostsSection`).
private struct HostRow: View {
    enum Kind {
        case local
        case remote(RemoteHost)
    }

    let kind: Kind
    let isSelected: Bool

    @Environment(RemoteHostController.self) private var remotes
    @Environment(EngineController.self) private var engine
    @State private var hovering = false

    var body: some View {
        Button {
            guard !isSelected else { return }
            switch kind {
            case .local:            remotes.select(.local)
            case .remote(let host): remotes.select(.remote(host.id))
            }
        } label: {
            HStack(spacing: 0) {
                // `Label`, so the icon lands in the same column the navigation rows use.
                Label {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fontWeight(isSelected ? .semibold : .regular)
                } icon: {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint)
                                                    : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 4)
                status
            }
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering && !isSelected ? AnyShapeStyle(.quaternary)
                                                  : AnyShapeStyle(.clear)))
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
    }

    /// A running-container count once a host is answering, and a coloured dot before that.
    /// The count is the honest "is this working" signal — a dot alone can't distinguish a
    /// connected daemon from a tunnel that came up to nothing.
    @ViewBuilder
    private var status: some View {
        switch kind {
        case .local:
            if engine.state.isRunning, let count = runningCount(engine.resources) {
                countLabel(count)
            } else {
                Circle().fill(engine.state.tint).frame(width: 6, height: 6)
            }
        case .remote(let host):
            let session = remotes.session(for: host.id)
            if session?.state == .connected, let count = runningCount(session?.resources) {
                countLabel(count)
            } else {
                Circle().fill(tint(for: session?.state ?? .stopped)).frame(width: 6, height: 6)
            }
        }
    }

    private func countLabel(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func runningCount(_ store: DockerResourceStore?) -> Int? {
        guard let store, store.containersLoaded else { return nil }
        return store.containers.filter(\.isRunning).count
    }

    private func tint(for state: SSHTunnel.State) -> Color {
        switch state {
        case .connected:  return .green
        case .connecting: return .yellow
        case .failed:     return .red
        case .stopped:    return .secondary
        }
    }

    private var title: String {
        switch kind {
        case .local:            return "This Mac"
        case .remote(let host): return host.name
        }
    }

    private var helpText: String {
        switch kind {
        case .local:
            return "The Velox engine on this Mac"
        case .remote(let host):
            let session = remotes.session(for: host.id)
            let state = session?.state ?? .stopped
            return "\(state.failureMessage ?? state.label)\n\(host.subtitle)"
        }
    }
}

// MARK: - Prompts

extension View {
    /// Host every remote-host dialog on a stable view (the sidebar `List`), not on the
    /// section that raises them. See `RemoteHostPanel` for why this separation exists.
    func remoteHostPrompts(_ remotes: RemoteHostController) -> some View {
        modifier(RemoteHostPrompts(remotes: remotes))
    }
}

private struct RemoteHostPrompts: ViewModifier {
    let remotes: RemoteHostController

    private var panel: RemoteHostPanel { remotes.panel }

    private func presenting(_ match: @escaping (RemoteHostPanel.Prompt) -> Bool) -> Binding<Bool> {
        Binding(
            get: { panel.prompt.map(match) ?? false },
            set: { if !$0 { panel.dismiss() } })
    }

    /// True while a *text-entry* prompt is up (rename / remove). They share one `.alert`,
    /// for the same reason the workspace prompts do: stacking presentation modifiers on one
    /// view is not-quite-guaranteed behaviour, and one alert can only present the one prompt
    /// that is set. The add sheet is separate because it is a sheet, not an alert.
    private var editorPresented: Binding<Bool> {
        presenting { if case .add = $0 { return false }
                     if case .resetList = $0 { return false }
                     return true }
    }

    private var resetPresented: Binding<Bool> {
        presenting { if case .resetList = $0 { return true }; return false }
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: presenting { if case .add = $0 { return true }; return false }) {
                AddHostSheet(remotes: remotes)
            }
            .alert(editorTitle, isPresented: editorPresented) {
                TextField(editorFieldLabel, text: Bindable(panel).text)
                Button(editorConfirmLabel, role: editorIsDestructive ? .destructive : nil) {
                    confirmEditor()
                }
                .disabled(!panel.primaryEnabled)
                Button("Cancel", role: .cancel) { panel.dismiss() }
            } message: {
                if !editorMessage.isEmpty { Text(editorMessage) }
            }
            .confirmationDialog("Start a new host list?", isPresented: resetPresented) {
                Button("Move Aside and Start Over", role: .destructive) {
                    remotes.resetCorruptManifest()
                }
                Button("Cancel", role: .cancel) { panel.dismiss() }
            } message: {
                Text("The unreadable file is kept alongside the new one so it can still be "
                     + "recovered by hand. Nothing on any server is changed.")
            }
            .alert("Action failed", isPresented: Binding(
                get: { panel.error != nil },
                set: { if !$0 { panel.error = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(panel.error ?? "")
            }
    }

    // MARK: Prompt text

    private var editorTitle: String {
        switch panel.prompt {
        case .rename:                       return "Rename Host"
        case .delete(let host):             return "Remove “\(host.name)”?"
        case .add, .resetList, .none:       return ""
        }
    }

    private var editorFieldLabel: String {
        if case .delete = panel.prompt { return "Type the host name" }
        return "Name"
    }

    private var editorConfirmLabel: String {
        switch panel.prompt {
        case .rename:                 return "Rename"
        case .delete:                 return "Remove"
        case .add, .resetList, .none: return "OK"
        }
    }

    private var editorIsDestructive: Bool {
        if case .delete = panel.prompt { return true }
        return false
    }

    private var editorMessage: String {
        // Only Remove has anything worth saying, and the reassuring half is the point:
        // Velox removes a pointer, never anything on the server.
        if case .delete = panel.prompt {
            return "This only removes the host from Velox. Nothing on the server is changed "
                + "— its containers, images and volumes are untouched."
        }
        return ""
    }

    private func confirmEditor() {
        switch panel.prompt {
        case .rename(let host):
            guard let name = panel.proposedName else { return }
            remotes.rename(host, to: name)
        case .delete(let host):
            guard panel.deleteConfirmed else { return }
            remotes.delete(host)
        case .add, .resetList, .none:
            panel.dismiss()
        }
    }
}

/// The add-host sheet. A host needs several fields, so this is a form rather than the
/// single-field alert a workspace gets.
private struct AddHostSheet: View {
    let remotes: RemoteHostController
    @State private var showsAdvanced = false

    private var panel: RemoteHostPanel { remotes.panel }

    var body: some View {
        @Bindable var panel = remotes.panel
        return VStack(alignment: .leading, spacing: 0) {
            Text("Add Remote Host")
                .font(.headline)
                .padding(.bottom, 2)
            Text("Velox connects over SSH using your existing keys and `~/.ssh/config`. "
                 + "It never asks for or stores a password.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            Form {
                // Port sits beside Host, NOT under "Advanced". Running sshd on a
                // non-standard port is ordinary practice, and a port field the user has to
                // go looking for reads as "Velox only does 22". Leaving it at 22 still
                // defers to a `Port` set for this host in ~/.ssh/config — see
                // `SSHTunnel.arguments`.
                LabeledContent("Host") {
                    HStack(spacing: 6) {
                        TextField("", text: $panel.draftHostname,
                                  prompt: Text("server.example.com"))
                            .onChange(of: panel.draftHostname) { panel.draftError = nil }
                        Text("Port").foregroundStyle(.secondary)
                        TextField("", text: $panel.draftPort)
                            .frame(width: 58)
                            .multilineTextAlignment(.trailing)
                    }
                }
                TextField("User", text: $panel.draftUser)
                    .onChange(of: panel.draftUser) { panel.draftError = nil }
                TextField("Name", text: $panel.draftName,
                          prompt: Text(panel.draftHostname.isEmpty ? "Optional" : panel.draftHostname))
                    .onChange(of: panel.draftName) { panel.draftError = nil }
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    TextField("Docker socket", text: $panel.draftSocketPath)
                    TextField("Identity file", text: $panel.draftIdentityFile,
                              prompt: Text("Optional — normally set in ~/.ssh/config"))
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)

            // Reserve the line whether or not there is a complaint, so the sheet doesn't
            // jump as the user types.
            Text(panel.draftMessage ?? " ")
                .font(.caption)
                .foregroundStyle(panel.draftMessage == nil ? AnyShapeStyle(.secondary)
                                                           : AnyShapeStyle(.red))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { panel.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!panel.primaryEnabled)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(width: 420)
    }

    private func add() {
        guard let port = panel.draftPortValue, panel.draftComplaint == nil else { return }
        remotes.addHost(name: panel.effectiveDraftName,
                        user: panel.draftUser,
                        hostname: panel.draftHostname,
                        port: port,
                        socketPath: panel.draftSocketPath,
                        identityFile: panel.draftIdentityFile)
    }
}
