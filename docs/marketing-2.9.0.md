# Marketing 2.9.0

The release that makes Crucible the hub of a Plex setup: Trakt records and scores what you watch, and Seerr (with
Overseerr and Jellyseerr) asks for what your server does not have, then shows it downloading and ready to play. Both
are opt-in under Settings › Integrations and send nothing until connected. The story for the listing: "Everything
about your server in one place".

## What the release says, and where it is true

| Claim in the listing or What's New | Where the build does it |
| --- | --- |
| Connect Trakt with a code, or a QR code on Apple TV; nothing is sent before | `TraktLinkSession`, `TraktConnectViewController`, `TVTraktLinkViewController`; `IntegrationPlugin.isActive`; `TraktTests` (iOS and tvOS UI) |
| What you play is scrobbled as it plays, downloads too once you are online | `TraktScrobbleWatcher`, `TraktOutbox`; `TraktTests` (Core) |
| Mark Watched, ratings and check-ins go to Trakt | `TraktPlugin.watchedChanged/ratingChanged`, `TraktCheckin` |
| Every title shows Trakt beside IMDb, TMDB, Rotten Tomatoes, Metacritic, Letterboxd and MyAnimeList | `TraktScores`, `TraktScoreTile`; ratings strip on iPhone, iPad and Apple TV detail pages |
| Nothing counts twice when Trakt's own Plex sync runs | `TraktAccount.traktRecordsPlexPlays`, the double-play question, Another App Records My Plays |
| Crucible finds your Seerr next to your Plex server and signs in with your Plex account | `SeerrDiscovery.candidates` (port 5055 on the server's home addresses), `SeerrClient.signIn` (`POST /api/v1/auth/plex`); `SeerrTests`, `DemoSeerrTests`, iOS and tvOS `SeerrTests` |
| Request a watchlist title your server lacks, or the seasons a show is missing | `SeerrRequestViewController`, `TVSeerrRequestViewController`, `SeerrPhoneActions.requestMoreSeasons`, Apple TV `.request` action |
| See it go from awaiting approval to downloading (with percent and finish time) to Play | `SeerrAvailability(media:)` reads Seerr's `downloadStatus` and `ratingKey`; `SeerrCopy.label/detail` |
| Requests join your Plex watchlist, so you hear when they land | `SeerrRequestViewController.addToWatchlist`; the existing free Watchlist Arrivals notification |
| With Crucible Pro, approve, decline and retry the household's requests from the couch | `ProFeature.manageRequests`, `SeerrRequests.decide/retry`, Requests screen on iPhone, iPad and Apple TV |

## Money

- Free: connecting both, scrobbling, sent changes, check-ins, the ratings strip, requesting and request state. These
  are the download drivers: Plex owners who run Seerr look for one app that requests and plays.
- Pro: Manage Requests (new, listed on the paywall only for someone who approves requests on a connected Seerr), on
  top of the existing Pro features. Trakt's Pro slice (two-way sync, the Trakt tab, Up Next everywhere) is next.

## Listing (to stage at release)

- Description: a new section, "YOUR WHOLE PLEX SETUP", after "PICK UP WHERE YOU LEFT OFF": "Connect Trakt to scrobble
  what you watch and see its score beside IMDb and Rotten Tomatoes on every title. Connect Seerr, Overseerr or
  Jellyseerr and request what your server doesn't have, watch it download, then play it. Both stay off until you
  connect them." Then the attribution line "Crucible uses Trakt but is not endorsed or certified by Trakt."
- Third-party names stay out of the name, subtitle and keywords (App Review 5.2.5); they appear in the description,
  What's New and captions.
- What's New (en-US draft): "Trakt and Seerr, built in and off until you connect them. Trakt: scrobble what you
  play, send what you mark watched, your ratings and check-ins, and see Trakt's score beside IMDb, Rotten Tomatoes
  and Letterboxd on every title. Seerr, Overseerr and Jellyseerr: Crucible finds your Seerr and signs in with Plex;
  request a watchlist title your server lacks or a show's missing seasons, watch it download, then play it. With
  Crucible Pro, approve and decline your household's requests from the couch." Translate into all seventeen
  listing languages when the version is created.
- Screenshots: two new iPhone and iPad panels (the Request sheet downloading, the ratings strip) and one Apple TV
  panel (Seerr found, one click); captures come from `ios/UITests/SeerrTests` and `TraktTests` in the demo, then
  `marketing/store/compose.py`.

## Privacy

- Seerr runs on the viewer's own server, like Plex; Crucible sends it the viewer's plex.tv token at sign-in and the
  titles they request, nothing to Midgar or any outside service. The App Privacy label does not change for Seerr.
- Trakt is an outside service the viewer connects: the label and the policy need a Trakt section before the store
  release (decision D3 in `docs/TRAKT.md`).

## Open before review

- D1 Trakt Developer Premium, D2 prices, D3 App Privacy and policy text, D4 the Trakt tab placement (`docs/TRAKT.md`).
- Trakt production access (the developer app works only for its owner and allow-listed accounts).
