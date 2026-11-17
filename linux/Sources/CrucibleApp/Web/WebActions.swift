import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// What a web video's card can do, shared by every screen that shows one: play it, open what it stands for, and the
/// menu a right click or the Menu key opens.
@MainActor
enum WebActions {
    /// Selecting a card: a video plays, a playlist or a channel opens its page.
    static func open(_ entry: WebEntry, queue: [WebEntry] = [], from view: View) {
        switch entry.kind {
        case .video: play(entry, queue: queue, from: view)
        case .playlist: view.rootView?.push(WebListScreen.playlist(entry))
        case .channel: view.rootView?.push(WebChannelScreen(address: entry.url, title: entry.title))
        }
    }

    /// Plays `entry` from where the viewer left it (or from `start`), with `queue` to follow.
    static func play(_ entry: WebEntry, queue: [WebEntry] = [], at start: Double? = nil, from view: View) {
        guard let root = view.rootView, let window = view.window else { return }
        guard WebService.shared.isAvailable || WebService.shared.locateTool() else {
            AlertView.notice(title: String(localized: "yt-dlp Is Missing", comment: "Title of the alert shown when web video cannot play"),
                             message: WebService.message(for: YtDlpError.notInstalled), in: window)
            return
        }
        root.closePlayer()
        root.playWeb(WebPlayback(entry: entry, start: start, queue: queue, localPath: WebService.shared.library.download(of: entry.id)?.path))
    }

    /// Opens the channel `entry` belongs to.
    static func openChannel(of entry: WebEntry, from view: View) {
        guard let address = entry.channelURL ?? entry.channelID.map({ "https://www.youtube.com/channel/\($0)" }) else { return }
        view.rootView?.push(WebChannelScreen(address: address, title: entry.channel ?? ""))
    }

    /// Play or Resume, Play from Beginning, Watch Later, Go to Channel, Follow, Copy Link, Open in Browser and Remove
    /// from History; what does not apply is left out. `afterChange` runs once the library changed.
    static func presentMenu(for entry: WebEntry, at point: Point?, in view: View, showsChannel: Bool = true, afterChange: (() -> Void)? = nil) {
        guard let window = view.window else { return }
        let library = WebService.shared.library
        var items: [MenuView.Item] = []
        let watch = library.watch(of: entry.id)
        if entry.kind == .video {
            let resumes = library.resumePosition(of: entry.id) > 0
            items.append(.init(id: "play", title: resumes ? String(localized: "Resume") : String(localized: "Play"), symbol: "play.fill"))
            if resumes { items.append(.init(id: "restart", title: String(localized: "Play from Beginning"), symbol: "gobackward")) }
            let saved = library.isSavedForLater(entry.id)
            items.append(.init(id: "later", title: saved ? String(localized: "Remove from Watch Later", comment: "Web video menu")
                                                        : String(localized: "Watch Later", comment: "Web video menu: save the video for later"),
                               symbol: saved ? "minus.circle" : "clock"))
            items.append(.init(id: "details", title: String(localized: "View Details"), symbol: "info.circle"))
            if WebDownloads.shared.isRunning(entry.id) {
                items.append(.init(id: "download.cancel", title: WebDownloads.cancelTitle, symbol: "xmark.circle"))
            } else if library.download(of: entry.id) != nil {
                items.append(.init(id: "download.delete", title: WebDownloads.deleteTitle, symbol: "trash"))
            } else if !entry.isLive, !entry.isUpcoming {
                items.append(.init(id: "download", title: WebDownloads.downloadTitle, symbol: "arrow.down.circle"))
            }
        } else {
            items.append(.init(id: "open", title: String(localized: "Open"), symbol: "chevron.right"))
        }
        if showsChannel, entry.kind != .channel, entry.channelURL != nil || entry.channelID != nil {
            items.append(.init(id: "channel", title: String(localized: "Go to Channel", comment: "Web video menu"), symbol: "person.crop.circle"))
        }
        if let channelID = entry.channelID, entry.kind != .channel {
            let follows = library.isSubscribed(to: channelID)
            items.append(.init(id: "follow", title: follows ? String(localized: "Unfollow \(entry.channel ?? "")", comment: "Web video menu: stop following the video's channel")
                                                           : String(localized: "Follow \(entry.channel ?? "")", comment: "Web video menu: follow the video's channel"),
                               symbol: follows ? "xmark.circle" : "person.badge.plus"))
        }
        items.append(.init(id: "copy", title: String(localized: "Copy Link", comment: "Web video menu"), symbol: "link"))
        items.append(.init(id: "browser", title: String(localized: "Open in Browser", comment: "Web video menu"), symbol: "globe"))
        if watch != nil {
            items.append(.init(id: "forget", title: String(localized: "Remove from History", comment: "Web video menu"), symbol: "trash"))
        }
        let frame = window.focusedView?.frameInWindow ?? view.frameInWindow
        let anchor = Rect(x: point.map { $0.x } ?? frame.minX, y: point.map { $0.y } ?? frame.maxY, width: 1, height: 1)
        let menu = MenuView(title: entry.title, items: items, anchor: anchor)
        menu.onSelect = { [weak view] item in
            guard let view else { return }
            switch item.id {
            case "play": play(entry, from: view)
            case "restart": play(entry, at: 0, from: view)
            case "open": open(entry, from: view)
            case "later":
                if library.isSavedForLater(entry.id) { library.removeFromWatchLater(entry.id) } else { library.saveForLater(entry) }
                afterChange?()
            case "details": view.rootView?.push(WebVideoScreen(entry: entry))
            case "download": WebDownloads.shared.start(entry, in: window)
            case "download.cancel": WebDownloads.shared.cancel(entry.id)
            case "download.delete":
                WebDownloads.shared.delete(entry.id)
                afterChange?()
            case "channel": openChannel(of: entry, from: view)
            case "follow":
                guard let channelID = entry.channelID else { return }
                if library.isSubscribed(to: channelID) {
                    library.unsubscribe(from: channelID)
                } else {
                    library.subscribe(to: WebChannel(id: channelID, title: entry.channel ?? channelID, url: entry.channelURL))
                }
                afterChange?()
            case "copy": window.copy(entry.url)
            case "browser":
                if let url = URL(string: entry.url) { Browser.open(url) }
            case "forget":
                library.removeFromHistory(entry.id)
                afterChange?()
            default: break
            }
        }
        menu.present(in: window)
    }
}
