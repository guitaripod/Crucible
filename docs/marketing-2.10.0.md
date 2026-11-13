# Marketing 2.10.0

The release that makes Crucible Pro worth its new price before the price changes: What to Watch picks from your own
library when you say what you feel like, and Previously On recaps your last episodes on every show. Both are asked
for, never automatic, and both are in the demo. The story for the listing: "Ask what to watch".

2.10.0 follows 2.9.0 in the store. 2.9.1 went to TestFlight only, so its work (Swedish, Danish, Norwegian, Finnish
and Icelandic, Share Card, the Crucible Pro screen in your own numbers, HDR MKV in full resolution) and the iPhone
Duo paragraph are part of 2.10.0's What's New.

## Where it starts from

- The 30 days to 2026-11-12 (`myyty app crucible`): 95 first downloads, 19 redownloads, 289 updates, 3 Crucible Pro
  purchases (3.2 % of first downloads). Impressions and tap-through were not read for this release.
- Target for the 30 days after release: first downloads at or above 95 and Crucible Pro purchases above 3.2 % of
  them, read on the lifetime price that starts 2026-12-07 (`docs/pricing.md`).

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
- App Review notes: `store/review-notes-2.10.0.txt` (where both features are in the demo, what they send).
- Screens, staged 2026-11-14 in `marketing/appstore` (not in git):
  - iPhone 6.9-inch, in English and fourteen locales: Ask what to watch is second, after Home, and Every play, day
    by day leaves the set, which stays at ten. Each locale's panel shows the answer the live model wrote in that
    language for "Something light for tonight". Captured with `SHOT_SCRIPT=watch` (`WatchShotScript`, answers from
    `DemoBrain`, no call to the service) and composed with `marketing/store/compose.py --only 15-what-to-watch`;
    the other nine panels of each locale are the ones in App Store Connect (`asc screenshots download`) or, for the
    four Nordic locales, the local set.
  - iPad 13-inch, English: the same panel second (ten in the set), from `IPadStoreShots.testCapturesWhatToWatch` in
    the demo, composed with `--only 09-what-to-watch`.
  - Apple TV, English: the picks at 4K second (ten in the set), from `DemoTests` on the 4K simulator.
  - iPhone Duo: unchanged, ten stories without What to Watch.
- Upload once the 2.10.0 version exists and `docs/asc-metadata.json` names it: `python3 scripts/asc-screenshots.py
  --locales=all`, then the Duo set and the Header and Search Results images as `docs/marketing-2.9.0.md` describes.

## Privacy

- `docs/privacy-policy.txt` has the section "Crucible's AI (optional)" from version 2.10; publish it with the
  release. `docs/app-privacy.json` adds Search History and widens Product Interaction; apply and publish it with
  `asc web privacy` at release.
- The on-screen sentences, the policy and the request are checked against each other: a recap sends the series
  name and the episode descriptions and nothing else.

## Open before release

- 2.9.0 has to clear review before the 2.10.0 version can be created.
- Midgar's model service runs on a plan whose CPU limit a burst of requests can trip, which hangs one network edge
  for every app until the service is deployed again (Midgar roadmap P3.22). Decide that before this feature is in
  front of every Crucible Pro owner.
- Aliases: `tools/ai/gen_alias_sql.py` after any change to `tools/ai/prompts`, and `tools/ai/gen_demo_answers.py`
  when the demo library or the example requests change.
