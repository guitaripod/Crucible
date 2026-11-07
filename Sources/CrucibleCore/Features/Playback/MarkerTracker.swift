import Foundation

/// A skippable stretch of the timeline: Plex's intro or credits marker, or a recap, preview, ending,
/// intro or credits read from the file's chapter names.
package struct SkipMarker: Equatable, Hashable, Sendable {
    package enum Kind: String, Sendable, CaseIterable {
        case intro, credits, recap, preview, ending, commercial
    }

    package let kind: Kind
    package let startSecs: Double
    package let endSecs: Double
    /// Read from a chapter name rather than made by the server; such markers are offered, never skipped on their own.
    package let fromChapter: Bool

    package init(kind: Kind, startSecs: Double, endSecs: Double, fromChapter: Bool = false) {
        self.kind = kind
        self.startSecs = startSecs
        self.endSecs = endSecs
        self.fromChapter = fromChapter
    }

    /// A server marker, or one a download stored with `storedType`. The server's intro, credits and a DVR's
    /// commercial breaks keep their kind; any other server type is offered as an intro, as it always was.
    package init?(_ marker: PlexMarker) {
        let type = marker.type ?? ""
        let chapterPrefix = "chapter-"
        if type.hasPrefix(chapterPrefix) {
            guard let kind = Kind(rawValue: String(type.dropFirst(chapterPrefix.count))) else { return nil }
            self.init(kind: kind, startSecs: marker.startSecs, endSecs: marker.endSecs, fromChapter: true)
            return
        }
        let kind: Kind
        switch type {
        case "credits": kind = .credits
        case "commercial": kind = .commercial
        default: kind = .intro
        }
        self.init(kind: kind, startSecs: marker.startSecs, endSecs: marker.endSecs)
    }

    /// The marker type a download keeps it under, which `init?(_:)` reads back.
    package var storedType: String { fromChapter ? "chapter-\(kind.rawValue)" : kind.rawValue }

    package var isCredits: Bool { kind == .credits }

    package var title: String {
        switch kind {
        case .intro: return String(localized: "Skip Intro")
        case .credits: return String(localized: "Skip Credits")
        case .recap: return String(localized: "Skip Recap", comment: "Player button that jumps past the recap of earlier episodes")
        case .preview: return String(localized: "Skip Preview", comment: "Player button that jumps past the preview of the next episode")
        case .ending: return String(localized: "Skip Ending", comment: "Player button that jumps past an episode's ending song")
        case .commercial: return String(localized: "Skip Commercial", comment: "Player button that jumps past a commercial break in a recording")
        }
    }

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
/// credits are only ever offered, and only while Skip Outro allows it; each automatic intro skip
/// happens once per marker start, and only for an intro the server marked: a recap, preview, ending
/// or anything read from a chapter name is offered under Skip Intro's setting and never skipped by itself.
package struct MarkerTracker: Sendable {
    private let markers: [SkipMarker]
    private var autoSkipped: Set<Double> = []
    private var isSkipShown = false

    package init(markers: [PlexMarker]) {
        self.markers = markers.compactMap(SkipMarker.init)
    }

    package init(segments: [SkipMarker]) {
        self.markers = segments
    }

    /// `upNextVisible` hides the control and holds automatic skips back; `undoVisible` only hides the
    /// control while the "skipped, undo" confirmation is on screen.
    package mutating func evaluate(
        absolute: Double,
        mode: Preferences.SkipIntroMode,
        outroMode: Preferences.SkipOutroMode,
        upNextVisible: Bool,
        undoVisible: Bool
    ) -> MarkerAction {
        let active = markers.first { absolute >= $0.startSecs && absolute < $0.endSecs - 1 }
        guard let active, !upNextVisible else { return hide() }
        if active.isCredits {
            guard outroMode != .off, !undoVisible else { return hide() }
            isSkipShown = true
            return .showSkip(active, progress: active.progress(at: absolute))
        }
        guard mode != .off else { return hide() }
        if mode == .automatic, active.kind == .intro || active.kind == .commercial, !active.fromChapter, !autoSkipped.contains(active.startSecs) {
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
