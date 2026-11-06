import Foundation

/// One selectable value of a choice setting.
package struct SettingChoice: Hashable, Identifiable, Sendable {
    package let id: Int
    package let title: String
    package let isSelected: Bool
    package let detail: String?

    package init(id: Int, title: String, isSelected: Bool, detail: String? = nil) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
        self.detail = detail
    }
}

/// Every preference the settings screens offer on either platform. Reads and writes go straight to `Preferences`, so a
/// screen only renders `control` and calls `select` or `setOn`; `didChange` lets each app react to a change it owns
/// (appearance, downloads, notifications).
package enum PreferenceSetting: CaseIterable, Sendable {
    case streamingQuality
    case remoteQuality
    case cellularQuality
    case autoplayNextEpisode
    case upNextCountdown
    case stillWatching
    case postPlaySuggestions
    case rewindAfterBreak
    case skipIntro
    case skipOutro
    case subtitleSize
    case skipBack
    case skipForward
    case holdLeft
    case holdRight
    case downloadQuality
    case downloadOverCellular
    case deleteWatchedDownloads
    case appearance
    case libraryGrid
    case notifyRatingReminders
    case ratingReminderTiming
    case notifyNewEpisodes
    case notifyWatchlistArrivals
    case notifyWeeklyRecap
    case notifyYearInReview
    case notifyDownloads
    case quietHours
    case preferLocalConnection
    case allowRelayConnection

    package enum Control: Equatable, Sendable {
        case choice([SettingChoice])
        case toggle(isOn: Bool)
    }

    /// Set by each app at launch; runs after a setting changed.
    @MainActor package static var didChange: (@MainActor (PreferenceSetting) -> Void)?

    package var title: String {
        switch self {
        case .streamingQuality: return String(localized: "Quality at Home", comment: "Setting: streaming quality on the home network")
        case .remoteQuality: return String(localized: "Quality Away from Home", comment: "Setting: streaming quality over a remote or relayed connection")
        case .cellularQuality: return String(localized: "Quality on Cellular", comment: "Setting: streaming quality on a cellular connection")
        case .autoplayNextEpisode: return String(localized: "Autoplay Next Episode")
        case .upNextCountdown: return String(localized: "Up Next Countdown", comment: "Setting: how long the Up Next card counts down")
        case .stillWatching: return String(localized: "Ask If Still Watching")
        case .postPlaySuggestions: return String(localized: "Suggest What to Watch Next", comment: "Setting: show titles like the one that just ended")
        case .rewindAfterBreak: return String(localized: "Rewind After a Break")
        case .skipIntro: return String(localized: "Skip Intro")
        case .skipOutro: return String(localized: "Skip Credits", comment: "Setting: what happens when the end credits start")
        case .subtitleSize: return String(localized: "Subtitle Size", comment: "Setting: how big subtitles are drawn")
        case .skipBack: return String(localized: "Skip Back")
        case .skipForward: return String(localized: "Skip Ahead")
        case .holdLeft: return String(localized: "Hold Left")
        case .holdRight: return String(localized: "Hold Right")
        case .downloadQuality: return String(localized: "Download Quality")
        case .downloadOverCellular: return String(localized: "Download over Cellular")
        case .deleteWatchedDownloads: return String(localized: "Delete Watched Downloads")
        case .appearance: return String(localized: "Appearance")
        case .libraryGrid: return String(localized: "Poster Size", comment: "Setting: how large posters are in library grids")
        case .notifyRatingReminders: return NotificationKind.ratingReminders.title
        case .ratingReminderTiming: return String(localized: "Remind Me", comment: "Setting: when a rating reminder arrives")
        case .notifyNewEpisodes: return NotificationKind.newEpisodes.title
        case .notifyWatchlistArrivals: return NotificationKind.watchlistArrivals.title
        case .notifyWeeklyRecap: return NotificationKind.weeklyRecap.title
        case .notifyYearInReview: return NotificationKind.yearInReview.title
        case .notifyDownloads: return NotificationKind.downloads.title
        case .quietHours: return String(localized: "Quiet Hours", comment: "Setting: hold reminders between 22:00 and 9:00")
        case .preferLocalConnection: return String(localized: "Prefer Local Connection")
        case .allowRelayConnection: return String(localized: "Allow Relay")
        }
    }

    package var explanation: String? {
        switch self {
        case .streamingQuality: return String(localized: "Original plays the file as it is whenever the device can. A lower quality asks the server to convert it to that bitrate.")
        case .remoteQuality: return String(localized: "Used when the server is reached over the internet or Plex Relay, where upload speed is often the limit.")
        case .cellularQuality: return String(localized: "Used on mobile data, to keep a movie from using up your plan.")
        case .autoplayNextEpisode: return String(localized: "The next episode starts on its own when the credits roll.")
        case .upNextCountdown: return String(localized: "How long the Up Next card waits before the next episode starts.")
        case .skipIntro: return String(localized: "Skip Intro can show a button, skip automatically, or stay out of the way.")
        case .skipOutro: return String(localized: "Skip Credits decides what the credits do: show the Up Next card, start the next episode automatically, or stay out of the way.")
        case .rewindAfterBreak: return String(localized: "After a break, playback backs up a few seconds, more the longer you were away.")
        case .stillWatching: return String(localized: "Asks before the next episode once this many have played in a row without the remote.")
        case .postPlaySuggestions: return String(localized: "When a movie or the last episode of a show ends, titles like it wait on the screen instead of the player closing.")
        case .subtitleSize: return String(localized: "Applies to subtitles the server draws into the picture and to the ones the player draws.")
        case .skipBack, .skipForward: return String(localized: "How far one skip goes: a click on the left or right of the Siri Remote's clickpad, or the skip buttons on the Lock Screen, in Control Center and on headphones.")
        case .holdLeft, .holdRight: return String(localized: "What holding the left or right of the clickpad does: the system's rewind and fast forward, a jump, or Start Over and Next Episode.")
        case .downloadQuality: return String(localized: "The quality new downloads start at. You can still pick another one for each download.")
        case .downloadOverCellular: return String(localized: "Off keeps downloads waiting until you are on Wi-Fi.")
        case .deleteWatchedDownloads: return String(localized: "A download is removed once you have watched it to the end.")
        case .appearance: return String(localized: "Light, Dark, or the same as the rest of your device.")
        case .libraryGrid: return String(localized: "Large shows fewer, bigger posters in each library.")
        case .notifyRatingReminders: return NotificationKind.ratingReminders.explanation
        case .ratingReminderTiming: return String(localized: "When a rating reminder arrives after you finish something.")
        case .notifyNewEpisodes: return NotificationKind.newEpisodes.explanation
        case .notifyWatchlistArrivals: return NotificationKind.watchlistArrivals.explanation
        case .notifyWeeklyRecap: return NotificationKind.weeklyRecap.explanation
        case .notifyYearInReview: return NotificationKind.yearInReview.explanation
        case .notifyDownloads: return NotificationKind.downloads.explanation
        case .quietHours: return String(localized: "Reminders and the recap wait until 9:00 instead of arriving between 22:00 and 9:00.")
        case .preferLocalConnection: return String(localized: "Uses your home network's address for the server whenever it answers there.")
        case .allowRelayConnection: return String(localized: "Plex Relay reaches a server no other way can, at a lower speed.")
        }
    }

    package var symbol: String {
        switch self {
        case .streamingQuality: return "house"
        case .remoteQuality: return "globe"
        case .cellularQuality: return "cellularbars"
        case .autoplayNextEpisode: return "play"
        case .upNextCountdown: return "timer"
        case .stillWatching: return "moon.zzz"
        case .postPlaySuggestions: return "sparkles.tv"
        case .rewindAfterBreak: return "gobackward"
        case .skipIntro: return "forward.end"
        case .skipOutro: return "forward.end.circle"
        case .subtitleSize: return "textformat.size"
        case .skipBack: return "gobackward.10"
        case .skipForward: return "goforward.10"
        case .holdLeft: return "backward"
        case .holdRight: return "forward"
        case .downloadQuality: return "arrow.down.circle"
        case .downloadOverCellular: return "antenna.radiowaves.left.and.right"
        case .deleteWatchedDownloads: return "trash"
        case .appearance: return "circle.lefthalf.filled"
        case .libraryGrid: return "square.grid.3x3"
        case .notifyRatingReminders: return NotificationKind.ratingReminders.symbol
        case .ratingReminderTiming: return "clock"
        case .notifyNewEpisodes: return NotificationKind.newEpisodes.symbol
        case .notifyWatchlistArrivals: return NotificationKind.watchlistArrivals.symbol
        case .notifyWeeklyRecap: return NotificationKind.weeklyRecap.symbol
        case .notifyYearInReview: return NotificationKind.yearInReview.symbol
        case .notifyDownloads: return NotificationKind.downloads.symbol
        case .quietHours: return "moon"
        case .preferLocalConnection: return "house.and.flag"
        case .allowRelayConnection: return "arrow.triangle.branch"
        }
    }

    /// The notification a switch belongs to, for the switches of Settings › Notifications.
    package var notificationKind: NotificationKind? {
        switch self {
        case .notifyRatingReminders: return .ratingReminders
        case .notifyNewEpisodes: return .newEpisodes
        case .notifyWatchlistArrivals: return .watchlistArrivals
        case .notifyWeeklyRecap: return .weeklyRecap
        case .notifyYearInReview: return .yearInReview
        case .notifyDownloads: return .downloads
        default: return nil
        }
    }

    package var control: Control {
        switch self {
        case .streamingQuality:
            return .choice(Self.choices(Preferences.Quality.allCases, current: Preferences.streamingQuality, rawValue: \.rawValue, title: \.title))
        case .remoteQuality:
            return .choice(Self.qualityChoices(current: Preferences.remoteQuality, same: String(localized: "Same as at Home", comment: "Quality option that follows the quality at home")))
        case .cellularQuality:
            return .choice(Self.qualityChoices(current: Preferences.cellularQuality, same: String(localized: "Same as Away from Home", comment: "Quality option that follows the quality away from home")))
        case .autoplayNextEpisode:
            return .toggle(isOn: Preferences.autoplayNextEpisode)
        case .postPlaySuggestions:
            return .toggle(isOn: Preferences.postPlaySuggestions)
        case .upNextCountdown:
            return .choice(Preferences.upNextCountdownChoices.map {
                SettingChoice(id: $0, title: String(localized: "\($0) Seconds", comment: "Up Next countdown option, e.g. 10 Seconds"), isSelected: $0 == Preferences.upNextCountdown)
            })
        case .stillWatching:
            return .choice(StillWatchingRule.choices.map { limit in
                SettingChoice(id: limit, title: StillWatchingRule.label(for: limit), isSelected: limit == Preferences.stillWatchingAfter)
            })
        case .rewindAfterBreak:
            return .toggle(isOn: Preferences.rewindAfterBreak)
        case .skipIntro:
            return .choice(Self.choices(Preferences.SkipIntroMode.allCases, current: Preferences.skipIntroMode, rawValue: \.rawValue, title: \.title))
        case .skipOutro:
            return .choice(Self.choices(Preferences.SkipOutroMode.allCases, current: Preferences.skipOutroMode, rawValue: \.rawValue, title: \.title))
        case .subtitleSize:
            return .choice(Self.choices(SubtitleSize.allCases, current: Preferences.subtitleSize, rawValue: \.rawValue, title: \.title))
        case .skipBack:
            return .choice(Self.skipChoices(current: Preferences.skipBackSeconds))
        case .skipForward:
            return .choice(Self.skipChoices(current: Preferences.skipForwardSeconds))
        case .holdLeft:
            return .choice(Self.holdChoices(current: Preferences.holdLeftAction, forward: false))
        case .holdRight:
            return .choice(Self.holdChoices(current: Preferences.holdRightAction, forward: true))
        case .downloadQuality:
            return .choice(DownloadQuality.allCases.map {
                SettingChoice(id: $0.rawValue, title: $0.title, isSelected: $0 == Preferences.downloadQuality, detail: $0.detail)
            })
        case .downloadOverCellular:
            return .toggle(isOn: Preferences.downloadOverCellular)
        case .deleteWatchedDownloads:
            return .toggle(isOn: Preferences.deleteWatchedDownloads)
        case .appearance:
            return .choice(Self.choices(Preferences.Appearance.allCases, current: Preferences.appearance, rawValue: \.rawValue, title: \.title))
        case .libraryGrid:
            return .choice([
                SettingChoice(id: 3, title: String(localized: "Standard", comment: "Poster size option"), isSelected: Preferences.libraryColumns == 3),
                SettingChoice(id: 2, title: String(localized: "Large", comment: "Poster size option"), isSelected: Preferences.libraryColumns == 2),
            ])
        case .ratingReminderTiming:
            return .choice(Self.choices(RatingReminderTiming.allCases, current: Preferences.ratingReminderTiming, rawValue: \.rawValue, title: \.title))
        case .notifyRatingReminders, .notifyNewEpisodes, .notifyWatchlistArrivals, .notifyWeeklyRecap, .notifyYearInReview, .notifyDownloads:
            return .toggle(isOn: notificationKind.map { Preferences.notifies($0) } ?? false)
        case .quietHours:
            return .toggle(isOn: Preferences.quietHours)
        case .preferLocalConnection:
            return .toggle(isOn: Preferences.preferLocalConnection)
        case .allowRelayConnection:
            return .toggle(isOn: Preferences.allowRelayConnection)
        }
    }

    package var choices: [SettingChoice] {
        if case .choice(let choices) = control { return choices }
        return []
    }

    package var isOn: Bool {
        if case .toggle(let isOn) = control { return isOn }
        return false
    }

    /// The text a value row shows: the selected choice, or On / Off for a toggle.
    package var valueLabel: String {
        switch control {
        case .choice(let choices): return choices.first(where: \.isSelected)?.title ?? ""
        case .toggle(let isOn): return isOn ? String(localized: "On") : String(localized: "Off")
        }
    }

    /// Whether the value differs from what a new install starts with, for Restore Defaults.
    package var isChanged: Bool { control != Self.defaults[self] }

    @MainActor
    package func select(_ choice: SettingChoice) {
        switch self {
        case .streamingQuality:
            guard let quality = Preferences.Quality(rawValue: choice.id) else { return }
            Preferences.streamingQuality = quality
        case .remoteQuality:
            guard choice.id == Preferences.sameQuality || Preferences.Quality(rawValue: choice.id) != nil else { return }
            Preferences.remoteQuality = Preferences.Quality(rawValue: choice.id)
        case .cellularQuality:
            guard choice.id == Preferences.sameQuality || Preferences.Quality(rawValue: choice.id) != nil else { return }
            Preferences.cellularQuality = Preferences.Quality(rawValue: choice.id)
        case .upNextCountdown:
            guard Preferences.upNextCountdownChoices.contains(choice.id) else { return }
            Preferences.upNextCountdown = choice.id
        case .skipIntro:
            guard let mode = Preferences.SkipIntroMode(rawValue: choice.id) else { return }
            Preferences.skipIntroMode = mode
        case .skipOutro:
            guard let mode = Preferences.SkipOutroMode(rawValue: choice.id) else { return }
            Preferences.skipOutroMode = mode
        case .subtitleSize:
            guard let size = SubtitleSize(rawValue: choice.id) else { return }
            Preferences.subtitleSize = size
        case .stillWatching:
            guard StillWatchingRule.choices.contains(choice.id) else { return }
            Preferences.stillWatchingAfter = choice.id
        case .skipBack:
            guard SkipRule.choices.contains(choice.id) else { return }
            Preferences.skipBackSeconds = choice.id
        case .skipForward:
            guard SkipRule.choices.contains(choice.id) else { return }
            Preferences.skipForwardSeconds = choice.id
        case .holdLeft:
            guard let action = HoldAction(rawValue: choice.id) else { return }
            Preferences.holdLeftAction = action
        case .holdRight:
            guard let action = HoldAction(rawValue: choice.id) else { return }
            Preferences.holdRightAction = action
        case .downloadQuality:
            guard let quality = DownloadQuality(rawValue: choice.id) else { return }
            Preferences.downloadQuality = quality
        case .appearance:
            guard let appearance = Preferences.Appearance(rawValue: choice.id) else { return }
            Preferences.appearance = appearance
        case .libraryGrid:
            guard choice.id == 2 || choice.id == 3 else { return }
            Preferences.libraryColumns = choice.id
        case .ratingReminderTiming:
            guard let timing = RatingReminderTiming(rawValue: choice.id) else { return }
            Preferences.ratingReminderTiming = timing
        default:
            return
        }
        Self.didChange?(self)
    }

    @MainActor
    package func setOn(_ isOn: Bool) {
        switch self {
        case .autoplayNextEpisode: Preferences.autoplayNextEpisode = isOn
        case .postPlaySuggestions: Preferences.postPlaySuggestions = isOn
        case .rewindAfterBreak: Preferences.rewindAfterBreak = isOn
        case .downloadOverCellular: Preferences.downloadOverCellular = isOn
        case .deleteWatchedDownloads: Preferences.deleteWatchedDownloads = isOn
        case .quietHours: Preferences.quietHours = isOn
        case .preferLocalConnection: Preferences.preferLocalConnection = isOn
        case .allowRelayConnection: Preferences.allowRelayConnection = isOn
        case .notifyRatingReminders, .notifyNewEpisodes, .notifyWatchlistArrivals, .notifyWeeklyRecap, .notifyYearInReview, .notifyDownloads:
            guard let kind = notificationKind else { return }
            Preferences.setNotifies(kind, isOn)
        default:
            return
        }
        if self == .preferLocalConnection || self == .allowRelayConnection {
            ServerRouteMonitor.shared.preferencesChanged()
        }
        Self.didChange?(self)
    }

    /// Puts the setting back to what a new install starts with.
    @MainActor
    package func restoreDefault() {
        switch Self.defaults[self] {
        case .toggle(let isOn)?:
            if self.isOn != isOn { setOn(isOn) }
        case .choice(let choices)?:
            if let choice = choices.first(where: \.isSelected), !(self.choices.first(where: \.isSelected)?.id == choice.id) { select(choice) }
        case nil:
            break
        }
    }

    private static let defaults: [PreferenceSetting: Control] = [
        .streamingQuality: .choice(choices(Preferences.Quality.allCases, current: .original, rawValue: \.rawValue, title: \.title)),
        .remoteQuality: .choice(qualityChoices(current: nil, same: String(localized: "Same as at Home", comment: "Quality option that follows the quality at home"))),
        .cellularQuality: .choice(qualityChoices(current: nil, same: String(localized: "Same as Away from Home", comment: "Quality option that follows the quality away from home"))),
        .autoplayNextEpisode: .toggle(isOn: true),
        .upNextCountdown: .choice(Preferences.upNextCountdownChoices.map {
            SettingChoice(id: $0, title: String(localized: "\($0) Seconds", comment: "Up Next countdown option, e.g. 10 Seconds"), isSelected: $0 == 10)
        }),
        .stillWatching: .choice(StillWatchingRule.choices.map { SettingChoice(id: $0, title: StillWatchingRule.label(for: $0), isSelected: $0 == StillWatchingRule.defaultLimit) }),
        .postPlaySuggestions: .toggle(isOn: true),
        .rewindAfterBreak: .toggle(isOn: true),
        .skipIntro: .choice(choices(Preferences.SkipIntroMode.allCases, current: .button, rawValue: \.rawValue, title: \.title)),
        .skipOutro: .choice(choices(Preferences.SkipOutroMode.allCases, current: .button, rawValue: \.rawValue, title: \.title)),
        .subtitleSize: .choice(choices(SubtitleSize.allCases, current: .standard, rawValue: \.rawValue, title: \.title)),
        .skipBack: .choice(skipChoices(current: SkipRule.defaultSeconds)),
        .skipForward: .choice(skipChoices(current: SkipRule.defaultSeconds)),
        .holdLeft: .choice(holdChoices(current: .scan, forward: false)),
        .holdRight: .choice(holdChoices(current: .scan, forward: true)),
        .downloadQuality: .choice(DownloadQuality.allCases.map { SettingChoice(id: $0.rawValue, title: $0.title, isSelected: $0 == .high, detail: $0.detail) }),
        .libraryGrid: .choice([
            SettingChoice(id: 3, title: String(localized: "Standard", comment: "Poster size option"), isSelected: true),
            SettingChoice(id: 2, title: String(localized: "Large", comment: "Poster size option"), isSelected: false),
        ]),
        .downloadOverCellular: .toggle(isOn: false),
        .deleteWatchedDownloads: .toggle(isOn: false),
        .appearance: .choice(choices(Preferences.Appearance.allCases, current: .system, rawValue: \.rawValue, title: \.title)),
        .ratingReminderTiming: .choice(choices(RatingReminderTiming.allCases, current: .anHourLater, rawValue: \.rawValue, title: \.title)),
        .notifyRatingReminders: .toggle(isOn: true),
        .notifyNewEpisodes: .toggle(isOn: true),
        .notifyWatchlistArrivals: .toggle(isOn: true),
        .notifyWeeklyRecap: .toggle(isOn: true),
        .notifyYearInReview: .toggle(isOn: true),
        .notifyDownloads: .toggle(isOn: true),
        .quietHours: .toggle(isOn: true),
        .preferLocalConnection: .toggle(isOn: true),
        .allowRelayConnection: .toggle(isOn: false),
    ]

    private static func qualityChoices(current: Preferences.Quality?, same: String) -> [SettingChoice] {
        [SettingChoice(id: Preferences.sameQuality, title: same, isSelected: current == nil)]
            + Preferences.Quality.allCases.map { SettingChoice(id: $0.rawValue, title: $0.title, isSelected: $0 == current) }
    }

    private static func skipChoices(current: Int) -> [SettingChoice] {
        SkipRule.choices.map { SettingChoice(id: $0, title: SkipRule.label(for: $0), isSelected: $0 == current) }
    }

    private static func holdChoices(current: HoldAction, forward: Bool) -> [SettingChoice] {
        HoldAction.allCases.map { SettingChoice(id: $0.rawValue, title: $0.title(forward: forward), isSelected: $0 == current) }
    }

    private static func choices<Value: Equatable>(
        _ values: [Value],
        current: Value,
        rawValue: KeyPath<Value, Int>,
        title: KeyPath<Value, String>
    ) -> [SettingChoice] {
        values.map { SettingChoice(id: $0[keyPath: rawValue], title: $0[keyPath: title], isSelected: $0 == current) }
    }
}
