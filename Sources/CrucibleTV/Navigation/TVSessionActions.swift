/// What a screen may ask of the running session. The scene coordinator implements it; screens reach
/// it through `TVAppEnvironment.session`.
@MainActor
protocol TVSessionActions: AnyObject {
    /// Presents server selection over the current UI and relaunches against the chosen server.
    func switchServer()

    /// Forgets the account and server, clears every per-account cache and returns to sign-in.
    /// Screens confirm with the user before calling this.
    func signOut()

    /// Ends the demo: stops its library, forgets its session, statistics and tour, and returns to the welcome screen. Screens confirm
    /// with the user before calling this.
    func leaveDemo()

    /// Re-runs the launch pipeline against the saved connection, for example after the saved
    /// route or server changed.
    func reconnect()
}
