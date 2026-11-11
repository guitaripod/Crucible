# App Privacy answers (App Store Connect)

Crucible has no analytics, no ads and no sign-up. It talks to plex.tv and the user's Plex server, and from version 2.4 keeps Crucible Pro purchases in Midgar's purchase ledger with an anonymous Midgar ID (MidgarKit). This replaces the earlier label, "Purchases, Purchase History, not linked", which held while RevenueCat checked purchases with a random app user ID.

| Data type (Apple) | Linked | Tracking | Purpose | What it is in Crucible |
| --- | --- | --- | --- | --- |
| Identifiers, User ID | Yes | No | App Functionality | The random Midgar ID, sent as the sign-in token to `api.midgarcorp.cc` for the purchase ledger and carried by purchases as Apple's app account token |
| Identifiers, Device ID | Yes | No | App Functionality | MidgarKit's App Attest key id on iPhone, stored with the Midgar ID when it is created or joined; no advertising or vendor identifier |
| Purchases, Purchase History | Yes | No | App Functionality | The App Store transactions of Crucible Pro (lifetime, yearly), sent to the Midgar ledger with the Midgar ID |
| Usage Data, Product Interaction | Yes | No | App Functionality | From 2.9, only once the viewer connects Trakt: what they play (scrobbles), mark watched and check in to, sent to their Trakt account by title id |
| User Content, Other User Content | Yes | No | App Functionality | From 2.9, only once the viewer connects Trakt: the ratings they give titles, sent to their Trakt account |

Everything else (contact info, location, diagnostics, other usage data and user content) is not collected. Seerr is the viewer's own server, like Plex, so the titles they request through it are not collected. The diagnostic log stays on the device unless the user exports it.

`docs/app-privacy.json` is the machine-readable form for `asc web privacy plan`, `apply` and `publish`. It matches the `PrivacyInfo.xcprivacy` files of both apps.
