import Foundation
import Testing
@testable import CrucibleCore

struct HomeSurpriseTests {
    private typealias F = HomeFixtures

    private let movie = F.item("1")
    private let show = F.item("2", type: "show")
    private let season = F.item("3", type: "season", fields: ["parentRatingKey": "2"])
    private let episode = F.item("4", type: "episode", fields: ["grandparentRatingKey": "2"])
    private let orphanEpisode = F.item("5", type: "episode")
    private let track = F.item("6", type: "track")

    @Test func anyKindResolvesEveryTypeToAMovieOrShowTarget() {
        #expect(SurpriseMe.target(for: movie, kind: .any) == .movie("1"))
        #expect(SurpriseMe.target(for: show, kind: .any) == .show("2"))
        #expect(SurpriseMe.target(for: season, kind: .any) == .show("2"))
        #expect(SurpriseMe.target(for: episode, kind: .any) == .show("2"))
        #expect(SurpriseMe.target(for: orphanEpisode, kind: .any) == nil)
        #expect(SurpriseMe.target(for: track, kind: .any) == nil)
    }

    @Test func movieKindOnlyAcceptsMovies() {
        #expect(SurpriseMe.target(for: movie, kind: .movie) == .movie("1"))
        for item in [show, season, episode] {
            #expect(SurpriseMe.target(for: item, kind: .movie) == nil)
        }
    }

    @Test func showKindRejectsMovies() {
        #expect(SurpriseMe.target(for: movie, kind: .show) == nil)
        #expect(SurpriseMe.target(for: episode, kind: .show) == .show("2"))
    }

    @Test func seasonsAndEpisodesOfOneShowCollapseToASingleTarget() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            #expect(SurpriseMe.pick(from: [show, season, episode], kind: .show, using: &generator) == .show("2"))
        }
    }

    @Test func pickChoosesAmongTheTargets() {
        var seen = Set<SurpriseMe.Target>()
        for _ in 0..<200 {
            if let pick = SurpriseMe.pick(from: [movie, show], kind: .any) { seen.insert(pick) }
        }
        #expect(seen == [.movie("1"), .show("2")])
    }

    @Test func emptyPoolOrNoMatchPicksNothing() {
        #expect(SurpriseMe.pick(from: [], kind: .any) == nil)
        #expect(SurpriseMe.pick(from: [show, track], kind: .movie) == nil)
        #expect(SurpriseMe.pick(from: [movie], kind: .show) == nil)
    }

    @Test func nothingToPickCopyNamesTheKind() {
        #expect(SurpriseMe.nothingToPickTitle == "Nothing to Pick")
        #expect(SurpriseMe.nothingToPickMessage(for: .any) == "There are no recently added titles to choose from.")
        #expect(SurpriseMe.nothingToPickMessage(for: .movie) == "There are no recently added movies to choose from.")
        #expect(SurpriseMe.nothingToPickMessage(for: .show) == "There are no recently added shows to choose from.")
        #expect([SurpriseMe.Kind.any, .movie, .show].map(\.menuTitle) == ["Any", "Movie", "Show"])
    }
}
