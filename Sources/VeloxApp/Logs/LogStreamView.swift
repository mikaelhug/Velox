import AppKit
import SwiftUI
import VeloxCore

/// Lightweight, `Codable` payload identifying a logs window so SwiftUI can key and
/// restore it (`ContainerSummary` is only `Decodable`, so it can't be a window value).
struct LogWindowTarget: Codable, Hashable, Identifiable {
    let id: String          // container id
    let name: String
    let image: String
    var shortID: String { String(id.prefix(12)) }
}

/// Hosts a logs window: pulls the live Docker client off the engine so the window
/// keeps working (and survives restore) as long as the engine is up.
struct LogWindowHost: View {
    let target: LogWindowTarget
    @Environment(EngineController.self) private var engine

    var body: some View {
        Group {
            if let docker = engine.docker {
                LogStreamView(docker: docker, target: target)
            } else {
                ContentUnavailableView("Engine not running",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("Start Velox to view container logs."))
            }
        }
        .navigationTitle("\(target.name) — Logs")
    }
}

/// Streaming container logs: ANSI-colored, searchable, auto-scrolling, wrap-toggle,
/// copyable, with a live status footer. Rendering goes through an `NSTextView`
/// (`LogTextView`) that appends only new lines rather than rebuilding each tick.
struct LogStreamView: View {
    let docker: any DockerClientProtocol
    let target: LogWindowTarget
    @State private var store: LogStore
    @State private var wrap = true

    init(docker: any DockerClientProtocol, target: LogWindowTarget) {
        self.docker = docker
        self.target = target
        _store = State(initialValue: LogStore(docker: docker, containerID: target.id))
    }

    var body: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            header($store.filter, $store.autoScroll)
            Divider()
            LogTextView(store: store, wrap: wrap)
            Divider()
            footer
        }
        .frame(minWidth: 660, minHeight: 460)
        .task {
            store.start()
            defer { store.stop() }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
        }
    }

    // MARK: Header

    private func header(_ filter: Binding<String>, _ autoScroll: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.name).fontWeight(.semibold)
                HStack(spacing: 5) {
                    Text(target.image).lineLimit(1).truncationMode(.middle)
                    Text("·")
                    Text(target.shortID).monospaced()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: filter)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                if !filter.wrappedValue.isEmpty {
                    Button { filter.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: Capsule())

            ControlGroup {
                Toggle(isOn: autoScroll) { Image(systemName: "arrow.down.to.line") }
                    .help("Auto-scroll to newest")
                Toggle(isOn: $wrap) { Image(systemName: "text.word.spacing") }
                    .help("Wrap long lines")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()

            Button { copyAll() } label: { Image(systemName: "doc.on.doc") }
                .help("Copy all log lines")
            Button { store.clear() } label: { Image(systemName: "trash") }
                .help("Clear the view")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isStreaming ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
                .opacity(store.isStreaming ? 1 : 0.5)
            Text(store.isStreaming ? "Streaming" : "Stream ended")
                .foregroundStyle(.secondary)

            Spacer()

            if !store.filter.isEmpty {
                Text("\(store.filteredLines.count) of \(store.lines.count) lines")
            } else {
                Text("\(store.lines.count) line\(store.lines.count == 1 ? "" : "s")")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.bar)
    }

    private func copyAll() {
        let text = store.filter.isEmpty
            ? store.plainText()
            : store.filteredLines.map(\.plain).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// `NSViewRepresentable` over a read-only `NSTextView`. The coordinator tracks how
/// many lines it has drawn and appends only the delta; a generation counter, a
/// filter change, or a wrap-mode change triggers a full rebuild.
private struct LogTextView: NSViewRepresentable {
    var store: LogStore
    var wrap: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true

        scroll.documentView = textView
        context.coordinator.textView = textView
        applyWrap(textView, scroll: scroll)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coord = context.coordinator
        guard let textView = coord.textView, let storage = textView.textStorage else { return }

        if coord.lastWrap != wrap {
            coord.lastWrap = wrap
            applyWrap(textView, scroll: nsView)
        }

        let filterChanged = coord.lastFilter != store.filter
        let rebuild = coord.lastGeneration != store.generation || filterChanged

        if rebuild {
            coord.lastGeneration = store.generation
            coord.lastFilter = store.filter
            let full = NSMutableAttributedString()
            for line in store.filteredLines { full.append(Self.attributed(line)) }
            storage.setAttributedString(full)
            coord.renderedCount = store.lines.count
        } else if store.lines.count > coord.renderedCount {
            let newLines = store.lines[coord.renderedCount...]
            let delta = NSMutableAttributedString()
            for line in newLines where store.filter.isEmpty
                || line.plain.localizedCaseInsensitiveContains(store.filter) {
                delta.append(Self.attributed(line))
            }
            if delta.length > 0 { storage.append(delta) }
            coord.renderedCount = store.lines.count
        }

        if store.autoScroll {
            textView.scrollToEndOfDocument(nil)
        }
    }

    /// Switch between soft-wrap (track the scroll width) and no-wrap (grow wide,
    /// horizontal scroller).
    private func applyWrap(_ textView: NSTextView, scroll: NSScrollView) {
        guard let container = textView.textContainer else { return }
        if wrap {
            scroll.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            container.size = NSSize(width: scroll.contentSize.width,
                                    height: CGFloat.greatestFiniteMagnitude)
        } else {
            scroll.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width, .height]
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // MARK: Rendering

    private static let baseFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)

    private static func attributed(_ line: LogStore.Line) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for span in line.spans {
            var attrs: [NSAttributedString.Key: Any] = [.font: span.bold ? boldFont : baseFont]
            if let fg = span.foreground {
                attrs[.foregroundColor] = ANSIPalette.color(fg)
            } else {
                // Deliberately NOT red for stderr: Docker's stderr stream is where many
                // daemons (nginx, postgres…) write perfectly normal logs — the fd says
                // nothing about severity. Apps that mean "error" color it themselves
                // via ANSI, which the branch above honors.
                attrs[.foregroundColor] = NSColor.labelColor
            }
            if let bg = span.background { attrs[.backgroundColor] = ANSIPalette.color(bg) }
            if span.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: span.text, attributes: attrs))
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
        return result
    }

    @MainActor
    final class Coordinator {
        var textView: NSTextView?
        var renderedCount = 0
        var lastGeneration = -1
        var lastFilter = ""
        var lastWrap = true
    }
}
