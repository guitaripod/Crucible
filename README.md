# Crucible

A fast, native Plex client for iPhone — offline downloads, Skip Intro, Picture-in-Picture, lock-screen controls, Handoff — built entirely on Arch Linux.

![Swift](https://img.shields.io/badge/Swift_6-F05138?style=flat&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/iOS_17+-000000?style=flat&logo=apple&logoColor=white)
![Arch Linux](https://img.shields.io/badge/Arch_Linux-1793D1?style=flat&logo=archlinux&logoColor=white)
![UIKit](https://img.shields.io/badge/UIKit-2396F3?style=flat&logo=apple&logoColor=white)
![xtool](https://img.shields.io/badge/xtool-FF6B35?style=flat&logo=hammer&logoColor=white)
![Plex](https://img.shields.io/badge/Plex_API-EBAF00?style=flat&logo=plex&logoColor=black)

No Xcode. No macOS. No storyboards. Pure programmatic UIKit, cross-compiled from Linux and deployed to iPhone over USB.

![Screenshots](screenshots.png)

## Stack

| | Tool |
|---|---|
| Language | **Swift 6** with strict concurrency |
| UI | **UIKit** — programmatic, compositional layouts, diffable data sources, content configurations, **Liquid Glass** on iOS 26 |
| Playback | **AVKit / AVFoundation** — direct play, HLS transcoding, offline file playback, Picture-in-Picture, lock-screen controls |
| Downloads | **Offline HLS engine** — sequential segment fetch, resumable, Wi-Fi-aware, `BGProcessingTask` background, **ActivityKit Live Activity** |
| Build | **SwiftPM** — cross-compiled with `swift build --swift-sdk arm64-apple-ios` |
| Deploy | **[xtool](https://github.com/xtool-org/xtool)** — cross-platform Xcode replacement, build and deploy iOS apps from Linux |
| Backend | **Plex Media Server API** — OAuth PIN auth, HLS transcoding, timeline reporting |
| Dev OS | **Arch Linux** |

## Features

### Playback

- **Direct play** for natively-supported codecs, automatic **HLS transcoding** otherwise
- **Skip Intro / Skip Credits** from Plex chapter markers
- **Picture-in-Picture** and **background audio**
- **Lock screen & Control Center controls** — play/pause, skip ±10s, scrub, next episode
- **Credits-triggered Up Next** autoplay between episodes
- Adjustable **playback speed**, subtitle and audio track selection
- Resume from where you left off, progress synced to the server via the timeline API

### Offline downloads

A proper download engine — not the afterthought the official app ships.

- **Download movies, whole seasons, or single episodes** for offline viewing
- **Per-download quality** — Original (source quality), High (1080p · 20 Mbps), Medium (720p · 8 Mbps), Low (480p · 3 Mbps), and Data Saver (360p · 0.7 Mbps), with a configurable default in Settings
- **Live Activity** — a Lock Screen card and Dynamic Island showing live download progress (percent, current title, "X of Y"), built with **ActivityKit + a WidgetKit extension** — compiled and signed on Linux by xtool
- **Real offline HLS engine** — downloads the transcoded stream segment-by-segment into a self-contained local playlist, re-minting the Plex session on the fly so a stalled transcode never breaks the download
- **Background downloading** — keeps going via background-time assertions and **`BGProcessingTask`**; if the system reclaims time mid-download it interrupts gracefully (never "failed") and **auto-resumes** from the segments already on disk, with a notification when a download finishes while you're away
- **Real download queue** — concurrency limit plus pause / resume / cancel / retry per item and live progress
- **Wi-Fi-only by default** — downloads pause when you leave Wi-Fi and resume when it returns; opt into cellular with one toggle
- **Dedicated Downloads tab** — in-progress items, downloaded movies, and episodes grouped by show, with storage used and free space
- **First-class offline playback** — Skip Intro / Skip Credits (markers saved with the download), resume, Picture-in-Picture, background audio, and lock-screen controls, all with no network
- **Storage management** — see space used, delete individual downloads or all at once, optional auto-delete of watched downloads; media is stored on-device and excluded from iCloud backup

### Browse & discover

- Home with **Continue Watching**, **On Deck**, and **Recently Added** hubs
- Library poster grids with **genre filtering**, sort options, and per-library Continue Watching carousels
- **Folder browsing** for unindexed content
- Movie/episode detail with backdrop hero, codec/HDR badges, **Cast & Crew**, and **More Like This**
- Show detail with season picker and an episode list that tracks watched and in-progress state
- **Search** across all libraries and a **watch history** timeline
- **Handoff & Spotlight** — hand a title between devices, find recently-viewed media in iOS search
- **Surprise Me** random picker

### Built different

- **Liquid Glass** materials throughout on iOS 26
- Automatic **best-connection server discovery** (prefers local, non-relay, HTTPS), Tailscale-friendly
- Live watched/progress refresh across Home, Library, and detail screens — never stale on return
- On-device **file logger** for diagnostics without a Mac attached
- Plex **OAuth** sign-in, token stored in the **Keychain**

## Building

Requires Swift 6+ via [swift-bin (AUR)](https://aur.archlinux.org/packages/swift-bin) and the iOS cross-compilation SDK.

```bash
swift build --swift-sdk arm64-apple-ios
```

## Deploying

Requires [xtool](https://github.com/xtool-org/xtool) and a USB-connected iPhone.

```bash
xtool dev run --usb
```

## Architecture

```
Sources/
├── CrucibleActivity/       # Shared ActivityAttributes (compiled into app + widget)
├── CrucibleWidgets/        # WidgetKit extension — download Live Activity (Lock Screen + Dynamic Island)
└── Crucible/               # The app
    ├── App/                # AppDelegate, SceneDelegate, ServerBootstrap, BGTask registration, deep links
    ├── Detail/             # Movie/episode detail, show detail, cast & episode cells
    ├── Downloads/          # HLS download engine, store, resolver, Live Activity controller, offline UI + tab
    ├── History/            # Watch activity history
    ├── Home/               # Hub-based home screen
    ├── Library/            # Movie grid, show grid, folder browser
    ├── Networking/         # APIClient (actor), endpoints, models, ImageLoader, Keychain, blurhash
    ├── Player/             # StreamResolver, PlaybackReporter, PlayerCoordinator, Now Playing, Up Next
    ├── Search/             # Search with hub-based results
    ├── Settings/           # Server setup/connection discovery, preferences, Plex OAuth
    └── Shared/             # Theme, Glass, PosterCell, Formatters, MediaActivity, AppLogger
```

The widget extension is built and signed entirely on Linux via xtool's `extensions:` mechanism — Live Activities with no Xcode.

Zero third-party dependencies. Pure Apple frameworks: Foundation, UIKit, AVKit/AVFoundation, MediaPlayer, Network, BackgroundTasks, ActivityKit, WidgetKit, UserNotifications, CoreSpotlight, WebKit, Security.
