# Marketing 2.10.0

The release that makes Crucible Pro worth its new price before the price changes: What to Watch picks from your own
library when you say what you feel like, and Previously On recaps your last episodes on every show. Both are asked
for, never automatic, and both are in the demo. The story for the listing: "Ask what to watch".

2.10.0 follows 2.9.0 in the store. 2.9.1 went to TestFlight only, so its work (Swedish, Danish, Norwegian, Finnish
and Icelandic, Share Card, the Crucible Pro screen in your own numbers, HDR MKV in full resolution) and the iPhone
Duo paragraph are part of 2.10.0's What's New.

## Where it starts from

- The 30 days to 2026-11-12 (`myyty app crucible`): 95 first downloads, 19 redownloads, 289 updates, 3 Crucible Pro
  purchases (3.2 % of first downloads).
- The store funnel over the 20 report days from 2026-10-19 to 2026-11-12 (App Store Discovery and Engagement,
  `asc analytics`): 7,384 impressions, 532 product page views and 68 taps in all, with Apple TV holding 4,056 of
  the impressions. On iPhone, search showed Crucible 1,794 times and 62 of those became a page view (3.5 %), while
  browse turned 31 of 169 into one (18 %). App Downloads counts 58 first downloads from 2026-10-26 to 2026-11-12,
  50 of them from search. Search is where people meet Crucible and where it loses them, and what they see there is
  the Search Results image and the first screenshots.
- Target for the 30 days after release: first downloads at or above 95 and Crucible Pro purchases above 3.2 % of
  them, read on the lifetime price that starts 2026-12-07 (`docs/pricing.md`), and iPhone search turning 6 % of
  its impressions into page views.

## What the release says, and where it is true

| Claim in the listing or What's New | Where the build does it |
| --- | --- |
| Say what you feel like and get picks from your own library, with a reason for each | `WatchSession`, `WatchPicker`; `WhatToWatchViewController`, `TVWhatToWatchViewController`; `WatchPickerTests`, `WhatToWatchTests` (iOS and tvOS UI, against the live service) |
| Only titles in your library can be picked | `WatchPicker.picks` takes numbers that were offered and nothing else |
| Open it with the wand button on Home, or the What to Watch tile on Apple TV | `HomeViewController.whatToWatchItem`, `TVHomeItem.whatToWatch` |
| Previously On works for every show: read the descriptions or Write a Recap | `PreviouslyOnRequest.offer`, `DescribedRecap`; `PreviouslyOnViewController`, `TVShowDetailViewController` |
| With Crucible Server the recap is written from what was said | `PreviouslyOnOffer.server`, unchanged since 2.8.0 |
| Both are part of Crucible Pro | `ProFeature.whatToWatch`, `.previouslyOn`; the service also refuses without Pro |
| They run only when you ask | no request is made on opening a screen or typing; `WatchSession.answer` and `DescribedRecap.write` are called from a button |
| What to Watch sends your words and your library's titles, years, genres, lengths, ratings and watched state | `WatchPicker.planInput`, `pickInput`, `digestLine`; hidden libraries are left out (`LibraryVisibility`) |
| A recap sends the show's name and the episode descriptions | `DescribedRecap.input` and its test |
| The demo shows both without using the network | `DemoBrain`, `Data/answers.json`; `DemoBrainTests`, `DemoTests` (iOS and tvOS UI) |

## Money

- Both features are inside Crucible Pro, with no tier of their own (Midgar D40). Measured cost is about 0.03 cents
  a call, and a What to Watch answer is two calls; an owner may ask 40 times a day for each kind, and Crucible as a whole is held to 0.75 dollars a day.
- Free: reading the episode descriptions under Previously On, and everything that was free before.
- Prices from 2026-12-07: $14.99 a year and $39.99 lifetime (`docs/pricing.md`). 2.10.0 should be live before then.

## Listing (staged)

- `store/metadata/{ios,tvos}/version/2.10.0/`: description, promotional text and What's New in 21 locales. The
  description gains ASK WHAT TO WATCH, names both features first in the Crucible Pro list and says what they send in
  PRIVATE BY DESIGN; the iPad, offline and search wording is shorter to stay within 4,000 characters.
- What's New: What to Watch and Previously On, then 2.9.1's notes, then on iPhone and iPad the iPhone Duo paragraph.
- Keywords (2026-11-14): no word of the name or subtitle any more. The App Store indexes both already, so
  filler, skip, intro and recap were spent twice in seventeen of twenty-one languages; their room went to
  movies, series, subtitles, 4K, HDR and what to watch, in each market's words, within 100 characters.
