@testable import CrucibleCore
import Foundation
import Testing
@testable import CrucibleDemo

/// The demo account's Plex Home: the owner, Sam with a PIN and a managed Kids profile, each with a library of their own behind
/// the one server, so every kind of viewer can be tried in the demo. These talk to the plex.tv stand-in directly, because the
/// app's own plex.tv host is shared by every test running at the same time.
@Suite(.serialized)
struct DemoHomeTests {
    private func api(_ demo: DemoHarness, as member: DemoHome.Member) -> APIClient {
        APIClient(baseURL: demo.base, token: member.serverToken)
    }

    private func plexTV<T: Decodable>(_ demo: DemoHarness, _ path: String, token: String, method: String = "GET", form: String? = nil) async throws -> (T?, Int) {
        var request = URLRequest(url: demo.url(path))
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try #require(response as? HTTPURLResponse).statusCode
        return (try? JSONDecoder().decode(T.self, from: data), status)
    }

    private struct Switched: Decodable {
        let authToken: String?
    }

    private struct Account: Decodable {
        let uuid: String?
    }

    @Test func theHomeListsTheOwnerSamAndKids() async throws {
        try await withDemo { demo in
            let (home, status): (HomeUsersResponse?, Int) = try await plexTV(demo, "/api/v2/home/users", token: demo.endpoint.token)
            #expect(status == 200)
            let profiles = try #require(home).users.compactMap(\.profile)
            #expect(profiles.map(\.title) == ["Demo", "Sam", "Kids"])
            #expect(profiles.map(\.isAdmin) == [true, false, false])
            #expect(profiles.map(\.isProtected) == [false, true, false])
            #expect(profiles.map(\.isRestricted) == [false, false, true])
            let (account, _): (Account?, Int) = try await plexTV(demo, "/api/v2/user", token: demo.endpoint.token)
            #expect(account?.uuid == DemoHome.owner.uuid)
        }
    }

    @Test func samsPINIsCheckedAndEachSwitchHandsOutThatMembersToken() async throws {
        try await withDemo { demo in
            let path = "/api/v2/home/users/\(DemoHome.sam.uuid)/switch"
            let (_, wrong): (Switched?, Int) = try await plexTV(demo, path, token: demo.endpoint.token, method: "POST", form: "pin=0000")
            #expect(wrong == 403)
            let (_, missing): (Switched?, Int) = try await plexTV(demo, path, token: demo.endpoint.token, method: "POST")
            #expect(missing == 403)
            let (sam, right): (Switched?, Int) = try await plexTV(demo, path, token: demo.endpoint.token, method: "POST", form: "pin=1234")
            #expect(right == 201)
            #expect(sam?.authToken == DemoHome.sam.plexTVToken)
            let (kids, _): (Switched?, Int) = try await plexTV(demo, "/api/v2/home/users/\(DemoHome.kids.uuid)/switch", token: demo.endpoint.token, method: "POST")
            #expect(kids?.authToken == DemoHome.kids.plexTVToken)
            let (owner, _): (Switched?, Int) = try await plexTV(demo, "/api/v2/home/users/\(DemoHome.owner.uuid)/switch", token: demo.endpoint.token, method: "POST")
            #expect(owner?.authToken == demo.endpoint.token)
            let (who, _): (Account?, Int) = try await plexTV(demo, "/api/v2/user", token: DemoHome.kids.plexTVToken)
            #expect(who?.uuid == DemoHome.kids.uuid)
        }
    }

    @Test func aMemberSeesTheServerAsSharedAndTheOwnerAsOwned() async throws {
        try await withDemo { demo in
            let (shared, _): ([PlexResource]?, Int) = try await plexTV(demo, "/api/v2/resources", token: DemoHome.kids.plexTVToken)
            let server = try #require(shared?.first { $0.clientIdentifier == demo.endpoint.machineIdentifier })
            #expect(server.owned == false)
            #expect(server.accessToken == DemoHome.kids.serverToken)
            let (owned, _): ([PlexResource]?, Int) = try await plexTV(demo, "/api/v2/resources", token: demo.endpoint.token)
            #expect(owned?.first?.owned == true)
        }
    }

