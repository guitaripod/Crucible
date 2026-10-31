# Architecture

Crucible is one SwiftPM package that builds two apps from the same logic: the iPhone app and the Apple TV app. Everything that is not presentation lives in shared modules; each platform owns only its screens.

## Module graph

```
                       CrucibleCore                Foundation, os, Security. No UIKit, no AVFoundation.
                      /     |      \               Networking, models, sessions, preferences, logging,
                     /      |       \              formatting and the feature logic of every screen.
          CrucibleMedia  CrucibleStats  CrucibleDesign
          AVFoundation   GRDB           UIKit tokens, glass, image pipeline, brand atoms
          MediaPlayer        \              /
          (playback           CrucibleStatsUI     UIKit charts and stats components
           engine)                 |
                                   |
        ┌──────────────────────────┴───────────────────────────┐
     Crucible (iPhone app)                             CrucibleTV (Apple TV app)
     @main, screens, downloads, widgets glue           app delegate, screens, focus-driven design system
                                                            |
                                                      CrucibleTopShelf (extension logic, depends on Core only)
     CrucibleWidgets + CrucibleActivity: the iPhone Live Activity extension (unchanged)
```

Dependencies only point downward. Core never imports UIKit, AVFoundation, MediaPlayer or GRDB, so its logic runs and is tested on the macOS host (`Tests/CrucibleCoreTests`, Swift Testing).

## Rules

- **Access control.** Symbols shared between targets are `package` (SE-0386), never `public`. The only public API is the deliberately tiny entry surface of `CrucibleTV` (`TVAppDelegate`) and `CrucibleTopShelf` (`TopShelfProvider`), because the Xcode project that hosts the tvOS app lives outside the package. Everything else stays `internal`; structs built from another module have an explicit `package init`.
- **Platform differences live in a few places.** `AppPlatform` (platform name, storage directories), `DeviceModel` (Liquid Glass capable hardware), `Theme.Metrics` (phone and Apple TV values behind one token vocabulary), `Glass.isAvailable` (the single glass gate), `Haptics` (no-ops on tvOS). Screens never branch on the platform.
- **Features are slices.** A feature's rules (what to load, how to order, filter, group, cap, page, decide) live once in `CrucibleCore/Features/<Feature>`: plain values, pure functions and one async feed/loader per feature. The iPhone screen and the Apple TV screen both render that output with their own cells and focus/touch behaviour. Decoration that only exists on one platform (downloads on iPhone) comes in through a neutral seam.
- **UIKit style.** Programmatic UIKit only; `UIButton.Configuration`, `UIAction` closures, compositional layout + diffable data sources, `UIContentConfiguration` cells, `UIStackView`; async/await; no inline comments. Closures that AVFoundation, MediaPlayer or KVO may call off-main are `@Sendable`.

## What lives where

