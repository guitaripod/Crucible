/// Why onboarding is on screen.
enum TVOnboardingMode: Sendable {
    /// No account is saved: the root of the app until a server is connected.
    case signIn

    /// The user is already signed in and chose Switch Server: presented full screen over the
    /// current UI, dismissed by Back without changes, relaunches the app once a server is chosen.
    case switchServer
}
