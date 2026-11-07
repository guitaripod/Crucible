import Foundation
import Testing
@testable import CrucibleCore

struct ArtworkAspectTests {
    @Test func agentMatchedArtworkKeepsItsKindsShape() {
        #expect(ArtworkAspect.of(DetailFixtures.item(["type": "movie", "thumb": "/t"]), path: "/t") == ArtworkAspect.poster)
        #expect(ArtworkAspect.of(DetailFixtures.item(["type": "show", "thumb": "/t"]), path: "/t") == ArtworkAspect.poster)
        #expect(ArtworkAspect.of(DetailFixtures.item(["type": "collection", "thumb": "/t"]), path: "/t") == ArtworkAspect.poster)
        #expect(ArtworkAspect.of(DetailFixtures.item(["type": "episode", "thumb": "/t"]), path: "/t") == ArtworkAspect.still)
        #expect(ArtworkAspect.of(DetailFixtures.item(["type": "clip", "thumb": "/t"]), path: "/t") == ArtworkAspect.still)
        #expect(ArtworkAspect.of(DetailFixtures.item(["type": "playlist", "composite": "/c"]), path: "/c") == ArtworkAspect.square)
        #expect(ArtworkAspect.of(DetailFixtures.item(["type": "album", "thumb": "/t"]), path: "/t") == ArtworkAspect.square)
    }

    @Test func aParentsArtworkIsAPoster() {
        let episode = DetailFixtures.item(["type": "episode", "thumb": "/still", "grandparentThumb": "/show"])
        #expect(ArtworkAspect.of(episode, path: "/show") == ArtworkAspect.poster)
        #expect(ArtworkAspect.of(episode, path: nil) == ArtworkAspect.poster)
    }

    @Test func personalVideoTakesTheShapeOfItsFile() {
        let wide = DetailFixtures.item([
            "type": "movie", "guid": "tv.plex.agents.none://6", "thumb": "/t",
            "Media": [["width": 1280, "height": 720]],
        ])
        let tall = DetailFixtures.item([
            "type": "movie", "guid": "com.plexapp.agents.none://81a1f1?lang=xn", "thumb": "/t",
            "Media": [["width": 720, "height": 1280]],
        ])
        let episode = DetailFixtures.item([
            "type": "episode", "guid": "tv.plex.agents.none://9", "thumb": "/t",
            "Media": [["width": 1440, "height": 1080]],
        ])
        #expect(wide.hasFrameArtwork)
        #expect(ArtworkAspect.of(wide, path: "/t") == 0.5625)
        #expect(ArtworkAspect.of(tall, path: "/t") == 1280.0 / 720.0)
        #expect(ArtworkAspect.of(episode, path: "/t") == 0.75)
    }

    @Test func personalVideoWithoutASizeIsAStill() {
        let item = DetailFixtures.item(["type": "movie", "guid": "tv.plex.agents.none://6", "thumb": "/t"])
        #expect(ArtworkAspect.of(item, path: "/t") == ArtworkAspect.still)
        #expect(!DetailFixtures.item(["guid": "plex://movie/5d776b"]).hasFrameArtwork)
        let unmatched = DetailFixtures.item(["guid": "local://3", "thumb": "/t", "Media": [["width": 1920, "height": 1080]]])
        #expect(ArtworkAspect.of(unmatched, path: "/t") == 0.5625)
    }

    @Test func gridTakesTheShapeMostOfItsArtworkHas() {
        #expect(ArtworkAspect.dominant([0.5625, 1.5, 9.0 / 16.0, 1080.0 / 1920.0]) == 0.5625)
        #expect(ArtworkAspect.dominant([1.5, 0.5625]) == 1.5)
        #expect(ArtworkAspect.dominant([0.5625, 1.5]) == 0.5625)
        #expect(ArtworkAspect.dominant([Double]()) == ArtworkAspect.poster)
    }

    @Test func gridShapeStaysWithinBounds() {
        #expect(ArtworkAspect.dominant([0.1]) == 0.4)
        #expect(ArtworkAspect.dominant([4]) == 1.8)
    }

