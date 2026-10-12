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
| `CrucibleMedia` | `PlaybackSession` (stream resolution, resume, timeline reporting, transcode keep-alive and restarts, fallback, skip markers, Up Next, remote commands) and `PlaybackReporter`; driven by both players |
| `CrucibleStats` | Watch-history SQLite mirror (GRDB), sync and backfill, queries, the pre-formatted Statistics page, Year in Review summary |
| `CrucibleDesign` | `Theme` tokens (colour, type, space, radius, metrics per platform), `Glass`, `Haptics`, `ProgressBar`, `BadgeChipView`, `ImageLoader` + disk cache, `CrystalGlyphView` |
| `CrucibleStatsUI` | Charts and stats components driven by `StatsMetrics` (`.phone`, `.tv`) |
| `Crucible` | iPhone screens, downloads engine, Live Activity glue, `AppDelegate`/`SceneDelegate`. The product name `Crucible` is what `xtool` packages |
| `CrucibleTV` | `App/` (scene, coordinator, launch gate, debug hooks), `Navigation/` (tab bar, router, `TVScreens` seams, session actions), `DesignSystem/` (cards, shelves, controls, focus helpers, state views, gallery), one folder per feature screen |
| `CrucibleTopShelf` | Builds Top Shelf content from the snapshot the app writes into the App Group |

`TVScreens` is the single catalogue of tvOS screens: each feature adds its factory in its own `Screens+<Feature>.swift`, so screens open each other without importing each other.

## Apple TV specifics

- One top tab bar: Home, one tab per visible Plex library, Search, You. Libraries excluded in Settings also leave the tab bar.
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

## Building and testing

The Linux box has no Apple SDK for the app targets; the Mac is the build host.

```bash
scripts/mac.sh ios          # iPhone package scheme on the iPhone simulator
scripts/mac.sh tvlib        # Apple TV package scheme (compiles Core, Media, Stats, Design, StatsUI, TV)
scripts/mac.sh core-test    # Core + Stats tests on the macOS host (CRUCIBLE_CORE_ONLY=1 swift test)
tv/scripts/tv.sh build|run|uitest|shot|logs   # the tvOS app, simulator, mock server and UI tests (see tv/README.md)
marketing/shots/run.sh      # iPhone screenshot harness, also the iPhone visual regression check
```

`NAME=<id>` isolates a remote checkout, simulator and mock port so several people (or agents) can work at once. The iPhone app is still packaged and signed with `xtool` from Linux (`scripts/install-ios.sh`); the tvOS app is built with Xcode from the XcodeGen project in `tv/`, because xtool does not support tvOS. The manifest only declares the tvOS targets when it is evaluated on macOS, so the Linux/xtool graph is unchanged.

### Tests

- Core and statistics logic: Swift Testing in `Tests/CrucibleCoreTests`, run on the macOS host (`scripts/mac.sh core-test`).
- Apple TV screens: XCUITest through the real focus engine (`XCUIRemote`) against the mock Plex server in `marketing/mock`, with screenshots exported to `tv/out/ui`. Every test class derives from `TVTestCase`, which returns the mock to a pristine library and history before the class starts (`/mock/reset`); a test states the settings it needs with `TVTest.launch(mock: [...])`, and every launch first clears the runtime settings, so a test never inherits another's state and a single run executes every test.
- DEBUG launch switches for simulator work: `CRUCIBLE_MOCK` (connect to the mock), `CRUCIBLE_FRESH` (first launch), `CRUCIBLE_OPEN` and `CRUCIBLE_OPEN_LINK` (start on a screen or a deep link), `CRUCIBLE_STYLE=light|dark`, `CRUCIBLE_MODEL_IDENTIFIER=AppleTV6,2` (render the classic look on a glass-capable simulator), `CRUCIBLE_VOICEOVER=1` (VoiceOver focus stops without VoiceOver), `CRUCIBLE_GALLERY` (the design-system gallery).
- iPhone regression: `marketing/shots/run.sh` captures the app against the mock; run it on a baseline checkout and on the working tree with the same simulator and compare the images.

## Security notes

- The Plex account token lives in the Keychain. The only other place it appears is the Top Shelf snapshot (`topshelf.json` in the `group.com.guitaripod.crucible` App Group container): every artwork URL in it carries the account token as `X-Plex-Token`, because the system fetches Top Shelf images itself and the extension does no networking. That is a trade-off, accepted for now: the file is readable only by this team's apps in the group, it is written with `.completeUntilFirstUserAuthentication` file protection, it is removed on sign-out and whenever the server changes (`AccountSessionReset`), and an Apple TV on a plain-HTTP LAN sends the token over that LAN like every other request the app makes. No scoped or delegated token is used because no endpoint for one has been verified against a real Plex server; if Plex documents a short-lived image token, switch `TopShelfBuilder.imageURL` to it.
- Signing out and connecting to a different server both go through `AccountSessionReset` (Core): statistics, the Home cache, library choices, recent searches, the You route status, the image cache and the Top Shelf snapshot are forgotten together, so nothing of one server or account is ever shown against another. Sign-out also forgets the remembered address and the saved account and server.
- The tvOS app and its Top Shelf extension set `NSAllowsArbitraryLoads` because Plex servers on a home network are usually plain `http://` at a LAN address. `NSLocalNetworkUsageDescription` explains the local network access.

## Adding a feature

1. Put the rules in `CrucibleCore/Features/<Feature>` with tests; no UIKit.
2. Render them from the iPhone screen (`Sources/Crucible/<Feature>`).
3. Add a `Screens+<Feature>.swift` factory and the screens in `Sources/CrucibleTV/<Feature>` using the design system.
4. Cover the tvOS screens with a UI test that drives the real focus engine and captures screenshots (`tv/UITests`).
