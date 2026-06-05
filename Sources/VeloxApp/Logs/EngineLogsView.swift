import SwiftUI

/// Live view of the engine's serial console (kernel + `vinit` + `dockerd`), backed
/// by `EngineLogStore`. Monospaced, filterable, auto-scrolling — the equivalent of
/// Docker Desktop's engine/troubleshoot log or `orb logs`.
struct EngineLogsView: View {
    @Bindable var store: EngineLogStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Filter", text: $store.filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle("Auto-scroll", isOn: $store.autoScroll)
                    .toggleStyle(.switch)
                Spacer()
                Text("\(store.filteredLines.count) lines")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear") { store.clear() }
            }
            .padding(8)
            Divider()
            logBody
        }
        .navigationTitle("Engine Logs")
    }

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(store.filteredLines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: store.lines.count) { _, _ in
                guard store.autoScroll, let last = store.filteredLines.last else { return }
                withAnimation(.none) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
