import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// The show page's downloads and its work on several episodes at once: the season's download ring and menu, the swipe
/// actions of an episode row and the toolbar of a multiple selection.
extension ShowDetailViewController {
    func seasonDownloadState(_ model: ShowDetailModel) -> DownloadRingButton.State {
        let manager = DownloadManager.shared
        let episodes = model.episodes
        let items = episodes.compactMap { manager.item(for: $0.id) }
        guard !episodes.isEmpty, !items.isEmpty else { return .idle }
        if items.count == episodes.count, items.allSatisfy({ $0.state == .completed }) { return .completed }
        let tracked = items.filter { $0.state != .failed }
        let done = tracked.reduce(0.0) { $0 + ($1.state == .completed ? 1 : $1.progress) }
        let fraction = tracked.isEmpty ? 0 : done / Double(tracked.count)
        if items.contains(where: { $0.state.isActive }) {
            return fraction > 0 ? .progress(fraction) : .queued
        }
        if items.contains(where: { $0.state == .failed }) { return .failed }
        if items.contains(where: { $0.state == .paused }) { return .paused(fraction) }
        return .idle
    }

    func downloadAccessibilityLabel(_ model: ShowDetailModel) -> String {
        let manager = DownloadManager.shared
        let completed = model.episodes.filter { manager.state(for: $0.id) == .completed }.count
        guard completed > 0 else { return String(localized: "Download options") }
        return String(localized: "Download options, \(completed) of \(model.episodes.count) episodes downloaded")
    }

    func downloadMenu(_ model: ShowDetailModel) -> UIMenu {
        let manager = DownloadManager.shared
        let episodes = model.episodes
        let seasonName = model.selectedSeasonTitle
        let pool = model.allEpisodes.isEmpty ? episodes : model.allEpisodes
        var downloads: [UIMenuElement] = []

        let seasonRemaining = episodes.filter { manager.item(for: $0.id) == nil }
        if !seasonRemaining.isEmpty {
            let action = UIAction(title: String(localized: "Download Season"), image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                self?.enqueue(seasonRemaining, reason: "season")
            }
            action.subtitle = String(localized: "\(seasonName) · \(Self.episodeCount(seasonRemaining.count))")
            downloads.append(action)
        }

        let unwatched = pool.filter { !$0.isWatched && manager.item(for: $0.id) == nil }
        if !unwatched.isEmpty {
            let action = UIAction(title: String(localized: "Download Unwatched"), image: UIImage(systemName: "eye")) { [weak self] _ in
                self?.enqueue(unwatched, reason: "unwatched")
            }
            action.subtitle = Self.episodeCount(unwatched.count)
            downloads.append(action)
        }

        if let upNext = model.upNext, let start = pool.firstIndex(where: { $0.id == upNext.episode.id }) {
            let next = Array(pool[start...].prefix(5)).filter { manager.item(for: $0.id) == nil }
            if !next.isEmpty {
                let action = UIAction(title: String(localized: "Download Next 5"), image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
                    self?.enqueue(next, reason: "next5")
                }
                action.subtitle = DetailFormat.episodeCode(season: upNext.episode.parentIndex, episode: upNext.episode.index)
                    .map { String(localized: "From \($0)") }
                downloads.append(action)
            }
        }

        downloads.append(UIAction(title: String(localized: "Options\u{2026}"), image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
            self?.presentDownloadOptions()
        })

        var manage: [UIMenuElement] = []
        let seasonItems = episodes.compactMap { manager.item(for: $0.id) }
        let activeKeys = seasonItems.filter { $0.state.isActive }.map(\.ratingKey)
        if !activeKeys.isEmpty {
            manage.append(UIAction(title: String(localized: "Pause Season Downloads"), image: UIImage(systemName: "pause.fill")) { _ in
                activeKeys.forEach { manager.pause($0) }
            })
        }
        let resumable = episodes.filter { manager.state(for: $0.id) == .failed || manager.state(for: $0.id) == .paused }
        if !resumable.isEmpty {
            manage.append(UIAction(title: String(localized: "Resume Season Downloads"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.enqueue(resumable, reason: "resume")
            })
        }
        if !seasonItems.isEmpty {
            let title = activeKeys.isEmpty ? String(localized: "Remove Season Downloads") : String(localized: "Cancel Season Downloads")
            manage.append(UIAction(title: title, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.removeSeasonDownloads()
            })
        }

        var children: [UIMenuElement] = [UIMenu(title: "", options: .displayInline, children: downloads)]
        if !manage.isEmpty { children.append(UIMenu(title: "", options: .displayInline, children: manage)) }
        return UIMenu(title: "", children: children)
    }

    private static func episodeCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 episode") : String(localized: "\(count) episodes")
    }

