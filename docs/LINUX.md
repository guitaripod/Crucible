# Crucible for Linux

Design for a Linux client that looks and behaves like the Apple TV app, on a desk monitor and on a TV, and shares its logic with the iPhone, iPad and Apple TV apps. The Mac is already served by the iPad app, so Linux is the only new platform. The first target is Arch Linux on KDE Plasma 6.8 (Wayland) with an NVIDIA RTX PRO 6000 (driver 615) and an LG C5 at 4K 144 Hz. The research behind every claim (web vs native, UI toolkits, HDR video on Wayland, Swift on Linux, platform integration, the tvOS and iPad specs, each checked by a second agent, plus the Linux build probe of Core) is in `~/Documents/crucible-linux-research/` on arch, written 2026-11-15.

**The line the whole design follows:** Core decides what to show, Kiln draws it the way the Apple TV does, and mpv plays it the way a home theatre does. The Linux client is a fourth renderer of the same feature slices, not a port with its own rules.

## 1. Decisions

| # | Decision | Decided |
| --- | --- | --- |
| D1 | Crucible Pro on Linux | 2026-11-15: the Linux client is free throughout, as Flaccy's Linux client is (Midgar decisions). No paywall, no Pro surfaces, no store code. Its AI (What to Watch, described recaps, Previously On from dialogue) runs on the person's own model under D38: the paired Crucible Server's model, or any OpenAI-compatible address and key the person gives. The Linux build bundles the prompts from `tools/ai/` and never calls Midgar's hosted Haiku, which stays behind Pro on Apple |
| D2 | Distribution | 2026-11-15: AUR package `crucible` plus a GitHub Release tarball with in-app update (the Tailscode Linux pattern) first; Flathub after audio passthrough is proven inside the sandbox |
| D3 | Language | 2026-11-15: Swift (§2) |
| D4 | Primary input | 2026-11-15: mouse and keyboard first. Gamepad, remote-style keys and the TV are a plus, never at the desk's expense (§5.4) |
| D5 | Glass | 2026-11-15: Kiln draws Liquid Glass, not a blur stand-in (§5.7) |

The bar is the best media client on any desktop: nothing ships that looks or feels worse than the Apple TV app it mirrors.

## 2. Swift, not Rust

The first idea was a Rust app. Measured on arch, the shared Swift code makes that the wrong trade:

| Evidence | Result |
| --- | --- |
| `CrucibleCore` (31k lines, 240 files), `CrucibleStats` (GRDB) and `MidgarCore` on Swift 6.4.2 Linux | Build after a probe patch: 18 files import an Apple-only module, fixed by a 183-line shim file and 41 guard lines, plus the `FoundationNetworking` import every networking file needs on Linux (`core-linux-probe.patch` in the research folder) |
| Core's own test suite on Linux | 1,701 tests in 205 suites run; 1,655 pass. The 46 failures sit in exactly the seams of §8: strings formatted through the probe's stub formatters, `URLProtocol` test stubs, and platform directories |
| Feature velocity | Features land on iPhone, iPad and Apple TV in one commit (Up Next gaps, Seerr, Trakt). A Rust client would re-implement about 35k lines of feature rules and then chase every release |
| House precedent | Tailscode Linux is 133k lines of Swift on Linux with an install script, a headless harness, self-update and the signal-handling lessons already paid for |

Rust's real advantage would be its UI crates, and §4 explains why none of them is used: the UI is a purpose-built engine either way. Swift calls C directly (libmpv, Wayland, EGL, Pango, SDL3, sd-bus), so nothing in the stack needs a binding crate.

## 3. Facts that shape the design

