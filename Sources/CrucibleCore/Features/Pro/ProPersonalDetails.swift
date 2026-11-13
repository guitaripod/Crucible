import Foundation

/// The Pro sheet told with the viewer's own numbers where the app has enough of them: the plays in their mirrored history, this
/// year's movies, episodes and hours, the titles downloaded to the iPhone and the titles in progress on the Apple TV. Every figure
/// is a count the app already keeps on the device; a benefit without enough behind it keeps its general line, and nothing here
/// names a title.
package enum ProPersonalDetails {
    /// Plays in the whole history before Full Statistics speaks of them: fewer leave patterns, binges and taste thin. The history
    /// must also reach back before this year, or "since" names the year the viewer is in and every range holds the same plays.
    package static let historyPlays = 50
    /// Plays this year before the poster line speaks of the year: fewer make a sparse poster.
    package static let yearPlays = 10
    /// Hours this year before the sheet opens with them.
    package static let yearHours = 10
    /// Downloads on the iPhone before the downloads line counts them: a free install holds one at a time, so two means the viewer
    /// came back for more.
    package static let downloadedTitles = 2
    /// Titles in progress on the Apple TV before Top Shelf counts them: one card is not a shelf.
    package static let titlesInProgress = 2

    /// The personal line of each benefit that has enough behind it; a benefit missing here keeps `ProFeature.summary`.
    package static func make(_ facts: ProViewerFacts, now: Date = Date(), calendar: Calendar = .current) -> [ProFeature: String] {
        var details: [ProFeature: String] = [:]
        if facts.downloadedTitles >= downloadedTitles {
            details[.unlimitedDownloads] = String(
                localized: "\(facts.downloadedTitles) titles are on this iPhone. Download whole seasons, queue as many as you like and keep the next episodes ready.",
                comment: "Pro feature summary for Unlimited downloads, starting with how many titles the viewer has downloaded"
            )
        }
        if facts.titlesInProgress >= titlesInProgress {
            details[.topShelf] = String(
                localized: "\(facts.titlesInProgress) titles in progress on this Apple TV. Top Shelf puts Continue Watching and Up Next on the Home screen.",
                comment: "Pro feature summary for Top Shelf, starting with how many titles the viewer stopped partway through"
            )
        }
        guard let history = facts.history else { return details }
        if let plays = history.playsAllTime, plays >= historyPlays, let firstYear = history.firstYear, firstYear < history.year {
            details[.fullStatistics] = String(
                localized: "Every range, the library filter, patterns, binges and taste across your \(plays) plays since \(String(firstYear)).",
                comment: "Pro feature summary for Full Statistics: the viewer's own play count, then the year of their oldest play"
            )
        }
        if isCurrent(history, now: now, calendar: calendar), history.playsThisYear >= yearPlays, let watched = watched(history) {
            details[.yearInReviewPoster] = String(
                localized: "Your \(String(history.year)) so far: \(watched). Preview and share it as a Story or Square poster.",
                comment: "Pro feature summary for the Year in Review poster: the year, then what the viewer watched in it, such as '14 movies · 212 episodes'"
            )
        }
        return details
    }

    /// The line the sheet opens with when nothing else explains why it opened: the viewer's hours this year.
    package static func headline(_ facts: ProViewerFacts, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let history = facts.history, isCurrent(history, now: now, calendar: calendar),
              let hours = history.hoursThisYear, hours >= yearHours else { return nil }
        return String(
            localized: "\(hours) hours watched in \(String(history.year)) so far",
            comment: "Subtitle of the Crucible Pro sheet: the viewer's own hours, then the current year"
        )
    }

    /// Whether the yearly counts still describe this year: a history read in December says nothing about January.
    private static func isCurrent(_ history: ProViewerFacts.History, now: Date, calendar: Calendar) -> Bool {
        history.year == calendar.component(.year, from: now)
    }

    /// "14 movies · 212 episodes", in the words the Year in Review card uses; nil when the year holds neither.
    private static func watched(_ history: ProViewerFacts.History) -> String? {
        var parts = [String]()
        if history.moviesThisYear > 0 {
            parts.append(history.moviesThisYear == 1 ? String(localized: "1 movie") : String(localized: "\(history.moviesThisYear) movies"))
        }
        if history.episodesThisYear > 0 {
            parts.append(history.episodesThisYear == 1 ? String(localized: "1 episode") : String(localized: "\(history.episodesThisYear) episodes"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension ProFeature {
    /// What the row says under the feature's name: the viewer's own line when there is one, the general summary otherwise.
    package func summary(in details: [ProFeature: String]) -> String {
        details[self] ?? summary
    }
}
