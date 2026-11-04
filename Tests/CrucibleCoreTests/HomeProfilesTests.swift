import Foundation
import Testing
@testable import CrucibleCore

@Suite(.serialized)
struct HomeProfilesTests {
    @Test func theHomeListsEveryProfileWithItsPINAndRestrictions() throws {
        let json = #"""
        {"id":7,"name":"Home","users":[
         {"id":1,"uuid":"owner-1","title":"Marcus","username":"marcus","admin":true,"protected":false,"restricted":false},
         {"id":31,"uuid":"kids-31","title":"","username":"","admin":false,"protected":0,"restricted":1},
         {"id":32,"uuid":"sam-32","title":"Sam","admin":false,"protected":true,"restricted":false,"hasPassword":true},
         {"id":33,"title":"No uuid"}
        ]}
        """#
        let response = try JSONDecoder().decode(HomeUsersResponse.self, from: Data(json.utf8))
        let profiles = response.users.compactMap(\.profile)
        #expect(profiles.map(\.id) == ["owner-1", "kids-31", "sam-32"])
        #expect(profiles[0].isAdmin && !profiles[0].isProtected)
        #expect(profiles[0].detail == "Owner")
        #expect(profiles[1].title == PlexAccountName.fallbackName)
        #expect(profiles[1].isRestricted && !profiles[1].isProtected)
        #expect(profiles[1].detail == "Managed")
        #expect(profiles[2].isProtected && profiles[2].detail == nil)
    }

    @Test func thePINIsSentEncodedWithTheClient() {
        let body = PlexEndpoint.switchFormBody(pin: "12&4")
        #expect(body.hasPrefix("pin=12%264&X-Plex-Client-Identifier="))
        #expect(!PlexEndpoint.switchFormBody(pin: nil).contains("pin="))
        #expect(PlexEndpoint.switchHomeUser(uuid: "sam-32", pin: "1234").path == "/api/v2/home/users/sam-32/switch")
        #expect(PlexEndpoint.homeUsers.isPlexTV && PlexEndpoint.switchHomeUser(uuid: "x", pin: nil).isPlexTV)
    }

    @MainActor
    @Test func aProfileOtherThanTheOwnersNeverGetsTheOwnersTools() throws {
        let machine = "home-profiles-test-machine"
        ServerOwnership.setForTesting(true, machineIdentifier: machine)
        defer { HomeProfiles.forgetProfile() }
        #expect(ServerOwnership.isOwner(machineIdentifier: machine))
        HomeProfiles.activate(HomeProfile(id: "kids-31", title: "Kids", thumb: nil, isAdmin: false, isProtected: false, isRestricted: true), serverToken: "s", plexTVToken: "p")
        #expect(HomeProfiles.active?.title == "Kids")
        #expect(PlexAccountName.stored == "Kids")
        #expect(!ServerOwnership.isOwner(machineIdentifier: machine))
        HomeProfiles.activate(HomeProfile(id: "owner-1", title: "Marcus", thumb: nil, isAdmin: true, isProtected: true, isRestricted: false), serverToken: "s", plexTVToken: "p")
        #expect(ServerOwnership.isOwner(machineIdentifier: machine))
        HomeProfiles.forgetProfile()
        #expect(HomeProfiles.active == nil)
        #expect(HomeProfiles.activeServerToken == nil)
        #expect(ServerOwnership.isOwner(machineIdentifier: machine))
    }

    @Test func aConnectionKeepsTheServerTokenAndThePlexTVTokenApart() {
        let plain = PlexConnection(serverURI: URL(string: "http://a")!, serverName: "A", machineIdentifier: "m", authToken: "t", clientIdentifier: "c")
        #expect(plain.plexTVToken == "t")
        let profile = PlexConnection(serverURI: URL(string: "http://a")!, serverName: "A", machineIdentifier: "m", authToken: "server", plexTVToken: "plextv", clientIdentifier: "c")
        #expect(profile.authToken == "server" && profile.plexTVToken == "plextv")
    }
}