| Fact | Source | Consequence |
| --- | --- | --- |
| libmpv's render API offers OpenGL, D3D11 and software only, and `vo=libmpv` always runs the `gpu` renderer (`gl_video`), never `gpu-next` | mpv master `render.h`, `video/out/gpu/libmpv_gpu.c` (2026-11-14) | Video is rendered with OpenGL into Crucible's own texture (§7.3) |
| A Vulkan render API was closed unmerged (PR #18258, 2026-07-13) and the follow-up issue #18343 closed as not planned | mpv GitHub | No waiting for one; the GL path is the long-term path |
| Measured on arch (P0, 2026-11-15): upstream's render API (`gl_video`) renders HDR10 within half-float precision (a 1,000 cd/m2 patch reads 1,001) and Dolby Vision 8.1 close to `gpu-next`, but gets Dolby Vision 5 wrong (the base layer's colours, not the reshaped picture). The `gpu-next` render backend from the andrewrabert/mpv patch series renders the same profile 5 frame identical to mpv's own `gpu-next` | `linux/Sources/KilnVideoSpike`, research folder | Video goes through `gpu-next` inside Kiln (§7.3); upstream `gl_video` is not good enough |
| That patch series (9 commits, about 2,600 lines, OpenGL and Vulkan render backends for `gpu-next`) sits 1,457 commits behind mpv master. Through its Vulkan render API on a Kiln-style device (`linux/Spikes/vulkan-video`), Dolby Vision 5 and 8.1 match mpv's own player down to the shadows (8.1 black reads 0.0146 PQ against the reference 0.0138, where `gl_video` gave 0.0704), and a software-decoded 4K Dolby Vision frame renders in 3.3 ms (median wall time). Its render backend never initialised mpv's hardware decode interop (`ra_hwdec_ctx`), so every `hwdec` mode fell back to software | `andrewrabert/mpv` branch `feat/libplacebo-swapchain` | Kiln renders with Vulkan, on the vendored series below |
| Done in P0: the series rebased onto mpv 0.42.0 (nine commits, only `render.h` numbering conflicted), plus a tenth patch that loads mpv's hardware decode interop in the render backend, and one libplacebo patch (`pl_vulkan_import` now reports the host's extensions, without which FFmpeg refuses Vulkan Video on an imported device). With zero-copy Vulkan Video decode, HDR10 stays exact, Dolby Vision 5 matches mpv's own player and a 4K frame of HDR10 or Dolby Vision 5, 8.1 or 7 renders in 0.55 to 0.67 ms median (3.3 ms when software-decoded) | `linux/Vendor/mpv`, `linux/scripts/build-mpv.sh` (35 s clean build), `linux/Spikes/vulkan-video` | The video path is settled; NVDEC through CUDA and Vulkan interop, Dolby Vision 7 enhancement layers in the render path and presentation-driven timing are follow-ups in the same series |
| mpv 0.42.0 (2026-11-05) adds Wayland colour management through the protocol, scRGB, and Dolby Vision profile 7 enhancement layers in `gpu-next` only; Arch ships 0.41.0 | mpv release notes | Profile 7 FEL is only in fallback B (§7.3); the base layer plays everywhere |
| KWin 6.8 binds `wp_color_manager_v1` v3: parametric descriptions, PQ, HLG, linear, BT.2020, mastering metadata, `windows_scrgb`. It stores a description per surface and tone-maps HDR surfaces onto an SDR output | `wayland-info` on arch; KWin v6.8.3 `colormanagement_v1.cpp`, `colormanagement.glsl` | One FP16 scRGB window surface carries UI and video; KWin handles an SDR desktop |
| Output HDR is per-output configuration that surfaces cannot request. `kde_output_management_v2` is open to non-sandboxed clients | KWin v6.8.3 `outputconfiguration.h`, `wayland_server.cpp` | Crucible switches the TV to HDR for an HDR title and back, like `hdr-game` (§7.4) |
| NVIDIA 615 on Wayland offers `HDR10_ST2084`, `PASS_THROUGH` and FP16 `EXTENDED_SRGB_LINEAR` swapchains; egl-wayland 1.1.22+ supports FP16 | `vulkaninfo` on arch; egl-wayland release notes | FP16 surfaces work on this GPU; Plezy uses FP16 EGL on NVIDIA for the same reason |
| NVIDIA's Vulkan WSI sends an all-zero mastering block when an app gives none, which KWin rejects by killing the client | NVIDIA forum 374323 (610.43.03) | Crucible always sends real mastering metadata, or none through a path that cannot zero it |
| Plezy (Flutter, GPL-3.0, 2.26.0) renders libmpv through the GL render API into a subsurface below its UI and sets the PQ description itself; Jellium (Rust, CEF) runs mpv's own `gpu-next` window through a Wayland proxy that turns it into a subsurface | Plezy `wayland_video_surface.cc`, Jellium `mpv_proxy/app.rs` | Both video paths have a shipping precedent; §7.3 picks one and keeps the other as fallback |
| `URLSession.bytes(for:)` does not exist on Linux (corelibs issue 3036, open), and corelibs cannot pin a server certificate (`serverTrust` unavailable) | probe; corelibs source | Server events (SSE) and the Crucible Server's certificate pinning need AsyncHTTPClient on Linux (§8) |
| `DateComponentsFormatter`, `RelativeDateTimeFormatter` and `ListFormatter` are unavailable in corelibs Foundation | probe | Core moves to `FormatStyle` APIs, which swift-foundation provides on both platforms |
| SwiftPM on Linux does not compile `.xcstrings`; Crucible has 1,826 keys in 16 languages, 560 of them with plural or device variations | `Localization/Localizable.xcstrings`; build warning | A build step compiles the catalogue for Linux, with ICU plural rules (§8) |
| SF Pro and SF Symbols are licensed for Apple platforms only | Apple font licence | Inter for type, an open icon set mapped from SF Symbol names (§5.6) |
| NVIDIA's driver exposes no HDMI-CEC | open-gpu-kernel-modules; kernel CEC docs | No TV-remote control over CEC; gamepad, keyboard and pointer instead |
| libdispatch on Linux exports `_dispatch_get_main_queue_handle_4CF` and `_dispatch_main_queue_callback_4CF`, the hooks CoreFoundation's run loop uses | `nm -D libdispatch.so` (Swift 6.4.2) | The main actor runs on Kiln's own event loop (§4.2) |

## 4. Architecture

### 4.1 Modules

```
            CrucibleTokens             CrucibleCore                 CrucibleStats        CruciblePlayback
            colours, type, space,      feature slices, Plex,        GRDB mirror,         PlaybackSession and its rules,
            metrics per density        sessions, Platform seams     statistics           PlaybackEngine protocol
                  |                          |                           |                      |
   ┌──────────────┴──────────────────────────┴───────────────────────────┴──────────────────────┴───────────┐
 Apple                                                                Linux
 CrucibleDesign (UIKit Theme from tokens)                             Kiln (UI engine: Wayland, EGL/GL, scene, focus, text)
 CrucibleMedia (AVPlaybackEngine)                                     CrucibleMPV (MPVPlaybackEngine, video texture, HDR metadata)
 Crucible (iPhone, iPad), CrucibleTV, CrucibleTopShelf                CrucibleSystem (D-Bus, portals, GDM, output control, secrets)
                                                                      CrucibleLinux (screens, player chrome, app: `crucible`)
```

- `CrucibleTokens` is new and shared: the values in `Theme`, `Theme.Metrics` and `TVMetrics` (colours for dark and light, the type scale, space and radius, card geometry, durations) move into plain Swift values. UIKit's `Theme` reads them; Kiln reads them. The two renderers cannot drift.
- `CruciblePlayback` is new and shared: `PlaybackSession` and `PlaybackReporter` leave `CrucibleMedia` and talk to a `PlaybackEngine` protocol instead of `AVPlayer` (§7.1). `CrucibleMedia` keeps the AVFoundation engine, remote commands and system captions.
- `Kiln` imports nothing from Crucible, so a second Midgar app can adopt it; it moves to its own package when one does.
- Dependencies point downward, screens never branch on the platform, and every rule of `docs/ARCHITECTURE.md` (Swift 6 language mode, `package` access, no inline comments, files under 1,000 lines, features as Core slices) applies unchanged.

