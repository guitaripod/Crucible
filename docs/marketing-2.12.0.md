# Marketing 2.12.0

The release that makes Trakt more than a scrobbler: every movie, show and episode page shows what Trakt members say
about it, and the viewer can join in. The story for the listing: "See what people say". Library Research, the
widened Sports Research, is the second paragraph, because it needs Crucible Server and an owner's own model.

2.12.0 follows 2.11.0, which went to review on 2026-11-15 and is still there, so its notes stay with it; 2.12.0's
What's New covers only what changed after tag `2.11.0`.

## Where it starts from

- The 30 days to 2026-11-13 (`myyty app crucible`, the warehouse's last day): 95 first downloads, 19 redownloads,
  325 updates, 3 Crucible Pro purchases (3.2 % of first downloads), the same as `docs/marketing-2.10.0.md` read.
  2.10.0 reached the store on 2026-11-14, too late to move them.
- The store funnel is the one `docs/marketing-2.10.0.md` measured: search is where people meet Crucible on iPhone and
  where it loses them (3.5 % of search impressions became a page view, 18 % of browse ones). The first three
  screenshots and the Search Results image are what search shows, so they stay on the three strongest stories
  (What to Watch, Skip the filler, Skip the recap); the community panel is fourth.
- Target for the 30 days after release: first downloads at or above 95 and Crucible Pro purchases above 3.2 % of
  them on the lifetime price from 2026-12-07 (`docs/pricing.md`). Trakt Community has no target of its own: Crucible
  sends no usage counts, so it can show only in purchases.

## What the release says, and where it is true

| Claim in the listing or What's New | Where the build does it |
| --- | --- |
| Every movie, show and episode page shows its Trakt community once Trakt is connected | `TraktCommunitySubject.init(_:)` (movie, show, episode; seasons have none); `TraktCommunityDetailBlock` in `MediaDetailViewController` and `ShowDetailViewController`; the community sections of `TVDetailViewController` |
| Trakt's score and how the votes spread | `TraktTitleStats`, `TraktRatingDistribution`; the histogram in `TraktCommunityArt` |
| Reviews and comments with replies, likes and seven reactions | `TraktCommunityRoute.comments`, `.replies`, `.like`, `.react`; `TraktReaction` has seven cases |
| Spoilers hidden until tapped (selected on Apple TV) | `TraktCommentText` spoiler runs; the cover in the iPhone card and thread, the reveal row on Apple TV |
| Write a comment or a review, reply, react, edit or delete your own, report | routes `.post`, `.reply`, `.edit`, `.delete`, `.reportComment`, `.reportUser`; `TraktCommentComposerViewController`, `TVCommentComposerViewController`; Trakt's rules in `TraktCommentDraft` |
| Free: the score, the top two comments with their threads, likes, reactions and writing | `ProFeature.traktCommunity`; free threads open with `isFree` and skip the paywall |
| Crucible Pro: every comment in seven orders, What People Say, who is watching now, members to follow or block | `TraktCommentSort` (seven cases), `TraktSentiments` (movies and shows), `TraktWatchingNow`, `.follow`, `.block`; member screens on both platforms |
| On iPhone, iPad and Apple TV, and in the demo | `DemoLibrary+TraktCommunity` (the stand-in Trakt); `TraktCommunityTests`, `DemoTraktCommunityTests`, `TraktTests` (iOS and tvOS UI) |
| Library Research covers any library Plex has no agent for, with Crucible Server 0.6 | `SportsCopy`, `ProFeature.sportsResearch`; a server before 0.6 is offered neither kinds nor take back (commit 38c4ed4) |
| Take back what research wrote, for a file or a library | `SportsItemViewController`, `SportsResearchViewController` |
| What you need, and Searching paused | `SportsCopy` (commits 940d8c7, a5db344) |
| Hold the Library tab to switch libraries (iPhone) | `LibraryTabMenu`, `TabBarController` |
| Every card filled with its artwork | `ArtworkAspect`, `PosterCell`, `TVArtworkView` |
| Recently Watched and Watch History show current titles and posters | `CurrentMetadata`, `HistoryFeed`, `RecentlyWatched` |
| Crucible Server reached away from home at once; a new pairing shows at once | `CompanionClient` (every host asked at once), `CompanionViewController` |

## Money

- Trakt Community joins Crucible Pro with no tier of its own; it costs Midgar nothing, since every call goes from the
  device to Trakt.
- Free keeps enough of it to be worth connecting Trakt for: the score, the top two comments with their threads, and
  writing, liking and reacting.

## Listing (staged)

- `store/metadata/{ios,tvos}/version/2.12.0/`: description, promotional text and What's New in 21 locales, keywords
  unchanged. The description's Trakt sentence now says you can read, react to and write the reviews on every title,
  and the Crucible Pro list names every comment and member on Trakt; the player, iPad, couch and free-week sentences
  are shorter to stay within 4,000 characters.
- Promotional text leads with Trakt Community on both platforms.
- What's New: Trakt Community, then Library Research, then the smaller changes; the Apple TV notes leave out the
  Library tab, which is iPhone only, and say select instead of tap.
- App Review notes: `store/review-notes-2.12.0.txt` (where Trakt Community is in the demo, what is free, what
  Library Research needs).
- Every translation was reviewed against English by an independent reviewer per locale, with each reported problem put
  to a second reviewer who tried to refute it; the eighteen that held were fixed (full Statistics read as a
  full-screen view in Japanese and Korean, What you need read as a clause, untranslated words in Russian and
  Norwegian, and others). Before that, the Crucible Pro sentence was rewritten in every language so What People Say
  no longer reads as one of the seven sort orders.
- Screens, staged 2026-11-15 in `marketing/appstore` (not in git):
  - iPhone 6.9-inch, English and fourteen locales: See what people say is the fourth panel, Halcyon's community
    scrolled to Trakt's score with its vote spread, who is watching, What People Say and the first comments; it takes
    the Year in Review poster's place, which Statistics and the description still name. The first three panels stay
    on What to Watch, Skip the filler and Skip the recap because they are what search shows. Every panel of every
    locale was shot again from this build (`SHOT_SCRIPT=store`; `StoreShotScript` now captures `17-community`, and
    `SHOT_SCRIPT=community` captures only it) because Recently Watched now shows items' current titles and Statistics
    waits until every play is counted. Each language's raw captures were checked against English side by side; the
    orange behind the tab bar on the community panel is Write a Review under the glass, wider in longer languages.
  - iPad 13-inch, English: `IPadStoreShots` captures `10-community` (Cold Meridian) after the movie page and
    `testCapturesCommunity` alone; it replaces Every play, day by day. All ten shot again.
  - Apple TV, English: panel 6 is Halcyon's community with the focus on What People Say
    (`TraktTests.testTheCommunityShowsItsPulseWhatPeopleSayAndCommentsTogether`), in place of a card's menu. Focus on
    a comment card scrolls the score card half off the top, so the capture is taken one row higher. The other nine
    are the 2026-11-14 set; `tv_set.py` names the new test.
  - iPhone Duo, English and fourteen locales: the community on the inner display in portrait is the fifth story
    (the outer display puts the bars on the side and cuts What People Say), after Previously On, and the Year in
    Review poster leaves the set. All three states were shot again for every language.
  - Header and Search Results, 21 languages: the words stay "Ask what to watch"; composed again from the new captures.
- Upload once the 2.12.0 version exists and `docs/asc-metadata.json` names it: `python3 scripts/asc-screenshots.py
  --locales=all`, then `python3 scripts/asc-creative.py`.

## Privacy

- `docs/privacy-policy.txt`, every listing locale's App Store privacy text (`store/metadata/*/app-info`) and
  midgarcorp.cc/crucible/privacy say what Trakt Community asks Trakt for and what it sends: comments, replies, likes,
  reactions, reports, follows and blocks go to Trakt under the viewer's own account, what they write is public there,
  and an unposted draft stays on the device. Midgar receives none of it.
- `docs/app-privacy.json` needs no change: Other User Content is already declared, and nothing reaches Midgar.

## Website

- midgarcorp.cc/crucible is a page of its own since 2026-11-15 (`web/midgarcorp/src/pages/crucible/index.astro` in
  the Midgar monorepo): it opens on the demo's lighthouse the way the app opens on its Resume hero, then one scene
  per idea with this build's captures framed by the frames CLI. Its FAQ, pricing and install steps still come from
  `src/data/landing/crucible.json`, which also carries What to Watch, Trakt Community and Library Research now.
