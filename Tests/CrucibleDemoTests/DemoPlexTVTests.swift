@testable import CrucibleCore
import Foundation
import Testing
@testable import CrucibleDemo

@Suite(.serialized)
struct DemoPlexTVTests {
    @Test func identityNamesTheServer() async throws {
        try await withDemo { demo in
            let (data, response) = try await demo.get("/identity")
            #expect(response.statusCode == 200)
            let identity = try JSONDecoder().decode(PlexIdentity.self, from: data)
            #expect(identity.MediaContainer.machineIdentifier == demo.endpoint.machineIdentifier)
            #expect(identity.MediaContainer.machineIdentifier?.isEmpty == false)
            #expect(await APIClient.probe(baseURL: demo.base, token: demo.endpoint.token))
        }
    }

    @Test func pinLinkResourcesUserAndRouteDiscoveryAnswerThroughTheHostOverride() async throws {
        try await withDemo { demo in
            PlexTVHost.setOverride(demo.endpoint.plexTVURL)
            defer { PlexTVHost.setOverride(nil) }

            let pin: PlexPin = try await APIClient.plexTVRequest(.requestPin(strong: false))
            #expect(pin.code.count == 4)
            #expect(pin.authToken == nil)
            let strong: PlexPin = try await APIClient.plexTVRequest(.requestPin(strong: true))
            #expect(strong.code.count == 24)
            let approved: PlexPin = try await APIClient.plexTVRequest(.checkPin(pinId: pin.id))
            #expect(approved.authToken == "demo-token")

            let resources: [PlexResource] = try await APIClient.plexTVRequest(.resources, token: "demo-token")
            let server = try #require(resources.first { $0.provides.contains("server") })
            #expect(server.name == "Crucible Demo")
            #expect(server.clientIdentifier == demo.endpoint.machineIdentifier)
            #expect(server.connections.first?.uri == demo.endpoint.serverURL.absoluteString)
            #expect(server.owned == true)

            let urls = resources.flatMap(\.connections).compactMap { URL(string: $0.uri) }
            #expect(await ServerConnectionResolver.firstReachable(urls, token: demo.endpoint.token) == demo.endpoint.serverURL)

            #expect(await PlexTokenCheck.isRejected(token: "demo-token") == false)
            await PlexAccountName.refresh(token: "demo-token")
            #expect(UserDefaults.standard.string(forKey: PlexAccountName.defaultsKey) == "Demo")
        }
    }
}
