import CrucibleCore
import UIKit

/// The single place that opens things from outside a screen: `crucible://` links from Top Shelf and
/// Siri, and the in-app jumps that must land on a known tab. Links that arrive before the main UI
/// exists wait here, only the latest one is kept, and run the moment the UI is activated.
@MainActor
final class TVRouter {
    private weak var tabBar: TVRootTabBarController?
    private var pending: DeepLink?
    private var resolveTask: Task<Void, Never>?
    #if DEBUG
    private static var launchLinkConsumed = false
    #endif

    /// Called by the coordinator once the tab bar is on screen; runs a link that arrived earlier.
    func activate(_ tabBar: TVRootTabBarController) {
        self.tabBar = tabBar
        #if DEBUG
        TVDebugScreen.openIfRequested(on: tabBar)
        queueLaunchLink()
        #endif
        guard let link = pending else { return }
        pending = nil
        handle(link)
    }

    #if DEBUG
    /// UI tests start from a link without the system's "Open in Crucible?" prompt: the environment
    /// variable `CRUCIBLE_OPEN_LINK` names a `crucible://` URL that runs once the main UI is up.
    private func queueLaunchLink() {
        guard !Self.launchLinkConsumed, pending == nil,
              let text = ProcessInfo.processInfo.environment["CRUCIBLE_OPEN_LINK"],
              let link = URL(string: text).flatMap(DeepLink.init(url:)) else { return }
        Self.launchLinkConsumed = true
        pending = link
        scheduleLaterLaunchLink()
    }

    /// `CRUCIBLE_OPEN_LINK_LATER=<seconds>:<url>` delivers a second link that long after launch, to
    /// exercise links that arrive while something is already on screen.
    private func scheduleLaterLaunchLink() {
        guard let text = ProcessInfo.processInfo.environment["CRUCIBLE_OPEN_LINK_LATER"],
              let colon = text.firstIndex(of: ":"),
              let seconds = Double(text[..<colon]),
              let link = URL(string: String(text[text.index(after: colon)...])).flatMap(DeepLink.init(url:)) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.handle(link)
        }
    }
    #endif

    /// Called when the main UI goes away (sign out, relaunch); drops anything still queued.
    func deactivate() {
        resolveTask?.cancel()
        resolveTask = nil
        tabBar = nil
        pending = nil
    }

    /// Routes a `crucible://` URL. Returns false when the URL is not one of ours.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let link = DeepLink(url: url) else {
            AppLogger.notice("Ignored unrecognised URL \(Self.redacted(url))", .lifecycle)
            return false
        }
        handle(link)
        return true
    }

    func handle(_ link: DeepLink) {
        AppLogger.notice("Deep link \(Self.describe(link)), main UI \(tabBar == nil ? "not ready" : "ready")", .lifecycle)
        guard tabBar != nil else {
            pending = link
            return
        }
        switch link {
        case .item(let ratingKey, let mediaType?):
            open(ratingKey: ratingKey, mediaType: mediaType)
        case .item(let ratingKey, nil):
            resolve(ratingKey: ratingKey) { router, item in
                guard ["movie", "show", "episode"].contains(item.mediaType) else {
                    AppLogger.error("Deep link item \(item.id) is a \(item.mediaType), which has no detail screen", .lifecycle)
                    return
                }
                router.open(ratingKey: item.id, mediaType: item.mediaType)
            }
        case .play(let ratingKey):
            resolve(ratingKey: ratingKey) { router, item in
                guard DeepLink.isPlayableType(item.mediaType) else {
                    AppLogger.error("Deep link item \(item.id) is a \(item.mediaType), which cannot be played", .lifecycle)
                    return
                }
                router.play(TVPlaybackRequest(item: item))
            }
        }
    }

    /// Shows the detail screen for an item from anywhere: closes whatever is presented (the
    /// player, a modal), selects Home, unwinds it to its root and pushes the detail on top.
    func open(ratingKey: String, mediaType: String) {
        guard let tabBar else {
            pending = .item(ratingKey: ratingKey, mediaType: mediaType)
            return
        }
        dismissPresented(over: tabBar) {
            let navigation = tabBar.showHome()
            navigation.popToRootViewController(animated: false)
            let detail = TVScreens.detail(tabBar.environment, ratingKey: ratingKey, mediaType: mediaType)
            navigation.pushViewController(detail, animated: true)
        }
    }

    /// Closes whatever is presented, selects the tab for `destination` and shows its root screen.
    func show(_ destination: TVTabDestination) {
        guard let tabBar else { return }
        dismissPresented(over: tabBar) {
            tabBar.select(destination)?.popToRootViewController(animated: false)
        }
    }

    /// Starts playback from anywhere, replacing whatever is presented.
    func play(_ request: TVPlaybackRequest) {
        guard let tabBar else {
            pending = .play(ratingKey: request.ratingKey)
            return
        }
        dismissPresented(over: tabBar) {
            TVScreens.play(tabBar.environment, request: request, from: tabBar)
        }
    }

    /// Looks the item up on the server for links that do not say what it is or where it resumes.
    private func resolve(
        ratingKey: String,
        then action: @escaping @MainActor (TVRouter, PlexMetadata) -> Void
    ) {
        guard let api = tabBar?.environment.api else { return }
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            do {
                let container = try await api.requestContainer(.metadata(ratingKey: ratingKey))
                guard !Task.isCancelled, let self, let item = container.Metadata?.first else {
                    AppLogger.error("Deep link item \(ratingKey) not found", .lifecycle)
                    return
                }
                action(self, item)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("Deep link lookup for \(ratingKey) failed: \(String(describing: error))", .networking)
            }
        }
    }

    /// An outside URL reduced to scheme and host: its path and query are not ours to keep in a log.
    private static func redacted(_ url: URL) -> String {
        "\(url.scheme ?? "?")://\(url.host ?? "")"
    }

    private static func describe(_ link: DeepLink) -> String {
        switch link {
        case .item(_, let mediaType): return "item(\(mediaType ?? "any type"))"
        case .play: return "play"
        }
    }

    private func dismissPresented(over tabBar: TVRootTabBarController, then action: @escaping @MainActor () -> Void) {
        guard tabBar.presentedViewController != nil else {
            action()
            return
        }
        Task {
            await TVPlayerCoordinator.endActive()
            guard tabBar.presentedViewController != nil else {
                action()
                return
            }
            tabBar.dismiss(animated: false) { action() }
        }
    }
}
