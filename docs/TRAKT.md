# Trakt for Crucible

Design for a Trakt.tv integration on iPhone, iPad and Apple TV that covers the whole Trakt API, ships as an opt-in plugin and earns its keep through Crucible Pro. Screens: https://claude.ai/artifact/4DCbeF5sTfT7anbwYX1fEy. Research behind every claim (endpoint catalogue, guides digest, policy, competitors, Plex-Trakt pitfalls, maps of this codebase): `~/Documents/crucible-trakt-research/`. Trakt facts are from `github.com/trakt/trakt-api` (contract and developer guides, read 2026-11-08).

**The line the whole design follows:** Plex is what you have. Trakt is what you have seen and what you want next. Every Trakt item in Crucible knows whether it is on your server, and the free app sends to Trakt while Pro brings Trakt in.

## 1. Decisions waiting on Marcus

| # | Decision | Recommendation |
| --- | --- | --- |
| D1 | Pay for Trakt Developer Premium ($149 a month, $1,788 a year) if Trakt only opens Production apps to Premium (portal commit 2026-10-28 "show production apps as unavailable without a developer plan") | Ask Trakt first (the production email already sent). If Premium is the only route, take it: it is the only way strangers can sign in, it lifts the two-app cap on free Trakt accounts, unlocks `up_next_nitro` and watch-now, and breaks even at about 85 lifetime or 265 yearly sales a year (§9.4) |
| D2 | Prices when Trakt ships | Yearly $7.99 to $9.99 and lifetime $24.99 to $29.99 for new buyers, announced with a Pro week (§9.4). Existing buyers keep everything |
| D3 | App Privacy label | Declare Product Interaction and Other User Content as linked, App Functionality, not tracking, because Crucible's client sends them to Trakt while the plugin is on (§10.2). The label already lists Identifiers and Purchases, so it is not losing "Data Not Collected" |
| D4 | Tab or no tab | A Trakt tab appears when the plugin is on (iPhone on iOS 26, iPad sidebar, Apple TV). Where the tab bar has no room it lives in You (§8.5) |

## Status

Slices 1 and 2 are built (2026-11-08), on iPhone, iPad and Apple TV, against the development app:

- The plugin seam (`CrucibleCore/Features/Integrations`) and Settings › Integrations › Trakt; nothing runs or is sent until Connect.
- Connecting by device code: a sheet with the code and Open Trakt on iPhone and iPad, the code in tiles and a QR code on Apple TV. Tokens per Plex account and Home profile in the Keychain, refreshed a day early, single-use refresh tokens saved before use; restricted profiles cannot connect.
- Matching by agent ids only (`TraktResolver`), with unmatched titles listed in Settings.
- Scrobbling from `PlaybackSession` (start, pause, stop; credits before 80% still record the play), manual watched, unwatched (opt-in) and ratings sent, check-in on detail pages, the offline outbox and the sent-plays ledger, the double-play question after connecting, the "Marked watched on Trakt" banner.
- The ratings strip on movie, episode and show pages on both platforms.
- The demo answers as a stand-in Trakt, so App Review and screenshots need no account. Strings in all eleven languages.

The Client ID is read from `Sources/CrucibleCore/Features/Trakt/TraktClientID.swift`, which is gitignored: a checkout without it builds with Trakt shown as unavailable, and a fork registers its own Trakt app. Everything above lives in Core (`Features/Trakt`) for now; the separate `CrucibleTrakt` target in §3.2 arrives with the GRDB mirror of slice 3. Not built yet: Use iPhone on Apple TV (§5), PKCE with the Universal Link, Fix Match, and slices 3 to 8.

Before any App Store release with Trakt: D1 to D4, the App Privacy answers and the privacy policy (§10.2), the marketing set (§11), and a live check with a real account (only allow-listed accounts can sign in to the development app).

## 2. Trakt facts that shape the design

| Fact | Source | Consequence |
| --- | --- | --- |
| Development apps sign in only the owner and allow-listed accounts (others get 418) and accept only localhost redirects | portal `ApplicationForm.svelte`, issue #1057 (2026-11-03) | Beta testers must be allow-listed; dev builds use the device code flow on every device |
| Production apps need https redirects; the portal gates them behind a developer plan | `developerErrorMessage.ts`, commit log 2026-10-28 | iPhone sign-in moves to PKCE + Universal Link once Production exists (§5) |
| Paid apps are allowed with no approval, fee or revenue share | `api-use-policy.md` (2026-10-20) | Pro can gate Trakt features |
| "Crucible uses Trakt but is not endorsed or certified by Trakt" in About/Settings and the store description | `api-use-policy.md` | Settings › Trakt footer, About, every locale's description |
| Free Trakt accounts connect two community apps; Premium developers are exempt | discussion #943, `premium.md` | Connect sheet explains a 420/403 on connect; Premium removes the problem |
| Authenticated GET 500 per 5 minutes per user; writes 1 per second; 429 with or without `Retry-After` | `rate-limiting.md` (2026-10-13), issue #909 | One rate-limited client for the whole app (§3.3) |
| Access tokens last 7 days; refresh tokens are single use | `authentication-oauth.md` (2026-10-01) | Refresh is a Keychain transaction; two devices never share a token |
| Login must use `auth.trakt.tv` from 2027-02-01; GitHub verification from 2027-01-01 | discussion #1031 | Build on `auth.trakt.tv` from day one |
| Registrations unused for 30 days, or test-only in their first 30 days, are deleted | `api-use-policy.md` | Keep the dev app in daily use |
| Images must be cached, never hotlinked; WebP; URLs need `https://` | `images.md` | Through `ImageLoader` + disk cache only |
| Account limits answer 420 (often empty body), VIP-only answers 426 with `X-Upgrade-URL`, locked accounts 423 | `user-account-limits.md`, `vip-methods.md`, `locked-user-account.md` | One error vocabulary, limits read from `/users/settings`, never hard-coded |
| Up Next "might be unavailable or incomplete" for public apps; watch-now is Limited Access | repo README, `limted-access.md` | Two Up Next sources and a watch-now fallback (§7.6, §8.4) |
| Scrobble stop at 80% or more marks watched, 1 to 79% pauses, under 1% is 422; 409 means a recent duplicate | scrobble contract | §6 state machine; 409 is success |
| `/sync/history` does not dedupe | sync contract | Crucible keeps a ledger of what it posted |
| Comments: 5 words minimum, English only, 200+ words is a review, spoiler tags, no "(via Crucible)" | `about-comments.md` | Composer enforces and explains the rules |
| `extended=streaming_ids` returns `ids.plex {guid, slug}` on movies and episodes | movies and shows contracts | A Trakt item can be matched to `plex://` guids without title matching |
| Trakt has its own Plex link (`/users/settings/plex`: servers, scrobbler toggles, sync) | users contract | Crucible detects it to avoid double plays (§6.4) |

## 3. Architecture: a plugin

### 3.1 Integrations seam (Core)

`CrucibleCore/Features/Integrations` defines what any outside service plugs into, so Trakt is the first plugin and not a special case:

- `IntegrationPlugin`: `id`, `displayName`, `consent: IntegrationConsent` (what is sent, to whom, how to stop), `state` (off, connecting, on, needsAttention), and optional providers:
  - `PlaybackObserving` gets `PlaybackSession` lifecycle facts (§6.1) after Plex's own reporter.
  - `WatchStateObserving` gets manual watched, unwatched, rating and watchlist changes from `WatchedService.setWatched`, `RatingService.setRating` and `WatchlistService`.
  - `HomeShelfProviding`, `DetailSectionProviding`, `SearchProviding`, `NotificationProviding`, `SettingsProviding`, `TabProviding`.
  - `AccountResetParticipating`: called from `AccountSessionReset.signOut` and `switchedProfile`.
- `Integrations.shared` holds the registry. A plugin that is off has no instance: no network, no timers, no background task submitted. Enabling it instantiates it; disabling tears it down and runs its reset.
- Settings gets an **Integrations** category in `SettingsCatalog` with one row per plugin (`SettingsDestination.integration(id)`), on iPhone and Apple TV.

### 3.2 Targets and files

| Place | Contents |
| --- | --- |
| `Sources/CrucibleTrakt` (new target: Core + GRDB + MidgarCore, no UIKit) | `TraktClient` (actor), `TraktEndpoint` (every route in Appendix A as a typed case), models, `TraktAuth` (device code, PKCE), `TraktTokenStore`, `TraktRateGate`, `TraktErrors`, `LibraryIndex`, `TraktResolver`, `TraktScrobbler`, `TraktOutbox`, `TraktSyncEngine` and its domain syncers, `TraktMirror` (GRDB: ids, watched, ratings, watchlist, lists, history cursors), `TraktPlugin` (the `IntegrationPlugin`), feeds for every screen (`UpNextFeed`, `CalendarFeed`, `ListsFeed`, `RecommendationsFeed`, `CommentsFeed`, `InsightsFeed` ...), copy |
| `Sources/Crucible/Trakt` | iPhone and iPad screens and cells |
| `Sources/CrucibleTV/Trakt` + `Navigation/Screens+Trakt.swift` | Apple TV screens on the tvOS design system, gallery entries |
| `Sources/CrucibleDemo/Trakt` | A deterministic fake Trakt on the demo's loopback server (`TraktHost.setOverride`), so the demo, App Review and screenshots show every feature with no account |
| `marketing/mock` | The same routes in the Python mock for UI tests |
| `Tests/CrucibleCoreTests/Trakt*` | Fake-transport tests in the `AuthPinTests` style, plus contract fixtures from Trakt's zod schemas |

