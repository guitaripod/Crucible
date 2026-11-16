import CrucibleCore
@preconcurrency import UIKit

/// The show page follows the server: an episode finished, paused or marked on any device, a season marked here in another
/// window, or a new episode arriving in its library reads the page again while it is on screen, or once the viewer is done
/// picking episodes. Off screen it reads again on its next appearance, as it always does.
extension ShowDetailViewController {
    func followServerState() {
        serverState = ServerStateFollower(matching: { [weak self] change in
            self?.isTouched(by: change) ?? false
        }, isOnScreen: { [weak self] in
            self?.viewIfLoaded?.window != nil
        }, refresh: { [weak self] in
            guard let self else { return }
            guard !multiSelect.isEditing else {
                serverState?.markStale()
                return
            }
            loadData()
        })
    }

    /// Whether the viewer picked another of the show's seasons after the load read which one to show: that load would put the
    /// old season back, so the page reads again for the new one instead.
    func isSuperseded(by loaded: ShowDetailModel) -> Bool {
        guard let picked = model?.selectedSeasonKey, picked != loaded.selectedSeasonKey else { return false }
        return loaded.seasons.contains { $0.id == picked }
    }

    /// A change that arrived while episodes were being picked is read once the picking ends.
    func catchUpAfterSelecting() {
        guard serverState?.takeStale() == true, viewIfLoaded?.window != nil else { return }
        loadData()
    }

    private func isTouched(by change: ServerStateChange) -> Bool {
        guard let model else { return change.touches([showRatingKey]) }
        let keys = [model.show.id] + model.seasons.map(\.id) + model.allEpisodes.map(\.id) + model.episodes.map(\.id)
        return change.touches(keys + [showRatingKey], sectionID: model.show.librarySectionID.map(String.init))
    }
}
