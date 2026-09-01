import SwiftUI
import VeloxCore

/// ⌘K command palette: type-to-find across containers, images, and volumes, with the
/// row actions inline (logs, shell, stop, open port/domain, copy). Searches only the
/// already-loaded stores, only while open — no index, no background work. Enter runs
/// the first container hit's default action (reveal in the Containers pane).
struct CommandPalette: View {
    @Environment(\.openWindow) private var openWindow
    /// Which daemon the palette acts on — the one whose pane is on screen, NOT always the
    /// local engine. Without this the palette silently searched and mutated this Mac while
    /// the window said "Containers — prod-server", so ⌘K → "stop" on a name that exists on
    /// both machines stopped the container on the wrong one.
    @Environment(\.dockerTarget) private var dockerTarget
    let store: DockerResourceStore
    let docker: any DockerClientProtocol
    @Binding var isPresented: Bool
    /// Reveal a container in the Containers pane (select + navigate).
    var reveal: (String) -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search containers, images, volumes…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onSubmit { runDefault() }
            Divider()
            List {
                containerResults(store)
                imageResults(store)
                volumeResults(store)
            }
            .listStyle(.plain)
            .frame(minHeight: 240, maxHeight: 360)
        }
        .frame(width: 520)
        .onAppear { focused = true }
        .onExitCommand { isPresented = false } // Esc
    }

    private func matches(_ s: String) -> Bool {
        query.isEmpty || s.localizedCaseInsensitiveContains(query)
    }

    private func runDefault() {
        if let c = store.containers.first(where: { matches($0.displayName) }) {
            reveal(c.id)
        }
        isPresented = false
    }

    // MARK: result sections

    @ViewBuilder
    private func containerResults(_ store: DockerResourceStore) -> some View {
        let hits = store.containers.filter { matches($0.displayName) }.prefix(6)
        if !hits.isEmpty {
            Section("Containers") {
                ForEach(Array(hits)) { c in
                    HStack(spacing: 8) {
                        Circle().fill(c.isRunning ? .green : .secondary).frame(width: 7, height: 7)
                        Text(c.displayName).fontWeight(.medium)
                        Spacer()
                        if c.isRunning {
                            if let pub = c.publishedBindings.first?.publicPort {
                                inlineAction(":\(pub)") {
                                    RowActions.openPort(pub, target: dockerTarget)
                                }
                            }
                            // Named access resolves through this Mac's own DNS responder, so
                            // it is meaningless for a container on another machine.
                            if let domain = c.namedAccessDomain, !dockerTarget.isRemote {
                                inlineAction("open") { RowActions.openDomain(domain) }
                            }
                            inlineAction("shell") {
                                RowActions.openShell(containerID: c.shortID, target: dockerTarget)
                            }
                            inlineAction("stop") {
                                Task { try? await docker.stopContainer(c.id) }
                            }
                        } else {
                            inlineAction("start") {
                                Task { try? await docker.startContainer(c.id) }
                            }
                        }
                        inlineAction("logs") {
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: WindowID.logs,
                                       value: LogWindowTarget(id: c.id, name: c.displayName,
                                                              image: c.image,
                                                              hostID: dockerTarget.remoteID))
                            isPresented = false
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { reveal(c.id); isPresented = false }
                }
            }
        }
    }

    @ViewBuilder
    private func imageResults(_ store: DockerResourceStore) -> some View {
        let hits = store.images.filter { matches("\($0.repository):\($0.tag)") }.prefix(4)
        if !hits.isEmpty && !query.isEmpty {
            Section("Images") {
                ForEach(Array(hits)) { img in
                    HStack {
                        Text("\(img.repository):\(img.tag)").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        inlineAction("copy ref") {
                            RowActions.copy("\(img.repository):\(img.tag)")
                            isPresented = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func volumeResults(_ store: DockerResourceStore) -> some View {
        let hits = store.volumes.filter { matches($0.name) }.prefix(4)
        if !hits.isEmpty && !query.isEmpty {
            Section("Volumes") {
                ForEach(Array(hits)) { v in
                    HStack {
                        Text(v.name)
                        Spacer()
                        inlineAction("copy path") {
                            RowActions.copy(v.mountpoint)
                            isPresented = false
                        }
                    }
                }
            }
        }
    }

    private func inlineAction(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.link)
    }
}
