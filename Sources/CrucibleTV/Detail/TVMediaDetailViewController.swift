import CrucibleCore
import MidgarCore
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
    private lazy var nextEpisodeSlot = makeTaskSlot()
    private lazy var rating = RatingSaver(
        api: env.api,
        ratingKey: ratingKey,
        changed: { [weak self] in self?.rebuild() },
        reload: { [weak self] in self?.reload() },
        failed: { [weak self] in self?.presentAlert(title: String(localized: "Couldn\u{2019}t Update"), message: String(localized: "Your rating was not saved.")) }
    )

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
            MidgarLog.error("Detail load failed ratingKey=\(ratingKey): \(error.localizedDescription)", category: .networking)
            if !hasContent { showFailure(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription) }
        }
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        play(startingAt: nil)
        return true
    }

    override func didSelect(_ item: Item) {
        switch item {
        case .related(let id):
            if let related = relatedByID[id] { push(.related(related)) }
        case .person(let id):
            if let person = person(withID: id) { TVNavigation.push(TVScreens.filmography(env, person: person), from: self) }
        default:
            break
        }
    }

    private func person(withID id: String) -> PlexRole? {
        guard let index = Int(id.dropFirst("cast.".count)), let roles = model?.castAndCrew, roles.indices.contains(index) else { return nil }
        return PersonFilmography.canOpen(roles[index]) ? roles[index] : nil
    }

    private func adopt(_ loaded: MovieDetailModel) {
        model = loaded
        rating.loaded()
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
            facts.insert(DetailFact(key: String(localized: "Genres"), value: item.genres.joined(separator: ", ")), at: 0)
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
        let primaryTitle = model.hasProgress ? String(localized: "\(model.playTitle) · \(model.progress.text)") : model.playTitle
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
                title: String(localized: "Start Over"),
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
        let current = rating.shown(served: model.userRating)
        actions.append(TVDetailAction(
            kind: .rate,
            title: UserRatingCopy.actionTitle(for: current),
            symbol: current == nil ? "star" : "star.fill",
            accessibilityLabel: UserRatingCopy.accessibilityLabel(for: current),
            handler: { [weak self] in
                guard let self else { return }
                presentRating(title: item.title, rating: current) { self.rating.save($0) }
            }
        ))
        if item.isPlaylistable {
            actions.append(TVDetailAction(
                kind: .playlist,
                title: PlaylistFormat.addToPlaylist,
                symbol: "text.badge.plus",
                handler: { [weak self] in
                    guard let self else { return }
                    TVPlaylistPicker.present(adding: [item], env: env, from: self)
                }
            ))
        }
        if let value = model.audioButtonValue(selectedId: audioID) {
            actions.append(TVDetailAction(
                kind: .audio,
                title: String(localized: "Audio: \(value)"),
                menu: audioMenu(for: model),
                accessibilityLabel: String(localized: "Audio, \(value)")
            ))
        }
        if let value = model.subtitleButtonValue(selectedId: subtitleID) {
            actions.append(TVDetailAction(
                kind: .subtitles,
                title: String(localized: "Subtitles: \(value)"),
                menu: subtitleMenu(for: model),
                accessibilityLabel: String(localized: "Subtitles, \(value)")
            ))
        }
        if let name = model.collectionNames.first {
            let sectionId = item.librarySectionID.map(String.init)
            actions.append(TVDetailAction(
                kind: .collection,
                title: String(localized: "Part of \(name)"),
                symbol: "rectangle.stack",
                accessibilityLabel: String(localized: "Part of the \(name) collection"),
                handler: { [weak self] in
                    guard let self else { return }
                    TVScreens.openCollection(named: name, sectionId: sectionId, env: env, from: self)
                }
            ))
        }
        if model.isEpisode, let route = model.showRoute {
            actions.append(TVDetailAction(kind: .goToShow, title: String(localized: "Go to Show"), symbol: "tv", handler: { [weak self] in self?.push(route) }))
        }
        if model.isEpisode, model.seasonKey != nil {
            actions.append(TVDetailAction(
                kind: .nextEpisode,
                title: String(localized: "Next Episode"),
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
        return UIMenu(title: String(localized: "Audio", comment: "Menu title for the audio track options"), options: .singleSelection, children: actions)
    }

    private func subtitleMenu(for model: MovieDetailModel) -> UIMenu {
        let off = UIAction(title: String(localized: "Off", comment: "Subtitle option that turns subtitles off"), state: subtitleID == nil ? .on : .off) { [weak self] _ in
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
        return UIMenu(title: String(localized: "Subtitles", comment: "Menu title for the subtitle options"), options: .singleSelection, children: [off] + actions)
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
        guard let seasonKey = model?.seasonKey else { return }
        nextEpisodeSlot.run { [weak self] in
            guard let self else { return }
            do {
                guard let next = try await MovieDetailLoader.nextEpisode(after: ratingKey, inSeason: seasonKey, api: env.api),
                      let route = model?.nextEpisodeRoute(next) else { return }
                push(route)
            } catch {
                MidgarLog.error("Next episode lookup failed ratingKey=\(ratingKey): \(error.localizedDescription)", category: .networking)
            }
        }
    }
}
