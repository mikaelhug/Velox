import Foundation

/// What a dashboard table's selection acts on — the one rule every multi-select pane
/// (Containers, Volumes, Images) resolves through, so a bulk delete touches exactly the rows
/// the user sees highlighted. Pure (no I/O) so the self-tests pin it.
///
/// Built from the rows the table currently *shows*: the filtered standalone rows, plus each
/// Compose project's header and its filtered members. Two failures it closes:
///
/// - **A header pulling deselected members back in.** ⌘A selects the header *and* every
///   member; ⌘-clicking one member out left the header selected, and expanding the header
///   re-added that member — the delete removed the very container the user had excluded. A
///   Shift-click range ending part-way into a group did the same. So a header stands for the
///   whole project only when its members weren't picked one by one: none picked → all of
///   them; all picked → all of them; some → just those.
/// - **Rows nobody can see.** SwiftUI keeps ids in the selection binding after a filter or a
///   collapsed group hides their rows, so "Delete 5" could include rows off-screen. Only
///   visible rows count; a collapsed group is represented by its header alone.
public struct TableSelection: Sendable {
    public struct Group: Sendable {
        public let header: String
        /// The members the table lists under the header (after filtering).
        public let members: [String]
        public let expanded: Bool
        public init(header: String, members: [String], expanded: Bool) {
            self.header = header; self.members = members; self.expanded = expanded
        }
    }

    private let visible: Set<String>
    private let groups: [String: Group]

    /// `rows` are the standalone (ungrouped) row ids the table shows.
    public init(rows: [String], groups: [Group] = []) {
        var visible = Set(rows)
        var byHeader: [String: Group] = [:]
        for g in groups {
            visible.insert(g.header)
            if g.expanded { visible.formUnion(g.members) }
            byHeader[g.header] = g
        }
        self.visible = visible
        self.groups = byHeader
    }

    /// The row ids that should be highlighted for a raw `ids` selection: visible rows only,
    /// minus any header whose members are only partly selected. Writing this back to the
    /// table's binding makes the highlight match what `resolve` will act on.
    public func effective(_ ids: Set<String>) -> Set<String> {
        var result = ids.intersection(visible)
        for (header, g) in groups where result.contains(header) {
            let picked = g.members.lazy.filter(result.contains).count
            if picked > 0 && picked < g.members.count { result.remove(header) }
        }
        return result
    }

    /// The item ids a selection acts on: `effective` rows, each surviving header replaced by
    /// its members.
    public func resolve(_ ids: Set<String>) -> Set<String> {
        var result: Set<String> = []
        for id in effective(ids) {
            if let g = groups[id] { result.formUnion(g.members) } else { result.insert(id) }
        }
        return result
    }
}
