import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// A show's Previously On (`TVShowDetailViewController.showPreviouslyOn`): the paired Crucible Server's recap, or without
/// one the last finished episodes' descriptions, read as they are or written into one recap on the person's own model
/// after saying what that sends (D1).
@MainActor
enum PreviouslyOnPresenter {
    static func present(_ model: ShowDetailModel, from screen: ScreenView) {
        guard let window = screen.window else { return }
        let title = CompanionCopy.previouslyOnTitle(model.show.title)
        guard PreviouslyOnRequest.offer(model) == .descriptions else {
            wait(title: title, message: CompanionCopy.writing, from: screen) { await serverRecap(model) }
            return
        }
        let show = model.show.title
        let episodes = DescribedRecap.episodes(of: model)
        guard DescribedRecap.canWrite(show: show, episodes: episodes) else {
            read(title: title, markup: descriptions(episodes), from: screen)
            return
        }
        AlertView(title: title, message: sends, actions: [
            AlertView.Action(DescribedRecapCopy.write) { [weak screen] in
                guard let screen else { return }
                wait(title: title, message: DescribedRecapCopy.writing, from: screen) { await writtenRecap(show: show, episodes: episodes) }
            },
            AlertView.Action(DescribedRecapCopy.readDescriptions) { [weak screen] in
                guard let screen else { return }
                read(title: title, markup: descriptions(episodes), from: screen)
            },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ]).present(in: window)
    }

    /// What writing a recap sends: to the person's own model, or in the demo nothing.
    private static var sends: String {
        HostedBrain.takesAnyRequest ? OwnModelCopy.recapSends : DescribedRecapCopy.sends
    }

    /// Says the recap is being written until `recap` returns its markup, then opens it; Cancel stops the request.
    private static func wait(title: String, message: String, from screen: ScreenView, recap: @escaping @MainActor () async -> String) {
        guard let window = screen.window else { return }
        let task = Task { @MainActor [weak screen] () -> String? in
            let text = await recap()
            return Task.isCancelled || screen == nil ? nil : text
        }
        let waiting = AlertView(title: title, message: message, actions: [AlertView.Action(String(localized: "Cancel"), role: .cancel) { task.cancel() }])
        waiting.present(in: window)
        Task { @MainActor [weak screen, weak waiting] in
            guard let markup = await task.value, let screen, let waiting, waiting.superview != nil else { return }
            waiting.dismiss()
            read(title: title, markup: markup, from: screen)
        }
    }

    private static func read(title: String, markup: String, from screen: ScreenView) {
        screen.rootView?.push(ReaderScreen(title: title, markup: markup))
    }

    private static func plain(_ text: String) -> String {
        TextLayout.escapingMarkup(text)
    }

    /// A line that says where the text came from, quieter than the text.
    private static func note(_ text: String) -> String {
        "<span fgalpha=\"60%\">\(plain(text))</span>"
    }

    private static func serverRecap(_ model: ShowDetailModel) async -> String {
        do throws(CompanionError) {
            let (recap, server) = try await PreviouslyOnRequest.recap(model)
            return plain(recap.text) + "\n\n" + note(CompanionCopy.basis(recap, server: server))
        } catch {
            return plain(error.message)
        }
    }

    private static func writtenRecap(show: String, episodes: [DescribedEpisode]) async -> String {
        do throws(HostedBrainError) {
            let recap = try await DescribedRecap.write(show: show, episodes: episodes)
            return plain(recap) + "\n\n" + note(DescribedRecap.basis(episodes))
        } catch {
            return plain(OwnModelCopy.recapFailure(error)) + "\n\n" + descriptions(episodes)
        }
    }

    /// The finished episodes as Plex describes them, each under its number and title, with what Crucible Server would
    /// add and, without a model of the person's own, how to have them written into one recap.
    private static func descriptions(_ episodes: [DescribedEpisode]) -> String {
        let blocks = episodes.map { episode in
            "<b>" + plain(episode.code == episode.title ? episode.title : "\(episode.code) · \(episode.title)") + "</b>\n" + plain(episode.description)
        }
        let hints = [DescribedRecapCopy.withServer] + (HostedBrain.isAvailable ? [] : [OwnModelCopy.recapSetup])
        return (blocks + hints.map(note)).joined(separator: "\n\n")
    }
}
