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

    /// The tab and More split of the current libraries, recomputed on every read so it follows
    /// `LibraryVisibility`.
    var libraryLayout: LibraryTabLayout {
        LibraryTabLayout(directories: sections.Directory ?? [])
    }
}
