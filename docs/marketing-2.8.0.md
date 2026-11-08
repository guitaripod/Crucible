# Marketing 2.8.0

The release that makes long anime short: Essentials hides the anime-only episodes of the shows Crucible Guides
covers, and the player skips recaps, previews and endings by the file's own chapter names. The listing leads with
both, in every one of the seventeen listing languages, and every claim below is checked against the build.

## What the release says, and where it is true

| Claim in the listing or What's New | Where the build does it |
| --- | --- |
| Dragon Ball Super goes from 131 episodes to 110, or 83 with the two films seen | Crucible Guides #1 (`Sources/CrucibleCore/Resources/guides.envelope.json`), `EssentialsPlan.hides`; `EssentialsTests.skipAnimeOnlyHidesTwentyOneEpisodesAndTheFilmsTwentySevenMore` |
| Starting with Dragon Ball, Dragon Ball Z and Dragon Ball Super | the seed's three shows; `EssentialsTests.theSeedIsSignedAndCoversTheDragonBallShows` |
| The show page offers it once and says how much time it saves | `EssentialsCopy.shouldOffer`, `offerMessage`; iPhone and iPad `EssentialsOfferConfiguration`, Apple TV `.essentialsOffer`; `DemoTests.testPaperLanternsOffersEssentialsOnceAndSkipsItsAnimeOnlyEpisodes` |
| Up Next and Continue follow your choice | the player: `UpNextResolver` through `EssentialsCenter.successor`; the show page: `ShowDetailModel.computeUpNext(hidden:)`; Home, the launch and the Top Shelf: `EssentialsCenter.hubs`; `EssentialsTests.homeShowsTheNextKeptEpisodeInsteadOfAHiddenOne` |
| A long press keeps any episode | `Keep This Episode` context actions on iPhone, iPad and Apple TV, `EssentialsChoice.kept` |
| The guides are an open dataset (CC BY-SA), checked every week | github.com/guitaripod/crucible-guides (two signals per hidden episode, CI weekly); `GuideStore.refresh` weekly, never in the demo |
| Skip Recap, Skip Preview and Skip Ending from named chapters (Recap, Previously On, Next Episode Preview, Ending, OP, ED), downloads keep them | `SkipSegments` rules and guards, `DownloadResolver` stores the segments; `SkipSegmentsTests` |
| Spoiler Shield hides titles, synopses and stills of unwatched episodes | `SpoilerShield`, `ShowDetailModel.status(shielded:)` |
| Subtitles are real tracks, Off is remembered | 5b787a9 (WebVTT rendition) |
| Lock screen and Control Center keep their controls between episodes | d1112be |
| Libraries take the shape of their artwork | e3d5da2 |
| Apple TV: Top Shelf carousel with previews, richer Home cards | db4205b, a3bf88c |
| Crucible Server: scan its code, Previously On written on your own hardware from the subtitles, no invented names, nothing leaves the network | `server/` (server-v0.2.0 on GitHub, Homebrew, AUR): HMAC pairing pinned to the certificate, `recap::write_summary` name and support checks, LAN/tailnet-only listener; the app's `Features/Companion`, `CompanionTests` including a live pairing with the Rust server |
| An Apple TV pairs through a paired iPhone (Pair with iPhone, then Allow) or by a code the iPhone scans | `TVCompanionViewController` (DeviceDiscoveryUI picker, `crucible-pair` application service), `TVCompanionCodeViewController`, the iPhone's `CompanionAdvertiser`; server-v0.2.0 `/pair/code` admits the Apple TV by the owner's policy; `CompanionLiveTests` pairs both paths with the Rust server |

Privacy: the only new request is the weekly guides download from `api.midgarcorp.cc`, identical for everyone and
carrying no identifier. The policy (listing and midgarcorp.cc/crucible/privacy) now says so, and says what happens
to the IP address it comes from (rate limiting at the gateway, Cloudflare's request logs for up to seven days),
instead of claiming no log at all. The App Privacy label stays as it is: nothing from the request is linked to a
person or kept beyond servicing it.

## Store set

- Listing text, keywords (anime, filler, skip intro, recap added), promotional text and What's New:
  `store/metadata/{ios,tvos}/version/2.8.0/*.json`, subtitle "Skip filler, recaps and intros" in
  `store/metadata/*/app-info/*.json`, all seventeen locales.
- iPhone 6.9" (ten panels, eleven languages): Skip the filler and Skip the recap move to second and third, Seasons
  at a glance leaves. `marketing/store/compose.py iphone` and `--locale <locale>`; captures from
  `marketing/shots/mac-run.sh` (`SHOT_SCRIPT=essentials` for the two new screens). The localized captures were
  reshot on the Mac because the earlier ones carried a 9.41 clock.
- iPad 13" (nine panels): Skip the filler second, from `marketing/store/shoot-ipad.sh`.
- Apple TV (nine panels): the Essentials offer, focused, second; from the 4K simulator run of
  `DemoTests.testPaperLanternsOffersEssentialsOnceAndSkipsItsAnimeOnlyEpisodes`.
- Upload with `scripts/asc-screenshots.py --locales=all` once ASC holds the 2.8.0 versions.

## Submitted (2026-11-08)

- iPhone and iPad 2.8.0 (build 202611080723) and Apple TV 2.8.0 (build 202611080732) are in review together, both
  released on approval. iOS 2.7.2 was withdrawn from review and its version renamed 2.8.0, so iOS goes from 2.4.0
  straight to 2.8.0; its What's New folds in 2.7.2's (`store/metadata/ios/version/2.8.0`).
- The new subtitle ("Skip filler, recaps and intros" and its translations), descriptions, keywords and promotional
  text are applied on both trains; `midgar listing crucible --train ios|tvos --version 2.8.0` plans no changes.
- Screenshots: ten iPhone panels in eleven languages, nine iPad panels and nine Apple TV panels, all COMPLETE. Review
  notes from `store/review-notes-2.8.0.txt` on both versions. Tag `2.8.0` is the commit both builds came from.

## Funnel

Baseline from the App Store Discovery and Engagement and App Downloads Standard reports, 2026-10-25 to
2026-11-05 (unique impressions, unique product page views, first-time downloads):

| Device | Impressions | Page views | Downloads | Tap-through | View to download |
| --- | --- | --- | --- | --- | --- |
| Apple TV | 3932 | 377 | 46 | 9.6 % | 12.2 % |
| iPhone | 2287 | 138 | 12 | 6.0 % | 8.7 % |
| iPad | 1083 | 41 | 9 | 3.8 % | 22.0 % |

On iPhone, App Store search brings 2198 of the 2287 impressions but only 66 page views. Targets for the four weeks
after 2.8.0 is live: iPhone tap-through 8 %, iPhone view to download 15 %, Apple TV view to download 16 %, and
search impressions from the new anime, filler and recap keywords.
