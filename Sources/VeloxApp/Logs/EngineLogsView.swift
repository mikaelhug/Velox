import AppKit
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
        EngineLogText(store: store)
    }
}

/// `NSViewRepresentable` over a read-only `NSTextView` (the same approach as the
/// container-log `LogTextView`): SwiftUI's LazyVStack materializes a `Text` per line,
/// which gets janky against the 10k-line ring; AppKit's text engine handles it
/// natively. Appends only the new lines per update; rebuilds on filter change or
/// `clear()`, and compacts once the rendered text has outgrown the ring by half
/// (trimmed head lines linger harmlessly until then).
private struct EngineLogText: NSViewRepresentable {
    var store: EngineLogStore

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let attrs: [NSAttributedString.Key: Any] =
        [.font: font, .foregroundColor: NSColor.labelColor]

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
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(width: scroll.contentSize.width,
                                              height: .greatestFiniteMagnitude)
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coord = context.coordinator
        guard let textView = coord.textView, let storage = textView.textStorage else { return }
        let rebuild = coord.lastFilter != store.filter
            || coord.lastGeneration != store.generation
            || coord.renderedLines > 15_000 // compact: ring-trimmed head got too long
        if rebuild {
            coord.lastFilter = store.filter
            coord.lastGeneration = store.generation
            storage.setAttributedString(Self.attributed(store.filteredLines))
            coord.renderedLines = store.filteredLines.count
            coord.nextID = (store.lines.last?.id).map { $0 + 1 } ?? 0
        } else if let last = store.lines.last, last.id >= coord.nextID {
            let fresh = store.lines.drop(while: { $0.id < coord.nextID })
            let visible = store.filter.isEmpty
                ? Array(fresh)
                : fresh.filter { $0.text.localizedCaseInsensitiveContains(store.filter) }
            if !visible.isEmpty { storage.append(Self.attributed(visible)) }
            coord.renderedLines += visible.count
            coord.nextID = last.id + 1
        }
        if store.autoScroll { textView.scrollToEndOfDocument(nil) }
    }

    private static func attributed<S: Sequence>(_ lines: S) -> NSAttributedString
        where S.Element == EngineLogStore.Line {
        let text = lines.map(\.text).joined(separator: "\n")
        return NSAttributedString(string: text.isEmpty ? "" : text + "\n", attributes: attrs)
    }

    @MainActor
    final class Coordinator {
        var textView: NSTextView?
        var renderedLines = 0
        var nextID = 0
        var lastFilter = ""
        var lastGeneration = -1
    }
}
