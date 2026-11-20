import Foundation

/// How the player treats one kind of stretch it can skip: offer a button, skip it on its own, offer it in the episode the
/// viewer started and skip it in the ones that play on after it, or leave it alone.
package enum SkipMode: String, Codable, CaseIterable, Sendable {
    case button
    case automatic
    case afterFirstEpisode
    case off

    package var title: String {
        switch self {
        case .button: return String(localized: "Show Button")
        case .automatic: return String(localized: "Skip Automatically")
        case .afterFirstEpisode: return String(localized: "After the First Episode", comment: "Skip setting: show the skip button in the episode you start, then skip on its own in the episodes that play on")
        case .off: return String(localized: "Off")
        }
    }

    /// A line under the choice in a menu, where its title alone does not say it.
    package var detail: String? {
        switch self {
        case .afterFirstEpisode:
            return String(localized: "Offered in the episode you start, skipped in the ones after.", comment: "Explanation of the After the First Episode skip setting")
        case .button, .automatic, .off:
            return nil
        }
    }

    /// What Skip Credits means by this mode; credits have no After the First Episode, so it counts as the button.
    package var creditsMode: Preferences.SkipOutroMode {
        switch self {
        case .button, .afterFirstEpisode: return .button
        case .automatic: return .automatic
        case .off: return .off
        }
    }

    package init(_ mode: Preferences.SkipIntroMode) {
        switch mode {
        case .button: self = .button
        case .automatic: self = .automatic
        case .off: self = .off
        }
    }

    package init(_ mode: Preferences.SkipOutroMode) {
        switch mode {
        case .button: self = .button
        case .automatic: self = .automatic
        case .off: self = .off
        }
    }
}

/// The kinds of stretch a viewer decides on separately. A file's "ending" chapter is part of the credits; a server's
/// commercial breaks are a recording's.
package enum SkipKind: String, Codable, CaseIterable, Sendable {
    case intro
    case recap
    case credits
    case preview
    case commercial

    package init(_ kind: SkipMarker.Kind) {
        switch kind {
        case .intro: self = .intro
        case .recap: self = .recap
        case .credits, .ending: self = .credits
        case .preview: self = .preview
        case .commercial: self = .commercial
        }
    }

    /// The modes a viewer can pick: the credits hand over to Up Next, so they have no After the First Episode.
    package var modes: [SkipMode] {
        self == .credits ? [.button, .automatic, .off] : SkipMode.allCases
    }

    package var title: String {
        switch self {
        case .intro: return String(localized: "Intros", comment: "Skip setting for a show's opening titles")
        case .recap: return String(localized: "Recaps", comment: "Skip setting for the recap of earlier episodes")
        case .credits: return String(localized: "Credits", comment: "Skip setting for the end credits")
        case .preview: return String(localized: "Previews", comment: "Skip setting for the preview of the next episode")
        case .commercial: return String(localized: "Commercials", comment: "Skip setting for commercial breaks in recordings")
        }
    }

    package var explanation: String {
        switch self {
        case .intro:
            return String(localized: "A show's opening titles, where your server marks them or the file's chapters name them.", comment: "Explanation of the skip setting for intros")
        case .recap:
            return String(localized: "The recap of earlier episodes, where the file's chapters name it.", comment: "Explanation of the skip setting for recaps")
        case .credits:
            return String(localized: "Show Button offers Skip Credits and Up Next. Skip Automatically starts the next episode as the credits roll. Off lets them play.", comment: "Explanation of the skip setting for credits")
        case .preview:
            return String(localized: "Scenes from the next episode, where the file's chapters name them.", comment: "Explanation of the skip setting for previews")
        case .commercial:
            return String(localized: "The breaks your server found in a recording.", comment: "Explanation of the skip setting for commercials")
        }
    }

    package var symbol: String {
        switch self {
        case .intro: return "forward.end"
        case .recap: return "arrow.uturn.backward"
        case .credits: return "forward.end.circle"
        case .preview: return "film"
        case .commercial: return "tv"
        }
    }
}

/// What the player does with a stretch now.
package enum SkipDecision: Equatable, Sendable {
    /// Jumps past it on its own (closing credits never are: they hand over to Up Next instead).
    case skip
    /// Offers a button.
    case offer
    /// Leaves it alone.
    case ignore

    /// The decision for `marker` under `mode`, `titlesBefore` titles into the sitting (0 for the one the viewer started).
    /// The closing credits are offered even under Skip Automatically, which for them means Up Next starts the next episode
    /// on its own; an ending song filed with the credits is skipped like any other stretch.
    package static func decide(_ mode: SkipMode, for marker: SkipMarker, titlesBefore: Int) -> SkipDecision {
        switch mode {
        case .off: return .ignore
        case .button: return .offer
        case .automatic: return marker.isCredits ? .offer : .skip
        case .afterFirstEpisode: return titlesBefore > 0 && !marker.isCredits ? .skip : .offer
        }
    }
}

/// What one show or movie keeps for itself over Settings: how each kind of stretch is skipped, whether the next episode
/// plays on its own, and whether the screen matches the title. A show's episodes share one; nil (or a missing kind)
/// follows Settings. The name is kept for listing the titles that have rules of their own.
package struct TitlePlaybackRules: Codable, Equatable, Sendable {
    package var name: String?
    package var isShow: Bool?
    package var skips: [String: SkipMode] = [:]
    package var autoplay: Bool?
    package var matchContent = false

    package init(name: String? = nil, isShow: Bool? = nil) {
        self.name = name
        self.isShow = isShow
    }

    package subscript(kind: SkipKind) -> SkipMode? {
        get { skips[kind.rawValue] }
        set { skips[kind.rawValue] = newValue }
    }

    /// Whether anything differs from Settings, which is when the rules are worth keeping.
    package var hasRules: Bool { !skips.isEmpty || autoplay != nil || matchContent }

    /// The mode for `kind`: this title's own, or `settings`.
    package func mode(for kind: SkipKind, settings: SkipMode) -> SkipMode { self[kind] ?? settings }

    /// Whether the next episode starts on its own: this show's own choice, or `settings`.
    package func autoplays(settings: Bool) -> Bool { autoplay ?? settings }
}
