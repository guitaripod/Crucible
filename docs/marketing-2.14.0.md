# Marketing 2.14.0

2.14.0 is the release that has the picture there with the press and shows where a scrub is going: Instant Start
makes the title a viewer is about to play ready before Play, and on iPhone and iPad the scrubber carries a preview of
every moment above the finger. It follows 2.13.0 on the store (released 2026-11-17), so its What's New covers
everything after 2.13.0, including what only reached TestFlight as 2.13.1 (iPhone and iPad) and 2.13.1 and 2.13.2
(Apple TV).

## What the release says, and where it is true

| Claim in the listing or What's New | Where the build does it |
| --- | --- |
| Instant Start: the title you are about to play is made ready before you press Play | `PlaybackWarmUp`, `PlaybackSession+Preload` (1e6077d3, 5ba2f7f1); never on mobile data, in Low Power Mode or on a hot device; Settings › Playback › Starting switches it off |
| Scrub previews on iPhone and iPad: a card above the finger, or the pointer, with the picture, time and chapter | `ScrubPreview`, `ScrubPreviewCard`, `ServerScrubStills` (f0587126); the pictures are the server's video preview thumbnails, a download shows frames of its own file (`FileScrubStills`) |
| Scrubbing a converted stream goes once, to where you let go | `PlaybackSession.viewerScrubbing` and `landScrub` (f0587126, f39e58c0) |
| Without Crucible Pro, What to Watch and a written recap each give one real answer | `ProTasteStore`, `ProAccess.tasteAccess` (09b26df2, 8e0738dc, d21bb4dd) |
| The player's close button stops playback; a swipe down keeps the mini player | 8218a1c8 |
| A folder button in the library, and Browse Folders on Shift-Command-O | d60d60f1 |
| No crash with a hardware keyboard on iOS 17 and 18 | de5d5d32 |
| A Dolby Vision profile 7 file in two video tracks plays at once, as HDR10 | b0d64b22 |
| Apple TV: Play after a night away no longer starts the episode over; Diagnostics shows the log | ac9ef136, f22e8bd5 |

Not claimed: scrub previews on Apple TV (the system player there has no place for them) and on the iPhone Duo's
store set (see below).

## Listing

- `store/metadata/ios/version/2.14.0/` and `store/metadata/tvos/version/2.14.0/`: What's New and promotional text in
  all 21 locales, each platform its own. The description's player paragraph now names Instant Start and, for iPhone
  and iPad, scrub previews, rewritten inside the 4,000 characters the description already filled; keywords and URLs
  are carried from 2.13.0.
- What's New was applied by `midgar ship`; the description and promotional text with
  `asc metadata apply --app 6822066419 --version 2.14.0 --platform IOS|TV_OS --dir store/metadata/<train>` and read
  back in all 21 locales on both platforms.
- App Review notes: `store/review-notes-2.14.0.txt` and `store/review-notes-tvos-2.14.0.txt`, pushed with
  `asc review details-update`.

## Store art

- iPhone, panel 3 is new: "Scrub with a preview", the player in its scrubbing state with the preview card over the
  thumb, above the Skip Recap capture, captioned in the 14 languages the set is shot in. Panel 6, the library, was
  shot again with its folder button. Both in all 15 app languages (`SHOT_SCRIPT=fresh`); the other eight panels show
  screens this build did not change and were composed again from the captures of 2.13.0.
- The scrubbing state needs a real touch: the runner holds a finger on the system player's scrubber through the
  capture (`press-scrubber` in `marketing/shots/mac-run.sh`), and the harness asks again until the preview says the
  scrub took. A capture is only accepted when it shows the scrubber.
- iPhone Duo: the library on the unfolded display was shot again in all 15 languages. Its player panel keeps Skip
  the recap: the Duo simulator takes taps through `duoctl` but no touch that is held.
- iPad 13-inch: the whole set was shot again (`marketing/store/shoot-ipad.sh`), which brings the library with its
  folder button; the player panel is unchanged in what it shows.
- Apple TV, Header and Search Results: nothing they show changed; carried from 2.13.0.
- Uploaded with `scripts/asc-screenshots.py` (`--only=iphone --locales=all`, `--only=duo --locales=all`,
  `--only=ipad`); every set read back with 10 COMPLETE.
- Not done for this release: a reading of the store funnel before staging.

## Submitted (2026-11-21)

- iOS 2.14.0, build `202611171250`, submitted 2026-11-21T16:48Z, release on approval with a phased release:
  submission `a8ee788b-66a5-4089-91f8-d6e7a3730a13`. Builds `202611171248` and `202611171249` of the same version
  stay on TestFlight; the last one adds the start and scrub fixes of f39e58c0 and 52259420.
- Apple TV 2.14.0, build `202611152019`, submitted 2026-11-21T16:49Z, release on approval with a phased release:
  submission `1c0a7efa-bb09-491e-8e14-11652a7b7b1a`.
- Both builds came from 93140175, which tag `2.14.0` names, archived locally with Xcode 27.1 through `midgar ship`.
- Linux 0.21.0 (build 36) was installed from the same day's master on arch and the Steam Deck. No `linux-` release
  was published.