### 4.2 Threads and the event loop

- **Main thread:** Kiln's event loop, one `epoll` over the Wayland display fd, the libdispatch main-queue handle (so `@MainActor` work runs here, through the same `_4CF` hooks CoreFoundation uses), the sd-bus fd, the mpv wakeup eventfd and a timerfd. Screens build and update the layer tree here and commit transactions.
- **Render thread:** owns the Vulkan device and queues, the committed scene, every running animation, the frame clock (`wp_presentation` feedback and `wp_fifo_v1`) and the mpv render context. It works like Core Animation's render server: animations are committed as curves and evaluated here, so a busy main actor never drops a frame at 144 Hz. Tailscode's governor logs show why: main-loop stalls of 250 ms and more happen on this machine.
- **mpv's threads** demux, decode and output audio. **The Swift concurrency pool** does networking, JSON, image decoding and GRDB.

## 5. Kiln, the UI engine

### 5.1 Why a purpose-built engine

| Option | Why not |
| --- | --- |
| GTK 4.24 | Composites in sRGB with no shipped HDR output path, no backdrop filter, `GtkGLArea` keeps mpv in SDR, and its widget focus model fights the tvOS focus physics. Right for Tailscode (a document app), wrong for a cinematic media app |
| Qt Quick 6.12 | The strongest off-the-shelf fit (MultiEffect blur, perspective rotation, AT-SPI), but C++ and QML around a Swift core over a C ABI, a full-window HDR Qt Quick surface on Plasma 6.8 is unverified, and Qt Quick 3D is GPL-only |
| Flutter | Plezy proves it for Plex on Linux, but it means rewriting the core in Dart |
| CEF | Every CSS effect, at the cost of a Chromium-sized runtime, a third language and still a native video plane underneath |
| Slint, iced, Xilem, Freya, Makepad | No documented backdrop blur, 3D or HDR; Xilem and Vello are experimental |

The Apple TV design system is about twenty components (`Sources/CrucibleTV/DesignSystem`): cards, shelves, grids, hero, backdrop, rows, chips, buttons, menus, state views, the tab bar and the player. An engine built for exactly those, with Core Animation's architecture, is smaller than adapting a general toolkit to them, and it is the only option that composites glass over live HDR video.

### 5.2 Layers

| Layer | Contents |
| --- | --- |
| Platform | Wayland client in Swift over C (protocol code generated by `wayland-scanner` and checked in): `xdg-shell`, subcompositor, viewporter, `fractional-scale-v1`, `wp_color_manager_v1`, `wp_presentation`, `fifo-v1`, `idle-inhibit`, `cursor-shape`, `xdg-activation`, `xdg-decoration`, `text-input-v3`, `linux-dmabuf`. Keyboard through xkbcommon. Gamepads through SDL3's gamepad subsystem only (Steam Input aware, the controller database) |
| Scene | A retained layer tree: frame, 3D transform, opacity, continuous corner radius, clip, shadow, and contents (image, text, colour, gradient, video, backdrop blur). The main actor commits immutable snapshots plus animations to the render thread |
| Layout | Pure functions from tokens and data to frames, mirroring the tvOS pieces instead of a general box model: stack, shelf (horizontal, `continuousGroupLeadingBoundary`), grid (`TVCardStyle.grid` column maths), hero, row list, overlay. Unit-tested against the tvOS numbers |
| Animation | Timed curves with the tvOS tokens (focus 0.2 s, fade 0.25 s, backdrop 0.35 s, debounce 0.4 s, skeleton pulse 1.2 s) and springs for focus lift and parallax. Reduce Motion follows the desktop's animation setting, read through the XDG Settings portal, and collapses them exactly as `TVMotion` does |
| Text | Pango for shaping, fallback, line breaking, line limits and tail ellipsis (the hero's 3, 2, 1 synopsis shrink order maps to Pango's height limit); each run rasterised by Pango and Cairo at the window's scale into an 8-bit coverage texture, cached by text and style, and drawn as a tinted quad (filtered only while a lift scales it) |
| Images | libjpeg-turbo, libpng and libwebp on the concurrency pool, the `TVImagePipeline` request rules (1.1 oversample, poster cap, backdrop sized to the output's device pixels), a disk cache in `$XDG_CACHE_HOME/crucible`. No shape baking: the GPU clips corners |
| Renderer | libplacebo on Vulkan 1.3: Kiln creates the device with mpv's own recipe (Vulkan Video decode queues, internally synchronised queues, so Kiln, mpv and FFmpeg's decode threads share queues safely) and hands it to mpv's `gpu-next` render API. Each frame draws into an FP16 linear-light texture (BT.709, 1.0 = 203 cd/m2, libplacebo's convention), blurs with a dual-Kawase pyramid for glass, composites the video texture in the same pass and is rendered onto an FP16 scRGB swapchain by `pl_render_image`, which also handles an SDR or PQ swapchain. Passes are GLSL bodies dispatched with `pl_shader_custom`, so Kiln has no Vulkan boilerplate of its own. NVIDIA's swapchain describes the surface itself (parametric BT.709, linear, luminances 0, 80 and 203) and owns its `wp_fifo_v1`, so the Wayland layer never creates either. Measured headless at 4K: scene, blur pyramid, glass and present cost 0.16 ms of GPU, and a 1,000 cd/m2 highlight reads back exactly (4.926) |
| Focus | §5.4 |
| Accessibility | AccessKit's C API with its Unix adapter (AT-SPI). Roles and labels come from the strings Core already builds (`accessibilityText`, `spokenLabel`) |

Vulkan and libplacebo because of video, not the 2D work: `gpu-next` is libplacebo's renderer and libplacebo's first backend is Vulkan, so decoded frames reach Kiln's image without a copy, Dolby Vision, tone mapping and scaling run where mpv's own player runs them, and the UI and the video share one colour pipeline.

