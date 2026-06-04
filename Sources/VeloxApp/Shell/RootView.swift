import SwiftUI

/// The dashboard window: a sidebar of resource views and a detail pane. The
/// detail adapts to engine state — when the VM is down, every dashboard shows a
/// single "start the engine" affordance instead of an empty table.
struct RootView: View {
    @Environment(EngineController.self) private var engine
    @State private var selection: SidebarItem? = .containers

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                EngineStatusBar()
                    .padding(10)
            }
        } detail: {
            detail(for: selection ?? .containers)
                .frame(minWidth: 560, minHeight: 360)
        }
        .navigationTitle(selection?.title ?? "Velox")
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        if engine.state.isRunning, let docker = engine.docker {
            switch item {
            case .containers: ContainersView(docker: docker)
            case .images:     ImagesView(docker: docker)
            case .volumes:    VolumesView(docker: docker)
            case .networks:   NetworksView(docker: docker)
            }
        } else {
            EngineDownView(item: item)
        }
    }
}

/// Compact engine status + Start/Stop control pinned to the sidebar bottom.
struct EngineStatusBar: View {
    @Environment(EngineController.self) private var engine

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(engine.state.tint)
                .frame(width: 9, height: 9)
            Text(engine.state.label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if engine.state.isBusy {
                ProgressView().controlSize(.small)
            } else if engine.state.isRunning {
                Button("Stop") { Task { await engine.stop() } }
                    .controlSize(.small)
            } else {
                Button("Start") { Task { await engine.start() } }
                    .controlSize(.small)
                    .disabled(engine.needsOnboarding)
            }
        }
    }
}

/// Shown in the detail pane whenever the engine isn't running.
struct EngineDownView: View {
    @Environment(EngineController.self) private var engine
    let item: SidebarItem

    var body: some View {
        ContentUnavailableView {
            Label(item.title, systemImage: item.systemImage)
        } description: {
            if let failure = engine.state.failureMessage {
                Text(failure)
            } else if engine.needsOnboarding {
                Text("Finish setup to boot the Velox engine.")
            } else {
                Text("The Velox engine is \(engine.state.label.lowercased()). Start it to see \(item.title.lowercased()).")
            }
        } actions: {
            if !engine.needsOnboarding {
                Button(engine.state.isBusy ? "Starting…" : "Start Engine") {
                    Task { await engine.start() }
                }
                .disabled(engine.state.isBusy)
            }
        }
    }
}

#if DEBUG
struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environment(EngineController())
            .frame(width: 820, height: 480)
    }
}
#endif
