# Crucible — iOS/tvOS Client for MediaForge

## Stack
- Swift 6, UIKit, programmatic UI only
- iOS 17+ / tvOS 17+
- Built and deployed from Linux via xtool + SwiftPM
- No Xcode, no Interface Builder, no storyboards, no xibs

## Architecture
- UIKit app with UIApplicationDelegate + UIWindowSceneDelegate
- Scene-based lifecycle (UISceneConfiguration)
- All UI is programmatic — no IB, no storyboards

## UIKit Rules — Modern APIs Only
- UIButton.Configuration for all buttons, never setTitle/setImage
- UIAction closures for all control events, never #selector/@objc target-action
- UICollectionView with compositional layout + diffable data source for all lists/grids
- UIContentConfiguration for cell content, never manual subview layout in cells
- UIHostingConfiguration when embedding SwiftUI views in cells
- No UITableView — use UICollectionView with list layout instead
- No #selector, no @objc unless strictly required by a system API with no alternative

## Build & Deploy
- `swift build --swift-sdk arm64-apple-ios` — cross-compile check after every change (~0.1s, no device needed)
- At the end of each task, use the `/deploy` skill to compile-check and install to the connected iPhone
- Bundle ID: com.guitaripod.crucible

## Backend
- MediaForge Rust backend at ../rust/mediaforge
- API base URL will be on the Tailscale network (no auth needed)
- Swagger docs at /swagger-ui for full API reference

## Code Style
- No code comments
- No file headers
- No storyboards, no xibs, no Interface Builder
- Programmatic Auto Layout via NSLayoutConstraint or layout anchors
- async/await and structured concurrency for networking
- Observation framework over KVO/NotificationCenter where applicable
