import Foundation

/// Which app a setting belongs to.
package enum SettingsPlatform: Sendable {
    case phone
    case tv
}

/// A screen a setting row opens.
package enum SettingsDestination: String, Hashable, Sendable {
    case homeRows
    case libraries
    case serverConnection
    case crucibleServer
    case manageStorage
    case notificationPermission
    case diagnostics
    case about
    case sourceCode
}

/// Something a setting row does at once, after a confirmation where it cannot be undone.
package enum SettingsAction: String, Hashable, Sendable {
    case shareLogs
    case clearImageCache
    case clearSearchHistory
    case forgetFinishedTitles

    package var needsConfirmation: Bool { self == .clearImageCache || self == .forgetFinishedTitles }

    package var confirmationTitle: String {
        switch self {
        case .clearImageCache: return String(localized: "Clear Image Cache?")
        case .forgetFinishedTitles: return String(localized: "Forget What You Finished?", comment: "Confirmation title for clearing the Rate What You Watched history")
        case .shareLogs, .clearSearchHistory: return ""
        }
    }

    package var confirmationMessage: String {
        switch self {
        case .clearImageCache: return String(localized: "Posters and backdrops will be downloaded again as you browse.")
        case .forgetFinishedTitles: return String(localized: "Rate What You Watched starts empty and no reminder is sent for anything finished so far.", comment: "Confirmation message for clearing the Rate What You Watched history")
        case .shareLogs, .clearSearchHistory: return ""
        }
    }

    package var confirmTitle: String {
        switch self {
        case .clearImageCache: return String(localized: "Clear")
        case .forgetFinishedTitles: return String(localized: "Forget", comment: "Button that clears the Rate What You Watched history")
        case .shareLogs, .clearSearchHistory: return ""
        }
    }
}

/// What a row of the settings is.
package enum SettingsItem: Hashable, Sendable {
    case preference(PreferenceSetting)
    case destination(SettingsDestination)
    case action(SettingsAction)
    case privacyStatement
}

/// A group of settings with its own screen.
package enum SettingsCategory: String, CaseIterable, Sendable {
    case playback
    case controls
    case home
    case downloads
    case notifications
    case appearance
    case connection
    case privacy
    case help

    package func title(on platform: SettingsPlatform) -> String {
        switch self {
        case .playback: return String(localized: "Playback", comment: "Settings section title for playback options")
        case .controls: return platform == .tv ? String(localized: "Remote", comment: "Settings category for the Siri Remote's skip and hold actions") : String(localized: "Skip Buttons", comment: "Settings category for skip distances")
        case .home: return String(localized: "Home & Libraries", comment: "Settings category for Home rows and library choices")
        case .downloads: return String(localized: "Downloads")
        case .notifications: return String(localized: "Notifications", comment: "Settings category for notifications")
        case .appearance: return String(localized: "Appearance")
        case .connection: return String(localized: "Server & Connection")
        case .privacy: return String(localized: "Privacy & Data", comment: "Settings category for privacy and stored data")
        case .help: return String(localized: "Help & About", comment: "Settings category for diagnostics, source code and version")
        }
    }

    package var symbol: String {
        switch self {
        case .playback: return "play.rectangle"
        case .controls: return "hand.point.up.left"
        case .home: return "house"
        case .downloads: return "arrow.down.circle"
        case .notifications: return "bell.badge"
        case .appearance: return "circle.lefthalf.filled"
        case .connection: return "server.rack"
        case .privacy: return "hand.raised"
        case .help: return "questionmark.circle"
        }
    }

    package func explanation(on platform: SettingsPlatform) -> String {
        switch self {
        case .playback: return String(localized: "Quality, Up Next, skipping and subtitles.")
        case .controls: return platform == .tv
            ? String(localized: "What the Siri Remote's clickpad does while a video plays.")
            : String(localized: "How far the skip buttons on the Lock Screen, in Control Center and on headphones go.")
        case .home: return String(localized: "Which rows Home shows, in what order, and which libraries count.")
        case .downloads: return String(localized: "Quality, cellular data and storage for offline viewing.")
        case .notifications: return String(localized: "Rating reminders, new episodes, watchlist arrivals and your weekly recap.")
        case .appearance: return String(localized: "Light or dark, and poster size.")
        case .connection: return String(localized: "How Crucible reaches your Plex server.")
        case .privacy: return String(localized: "What is kept on this device, and how to clear it.")
        case .help: return String(localized: "Diagnostics, the source code and the version you are running.")
        }
    }
}

