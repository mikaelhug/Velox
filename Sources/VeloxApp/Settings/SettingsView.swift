import AppKit
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
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
                    Text("Velox \(Versions.velox)").foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        } detail: {
            Group {
                switch selection {
                case .general:     GeneralPane(config: $engine.config)
                case .resources:   ResourcesPane(config: $engine.config)
                case .fileSharing: FileSharingPane(config: $engine.config)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        }
        .toolbar(removing: .sidebarToggle)
        .navigationTitle(selection.title)
        .frame(minWidth: 700, idealWidth: 720, minHeight: 520, idealHeight: 560)
        .onChange(of: engine.config) { engine.applyRuntimeConfig() }
        .background(CloseOnlyWindowButtons())
    }
}

private struct CloseOnlyWindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }

        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Binding var config: VeloxConfig
    @Environment(EngineController.self) private var engine
    @State private var activeContext: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch Velox at login", isOn: $config.launchAtLogin)
                    .onChange(of: config.launchAtLogin) { _, enabled in LoginItem.set(enabled) }
            } header: {
                Text("Startup")
            } footer: {
                Text("Velox lives in the menu bar and keeps the engine available without opening the dashboard.")
            }

            Section {
                Toggle("Notify when a container crashes", isOn: $config.notifyOnCrash)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Posts a macOS notification when a container exits with a non-zero code (clean stops are ignored). Event-driven — nothing polls.")
            }

            Section {
                Toggle("Check for updates on startup", isOn: $config.checkUpdatesOnStartup)
                LabeledContent("Status") { updateControls }
                if engine.availableUpdate?.isUpdateAvailable == true,
                   let urlString = engine.availableUpdate?.releaseURL,
                   let url = URL(string: urlString) {
                    Link("View release notes", destination: url)
                }
            } header: {
                Text("Software Updates")
            } footer: {
                Text("Updates are pulled from GitHub Releases and installed in place.")
            }

            Section {
                LabeledContent("Active context", value: activeContext ?? "—")
                Button("Use Velox context") {
                    engine.switchToVeloxContext()
                    activeContext = "velox"
                }
                .disabled(activeContext == "velox")
            } header: {
                Text("Docker CLI")
            } footer: {
                Text("Points the `docker` CLI at the Velox engine, so `docker` commands target Velox from any terminal.")
            }

            Section("About") {
                LabeledContent("Velox", value: Versions.velox)
                LabeledContent("Kernel", value: Versions.kernelVersion)
                LabeledContent("Docker Engine", value: Versions.dockerVersion)
                LabeledContent("Diagnostics") {
                    Button("Copy") { copyDiagnostics() }
                        .help("Copies versions, engine state, config, and the engine-log tail — paste into a bug report")
                }
            }
        }
        .formStyle(.grouped)
        .task { activeContext = await engine.activeDockerContext() }
    }

    /// Everything a useful bug report needs, one paste: versions, host, engine
    /// state + allocation, and the last 40 engine-log lines.
    private func copyDiagnostics() {
        var lines = [
            "Velox \(Versions.velox) — kernel \(Versions.kernelVersion), docker \(Versions.dockerVersion)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Engine: \(engine.state.label)"
                + (engine.startedAt.map { " (started \($0.formatted(date: .abbreviated, time: .standard)))" } ?? ""),
            "Config: \(engine.config.cpuCount) CPU · \(engine.config.memoryGiB) GiB RAM · "
                + "\(engine.config.diskGiB) GiB disk · \(engine.config.swapGiB) GiB swap · "
                + "saver \(engine.config.resourceSaverEnabled ? "on" : "off")",
            "",
            "— engine log (last 40 lines) —",
        ]
        lines += engine.engineLog.lines.suffix(40).map(\.text)
        RowActions.copy(lines.joined(separator: "\n"))
    }

    /// The right-hand control of the "Status" row: either an up-to-date / check
    /// affordance, or the available-update message plus an Update Now button.
    @ViewBuilder
    private var updateControls: some View {
        HStack(spacing: 8) {
            if engine.availableUpdate?.isUpdateAvailable == true {
                Text(engine.availableUpdate?.message ?? "Update available")
                    .foregroundStyle(.secondary)
                Button(engine.updateInProgress ? "Updating…" : "Update Now") {
                    engine.applyUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(engine.updateInProgress)
            } else {
                Text(engine.availableUpdate?.message ?? "Up to date")
                    .foregroundStyle(.secondary)
                Button(engine.checkingForUpdate ? "Checking…" : "Check Now") {
                    Task { await engine.checkForUpdates() }
                }
                .controlSize(.small)
                .disabled(engine.checkingForUpdate || engine.updateInProgress)
            }
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
            Section {
                IntSlider(value: $config.cpuCount, range: 1...maxCores,
                          unit: config.cpuCount == 1 ? "core" : "cores")
            } header: {
                Text("CPU")
            } footer: {
                Text("Number of virtual CPUs available to the engine.")
            }
            Section {
                IntSlider(value: $config.memoryGiB, range: 1...maxMemory, unit: "GB")
            } header: {
                Text("Memory")
            } footer: {
                Text("Maximum RAM the guest may use. Resource Saver reclaims unused memory back to macOS while idle.")
            }
            Section {
                IntSlider(value: $config.swapGiB, range: 0...8,
                          unit: config.swapGiB == 0 ? "(off)" : "GB")
            } header: {
                Text("Swap")
            } footer: {
                Text("Disk-backed swap inside the guest, on the data disk. Lets memory-hungry builds spill over instead of being OOM-killed.")
            }
            Section {
                IntSlider(value: activeDiskGiB, range: 8...256, step: 8, unit: "GB")
                if let workspace = engine.activeWorkspace {
                    DiskUsageRow(allocatedGiB: workspace.diskGiB,
                                 dataDiskURL: workspace.dataDiskURL)
                }
            } header: {
                Text("Disk")
            } footer: {
                // Size and location are per-workspace, so this section describes the active
                // one. Location lives on the workspace itself (right-click it in the
                // sidebar) rather than here, where it would read as a global setting.
                Text("Maximum size of \(activeName)'s data disk, backing /var/lib/docker. "
                    + "The image is sparse — only the space actually used is allocated on "
                    + "your Mac, and reclaimed when you remove images. To move it to another "
                    + "folder or disk, right-click the workspace in the sidebar.")
            }
            ResourceSaverSection(config: $config)
            NestedVirtualizationSection(config: $config)
        }
        .formStyle(.grouped)
        // The pending-restart bar lives OUTSIDE the scrolling Form (a fixed bottom
        // inset) so it can appear/disappear without changing the Form's section
        // structure — inserting it as a top Section reset the scroll to the top
        // mid-drag, which moved the slider out from under the cursor and broke it.
        .safeAreaInset(edge: .bottom) {
            if engine.needsRestart {
                RestartBanner()
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
            }
        }
    }

    /// The disk-size slider edits the ACTIVE workspace, and persists through the same
    /// debounced writer the rest of Settings uses — dragging a slider must not fsync a
    /// manifest on every integer tick.
    private var activeDiskGiB: Binding<Int> {
        Binding(
            get: { engine.activeWorkspace?.diskGiB ?? config.diskGiB },
            set: { engine.setActiveWorkspaceDiskGiB($0) })
    }

    private var activeName: String { engine.activeWorkspace?.name ?? "the workspace" }
}

