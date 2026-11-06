import Testing

/// The suites that change the saved session (server, account and Plex Home profile, kept in the defaults and the keychain the
/// whole test process shares) run one at a time inside this one, so none of them sees another's half-made session.
@Suite(.serialized)
enum SavedSessionSuites {}