/// One row of the settings: where it lives, what it is, and the words that find it.
package struct SettingsEntry: Hashable, Identifiable, Sendable {
    package let item: SettingsItem
    package let category: SettingsCategory
    package let section: String?

    package var id: String {
        switch item {
        case .preference(let setting): return "pref.\(setting)"
        case .destination(let destination): return "dest.\(destination.rawValue)"
        case .action(let action): return "action.\(action.rawValue)"
        case .privacyStatement: return "info.privacy"
        }
    }

    package var title: String {
        switch item {
        case .preference(let setting): return setting.title
        case .destination(let destination): return SettingsCatalog.title(destination)
        case .action(let action): return SettingsCatalog.title(action)
        case .privacyStatement: return String(localized: "Nothing Leaves This Device", comment: "Privacy statement row title")
        }
    }

    package var symbol: String {
        switch item {
        case .preference(let setting): return setting.symbol
        case .destination(let destination): return SettingsCatalog.symbol(destination)
        case .action(let action): return SettingsCatalog.symbol(action)
        case .privacyStatement: return "lock.shield"
        }
    }

    package var explanation: String? {
        switch item {
        case .preference(let setting): return setting.explanation
        case .destination(let destination): return SettingsCatalog.explanation(destination)
        case .action(let action): return SettingsCatalog.explanation(action)
        case .privacyStatement: return SettingsCatalog.privacyStatement
        }
    }

    package var keywords: [String] {
        SettingsCatalog.keywords(for: item)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Every setting of both apps, grouped the way Settings shows them, with search over titles, explanations and keywords.
package enum SettingsCatalog {
    private struct Spec {
        let item: SettingsItem
        let category: SettingsCategory
        let section: String?
        let platforms: Set<Platform>

        enum Platform { case phone, tv }
    }

    private static let both: Set<Spec.Platform> = [.phone, .tv]
    private static let phone: Set<Spec.Platform> = [.phone]
    private static let tv: Set<Spec.Platform> = [.tv]

    private static var specs: [Spec] {
        let quality = String(localized: "Streaming Quality", comment: "Settings section for the three streaming quality settings")
        let upNext = String(localized: "Up Next")
        let skipping = String(localized: "Skipping", comment: "Settings section for skip intro and skip credits")
        let subtitles = String(localized: "Subtitles")
        let reminders = String(localized: "Reminders", comment: "Settings section for rating reminders")
        let news = String(localized: "From Your Server", comment: "Settings section for new-episode, watchlist, recap and Year in Review notifications")
        return [
            Spec(item: .preference(.streamingQuality), category: .playback, section: quality, platforms: both),
            Spec(item: .preference(.remoteQuality), category: .playback, section: quality, platforms: both),
            Spec(item: .preference(.cellularQuality), category: .playback, section: quality, platforms: phone),
            Spec(item: .preference(.autoplayNextEpisode), category: .playback, section: upNext, platforms: both),
            Spec(item: .preference(.upNextCountdown), category: .playback, section: upNext, platforms: both),
            Spec(item: .preference(.stillWatching), category: .playback, section: upNext, platforms: both),
            Spec(item: .preference(.postPlaySuggestions), category: .playback, section: upNext, platforms: both),
            Spec(item: .preference(.rewindAfterBreak), category: .playback, section: upNext, platforms: both),
            Spec(item: .preference(.skipIntro), category: .playback, section: skipping, platforms: both),
            Spec(item: .preference(.skipOutro), category: .playback, section: skipping, platforms: both),
            Spec(item: .preference(.subtitleSize), category: .playback, section: subtitles, platforms: both),
            Spec(item: .preference(.skipBack), category: .controls, section: nil, platforms: both),
            Spec(item: .preference(.skipForward), category: .controls, section: nil, platforms: both),
            Spec(item: .preference(.holdLeft), category: .controls, section: nil, platforms: tv),
            Spec(item: .preference(.holdRight), category: .controls, section: nil, platforms: tv),
            Spec(item: .destination(.homeRows), category: .home, section: nil, platforms: both),
            Spec(item: .destination(.libraries), category: .home, section: nil, platforms: both),
            Spec(item: .preference(.downloadQuality), category: .downloads, section: nil, platforms: phone),
            Spec(item: .preference(.downloadOverCellular), category: .downloads, section: nil, platforms: phone),
            Spec(item: .preference(.deleteWatchedDownloads), category: .downloads, section: nil, platforms: phone),
            Spec(item: .destination(.manageStorage), category: .downloads, section: nil, platforms: phone),
            Spec(item: .destination(.notificationPermission), category: .notifications, section: nil, platforms: phone),
            Spec(item: .preference(.notifyRatingReminders), category: .notifications, section: reminders, platforms: phone),
            Spec(item: .preference(.ratingReminderTiming), category: .notifications, section: reminders, platforms: phone),
            Spec(item: .preference(.quietHours), category: .notifications, section: reminders, platforms: phone),
            Spec(item: .preference(.notifyNewEpisodes), category: .notifications, section: news, platforms: phone),
            Spec(item: .preference(.notifyWatchlistArrivals), category: .notifications, section: news, platforms: phone),
            Spec(item: .preference(.notifyWeeklyRecap), category: .notifications, section: news, platforms: phone),
            Spec(item: .preference(.notifyYearInReview), category: .notifications, section: news, platforms: phone),
            Spec(item: .preference(.notifyDownloads), category: .notifications, section: news, platforms: phone),
            Spec(item: .preference(.appearance), category: .appearance, section: nil, platforms: phone),
            Spec(item: .preference(.libraryGrid), category: .appearance, section: nil, platforms: phone),
            Spec(item: .destination(.serverConnection), category: .connection, section: nil, platforms: both),
            Spec(item: .destination(.crucibleServer), category: .connection, section: nil, platforms: both),
            Spec(item: .preference(.preferLocalConnection), category: .connection, section: nil, platforms: both),
            Spec(item: .preference(.allowRelayConnection), category: .connection, section: nil, platforms: both),
            Spec(item: .privacyStatement, category: .privacy, section: nil, platforms: both),
            Spec(item: .action(.clearSearchHistory), category: .privacy, section: nil, platforms: both),
            Spec(item: .action(.forgetFinishedTitles), category: .privacy, section: nil, platforms: both),
            Spec(item: .action(.clearImageCache), category: .privacy, section: nil, platforms: both),
            Spec(item: .action(.shareLogs), category: .help, section: nil, platforms: phone),
            Spec(item: .destination(.diagnostics), category: .help, section: nil, platforms: tv),
            Spec(item: .destination(.sourceCode), category: .help, section: nil, platforms: phone),
            Spec(item: .destination(.about), category: .help, section: nil, platforms: both),
        ]
    }

    private static func includes(_ spec: Spec, on platform: SettingsPlatform) -> Bool {
        spec.platforms.contains(platform == .phone ? .phone : .tv)
    }

    package static func entries(on platform: SettingsPlatform) -> [SettingsEntry] {
        specs.filter { includes($0, on: platform) }.map { SettingsEntry(item: $0.item, category: $0.category, section: $0.section) }
    }

    package static func categories(on platform: SettingsPlatform) -> [SettingsCategory] {
        let present = Set(entries(on: platform).map(\.category))
        return SettingsCategory.allCases.filter(present.contains)
    }

    /// A category's rows in order, grouped by section; the first group of a category without sections has no title.
    package static func sections(of category: SettingsCategory, on platform: SettingsPlatform) -> [(title: String?, entries: [SettingsEntry])] {
        var groups = [(title: String?, entries: [SettingsEntry])]()
        for entry in entries(on: platform) where entry.category == category {
            if let last = groups.indices.last, groups[last].title == entry.section {
                groups[last].entries.append(entry)
            } else {
                groups.append((entry.section, [entry]))
            }
        }
        return groups
    }

    /// The preference rows of a category, for Restore Defaults.
    package static func preferences(in category: SettingsCategory, on platform: SettingsPlatform) -> [PreferenceSetting] {
        entries(on: platform).compactMap { entry in
            guard entry.category == category, case .preference(let setting) = entry.item else { return nil }
            return setting
        }
    }

    /// A line under a category on the first Settings screen: the value that matters most there, or nil.
    @MainActor
    package static func summary(of category: SettingsCategory, on platform: SettingsPlatform) -> String? {
        switch category {
        case .playback:
            return PreferenceSetting.streamingQuality.valueLabel
        case .controls:
            return String(localized: "Back \(SkipRule.label(for: Preferences.skipBackSeconds)) · Ahead \(SkipRule.label(for: Preferences.skipForwardSeconds))", comment: "Summary of the skip distances, e.g. Back 10 Seconds · Ahead 30 Seconds")
        case .home:
            let rows = String(localized: "\(HomeLayout.visibleRows().count) rows", comment: "How many Home rows are on, e.g. 5 rows")
            return [rows, LibrariesSettings.summary].compactMap { $0 }.joined(separator: " · ")
        case .downloads:
            return PreferenceSetting.downloadQuality.valueLabel
        case .notifications:
            let on = NotificationKind.allCases.filter { Preferences.notifies($0) }.count
            return String(localized: "\(on) of \(NotificationKind.allCases.count) on", comment: "Summary of notification switches, e.g. 5 of 6 on")
        case .appearance:
            return PreferenceSetting.appearance.valueLabel
        case .connection:
            return Preferences.allowRelayConnection ? String(localized: "Relay allowed", comment: "Connection summary") : nil
        case .privacy:
            return String(localized: "No tracking", comment: "Privacy summary")
        case .help:
            return AppInfo.versionSummary
        }
    }

    /// Settings whose title, keywords, explanation, section or category match every word of `query`, best match first.
    package static func search(_ query: String, on platform: SettingsPlatform) -> [SettingsEntry] {
        let tokens = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let scored: [(entry: SettingsEntry, score: Int, order: Int)] = entries(on: platform).enumerated().compactMap { index, entry in
            let fields: [(text: String, weight: Int)] = [
                (entry.title, 8),
                (entry.keywords.joined(separator: " "), 4),
                (entry.section ?? "", 2),
                (entry.category.title(on: platform), 2),
                (entry.explanation ?? "", 1),
            ]
            let words = fields.map { field in (Self.words(field.text), field.weight) }
            var score = 0
            for token in tokens {
                let best = words.filter { $0.0.contains { $0.hasPrefix(token) } }.map(\.1).max()
                guard let best else { return nil }
                score += best
            }
            if normalized(entry.title).hasPrefix(normalized(query)) { score += 16 }
            return (entry, score, index)
        }
        return scored.sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }.map(\.entry)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func words(_ text: String) -> [String] {
        normalized(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    // MARK: - Copy

    package static func title(_ destination: SettingsDestination) -> String {
        switch destination {
        case .homeRows: return String(localized: "Home Rows", comment: "Settings row that opens the Home row arrangement")
        case .libraries: return String(localized: "Libraries")
        case .serverConnection: return String(localized: "Server & Connection")
        case .crucibleServer: return CompanionCopy.title
        case .manageStorage: return String(localized: "Manage Storage")
        case .notificationPermission: return String(localized: "Allow Notifications", comment: "Settings row showing whether iOS lets Crucible notify")
        case .diagnostics: return String(localized: "Diagnostics")
        case .about: return String(localized: "About Crucible")
        case .sourceCode: return String(localized: "Source Code")
        }
    }

    package static func symbol(_ destination: SettingsDestination) -> String {
        switch destination {
        case .homeRows: return "rectangle.grid.1x2"
        case .libraries: return "rectangle.stack"
        case .serverConnection: return "server.rack"
        case .crucibleServer: return "sparkles.tv"
        case .manageStorage: return "internaldrive"
        case .notificationPermission: return "bell"
        case .diagnostics: return "doc.text.magnifyingglass"
        case .about: return "info.circle"
        case .sourceCode: return "chevron.left.forwardslash.chevron.right"
        }
    }

    package static func explanation(_ destination: SettingsDestination) -> String? {
        switch destination {
        case .homeRows: return String(localized: "Turn Home's rows on or off and put them in the order you like.")
        case .libraries: return LibrariesSettings.homeFooterText
        case .serverConnection: return String(localized: "Which server Crucible uses, every route to it and how fast each one answers.")
        case .crucibleServer: return CompanionCopy.pitch
        case .manageStorage: return String(localized: "What is downloaded and how much space it takes.")
        case .notificationPermission: return String(localized: "Crucible can only notify you when iOS allows it.")
        case .diagnostics: return String(localized: "The app's log and what the Top Shelf extension last saw.")
        case .about: return nil
        case .sourceCode: return String(localized: "Crucible is open source under the GPL.")
        }
    }

    package static func title(_ action: SettingsAction) -> String {
        switch action {
        case .shareLogs: return String(localized: "Share Diagnostic Logs")
        case .clearImageCache: return String(localized: "Clear Image Cache")
        case .clearSearchHistory: return String(localized: "Clear Search History", comment: "Settings action that forgets recent searches")
        case .forgetFinishedTitles: return String(localized: "Forget What You Finished", comment: "Settings action that clears the Rate What You Watched history")
        }
    }

    package static func symbol(_ action: SettingsAction) -> String {
        switch action {
        case .shareLogs: return "doc.text"
        case .clearImageCache: return "photo.stack"
        case .clearSearchHistory: return "magnifyingglass"
        case .forgetFinishedTitles: return "star.slash"
        }
    }

    package static func explanation(_ action: SettingsAction) -> String? {
        switch action {
        case .shareLogs: return String(localized: "Sends the app's log to whoever you choose, to help track down a problem.")
        case .clearImageCache: return String(localized: "Frees the space posters and backdrops take on this device.")
        case .clearSearchHistory: return String(localized: "Forgets your recent searches.")
        case .forgetFinishedTitles: return String(localized: "Empties Rate What You Watched and its reminders.")
        }
    }

    static let privacyStatement = String(localized: "Crucible has no analytics, no ads and no tracking. It talks to your Plex server and to plex.tv, and keeps your history, statistics and settings on this device.", comment: "Privacy statement in Settings")

    /// Words that find a setting besides its title, comma separated so translators can add their own synonyms.
    static func keywords(for item: SettingsItem) -> String {
        switch item {
        case .preference(let setting):
            switch setting {
            case .streamingQuality, .remoteQuality, .cellularQuality:
                return String(localized: "bitrate, resolution, 4K, 1080p, original, transcode, data, mbps", comment: "Search keywords for the streaming quality settings, comma separated")
            case .autoplayNextEpisode, .upNextCountdown, .stillWatching, .postPlaySuggestions:
                return String(localized: "binge, next episode, autoplay, countdown, sleep", comment: "Search keywords for the Up Next settings, comma separated")
            case .rewindAfterBreak:
                return String(localized: "resume, pause, back", comment: "Search keywords for Rewind After a Break, comma separated")
            case .skipIntro, .skipOutro:
                return String(localized: "intro, credits, outro, opening, automatic", comment: "Search keywords for the skip intro and credits settings, comma separated")
            case .subtitleSize:
                return String(localized: "captions, CC, text, font, bigger, smaller", comment: "Search keywords for the subtitle size setting, comma separated")
            case .skipBack, .skipForward, .holdLeft, .holdRight:
                return String(localized: "remote, seek, jump, rewind, fast forward, seconds, headphones", comment: "Search keywords for the skip and remote settings, comma separated")
            case .downloadQuality, .downloadOverCellular, .deleteWatchedDownloads:
                return String(localized: "offline, storage, space, cellular, wifi, data, plane", comment: "Search keywords for the download settings, comma separated")
            case .appearance:
                return String(localized: "dark mode, light mode, theme", comment: "Search keywords for the appearance setting, comma separated")
            case .libraryGrid:
                return String(localized: "posters, grid, columns, bigger", comment: "Search keywords for the poster size setting, comma separated")
            case .notifyRatingReminders, .ratingReminderTiming:
                return String(localized: "rate, stars, reminder, push, alert", comment: "Search keywords for rating reminders, comma separated")
            case .notifyNewEpisodes, .notifyWatchlistArrivals, .notifyWeeklyRecap, .notifyYearInReview, .notifyDownloads, .quietHours:
                return String(localized: "push, alert, notify, badge, quiet, night", comment: "Search keywords for notification settings, comma separated")
            case .preferLocalConnection, .allowRelayConnection:
                return String(localized: "network, LAN, remote, relay, Tailscale, wifi", comment: "Search keywords for connection settings, comma separated")
            }
        case .destination(let destination):
            switch destination {
            case .homeRows: return String(localized: "home, rows, order, hide, continue watching, recently added", comment: "Search keywords for Home Rows, comma separated")
            case .libraries: return String(localized: "libraries, movies, shows, hide, statistics", comment: "Search keywords for Libraries, comma separated")
            case .serverConnection: return String(localized: "server, switch, address, IP, Tailscale, relay", comment: "Search keywords for Server & Connection, comma separated")
            case .crucibleServer: return String(localized: "companion, previously on, recap, pair, model, AI", comment: "Search keywords for Crucible Server, comma separated")
            case .manageStorage: return String(localized: "storage, space, delete, offline", comment: "Search keywords for Manage Storage, comma separated")
            case .notificationPermission: return String(localized: "permission, allow, notifications", comment: "Search keywords for the notification permission row, comma separated")
            case .diagnostics, .about, .sourceCode: return String(localized: "logs, version, help, support, GitHub, license", comment: "Search keywords for help and about rows, comma separated")
            }
        case .action(let action):
            switch action {
            case .shareLogs: return String(localized: "logs, support, bug, report", comment: "Search keywords for sharing logs, comma separated")
            case .clearImageCache, .clearSearchHistory, .forgetFinishedTitles: return String(localized: "clear, reset, delete, forget, cache", comment: "Search keywords for clearing data, comma separated")
            }
        case .privacyStatement:
            return String(localized: "privacy, tracking, analytics, data", comment: "Search keywords for the privacy statement, comma separated")
        }
    }
}
