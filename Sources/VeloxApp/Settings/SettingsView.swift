import SwiftUI
import UniformTypeIdentifiers
import VeloxCore

/// The settings window: General, Resources, and File Sharing tabs backed by the
/// persisted `VeloxConfig`. Edits write through to ~/.velox/config.json; the
/// Resources/File-Sharing changes surface a "restart engine" banner.
struct SettingsView: View {
    @Environment(EngineController.self) private var engine

    var body: some View {
        @Bindable var engine = engine
        TabView {
            GeneralTab(config: $engine.config)
                .tabItem { Label("General", systemImage: "gearshape") }
            ResourcesTab(config: $engine.config)
                .tabItem { Label("Resources", systemImage: "cpu") }
            FileSharingTab(config: $engine.config)
                .tabItem { Label("File Sharing", systemImage: "folder") }
        }
        .frame(width: 540, height: 440)
        .onChange(of: engine.config) { engine.saveConfig() }
    }
}

// MARK: - General

private struct GeneralTab: View {
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

private struct ResourcesTab: View {
    @Binding var config: VeloxConfig
    @Environment(EngineController.self) private var engine

    private var maxCores: Int { ProcessInfo.processInfo.activeProcessorCount }
    private var maxMemory: Int { max(2, Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))) }

    var body: some View {
        Form {
            if engine.needsRestart {
                Section {
                    RestartBanner()
                }
            }
            Section("CPU") {
                slider(value: $config.cpuCount, range: 1...maxCores, unit: config.cpuCount == 1 ? "core" : "cores")
            }
            Section("Memory") {
                slider(value: $config.memoryGiB, range: 1...maxMemory, unit: "GB")
            }
            Section("Disk") {
                slider(value: $config.diskGiB, range: 8...256, step: 8, unit: "GB")
                Text("Maximum size of the virtual data disk backing /var/lib/docker. The image is sparse — space is used only as needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func slider(value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Slider(value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: Double(step))
                Text("\(value.wrappedValue) \(unit)")
                    .monospacedDigit().frame(width: 80, alignment: .trailing)
            }
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

private struct FileSharingTab: View {
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
