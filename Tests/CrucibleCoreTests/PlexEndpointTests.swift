import Foundation
import Testing
@testable import CrucibleCore

struct PlexEndpointTests {
    private let server = URL(string: "http://192.168.1.5:32400")!

    private func request(_ endpoint: PlexEndpoint, base: URL? = nil, token: String? = "tok") throws -> URLRequest {
        try endpoint.urlRequest(baseURL: base ?? server, token: token)
    }

    @Test func metadataRequestAsksForMarkersAndRelatedItems() throws {
        let request = try request(.metadata(ratingKey: "42"))
        #expect(request.url?.absoluteString == "http://192.168.1.5:32400/library/metadata/42?includeMarkers=1&includeRelated=1&includeRelatedCount=10")
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 15)
        #expect(request.httpBody == nil)
    }

    @Test func requestsCarryPlexHeadersAndToken() throws {
        let request = try request(.identity, token: "secret")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Product") == "Crucible")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Platform") == AppPlatform.plexName)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier")?.isEmpty == false)
    }

    @Test func missingTokenOmitsTheTokenHeader() throws {
        let request = try request(.identity, token: nil)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == nil)
    }

    @Test func trailingSlashesOnTheBaseAreTrimmed() throws {
        let request = try request(.sections, base: URL(string: "http://192.168.1.5:32400///")!)
        #expect(request.url?.absoluteString == "http://192.168.1.5:32400/library/sections")
    }

    @Test func plexTvEndpointsIgnoreTheServerBase() throws {
        let resources = try request(.resources)
        #expect(resources.url?.absoluteString == "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")
        let check = try request(.checkPin(pinId: 77))
        #expect(check.url?.absoluteString == "https://clients.plex.tv/api/v2/pins/77")
        #expect(check.httpMethod == "GET")
    }

    @Test func requestPinPostsAFormBody() throws {
        let request = try request(.requestPin, token: nil)
        #expect(request.url?.absoluteString == "https://clients.plex.tv/api/v2/pins")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.hasPrefix("strong=true&X-Plex-Product=Crucible&X-Plex-Client-Identifier="))
        #expect(body.count > "strong=true&X-Plex-Product=Crucible&X-Plex-Client-Identifier=".count)
    }

    @Test func plusSignsInQueriesAreEscaped() throws {
        let request = try request(.search(query: "a+b c&d"))
        let url = try #require(request.url?.absoluteString)
        #expect(url.contains("query=a%2Bb%20c%26d"))
        #expect(url.hasPrefix("http://192.168.1.5:32400/hubs/search?"))
        #expect(!url.contains("+"))
    }

    @Test func sectionItemsQueryHonoursFilters() throws {
        let plain = PlexEndpoint.sectionItems(sectionId: "3")
        #expect(plain.path == "/library/sections/3/all")
        #expect(plain.queryItems == [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "50"),
        ])

        let filtered = PlexEndpoint.sectionItems(sectionId: "3", sort: "titleSort", genre: "12", start: 100, size: 25, unwatched: true, inProgress: true)
        #expect(filtered.queryItems?.map(\.name) == ["X-Plex-Container-Start", "X-Plex-Container-Size", "sort", "genre", "unwatched", "inProgress"])
        #expect(filtered.queryItems?.first(where: { $0.name == "X-Plex-Container-Start" })?.value == "100")
        #expect(filtered.queryItems?.first(where: { $0.name == "genre" })?.value == "12")
    }

    @Test func historyDefaultsToNewestFirst() {
        let endpoint = PlexEndpoint.history()
        #expect(endpoint.path == "/status/sessions/history/all")
        #expect(endpoint.queryItems?.contains(URLQueryItem(name: "sort", value: "viewedAt:desc")) == true)
        let unsorted = PlexEndpoint.history(start: 10, size: 20, sort: nil)
        #expect(unsorted.queryItems?.map(\.name) == ["X-Plex-Container-Start", "X-Plex-Container-Size"])
    }

    @Test func reportingEndpointsUseShortTimeoutsAndRightVerbs() throws {
        let timeline = try request(.timeline(ratingKey: "5", state: "playing", timeMs: 1000, durationMs: 9000))
        #expect(timeline.timeoutInterval == 10)
        #expect(timeline.url?.path == "/:/timeline")
        let items = URLComponents(url: try #require(timeline.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first(where: { $0.name == "key" })?.value == "/library/metadata/5")
        #expect(items?.first(where: { $0.name == "state" })?.value == "playing")

        let stop = try request(.stopTranscode(session: "abc"))
        #expect(stop.httpMethod == "DELETE")
        #expect(stop.url?.query == "session=abc")
    }

    @Test func endpointsWithoutQueryItemsProduceNoQuery() throws {
        let request = try request(.onDeck)
        #expect(request.url?.absoluteString == "http://192.168.1.5:32400/library/onDeck")
        #expect(PlexEndpoint.onDeck.queryItems == nil)
    }

    @Test func hubsCountIsConfigurable() {
        #expect(PlexEndpoint.hubs().queryItems == [URLQueryItem(name: "count", value: "20")])
        #expect(PlexEndpoint.hubs(count: 5).queryItems == [URLQueryItem(name: "count", value: "5")])
    }

    @Test func scrobbleAndUnscrobbleShareTheLibraryIdentifier() {
        for endpoint in [PlexEndpoint.scrobble(ratingKey: "9"), PlexEndpoint.unscrobble(ratingKey: "9")] {
            #expect(endpoint.queryItems == [
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "key", value: "9"),
            ])
        }
        #expect(PlexEndpoint.scrobble(ratingKey: "9").path == "/:/scrobble")
        #expect(PlexEndpoint.unscrobble(ratingKey: "9").path == "/:/unscrobble")
    }
}

@Suite(.serialized)
struct PlexHeadersTests {
    private func withSimulatorModel<T>(_ value: String?, _ body: () -> T) -> T {
        let key = "SIMULATOR_MODEL_IDENTIFIER"
        let previous = ProcessInfo.processInfo.environment[key]
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        return body()
    }

    @Test func simulatorModelIdentifierIsReportedAsTheDevice() {
        let device = withSimulatorModel("AppleTV14,1") { PlexHeaders.allHeaders(token: nil)["X-Plex-Device"] }
        #expect(device == "AppleTV14,1")
    }

    @Test func deviceFallsBackToMachineModelWithoutSimulator() {
        let device = withSimulatorModel(nil) { PlexHeaders.allHeaders(token: nil)["X-Plex-Device"] }
        #expect(device?.isEmpty == false)
    }

    @Test func platformComesFromAppPlatform() {
        let headers = PlexHeaders.allHeaders(token: "t")
        #expect(headers["X-Plex-Platform"] == AppPlatform.plexName)
        #expect(headers["X-Plex-Token"] == "t")
        #expect(headers["X-Plex-Product"] == "Crucible")
        #expect(headers["X-Plex-Platform-Version"]?.isEmpty == false)
    }
}
