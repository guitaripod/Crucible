import Foundation

/// A skippable stretch of the timeline: an intro, the credits, or any other server marker.
package struct SkipMarker: Equatable, Hashable, Sendable {
    package enum Kind: Sendable { case intro, credits }

    package let kind: Kind
    package let startSecs: Double
    package let endSecs: Double

    package init(kind: Kind, startSecs: Double, endSecs: Double) {
        self.kind = kind
        self.startSecs = startSecs
        self.endSecs = endSecs
    }

    package init(_ marker: PlexMarker) {
        self.init(kind: marker.isCredits ? .credits : .intro, startSecs: marker.startSecs, endSecs: marker.endSecs)
    }

    package var isCredits: Bool { kind == .credits }
    package var title: String { isCredits ? "Skip Credits" : "Skip Intro" }

    /// How far through the marker `absolute` is.
    package func progress(at absolute: Double) -> Double {
        let span = endSecs - startSecs
        return span > 0 ? (absolute - startSecs) / span : 0
    }
}

/// What the player surface should do after a playhead update.
package enum MarkerAction: Equatable, Sendable {
    case none
    case showSkip(SkipMarker, progress: Double)
    case autoSkip(SkipMarker)
    case hideSkip
}

/// Decides, once per playhead update, whether a skip control is offered, a marker is skipped on its
/// own, or the control goes away. A marker is active from its start until one second before its end;
/// credits are only ever offered; each automatic skip happens once per marker start.
package struct MarkerTracker: Sendable {
    private let markers: [SkipMarker]
    private var autoSkipped: Set<Double> = []
    private var isSkipShown = false

    package init(markers: [PlexMarker]) {
        self.markers = markers.map(SkipMarker.init)
    }

    /// `upNextVisible` hides the control and holds automatic skips back; `undoVisible` only hides the
    /// control while the "skipped, undo" confirmation is on screen.
    package mutating func evaluate(
        absolute: Double,
        mode: Preferences.SkipIntroMode,
        upNextVisible: Bool,
        undoVisible: Bool
    ) -> MarkerAction {
        let active = markers.first { absolute >= $0.startSecs && absolute < $0.endSecs - 1 }
        guard mode != .off, let active, !upNextVisible else { return hide() }
        if mode == .automatic, !active.isCredits, !autoSkipped.contains(active.startSecs) {
            autoSkipped.insert(active.startSecs)
            isSkipShown = false
            return .autoSkip(active)
        }
        guard !undoVisible else { return hide() }
        isSkipShown = true
        return .showSkip(active, progress: active.progress(at: absolute))
    }

    private mutating func hide() -> MarkerAction {
        guard isSkipShown else { return .none }
        isSkipShown = false
        return .hideSkip
    }
}
