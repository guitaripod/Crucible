import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CrucibleCore

/// The rules that take a title the app cannot play out of every device: what a mark hides, and what the label write
/// through the server carries. The server's own answers are exercised against a stub in the app's UI tests; here nothing
/// touches the network, so these run beside every other suite.
@Suite(.serialized)
@MainActor
final class IncompatibleTitlesTests {
    init() {
        IncompatibleTitles.forgetServer()
    }

    private static func item(
        _ ratingKey: String,
        type: String = "movie",
        series: String? = nil,
        season: String? = nil,
        section: Int = 1
    ) -> PlexMetadata {
        PlexMetadata(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)",
            type: type,
            title: "Title \(ratingKey)",
            grandparentTitle: series == nil ? nil : "Show",
            grandparentRatingKey: series,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: season == nil ? nil : "Season 1",
            parentRatingKey: season,
            parentThumb: nil,
            parentIndex: nil,
            index: nil,
            year: 2001,
            summary: nil,
            tagline: nil,
            contentRating: nil,
            studio: nil,
            rating: nil,
            audienceRating: nil,
            duration: nil,
            viewOffset: nil,
            viewCount: nil,
            lastViewedAt: nil,
            viewedAt: nil,
            accountID: nil,
            deviceID: nil,
            addedAt: nil,
            originallyAvailableAt: nil,
            thumb: nil,
            art: nil,
            leafCount: nil,
            viewedLeafCount: nil,
            childCount: nil,
            librarySectionID: section,
            librarySectionTitle: "Library",
            Genre: nil,
            Role: nil,
            Director: nil,
            Writer: nil,
            Media: nil,
            Marker: nil,
            Related: nil
        )
    }

    private static func mark(_ ratingKey: String, type: String = "movie", reason: IncompatibleTitles.Reason = .manual) -> IncompatibleTitles.Mark {
        .init(ratingKey: ratingKey, title: "Title \(ratingKey)", type: type, thumb: nil, sectionId: "1", reason: reason, markedAt: Date(), shared: true)
    }

    @Test func aMarkLeavesItsTitleOutAndStaysOutUntilItIsForgotten() {
        IncompatibleTitles.restore([Self.mark("42")])
        #expect(IncompatibleTitles.isHidden("42"))
        #expect(IncompatibleTitles.shown([Self.item("42"), Self.item("43")]).map(\.id) == ["43"])

        IncompatibleTitles.forgetServer()
        #expect(!IncompatibleTitles.isHidden("42"))
        #expect(IncompatibleTitles.count == 0)
    }

    @Test func aMarkedSeriesTakesItsSeasonsAndEpisodesWithIt() {
        IncompatibleTitles.restore([Self.mark("7", type: "show")])
        let episode = Self.item("8", type: "episode", series: "7", season: "6")
        let season = Self.item("6", type: "season", series: "7")
        #expect(IncompatibleTitles.hides(episode))
        #expect(IncompatibleTitles.hides(season))
        #expect(!IncompatibleTitles.hides(Self.item("9", type: "movie")))
        #expect(IncompatibleTitles.shown([Self.item("9"), episode]).count == 1)
    }

    @Test func aMarkedEpisodeLeavesItsShowAlone() {
        IncompatibleTitles.restore([Self.mark("8", type: "episode")])
        let show = Self.item("7", type: "show")
        let other = Self.item("8", type: "episode", series: "7")
        #expect(!IncompatibleTitles.hides(show))
        #expect(IncompatibleTitles.hides(other))
    }

    @Test func theMarksOfOneServerAreNotTheMarksOfAnother() {
        let original = ServerBootstrap.savedMachineIdentifier
        defer {
            IncompatibleTitles.forgetServer()
            if let original {
                ServerBootstrap.saveServer(uri: URL(string: "http://plex.test:32400")!, name: "Test", machineIdentifier: original)
            }
        }
        let first = UUID().uuidString
        let second = UUID().uuidString
        ServerBootstrap.saveServer(uri: URL(string: "http://plex.test:32400")!, name: "Test", machineIdentifier: first)
        IncompatibleTitles.restore([Self.mark("42")])
        #expect(IncompatibleTitles.isHidden("42"))

        ServerBootstrap.saveServer(uri: URL(string: "http://plex.test:32400")!, name: "Test", machineIdentifier: second)
        #expect(!IncompatibleTitles.isHidden("42"), "a rating key means nothing against another server")
    }

    @Test func writingLabelsSendsEveryOneAndLocksThem() throws {
        let endpoint = PlexEndpoint.setLabels(sectionId: "1", ratingKey: "42", type: 1, labels: ["Holiday", IncompatibleTitles.label])
        #expect(endpoint.method == "PUT")
        #expect(endpoint.path == "/library/sections/1/all")
        let request = try endpoint.urlRequest(baseURL: URL(string: "http://plex.test:32400")!, token: "token")
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        #expect(value("id") == "42")
        #expect(value("type") == "1")
        #expect(value("label[0].tag.tag") == "Holiday")
        #expect(value("label[1].tag.tag") == IncompatibleTitles.label)
        #expect(value("label.locked") == "1")
    }
}
