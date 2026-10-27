import AVKit
import UIKit
@testable import Crucible
@testable import CrucibleCore

/// Proves on the iPhone simulator that the next episode starts in the player already on screen (no
/// dismissal, no reload of the screen underneath), that the episode left at its credits is reported as
/// finished, and that the swap lands on the next episode. Writes its findings beside the captures.
@MainActor
enum EpisodeFlowProbe {
    private static let episode = "4013"
    private static let nextEpisode = "4014"

    static func run() async {
        var findings: [String] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            findings.append("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        guard let tabBar = await ShotHarness.waitForTabBar() else { return }
        let base = ServerBootstrap.connection()!.serverURI
        let api = APIClient(baseURL: base, token: "mock-token")
        Preferences.streamingQuality = .original
        Preferences.autoplayNextEpisode = true
        Preferences.stillWatchingAfter = 0

        await http(base, "/mock/flags?clip_markers=1&no_credits=0")
        await http(base, "/:/timeline?ratingKey=\(episode)&state=stopped&time=105000&duration=150000")

        guard let container = try? await api.requestContainer(.metadata(ratingKey: episode)),
              let item = container.Metadata?.first else {
            record("episode metadata loads", false)
            return await finish(findings)
        }
        record("the episode resumes before its credits", item.positionSecs > 100, "\(Int(item.positionSecs)) s")

        let coordinator = PlayerCoordinator(api: api, request: PlaybackRequest(item: item))
        coordinator.present(from: tabBar)

        guard let playerVC = await waitForPlayer(in: tabBar) else {
            record("the player opens", false)
            return await finish(findings)
        }
        record("the player opens", true)
        await ShotHarness.capture("01-playing")

        var offered = false
        for _ in 0..<200 where !offered {
            offered = coordinator.offersNextEpisode
            if !offered { try? await Task.sleep(for: .milliseconds(200)) }
        }
        record("Up Next appears at the credits", offered)
        if offered { await ShotHarness.capture("02-up-next") }

        var title = windowTitle()
        for _ in 0..<250 where title == item.title {
            try? await Task.sleep(for: .milliseconds(200))
            title = windowTitle()
        }
        try? await Task.sleep(for: .seconds(4))
        await ShotHarness.capture("03-next-episode")

        record("the countdown starts the next episode", title != nil && title != item.title, title ?? "no title")
        record(
            "the same player is still on screen",
            tabBar.presentedViewController === playerVC && playerVC.player != nil,
            tabBar.presentedViewController.map { String(describing: type(of: $0)) } ?? "nothing"
        )
        let playing = (playerVC.player?.rate ?? 0) > 0 || playerVC.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
        record("the next episode is playing", playing)

        if let watched = try? await api.requestContainer(.metadata(ratingKey: episode)),
           let left = watched.Metadata?.first {
            record("the finished episode is watched on the server", left.isWatched, "viewCount=\(left.viewCount ?? 0)")
        }
        if let resumed = try? await api.requestContainer(.metadata(ratingKey: nextEpisode)),
           let next = resumed.Metadata?.first {
            let request = PlaybackRequest(item: next)
            record("the next episode starts from the beginning", request.resumePosition == 0, "\(Int(request.resumePosition)) s")
        }

        await finish(findings)
    }

    private static func finish(_ findings: [String]) async {
        let path = ShotHarness.signalDirectory + "/flow.txt"
        try? (findings.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        await ShotHarness.capture("done")
    }

    private static func waitForPlayer(in tabBar: TabBarController) async -> AVPlayerViewController? {
        for _ in 0..<300 {
            if let playerVC = tabBar.presentedViewController as? AVPlayerViewController, playerVC.player != nil {
                return playerVC
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private static func windowTitle() -> String? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .title
    }

    private static func http(_ base: URL, _ path: String) async {
        guard let url = URL(string: path, relativeTo: base) else { return }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try? await URLSession.shared.data(for: request)
    }
}
