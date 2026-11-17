# Marketing 2.13.0

2.13.0 is the release that keeps the picture playing after the player closes and lets the words on a title come to the
viewer's own language: a mini player above the tab bar, translation of Trakt's comments, What People Say and Plex's
descriptions, a first-launch welcome that says where the viewer stands, and title pages that load behind a skeleton in
their own shape instead of a spinner. It follows 2.12.0 on the store (submitted 2026-11-15, released), so its What's
New covers everything after 2.12.0, including the work that only ever reached TestFlight as 2.12.1.

## What the release says, and where it is true

| Claim in the listing or What's New | Where the build does it |
| --- | --- |
| Close the player and the picture keeps playing in a mini player above the tab bar, with title, progress, play or pause and close | `MiniPlayer` docked to the tab bar's accessory (commit 840b1781); the next episode plays on in it |
| Trakt's comments, What People Say and Plex's descriptions translate as they load or on request | `TranslationCenter` and the translate runs on comment cards, the sentiments block and Plex descriptions (d6ddab65, 890f8f7a); Translated from, Show Original, Translate in a comment's menu, Translate to English in the composer |
| A first launch says where the viewer stands with Crucible Pro and what Trakt adds | `WelcomePlan`, the welcome sheet over Home, once after a new install (e5ccf60b, 5e181dda, 1594942e); never after an update, never in the demo |
| Title pages, filmographies, collections, playlists and Trakt's comment lists load behind a skeleton in their own shape | `SkeletonCanvasView` and the per-page skeletons (c9d18cb7), with the edges fixed in 5729c19d |
| Where Trakt is not connected, a title's Community place invites Connect Trakt or Not Now | `TraktInviteCard` on film, episode and show pages (ea9f9ae9), offered only once the account has loaded (63d8604a) |
| Everything stays in step with the server, and playback starts where the server has the title now | Foreground re-read and event stream refresh (9d71af54); resume checked against the server (f6522b73) |
| Mark Watched and Mark Unwatched work on Recently Watched | 8e609383 |
| No crash on iPad in top nav bar mode | `preferContentHeight()` on `TraktUnlockCardContentView` (081b30ee); the content view had reported an unbounded height to UIKit |

## Listing (staged)

- `store/metadata/ios/version/2.13.0/`: What's New and promotional text in all 21 locales; description, keywords,
  marketing URL and support URL carried from 2.12.0 unchanged (still true of this build).
- What's New leads with the mini player, then translation, then the first-launch welcome, the skeletons and the Trakt
  invitation, then staying in step, then the fixes. Promotional text leads with the mini player and translation.
- App Review notes: `store/review-notes-2.13.0.txt` (where the new things are in the demo, what translation needs, the
  Pro products and the demo accounts).
- Screenshots, Header and Search Results: App Store Connect copies a new version's sets from the one before, and the
  panels this release ships show screens this build did not change (Home, Essentials, Skip Recap, the library, a movie,
  a show, Statistics, the Year in Review poster, Trakt Community and the three iPhone Duo states). Nothing was
  re-shot; every set read back COMPLETE on 2.13.0.

## Submitted (2026-11-17)

- Version 2.13.0 (iOS) created from 2.12.0's localizations, metadata applied with `asc metadata apply`, build
  `202611171245` attached, review notes pushed with `asc review details-update`, `asc validate` with no errors (the
  annual subscription's promotional-image warning and the unverifiable App Privacy publish state are the same as
  2.12.0's), submitted 2026-11-17T11:31Z, release on approval: submission `c13cb2cc-02d6-45ff-9fdf-f96d2dd808fe`.
- Tag `2.13.0` names 081b30ee, the commit the build came from. The Apple TV app is not in this submission; its 2.13.0
  build `202611152013` is in TestFlight.
