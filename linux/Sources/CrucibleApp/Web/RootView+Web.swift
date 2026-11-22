import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln

/// Opening things from the web in the main UI: a link typed or pasted (Ctrl+L, Ctrl+V on a page), one handed over on
/// the command line, or one a screen found.
extension RootView {
    /// Opens what `link` points at: a video plays, a playlist and a channel show their page, and any other address is
    /// handed to yt-dlp as a video.
    func open(_ link: WebLink) {
        switch link {
        case .video(let url, let start):
            playLink(url, start: start)
        case .other(let url):
            playLink(url, start: nil)
        case .playlist(let url):
            closePlayer()
            if Self.showsWeb { select(Self.webID) }
            push(WebListScreen.playlist(WebEntry(id: url, url: url, kind: .playlist, title: String(localized: "Playlist", comment: "Badge on a card that opens a web playlist"))))
        case .channel(let url):
            closePlayer()
            if Self.showsWeb { select(Self.webID) }
            push(WebChannelScreen(address: url, title: ""))
        }
    }

    /// Plays the video at `url`; a link to a Short opens the Shorts player on it, its channel's other Shorts after it.
    private func playLink(_ url: String, start: Double?) {
        guard WebService.shared.isAvailable || WebService.shared.locateTool() else {
            if let window {
                AlertView.notice(title: String(localized: "yt-dlp Is Missing", comment: "Title of the alert shown when web video cannot play"),
                                 message: WebService.message(for: YtDlpError.notInstalled), in: window)
            }
            return
        }
        closePlayer()
        let entry = WebEntry(id: WebLink.youTubeVideoID(in: url) ?? url, url: url, title: "", isShort: url.contains("/shorts/"))
        if entry.isShort, start == nil {
            playShorts(WebShortsFeed(entries: [entry], followsWithChannel: true))
        } else {
            playWeb(WebPlayback(entry: entry, start: start))
        }
    }

    /// Asks for an address (Ctrl+L), offering the clipboard's when it holds one, and opens it.
    func presentOpenLink() {
        guard let window else { return }
        let offered = window.pasteboardText().flatMap(WebLink.init)?.url ?? ""
        weak var alert: AlertView?
        let shown = AlertView(title: String(localized: "Open Link", comment: "Title of the panel that asks for the address of a video to play"),
                              message: String(localized: "Paste the address of a video, a playlist or a channel. Anything yt-dlp can read plays.",
                                              comment: "Explains what the Open Link panel accepts"),
                              actions: [
                                  AlertView.Action(String(localized: "Open")) { [weak self] in
                                      guard let self, let link = WebLink(alert?.text ?? "") else {
                                          AlertView.notice(title: String(localized: "That Isn’t a Link", comment: "Alert title when Open Link got something that is no web address"),
                                                           message: String(localized: "Enter a web address, such as https://youtu.be/…", comment: "Alert message when Open Link got no web address"),
                                                           in: window)
                                          return
                                      }
                                      self.open(link)
                                  },
                                  AlertView.Action(String(localized: "Cancel"), role: .cancel),
                              ], fieldPlaceholder: "https://", fieldText: offered)
        alert = shown
        shown.present(in: window)
    }
}
