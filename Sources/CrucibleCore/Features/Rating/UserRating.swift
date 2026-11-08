import Foundation
import MidgarCore

/// A viewer's own rating of a title: half-star steps from one half to five stars, which Plex keeps on a ten point scale
/// where one half star is one point.
package struct UserRating: Hashable, Sendable {
    package static let maxStars = 5
    package static let maxHalfStars = maxStars * 2

    /// The value `/:/rate` takes to remove a rating.
    package static let clearValue = -1

    package let halfStars: Int

    package init?(halfStars: Int) {
        guard (1...Self.maxHalfStars).contains(halfStars) else { return nil }
        self.halfStars = halfStars
    }

    /// What the server reports in `userRating`; nothing, zero or less is an unrated title.
    package init?(plexValue: Double?) {
        guard let plexValue, plexValue.isFinite, plexValue > 0 else { return nil }
        self.halfStars = min(Self.maxHalfStars, max(1, Int(plexValue.rounded())))
    }

    /// The step under a finger or a pointer `fraction` of the way along the row of stars, so the left half of a star is
    /// its half step and the right half its whole one. The very start of the row is no rating.
    package init?(fraction: Double) {
        guard fraction.isFinite else { return nil }
        let clamped = min(1, max(0, fraction))
        self.init(halfStars: Int((clamped * Double(Self.maxHalfStars)).rounded(.up)))
    }

    package var stars: Double { Double(halfStars) / 2 }

    package var plexValue: Int { halfStars }

    package var fullStars: Int { halfStars / 2 }

    package var hasHalfStar: Bool { halfStars % 2 == 1 }

    /// The step one half star up or down, held inside the scale; stepping down from the lowest step is no rating.
    package func stepped(by halfSteps: Int) -> UserRating? {
        let next = halfStars + halfSteps
        return UserRating(halfStars: min(Self.maxHalfStars, next))
    }

    package var text: String {
        String(format: hasHalfStar ? "%.1f" : "%.0f", locale: Formatters.interfaceLocale, stars)
    }

    package var spokenText: String {
        String(localized: "\(text) out of \(Self.maxStars) stars", comment: "Spoken form of the viewer's own star rating, e.g. 4.5 out of 5 stars")
    }
}

/// Copy for the rating control and the Details row.
package enum UserRatingCopy {
    package static let title = String(localized: "Your Rating", comment: "Title of the control and the Details row for the viewer's own star rating")
    package static let rate = String(localized: "Rate", comment: "Button label that opens the star rating control")
    package static let clear = String(localized: "Clear Rating", comment: "Button that removes the viewer's star rating")

    package static func accessibilityLabel(for rating: UserRating?) -> String {
        guard let rating else { return rate }
        return String(localized: "Your rating, \(rating.spokenText)", comment: "Accessibility label of the rating button when the viewer has rated the title")
    }

    /// The label of the rating button where the button names its state instead of showing stars: Rate, or Your Rating: 4.5.
    package static func actionTitle(for rating: UserRating?) -> String {
        guard let rating else { return rate }
        return String(localized: "Your Rating: \(rating.text)", comment: "Rating button label on a detail screen when the viewer has rated the title, e.g. Your Rating: 4.5")
    }

    package static let tvHint = String(localized: "Swipe left or right to choose, press to rate", comment: "Hint under the star rating control on Apple TV")

    package static func detail(for rating: UserRating) -> String {
        String(localized: "\(rating.text) of \(UserRating.maxStars)", comment: "Details row value for the viewer's own star rating, e.g. 4.5 of 5")
    }
}

/// Sets or removes the viewer's rating of a movie, episode, season or show.
package enum RatingService {
    /// Rates `ratingKey`, or removes its rating for nil, then drops the cached metadata of that title so the next load
    /// shows it. Failures are logged and rethrown.
    package static func setRating(_ rating: UserRating?, ratingKey: String, api: APIClient) async throws {
        do {
            try await api.requestConfirmed(.rate(ratingKey: ratingKey, rating: rating?.plexValue ?? UserRating.clearValue))
            await api.invalidate(ratingKey: ratingKey)
            await MainActor.run {
                FinishedTitlesLedger.shared.noteRated(ratingKey, isRated: rating != nil)
                Integrations.ratingChanged(ratingKey, rating: rating, api: api)
            }
        } catch {
            MidgarLog.error("Rate ratingKey=\(ratingKey) failed: \(error.localizedDescription)", category: .networking)
            throw error
        }
    }
}
