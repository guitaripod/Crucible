# Integrations: Crucible as the hub of a Plex setup

Crucible plays what is on the server. Integrations connect it to everything around the server: where the viewer tracks what they watch, where they ask for what is missing, what is on its way, and what the household watched. Each integration is an opt-in plugin under Settings › Integrations (`CrucibleCore/Features/Integrations`), sends nothing until connected, and lives on iPhone, iPad and Apple TV. Trakt is the first (`docs/TRAKT.md`). Research behind this page, read on the services' own pages on 2026-11-08: `~/Documents/crucible-trakt-research/landscape/services.json`.

## Which services, and why

| Plugin | Role | Access and cost | Paid-app terms | Order |
| --- | --- | --- | --- | --- |
| Trakt | Tracking, discovery, social | Free Standard API; Premium $149/month only for higher limits, Limited Access endpoints and the per-user app cap | Paid apps allowed, no approval, no revenue share | Built (slices 1-2) |
| Seerr (Overseerr and Jellyseerr, merged) | Ask for a title that is not on the server, see its request state | Self-hosted, free; Plex sign-in (`POST /api/v1/auth/plex` with the token Crucible already holds) or API key | MIT | Built (2.9.0) |
| Sonarr and Radarr | What is coming and downloading: calendar, queue, history | Self-hosted, free; API key | GPL-3.0 servers, called over HTTP | Next |
| Tautulli | Every play on the server from every app, home stats | Self-hosted, free; API key | GPL-3.0 server | After Sonarr/Radarr |
| Simkl | Second tracker, strong on anime | Free key, no approval | Free under $150/month app revenue, then a commercial licence; a tracker that syncs another tracker must also offer Simkl sync | After Trakt sync |
| AniList | Anime lists | Free, OAuth | Free under $150/month, then a licence | With Simkl |

Not integrated: TMDB (commercial use needs a written agreement), TVDB (licence or a per-user PIN), Letterboxd (API by request, not for paid-tier features), Serializd, TV Time, Hobi, Sequel and Callsheet (no API), JustWatch (partners only), Watchmode ($349/month for commercial use), OMDb (CC BY-NC), MyAnimeList and Kitsu (terms unread or non-commercial), MDBList and Movie of the Night (no commercial terms found; ask before use). Self-hosted trackers (Ryot, Movary, Yamtrack) are a later "bring your own tracker" option.

## How they tie together

The hub is one idea seen everywhere: every title Crucible shows knows where it stands across the connected services.

- **Availability on every card**: on Nimbus (play), requested (Seerr), downloading 42% (Sonarr/Radarr queue), coming Thursday (Sonarr calendar), or elsewhere (Trakt).
- **A title not on the server** (from Trakt, the Plex watchlist, search or a recommendation) gets **Request** when Seerr is connected, then shows Requested, Approved, Downloading and finally Play, and a notification says when it arrives.
- **One calendar**: Trakt's airing episodes and Sonarr's and Radarr's upcoming downloads in one agenda, each entry saying whether it will land on the server.
- **One history**: Statistics and Year in Review count plays from every Plex app (Tautulli) and from outside Plex (Trakt), each labelled by source.
- **Up Next everywhere**: Trakt progress plus Plex On Deck, with Seerr requests for the next season.

## Money

Free features bring downloads; Pro features turn them into revenue. The rule stays the one Trakt follows: free sends and connects, Pro brings data in and joins services together.

| Free | Crucible Pro |
| --- | --- |
| Connect any integration | Two-way Trakt sync, Simkl and AniList sync |
| Trakt and Simkl scrobbling, ratings and check-ins sent | The Trakt tab, Up Next everywhere, Home rows |
| Request a title through Seerr, its request state and download progress, your own requests | Manage Requests: approve, decline and retry everyone's requests |
| Ratings strip on every page | One calendar across Trakt, Sonarr and Radarr, downloading and coming-soon on cards |
| | Statistics and Year in Review across every app (Tautulli, Trakt) |

The free Request button is the download driver: Plex owners who run Seerr look for a client that requests and plays in one place. The paywall leads with what only the hub can do: "Everything about your server in one place".

## Store and marketing

Third-party names stay out of the app name, subtitle and keywords (Apple 5.2.5); they go in the description ("Works with Trakt, Overseerr, Jellyseerr, Sonarr, Radarr and Tautulli") with each required attribution line, in What's New and in screenshot captions. Every integration release gets its claims table in `docs/marketing-<version>.md`, the App Privacy answers it needs (Trakt and Simkl are outside services; Seerr, Sonarr, Radarr and Tautulli run on the viewer's own servers, like Plex) and its privacy-policy section.

## Seerr as built (2.9.0)

`CrucibleCore/Features/Seerr`, with the iPhone and iPad screens in `Sources/Crucible/Seerr` and Apple TV's in `Sources/CrucibleTV/Settings/TVSeerr*`.

- **Connecting**: Settings › Integrations › Seerr looks for Seerr on port 5055 of every home-network address the Plex server answers at (a `plex.direct` name gives its address away), probes `GET /api/v1/status` and `/settings/public` (a Jellyfin or Emby setup is refused), and signs in with the viewer's own plex.tv token (`POST /auth/plex`), so connecting is one click on Apple TV. An address can be typed (port 5055 and https are tried when none is given, a reverse-proxy path is kept), and an API key is the fallback when Plex sign-in is off (requests are then made as Seerr's administrator). Each Plex account and Home profile connects its own; restricted profiles cannot.
- **Session**: the client keeps Seerr's cookies itself, per viewer and server (Keychain), signs in again once with the Plex token when Seerr answers 401/403, and answers Seerr's optional cross-site check (`XSRF-TOKEN` cookie echoed as `X-XSRF-TOKEN`).
- **Matching**: TMDB ids only. A server title's `tmdb://` guid comes from its full record; a watchlist title the server lacks is looked up in Plex's own catalogue (`discover.provider.plex.tv/library/metadata/<key>`), the way Seerr's own watchlist sync does it.
- **Where it shows**: a watchlist title the server lacks opens the Request sheet (without Seerr, the old "Not in Your Library" alert gains Set Up Requests); a show missing seasons gets Request More Seasons (iPhone More menu, Apple TV action row); You gets Requests once connected. The sheet shows availability (not requested, awaiting approval, approved, downloading with percent and finish time from Sonarr/Radarr via Seerr, partly or fully on the server, declined, failed, blocklisted), each season's state, Withdraw for the viewer's own pending request and Play once Seerr reports the Plex rating key. Requesting a title the server lacks also adds it to the Plex watchlist, so the free Watchlist Arrivals notification says when it lands.
- **Pro**: `ProFeature.manageRequests` (approve, decline, retry everyone's requests); listed on the paywall only for someone who manages requests on a connected Seerr or reached for it.
- **Demo**: the demo serves a stand-in Seerr under `/seerr` of its own address (titles off the server, Sam's pending request, a download at 62%, one season missing on every library show), so UI tests and store captures need no Seerr.
- **Privacy**: Seerr runs on the viewer's own server, like Plex; Crucible sends it the viewer's plex.tv token at sign-in and the titles they request. Nothing goes to Midgar or any outside service, so the App Privacy label does not change.

