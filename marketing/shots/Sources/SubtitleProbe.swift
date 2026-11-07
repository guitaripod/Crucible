import AVKit
import UIKit
@testable import Crucible
@testable import CrucibleCore

/// Proves on the iPhone simulator that a text subtitle plays as a real subtitle track: it shows, the system's own subtitle
/// control hides and shows it again without a new stream while the server is told each time, and the player menu lists the
/// title's subtitles and audio tracks. Writes its findings beside the captures (SHOT_SCRIPT=subtitles).
@MainActor
enum SubtitleProbe {
    private static let movie = "1001"
    private static let english = 10015

    static func run() async {
        var findings: [String] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            findings.append("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        guard let tabBar = await ShotHarness.waitForTabBar() else { return }
        let base = ServerBootstrap.connection()!.serverURI
        let api = APIClient(baseURL: base, token: "mock-token")
        Preferences.streamingQuality = .original
        guard let container = try? await api.requestContainer(.metadata(ratingKey: movie)), let item = container.Metadata?.first else {
            record("the movie loads", false)
            return await finish(findings)
        }
        let request = PlaybackRequest(item: item).resuming(at: 0, selectedSubtitleId: .some(english), selectedAudioStreamId: .some(item.audioStreams.first?.id))
        let coordinator = PlayerCoordinator(api: api, request: request)
        coordinator.present(from: tabBar)
        guard let playerVC = await waitForPlayer(in: tabBar), let player = playerVC.player else {
            record("the player opens", false)
            return await finish(findings)
        }
        try? await Task.sleep(for: .seconds(7))
        await ShotHarness.capture("sub-01-english")

        let streams = await count(base, "start.m3u8")
        guard let current = player.currentItem, let group = try? await current.asset.loadMediaSelectionGroup(for: .legible) else {
            record("the stream carries a subtitle track", false)
            return await finish(findings)
        }
        record("the stream carries one subtitle track", group.options.count == 1, "\(group.options.map(\.displayName))")
        record("the subtitle shows", current.currentMediaSelection.selectedMediaOption(in: group) != nil)

        current.select(nil, in: group)
        try? await Task.sleep(for: .seconds(2))
        await ShotHarness.capture("sub-02-hidden-by-the-system-control")
        record("hiding it tells the server", await count(base, "subtitleStreamID=0") >= 1)

        current.select(group.options.first, in: group)
        try? await Task.sleep(for: .seconds(2))
        record("showing it again tells the server", await count(base, "subtitleStreamID=\(english)") >= 2)
        record("neither asked for a new stream", await count(base, "start.m3u8") == streams)

        if let more = moreButton(in: playerVC.view) {
            if #available(iOS 17.4, *) {
                more.performPrimaryAction()
                try? await Task.sleep(for: .seconds(1.5))
                await ShotHarness.capture("sub-03-player-menu")
            }
            let titles = more.menu?.children.compactMap { ($0 as? UIMenu)?.title } ?? []
            record("the player menu has Subtitles and Audio", titles.contains("Subtitles") && titles.contains("Audio"), "\(titles)")
        } else {
            record("the player menu button exists", false)
        }
        withExtendedLifetime(coordinator) {}
        await finish(findings)
    }

    private static func moreButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.showsMenuAsPrimaryAction, button.menu != nil { return button }
        return view.subviews.lazy.compactMap { moreButton(in: $0) }.first
    }

    private static func finish(_ findings: [String]) async {
        try? (findings.joined(separator: "\n") + "\n").write(toFile: ShotHarness.signalDirectory + "/subtitles.txt", atomically: true, encoding: .utf8)
        await ShotHarness.capture("done")
    }

    private static func waitForPlayer(in tabBar: TabBarController) async -> AVPlayerViewController? {
        for _ in 0..<300 {
            if let playerVC = tabBar.presentedViewController as? AVPlayerViewController, playerVC.player != nil { return playerVC }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private static func count(_ base: URL, _ needle: String) async -> Int {
        var components = URLComponents(url: base.appendingPathComponent("mock/requests"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "contains", value: needle)]
        guard let url = components?.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return -1 }
        return object["count"] ?? -1
    }
}