### 5.3 Colour

UI colours stay sRGB tokens. The renderer linearises them and scales them to the reference white of the surface, so the UI looks identical on an SDR desktop and over HDR video. Video arrives as PQ BT.2020 (absolute luminance) and is decoded to linear in the composite pass. With the output in SDR, KWin tone-maps the surface (§3); with the output in HDR, highlights reach the panel.

### 5.4 Mouse and keyboard first

The desk is the main room (D4). Every screen is designed and judged with a mouse and a keyboard; the TV and the gamepad reuse the same screens.

- **Pointer:** a card under the pointer lifts with the tvOS focus effect and tilts toward it (parallax and a specular sheen that follow the pointer inside the card), the way iPadOS lifts artwork under a trackpad. A click selects; middle click opens a title in a new window; right click opens the context menu (the tvOS long-press menu); the back and forward mouse buttons walk history. Hover never moves keyboard focus, so a resting pointer cannot steal it.
- **Scrolling:** wheel and touchpad scroll grids and pages with momentum and rubber banding at the ends; shelves scroll sideways under a horizontal swipe or Shift with the wheel, and show edge arrows on hover for mice without a horizontal axis. Overlay scroll indicators appear while scrolling and on hover, never as permanent bars. Ctrl with the wheel resizes posters (the iPad's Command plus and minus).
- **Keyboard:** the geometric focus engine (below) moves with the arrows; Enter selects, Escape goes back, Tab and Shift+Tab walk controls in reading order, and the focus ring shows only once the keyboard is used (the platform's focus-visible rule). Typing a letter anywhere outside a text field opens Search with that letter. Every command has a shortcut and appears in the menu (§6).
- **Text:** titles, synopses and cast names can be selected and copied; tooltips name icon-only buttons after a short hover.
- **Focus engine:** modelled on tvOS: focus environments, preferred focus, focus guides, nearest-in-direction search with overlap preference, focus memory by item identifier across reloads (the `TVScreenViewController` rule), and the anchor that holds focus while a screen loads. The focus effect comes from `TVMetrics.Focus`: lift 1.04, pressed 0.98, shadow radius 32 at (0, 20) with 0.4 opacity, row growth `min(1.04, 1 + 40 / width)`.
- **Gamepad and couch (a plus):** d-pad and stick move focus with tvOS-like repeat acceleration, A selects, B goes back, Start plays and pauses, Y opens the context menu, LB and RB change tabs; the right stick drives the parallax a pointer would.

### 5.5 Two densities, one design

| Density | When | Values |
| --- | --- | --- |
| Desk (default) | Every window | The Apple TV layouts and components at 60% of the tvOS numbers, type, space, radius and geometry alike, so body text lands on the iPad's 17 points (17.5), a poster is 156 x 234 and the gutter 24; a wider window shows more of the same shelves and more grid columns, and Ctrl with the wheel zooms cards from 0.7 to 1.6 times |
| Couch | Chosen in the View menu, `crucible --couch` (the Steam Big Picture shortcut), or offered once when a gamepad is used fullscreen on an output 40 inches or larger (from EDID) | The tvOS tokens one to one on a 1920 x 1080 point canvas scaled to the output (2x on the C5 at 4K) |

Desk windows adapt like the iPad's `Theme.Room`: grids add columns toward the target poster width, list screens centre a readable column, and the hero grows with the window. Windowed mode uses KWin's server-side decorations; fullscreen (F11) and Couch hide them.

### 5.6 Type and symbols

- **Type:** Inter (SIL OFL), bundled so metrics match on every distribution, as static cuts: Inter Display from an optical size of 23 points, the middle of Inter's 14 to 32 axis (SF moves from Text to Display at 20), and Inter below it; on the TV the optical size follows the reading distance, so 29 point body text stays Text. CJK and other scripts Inter lacks fall back through fontconfig, to Noto Sans CJK when it is installed (an optional dependency of the package) or any CJK font the system has. The tvOS sizes are kept; line heights are checked in the parity captures (§11).
- **Symbols:** SF Symbols cannot ship. One map file names an open icon (Lucide, ISC) for every SF Symbol name Core and the Apple TV screens use, with a drawn icon where Lucide has no match; a unit test fails when Core names a symbol the map lacks. librsvg rasterises each icon at the pixel size it is drawn at into a cached coverage texture, so it is sharp at every density; `.fill` names fill the outline and `.circle.fill` names cut their glyph out of a solid disc.

### 5.7 Liquid Glass

Glass is a layer content type with a shape (rounded rectangle or capsule, as a signed distance field) and a variant (regular or clear), drawn in one shader pass over whatever lies behind it, including live HDR video, because Kiln composites everything itself (§7.3).

| Property | How Kiln draws it |
| --- | --- |
| Lensing | Behind-content is sampled through a refraction offset along the shape's distance-field normal, strongest in a rim band (about 14 points at Desk density), so edges bend the picture as a thick lens does; a slight colour dispersion at the rim |
| Frost | The sample comes from the dual-Kawase pyramid at a radius set by the variant; clear glass keeps the picture almost sharp and adds a dimming layer for legibility |
| Light | A specular rim from the normal and a light direction that follows the pointer (or focus, or the right stick), plus a soft inner highlight on the top edge; pressing brightens the area under the pointer |
| Adaptivity | The behind-content's mean luminance under the shape picks light or dark glass and the label colour, with hysteresis so text never flickers over moving video: the pyramid's smallest level is copied to the host asynchronously once a frame and read a frame or two later, and each glass element flips its tone (glass and label together, on a fade) when the luminance crosses 0.42 going up or 0.28 going down |
| Shadow | A soft contact shadow under floating glass (tab bar, player transport, menus), absent on flush controls |
| Morphing | Shapes in one glass container blend with a smooth minimum of their distance fields, so the tab bar's selection slides as a liquid drop and menus grow out of the button that opened them, on springs |
| Focus | A focused glass button becomes the light pill with dark text that tvOS 26 draws (`TVButton` legibility rules) |

Reduce Transparency (the desktop setting, read through the portal) turns every variant into the opaque `surfaceRaised` fallback that `Glass` uses on older Apple TVs. Glass gets its own gallery page with every variant over a still, a bright poster and a playing HDR clip, each with golden images.

## 6. Navigation and screens

- One top tab bar as on the Apple TV: Home, one tab per movie or show library (three plus More past four), Search, You. It slides away as content scrolls, except on Search.
- `LinuxScreens` mirrors `TVScreens`: each feature adds its factory in its own file, so screens open each other without importing each other.

| Screen | Core slice | Linux specifics |
| --- | --- | --- |
| Sign in | `Features/Auth` (Plex PIN, QR for the strong PIN) | Same flow; the browser opens with `xdg-open` on a desk |
| Home | `Features/Home`, `Snapshots` | Full-screen backdrop following focus, non-focusable hero, shelves |
| Library | `Features/Library`, `Navigation` | Chips, Genre and Sort menus, Browse Folders, grid |
| Detail (movie, show, season, episode) | `Features/Detail`, `Rating`, `People`, `Watchlist` | Audio and subtitle menus, cast row, gaps the server lacks, Seerr requests |
| Search | `Features/Search` | Desk: a real text field with IME through `text-input-v3`. Couch: the tvOS-style letter grid, so a gamepad can type |
| You, History, Collections, Playlists | `Features/You`, `History`, `Collections`, `Playlists` | As on the Apple TV |
| Statistics, Year in Review | `CrucibleStats` | Charts drawn by Kiln from `StatsMetrics.tv` and a new desk preset. Share Your Year opens the poster preview: the iPhone's Story and Square compositions from `StatsShareFacts`, drawn by one Kiln view at any size (the preview, then 1080 pixels wide offscreen on the app's GPU for export), with the lead poster blurred by the frost pyramid for the wash. Save to Pictures (Ctrl+S) writes a PNG to the XDG Pictures folder without replacing a file; Copy Image (Ctrl+C) offers it on the clipboard as `image/png` |
| What to Watch, described recaps | `Features/Watch`, `Hosted`, `Companion` | Free, on the person's own model (D1): an `OwnModelBrain` implements `HostedBrain` against the paired Crucible Server's model or an OpenAI-compatible address, with the alias prompts bundled from `tools/ai/` |
| Settings | `Features/Settings/SettingsCatalog` | Catalogue entries gain a Linux platform flag; Linux-only entries: model address and key, audio passthrough, Match Content, density. Pro entries are hidden |
| Trakt, Seerr, Crucible Server | `Features/Trakt`, `Seerr`, `Companion` | Device code and QR as on the Apple TV; Crucible Server pairs by invite or QR (the Bonjour hand-off is Apple-only) |
| Player, Up Next, post-play, sleep timer, still watching | `CruciblePlayback`, `Features/Playback` | §7.5 |

- **Menu and shortcuts**, taken from the iPad's `AppCommand` and `AppMenu` with Ctrl for Command: a menu button in the tab bar (and F10) opens Go, View, Media and Settings, each item showing its shortcut. Ctrl+1 to 4 (tabs), Ctrl+F or `/` (search), Alt+Left and Alt+Right (back and forward), Ctrl+R (refresh), Ctrl+plus and minus (poster size), Ctrl+N (new window), Ctrl+comma (settings), F11 (fullscreen), and in the player Space or K, J and L, Left and Right, S (skip intro or credits), N (next episode), F (fullscreen), M (mute), Up and Down (volume) and Escape. Ctrl+? shows the full list, as the iPad's Command-key overlay does.
- **Windows:** several windows share one connection, as on the iPad (`SceneDelegate.launchLeader`); each restores its tab and screen, and a title opens in a new window from its context menu or by middle click.
- **Not on Linux:** Top Shelf, widgets, the Live Activity and downloads. Downloads can follow later; the others have no Linux equivalent worth building.

## 7. Playback

### 7.1 The engine seam

`PlaybackSession` (stream resolution, resume, timeline reporting, transcode keep-alive and restarts, fallback, skip markers, Up Next, self-healing) lives in `CrucibleMedia`, 2,295 lines of which eleven of twelve files touch AVFoundation. It moves to `CruciblePlayback` behind a `PlaybackEngine` protocol: load an item (URL, headers, start position), play, pause, seek, rate, audio and subtitle tracks, a stream of time, state, buffering and errors, and the item's end. The Apple side moves first and is checked with the Apple TV UI tests, the iPhone shots and `scripts/mac.sh bench`; then `MPVPlaybackEngine` implements the same protocol and the bench's 26 episode-flow behaviours run against it headless.

### 7.2 What plays directly

On Linux `PlaybackCapabilities` says mpv decodes every container and codec, so direct play is the default and the server transcodes only for bandwidth (a remote or relay route) or a chosen quality. Every text and image subtitle renders on the client (libass, PGS), so nothing is burned in.

### 7.3 Video and HDR

**The path (decided in P0):** mpv's `gpu-next` renders each frame through a Vulkan render API into a Kiln-owned FP16 image on Kiln's device: PQ BT.2020 for HDR sources, so absolute luminance survives, and BT.709 for SDR. Kiln composites that image under the player chrome in linear light, so glass panels blur the live picture as tvOS 26 does, video can shrink into a card or play behind the hero, and the window stays one scRGB surface. The render API is the andrewrabert/mpv `gpu-next` series rebased onto mpv 0.42 and kept in `linux/vendor/mpv` (built with libplacebo 7.387 or newer, also vendored while Arch ships 7.360) until it is accepted upstream; the P0 spike showed it renders Dolby Vision 5 identical to mpv's own player, where upstream's `gl_video` path does not. Dolby Vision 7 enhancement layers come with it, since they are a `gpu-next` feature of 0.42.

**HDR metadata:** mastering primaries and luminance, MaxCLL and MaxFALL come from mpv's `video-params` and go into the surface's image description, never as zeros (§3).

**Fallback:** if the vendored series cannot follow mpv for a release, mpv runs its own `gpu-next` Wayland output, made a subsurface below Kiln's surface by a Wayland proxy (the Jellium pattern), with mpv 0.42's own colour management; the chrome then sits in a sibling surface and glass over video becomes a translucent plate without live blur. Rejected as the main path because upstream's OpenGL render API (`gl_video`) gets Dolby Vision 5 wrong (§3).

### 7.4 Match Content

Match Content in Settings › Playback, on by default, acts whenever the player is fullscreen, and only on the output showing it: an HDR title switches that output to HDR with wide colour gamut through `kde_output_management_v2` (the devices come from `kde_output_device_registry_v2` on KWin 6.5 and later) and it goes back when playback ends or leaves full screen, the same rule as `hdr-game`. The state to go back to is written to `$XDG_STATE_HOME/crucible/display-prior.json` first and `crucible --display-guard` watches the player's process, so a crash or a kill still ends with the output restored, and a launch restores what a guard could not. Frame rates match where the mode exists at the current size, a whole number of refreshes a frame within 0.05%: 23.976 and 29.97 fps to 119.88 Hz, 25 and 50 fps to 100 Hz, 24.000 stays on 144 Hz (exactly six refreshes a frame) (`MatchContentPlan`). Compositors other than KWin get no switching and tone-map or clip on their own.

### 7.5 Player chrome

Rebuilt in Kiln from the tvOS 26 player Crucible uses today: title and transport bar with scrubbing thumbnails (Plex's index thumbnails), time left, glass Info, Audio, Subtitles and speed menus, contextual Skip Intro and Skip Credits from Core's markers, the Up Next card with Watch Credits and Play Now, post-play, the sleep timer, Still Watching and Rewind After a Break. The rules all come from Core (skip distances, hold actions, countdowns); only drawing is new. Inputs: Space and K play and pause, Left and Right skip by Core's distances, Up and Down open the info panel, triggers scrub.

### 7.6 Audio

mpv with `ao=pipewire` (other outputs only when PipeWire is missing). Audio Passthrough in Settings › Playback (Automatic, Always, Never) feeds `audio-spdif`: Automatic with the codecs the default sink is set to accept (its `iec958Codecs` in `pw-dump`), Always with every one, which the sink is then set to accept, so TrueHD with Atmos, DTS-HD, E-AC-3 and AC-3 reach the receiver or TV as bitstreams; otherwise mpv decodes to multichannel PCM. PipeWire forgets a sink's enabled IEC958 codecs when it reconnects (PipeWire issue 3462), so when a play starts Crucible remembers the sink's own choice and sets it again with `pw-cli` when it finds the sink back on PCM alone. Headless runs pass `KILN_AO=null` and stay silent.

## 8. Shared code: the Linux seams

Each seam is a protocol, a cross-platform API or a Linux stand-in with Apple's surface, kept in `Support/Portability` or beside its feature, never `#if` scattered through feature code.

| Seam | Before | Now (P1, done 2026-11-15) |
| --- | --- | --- |
| Locks | `OSAllocatedUnfairLock`, 10 sites | Unchanged call sites; Linux gets a stand-in with the same surface (`Support/Portability/UnfairLockLinux.swift`), because `Synchronization.Mutex` needs iOS 18 and Crucible supports iOS 17 |
| Logging | `os.Logger` in 5 files | `MidgarLog` everywhere (it already builds on Linux) |
| Crypto | `CryptoKit` in 3 files | `Crypto` from swift-crypto on Linux, the same API, declared for Linux only in `Package.swift` |
| Secrets | `KeychainHelper`, `ProWeek` | `KeychainHelper` sits on a `SecretStoring` backend: the Keychain on Apple; on Linux the store the app installs (Secret Service), with a 0600 file as the default. Pro Week keeps its Keychain item on Apple only |
| Strings | `String(localized:)`, 1,421 call sites, 16 languages | Unchanged call sites. On Linux, `String.LocalizationValue` and `String(localized:)` are implemented in Core (`LocalizationLinux.swift`), reading the same `Localizable.xcstrings` at launch, with CLDR plural rules for the 16 languages and a formatter that fills `%@`, `%lld` and positional arguments while leaving a literal `%` (as in "87% critics") as text |
| Formatters | `RelativeDateTimeFormatter`, `ListFormatter`, `DateComponentsFormatter` at 11 sites | `PortableFormat`: the formatters on Apple (iOS 17), swift-foundation's `AnchoredRelativeFormatStyle`, `ListFormatStyle` and `Duration.UnitsFormatStyle` on Linux |
| HTTP | `URLSession.shared` at 10 sites | `HTTPSession.current` (`.shared` unless installed). swift-corelibs-foundation's shared session only sees URL protocols registered before its first use, so tests install one session with their stubs |
| Server events | `URLSession.bytes(for:)` | A streaming `bytes(for:)` for Linux built on a delegate data task (`StreamingBytesLinux.swift`), cancelled when the reader stops |
| Certificate pinning | `CompanionClient`'s trust challenge | The decision (`FingerprintTrust.accept`) is shared; Apple answers URLSession's challenge, Linux sends through an installed `FingerprintPinnedTransport` (AsyncHTTPClient and NIOSSL in the Linux package) |
| Network changes | `NWPathMonitor` | `NetworkPathWatcher`: Network.framework on Apple, rtnetlink link, address and route events on Linux, same signature |
| Addresses | `IPv4Address`, `IPv6Address` | `IPAddressBytes` (`inet_pton`) on both platforms |
| Device capability | VideoToolbox and `AVPlayer` in `StreamProfile` | Apple probes as before; Linux defaults to everything mpv decodes, with HDR kept, and the app can `provide` its own |
| Platform | App Group container, `NSSetUncaughtExceptionHandler`, Library directories | `AppPlatform` answers `Linux` and XDG directories (`~/.local/share/crucible`, logs in `~/.local/state/crucible`); Top Shelf and the exception handler stay Apple-only |
| Apple-only | Bonjour hand-off channel | Stays behind `canImport(Network)` |
| Tests | `URLProtocol` stubs | Registered once and delivered only while the task runs (swift-corelibs-foundation traps on a late answer) |

Measured: all 1,709 Core tests pass on Linux (Swift 6.4.2) and all 1,710 on the Mac host (the extra one is the Apple-only hand-off), and the iPhone and Apple TV package schemes build.

A Linux job in CI (`.github/workflows/linux-core.yml`) runs `CRUCIBLE_CORE_ONLY=1 swift test` on every push, so an Apple-side change cannot break Linux unnoticed; MidgarKit should get the same job for `MidgarCore`, which has no CI today.

## 9. System integration (`CrucibleSystem`)

| Need | Mechanism |
| --- | --- |
| Media keys and desktop media controls | MPRIS over sd-bus: metadata, artwork, position, seek |
| Keep the screen awake | `zwp_idle_inhibit_v1` on the window while playing, with `org.freedesktop.ScreenSaver.Inhibit` as fallback (gamescope lacks idle inhibit) |
| Find servers | Plex GDM over UDP (an `M-SEARCH` to the multicast group 239.0.0.250 and the broadcast address on port 32414; 32412 is where players answer, not servers) beside plex.tv resources and the tailnet routes Core already probes, and on their own when plex.tv cannot be reached |
| `crucible://` links and one instance | A desktop entry with `MimeType=x-scheme-handler/crucible;` and the D-Bus name `org.guitaripod.Crucible`, which hands a second launch's link to the running app and Core's deep-link parser |
| Notifications | `org.freedesktop.Notifications` for `LibraryNews` while the app runs; a systemd user timer for background refresh can follow |
| Output HDR and refresh rate | `kde_output_management_v2` (§7.4) |
| Couch | `crucible --couch` as a non-Steam shortcut for Big Picture: `linux/scripts/steam-shortcut.py` adds it to every Steam account with Steam closed and picks Steam Input's own gamepad templates for it (gamepad and trackpad mouse on the Steam Deck and DualSense, gamepad elsewhere) |
| Clean exit | SIGTERM, SIGINT and SIGHUP save resume positions and send the stopped timeline before exiting (the Tailscode lesson that an unhandled SIGTERM counts as a crash) |

## 10. Layout, build and install

- The root `Package.swift` declares the Linux targets inside `#if os(Linux)`, as it declares the tvOS ones only on macOS, so the Apple graphs stay unchanged: `CrucibleTokens` and `CruciblePlayback` (both platforms), `Kiln` with its C target `CKiln`, system libraries (`mpv`, `wayland-client`, `egl`, `pango`, `xkbcommon`, `sdl3`, `libsecret`, `libsystemd`, `libjpeg`, `libpng`, `libwebp`, `icu-uc`), `CrucibleMPV`, `CrucibleSystem` and the executable `CrucibleLinux` (product `crucible`).
- `linux/` holds what `tv/` holds for the Apple TV: `README.md`, `scripts/linux.sh build|run|test|shot|uitest|install`, `packaging/` (PKGBUILD, desktop entry, icons, AppStream metadata), and resources (Inter, the symbol atlas, compiled strings).
- `linux/scripts/linux.sh install` builds release with the Swift runtime linked statically, installs `~/.local/bin/crucible`, the desktop entry, icons and the scheme handler, and checks that the installed binary reports the new version.

## 11. Testing and parity

- **Core:** the Linux CI job and `linux/scripts/linux.sh core-test`.
- **Kiln:** unit tests for layout (shelf and grid maths equal `TVCardStyle`), the focus engine (directional search cases), text limits and ellipsis, and the colour pipeline (sRGB to scRGB, PQ decode within tolerance).
- **Gallery:** `crucible-gallery` shows every component with the Apple TV gallery's fixture titles and runtime-drawn art (Home, cards, controls over dark and bright art, a library grid, states, genre tiles with cast monograms, brand marks and the letter grid, fields and the panels presented over them, and every Statistics component), in a window (keys 1 to 8) or with `--capture DIR` offscreen to PNG at any size, scale, density and appearance, each page also in its focused, hovered and presented states. `linux/scripts/gallery-check.sh` captures every page in Desk dark and Couch light and compares each with its golden thumbnail in `linux/Tests/Gallery` (a quarter of the capture, averaged in linear light, so a moved layout, colour or state fails while a spinner's angle does not), writing red diff images on a mismatch; `--update` rewrites the goldens after a deliberate design change, and every new golden is looked at before it is committed.
- **Screens:** headless EGL renders every screen against `marketing/mock/server.py`, driven by a scripted remote over a debug socket (press, select, back), the way XCUITest drives `XCUIRemote`. Captures go beside the Apple TV UI-test captures of the same mock library in a contact sheet, and every image is looked at; a passing count is never trusted on its own (the store-capture lesson).
- **Playback:** HDR10, HLG, Dolby Vision 5 and 8.1, and 23.976 fps SDR samples; the FP16 texture is read back to check PQ code values; KWin's own screenshot with the output in HDR checks the end; `pw-dump` confirms the IEC958 format on the C5 path.
- **Episode flow:** `CrucibleBench` against `MPVPlaybackEngine` headless.

## 12. Delivery

| Phase | Work | Done when |
| --- | --- | --- |
| P0 Spikes | Kiln window with an FP16 scRGB surface on KWin 6.8 and NVIDIA 615, one glass panel blurring an image at 4K 144 Hz; mpv rendering HDR10, Dolby Vision 5 and 8 into the shared texture; output HDR switch and restore; the main actor on Kiln's loop; TrueHD passthrough to the C5 | 144 fps without a dropped frame at the 99th percentile, measured PQ values, a KWin screenshot, a receiver showing Atmos. Path A or B is decided here |
| P0 status (2026-11-15) | Done: FP16 scRGB window on KWin 6.8 and NVIDIA 615 with Liquid Glass (OpenGL spike, `kiln-spike`), the main actor on Kiln's loop, HDR10 and Dolby Vision 5, 8.1 and 7 through mpv into Kiln's image (`kiln-video-spike`), the render-path decision. Also done: the vendored mpv 0.42 series with zero-copy Vulkan Video decode (0.55 to 0.67 ms per 4K frame, Dolby Vision 5 matching the reference). Also done: Kiln's renderer on libplacebo and Vulkan with the glass ported (`kiln-spike`, identical look, 0.16 ms per 4K frame). Open: 144 Hz pacing on the C5, output HDR switching, TrueHD passthrough | |
| P1 Core on Linux | The seams of §8, `FormatStyle`, the strings compiler, AsyncHTTPClient, `CrucibleTokens`, `CruciblePlayback` (Apple first), CI | Core tests pass on Linux and macOS; Apple TV UI tests, iPhone shots and the bench unchanged |
| P2 Kiln components | The design system and the gallery | Golden images beside the Apple TV gallery |
| P3 Screens | Sign in, Home, Library, Detail, Search, You, Settings | Parity contact sheets against the Apple TV captures |
| P4 Player | Chrome, markers, Up Next, post-play, sleep timer, MPRIS, idle inhibit, Match Content | Bench passes on mpv; a film and a series watched start to finish on the C5 |
| P5 Integrations | Trakt, Seerr, Statistics, What to Watch and recaps on the person's own model (D1), Crucible Server | Each feature's Apple TV UI test has a Linux counterpart |
| P6 Ship | Install script, AUR, release tarball and self-update, README screenshots | Installed from the package on arch (D2) |
| Status (2026-11-15) | P1 done (1,711 Core tests on Linux in CI). P2 done: Kiln's views, focus, springs, scrolling, text, images, symbols, glass with adaptive tone, menus and text fields; the design system and `crucible-gallery`. P3 in place: sign-in through plex.tv with code and QR, server choice, launch gate, Home, the libraries, title pages, Search (type anywhere), You, Settings from the shared catalogue's Linux entries, card context menus. P4 in place: the player with the glass transport, Audio and Subtitles, Skip Intro and Credits (automatic when set), Up Next with its countdown, timeline reports, MPRIS, HDR10 and Dolby Vision into Kiln through libmpv on Kiln's own device (mpv patch 0011). P6: `linux/scripts/install.sh` installs and stamps a checkout build; `linux/scripts/release-tarball.sh` builds the release tarball and Software Update installs the next one in place; `linux/packaging/aur/crucible` (from the `linux-X.Y.Z` tag) and `crucible-git` build with makepkg, and `linux/scripts/aur-release.sh VERSION --push` publishes them. Open: checks against a signed-in server, post-play suggestions, still watching, Match Content and the real-display checks of P0, P5, publishing to the AUR | |

**Releases and Software Update (D2).** `linux/scripts/release-tarball.sh --with-trakt|--without-trakt` builds `crucible-linux-X.Y.Z-ARCH.tar.zst` and its `.sha256` from a clean export of HEAD (nothing uncommitted rides along; Trakt's gitignored Client ID only when asked), for a GitHub release tagged `linux-X.Y.Z` beside the server's `server-v` releases. The tarball's `install.sh` installs into `~/.local` (or `--prefix`), swapping the install in one move so a running Crucible keeps working, and leaves a stamp in `$XDG_STATE_HOME/crucible/install.json`; `linux/scripts/install.sh` stamps checkout installs the same way. You → About Crucible → Software Update reads how the running copy was installed (Core's `LinuxInstallKind`: a stamp counts only when it names the running executable at its current size; `/usr` and `/opt` belong to pacman; a build directory is a working copy), asks GitHub for the newest `linux-` release once a day after launch and whenever the screen opens, and offers what that install allows (`LinuxUpdateOffer`): a tarball install downloads the release, checks its SHA-256, runs the release's own `install.sh` and restarts into it; a pacman install copies the AUR helper's command for its package; a checkout copies `git pull && linux/scripts/install.sh`; a bare binary opens the release page. A headless run points the check at a local listing with `CRUCIBLE_RELEASES_URL`.

Linux targets never affect the Apple builds, so every phase lands on `master` as it is finished.

Feature parity is tracked row by row in `linux/PARITY.md` (audited 2026-11-15; `linux/scripts/parity.py done <id>` checks a row off, `open` lists what is left). The AUR package (D2) is published only once every row is closed and Marcus has used the client day to day for a while.

## 13. Risks

| Risk | Answer |
| --- | --- |
| The vendored `gpu-next` render API drifts from mpv | Rebased each mpv release with the Dolby Vision, HDR10 and timing checks of `KilnVideoSpike` as its gate, offered upstream as a clean series; the Wayland-proxy fallback of §7.3 needs no patch |
| NVIDIA and KWin frame pacing at 144 Hz (triple buffering is on by default for NVIDIA in Plasma 6.8) | P0 measures with `wp_presentation` feedback before any screen is built |
| GRDB's Linux support is contributor-maintained and not in GRDB's CI | Crucible's Linux CI runs the statistics tests |
| An engine is more code than a toolkit | It is bounded by the design system's twenty components, and the gallery plus golden images keep it honest |
| Inter's line heights differ from SF Pro's | Tokens keep point sizes; parity captures catch layout shifts |