- App Review notes: `store/review-notes-2.10.0.txt` (where both features are in the demo, what they send).
- Screens, staged 2026-11-14 in `marketing/appstore` (not in git):
  - iPhone 6.9-inch, in English and fourteen locales (2026-11-14): the set opens with Ask what to watch, Skip the
    filler and Skip the recap, then Home, the library, a title, search, Downloads, Statistics and the Year in
    Review poster; Every play, day by day leaves the set, which stays at ten. Each locale's first panel shows the
    answer the live model wrote in that language for "Something light for tonight" (`DemoBrain`, no call to the
    service). All ten panels of every locale are shot from this release's build with `SHOT_SCRIPT=store` on
    `marketing/shots/mac-run.sh` and composed with `marketing/store/compose.py iphone --locale LOCALE`.
  - Before composing, look at every language's raw captures side by side. A run on a loaded Mac reports success
    and the right number of shots while one of them shows the screen before it, plays instead of hours, or a
    sheet that had not opened yet; several languages were shot again for that on 2026-11-14.
  - iPad 13-inch, English: the same panel second (ten in the set), from `IPadStoreShots.testCapturesWhatToWatch` in
    the demo, composed with `--only 09-what-to-watch`.
  - Apple TV, English (2026-11-14): all ten panels shot again at 4K from the polished build, because the round
    that redrew the settings rows, the cards and the tab bar made the October set stale. Home, What to Watch,
    a Previously On recap, Skip 11 Anime-Only on Paper Lanterns, Halcyon, a card's menu, the Movies library,
    scrubbing, Up Next and Statistics for the year. The recap is new to the set and takes the place of the Audio
    menu, whose third track name the menu cuts short; the Movies panel is the loaded library with its Recently
    Watched row and Statistics is the demo's year, in place of the Genre menu over six copies of one poster and
    the mock's week.
    `marketing/store/tv_set.py` names the UI test and attachment behind each panel and assembles the set from a
    test run on the Apple TV 4K simulator at 4K.
  - iPhone Duo, in English and fourteen locales (2026-11-14): ten stories that open with Ask what to watch and
    Skip the filler on the inner display, then Skip the recap, Catch up before you play (Previously On), search,
    the library, a title, Downloads, Statistics and the Year in Review poster. The type is twice the size of the
    2.9.0 set's and each device fills its panel and runs off the lower edge. Captured from this release's build
    with `marketing/shots/duo-run.sh STATE LANGUAGE...` and `SHOT_SCRIPT=store` (`StoreShotScript`: the screens the
    store uses and nothing else, a third of the tour's time), composed with `marketing/store/compose_duo.py duo`.
  - Header and Search Results, in all 21 listing languages: "Ask what to watch" over "Picks from your own Plex
    library" and five iPhones, What to Watch in the middle. Each is made for its own placement (3840 by 1646 and
    3840 by 2560) instead of one 5244 by 2950 image cropped two ways, because Apple promises only an art safe area
    in the middle of each (1646 by 661 and 2168 by 1030, creative assets specifications in App Store Connect
    Help): the phrase and the phone down to its request field sit inside it, which `compose_duo.py header
    --guides` draws. The 2.9.0 images had their words above that box, where a crop removes them. Arabic and Thai
    carry the English words; Indonesian, Russian, Turkish and Vietnamese carry their own words over the English app.
- Upload once the 2.10.0 version exists and `docs/asc-metadata.json` names it: `python3 scripts/asc-screenshots.py
  --locales=all` (iPhone, iPad, Duo and Apple TV; `--locales=de-DE,fr-FR` uploads named locales alone), then
  `python3 scripts/asc-creative.py` for the Header and Search Results images. Look at both placements in App Store Connect's preview before the version is submitted: Apple
  publishes the safe areas, not how each device crops around them.

## Privacy

- `docs/privacy-policy.txt` has the section "Crucible's AI (optional)" from version 2.10. Published 2026-11-14:
  midgarcorp.cc/crucible/privacy carries it, and every listing locale on both platforms has the 13 November text
  as its App Store privacy text (the four Nordic listings had a shorter text from 7 November).
- `docs/app-privacy.json` adds Search History. Applied and published 2026-11-14 with `asc web privacy apply` and
  `publish`, which need an Apple web session (`asc web auth login`, a 2FA code from the founder); `asc web privacy
  plan` reads no difference since.
- The on-screen sentences, the policy and the request are checked against each other: a recap sends the series
  name and the episode descriptions and nothing else.

## Submitted (2026-11-14)

- iPhone and iPad 2.10.0 (build 202611131818) and Apple TV 2.10.0 (build 202611111328) went to review together,
  release on approval. They were submitted with manual release while the App Privacy label still lacked Search
  History and switched to release on approval once it was published the same day. Tag `2.10.0`.
- `asc validate`: no errors on either platform; the one warning left is the annual subscription's missing
  promotional image.

## Open

- Midgar's model service runs on a plan whose CPU limit a burst of requests can trip, which hangs one network edge
  for every app until the service is deployed again (Midgar roadmap P3.22). Decide that before this feature is in
  front of every Crucible Pro owner.
- Aliases: `tools/ai/gen_alias_sql.py` after any change to `tools/ai/prompts`, and `tools/ai/gen_demo_answers.py`
  when the demo library or the example requests change.
