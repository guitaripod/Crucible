# Crucible

A fast, native Plex client for iPhone — Skip Intro, Picture-in-Picture, lock-screen controls, Handoff — built entirely on Arch Linux.

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
| Playback | **AVKit / AVFoundation** — direct play, HLS transcoding, Picture-in-Picture, lock-screen controls |
| Build | **SwiftPM** — cross-compiled with `swift build --swift-sdk arm64-apple-ios` |
| Deploy | **[xtool](https://github.com/xtool-org/xtool)** — cross-platform Xcode replacement, build and deploy iOS apps from Linux |
| Backend | **Plex Media Server API** — OAuth PIN auth, HLS transcoding, timeline reporting |
| Dev OS | **Arch Linux** (btw) |

## Features

### Playback

- **Direct play** for natively-supported codecs, automatic **HLS transcoding** otherwise
- **Skip Intro / Skip Credits** from Plex chapter markers
- **Picture-in-Picture** and **background audio**
- **Lock screen & Control Center controls** — play/pause, skip ±10s, scrub, next episode
- **Credits-triggered Up Next** autoplay between episodes
- Adjustable **playback speed**, subtitle and audio track selection
- Resume from where you left off, progress synced to the server via the timeline API

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
Sources/Crucible/
├── App/                    # AppDelegate, SceneDelegate, ServerBootstrap, deep-link routing
├── Detail/                 # Movie/episode detail, show detail, cast & episode cells
├── History/                # Watch activity history
├── Home/                   # Hub-based home screen
├── Library/                # Movie grid, show grid, folder browser
├── Networking/             # APIClient (actor), endpoints, models, ImageLoader, Keychain, blurhash
├── Player/                 # StreamResolver, PlaybackReporter, PlayerCoordinator, Now Playing, Up Next
├── Search/                 # Search with hub-based results
├── Settings/               # Server setup/connection discovery, preferences, Plex OAuth
└── Shared/                 # Theme, Glass, PosterCell, Formatters, MediaActivity, AppLogger
```

Zero third-party dependencies. Pure Apple frameworks: Foundation, UIKit, AVKit/AVFoundation, MediaPlayer, CoreSpotlight, WebKit, Security.
