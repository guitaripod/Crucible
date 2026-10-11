import CrucibleCore
import UIKit

/// Movie and episode detail: backdrop hero, Play or Resume, Start Over, Mark Watched, the Audio and
/// Subtitles menus, and for episodes Go to Show and Next Episode; below, Cast & Crew, More Like This
/// and the Information panel. The screen refreshes every time it appears, so it shows the new
/// progress after playback.
@MainActor
final class TVMediaDetailViewController: TVDetailViewController {
    private let ratingKey: String
    private var model: MovieDetailModel?
    private var audioID: Int?
    private var subtitleID: Int?
    private var relatedByID: [String: PlexMetadata] = [:]
    private var nextEpisodeTask: Task<Void, Never>?

    init(env: TVAppEnvironment, ratingKey: String) {
        self.ratingKey = ratingKey
        super.init(env: env)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func fetch() async {
        do {
            guard let loaded = try await MovieDetailLoader.load(api: env.api, ratingKey: ratingKey) else {
                if !hasContent { showUnavailable(DetailMessage.itemUnavailable) }
                return
            }
            adopt(loaded)
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.error("Detail load failed ratingKey=\(ratingKey): \(error.localizedDescription)", .networking)
            if !hasContent { showFailure(title: "Couldn\u{2019}t Load", message: error.localizedDescription) }
        }
    }

    override func didSelect(_ item: Item) {
        guard case .related(let id) = item, let related = relatedByID[id] else { return }
        push(.related(related))
    }

    private func adopt(_ loaded: MovieDetailModel) {
        model = loaded
        let tracks = loaded.reconciledTracks(audioId: audioID, subtitleId: subtitleID)
        audioID = tracks.audioId
        subtitleID = tracks.subtitleId
        rebuild()
    }

    private func rebuild() {
        guard let model else { return }
        let related = model.related
        relatedByID = Dictionary(zip(TVDetailMapping.related(related).map(\.id), related), uniquingKeysWith: { first, _ in first })
        present(content(for: model, related: related))
    }

    private func content(for model: MovieDetailModel, related: [PlexMetadata]) -> TVDetailContent {
        let item = model.item
        var facts = model.facts
        if !item.genres.isEmpty {
            facts.insert(DetailFact(key: "Genres", value: item.genres.joined(separator: ", ")), at: 0)
        }
        return TVDetailContent(
            artwork: model.heroArtwork,
            header: TVDetailMapping.heroInfo(model.heroInfo, progress: model.hasProgress ? model.progress.fraction : nil),
            synopsis: model.hasSummary ? item.summary : nil,
            synopsisTitle: item.title,
            actions: actions(for: model),
            cast: TVDetailMapping.people(model.castAndCrew),
            related: TVDetailMapping.related(related),
            facts: facts
        )
    }

    private func actions(for model: MovieDetailModel) -> [TVDetailAction] {
        let item = model.item
        let primaryTitle = model.hasProgress ? "\(model.playTitle) · \(model.progress.text)" : model.playTitle
        var actions = [
            TVDetailAction(
                kind: .primary,
                title: primaryTitle,
                symbol: "play.fill",
                appearance: .primary,
                accessibilityLabel: model.playAccessibilityLabel,
                handler: { [weak self] in self?.play(startingAt: nil) }
            ),
        ]
        if model.hasResumePosition {
            actions.append(TVDetailAction(
                kind: .startOver,
                title: "Start Over",
                symbol: "arrow.counterclockwise",
                handler: { [weak self] in self?.play(startingAt: 0) }
            ))
        }
        actions.append(TVDetailAction(
            kind: .watched,
            title: model.watchedToggleTitle,
            symbol: item.isWatched ? "eye.slash" : "checkmark.circle",
            handler: { [weak self] in self?.markWatched(!item.isWatched, ratingKey: item.id) }
        ))
        if let value = model.audioButtonValue(selectedId: audioID) {
            actions.append(TVDetailAction(
                kind: .audio,
                title: "Audio: \(value)",
                menu: audioMenu(for: model),
                accessibilityLabel: "Audio, \(value)"
            ))
        }
        if let value = model.subtitleButtonValue(selectedId: subtitleID) {
            actions.append(TVDetailAction(
                kind: .subtitles,
                title: "Subtitles: \(value)",
                menu: subtitleMenu(for: model),
                accessibilityLabel: "Subtitles, \(value)"
            ))
        }
        if model.isEpisode, let route = model.showRoute {
            actions.append(TVDetailAction(kind: .goToShow, title: "Go to Show", symbol: "tv", handler: { [weak self] in self?.push(route) }))
        }
        if model.isEpisode, model.seasonKey != nil {
            actions.append(TVDetailAction(
                kind: .nextEpisode,
                title: "Next Episode",
                symbol: "forward.end.fill",
                handler: { [weak self] in self?.goToNextEpisode() }
            ))
        }
        return actions
    }

    private func audioMenu(for model: MovieDetailModel) -> UIMenu {
        let actions = model.audioOptions(selectedId: audioID).map { option in
            let action = UIAction(title: option.title, state: option.isSelected ? .on : .off) { [weak self] _ in
                self?.audioID = option.id
                self?.rebuild()
            }
            action.subtitle = option.detail
            return action
        }
        return UIMenu(title: "Audio", options: .singleSelection, children: actions)
    }

    private func subtitleMenu(for model: MovieDetailModel) -> UIMenu {
        let off = UIAction(title: "Off", state: subtitleID == nil ? .on : .off) { [weak self] _ in
            self?.subtitleID = nil
            self?.rebuild()
        }
        let actions = model.subtitleOptions(selectedId: subtitleID).map { option in
            let action = UIAction(
                title: option.title,
                attributes: option.isEnabled ? [] : .disabled,
                state: option.isSelected ? .on : .off
            ) { [weak self] _ in
                guard option.isEnabled else { return }
                self?.subtitleID = option.id
                self?.rebuild()
            }
            action.subtitle = option.detail
            return action
        }
        return UIMenu(title: "Subtitles", options: .singleSelection, children: [off] + actions)
    }

    private func play(startingAt position: Double?) {
        guard let model else { return }
        let resume = position ?? model.resumePosition(offlineResumeSecs: nil)
        play(TVPlaybackRequest(
            item: model.item,
            resumeSeconds: resume,
            selectedAudioStreamID: audioID,
            selectedSubtitleStreamID: subtitleID
        ))
    }

    private func goToNextEpisode() {
        guard nextEpisodeTask == nil, let seasonKey = model?.seasonKey else { return }
        nextEpisodeTask = Task { [weak self] in
            defer { self?.nextEpisodeTask = nil }
            guard let self else { return }
            do {
                guard let next = try await MovieDetailLoader.nextEpisode(after: ratingKey, inSeason: seasonKey, api: env.api),
                      let route = model?.nextEpisodeRoute(next) else { return }
                push(route)
            } catch {
                AppLogger.error("Next episode lookup failed ratingKey=\(ratingKey): \(error.localizedDescription)", .networking)
            }
        }
    }
}
