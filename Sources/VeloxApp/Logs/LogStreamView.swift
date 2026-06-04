import AppKit
import SwiftUI
import VeloxCore

/// Streaming container logs: ANSI-colored, searchable, auto-scrolling, and built
/// to survive high-velocity output. Rendering goes through an `NSTextView`
/// (`LogTextView`) that appends only new lines rather than rebuilding the whole
/// document each tick.
struct LogStreamView: View {
    let docker: any DockerClientProtocol
    let container: ContainerSummary
    @State private var store: LogStore
    @Environment(\.dismiss) private var dismiss

    init(docker: any DockerClientProtocol, container: ContainerSummary) {
        self.docker = docker
        self.container = container
        _store = State(initialValue: LogStore(docker: docker, containerID: container.id))
    }

    var body: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            toolbar($store.filter, $store.autoScroll)
            Divider()
            LogTextView(store: store)
        }
        .frame(minWidth: 620, minHeight: 420)
        .task {
            store.start()
            defer { store.stop() }
            // Keep the task alive while the sheet is open.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
        }
    }

    private func toolbar(_ filter: Binding<String>, _ autoScroll: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(container.displayName).fontWeight(.semibold)
                Text(container.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter", text: filter)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())

            Toggle(isOn: autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Auto-scroll")

            Button { store.clear() } label: { Image(systemName: "trash") }
                .help("Clear")

            Button("Done") { dismiss() }
        }
        .padding(10)
    }
}

/// `NSViewRepresentable` over a read-only `NSTextView`. The coordinator tracks
/// how many lines it has already drawn and appends only the delta; a generation
/// counter or a filter change triggers a full rebuild.
private struct LogTextView: NSViewRepresentable {
    var store: LogStore

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
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coord = context.coordinator
        guard let textView = coord.textView, let storage = textView.textStorage else { return }

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
                attrs[.foregroundColor] = line.isStderr ? NSColor.systemRed : NSColor.labelColor
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
    }
}
