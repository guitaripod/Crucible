import UIKit
@testable import Crucible
@testable import CrucibleCore
import CrucibleDesign

/// Renders watch cards against the mock for every format and look (`card-<case>-<format>-<look>.png` in the signal
/// folder, copied out beside the captures), then captures the screen that makes them: a movie, a long title, the switch
/// to a season and a show, words being written, and each format.
@MainActor
enum WatchCardShotScript {
    private struct Case {
        let name: String
        let origin: WatchCardOrigin
        let scope: WatchCardScope
        let rating: UserRating?
        let take: String?
    }

    static func run() async {
        guard let tabBar = await ShotHarness.waitForTabBar() else { return }
        let api = APIClient(baseURL: ServerBootstrap.connection()!.serverURI, token: "mock-token")
        await ShotHarness.settle(3)
        let cases = [
            Case(name: "movie", origin: WatchCardOrigin(initial: .movie, movieKey: "1003"), scope: .movie, rating: UserRating(halfStars: 9), take: "A quiet, salt-stung mystery that sneaks up on you and stays for days."),
            Case(name: "longtitle", origin: WatchCardOrigin(initial: .movie, movieKey: "1026"), scope: .movie, rating: UserRating(halfStars: 7), take: nil),
            Case(name: "season", origin: WatchCardOrigin(initial: .season, seasonIndex: 1, showKey: "2001"), scope: .season, rating: UserRating(halfStars: 10), take: "Eight episodes, one wreck, zero wasted minutes."),
            Case(name: "show", origin: WatchCardOrigin(initial: .show, showKey: "2001"), scope: .show, rating: nil, take: nil),
            Case(name: "episode", origin: WatchCardOrigin(initial: .episode, episodeKey: "4001", showKey: "2001"), scope: .episode, rating: UserRating(halfStars: 8), take: "That cold open."),
        ]
        for item in cases {
            await renderAll(item, api: api)
        }
        await captureComposer(api: api, tabBar: tabBar)
        await ShotHarness.capture("done")
    }

    private static func renderAll(_ item: Case, api: APIClient) async {
        guard let subject = try? await WatchCardLoader.load(item.scope, origin: item.origin, api: api) else {
            log("no subject for \(item.name)")
            return
        }
        let facts = WatchCardFacts(subject: subject)
        async let poster = image(facts.posterPath, width: 720)
        async let backdrop = image(facts.backdropPath, width: 960)
        let artwork = await WatchCardArtwork.prepare(poster: await poster, backdrop: await backdrop)
        log("\(item.name): \(facts.eyebrow) | \(facts.title) | \(facts.context ?? "-") | \(facts.facts) | \(facts.genres) | \(facts.credit ?? "-") | scores \(facts.scores.map(\.text)) | \(facts.watched) | progress \(facts.progress?.label ?? "-") tone \(artwork.tone != nil)")
        for format in WatchCardFormat.allCases {
            for style in WatchCardStyle.allCases {
                let draft = WatchCardDraft(
                    facts: facts,
                    rating: item.rating ?? facts.servedRating,
                    take: item.take,
                    options: WatchCardOptions(format: format, style: style),
                    artwork: artwork
                )
                let started = Date()
                let png = WatchCardRenderer.render(draft).pngData()
                log("rendered \(item.name) \(format.rawValue) \(style.rawValue) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                try? png?.write(to: URL(fileURLWithPath: "\(ShotHarness.signalDirectory)/card-\(item.name)-\(format.rawValue)-\(style.rawValue).png"))
            }
        }
    }

    private static func captureComposer(api: APIClient, tabBar: UIViewController) async {
        WatchCardOptions().save()
        WatchCardScreens.present(WatchCardOrigin(initial: .episode, episodeKey: "4008", seasonKey: nil, seasonIndex: 1, showKey: "2001"), api: api, from: tabBar)
        await ShotHarness.settle(5)
        await ShotHarness.capture("wc-01-episode")
        guard let composer = (tabBar.presentedViewController as? UINavigationController)?.viewControllers.first as? WatchCardComposerViewController else {
            log("composer not presented")
            return
        }
        composer.select(.season)
        await ShotHarness.settle(4)
        await ShotHarness.capture("wc-02-season")
        composer.write("Eight episodes, one wreck, zero wasted minutes.")
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("wc-03-words")
        composer.select(.story)
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("wc-04-story")
        composer.select(.square)
        await ShotHarness.settle(1.5)
        await ShotHarness.capture("wc-05-square")
        composer.select(.show)
        await ShotHarness.settle(4)
        await ShotHarness.capture("wc-06-show")
        tabBar.dismiss(animated: false)
        await ShotHarness.settle(1)
    }

    private static func image(_ path: String?, width: Int) async -> UIImage? {
        guard let path else { return nil }
        return await ImageLoader.shared.loadImage(path: path, width: width)
    }

    private static func log(_ line: String) {
        let url = URL(fileURLWithPath: "\(ShotHarness.signalDirectory)/watchcard-log.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
