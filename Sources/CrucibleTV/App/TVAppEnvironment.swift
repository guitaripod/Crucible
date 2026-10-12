import CrucibleCore

/// The immutable context handed to every screen factory: the API client bound to the validated
/// route, the launch payload, and the two seams back into the app (navigation and the session).
struct TVAppEnvironment {
    let payload: LaunchPayload
    let router: TVRouter
    let session: any TVSessionActions

    var api: APIClient { payload.api }
    var connection: PlexConnection { payload.connection }
    var hubs: PlexMediaContainer { payload.hubs }
    var sections: PlexMediaContainer { payload.sections }

    /// The tab and More split of the server's movie and show libraries.
    var libraryLayout: LibraryTabLayout {
        LibraryTabLayout(directories: sections.Directory ?? [], limit: Self.libraryTabLimit)
    }

    /// Home, Search and You take three tabs of their own. tvOS 26 packs seven tabs into its bar; tvOS
    /// 18.6 clips the seventh (You vanished from the bar), so older systems get one library tab fewer.
    private static var libraryTabLimit: Int {
        if #available(tvOS 26.0, *) { return LibraryTabLayout.defaultLimit }
        return LibraryTabLayout.defaultLimit - 1
    }
}
