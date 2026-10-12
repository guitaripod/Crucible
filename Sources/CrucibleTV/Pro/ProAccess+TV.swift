import CrucibleCore

extension ProAccess {
    /// Whether locked controls show a lock glyph right now: free installs that can buy Pro only.
    var showsLocks: Bool {
        ProTVPresentation.showsLocks(status: status, isStoreBacked: isStoreBacked)
    }
}
