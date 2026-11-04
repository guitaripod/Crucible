import Foundation
import MidgarCore

/// Saves the viewer's rating of one title for a detail screen: the screen shows the viewer's choice at once, the save runs behind
/// it one request at a time, and a refused save takes the choice back.
@MainActor
package final class RatingSaver {
    private struct Choice {
        let rating: UserRating?
    }

    private let api: APIClient
    private let ratingKey: String
    private let changed: () -> Void
    private let reload: () -> Void
    private let failed: () -> Void
    private var choice: Choice?
    private var saving: Task<Void, Never>?

    /// `changed` redraws the rating control from `shown(served:)`, `reload` fetches the title again once the server has saved a rating
    /// and `failed` tells the viewer a save was refused.
    package init(
        api: APIClient,
        ratingKey: String,
        changed: @escaping () -> Void,
        reload: @escaping () -> Void,
        failed: @escaping () -> Void
    ) {
        self.api = api
        self.ratingKey = ratingKey
        self.changed = changed
        self.reload = reload
        self.failed = failed
    }

    deinit { saving?.cancel() }

    /// The rating to show: the viewer's latest choice while the server has not confirmed it, otherwise the server's.
    package func shown(served: UserRating?) -> UserRating? {
        choice.map(\.rating) ?? served
    }

    /// A fresh load carries what the server now holds, so the viewer's choice has done its job.
    package func loaded() {
        choice = nil
    }

    package func save(_ rating: UserRating?) {
        choice = Choice(rating: rating)
        changed()
        let previous = saving
        saving = Task { [weak self, api, ratingKey] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await RatingService.setRating(rating, ratingKey: ratingKey, api: api)
                self?.reload()
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Rating ratingKey=\(ratingKey) not saved: \(error.localizedDescription)", category: .networking)
                self?.choice = nil
                self?.failed()
                self?.changed()
            }
        }
    }
}