| Module | Contents |
| --- | --- |
| `CrucibleCore` | `Networking` (APIClient actor, endpoints, Plex models, headers, keychain), `Session` (server bootstrap, route resolution, launch pipeline, library visibility), `Preferences`, `Support` (logging, formatters, error copy), `Snapshots` (cold-launch Home cache), `Features/*` (Home, Library, Detail, Search, History, You, Settings, Auth, Playback rules, Top Shelf snapshot, Navigation: deep links and library tab layout) |
| `CrucibleMedia` | `PlaybackSession` (stream resolution, resume, timeline reporting, transcode keep-alive and restarts, fallback, skip markers, Up Next, remote commands, suspend and return, self-healing) and `PlaybackReporter`; driven by both players. Where the viewer is comes from `PlayheadTracker` (Core), never straight from the player's clock, and is saved on the device in `PlaybackResumeStore`; `PlaybackResumeSync` tells the server at launch what a run that was ended left behind, including a finished run's end so a killed app cannot leave an episode in Continue Watching. Reports leave the reporter one at a time and in order, so a stopped item is never overtaken by a tick from before it. The rules of self-healing live in Core (`PlaybackContinuity.swift`): `AwayDetector` (a 1 s heartbeat on the continuous clock notices an absence no lifecycle notification announced, such as an Apple TV that sleeps from its screen saver), `TranscodeLiveness` (pings, segment loads and the item's error log say whether the server still has the transcode; one it may have reaped is rebuilt under a new session id before it plays again), `ItemEndRule` (a transcode that ends before the credits is rebuilt, never taken for the end), `BreakRule` (come back paused after a long absence, Rewind After a Break) and `StillWatchingRule` (ask before the next episode after a run nobody touched the remote in), with `HealBudget` keeping a server that keeps dropping the stream from looping. Every transcode restart is logged with its reason, and each lifecycle notification with the player's state. What is watched lives beside it: `WatchedRule.isFinished` finishes an item at the earlier of its credits marker and its percentage (the rule Plex itself defaults to), and `PlaybackResumeStore` keeps a finished run until the server confirms it |
| `CrucibleStats` | Watch-history SQLite mirror (GRDB), sync and backfill, queries, the pre-formatted Statistics page, Year in Review summary |
| `CrucibleDesign` | `Theme` tokens (colour, type, space, radius, metrics per platform), `Glass`, `Haptics`, `ProgressBar`, `BadgeChipView`, `ImageLoader` + disk cache, `CrystalGlyphView` |
| `CrucibleStatsUI` | Charts and stats components driven by `StatsMetrics` (`.phone`, `.tv`) |
| `Crucible` | iPhone screens, downloads engine, Live Activity glue, `AppDelegate`/`SceneDelegate`. The product name `Crucible` is what `xtool` packages |
| `CrucibleTV` | `App/` (scene, coordinator, launch gate, debug hooks), `Navigation/` (tab bar, router, `TVScreens` seams, session actions), `DesignSystem/` (cards, shelves, controls, focus helpers, state views, gallery), one folder per feature screen |
| `CrucibleTopShelf` | Builds Top Shelf content from the snapshot the app writes into the App Group |

`TVScreens` is the single catalogue of tvOS screens: each feature adds its factory in its own `Screens+<Feature>.swift`, so screens open each other without importing each other.

## iPad specifics

The iPhone app is universal. Nothing branches on the device: layout reads the room a window has, so a narrow iPad window, a Split View half or Slide Over looks like the phone and a large window gets the iPad layout.

- **Room.** `Theme.Room` (`Shared/Theme+Layout.swift`) classifies a container as compact (under 600 points wide or 500 tall), regular or wide, and supplies the gutter (16 points on a phone, the system's 20 otherwise), rail card widths and the readable width (720). Rails grow their cards, grids add columns toward a target poster width (`Theme.gridColumns`), list screens centre a readable column (`Theme.centerReadable`), detail rows stop at the readable width (`DetailLayout.fullWidth`), detail artwork turns 16:9, the Home hero grows with the window, Statistics centres a 960-point dashboard with four KPI tiles a row, and genre tiles, facts and search episodes go to three or four across.
- **Navigation.** On iOS 18 and later the Library tab is a `UITabGroup` of the server's libraries with a managing navigation controller: the sidebar lists each library, the tab bar keeps one Library tab whose title menu moves between them (`TabBarController.selectLibrary`), and the group's own screen is never shown. iOS 17 keeps the single Library tab with the switcher.
- **Windows.** `UIApplicationSupportsMultipleScenes` is on. One window connects to the server for all of them (`SceneDelegate.launchLeader`); the others hold their launch screen and adopt its payload, a window opened later reuses the last payload, and a sign-out, server switch or demo exit starts every window over. Each window restores its tab and title (`WindowActivity`, `stateRestorationActivity`), is named after the screen on top (`ContentNavigationController`), opens titles in new windows from context menus ("Open in New Window") or by dragging a card to the edge of the screen (`MediaDragSource`), and stops its own player when it closes. The player follows its window's scene for suspension and return. Foreground work (downloads, Pro refresh, the demo library) runs once, for the first window to return.
- **Keyboard and menu bar.** Every command is an `AppCommand` (`Shared/AppCommand.swift`) handled by the window's `TabBarController` through one selector, `performCommand(_:)`; commands about what is on screen go to the top screen through `CommandHandling`. `AppMenu` builds the iPadOS 26 menu bar (`UIMainMenuSystem`, from `AppDelegate`) and the Command-key overlay before it: Go (Command-1 to 4, Command-F, Command-[, Statistics, Watch History, Surprise Me), View (Command-R, Command-plus and minus for poster size), Media (Space plays or resumes, S skips the intro or credits, N plays the next episode, Escape closes the player, Mark as Watched, Download) and Settings (Command-comma). Collection views take arrow, Tab and Return keys (`allowsKeyboardFocus`), with the focus ring drawn around a card's artwork.
- **Pointer.** Artwork lifts under the trackpad pointer or a hovering Pencil (`liftsOnHover`), rows and chips highlight, and every custom button has `isPointerInteractionEnabled`.
- **Checking.** `ios/scripts/ipad-uitest.sh` runs the XCUITests on an iPad simulator locally (rotation, shortcuts, sidebar). The screenshot harness (`marketing/shots`) is universal: pass an iPad simulator as `UDID` to capture the iPad layouts.

## Apple TV specifics

- One top tab bar: Home, one tab per Plex movie or show library (three plus More past four; one fewer on tvOS before 26, whose bar clips a seventh tab), Search, You. Libraries excluded in Settings, or hidden from Home on Plex, leave Home and Statistics, never the tab bar.
- Home is cinematic: a full-screen backdrop that follows focus, a non-focusable hero (title, metadata, synopsis), then shelves. Select acts, Play/Pause plays, long press opens the context menu.
- Cards are custom `UIContentView`s on `UIImageView.adjustsImageWhenAncestorFocused` (system tvOS 26 focus: lift, glass rim, parallax) with the title outside the scaling artwork. `UIFocusEffect` does not exist on tvOS; custom surfaces animate through the focus animation coordinator.
- Liquid Glass is used only for controls and navigation, gated by `Glass.isAvailable` (tvOS 26 and Apple TV 4K 2nd generation or later); older systems and boxes get the classic look with the same layout.
- Playback uses `AVPlayerViewController` with `contextualActions` (Skip Intro / Skip Credits), `AVContentProposal` (Up Next) and `externalMetadata`, on the same `PlaybackSession` as the iPhone.
- Sign-in uses the Plex PIN flow (code at plex.tv/link plus a QR for the strong PIN). Top Shelf shows Continue Watching and Up Next from a small snapshot in the App Group.
- tvOS has no persistent app storage: `AppPlatform.persistentDirectory` is Caches there, so the statistics mirror and Home snapshot are rebuilt from the server if the system purges them.

## tvOS design system

`Sources/CrucibleTV/DesignSystem` is the only place that decides how an Apple TV screen looks and behaves under focus; feature folders only arrange its pieces.

- **Foundation.** `TVMetrics` (columns, tab bar clearance, hero, focus lift numbers), `TVFont` (type recipes), `TVMotion` (animation that honours Reduce Motion and the UI-test switch, pulsing), `TVStatusDot`, the image pipeline.
- **Content.** Cards on `adjustsImageWhenAncestorFocused`, shelf layouts, `TVHeroInfoView`, `TVBackdropView`, `TVArtworkView`, `TVScreenTitleView`, `TVChipRow`, `TVStatusRow`, `TVButton` recipes, `MonogramView` (shared with the iPhone).
- **Screen host.** `TVScreenViewController` owns the collection view, the loading/empty/error `TVStateView` and the focus rules: identifier-keyed focus memory, an anchor that holds focus while a screen loads, `playFocused(at:)` for Play/Pause, task slots cancelled on disappear. `TVNavigation` guards pushes, `TVHostCell` hosts any view in a cell, `TVFocusableSurface` sends Select exactly once, `TVReadOnlyPanel` makes read-only information reachable with VoiceOver.
- **Rules.** Menu while a pushed screen loads pops it. Every alert goes through `presentAlert` or `presentConfirmation`, because tvOS dismisses an alert with Menu only when it has a cancel action. Sizes, fonts and clearances come from tokens, never from literals in a screen. Nothing branches on the platform or the OS version outside `Glass`. Every new piece gets an entry in the debug gallery (`CRUCIBLE_GALLERY=1`) with a UI test.

## Crucible Pro

The App Store build sells an optional Crucible Pro through MidgarKit's MidgarStore; source builds have everything unlocked. The store never appears in the feature code:

- `CrucibleCore/Features/Pro` holds the store-free model: `ProAccess.shared` (is Pro on, observers, `requestUnlock`), `ProPolicy` (what a free install may do: one download at a time, the Week range, no poster, no Top Shelf), `ProOffer` (priced, described offers), `PaywallModel` (the paywall state machine both platforms render: loading, ready, unavailable, purchasing, restoring, pending, cancelled, failed, finished), `ProAccessProviding` (the store behind it), `UnlockedProAccess` (source builds) and `ScriptedProAccess` (debug builds and UI tests, driven by `CRUCIBLE_PRO*` environment variables).
- `CrucibleStore` is a package target that only the macOS manifest declares, on MidgarKit's `MidgarCommerce` (tagged package, `exact: 4.4.0`). `MidgarProAccess` implements `ProAccessProviding` for the `pro` entitlement: StoreKit buys and finishes, the purchase carries the anonymous Midgar ID as its app account token and reaches the Midgar ledger. Only the Xcode projects (`ios/`, `tv/`) link it; the xtool build never sees it. `Tests/CrucibleStoreTests` (scheme `CrucibleStoreTests`, iOS 27.1 simulator) runs it against `Products.storekit`.
- Each app's entry point opens the log (`CrucibleLog.configure()`, MidgarLog writing `Library/Logs/crucible.log`) and installs `MidgarProAccess.live()` before `UIApplicationMain`, except in a test host; the shared launch code calls `ProAccess.shared.configureForLaunch(store: nil)` and sets the paywall presenter.
- Products: `com.guitaripod.crucible.pro.lifetime` (non-consumable) and `com.guitaripod.crucible.pro.yearly` (auto-renewable, no free trial since 2026-10-31), one app record and one bundle id for iPhone and Apple TV, so a purchase on one covers the other. `docs/asc-products.md` records how they were created, and `scripts/asc-setup.py` and `scripts/asc-products.py` keep the listing and the review material in line.

## Building and testing

The Linux box has no Apple SDK for the app targets; the Mac is the build host.

```bash
scripts/mac.sh ios          # iPhone package scheme on the iPhone simulator
scripts/mac.sh tvlib        # Apple TV package scheme (compiles Core, Media, Stats, Design, StatsUI, TV)
scripts/mac.sh core-test    # Core + Stats tests on the macOS host (CRUCIBLE_CORE_ONLY=1 swift test)
scripts/mac.sh bench        # the episode-flow benchmark: 26 behaviours, PASS/FAIL and the score (CRUCIBLE_BENCH=1)
tv/scripts/tv.sh build|run|uitest|shot|logs   # the tvOS app, simulator, mock server and UI tests (see tv/README.md)
marketing/shots/run.sh      # iPhone screenshot harness, also the iPhone visual regression check
marketing/store/shoot-ipad.sh   # 13-inch iPad App Store captures (landscape, sidebar) through the IPadStoreShots UI test
marketing/store/compose.py      # frames the iPhone and iPad captures and captions them (captions.json) into marketing/appstore
```

`NAME=<id>` isolates a remote checkout, simulator and mock port so several people (or agents) can work at once. The iPhone app is still packaged and signed with `xtool` from Linux (`scripts/install-ios.sh`); the tvOS app is built with Xcode from the XcodeGen project in `tv/`, because xtool does not support tvOS. The manifest only declares the tvOS targets when it is evaluated on macOS, so the Linux/xtool graph is unchanged.

### Tests

- Core and statistics logic: Swift Testing in `Tests/CrucibleCoreTests`, run on the macOS host (`scripts/mac.sh core-test`).
- Episode flow: `scripts/mac.sh bench` scores the behaviours behind going from one episode to the next and keeping watched state in step, against canned Plex responses, with a PASS or FAIL and the reason for each (`Sources/CrucibleBench`, declared only with `CRUCIBLE_BENCH=1`).
- Apple TV screens: XCUITest through the real focus engine (`XCUIRemote`) against the mock Plex server in `marketing/mock`, with screenshots exported to `tv/out/ui`. Every test class derives from `TVTestCase`, which returns the mock to a pristine library and history before the class starts (`/mock/reset`); a test states the settings it needs with `TVTest.launch(mock: [...])`, and every launch first clears the runtime settings, so a test never inherits another's state and a single run executes every test.
- DEBUG launch switches for simulator work: `CRUCIBLE_MOCK` (connect to the mock), `CRUCIBLE_FRESH` (first launch), `CRUCIBLE_OPEN` and `CRUCIBLE_OPEN_LINK` (start on a screen or a deep link), `CRUCIBLE_STYLE=light|dark`, `CRUCIBLE_MODEL_IDENTIFIER=AppleTV6,2` (render the classic look on a glass-capable simulator), `CRUCIBLE_VOICEOVER=1` (VoiceOver focus stops without VoiceOver), `CRUCIBLE_GALLERY` (the design-system gallery).
- iPhone regression: `marketing/shots/run.sh` captures the app against the mock; run it on a baseline checkout and on the working tree with the same simulator and compare the images. `SHOT_SCRIPT=flow marketing/shots/run.sh` runs `EpisodeFlowProbe` instead: it plays an episode up to its credits, lets Up Next start the next one, and writes PASS/FAIL findings beside the captures for the iPhone's side of the episode flow (the same player stays on screen, the finished episode is watched on the server, the next one starts from the beginning).

## Security notes

- The Plex account token lives in the Keychain. The only other place it appears is the Top Shelf snapshot (`topshelf.json` in the `group.com.guitaripod.crucible` App Group container, under `Library/Caches` because tvOS denies writes at the container root): every artwork URL in it carries the account token as `X-Plex-Token`, because the system fetches Top Shelf images itself and the extension does no networking. That is a trade-off, accepted for now: the file is readable only by this team's apps in the group, a snapshot left at the container root by an earlier version is read and replaced on the next write, it is removed on sign-out and whenever the server changes (`AccountSessionReset`), and an Apple TV on a plain-HTTP LAN sends the token over that LAN like every other request the app makes. No scoped or delegated token is used because no endpoint for one has been verified against a real Plex server; if Plex documents a short-lived image token, switch `TopShelfBuilder.imageURL` to it. The extension writes `topshelf-read.json` beside the snapshot after every load, and Diagnostics shows both plus whether the launch was granted the App Group, because the extension process has no other way to report on the Apple TV.
- Signing out and connecting to a different server both go through `AccountSessionReset` (Core): statistics, the Home cache, library choices, recent searches, the You route status, the image cache and the Top Shelf snapshot are forgotten together, so nothing of one server or account is ever shown against another. Sign-out also forgets the remembered address and the saved account and server.
- The tvOS app and its Top Shelf extension set `NSAllowsArbitraryLoads` because Plex servers on a home network are usually plain `http://` at a LAN address. `NSLocalNetworkUsageDescription` explains the local network access.

## Adding a feature

1. Put the rules in `CrucibleCore/Features/<Feature>` with tests; no UIKit.
2. Render them from the iPhone screen (`Sources/Crucible/<Feature>`).
3. Add a `Screens+<Feature>.swift` factory and the screens in `Sources/CrucibleTV/<Feature>` using the design system.
4. Cover the tvOS screens with a UI test that drives the real focus engine and captures screenshots (`tv/UITests`).