    @Test func kidsSeeOnlyFamilyTitlesAndNoneOfTheOthers() async throws {
        try await withDemo { demo in
            let kids = api(demo, as: DemoHome.kids)
            var kidsTitles: [PlexMetadata] = []
            var ownerTitles: [PlexMetadata] = []
            for section in ["1", "2", "3"] {
                kidsTitles += try await kids.requestContainer(.sectionItems(sectionId: section, size: 200)).Metadata ?? []
                ownerTitles += try await demo.api.requestContainer(.sectionItems(sectionId: section, size: 200)).Metadata ?? []
            }
            #expect(!kidsTitles.isEmpty)
            #expect(kidsTitles.count < ownerTitles.count)
            #expect(kidsTitles.allSatisfy { DemoHome.familyRatings.contains($0.contentRating ?? "") })
            let adult = try #require(ownerTitles.first { !DemoHome.familyRatings.contains($0.contentRating ?? "") })
            let adultKey = try #require(adult.ratingKey)
            await #expect(throws: (any Error).self) {
                _ = try await kids.requestContainer(.metadata(ratingKey: adultKey))
            }
            let search = try await kids.requestContainer(.search(query: adult.title)).Hub ?? []
            #expect(!search.flatMap { $0.Metadata ?? [] }.contains { $0.ratingKey == adultKey })
        }
    }

    @Test func samStartsWithNothingWatchedAndWatchingStaysSams() async throws {
        try await withDemo { demo in
            let sam = api(demo, as: DemoHome.sam)
            let ownerDeck = try await demo.api.requestContainer(.onDeck).Metadata ?? []
            #expect(!ownerDeck.isEmpty)
            #expect((try await sam.requestContainer(.onDeck).Metadata ?? []).isEmpty)
            #expect((try await sam.requestContainer(.history(start: 0, size: 20)).Metadata ?? []).isEmpty)
            #expect((try await sam.requestContainer(.playlists).Metadata ?? []).isEmpty)

            let ownerFilm = try await demo.metadata("1008")
            try await sam.requestConfirmed(.scrobble(ratingKey: "1008"))
            await sam.invalidateCache()
            let samsFilm = try #require(try await sam.requestContainer(.metadata(ratingKey: "1008")).Metadata?.first)
            #expect((samsFilm.viewCount ?? 0) > 0)
            #expect(try await demo.metadata("1008").viewCount == ownerFilm.viewCount)
        }
    }

    @Test func aMembersWatchStateIsKeptInAFileOfItsOwn() async throws {
        let stateFile = DemoHarness.temporaryStateFile()
        try await withDemo(stateFile: stateFile) { demo in
            try await api(demo, as: DemoHome.sam).requestConfirmed(.scrobble(ratingKey: "1008"))
        }
        let samsFile = try #require(DemoHome.stateFileURL(for: DemoHome.sam, ownerFile: stateFile))
        #expect(FileManager.default.fileExists(atPath: samsFile.path))
        try await withDemo(stateFile: stateFile) { demo in
            let sam = api(demo, as: DemoHome.sam)
            let film = try #require(try await sam.requestContainer(.metadata(ratingKey: "1008")).Metadata?.first)
            #expect((film.viewCount ?? 0) > 0)
        }
    }
}

extension DemoPlexTVTests {
    /// The app's own switch, through the plex.tv host it uses, maps a wrong PIN to its PIN error. It runs with the other plex.tv
    /// tests, one at a time, since they all move that host.
    @Test func theAppsSwitchSaysAWrongPINIsWrong() async throws {
        try await withDemo { demo in
            PlexTVHost.setOverride(demo.endpoint.plexTVURL)
            defer { PlexTVHost.setOverride(nil) }
            let sam = HomeProfile(id: DemoHome.sam.uuid, title: "Sam", thumb: nil, isAdmin: false, isProtected: true, isRestricted: false)
            await #expect(throws: HomeProfiles.SwitchError.wrongPIN) {
                try await HomeProfiles.switchTo(sam, pin: "0000", isAccount: false, accountToken: demo.endpoint.token, machineIdentifier: demo.endpoint.machineIdentifier)
            }
        }
    }
}
