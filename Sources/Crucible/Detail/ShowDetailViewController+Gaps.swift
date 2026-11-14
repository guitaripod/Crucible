import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The show page's gaps: what has aired that the server lacks, as Plex's catalogue lists it, shown dimmed among the seasons
/// and episodes, and asked of Seerr with a tap.
extension ShowDetailViewController {
    /// A row for an episode that has aired but is not on the server: dimmed, with nothing to download or play.
    func missingConfiguration(_ missing: MissingEpisode) -> EpisodeContentConfiguration {
        let shielded = SpoilerShield.isOn(showRatingKey)
        var config = EpisodeContentConfiguration(status: EpisodeStatus(missing: missing, shielded: shielded))
        config.summary = shielded ? nil : missing.summary
        config.thumbPath = shielded ? nil : missing.thumb
        config.showsDownloadControl = false
        if SeerrAccount.shared.isConnected {
            config.accessibilityActions = [UIAccessibilityCustomAction(name: SeerrCopy.request) { [weak self] _ in
                self?.requestMissing()
                return true
            }]
        }
        return config
    }

    /// Asks Seerr for what the server lacks of the show, or says how to connect Seerr when it is not.
    func requestMissing() {
        guard let show = model?.show else { return }
        Haptics.selection()
        SeerrRequestViewController.present(for: show, api: api, isOnServer: true, from: self)
    }

    /// A reload keeps what the catalogue said, and a season the server lacks stays open, until the next look answers; once the
    /// server has that season, the screen moves to it (`follow`).
    static func keepingGaps(of previous: ShowDetailModel?, in loaded: ShowDetailModel) -> (model: ShowDetailModel, follow: String?) {
        guard let previous, !previous.gaps.isEmpty else { return (loaded, nil) }
        let kept = loaded.replacingGaps(previous.gaps)
        guard let open = previous.selectedMissingSeason else { return (kept, nil) }
        if let arrived = loaded.seasons.first(where: { $0.index == open.index }) {
            return arrived.id == loaded.selectedSeasonKey ? (kept, nil) : (kept.selectingSeason(arrived.id).replacingEpisodes([]), arrived.id)
        }
        return (kept.selectingSeason(open.id).replacingEpisodes([]), nil)
    }

    /// Asks Plex's catalogue what has aired that the server lacks, once every episode on the server is known.
    func loadGaps() {
        guard let model, !model.allEpisodes.isEmpty || model.seasons.isEmpty else { return }
        gapsTask?.cancel()
        let show = model.show, episodes = model.allEpisodes, check = ShowGapsCheck.live(api: api)
        gapsTask = Task { [weak self] in
            guard let gaps = await ShowGapsCenter.shared.gaps(show: show, serverEpisodes: episodes, check: check),
                  !Task.isCancelled, let self, let current = self.model else { return }
            self.adoptGaps(gaps.keepingOpened(from: current.gaps), in: current)
        }
    }

    /// Puts a look's answer on screen: opens the missing season the screen was opened on, once and only while the viewer has
    /// not picked a season; leaves a missing season that is no longer missing; and lists an open missing season whose episodes
    /// the answer does not carry yet.
    func adoptGaps(_ gaps: ShowGaps, in current: ShowDetailModel) {
        let updated = current.replacingGaps(gaps)
        let initial = openedInitialMissingSeason ? nil : gaps.season(id: initialSeasonKey)
        openedInitialMissingSeason = true
        if let initial, !viewerPickedSeason, !updated.seasons.contains(where: { $0.index == initial.index }) {
            model = updated.selectingSeason(initial.id)
            reconfigure([.seasonBar])
            openMissingSeason(initial, key: initial.id)
            return
        }
        if updated.leftMissingSeason {
            guard let target = updated.arrivedSeason ?? updated.seasons.first else { return }
            model = updated.selectingSeason(target.id).replacingEpisodes([])
            reconfigure([.seasonBar])
            selectSeasonAfterGaps(target.id)
            return
        }
        if updated.needsMissingEpisodes, let missing = updated.selectedMissingSeason {
            model = updated
            openMissingSeason(missing, key: missing.id)
            return
        }
        guard updated.gaps != current.gaps else { return }
        model = updated
        Task { await applySnapshot() }
    }

    func selectSeasonAfterGaps(_ key: String) {
        seasonTask?.cancel()
        seasonTask = Task { [weak self] in
            guard let self else { return }
            guard let episodes = await ShowDetailLoader.episodes(inSeason: key, api: api), model?.selectedSeasonKey == key else { return }
            model = model?.replacingEpisodes(episodes)
            await applySnapshot()
        }
    }

    /// Lists the aired episodes of a season the server has none of, asking the catalogue for them the first time.
    func openMissingSeason(_ missing: MissingSeason, key: String) {
        guard let current = model else { return }
        seasonTask?.cancel()
        model = current.replacingEpisodes([])
        let show = current.show, gaps = current.gaps, check = ShowGapsCheck.live(api: api)
        seasonTask = Task { [weak self] in
            guard let self else { return }
            await applySnapshot()
            guard let filled = await ShowGapsCenter.shared.opening(missing, of: show, in: gaps, check: check),
                  !Task.isCancelled, model?.selectedSeasonKey == key else { return }
            model = model?.replacingGaps(filled)
            await applySnapshot()
        }
    }
}
