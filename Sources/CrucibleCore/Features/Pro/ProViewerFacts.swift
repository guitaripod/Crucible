import Foundation

/// What the Pro sheet may say about the viewer: counts the app already keeps on the device, never a title or a poster.
package struct ProViewerFacts: Equatable, Sendable {
    /// The viewer's mirrored watch history, counted the way Statistics counts the Plex source.
    package struct History: Equatable, Sendable {
        /// The calendar year the yearly counts belong to.
        package var year: Int
        package var playsThisYear: Int
        package var moviesThisYear: Int
        package var episodesThisYear: Int
        /// Whole hours watched this year; nil while too few runtimes are known to estimate them.
        package var hoursThisYear: Int?
        /// Every play on record; nil until the whole history is on the device.
        package var playsAllTime: Int?
        /// The year of the oldest play, known together with `playsAllTime`.
        package var firstYear: Int?

        package init(
            year: Int,
            playsThisYear: Int = 0,
            moviesThisYear: Int = 0,
            episodesThisYear: Int = 0,
            hoursThisYear: Int? = nil,
            playsAllTime: Int? = nil,
            firstYear: Int? = nil
        ) {
            self.year = year
            self.playsThisYear = playsThisYear
            self.moviesThisYear = moviesThisYear
            self.episodesThisYear = episodesThisYear
            self.hoursThisYear = hoursThisYear
            self.playsAllTime = playsAllTime
            self.firstYear = firstYear
        }
    }

    package var history: History?
    /// Titles downloaded to this iPhone.
    package var downloadedTitles: Int
    /// Titles the viewer stopped partway through on this Apple TV in the last week.
    package var titlesInProgress: Int

    package init(history: History? = nil, downloadedTitles: Int = 0, titlesInProgress: Int = 0) {
        self.history = history
        self.downloadedTitles = downloadedTitles
        self.titlesInProgress = titlesInProgress
    }
}

#if DEBUG
extension ProViewerFacts {
    /// `CRUCIBLE_PRO_FACTS=none` says nothing is known about the viewer, and `CRUCIBLE_PRO_FACTS=staged` stages a year, a whole
    /// history, downloads and titles in progress, so a screenshot or a UI test reads the same lines whatever the mirror holds.
    /// Nil without the variable, where the device's own counts are used.
    package static func staged(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ProViewerFacts? {
        switch environment["CRUCIBLE_PRO_FACTS"] {
        case "none":
            return ProViewerFacts()
        case "staged":
            let history = History(
                year: calendar.component(.year, from: now), playsThisYear: 226, moviesThisYear: 14, episodesThisYear: 212,
                hoursThisYear: 187, playsAllTime: 1_284, firstYear: 2019
            )
            return ProViewerFacts(history: history, downloadedTitles: 6, titlesInProgress: 4)
        default:
            return nil
        }
    }
}
#endif
