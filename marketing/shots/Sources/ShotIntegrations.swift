import Foundation
@testable import CrucibleCore
#if canImport(CrucibleDemo)
import CrucibleDemo
#endif

/// Connects Trakt and Seerr before the store captures, so every screen shows what the integrations add: Trakt's score in the
/// ratings strip, Everything in Statistics and Seerr's titles in Search. Both answer from the demo's stand-ins, served by a demo
/// library started beside the mock Plex server; the mock carries the IMDb and TMDB ids the stand-ins know its titles by.
/// `CRUCIBLE_SHOT_INTEGRATIONS=0` captures without them.
@MainActor
enum ShotIntegrations {
    #if canImport(CrucibleDemo)
    private static let standIns = DemoLibraryProvider()
    #endif

    static var isWanted: Bool {
        ProcessInfo.processInfo.environment["CRUCIBLE_SHOT_INTEGRATIONS"] != "0"
    }

    static func connect() async {
        #if canImport(CrucibleDemo)
        guard isWanted, let endpoint = try? await standIns.start() else { return }
        TraktConfig.setOverride(endpoint.plexTVURL)
        SeerrConfig.setStandIn(endpoint.serverURL.appendingPathComponent("seerr"))
        await connectTrakt()
        await connectSeerr()
        #endif
    }

    private static func connectTrakt() async {
        let created = Int(Date().timeIntervalSince1970)
        let json = #"{"access_token":"demo-trakt","refresh_token":"demo-trakt-refresh","expires_in":604800,"created_at":\#(created)}"#
        guard let token = try? JSONDecoder().decode(TraktToken.self, from: Data(json.utf8)) else { return }
        await TraktAccount.shared.connect(with: token)
    }

    private static func connectSeerr() async {
        guard let (address, settings) = await SeerrAccount.shared.discover(serverRoutes: []) else { return }
        try? await SeerrAccount.shared.connect(address: address, settings: settings)
    }
}