/// Shows the data disk's **actual** on-disk footprint (the raw image is sparse, so
/// this is far below the allocated maximum) against the allocated size — the
/// equivalent of Docker Desktop's disk-usage readout. Read host-side in pure Swift
/// via the file's allocated-size resource value; refreshed on appear and on demand.
private struct DiskUsageRow: View {
    let allocatedGiB: Int
    let dataDiskURL: URL
    @State private var usedBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("On disk", systemImage: "internaldrive")
                Spacer()
                Text(usageText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            ProgressView(value: fraction)
                .tint(.purple)
        }
        .task { refresh() }
    }

    private var allocatedBytes: Double { Double(allocatedGiB) * 1024 * 1024 * 1024 }

    private var fraction: Double {
        guard let usedBytes, allocatedBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / allocatedBytes)
    }

    private var usageText: String {
        guard let usedBytes else { return "—" }
        let used = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        return "\(used) of \(allocatedGiB) GB"
    }

    private func refresh() {
        let vals = try? dataDiskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        usedBytes = vals?.totalFileAllocatedSize.map(Int64.init)
    }
}

/// Nested virtualization (KVM inside the guest) — restart-required, M3+/macOS 15.
private struct NestedVirtualizationSection: View {
    @Binding var config: VeloxConfig
    private let supported = VMConfiguration.nestedVirtualizationSupported

    var body: some View {
        Section {
            Toggle("Enable nested virtualization", isOn: $config.nestedVirtualization)
                .disabled(!supported)
        } header: {
            Text("Nested Virtualization")
        } footer: {
            Text(supported
                 ? "Exposes /dev/kvm inside the engine, so containers you grant it to (--device /dev/kvm) can run their own hardware-accelerated VMs — QEMU, Firecracker, Android emulators. Off by default; takes effect on restart."
                 : "Requires an Apple M3 or later. This Mac's chip doesn't support nested virtualization.")
        }
    }
}

/// The Resource Saver controls — a live-tunable section (no restart needed).
private struct ResourceSaverSection: View {
    @Binding var config: VeloxConfig

    var body: some View {
        Section {
            Toggle("Enable Resource Saver", isOn: $config.resourceSaverEnabled)
            if config.resourceSaverEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Idle timeout").font(.callout)
                    IntSlider(value: $config.resourceSaverMinutes, range: 1...60,
                              unit: config.resourceSaverMinutes == 1 ? "minute" : "minutes")
                }
            }
        } header: {
            Text("Resource Saver")
        } footer: {
            Text(config.resourceSaverEnabled
                 ? "Reclaims CPU and memory \(config.resourceSaverMinutes) \(config.resourceSaverMinutes == 1 ? "minute" : "minutes") after the last container stops. Exits automatically the moment a container starts."
                 : "Reduces CPU and memory usage when no containers are running. Exits automatically when a container starts.")
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
                        HStack {
                            Image(systemName: "folder.badge.questionmark").foregroundStyle(.tertiary)
                            Text("No additional directories shared.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(config.fileShares, id: \.self) { path in
                            HStack {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                Text(path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(role: .destructive) { remove(path) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }.buttonStyle(.borderless).help("Stop sharing")
                            }
                        }
                    }
                } header: {
                    Text("Additional Directories")
                } footer: {
                    Text("Containers can mount these read-write with `docker run -v`.")
                }
            }

            Divider()
            HStack {
                Button { importing = true } label: { Label("Add Directory…", systemImage: "plus") }
                Spacer()
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
