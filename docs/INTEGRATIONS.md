# Integrations: Crucible as the hub of a Plex setup

Crucible plays what is on the server. Integrations connect it to everything around the server: where the viewer tracks what they watch, where they ask for what is missing, what is on its way, and what the household watched. Each integration is an opt-in plugin under Settings › Integrations (`CrucibleCore/Features/Integrations`), sends nothing until connected, and lives on iPhone, iPad and Apple TV. Trakt is the first (`docs/TRAKT.md`). Research behind this page, read on the services' own pages on 2026-11-08: `~/Documents/crucible-trakt-research/landscape/services.json`.

## Which services, and why

| Plugin | Role | Access and cost | Paid-app terms | Order |
| --- | --- | --- | --- | --- |
| Trakt | Tracking, discovery, social | Free Standard API; Premium $149/month only for higher limits, Limited Access endpoints and the per-user app cap | Paid apps allowed, no approval, no revenue share | Built (slices 1-2) |
| Seerr (Overseerr and Jellyseerr, merged) | Ask for a title that is not on the server, see its request state | Self-hosted, free; Plex sign-in (`POST /api/v1/auth/plex` with the token Crucible already holds) or API key | MIT | Next |
| Sonarr and Radarr | What is coming and downloading: calendar, queue, history | Self-hosted, free; API key | GPL-3.0 servers, called over HTTP | After Seerr |
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
| Request a title through Seerr, its request state on the page | Arrival notifications, request approvals for owners |
| Ratings strip on every page | One calendar across Trakt, Sonarr and Radarr, downloading and coming-soon on cards |
| | Statistics and Year in Review across every app (Tautulli, Trakt) |

The free Request button is the download driver: Plex owners who run Seerr look for a client that requests and plays in one place. The paywall leads with what only the hub can do: "Everything about your server in one place".

## Store and marketing

Third-party names stay out of the app name, subtitle and keywords (Apple 5.2.5); they go in the description ("Works with Trakt, Overseerr, Jellyseerr, Sonarr, Radarr and Tautulli") with each required attribution line, in What's New and in screenshot captions. Every integration release gets its claims table in `docs/marketing-<version>.md`, the App Privacy answers it needs (Trakt and Simkl are outside services; Seerr, Sonarr, Radarr and Tautulli run on the viewer's own servers, like Plex) and its privacy-policy section.
