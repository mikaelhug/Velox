import Foundation

/// Which operations are permitted on a workspace right now, and why not.
///
/// These are safety rules, not presentation: they are what stops a workspace operation from
/// doing something unrecoverable — deleting the disk a VM has open, deleting the last
/// workspace, duplicating a filesystem that has recorded errors. They live here, pure and
/// testable, rather than inline in a context menu where they can only be verified by
/// clicking. The menu just renders this.
public struct WorkspaceCapabilities: Equatable, Sendable {
    public let isActive: Bool
    public let canSwitch: Bool
    public let canDuplicate: Bool
    public let canRename: Bool
    public let canRelocate: Bool
    public let canDelete: Bool
    public let canRevealInFinder: Bool
    /// Why delete is unavailable, for help text. Nil when it is available.
    public let deleteBlockedReason: String?

    /// - Parameters:
    ///   - attachedDiskURL: the disk the running VM actually has open, or nil when nothing is
    ///     running. Checked **instead of** "is this the active workspace": `activeID` lives in
    ///     a file another process can rewrite, so it does not answer "does a VM hold this
    ///     file?". Unlinking a live disk succeeds silently on macOS and loses everything when
    ///     the guest stops.
    public init(workspace: Workspace,
                activeID: String?,
                workspaceCount: Int,
                engineBusy: Bool,
                attachedDiskURL: URL?) {
        let isActive = workspace.id == activeID
        let isAttached = attachedDiskURL?.standardizedFileURL
            == workspace.dataDiskURL.standardizedFileURL
        let exists = workspace.diskExists

        self.isActive = isActive
        self.canSwitch = !isActive && !engineBusy
        // Duplicating the ACTIVE workspace is allowed: the operation stops the engine first,
        // which is what makes the copy safe.
        self.canDuplicate = !engineBusy && exists
            && Storage.dataDiskIsClean(at: workspace.dataDiskURL)
        self.canRename = !engineBusy
        self.canRelocate = !engineBusy
        self.canRevealInFinder = exists

        if engineBusy {
            self.canDelete = false
            self.deleteBlockedReason = "Velox is busy."
        } else if isAttached || isActive {
            self.canDelete = false
            self.deleteBlockedReason = "This is the active workspace — switch to another first."
        } else if workspaceCount <= 1 {
            self.canDelete = false
            self.deleteBlockedReason = "Velox needs at least one workspace."
        } else {
            self.canDelete = true
            self.deleteBlockedReason = nil
        }
    }
}
