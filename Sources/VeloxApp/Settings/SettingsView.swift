import SwiftUI
import UniformTypeIdentifiers
import VeloxCore

/// The settings window: a Docker Desktop-style sidebar with General, Resources,
/// and File Sharing panes, backed by the persisted `VeloxConfig`. Edits write
/// through to ~/.velox/config.json; resource changes surface a "restart engine"
/// banner, while Resource Saver settings apply live.
struct SettingsView: View {
    @Environment(EngineController.self) private var engine
    @State private var selection: Pane = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general, resources, fileSharing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .resources: return "Resources"
            case .fileSharing: return "File Sharing"
            }
        }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .resources: return "cpu"
            case .fileSharing: return "folder"
            }
        }
    }

    var body: some View {
        @Bindable var engine = engine
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.icon).tag(pane)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Group {
                switch selection {
                case .general:     GeneralPane(config: $engine.config)
                case .resources:   ResourcesPane(config: $engine.config)
                case .fileSharing: FileSharingPane(config: $engine.config)
                }
            }
            .navigationTitle(selection.title)
            .frame(minWidth: 420, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        }
        .frame(width: 720, height: 520)
        // Persist every edit and re-apply the live-tunable ones (Resource Saver).
        .onChange(of: engine.config) { engine.applyRuntimeConfig() }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Binding var config: VeloxConfig
    @State private var updateMessage: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch Velox at login", isOn: $config.launchAtLogin)
                    .onChange(of: config.launchAtLogin) { _, enabled in LoginItem.set(enabled) }
                Picker("Software updates", selection: $config.updateBehavior) {
                    Text("Manual").tag(VeloxConfig.UpdateBehavior.manual)
                    Text("Notify when available").tag(VeloxConfig.UpdateBehavior.notify)
                    Text("Download automatically").tag(VeloxConfig.UpdateBehavior.automatic)
                }
                TextField("Default terminal", text: $config.defaultTerminal)
            }

            Section("Updates") {
                HStack {
                    Button(checking ? "Checking…" : "Check for Updates", action: checkForUpdates)
                        .disabled(checking)
                    if let updateMessage {
                        Text(updateMessage).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Section("About") {
                LabeledContent("Velox", value: Versions.velox)
                LabeledContent("Kernel", value: Versions.kernelVersion)
                LabeledContent("Docker", value: Versions.dockerVersion)
            }
        }
        .formStyle(.grouped)
    }

    private func checkForUpdates() {
        checking = true
        updateMessage = nil
        Task {
            let result = await Updater.checkForUpdate()
            updateMessage = result.message
            checking = false
        }
    }
}

// MARK: - Resources

private struct ResourcesPane: View {
    @Binding var config: VeloxConfig
    @Environment(EngineController.self) private var engine

    private var maxCores: Int { ProcessInfo.processInfo.activeProcessorCount }
    private var maxMemory: Int { max(2, Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))) }

    var body: some View {
        Form {
            if engine.needsRestart {
                Section { RestartBanner() }
            }
            Section("CPU") {
                IntSlider(value: $config.cpuCount, range: 1...maxCores,
                          unit: config.cpuCount == 1 ? "core" : "cores")
                Text("Number of virtual CPUs available to the engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Memory") {
                IntSlider(value: $config.memoryGiB, range: 1...maxMemory, unit: "GB")
                Text("Maximum RAM the guest may use. Resource Saver reclaims unused memory back to macOS while idle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Swap") {
                IntSlider(value: $config.swapGiB, range: 0...8,
                          unit: config.swapGiB == 0 ? "(off)" : "GB")
                Text("Disk-backed swap inside the guest, on the data disk. Lets memory-hungry builds spill over instead of being OOM-killed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Disk") {
                IntSlider(value: $config.diskGiB, range: 8...256, step: 8, unit: "GB")
                Text("Maximum size of the virtual data disk backing /var/lib/docker. The image is sparse — space is used only as needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ResourceSaverSection(config: $config)
        }
        .formStyle(.grouped)
    }
}

/// The Resource Saver controls — a live-tunable section (no restart needed).
private struct ResourceSaverSection: View {
    @Binding var config: VeloxConfig

    var body: some View {
        Section("Resource Saver") {
            Toggle("Enable Resource Saver", isOn: $config.resourceSaverEnabled)
            Text("Reduces CPU and memory utilization when no containers are running. Exit from Resource Saver mode happens automatically when containers are started.")
                .font(.caption).foregroundStyle(.secondary)
            if config.resourceSaverEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Idle time before entering Resource Saver")
                        .font(.callout)
                    IntSlider(value: $config.resourceSaverMinutes, range: 1...60,
                              unit: config.resourceSaverMinutes == 1 ? "minute" : "minutes")
                    Text("Duration of time between no containers running and Velox entering Resource Saver mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A labeled integer slider used across the Resources pane.
private struct IntSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    let unit: String

    var body: some View {
        HStack {
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Int($0.rounded()) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step))
            Text("\(value) \(unit)")
                .monospacedDigit().frame(width: 92, alignment: .trailing)
        }
    }
}

private struct RestartBanner: View {
    @Environment(EngineController.self) private var engine
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Changes apply after the engine restarts.")
            Spacer()
            Button("Restart Engine") { Task { await engine.restart() } }
                .disabled(engine.state.isBusy)
        }
    }
}

// MARK: - File Sharing

private struct FileSharingPane: View {
    @Binding var config: VeloxConfig
    @Environment(EngineController.self) private var engine
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if engine.needsRestart {
                RestartBanner().padding(12)
                Divider()
            }
            List {
                Section {
                    HStack {
                        Image(systemName: "house").foregroundStyle(.secondary)
                        Text("/Users")
                        Spacer()
                        Text("Always shared").font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Default") }

                Section {
                    if config.fileShares.isEmpty {
                        Text("No additional directories shared.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(config.fileShares, id: \.self) { path in
                            HStack {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                Text(path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(role: .destructive) { remove(path) } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                } header: { Text("Additional Directories") }
            }

            Divider()
            HStack {
                Button { importing = true } label: { Label("Add Directory…", systemImage: "plus") }
                Spacer()
                Text("Containers can mount these with `docker run -v`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            if !config.fileShares.contains(path) { config.fileShares.append(path) }
        }
    }

    private func remove(_ path: String) {
        config.fileShares.removeAll { $0 == path }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView().environment(EngineController())
    }
}
#endif
