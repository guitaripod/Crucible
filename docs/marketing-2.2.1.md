# Marketing 2.2.1

The release that makes the player play on: an episode finished at the credits stays watched, a season
finale rolls into the next season, and the iPhone swaps the next episode into the player already on
screen. Everything below is checked against the build, not against the previous notes.

## What the release says, and where it is true

| Claim in the listing or What's New | Where the build does it |
| --- | --- |
| The next episode starts in the same player, without leaving it | `PlayerCoordinator.advance` swaps `AVPlayerViewController.player` and never dismisses; proven on the iPhone simulator by `SHOT_SCRIPT=flow` (`EpisodeFlowProbe`) |
| A season finale rolls into the next season | `UpNextResolver.firstEpisodeOfNextSeason`, `EpisodeOrder.next`; `flow.finale` and `flow.agreement` in `scripts/mac.sh bench` |
| The subtitle and audio chosen on one episode carry to the next | `UpNextOffer.nextRequest(selectedSubtitleId:selectedAudioStreamId:)`, both players pass the session's picks; `flow.selections` |
| An episode finished at the credits counts as watched | `WatchedRule.isFinished` (credits marker or 92 %, Plex's own default rule), `PlaybackSession.stop` reports the end; `watched.credits`, `watched.report-end`; proven end to end by the probe (`viewCount=1` on the mock) |
| A watched episode plays from the beginning | `PlexMetadata.resumeSecs`, `MovieDetailModel.resumePosition`, `EpisodeStatus`; `screen.start`, `screen.row` |
| A show's Continue follows what was watched last | `ShowDetailModel.computeUpNext` + `lastViewedAt`; `screen.recent` |
| A finished download is marked watched and cleared | `DownloadManager.recordOfflineProgress(finished:)` with the session's credits rule |

The benchmark (`scripts/mac.sh bench`) reads 26/26; it read 14/21 before this release, and its seven
failures are the list above.

## Store set

- Listing text, keywords, promotional text, What's New and the review notes: `docs/asc-metadata.json`,
  pushed with `scripts/asc-setup.py`.
- Screenshots: no screen changed its look in this release, so the iPhone, iPad and Apple TV sets in
  `marketing/appstore/` stay valid. Reshoot only if a capture shows the player between episodes.
- The listing's feature paragraph now says Up Next carries on through the end of a season.

## Funnel

There was no Analytics report request on the app record, so there is no Discovery & Engagement history
to read a baseline from. One ONGOING request was created on 2026-10-27 (`a5505f31-89b7-455e-8f5b-d7e517c0e1d6`);
data starts a day or two after, and the next release writes its impressions, tap-through and
view-to-download baseline here before shipping. Units and proceeds stay in `myyty`.