    func enqueue(_ items: [PlexMetadata], reason: String) {
        Haptics.medium()
        DownloadManager.shared.requestDownloads(items) { added in
            guard let added else { return }
            MidgarLog.notice("Show download (\(reason)) queued \(added) episodes", category: .persistence)
        }
    }

    func removeSeasonDownloads() {
        let keys = (model?.episodes ?? []).map(\.id).filter { DownloadManager.shared.item(for: $0) != nil }
        guard !keys.isEmpty else { return }
        Haptics.medium()
        DownloadManager.shared.deleteItems(keys)
    }

    func presentDownloadOptions() {
        guard let model else { return }
        let context = DownloadOptionsSheetViewController.Context(
            showRatingKey: showRatingKey,
            showTitle: model.show.title,
            seasonTitle: model.selectedSeason.map(ShowDetailModel.seasonTitle) ?? "",
            posterPath: model.show.thumb,
            episodes: model.episodes
        )
        let sheet = DownloadOptionsSheetViewController(context: context) { [weak self] in
            guard let presented = self?.presentedViewController as? DownloadOptionsSheetViewController else { return }
            presented.dismiss(animated: true)
        }
        sheet.modalPresentationStyle = .formSheet
        if let controller = sheet.sheetPresentationController {
            controller.detents = [.medium(), .large()]
            controller.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    #if os(iOS)
    func leadingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !collectionView.isEditing, let episode = episode(at: indexPath) else { return nil }
        let markWatched = !episode.isWatched
        let action = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
            self?.setWatched(markWatched, ratingKey: episode.id)
            completion(true)
        }
        action.backgroundColor = Theme.Color.accent
        action.image = SwipeActionArt.image(
            symbol: markWatched ? "eye" : "eye.slash",
            title: markWatched ? String(localized: "Watched") : String(localized: "Unwatched"),
            spokenTitle: WatchedService.title(isWatched: !markWatched),
            color: Theme.Color.onAccent,
            traits: traitCollection
        )
        return UISwipeActionsConfiguration(actions: [action])
    }

    func trailingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !collectionView.isEditing, let episode = episode(at: indexPath) else { return nil }
        let key = episode.id
        let manager = DownloadManager.shared
        let traits = traitCollection
        let sourceView = collectionView.cellForItem(at: indexPath)

        func graphite(_ symbol: String, _ title: String, _ spoken: String, handler: @escaping () -> Void) -> UIContextualAction {
            let action = UIContextualAction(style: .normal, title: nil) { _, _, completion in
                Haptics.medium()
                handler()
                completion(true)
            }
            action.backgroundColor = Theme.Color.surfaceHigh
            action.image = SwipeActionArt.image(symbol: symbol, title: title, spokenTitle: spoken, color: Theme.Color.label, traits: traits)
            return action
        }

        func destructive(_ title: String, _ spoken: String, handler: @escaping () -> Void) -> UIContextualAction {
            let action = UIContextualAction(style: .normal, title: nil) { _, _, completion in
                handler()
                completion(true)
            }
            action.backgroundColor = Theme.Color.destructive
            action.image = SwipeActionArt.image(symbol: "trash", title: title, spokenTitle: spoken, color: Theme.Color.onArt, traits: traits)
            return action
        }

