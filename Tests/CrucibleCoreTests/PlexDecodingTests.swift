import Foundation
import Testing
@testable import CrucibleCore

struct PlexDecodingTests {
    private static let hubsResponse = #"""
    {
      "MediaContainer": {
        "size": 2,
        "allowSync": true,
        "Hub": [
          {
            "key": "/hubs/home/continueWatching",
            "title": "Continue Watching",
            "type": "mixed",
            "hubIdentifier": "home.continue",
            "size": 1,
            "more": false,
            "promoted": true,
            "Metadata": [
              {
                "ratingKey": "101",
                "key": "/library/metadata/101",
                "type": "episode",
                "title": "Low Tide",
                "grandparentTitle": "The Show",
                "grandparentRatingKey": "100",
                "parentTitle": "Season 2",
                "parentIndex": 2,
                "index": 4,
                "viewOffset": 600000,
                "duration": 2700000,
                "thumb": "/library/metadata/101/thumb/1",
                "unknownFutureField": {"nested": [1, 2, 3]}
              }
            ]
          },
          {
            "key": "/hubs/home/recentlyAdded",
            "title": "Recently Added",
            "type": "movie",
            "hubIdentifier": "home.movies.recent",
            "size": 0
          }
        ]
      }
    }
    """#

    private static let metadataResponse = #"""
    {
      "MediaContainer": {
        "size": 1,
        "Metadata": [
          {
            "ratingKey": "101",
            "type": "episode",
            "title": "Low Tide",
            "year": 2021,
            "duration": 2700000,
            "viewCount": 2,
            "originallyAvailableAt": "2021-03-05",
            "Genre": [{"tag": "Drama"}, {"tag": "Mystery"}],
            "Director": [{"tag": "A. Director"}],
            "Writer": [{"tag": "A. Writer"}, {"tag": "B. Writer"}],
            "Role": [{"id": 5, "tag": "Jane Actor", "role": "Captain", "thumb": "/t/5"}],
            "Marker": [
              {"type": "intro", "startTimeOffset": 1000, "endTimeOffset": 31000, "final": false},
              {"type": "credits", "startTimeOffset": 2600000, "endTimeOffset": 2700000, "final": true}
            ],
            "Media": [
              {
                "id": 11,
                "videoCodec": "h264",
                "audioCodec": "aac",
                "videoResolution": "1080",
                "width": 1920,
                "height": 1080,
                "audioChannels": 6,
                "bitrate": 8000,
                "container": "mp4",
                "Part": [
                  {
                    "id": 21,
                    "key": "/library/parts/21/1/file.mp4",
                    "file": "/media/shows/low-tide.mp4",
                    "size": 1610612736,
                    "duration": 2700000,
                    "Stream": [
                      {"id": 31, "streamType": 1, "codec": "h264"},
                      {"id": 32, "streamType": 2, "codec": "aac", "language": "English", "channels": 6, "default": true, "selected": true, "displayTitle": "English (AAC 5.1)"},
                      {"id": 33, "streamType": 2, "codec": "ac3", "language": "Finnish", "channels": 2, "displayTitle": "Finnish (AC3 Stereo)"},
                      {"id": 34, "streamType": 3, "codec": "srt", "language": "English", "forced": false, "key": "/library/streams/34"},
                      {"id": 35, "streamType": 3, "codec": "hdmv_pgs_subtitle", "language": "Finnish"}
                    ]
                  }
                ]
              }
            ],
            "Related": {
              "Hub": [
                {"title": "More Like This", "Metadata": [{"ratingKey": "300", "type": "show", "title": "Neighbour"}]},
                {"title": "Empty", "Metadata": []},
                {"title": "Missing"}
              ]
            }
          }
        ]
      }
    }
    """#

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func hubsResponseDecodesHubsAndTheirMetadata() throws {
        let container = try decode(PlexResponse.self, Self.hubsResponse).MediaContainer
        let hubs = try #require(container.Hub)
        #expect(hubs.count == 2)
        #expect(hubs[0].title == "Continue Watching")
        #expect(hubs[0].hubIdentifier == "home.continue")
        #expect(hubs[1].Metadata == nil)

        let episode = try #require(hubs[0].Metadata?.first)
        #expect(episode.id == "101")
        #expect(episode.mediaType == "episode")
        #expect(episode.showName == "The Show")
        #expect(episode.seasonNumber == 2)
        #expect(episode.episodeNumber == 4)
        #expect(episode.positionSecs == 600)
        #expect(episode.durationSecs == 2700)
        #expect(abs(episode.progressPercent - 600_000.0 / 2_700_000.0) < 0.0001)
        #expect(!episode.isWatched)
    }

    @Test func metadataResponseDecodesMediaPartsAndStreams() throws {
        let container = try decode(PlexResponse.self, Self.metadataResponse).MediaContainer
        let item = try #require(container.Metadata?.first)
        #expect(item.videoWidth == 1920)
        #expect(item.videoHeight == 1080)
        #expect(item.videoCodec == "h264")
        #expect(item.fileSize == 1_610_612_736)
        #expect(item.mediaContainer == "mp4")
        #expect(item.isWatched)

        #expect(item.audioStreams.map(\.id) == [32, 33])
        #expect(item.subtitleStreams.map(\.id) == [34, 35])
        let defaultAudio = try #require(item.audioStreams.first)
        #expect(defaultAudio.isDefault == true)
        #expect(defaultAudio.channels == 6)
        #expect(item.audioStreams[1].isDefault == nil)
        #expect(!item.subtitleStreams[0].isBitmap)
        #expect(item.subtitleStreams[1].isBitmap)
    }

    @Test func metadataResponseDecodesMarkersAndTags() throws {
        let item = try #require(decode(PlexResponse.self, Self.metadataResponse).MediaContainer.Metadata?.first)
        let markers = try #require(item.Marker)
        #expect(markers.count == 2)
        #expect(markers[0].type == "intro")
        #expect(markers[0].startSecs == 1)
        #expect(markers[0].endSecs == 31)
        #expect(!markers[0].isCredits)
        #expect(markers[1].isCredits)
        #expect(markers[1].final == true)

        #expect(item.genres == ["Drama", "Mystery"])
        #expect(item.directors == ["A. Director"])
        #expect(item.writers == ["A. Writer", "B. Writer"])
        #expect(item.cast.first?.role == "Captain")
        #expect(item.cast.first?.id == 5)
    }

    @Test func relatedHubsKeepOnlyThoseWithItems() throws {
        let item = try #require(decode(PlexResponse.self, Self.metadataResponse).MediaContainer.Metadata?.first)
        #expect(item.relatedHubs.map(\.title) == ["More Like This"])
    }

    @Test func containerFallsBackToTheFileExtension() throws {
        let json = #"{"ratingKey":"1","title":"X","Media":[{"id":1,"container":"","Part":[{"id":2,"key":"/p","file":"/m/Movie.MKV"}]}]}"#
        let item = try decode(PlexMetadata.self, json)
        #expect(item.mediaContainer == "mkv")
        #expect(try decode(PlexMetadata.self, #"{"title":"Bare"}"#).mediaContainer == nil)
    }

    @Test func idFallsBackToKeyThenEmpty() throws {
        #expect(try decode(PlexMetadata.self, #"{"key":"/library/metadata/5","title":"A"}"#).id == "/library/metadata/5")
        #expect(try decode(PlexMetadata.self, #"{"title":"A"}"#).id == "")
        #expect(try decode(PlexMetadata.self, #"{"title":"A"}"#).mediaType == "unknown")
    }

    @Test func metadataEqualityFollowsIdentity() throws {
        let first = try decode(PlexMetadata.self, #"{"ratingKey":"1","title":"Old title"}"#)
        let renamed = try decode(PlexMetadata.self, #"{"ratingKey":"1","title":"New title"}"#)
        let other = try decode(PlexMetadata.self, #"{"ratingKey":"2","title":"Old title"}"#)
        #expect(first == renamed)
        #expect(first != other)
        #expect(Set([first, renamed, other]).count == 2)
    }

    @Test func homeCardSnapshotRoundTripsThroughMetadata() throws {
        let item = try #require(decode(PlexResponse.self, Self.hubsResponse).MediaContainer.Hub?.first?.Metadata?.first)
        let card = item.homeCard(bucket: "continue")
        #expect(card.ratingKey == "101")
        #expect(card.bucket == "continue")
        let restored = PlexMetadata(homeCard: card)
        #expect(restored.id == "101")
        #expect(restored.title == "Low Tide")
        #expect(restored.viewOffset == 600000)
        #expect(restored.Media == nil)
    }

    @Test func historyResponseToleratesLooseTypesAndMissingFields() throws {
        let json = #"""
        {"MediaContainer": {"totalSize": 3, "Metadata": [
            {"ratingKey": 55, "type": "movie", "title": "Numeric key", "viewedAt": "1700000000", "accountID": "1"},
            {"ratingKey": "56", "viewedAt": 1700000100, "parentIndex": "3", "index": 7},
            {"title": "Nothing else"}
        ]}}
        """#
        let container = try decode(PlexHistoryResponse.self, json).MediaContainer
        #expect(container.totalSize == 3)
        let entries = try #require(container.Metadata)
        #expect(entries.count == 3)
        #expect(entries[0].ratingKey == "55")
        #expect(entries[0].viewedAt == 1_700_000_000)
        #expect(entries[0].accountID == 1)
        #expect(entries[1].parentIndex == 3)
        #expect(entries[1].index == 7)
        #expect(entries[2].ratingKey == nil)
        #expect(entries[2].viewedAt == nil)
    }

    @Test func historyEntryLiftsIntoViewedMetadata() throws {
        let json = #"{"MediaContainer":{"Metadata":[{"ratingKey":"9","type":"episode","title":"Ep","grandparentTitle":"Show","viewedAt":5,"librarySectionID":3}]}}"#
        let entry = try #require(decode(PlexHistoryResponse.self, json).MediaContainer.Metadata?.first)
        let item = PlexMetadata(historyEntry: entry)
        #expect(item.id == "9")
        #expect(item.showName == "Show")
        #expect(item.viewCount == 1)
        #expect(item.librarySectionID == 3)
    }

    @Test func directoriesDecodeAndReportHiddenFlag() throws {
        let json = #"{"MediaContainer":{"size":2,"Directory":[{"key":"1","type":"movie","title":"Movies"},{"key":"2","type":"show","title":"Shows","hidden":2}]}}"#
        let directories = try #require(decode(PlexResponse.self, json).MediaContainer.Directory)
        #expect(directories.map(\.title) == ["Movies", "Shows"])
        #expect(!directories[0].isHiddenFromHome)
        #expect(directories[1].isHiddenFromHome)
    }

    @Test func pinResourceAndIdentityDecode() throws {
        let pin = try decode(PlexPin.self, #"{"id": 12, "code": "ABCD", "authToken": null, "expiresIn": 900}"#)
        #expect(pin.id == 12)
        #expect(pin.code == "ABCD")
        #expect(pin.authToken == nil)

        let resource = try decode(PlexResource.self, #"{"name":"Home","provides":"server,player","clientIdentifier":"abc","connections":[{"uri":"http://10.0.0.2:32400","local":true}]}"#)
        #expect(resource.provides.contains("server"))
        #expect(resource.connections.first?.local == true)
        #expect(resource.owned == nil)

        let identity = try decode(PlexIdentity.self, #"{"MediaContainer":{"machineIdentifier":"m1","version":"1.40.0"}}"#)
        #expect(identity.MediaContainer.machineIdentifier == "m1")
        #expect(identity.MediaContainer.version == "1.40.0")
    }

    @Test func streamEqualityIgnoresVolatileFields() throws {
        let selected = try decode(PlexStream.self, #"{"id":1,"streamType":2,"codec":"aac","selected":true}"#)
        let unselected = try decode(PlexStream.self, #"{"id":1,"streamType":2,"codec":"aac","selected":false}"#)
        #expect(selected == unselected)
    }

    @Test func apiErrorDescriptionsAreUserFacing() {
        #expect(APIError.unauthorized.errorDescription == "Authentication expired. Please sign in again.")
        #expect(APIError.httpError(statusCode: 404, message: "Not Found").errorDescription == "HTTP 404: Not Found")
        #expect(ConnectionError.message(for: APIError.timedOut) == APIError.timedOut.errorDescription)
        #expect(ConnectionError.message(for: URLError(.notConnectedToInternet)) == "No internet connection.")
        #expect(ConnectionError.message(for: URLError(.cannotFindHost)).hasPrefix("Couldn't find the server"))
    }
}
