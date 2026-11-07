import Foundation

/// The guide the demo library's long animation, Paper Lanterns, is shown with, so App Review and the store
/// screenshots see Essentials on a show Crucible owns instead of a real one.
package enum DemoGuide {
    package static let tvdb = 9_100_005

    package static let paperLanterns = GuideShow(
        slug: "paper-lanterns-demo",
        title: "Paper Lanterns",
        ids: GuideIDs(tvdb: tvdb, tmdb: tvdb),
        episodes: (1...52).map { n in
            GuideEpisode(n: n, kind: animeOnly.contains(n) ? .animeOnly : (mixed.contains(n) ? .mixed : .canon))
        },
        ranges: [
            GuideRange(from: 1, to: 6, retells: ["Paper Lanterns: The Movie"], source: "demo", url: "https://github.com/guitaripod/crucible-guides", quote: "The series opens by retelling the film."),
        ],
        arcs: [GuideArc(name: "River Town", from: 1, to: 26), GuideArc(name: "Upriver", from: 27, to: 52)],
        sources: [GuideSource(id: "demo", name: "Crucible Guides", licence: "CC BY-SA 4.0", licenceUrl: "https://creativecommons.org/licenses/by-sa/4.0/", url: "https://github.com/guitaripod/crucible-guides")]
    )

    private static let animeOnly: Set<Int> = [9, 14, 15, 16, 20, 25, 31, 37, 38, 44, 49]
    private static let mixed: Set<Int> = [11, 22, 33, 41]
}