        let configuration: UISwipeActionsConfiguration
        switch manager.item(for: key)?.state {
        case nil:
            configuration = UISwipeActionsConfiguration(actions: [
                graphite("arrow.down", String(localized: "Download"), String(localized: "Download")) { manager.requestDownload(metadata: episode) },
            ])
        case .completed?:
            configuration = UISwipeActionsConfiguration(actions: [
                destructive(String(localized: "Remove"), String(localized: "Remove Download")) { [weak self] in
                    guard let self else { return }
                    DetailDownload.confirmRemoval(title: episode.title, ratingKey: key, from: self, sourceView: sourceView)
                },
            ])
        case .queued?, .waitingForWiFi?, .downloading?:
            configuration = UISwipeActionsConfiguration(actions: [
                destructive(String(localized: "Cancel"), String(localized: "Cancel Download")) { Haptics.medium(); manager.delete(key) },
                graphite("pause.fill", String(localized: "Pause"), String(localized: "Pause Download")) { manager.pause(key) },
            ])
            configuration.performsFirstActionWithFullSwipe = false
        case .paused?:
            configuration = UISwipeActionsConfiguration(actions: [
                destructive(String(localized: "Delete"), String(localized: "Delete Download")) { Haptics.medium(); manager.delete(key) },
                graphite("arrow.down", String(localized: "Resume"), String(localized: "Resume Download")) { manager.requestResume(key) },
            ])
            configuration.performsFirstActionWithFullSwipe = false
        case .failed?:
            configuration = UISwipeActionsConfiguration(actions: [
                destructive(String(localized: "Delete"), String(localized: "Delete Download")) { Haptics.medium(); manager.delete(key) },
                graphite("arrow.clockwise", String(localized: "Retry"), String(localized: "Retry Download")) { manager.requestResume(key) },
            ])
            configuration.performsFirstActionWithFullSwipe = false
        }
        return configuration
    }
    #endif

    func selectionToolbarItems(count: Int) -> [UIBarButtonItem] {
        let selectAll = UIBarButtonItem(primaryAction: UIAction(title: String(localized: "Select All")) { [weak self] _ in
            self?.selectAllEpisodes()
        })

        let downloadItem = UIBarButtonItem(title: count > 0 ? String(localized: "Download \(count)") : String(localized: "Download"), menu: selectedDownloadMenu())
        downloadItem.isEnabled = count > 0

        let removeAction = UIAction(title: count > 0 ? String(localized: "Remove \(count)") : String(localized: "Remove")) { [weak self] _ in
            self?.removeSelectedEpisodes()
        }
        let removeItem = UIBarButtonItem(primaryAction: removeAction)
        removeItem.tintColor = Theme.Color.destructive
        removeItem.isEnabled = count > 0 && selectionHasDownloads()

        return [selectAll, .flexibleSpace(), downloadItem, .flexibleSpace(), removeItem]
    }

    func selectedDownloadMenu() -> UIMenu {
        let current = Preferences.downloadQuality
        let actions = DownloadQuality.allCases.map { quality in
            UIAction(title: String(localized: "\(quality.title) · \(quality.detail)"), state: quality == current ? .on : .off) { [weak self] _ in
                self?.downloadSelectedEpisodes(quality: quality)
            }
        }
        return UIMenu(title: String(localized: "Download Quality"), children: actions)
    }

    func selectedEpisodes() -> [PlexMetadata] {
        (collectionView.indexPathsForSelectedItems ?? []).compactMap {
            if case .episode(let episode) = dataSource.itemIdentifier(for: $0) { return episode }
            return nil
        }
    }

    func selectionHasDownloads() -> Bool {
        selectedEpisodes().contains { DownloadManager.shared.item(for: $0.id) != nil }
    }

    func selectAllEpisodes() {
        let paths = (model?.episodes ?? []).compactMap { dataSource.indexPath(for: .episode($0)) }
        multiSelect.selectAll(paths)
    }

    func downloadSelectedEpisodes(quality: DownloadQuality) {
        let eps = selectedEpisodes()
        guard !eps.isEmpty else { return }
        Haptics.medium()
        DownloadManager.shared.requestDownloads(eps, quality: quality) { [weak self] added in
            guard let added else { return }
            MidgarLog.notice("Batch download queued \(added) episodes", category: .persistence)
            self?.multiSelect.setEditing(false)
        }
    }

    func removeSelectedEpisodes() {
        let keys = selectedEpisodes().map(\.id).filter { DownloadManager.shared.item(for: $0) != nil }
        guard !keys.isEmpty else { return }
        DownloadManager.shared.deleteItems(keys)
        multiSelect.setEditing(false)
    }
}
