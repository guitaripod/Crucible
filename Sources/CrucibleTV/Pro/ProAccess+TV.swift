import CrucibleCore

extension ProAccess {
    /// Whether locked controls show a lock glyph right now: free installs that can buy Pro only, never while the demo runs.
    var showsLocks: Bool {
        !hasFullAccess && ProTVPresentation.showsLocks(status: status, isStoreBacked: isStoreBacked)
    }
}