The xtool build includes the target; nothing in it runs until the plugin is on.

### 3.3 Client rules

- Hosts `api.trakt.tv` (Standard) or `apiz.trakt.tv` (Premium), auth on `auth.trakt.tv`. Headers on every call: `trakt-api-key` (Client ID from the build's config, never a secret), `trakt-api-version: 2`, `Content-Type: application/json`, `User-Agent: Crucible/<version> (<platform>)`.
- `TraktRateGate`: writes leave one per second from one serial queue; GETs draw from a 500-per-5-minutes bucket per account with headroom for the foreground (background work stops at 60%). A 429 waits `Retry-After`, or backs off exponentially with jitter, three tries.
- Errors: 401 refreshes once, then marks the account `needsAttention` (repeated 401s get IPs blocked); 418 explains the development-app allow list; 420 reads `/users/settings` limits and shows them; 423 tells the user to contact Trakt support; 426 offers Trakt VIP via `X-Upgrade-URL`; 5xx and Cloudflare 52x retry later and never surface as alerts in the background.
- Pagination: always `page` and `limit`, read `X-Pagination-*`, never assume the default; lists cap at 250 per page.
- Caching: metadata from summary endpoints keyed by Trakt id with `updated_at`, refreshed through `/movies|shows|people/updates/id/:start_date` once a day; activity from sync endpoints keyed by `last_activities`. Images through `ImageLoader` and the disk cache, `https://` prepended.
- Logging: a `.trakt` category in `CrucibleLog`; tokens never logged.

### 3.4 Data kept on the device

Tokens in the Keychain per Plex account and Home profile (`trakt.<plexUserUUID>`). `TraktMirror` (GRDB, `Library/Application Support/trakt.sqlite`, Caches on tvOS): Trakt ids for library items, the user's watched/ratings/watchlist/lists snapshot, cursors, the outbox and the posted-plays ledger. Disconnect revokes the token (`POST /oauth/revoke`) and deletes the mirror, the outbox and every Trakt image in the cache.

## 4. Identity: knowing what is on your server

### 4.1 LibraryIndex

One call per movie and show library, `/library/sections/{id}/all?includeGuids=1`, builds `plex guid → ratingKey`, `imdb/tmdb/tvdb → ratingKey`, refreshed on `ServerEventHub` library changes and at most hourly. Episodes resolve through their show: Trakt `(show, season, number)` to the show's `/children` indexes, falling back to the episode's own Guid array. Every Trakt object the app shows passes through `LibraryIndex.locate(_:) -> Availability` (`.onServer(ratingKey, progress)`, `.elsewhere(watchNow?)`, `.notAvailable`), which decides the card's badge and its primary action.

### 4.2 Plex item to Trakt id

`TraktResolver` in this order, cached in the mirror:
1. Movies and episodes: the item's `plex://` guid against `ids.plex.guid` when a Trakt response already carried `streaming_ids`.
2. The Guid array from `includeGuids=1` (`StreamResolver` already fetches it and drops it; `PlaybackMetadata` gains `externalIDs`): `/search/{imdb|tmdb|tvdb}/{id}?type=movie|show|episode`, accepted only when the type matches and the returned id equals the one asked for. Never tvdb for movies.
3. Episodes: resolve the show, cache its seasons (`/shows/:id/seasons?extended=episodes`), match season and number; if the numbering disagrees, match the episode's own tvdb/tmdb id.
4. Legacy agents (`com.plexapp.agents.*`, `thetvdb://`, `themoviedb://`) are normalised; hama/AniDB, YouTube, local and `none` are unsyncable.
5. No match: never written to Trakt. The item appears in Settings › Trakt › Unmatched with **Fix Match** (Trakt search, pick, remembered per ratingKey).

Multi-episode files (S01E01-E02) post every episode they contain. Specials (season 0) scrobble but stay out of collection sync.

## 5. Connecting

**iPhone and iPad.** Settings › Integrations › Trakt › Connect opens the consent sheet (§10.1), then sign-in:
- Development app (now): device code. The sheet shows the eight-character code large, copies it, and opens `auth.trakt.tv/activate` in an `ASWebAuthenticationSession`-style in-app browser; the app polls `/oauth/device/token` at `interval` and stops at `expires_in` with a Try Again.
- Production app: PKCE (S256, a fresh verifier per sign-in) with the Universal Link `https://midgarcorp.cc/crucible/trakt/callback` (`apple-app-site-association` on midgarcorp.cc, `applinks:midgarcorp.cc` in both entitlements), `ASWebAuthenticationSession` with an https callback on iOS 17.4 and later, device code before that.

**Apple TV.** Device code: a QR to `auth.trakt.tv/activate` and the code in the TV's mono type, plus **Use iPhone**: the existing `crucible-pair` DeviceDiscoveryUI channel (new message version, explicit Allow on the iPhone) carries only the TV's `user_code`; the iPhone opens the activate page with it, the user taps Approve, and the TV's own poll completes. Each device has its own tokens.

**Profiles.** Each Plex Home profile links its own Trakt account; the owner's link is never used for another profile. Restricted (kids) profiles cannot connect.

**After connect.** `/users/settings` (limits, VIP, timezone, watch-now country) and `/users/settings/plex` (Trakt's own Plex link) are read; the double-play check (§6.4) runs; Pro users get the first-sync preview (§7.2); free users see what is on and what Pro adds.

## 6. Scrobbling (free)

### 6.1 State machine

| PlaybackSession fact | Trakt call |
| --- | --- |
| `begin` plays (not an extra: `PlaybackRequest.isExtra` stays excluded) | `POST /scrobble/start {item, progress}` |
| paused (timeControlStatus) | `POST /scrobble/pause {progress}` |
| resumed, or a seek that lands while playing | `POST /scrobble/start {progress}` |
| stopped below the finish rule | `POST /scrobble/pause` (Trakt keeps the resume point, six months) |
| finished (`WatchedRule.isFinished`: credits marker or 92%) | `POST /scrobble/stop {progress}`; if `progress < 80` because credits came early, also `POST /sync/history {watched_at: now}` |
| app killed mid-play | `PlaybackResumeSync.flush` at next launch sends the stored point as a pause, or the finish as history |

Progress is `absolutePosition / durationSecs` from `PlayheadTracker`, never the player clock. The scrobbler is a `PlaybackObserving` that rides the reporter's serial order, so a stop is never overtaken by an older start. 409 is success (its `expires_at` is remembered); 422 under 1% is ignored.

### 6.2 Offline and downloads

Downloads play offline and finish into `TraktOutbox` (GRDB) as history entries with the real `watched_at`. The outbox drains in order when online, 100 items per POST, one POST a second, and each posted `(trakt id, watched_at to the minute)` goes in the ledger so a retry never doubles a play.

### 6.3 Manual changes

Mark Watched posts `/sync/history` (with a date choice: now, release date, pick a date); Mark Unwatched asks whether to remove the plays on Trakt too (`/sync/history/remove`, default no, remembered). Rating a title (stars, half steps 1 to 10 = Trakt 1 to 10 one-to-one) posts `/sync/ratings`; clearing posts `/sync/ratings/remove`. These ride `RatingSaver`'s queue, optimistic, reverting on failure.

### 6.4 Never two plays

If `/users/settings/plex` shows Trakt's own Plex scrobbler or sync on for this server (machine identifier in `/servers`), a sheet asks once: **Let Trakt's Plex sync record plays** (Crucible scrobbling off, everything else on) or **Crucible records plays** (recommended for live progress; Crucible turns Trakt's scrobbler off for this server with `PUT /users/settings/plex`, which leaves every other Trakt toggle as it was). PlexTraktSync and webhook setups cannot be detected, so the same choice is a switch in settings, "Another app already scrobbles this profile".

### 6.5 Feedback

The player's info panel carries a quiet "Trakt" status line (Watching · Paused · Saved). On finish, a banner over post-play: **Marked watched on Trakt** with Rate (opens the existing rating sheet, which writes Plex and Trakt). Nothing else interrupts playback. Failures queue silently and surface only in the Sync Center.

## 7. Sync (Pro)

### 7.1 Engine

`TraktSyncEngine` wakes on launch, foreground, after a scrobble stop, from a new BG task `com.guitaripod.crucible.trakt` (every 4 hours; added to `InfoAdditions.plist` and `ios/project.yml`) and from Sync Now. It reads `/sync/last_activities` and pulls only domains whose timestamps moved, using `extended=min` where offered. Each domain is a `TraktDomainSyncer` with a plan (what will change, both directions) before it applies, so the first sync and Sync Now can show a preview.

### 7.2 Domains

| Domain | Endpoints | Default | Rule |
| --- | --- | --- | --- |
| Watched | `/sync/watched/:type`, `/sync/history`, `/sync/history/remove`, Plex `/:/scrobble`, `/status/sessions/history/all` | Two-way, unwatch off | Union: watched on either side becomes watched on both; plays from other Plex apps are posted with their `viewedAt`; Trakt plays (other apps, streaming via Trakt's younify, cinema check-ins) mark the Plex item watched. Unwatch spreads only with the switch on |
| Ratings | `/sync/ratings*`, Plex `/:/rate` | Two-way | Newest `rated_at` / `lastRatedAt` wins; season ratings Trakt-only |
| Watchlist | `/sync/watchlist*`, plex.tv watchlist | Two-way | Union; removal spreads; Trakt removes items once watched, so Crucible does not re-add them |
| Collection | `/sync/collection*` | Off; owner only | The server's library as the Trakt collection with `media_type`, `resolution`, `hdr`, `audio`, `audio_channels`, `collected_at = addedAt`; specials excluded |
| Resume points | `/sync/playback*` | On | A newer point from another app offers "Resume from 41:12 (watched on another device)" on Play |
| Lists | `/users/me/lists*`, Plex playlists | Off | Optional mirror of chosen Trakt lists as Plex playlists of what is on the server |
| Favorites | `/sync/favorites*` | Trakt-only | Shown as a heart on detail; no Plex counterpart |

**First sync** shows the plan before anything is written: "Trakt knows 1,204 episodes you watched elsewhere: mark them watched on Nimbus", "312 plays from other Plex apps are not on Trakt: add them", per-row toggles, **Apply** or **Start from Now** (only future plays, matching Trakt's own `trigger_sync: false`). Everything Crucible marks on Plex is journaled for 30 days with **Undo this sync**.

### 7.3 Sync Center

Settings › Trakt › Sync Center: last and next sync, one row per domain with counts and direction arrows, Sync Now, Unmatched (with Fix Match), Limits ("Watchlist 212 of 250", VIP upsell only when Trakt answered 420), the outbox, and an activity log of the last 200 writes with their result. Trakt's own imports (`/users/syncs`: younify, Plex, CSV imports) are listed with paused/skipped items, and **Undo import** (`DELETE /users/syncs/:id`, confirmed, explained as destructive). **Trakt's Plex link** shows its state with Sync Now (`POST /users/settings/plex/sync`) and Unlink (confirmed); linking it is done on Trakt's site, because its return URL only accepts Trakt hosts. **Streaming services** lists what Trakt imports from (`/younify/connections`) with Refresh and Remove; adding one opens Trakt's settings for the same reason.

## 8. Surfaces

Every surface ships on iPhone, iPad and Apple TV in the same release (the parity rule). Cards for Trakt items reuse `PosterCell`/`TVCardContentView` with one new overlay: an availability chip (**On Nimbus** in ember, or the streaming service name, or nothing).

### 8.1 Settings › Integrations › Trakt

Off: a plugin card (what it does, what it sends, Connect). On: account header (avatar, username, VIP badge, Disconnect), then **Free**: Scrobble playback, Send manual changes, Check-ins; **Pro** (locked rows show the Pro badge and open the paywall): Watched sync (two-way / to Trakt / from Trakt), Ratings sync, Watchlist sync, Collection (owners), Resume points, Lists as playlists, Trakt tab, Home shelves (opens Home Rows), Notifications; then Libraries included, Sync Center, Unmatched, "Another app already scrobbles this profile", Trakt account settings (`PUT /users/settings`: private profile, watch-now country and favourite services, timezone, spoilers), Hidden items, About Trakt (`/team`), and the disclaimer line.

### 8.2 Player

Status line in the info panel, finish banner with Rate (§6.5), "Resume from another device" on Play (§7.2). Apple TV: the same line in the info tab and a Rate action on the post-play screen. No interruptions during playback.

### 8.3 Detail page of a library item

New sections after Overview (movies) or after the episode list (shows), each hidden when empty:

1. **Ratings strip** (free): Trakt percentage and votes, then IMDb, TMDB, Rotten Tomatoes, Metacritic, Letterboxd, MyAnimeList from `/:type/:id/ratings?extended=all`, each labelled by source; tap for Trakt's 1 to 10 distribution. Never blended into one score unless labelled as Crucible's.
2. **You on Trakt** (Pro): plays ("Watched 3 times · last 12 Apr"), your rating, watchlist, favourite heart, in your lists, private note (`/notes`, 500 characters), show progress ring ("14 of 22 · S2"), next airing (`/next_episode`), **Stop watching** (`/users/hidden/dropped`), **Reset progress** (VIP, `/progress/watched/reset`).
3. **Community** (Pro): watching now (`/watching`), watchers, plays, collectors, lists, comments counts (`/stats`), What people say (`/sentiments` as two chip rows), top comments (three, spoilers blurred, reactions), "In 1,240 lists" (`/lists/popular`).
4. **Related on Trakt** (Pro): merged with Plex related, on-server first, `personalized=true` for VIP.
5. **Facts**: studios, aliases and the title in your language (`/translations`), release dates and certification for your country (`/releases/:country`), trailers (`/videos`, opened in the YouTube app or Safari).
6. **Actions** in the action row and More menu: Check In (free), Add to List…, Favourite, Watchlist, Note, Hide from Recommendations, Report a Problem (`/report`).

Seasons and episodes get the strip, You on Trakt, comments and watching now. People: the Plex cast row matches Trakt's `/people` by name to open a Trakt person page (headshot, biography, filmography with on-server badges).

### 8.4 Detail page of a title not on your server (Pro)

Opened from any Trakt surface. The same layout as §8.3 with Trakt artwork, and the hero's primary action replaced by availability: **Where to Watch** (watch-now offers by country with deep links, `link_tvos` on Apple TV, when Trakt grants Limited Access; otherwise the TMDB/IMDb links and a note), Watchlist, Check In, Add to List. A strip reads "Not on Nimbus"; when the title arrives on the server the page turns into the library page and a notification says so.

### 8.5 The Trakt tab (Pro, preview for free)

Appears when the plugin is on: iPhone between Downloads and You on iOS 26 (search sits apart); iPad sidebar section with its screens as items; Apple TV top tab before Search. On iOS 17 and 18, where a sixth tab would fall into More, the hub opens from a You row instead. Setting: "Show Trakt as a tab".

The hub, top to bottom: profile header (avatar, VIP, this week's plays and hours, sync status chip), **Up Next** (§8.6), **Airing This Week** (a seven-day strip with episode counts, tap a day), **Watchlist** (on-server first), **Recommended on Nimbus** and **Recommended** (`/recommendations/:type`, with Not Interested), **Your Lists**, **Friends Watching**, **Your Month** (month in review card). Each row has See All:

- **Up Next**: shows in progress with rings (`/sync/progress/watched`, `/shows/:id/progress/watched`; `up_next_nitro` with Premium), sorted by last watched, swipe to Hide (`/users/hidden/progress_watched`) or Stop Watching; a Dropped segment restores them.
- **Calendar**: agenda by day in the user's timezone, segments My Shows, Premieres, Finales, Movies, Streaming, DVD, and an All Shows / Hot switch (`/calendars/my|all/...`, `/calendars/releases/hot/...`); filters from genres, networks, languages, countries and certifications; saved filters for VIP (`/users/saved_filters/calendar`); hide a show from the calendar (`/users/hidden/calendar`).
- **Watchlist**: grid with sort (rank, added, released, title, Trakt and external ratings for VIP), "On my server" filter, drag to reorder (`/sync/watchlist/reorder`), item notes (VIP).
- **Lists**: Yours, Smart, Liked, Collaborations, Trending, Popular. A list page shows "23 of 40 on Nimbus" with **Play** and **Shuffle** (a `PlaybackQueue` of what is on the server), edit (name, description, privacy, sort, reorder, item notes), like, comments, share link. **Smart lists**: start from a template (`/smart-lists/templates`) or build one (source, type, genres, years, ratings, runtime, people, studios, networks, watch-now, ignore watched/watchlisted/unreleased), live preview while editing, save (`POST /users/me/smart-lists`, VIP enhanced); stale lists offer **Convert to Smart List**.
- **Discover**: charts with a Movies / Shows / Both switch: Trending, Popular, Anticipated, Hot, Box Office, Streaming (daily, weekly, monthly with rank changes), and Most Watched, Played, Collected and Favourited by period (`/movies|shows/...`, `/media/...`), each card with its availability chip and an "On my server" filter; filters from genres, languages, countries, certifications and networks.
- **History**: a timeline by day with the source of each play (this app, another Plex app, Trakt), filter by movies/shows, Remove Play, Add Play at a date.
- **Ratings and Favourites**: grids by score bucket; favourites reorderable.
- **Friends**: following, followers, friends, requests (approve/deny), blocked; a profile shows their watching now, recent history, lists, ratings and favourites when public; Follow, Block, Report. Trakt keeps social activity feeds first-party, so Friends Watching is built from `/users/:id/watching` of up to 20 people followed, refreshed on open.
- **Comments and likes**: your comments, replies, liked comments and lists, reactions.
- **Notes**: every private note, by type.
- **Insights**: Trakt stats (`/users/me/stats`, VIP) and Year in Review / Month in Review (`/yir`, `/mir`, persona for VIP), linking into §8.8.

### 8.6 Home

New rows in `HomeLayout` (off until the plugin is on, then on by default in this order after Continue Watching): **Up Next Everywhere** (Trakt progress merged with Plex On Deck, on-server first, elsewhere shows the service), **Airing This Week**, **Recommended on Nimbus**, **From Your Lists** (one pinned list or smart list), **Trending on Trakt** (`/media/trending`, on-server badge). Trakt rows are a second source beside `/hubs` in `HomeFeed.Environment`, never mixed into the cold-launch snapshot. A free user sees the first three Up Next cards and an unlock card.

### 8.7 Search

Library results first, unchanged. Then **On Trakt**: exact match first, then broad (`/search/:type/exact`, `/search/:type`), movies, shows, episodes, people, lists and users, each with the availability chip. The empty state shows trending searches (`/search/recent_by_id/global/:type`). Sending queries to Trakt's recent-search history (`POST /search/recent`) is its own switch, off.

### 8.8 Statistics and Year in Review

Statistics gains a source switch, **Plex** or **Everything on Trakt** (Pro). Trakt history imports into a new `trakt_play` table with a source column and an optional ratingKey, so the Plex-only aggregates stay exact and the Everything view adds plays from other apps, streaming and cinemas. Year in Review adds the Trakt persona and traits when Trakt has them (VIP for your own), and the poster carries a line "Tracked with Trakt".

### 8.9 Notifications (iPhone)

Computed on device in the existing refresh task and the new Trakt task, deduped by `NotificationLedger` (new key prefixes `trakt.airing.`, `trakt.arrived.`, `trakt.request.`): **Airing tonight** (a followed show's episode airs, local time), **Now on Nimbus** (a watchlist or Up Next title arrives on the server), **Follow request**, **Your month on Trakt** (first of the month). Each is a switch in Notifications.

### 8.10 Apple TV

Connect by QR, code or Use iPhone (§5). The Trakt tab is a cinematic hub on `TVScreenViewController`: hero follows focus, shelves as on iPhone, Calendar as one shelf per day. Detail: the ratings strip as a non-focusable row under the hero, Check In and Add to List among the actions (between Rate and Playlist), comments in a `TVReadOnlyPanel` reader. Rating uses the existing ten-segment `TVRatingViewController`. Composing comments, notes and smart lists is iPhone and iPad only; Apple TV can react, like, add and remove. Top Shelf can show Up Next Everywhere items that are on the server.

### 8.11 iPad

The Trakt sidebar section lists Up Next, Calendar, Watchlist, Lists, History, Friends and Insights. Calendar uses a two-column agenda with a month grid in wide windows. New `AppCommand`s: Go › Trakt (Command-5), Media › Check In, Media › Add to List. Lists and watchlist items drag to the sidebar's lists and onto other windows.

## 9. Money

### 9.1 The split

| Free (with the plugin on) | Crucible Pro |
| --- | --- |
| Connect on every device | Two-way sync: watched, ratings, watchlist, collection, resume points, lists as playlists |
| Real-time scrobbling, offline outbox, double-play guard | The Trakt tab: Up Next everywhere, Calendar, Watchlist, Lists and Smart Lists with Play on your server, Recommendations on your server, History, Friends, Insights |
| Manual watched, ratings and check-ins sent to Trakt | Home rows, Trakt search, pages for titles not on your server, Where to Watch |
| The ratings strip on detail pages | Community, comments and reactions, notes, favourites |
| | Statistics and Year in Review with everything Trakt knows, Trakt notifications |

Free sends to Trakt; Pro brings Trakt in. It mirrors the split Trakt users already know from Infuse (free sends, paid pulls) and keeps the free plugin useful enough to be the reason a Trakt user downloads Crucible.

### 9.2 Where the paywall appears

- The first sync preview: the counts are computed for free users too ("Trakt knows 1,204 episodes you watched elsewhere"), Apply is the Pro button.
- Up Next Everywhere on Home: three real cards, then an unlock card with the user's own count.
- The Trakt tab for free users: the real hub, blurred below the header, one unlock button.
- After the third scrobble: a one-time card in the finish banner, "Bring your Trakt history into Crucible".
- Pro week: the week (`ProWeek`) unlocks the whole plugin; on its last day the hub says what will pause, with the user's numbers.

`ProFeature` gains `traktSync`, `traktHub`, `traktInsights` (paywall copy and order), and every paywall shown from a Trakt surface leads with them.

### 9.3 Trakt features that raise revenue

- **On-your-server intersections** are what no other app can do: recommendations, lists, smart lists, the watchlist and the calendar filtered to what plays now, and Play on any list. They lead the paywall and the screenshots.
- **Smart lists as Mixes**: three templates offered on Home ("Unwatched and loved", "Short tonight", "Finish a show"), each a one-tap smart list.
- **Year in Review with everything** makes the shareable poster complete, and the poster carries Crucible's name.
- **Trakt VIP** is shown only where Trakt itself gates (426/420, stats, persona, saved filters, reset progress), never as Crucible's upsell.

### 9.4 Prices and cost

If D1 is yes, Premium is a fixed $1,788 a year. After Apple's 15%: lifetime $24.99 nets about $21.24 (about 85 sales a year to cover it), yearly $7.99 nets about $6.79 (about 265). At the recommended $29.99 and $9.99 (D2) it is 71 or 211. Trakt brings a new, large audience searching for a Plex client that scrobbles; the free plugin is the hook and the first-sync preview is the conversion.

## 10. Privacy and compliance

### 10.1 Consent

Turning the plugin on shows, before any request: what is sent (what you play and when, how far, your ratings, watchlist and lists; your library only if you turn on Collection), to whom (Trakt, under its privacy policy, linked), that Midgar never receives it, and how to stop (Disconnect revokes access and deletes everything Crucible kept). Two buttons: Connect Trakt, Not Now. The plugin stays off until the user connects.

### 10.2 Store answers

- App Privacy (D3): add **Usage Data › Product Interaction** and **User Content › Other User Content**, linked, not tracking, App Functionality; `docs/app-privacy.md`, `app-privacy.json` and both `PrivacyInfo.xcprivacy` files.
- Privacy policy (`docs/privacy-policy.txt`, midgarcorp.cc/crucible/privacy): a Trakt section with the consent text, retention (the mirror lives on the device until Disconnect) and deletion (Disconnect here; Trakt data at app.trakt.tv/settings/data).
- Disclaimer "Crucible uses Trakt but is not endorsed or certified by Trakt" in Settings › Trakt, About, and every locale's description.
- Branding: Trakt's logo only from app.trakt.tv/branding, unmodified, only in Settings › Trakt and the connect sheet; the tab icon is an SF Symbol.
- Comments: the composer enforces five words and English, offers the spoiler switch and `[spoiler]` tags, and shows Trakt's rules once.

## 11. Marketing with each release

Each Trakt release ships with: `docs/marketing-<version>.md` (claims table checked against the build, as 2.8.0 does), `store/metadata/{ios,tvos}/version/<version>` What's New and promotional text in all seventeen locales, a Trakt paragraph and the disclaimer in the description, keywords that avoid the trademark (scrobble, tracker, watch history, calendar, up next), new screenshot panels (iPhone 6.9", iPad 13", Apple TV: the hub, Up Next Everywhere, a list with Play on your server, the detail ratings strip, the Apple TV connect screen) through `marketing/shots` and `marketing/store` against the demo's fake Trakt, review notes saying the demo shows Trakt without an account, the Pro paywall copy and IAP review screenshot updated, the README feature list, and the website page.

## 12. Plan

Vertical slices, each committed when verified, each on iPhone, iPad and Apple TV, each with demo, mock, tests, eleven-language strings and its marketing:

1. **Foundation**: Integrations seam and settings category, consent, `CrucibleTrakt` client, rate gate, errors, device code on iPhone and Apple TV (QR, Use iPhone), tokens per profile, LibraryIndex, resolver, Unmatched, disconnect and reset, demo Trakt, mock routes.
2. **Scrobbling (free)**: scrobbler, outbox and ledger, manual changes, ratings out, check-in, double-play guard, player status and finish banner, ratings strip on detail. First Trakt release.
3. **Sync (Pro)**: engine, last activities, domains, first-sync preview and undo, Sync Center, BG task, resume points, paywall moments, `ProFeature` cases, price change (D2).
4. **Hub (Pro)**: the tab, Up Next, Calendar, Watchlist, Lists and Smart Lists with Play, Recommendations, History, Ratings and Favourites, Hidden.
5. **Discovery (Pro)**: Home rows, Trakt search, pages for titles not on the server, Where to Watch, Related, people pages.
6. **Community (Pro)**: You on Trakt and Community sections, comments and reactions, notes, Friends, requests, profiles.
7. **Insights (Pro)**: Statistics source switch, Trakt history import, Year and Month in Review with persona, notifications.
8. **Production sign-in**: PKCE and the Universal Link once Trakt grants Production; `apiz.trakt.tv` if Premium.

Acceptance for every slice: Core tests on fake transports (state machine, outbox ordering, dedupe, conflict rules, rate gate, error mapping, resolver), contract fixtures, `mac.sh core-test`, iPhone build and the screenshot harness, `tv.sh uitest` for the new screens, the demo walkthrough, and one real check against the developer app with Marcus's account before release.

## 13. Risks and open questions

- Production access and price (D1); until then only allow-listed accounts can sign in.
- Free-tier caps are in flux (watchlist 100 vs 250); everything reads limits live.
- The Trakt API is changing fast (seven breaking removals on 2026-10-13); contract fixtures from Trakt's zod schemas run in tests, and the plugin degrades a broken feature instead of failing the app.
- Episode numbering (anime absolute order, date-based shows) stays Unmatched until Fix Match; no automatic guessing.
- `ids.plex.guid` format, watch-now record keys, the minimal collection shapes and the up-next item count bug (#926) need checking on live responses before code depends on them.
- Younify (streaming service linking) only accepts Trakt-owned return URLs, so Crucible links to Trakt's settings instead of connecting services itself.

## Appendix A: every Trakt endpoint

Generated from the contract catalogue in `~/Documents/crucible-trakt-research/api/*.json` (338 routes; two `watched` routes are declared twice in Trakt's contract, full and `extended=min`). Auth: none, optional or required OAuth. VIP: Trakt-side gating (yes, partial: some sorts, limits or options). Tier: what Crucible needs to use it.

| Method | Path | Auth | VIP | Used by | Tier |
| --- | --- | --- | --- | --- | --- |
| GET | `/calendars/:target/dvd/:start_date/:days` | optional | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/calendars/:target/media/:start_date/:days` | optional | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/calendars/:target/movies/:start_date/:days` | optional | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/calendars/:target/shows/:start_date/:days` | optional | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/calendars/:target/shows/finales/:start_date/:days` | optional | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/calendars/:target/shows/new/:start_date/:days` | optional | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/calendars/:target/shows/premieres/:start_date/:days` | optional | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/calendars/:target/streaming/:start_date/:days` | optional | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/calendars/releases/hot/:start_date/:days` | none | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/calendars/releases/hot/finales/:start_date/:days` | none | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/calendars/releases/hot/new/:start_date/:days` | none | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/calendars/releases/hot/premieres/:start_date/:days` | none | no | §8.5 Calendar, §8.6 Airing This Week, §8.9 Airing tonight | Pro |
| GET | `/certifications/:type` | none | no | §8.5 Filters for Calendar, Discover and Smart Lists | Pro |
| GET | `/certifications/movies` | none | no | §8.5 Filters for Calendar, Discover and Smart Lists | Pro |
| GET | `/certifications/shows` | none | no | §8.5 Filters for Calendar, Discover and Smart Lists | Pro |
| POST | `/checkin` | required | no | §8.3 Check In | Free |
| DELETE | `/checkin` | required | no | §8.3 Check In | Free |
| POST | `/comments` | required | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/comments/:id` | none | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| PUT | `/comments/:id` | required | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| DELETE | `/comments/:id` | required | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/comments/:id/item` | none | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| POST | `/comments/:id/like` | required | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| DELETE | `/comments/:id/like` | required | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/comments/:id/likes` | none | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/comments/:id/reactions` | none | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| POST | `/comments/:id/reactions/:reaction_type` | required | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| DELETE | `/comments/:id/reactions/:reaction_type` | required | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/comments/:id/reactions/summary` | none | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/comments/:id/replies` | optional | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| POST | `/comments/:id/replies` | required | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| POST | `/comments/:id/report` | required | no | §8.3 Report a Problem, §8.5 Report | Free |
| GET | `/comments/recent/:comment_type/:type` | none | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/comments/trending/:comment_type/:type` | none | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/comments/updates/:comment_type/:type` | none | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/countries/:type` | none | no | §8.5 Filters for Calendar, Discover and Smart Lists | Pro |
| POST | `/episodes/:id/report` | required | no | §8.3 Report a Problem, §8.5 Report | Free |
| GET | `/episodes/:id/watchnow/:country` | none | no | §8.4 Where to Watch (Limited Access) | Pro |
| GET | `/genres/:type` | none | no | §8.5 Filters for Calendar, Discover and Smart Lists | Pro |
| GET | `/languages/:type` | none | no | §8.5 Filters for Calendar, Discover and Smart Lists | Pro |
| GET | `/lists/:id` | none | no | §8.5 Lists | Pro |
| GET | `/lists/:id/comments/:sort` | optional | no | §8.5 Lists: comments | Pro |
| GET | `/lists/:id/items/:type/:sort_by/:sort_how` | none | partial | §8.5 Lists | Pro |
| GET | `/lists/:id/items/movie` | none | no | §8.5 Lists | Pro |
| GET | `/lists/:id/items/movie,show` | none | no | §8.5 Lists | Pro |
| GET | `/lists/:id/items/movie,show,episode,season` | none | no | §8.5 Lists | Pro |
| GET | `/lists/:id/items/show` | none | no | §8.5 Lists | Pro |
| POST | `/lists/:id/like` | required | no | §8.5 Lists | Pro |
| DELETE | `/lists/:id/like` | required | no | §8.5 Lists | Pro |
| GET | `/lists/:id/likes` | none | no | §8.5 Lists | Pro |
| POST | `/lists/:id/report` | required | no | §8.3 Report a Problem, §8.5 Report | Free |
| GET | `/lists/popular` | none | no | §8.5 Lists | Pro |
| GET | `/lists/popular/:type` | none | no | §8.5 Lists | Pro |
| GET | `/lists/trending` | none | no | §8.5 Lists | Pro |
| GET | `/lists/trending/:type` | none | no | §8.5 Lists | Pro |
| GET | `/media/anticipated` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/media/popular` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/media/trending` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/movies/:id` | none | no | §8.3 and §8.4 Detail | Pro |
| GET | `/movies/:id/aliases` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/movies/:id/comments/:sort` | optional | no | §8.3 Community: top comments | Pro |
| GET | `/movies/:id/lists/:type/:sort` | none | no | §8.3 Community: lists containing this title | Pro |
| GET | `/movies/:id/people` | none | no | §8.3 Cast matched to Trakt people | Pro |
| GET | `/movies/:id/ratings` | none | no | §8.3 Ratings strip | Free |
| POST | `/movies/:id/refresh/justwatch` | required | yes | §8.4 Where to Watch (Limited Access) | Pro |
| GET | `/movies/:id/related` | none | partial | §8.3 Related on Trakt | Pro |
| GET | `/movies/:id/releases/:country` | none | no | §8.3 Facts and trailers | Pro |
| POST | `/movies/:id/report` | required | no | §8.3 Report a Problem, §8.5 Report | Free |
| GET | `/movies/:id/sentiments` | none | no | §8.3 Community | Pro |
| GET | `/movies/:id/stats` | none | no | §8.3 Community | Pro |
| GET | `/movies/:id/studios` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/movies/:id/translations` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/movies/:id/videos` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/movies/:id/watching` | none | no | §8.3 Community | Pro |
| GET | `/movies/:id/watchnow/:country` | none | no | §8.4 Where to Watch (Limited Access) | Pro |
| GET | `/movies/:id/watchnow/justwatch_links/:country` | none | no | §8.4 Where to Watch (Limited Access) | Pro |
| GET | `/movies/anticipated` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/movies/boxoffice` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/movies/collected/:period` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/movies/favorited/:period` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/movies/hot` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/movies/played/:period` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/movies/popular` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/movies/streaming/:period` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/movies/trending` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/movies/updates/:start_date` | none | no | §3.3 Metadata freshness | Free |
| GET | `/movies/updates/id/:start_date` | none | no | §3.3 Metadata freshness | Free |
| GET | `/movies/watched/:period` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/networks` | none | no | §8.5 Filters for Calendar, Discover and Smart Lists | Pro |
| POST | `/notes` | required | partial | §8.3 Note, §8.5 Notes | Pro |
| GET | `/notes/:id` | required | no | §8.3 Note, §8.5 Notes | Pro |
| PUT | `/notes/:id` | required | no | §8.3 Note, §8.5 Notes | Pro |
| DELETE | `/notes/:id` | required | no | §8.3 Note, §8.5 Notes | Pro |
| GET | `/notes/:id/item` | required | no | §8.3 Note, §8.5 Notes | Pro |
| GET | `/oauth/authorize` | none | no | §5 Connect: PKCE once Production exists; token refresh | Free |
| POST | `/oauth/device/code` | none | no | §5 Connect: device code on every device | Free |
| POST | `/oauth/device/token` | none | no | §5 Connect: device code on every device | Free |
| POST | `/oauth/revoke` | none | no | §3.4 Disconnect | Free |
| POST | `/oauth/token` | none | no | §5 Connect: PKCE once Production exists; token refresh | Free |
| GET | `/people/:id` | none | no | §8.3 Person pages | Pro |
| GET | `/people/:id/lists/:type/:sort` | none | no | §8.3 Community: lists containing this title | Pro |
| GET | `/people/:id/movies` | none | no | §8.3 Person pages | Pro |
| POST | `/people/:id/report` | required | no | §8.3 Report a Problem, §8.5 Report | Free |
| GET | `/people/:id/shows` | none | no | §8.3 Person pages | Pro |
| GET | `/people/updates/:start_date` | none | no | §3.3 Metadata freshness | Free |
| GET | `/people/updates/id/:start_date` | none | no | §3.3 Metadata freshness | Free |
| GET | `/recommendations/movies` | required | no | §8.5 Recommended, §8.6 Recommended on your server | Pro |
| DELETE | `/recommendations/movies/:id` | required | no | §8.5 Recommended, §8.6 Recommended on your server | Pro |
| GET | `/recommendations/shows` | required | no | §8.5 Recommended, §8.6 Recommended on your server | Pro |
| DELETE | `/recommendations/shows/:id` | required | no | §8.5 Recommended, §8.6 Recommended on your server | Pro |
| POST | `/scrobble/pause` | required | no | §6.1 Scrobbling | Free |
| POST | `/scrobble/start` | required | no | §6.1 Scrobbling | Free |
| POST | `/scrobble/stop` | required | no | §6.1 Scrobbling | Free |
| GET | `/search/:id_type/:id` | none | no | §4.2 Resolver | Free |
| GET | `/search/:type` | none | no | §8.7 Search on Trakt, §4.2 Fix Match | Pro |
| GET | `/search/:type/exact` | none | no | §8.7 Search on Trakt, §4.2 Fix Match | Pro |
| POST | `/search/recent` | required | no | §8.7 Recent searches to Trakt (switch, off) | Pro |
| GET | `/search/recent_by_id/global/:type` | none | no | §8.7 Trending searches in the empty state | Pro |
| POST | `/seasons/:id/report` | required | no | §8.3 Report a Problem, §8.5 Report | Free |
| GET | `/shows/:id` | none | no | §8.3 and §8.4 Detail | Pro |
| GET | `/shows/:id/aliases` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/shows/:id/certifications` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/shows/:id/comments/:sort` | optional | no | §8.3 Community: top comments | Pro |
| GET | `/shows/:id/last_episode` | none | no | §8.3 Next airing, §8.9 | Pro |
| GET | `/shows/:id/lists/:type/:sort` | none | no | §8.3 Community: lists containing this title | Pro |
| GET | `/shows/:id/next_episode` | none | no | §8.3 Next airing, §8.9 | Pro |
| GET | `/shows/:id/people` | none | no | §8.3 Cast matched to Trakt people | Pro |
| GET | `/shows/:id/progress/collection` | required | no | §8.3 You on Trakt: progress, Reset progress (VIP) | Pro |
| GET | `/shows/:id/progress/watched` | required | no | §8.3 You on Trakt: progress, Reset progress (VIP) | Pro |
| POST | `/shows/:id/progress/watched/reset` | required | yes | §8.3 You on Trakt: progress, Reset progress (VIP) | Pro |
| DELETE | `/shows/:id/progress/watched/reset` | required | yes | §8.3 You on Trakt: progress, Reset progress (VIP) | Pro |
| GET | `/shows/:id/ratings` | none | no | §8.3 Ratings strip | Free |
| POST | `/shows/:id/refresh/justwatch` | required | yes | §8.4 Where to Watch (Limited Access) | Pro |
| GET | `/shows/:id/related` | none | partial | §8.3 Related on Trakt | Pro |
| POST | `/shows/:id/report` | required | no | §8.3 Report a Problem, §8.5 Report | Free |
| GET | `/shows/:id/seasons` | none | no | §8.3 and §8.4 Seasons and episodes, §4.2 episode table | Pro |
| GET | `/shows/:id/seasons/:season` | none | no | §8.3 and §8.4 Seasons and episodes, §4.2 episode table | Pro |
| GET | `/shows/:id/seasons/:season/comments/:sort` | optional | no | §8.3 Community: top comments | Pro |
| GET | `/shows/:id/seasons/:season/episodes/:episode` | none | no | §8.3 and §8.4 Seasons and episodes, §4.2 episode table | Pro |
| GET | `/shows/:id/seasons/:season/episodes/:episode/comments/:sort` | optional | no | §8.3 Community: top comments | Pro |
| GET | `/shows/:id/seasons/:season/episodes/:episode/lists/:type/:sort` | none | no | §8.3 Community: lists containing this title | Pro |
| GET | `/shows/:id/seasons/:season/episodes/:episode/people` | none | no | §8.3 Cast matched to Trakt people | Pro |
| GET | `/shows/:id/seasons/:season/episodes/:episode/ratings` | none | no | §8.3 Ratings strip | Free |
| POST | `/shows/:id/seasons/:season/episodes/:episode/report` | required | no | §8.3 Report a Problem, §8.5 Report | Free |
| GET | `/shows/:id/seasons/:season/episodes/:episode/stats` | none | no | §8.3 Community | Pro |
| GET | `/shows/:id/seasons/:season/episodes/:episode/translations` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/shows/:id/seasons/:season/episodes/:episode/videos` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/shows/:id/seasons/:season/episodes/:episode/watching` | none | no | §8.3 Community | Pro |
| GET | `/shows/:id/seasons/:season/episodes/:episode/watchnow/:country` | none | no | §8.4 Where to Watch (Limited Access) | Pro |
| GET | `/shows/:id/seasons/:season/info` | none | no | §8.3 and §8.4 Seasons and episodes, §4.2 episode table | Pro |
| GET | `/shows/:id/seasons/:season/lists/:type/:sort` | none | no | §8.3 Community: lists containing this title | Pro |
| GET | `/shows/:id/seasons/:season/people` | none | no | §8.3 Cast matched to Trakt people | Pro |
| GET | `/shows/:id/seasons/:season/ratings` | none | no | §8.3 Ratings strip | Free |
| POST | `/shows/:id/seasons/:season/report` | required | no | §8.3 Report a Problem, §8.5 Report | Free |
| GET | `/shows/:id/seasons/:season/stats` | none | no | §8.3 Community | Pro |
| GET | `/shows/:id/seasons/:season/translations` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/shows/:id/seasons/:season/videos` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/shows/:id/seasons/:season/watching` | none | no | §8.3 Community | Pro |
| GET | `/shows/:id/seasons/:season/watchnow/justwatch_links/:country` | none | no | §8.4 Where to Watch (Limited Access) | Pro |
| GET | `/shows/:id/sentiments` | none | no | §8.3 Community | Pro |
| GET | `/shows/:id/stats` | none | no | §8.3 Community | Pro |
| GET | `/shows/:id/studios` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/shows/:id/translations` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/shows/:id/videos` | none | no | §8.3 Facts and trailers | Pro |
| GET | `/shows/:id/watching` | none | no | §8.3 Community | Pro |
| GET | `/shows/:id/watchnow/:country` | none | no | §8.4 Where to Watch (Limited Access) | Pro |
| GET | `/shows/:id/watchnow/justwatch_links/:country` | none | no | §8.4 Where to Watch (Limited Access) | Pro |
| GET | `/shows/anticipated` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/shows/collected/:period` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/shows/favorited/:period` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/shows/hot` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/shows/played/:period` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/shows/popular` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/shows/streaming/:period` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/shows/trending` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/shows/updates/:start_date` | none | no | §3.3 Metadata freshness | Free |
| GET | `/shows/updates/id/:start_date` | none | no | §3.3 Metadata freshness | Free |
| GET | `/shows/watched/:period` | none | no | §8.5 Discover charts, §8.6 Trending on Trakt | Pro |
| GET | `/smart-lists/:list_id` | optional | no | §8.5 Smart Lists | Pro |
| GET | `/smart-lists/:list_id/items` | optional | no | §8.5 Smart Lists | Pro |
| GET | `/smart-lists/:list_id/items/:type/:sort_by/:sort_how` | optional | no | §8.5 Smart Lists | Pro |
| GET | `/smart-lists/templates` | optional | no | §8.5 Smart Lists | Pro |
| POST | `/sync/collection` | required | partial | §7.2 Collection (owners) | Pro |
| GET | `/sync/collection/:type` | required | no | §7.2 Collection (owners) | Pro |
| GET | `/sync/collection/episodes` | required | no | §7.2 Collection (owners) | Pro |
| GET | `/sync/collection/media` | required | no | §7.2 Collection (owners) | Pro |
| GET | `/sync/collection/minimal/episodes` | required | no | §7.2 Collection (owners) | Pro |
| GET | `/sync/collection/minimal/movies` | required | no | §7.2 Collection (owners) | Pro |
| GET | `/sync/collection/minimal/shows` | required | no | §7.2 Collection (owners) | Pro |
| GET | `/sync/collection/movies` | required | no | §7.2 Collection (owners) | Pro |
| POST | `/sync/collection/remove` | required | no | §7.2 Collection (owners) | Pro |
| GET | `/sync/collection/shows` | required | no | §7.2 Collection (owners) | Pro |
| POST | `/sync/favorites` | required | no | §8.3 Favourite, §8.5 Favourites | Pro |
| PUT | `/sync/favorites/:list_item_id` | required | no | §8.3 Favourite, §8.5 Favourites | Pro |
| GET | `/sync/favorites/:type/:sort_by/:sort_how` | required | partial | §8.3 Favourite, §8.5 Favourites | Pro |
| POST | `/sync/favorites/remove` | required | no | §8.3 Favourite, §8.5 Favourites | Pro |
| POST | `/sync/favorites/reorder` | required | no | §8.3 Favourite, §8.5 Favourites | Pro |
| POST | `/sync/history` | required | no | §6.3 Manual watched/unwatched, §6.2 outbox, §7.2 Watched sync | Free |
| GET | `/sync/history/:type/:id` | required | no | §8.5 History, §7.2 | Pro |
| POST | `/sync/history/remove` | required | no | §6.3 Manual watched/unwatched, §6.2 outbox, §7.2 Watched sync | Free |
| GET | `/sync/last_activities` | required | no | §7.1 Sync engine | Pro |
| GET | `/sync/playback` | required | no | §7.2 Resume points | Pro |
| DELETE | `/sync/playback/:id` | required | no | §7.2 Resume points | Pro |
| GET | `/sync/playback/episodes` | required | no | §7.2 Resume points | Pro |
| GET | `/sync/playback/movies` | required | no | §7.2 Resume points | Pro |
| GET | `/sync/progress/up_next` | required | no | §8.5 Up Next, §8.6 Up Next Everywhere | Pro |
| GET | `/sync/progress/up_next_nitro` | required | no | §8.5 Up Next, §8.6 Up Next Everywhere | Pro |
| GET | `/sync/progress/watched` | required | no | §8.5 Up Next, §8.6 Up Next Everywhere | Pro |
| POST | `/sync/ratings` | required | no | §6.3 Ratings sent to Trakt | Free |
| GET | `/sync/ratings/:type/:rating` | required | no | §7.2 Ratings sync | Pro |
| POST | `/sync/ratings/remove` | required | no | §6.3 Ratings sent to Trakt | Free |
| GET | `/sync/watched/:type` | required | no | §7.2 Watched sync | Pro |
| POST | `/sync/watchlist` | required | partial | §7.2 Watchlist sync, §8.5 Watchlist | Pro |
| PUT | `/sync/watchlist` | required | no | §7.2 Watchlist sync, §8.5 Watchlist | Pro |
| PUT | `/sync/watchlist/:list_item_id` | required | partial | §7.2 Watchlist sync, §8.5 Watchlist | Pro |
| GET | `/sync/watchlist/:type/:sort_by/:sort_how` | required | partial | §7.2 Watchlist sync, §8.5 Watchlist | Pro |
| POST | `/sync/watchlist/remove` | required | no | §7.2 Watchlist sync, §8.5 Watchlist | Pro |
| POST | `/sync/watchlist/reorder` | required | no | §7.2 Watchlist sync, §8.5 Watchlist | Pro |
| GET | `/team` | none | no | §8.1 About Trakt | Free |
| GET | `/users/:id` | optional | no | §8.1 account header, §8.5 profiles | Free |
| GET | `/users/:id/:type/activities` | optional | no | Not available: first-party only (403 for other apps) | — |
| POST | `/users/:id/block` | required | no | §8.5 Friends: follow, requests, block | Pro |
| DELETE | `/users/:id/block` | required | no | §8.5 Friends: follow, requests, block | Pro |
| GET | `/users/:id/collection/:type` | optional | no | §8.5 Friends' profiles | Pro |
| GET | `/users/:id/comments/:comment_type/:type` | optional | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/users/:id/favorites/:type/:sort_by/:sort_how` | required | partial | §8.5 Favourites and Friends' profiles | Pro |
| GET | `/users/:id/favorites/comments/:sort` | optional | no | §8.5 Watchlist and Favourites: comments on them | Pro |
| GET | `/users/:id/favorites/media/:sort` | required | partial | §8.5 Favourites and Friends' profiles | Pro |
| GET | `/users/:id/favorites/movies/:sort` | required | partial | §8.5 Favourites and Friends' profiles | Pro |
| GET | `/users/:id/favorites/shows/:sort` | required | partial | §8.5 Favourites and Friends' profiles | Pro |
| POST | `/users/:id/follow` | required | no | §8.5 Friends: follow, requests, block | Pro |
| DELETE | `/users/:id/follow` | required | no | §8.5 Friends: follow, requests, block | Pro |
| GET | `/users/:id/followers` | optional | no | §8.5 Friends: follow, requests, block | Pro |
| GET | `/users/:id/following` | optional | no | §8.5 Friends: follow, requests, block | Pro |
| GET | `/users/:id/friends` | optional | no | §8.5 Friends: follow, requests, block | Pro |
| GET | `/users/:id/history` | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/history/:type/:item_id` | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/history/episodes` | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/history/episodes/:item_id` | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/history/movies` | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/history/movies/:item_id` | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/history/shows` | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/history/shows/:item_id` | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/likes/:type` | optional | no | §8.5 Comments and likes | Pro |
| GET | `/users/:id/lists` | optional | no | §8.5 Lists | Pro |
| POST | `/users/:id/lists` | required | partial | §8.5 Lists | Pro |
| GET | `/users/:id/lists/:list_id` | optional | no | §8.5 Lists | Pro |
| PUT | `/users/:id/lists/:list_id` | required | no | §8.5 Lists | Pro |
| DELETE | `/users/:id/lists/:list_id` | required | no | §8.5 Lists | Pro |
| GET | `/users/:id/lists/:list_id/comments/:sort` | optional | no | §8.5 Lists: comments | Pro |
| POST | `/users/:id/lists/:list_id/items` | required | partial | §8.5 Lists | Pro |
| PUT | `/users/:id/lists/:list_id/items/:list_item_id` | required | partial | §8.5 Lists | Pro |
| GET | `/users/:id/lists/:list_id/items/:type/:sort_by/:sort_how` | optional | partial | §8.5 Lists | Pro |
| GET | `/users/:id/lists/:list_id/items/movie` | optional | partial | §8.5 Lists | Pro |
| GET | `/users/:id/lists/:list_id/items/movie,show` | optional | partial | §8.5 Lists | Pro |
| GET | `/users/:id/lists/:list_id/items/movie,show,season,episode` | optional | partial | §8.5 Lists | Pro |
| POST | `/users/:id/lists/:list_id/items/remove` | required | no | §8.5 Lists | Pro |
| POST | `/users/:id/lists/:list_id/items/reorder` | required | no | §8.5 Lists | Pro |
| GET | `/users/:id/lists/:list_id/items/show` | optional | partial | §8.5 Lists | Pro |
| POST | `/users/:id/lists/:list_id/like` | required | no | §8.5 Lists | Pro |
| DELETE | `/users/:id/lists/:list_id/like` | required | no | §8.5 Lists | Pro |
| GET | `/users/:id/lists/:list_id/likes` | optional | no | §8.5 Lists | Pro |
| POST | `/users/:id/lists/:list_id/reorder` | required | no | §8.5 Lists | Pro |
| POST | `/users/:id/lists/:list_id/report` | required | no | §8.3 Report a Problem, §8.5 Report | Free |
| GET | `/users/:id/lists/:list_id/smart-list-draft` | required | no | §8.5 Smart Lists | Pro |
| POST | `/users/:id/lists/:list_id/smart-list-draft/convert` | required | partial | §8.5 Smart Lists | Pro |
| GET | `/users/:id/lists/collaborations` | optional | no | §8.5 Lists | Pro |
| POST | `/users/:id/lists/reorder` | required | no | §8.5 Lists | Pro |
| GET | `/users/:id/mir/:year/:month` | optional | no | §8.8 Year and Month in Review, §8.9 | Pro |
| GET | `/users/:id/notes/:type` | optional | no | §8.3 Note, §8.5 Notes | Pro |
| GET | `/users/:id/ratings` | optional | no | §8.5 Ratings | Pro |
| GET | `/users/:id/ratings/:type/:rating` | optional | no | §8.5 Ratings | Pro |
| GET | `/users/:id/ratings/episodes` | optional | no | §8.5 Ratings | Pro |
| GET | `/users/:id/ratings/movies` | optional | no | §8.5 Ratings | Pro |
| GET | `/users/:id/ratings/shows` | optional | no | §8.5 Ratings | Pro |
| POST | `/users/:id/report` | required | no | §8.3 Report a Problem, §8.5 Report | Free |
| GET | `/users/:id/smart-list-drafts` | required | no | §8.5 Smart Lists | Pro |
| GET | `/users/:id/smart-lists` | optional | no | §8.5 Smart Lists | Pro |
| POST | `/users/:id/smart-lists` | required | partial | §8.5 Smart Lists | Pro |
| GET | `/users/:id/smart-lists/:list_id` | optional | no | §8.5 Smart Lists | Pro |
| PUT | `/users/:id/smart-lists/:list_id` | required | no | §8.5 Smart Lists | Pro |
| DELETE | `/users/:id/smart-lists/:list_id` | required | no | §8.5 Smart Lists | Pro |
| GET | `/users/:id/stats` | optional | yes | §8.5 Insights (VIP) | Pro |
| GET | `/users/:id/watched/:type` | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/watched/movies` | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/watched/movies` (`extended=min` twin) | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/watched/shows` | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/watched/shows` (`extended=min` twin) | optional | no | §8.5 History and Friends' profiles, §8.8 history import | Pro |
| GET | `/users/:id/watching` | optional | no | §8.5 Friends Watching | Pro |
| GET | `/users/:id/watchlist/:type/:sort_by/:sort_how` | optional | partial | §8.5 Watchlist and Friends' profiles | Pro |
| GET | `/users/:id/watchlist/comments/:sort` | optional | no | §8.5 Watchlist and Favourites: comments on them | Pro |
| GET | `/users/:id/watchlist/movie,show/:sort` | optional | partial | §8.5 Watchlist and Friends' profiles | Pro |
| GET | `/users/:id/watchlist/movies/:sort` | optional | partial | §8.5 Watchlist and Friends' profiles | Pro |
| GET | `/users/:id/watchlist/shows/:sort` | optional | partial | §8.5 Watchlist and Friends' profiles | Pro |
| GET | `/users/:id/yir/:year` | optional | no | §8.8 Year and Month in Review, §8.9 | Pro |
| GET | `/users/:id/yir/:year/persona` | optional | partial | §8.8 Year and Month in Review, §8.9 | Pro |
| PUT | `/users/avatar` | required | no | Not available: first-party only (401 for other apps) | — |
| DELETE | `/users/avatar` | required | no | Not available: first-party only (401 for other apps) | — |
| GET | `/users/blocked` | required | no | §8.5 Friends: follow, requests, block | Pro |
| GET | `/users/hidden/:section` | required | no | §8.5 Hidden items, Stop Watching, calendar and recommendation hides | Pro |
| POST | `/users/hidden/:section` | required | no | §8.5 Hidden items, Stop Watching, calendar and recommendation hides | Pro |
| POST | `/users/hidden/:section/remove` | required | no | §8.5 Hidden items, Stop Watching, calendar and recommendation hides | Pro |
| POST | `/users/hidden/calendar/remove` | required | no | §8.5 Hidden items, Stop Watching, calendar and recommendation hides | Pro |
| GET | `/users/hidden/dropped` | required | no | §8.5 Hidden items, Stop Watching, calendar and recommendation hides | Pro |
| GET | `/users/hidden/progress_watched` | required | no | §8.5 Hidden items, Stop Watching, calendar and recommendation hides | Pro |
| POST | `/users/hidden/progress_watched/remove` | required | no | §8.5 Hidden items, Stop Watching, calendar and recommendation hides | Pro |
| GET | `/users/likes/comments` | required | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/users/likes/lists` | required | no | §8.5 Lists | Pro |
| GET | `/users/reactions/comments` | required | no | §8.3 Comments, §8.5 Comments and likes | Pro |
| GET | `/users/requests` | required | no | §8.5 Friends: follow, requests, block | Pro |
| POST | `/users/requests/:id` | required | no | §8.5 Friends: follow, requests, block | Pro |
| DELETE | `/users/requests/:id` | required | no | §8.5 Friends: follow, requests, block | Pro |
| GET | `/users/requests/following` | required | no | §8.5 Friends: follow, requests, block | Pro |
| GET | `/users/saved_filters/:section` | required | yes | §8.5 Calendar saved filters (VIP) | Pro |
| PUT | `/users/set_cover` | required | no | Not available: first-party only (401 for other apps) | — |
| GET | `/users/settings` | required | no | §5 after connect, §8.1 Trakt account settings, limits | Free |
| PUT | `/users/settings` | required | no | §5 after connect, §8.1 Trakt account settings, limits | Free |
| GET | `/users/settings/plex` | required | partial | §6.4 Double-play guard: Trakt's own Plex link | Free |
| PUT | `/users/settings/plex` | required | no | §6.4 Turn Trakt's Plex scrobbler off for this server when Crucible records plays | Free |
| POST | `/users/settings/plex/connect` | required | no | §7.3 Link out to Trakt (return_url only accepts Trakt hosts) | Pro |
| DELETE | `/users/settings/plex/connect` | required | no | §7.3 Unlink Trakt's Plex connection (confirmed) | Pro |
| GET | `/users/settings/plex/servers` | required | no | §6.4 Double-play guard: Trakt's own Plex link | Free |
| GET | `/users/settings/plex/servers/:server_id` | required | no | §6.4 Double-play guard: Trakt's own Plex link | Free |
| POST | `/users/settings/plex/sync` | required | no | §7.3 Sync Center: ask Trakt's Plex link to sync now | Pro |
| GET | `/users/syncs` | required | no | §7.3 Trakt imports: list, paused, skipped, Undo import | Pro |
| GET | `/users/syncs/:id` | required | no | §7.3 Trakt imports: list, paused, skipped, Undo import | Pro |
| DELETE | `/users/syncs/:id` | required | no | §7.3 Trakt imports: list, paused, skipped, Undo import | Pro |
| GET | `/users/syncs/:id/paused` | required | no | §7.3 Trakt imports: list, paused, skipped, Undo import | Pro |
| GET | `/users/syncs/:id/skipped` | required | no | §7.3 Trakt imports: list, paused, skipped, Undo import | Pro |
| GET | `/users/syncs/:type` | required | no | §7.3 Trakt imports: list, paused, skipped, Undo import | Pro |
| GET | `/watchnow/sources` | none | no | §8.4 Where to Watch (Limited Access) | Pro |
| GET | `/watchnow/sources/:countryCode` | none | no | §8.4 Where to Watch (Limited Access) | Pro |
| POST | `/younify/connect` | required | partial | §7.3 Link out to Trakt (return_url only accepts Trakt hosts) | Pro |
| GET | `/younify/connections` | required | partial | §7.3 Streaming services Trakt imports from: list, refresh, remove | Pro |
| POST | `/younify/users/refresh` | required | partial | §7.3 Streaming services Trakt imports from: list, refresh, remove | Pro |
| POST | `/younify/users/refresh/:service_id` | required | partial | §7.3 Streaming services Trakt imports from: list, refresh, remove | Pro |
| POST | `/younify/users/refresh/:service_id/:all_data` | required | partial | §7.3 Streaming services Trakt imports from: list, refresh, remove | Pro |
| DELETE | `/younify/users/services/:service_id` | required | no | §7.3 Streaming services Trakt imports from: list, refresh, remove | Pro |

## Appendix B: sources

- Trakt contract and guides: github.com/trakt/trakt-api (`projects/api/src/contracts`, `projects/developer/src/lib/guides`), read 2026-11-08; announcements #495, #635, #655, #681, #694, #775, #808, #943, #1031; issues #888, #909, #926, #955, #972, #996, #1038, #1041, #1057, #1063.
- Research notes: `~/Documents/crucible-trakt-research/` (`api/*.json` endpoint catalogue and narratives, `api/guides.md`, `api/legacy-diff.md`, `research/trakt-policy-2026.md`, `research/competitor-ux.md`, `research/plex-trakt-pitfalls.md`, `app/*.md` maps of this codebase).
- Matching and sync practice: github.com/Taxel/PlexTraktSync (guid parsing, search-by-id checks, union watched sync, `trigger_sync`), Firecore's Infuse Trakt articles (free sends, paid pulls), Plezy's README (Trakt rows and scores).
