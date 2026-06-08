import Foundation

/// Run `action` over `items` with **bounded concurrency**, returning the first error
/// string if any operation threw (others still run). The cap keeps a big "select-all"
/// bulk action (stop/remove containers, delete images/volumes) from opening hundreds of
/// VSOCK connections at once. Shared by the dashboard bulk actions so they all behave
/// the same — capped-parallel, not serial.
func runBounded<Item: Sendable>(
    over items: some Collection<Item>,
    maxConcurrent: Int = 16,
    _ action: @escaping @Sendable (Item) async throws -> Void
) async -> String? {
    guard !items.isEmpty else { return nil }
    return await withTaskGroup(of: String?.self) { group -> String? in
        var iterator = items.makeIterator()
        let cap = min(items.count, maxConcurrent)
        func add(_ item: Item) {
            group.addTask {
                do { try await action(item); return nil }
                catch { return "\(error)" }
            }
        }
        for _ in 0..<cap { if let item = iterator.next() { add(item) } }
        var firstError: String?
        while let result = await group.next() {
            if let result, firstError == nil { firstError = result }
            if let item = iterator.next() { add(item) }
        }
        return firstError
    }
}
