# App Privacy answers (App Store Connect)

Crucible has no server of its own, no analytics and no ads. It talks to plex.tv and the user's Plex server, and checks Crucible Pro purchases through RevenueCat.

- Data collected: Purchases, Purchase History.
- Purpose: App Functionality (unlocking Crucible Pro and restoring it).
- Linked to the user: no (a random app user ID that is not tied to an Apple Account or a Plex account).
- Used for tracking: no.
- Everything else (contact info, identifiers, usage data, diagnostics, location): not collected. Crash and diagnostic logs stay on the device.

`docs/app-privacy.json` is the machine-readable form for `asc web privacy apply`. It matches the `PrivacyInfo.xcprivacy` that RevenueCat's SDK and the app bundle declare.