    @Test func artworkFillsACardOnlyWhenItsShapeIsClose() {
        #expect(ArtworkAspect.fills(40.0 / 27.0, card: ArtworkAspect.poster))
        #expect(ArtworkAspect.fills(1 / 1.85, card: ArtworkAspect.still))
        #expect(!ArtworkAspect.fills(1 / 2.39, card: ArtworkAspect.still))
        #expect(!ArtworkAspect.fills(ArtworkAspect.still, card: ArtworkAspect.poster))
        #expect(!ArtworkAspect.fills(1280.0 / 720.0, card: ArtworkAspect.still))
    }

    @Test func libraryPosterCarriesItsArtworksShape() throws {
        let clip = try LibraryFixtures.item(#"{"ratingKey":"6","type":"movie","title":"Wide Clip","guid":"tv.plex.agents.none://6","thumb":"/t","Media":[{"width":1280,"height":720}]}"#)
        #expect(LibraryPoster(grid: clip, kind: .movie).aspect == 0.5625)
        #expect(LibraryPoster(folderItem: clip).aspect == 0.5625)
        let episode = try LibraryFixtures.item(#"{"ratingKey":"9","type":"episode","title":"Pilot","grandparentThumb":"/show","thumb":"/still"}"#)
        #expect(LibraryPoster(recent: episode, kind: .show).aspect == ArtworkAspect.poster)
        #expect(LibraryPoster(folderItem: episode).aspect == ArtworkAspect.still)
    }
}

struct ArtworkMeasuredShapeTests {
    private static let posters = (1...6).map { ArtworkAspect.Sample(path: "/m/\($0)", guess: ArtworkAspect.poster) }

    @Test func framesWithoutPostersReshapeAGridOfMovies() {
        let frames = Dictionary(uniqueKeysWithValues: (1...6).map { ("/m/\($0)", 405.0 / 720.0) })
        #expect(ArtworkAspect.dominant(Self.posters, measured: { frames[$0] }) == ArtworkAspect.still)
    }

    @Test func aFewMeasuredFramesOutweighManyUnmeasuredGuesses() {
        let samples = (1...200).map { ArtworkAspect.Sample(path: "/m/\($0)", guess: ArtworkAspect.poster) }
        let frames = Dictionary(uniqueKeysWithValues: (1...4).map { ("/m/\($0)", 720.0 / 1280.0) })
        #expect(ArtworkAspect.dominant(samples, measured: { frames[$0] }) == ArtworkAspect.still)
    }

    @Test func untilAQuorumIsMeasuredEachCardCountsItsBestShape() {
        let frames = ["/m/1": 0.5625, "/m/2": 0.5625]
        #expect(ArtworkAspect.dominant(Self.posters, measured: { frames[$0] }) == ArtworkAspect.poster)
        let short = Array(Self.posters.prefix(2))
        #expect(ArtworkAspect.dominant(short, measured: { frames[$0] }) == ArtworkAspect.still)
    }

    @Test func realPostersKeepAPosterGrid() {
        let posters = Dictionary(uniqueKeysWithValues: (1...6).map { ("/m/\($0)", $0.isMultiple(of: 2) ? 1.48 : 1.5) })
        #expect(ArtworkAspect.dominant(Self.posters, measured: { posters[$0] }) == ArtworkAspect.poster)
    }

    @Test func aPosterUploadedToAPersonalVideoWins() {
        let clips = (1...5).map { ArtworkAspect.Sample(path: "/c/\($0)", guess: ArtworkAspect.still) }
        let posters = Dictionary(uniqueKeysWithValues: (1...5).map { ("/c/\($0)", 1.5) })
        #expect(ArtworkAspect.dominant(clips, measured: { posters[$0] }) == ArtworkAspect.poster)
    }

    @Test func measuredShapesSnapOnlyWhenClose() {
        #expect(ArtworkAspect.snapped(40.0 / 27.0) == ArtworkAspect.poster)
        #expect(ArtworkAspect.snapped(1 / 1.85) == ArtworkAspect.still)
        #expect(ArtworkAspect.snapped(0.75) == 0.75)
        #expect(ArtworkAspect.snapped(1280.0 / 720.0) == 1280.0 / 720.0)
    }
}
