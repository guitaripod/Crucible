import CrucibleCore
import CrucibleWeb
import Foundation
import MidgarCore

/// The single place that opens things from outside a screen (`TVRouter`): `crucible://` links a later launch handed over.
/// A link that arrives before the main UI exists waits here, only the latest one is kept, and it runs once the UI is up.
@MainActor
final class Router {
    private weak var root: RootView?
    private var pending: DeepLink?
    private var pendingWeb: WebLink?
    private var pendingLive: LiveTVLink?
    private var resolveTask: Task<Void, Never>?

    /// Called once the main UI is on screen; runs a link that arrived earlier.
    func activate(_ root: RootView) {
        self.root = root
        if let web = pendingWeb {
            pendingWeb = nil
            root.open(web)
        }
        if let live = pendingLive {
            pendingLive = nil
            root.openLiveTV(live)
        }
        guard let link = pending else { return }
        pending = nil
        handle(link)
    }

    /// Called when the main UI goes away (sign out, another server); drops anything still queued.
    func deactivate() {
        resolveTask?.cancel()
        resolveTask = nil
        root = nil
        pending = nil
        pendingWeb = nil
        pendingLive = nil
    }

    /// Routes a `crucible://` URL, or a web address, which plays through yt-dlp; false when it is neither.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let web = WebLink(url.absoluteString) {
            MidgarLog.notice("Web link from \(url.host ?? "?"), main UI \(root == nil ? "not ready" : "ready")", category: .lifecycle)
            if let root { root.open(web) } else { pendingWeb = web }
            return true
        }
        if let live = LiveTVLink(url: url) {
            MidgarLog.notice("Live TV link, main UI \(root == nil ? "not ready" : "ready")", category: .lifecycle)
            if let root { root.openLiveTV(live) } else { pendingLive = live }
            return true
        }
        guard let link = DeepLink(url: url) else {
            MidgarLog.notice("Ignored unrecognised URL \(url.scheme ?? "?")://\(url.host ?? "")", category: .lifecycle)
            return false
        }
        handle(link)
        return true
    }

    func handle(_ link: DeepLink) {
        MidgarLog.notice("Deep link \(Self.describe(link)), main UI \(root == nil ? "not ready" : "ready")", category: .lifecycle)
        guard root != nil else {
            pending = link
            return
        }
        switch link {
        case .item(let ratingKey, _):
            resolve(ratingKey) { root, item in
                guard DeepLink.isItemType(item.mediaType) else {
                    MidgarLog.error("Deep link item \(item.id) is a \(item.mediaType), which has no title page", category: .lifecycle)
                    return
                }
                root.showDetail(item)
            }
        case .play(let ratingKey):
            resolve(ratingKey) { root, item in
                guard DeepLink.isPlayableType(item.mediaType) else {
                    MidgarLog.error("Deep link item \(item.id) is a \(item.mediaType), which cannot be played", category: .lifecycle)
                    return
                }
                root.closePlayer()
                root.play(item: item, api: root.payload.api)
            }
        }
    }

    private static func describe(_ link: DeepLink) -> String {
        switch link {
        case .item(_, let mediaType): "item(\(mediaType ?? "any type"))"
        case .play: "play"
        }
    }

    /// Looks the item up on the server: a link names only its rating key, and the page and the player need the item.
    private func resolve(_ ratingKey: String, then action: @escaping @MainActor (RootView, PlexMetadata) -> Void) {
        guard let api = root?.payload.api else { return }
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            do {
                let container = try await api.requestContainer(.metadata(ratingKey: ratingKey))
                guard !Task.isCancelled, let root = self?.root, let item = container.Metadata?.first else {
                    MidgarLog.error("Deep link item \(ratingKey) not found", category: .lifecycle)
                    return
                }
                action(root, item)
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Deep link lookup for \(ratingKey) failed: \(String(describing: error))", category: .networking)
            }
        }
    }
}
