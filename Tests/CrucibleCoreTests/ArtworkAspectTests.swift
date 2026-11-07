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
        #expect(wide.isPersonalMedia)
        #expect(ArtworkAspect.of(wide, path: "/t") == 0.5625)
        #expect(ArtworkAspect.of(tall, path: "/t") == 1280.0 / 720.0)
        #expect(ArtworkAspect.of(episode, path: "/t") == 0.75)
    }

    @Test func personalVideoWithoutASizeIsAStill() {
        let item = DetailFixtures.item(["type": "movie", "guid": "tv.plex.agents.none://6", "thumb": "/t"])
        #expect(ArtworkAspect.of(item, path: "/t") == ArtworkAspect.still)
        #expect(!DetailFixtures.item(["guid": "plex://movie/5d776b"]).isPersonalMedia)
        #expect(!DetailFixtures.item(["guid": "local://12"]).isPersonalMedia)
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
