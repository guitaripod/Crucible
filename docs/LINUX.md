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
| D6 | Web video | 2026-11-17: the Linux client plays YouTube and whatever else yt-dlp reads, as a destination beside the libraries, built on open tools (yt-dlp, mpv, SponsorBlock) and never on a site's API or account, with an inbox of every followed channel's new videos. It exists on Linux only: none of its code or words is in any target or catalog the Apple apps build from (§14) |

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
| gamescope reports only XWayland windows to Steam as focusable, so a Wayland toplevel launched from Steam's Game Mode is never shown: Steam stays on its launch screen while the app draws unseen | gamescope 3.16 `steamcompmgr.cpp` (`determine_and_apply_focus`); measured on a Steam Deck OLED, SteamOS 3.9.5 (2026-11-16) | In Game Mode Kiln opens an X11 window (§9.1) |
| gamescope's WSI layer, which Game Mode turns on for every launch, looks queues up without their creation flags and aborts on an internally synchronised queue | crash on the Deck in `vkroots` under `pl_vulkan_create` | Under the layer the device's queues are left to libplacebo's locking |
| On an HDR output gamescope shows SDR content (Steam's interface) at `GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS` times the SDR gain and multiplies HDR content by the HDR gain; Steam's brightness slider sets both gains on the root window | gamescope `steamcompmgr.cpp` (colour LUTs) | Kiln scales its scRGB output so its white lands on Steam's, and draws SDR when the output is SDR (§9.1) |
| swift-corelibs-foundation's URLSession only ever adds libdispatch sources for a socket: after libcurl has sent a request and only waits to read, the write source stays and fires as fast as the socket is writable. Any request that stays open (the server-events stream) spins a core for as long as the app runs: 99% CPU measured on the desktop, 108% on the Deck | `MultiHandle.swift` (`_SocketSources.createSources`); perf on both machines | `CLinuxServices/crucible_curl.c` relays URLSession's socket callback and drops the sources libcurl no longer wants |
| RADV on the Deck exposes no Vulkan Video decode, and the gpu-next libmpv backend handed mpv no display, so VA-API fell back to copying every frame through system memory (`vaapi-copy`) | mpv's log on the Deck | mpv patch 0012 opens the GPU's render node for the VA-API interop: zero-copy VA-API |
| On NVIDIA `hwdec=auto-safe` settled on `nvdec-copy` (this libmpv has no CUDA interop), so every 4K HDR frame went back to system memory and was uploaded again on the UI thread: 3.6 ms of main-thread time per frame and 7% of a core in mpv's core thread for a 24 fps title | Live sampling of the running client, then `KILN_HWDEC=vulkan` headless with `KILN_TRACE` | NVIDIA asks for `vulkan,auto-safe` (`preferred_hwdec` in `kiln_video.c`): 0.8 ms per frame, main thread 8.8% to 1.5% and mpv's core 7% to 0.5% of a core; HEVC HDR10, Dolby Vision 8.1 and 7, H.264, AV1 and VP9 decode the same picture, MPEG-2 and VC-1 fall through to `auto-safe` |
| The vendored Vulkan render backend ended every frame with `pl_gpu_finish()` and never read the `MPV_RENDER_PARAM_VULKAN_SYNC` its header declares, so Kiln's main thread waited out all of a frame's GPU work: 9 to 11 ms of every 4K frame on the Deck, which held 4K 60 fps titles near 40 fps | `KILN_FRAMES` and `perf` on the Deck (2026-11-16); `video/out/gpu_next/context.c` | mpv patch 0013 hands the frame back through a timeline semaphore that Kiln's next use waits for on the GPU (§7.3) |
| Opening a title's page froze the desktop window for 0.4 to 0.9 s as the page slid in (8 frames drawn of the push's 39, one gap of 574 ms): the gpu-next render backend loaded every hardware decode interop when a render context was created, on the caller's thread, and on NVIDIA the VA-API one opens nvidia-vaapi-driver, which takes that long to find it cannot work. Every player made paid it, and Instant Start makes one as a title's page opens | Headless on a copy of the signed-in profile with `KILN_FRAMES` (gone with `CRUCIBLE_INSTANT=0`), then mpv's own log (`KILN_MPV_OPTIONS='msg-level=all=v;log-file=…'`) | mpv patch 0014 has the backend load what `gpu-hwdec-interop` names, and NVIDIA asks for `vulkan` alone (`preferred_hwdec_interop` in `kiln_video.c`): a player is made in about 4 ms, the push draws all 39 frames, and Vulkan Video still decodes. Other GPUs load them all as before |
| mpv's default chroma upscaler (Lanczos) brings a 4:2:0 picture's colour up to the full size of its luma before the picture is scaled to the view, so a 4K picture on an 800-line screen spent most of mpv's GPU time on a pass whose detail the shrinking then discards | `KILN_MPV_OPTIONS` trials on the Deck: `cscale=bilinear` alone took 4K 60 fps from 52% to 32% of the GPU | A picture shown at half its size or smaller gets the bilinear chroma pass (§7.3) |
| gamescope sets its refresh for the shown title from the private `gamescope_control` protocol, which Steam drives and whose definition says regular clients must not use it; the `GAMESCOPE_DYNAMIC_REFRESH` root property Steam still writes is cleared on every frame it composes | gamescope 3.16 `steamcompmgr.cpp` (`_update_app_target_refresh_cycle`), `gamescope-control.xml` | No Match Content in Game Mode: Steam's per-game refresh rate (72 Hz for film on the OLED) is the way (§7.4) |

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

- **Pointer:** a card under the pointer lifts with the tvOS focus effect and tilts toward it (parallax and a specular sheen that follow the pointer inside the card), the way iPadOS lifts artwork under a trackpad, and in the Desktop layout brings out a play button, a watched toggle and a menu button on its artwork, with the full title in a tooltip when the caption cuts it short. A click selects; middle click opens a title in a new window; right click opens the context menu, a desktop menu (one highlighted row per panel, submenus with menu aim, type-ahead) rather than the tvOS long-press panel; the back and forward mouse buttons walk history. Hover never moves keyboard focus, so a resting pointer cannot steal it.
- **Scrolling:** wheel and touchpad scroll grids and pages with momentum and rubber banding at the ends; shelves of many titles (Home, a library) scroll sideways under a horizontal swipe or Shift with the wheel, and show edge arrows on hover for mice without a horizontal axis, but a row a mouse should see whole wraps onto further lines instead of scrolling: a title page's action and filter chips, Search's genre tiles, and a title page's Cast & Crew, Extras, More Like This and episodes (the first two lines, with Show All in the header for the rest, and every episode of the season). In the Desktop layout every vertical page has a slim scrollbar that stays while there is more to scroll, widens under the pointer, drags and pages on a click, and Page Up, Page Down, Home and End scroll; the Steam Deck layout keeps tvOS's indicator that shows only while scrolling. Ctrl with the wheel resizes posters (the iPad's Command plus and minus).
- **Keyboard:** the geometric focus engine (below) moves with the arrows; Enter selects, Escape goes back, Tab and Shift+Tab walk controls in reading order, and the focus ring shows only once the keyboard is used (the platform's focus-visible rule). Typing a letter anywhere outside a text field opens Search with that letter. Every command has a shortcut and appears in the menu (§6).
- **Text:** titles, synopses and cast names can be selected and copied; tooltips name icon-only buttons after a short hover.
- **Focus engine:** modelled on tvOS: focus environments, preferred focus, focus guides, nearest-in-direction search with overlap preference, focus memory by item identifier across reloads (the `TVScreenViewController` rule), and the anchor that holds focus while a screen loads. The focus effect comes from `TVMetrics.Focus`: lift 1.04, pressed 0.98, shadow radius 32 at (0, 20) with 0.4 opacity, row growth `min(1.04, 1 + 40 / width)`.
- **Gamepad and couch (a plus):** d-pad and stick move focus with tvOS-like repeat acceleration, A selects, B goes back, Start plays and pauses, Y opens the context menu, LB and RB change tabs; the right stick drives the parallax a pointer would.

### 5.5 Two layouts, one design

| Layout (density) | When | Values |
| --- | --- | --- |
| Desktop (`desk`, default) | Every window outside Steam's Game Mode | The Apple TV components at 60% of the tvOS numbers, type, space, radius and geometry alike, so body text lands on the iPad's 17 points (17.5), a poster is 156 x 234 and the gutter 24; a wider window shows more of the same shelves and more grid columns, and Ctrl with the wheel zooms cards from 0.7 to 1.6 times. Laid out for a mouse and keyboard rather than a remote: a sidebar instead of the floating tab bar (below), two-pane Settings with switches, a season's episodes as a list, the player's desktop control bar (whose menus, Mini Player and Full Screen move to their own row beside the title when the window is too narrow for one row), desktop menus, scrollbars, text fields and dialogs |
| Steam Deck (`couch`) | Steam's Game Mode (gamescope with Steam's gamepad interface) until the viewer picks a layout, Settings › Appearance › Layout, the View menu's Switch Layout, `crucible --steam-deck` (the Steam shortcut; `--couch` still works), `CRUCIBLE_LAYOUT=steam-deck`, or offered once when a gamepad is used fullscreen on an output 40 inches or larger (from EDID) | The tvOS tokens one to one on a 1920 x 1080 point canvas scaled to the output (2x on the C5 at 4K, two thirds on the Deck's 1280 x 800, where the canvas grows to 1920 x 1200), with the tvOS screens as the Apple TV draws them |

`--desktop` and `CRUCIBLE_LAYOUT=desktop` force the Desktop layout. Desktop windows adapt like the iPad's `Theme.Room`: grids add columns toward the target poster width, forms centre a readable column (wider than on a TV), and the hero grows with the window. Windowed mode uses KWin's server-side decorations; fullscreen (F11) and the Steam Deck layout hide them.

#### The Desktop layout's sidebar

The Desktop layout navigates from a sidebar down the window's leading edge instead of the floating tab bar: Back and Forward at its head (Alt+Left and Alt+Right, the mouse's side buttons), Home and Search, every library (the tab bar's More folds into the list), You, and Settings and the app's menu at its foot (the menu cascades into Go, View, Media and Settings). Ctrl with a number picks destinations in the order they show; Ctrl+B, or a window narrower than about 1140 points, narrows it to a rail of symbols named in tooltips. Pages no longer leave room for a floating bar at their top.

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
| Settings | `Features/Settings/SettingsCatalog` | Catalogue entries gain a Linux platform flag; Linux-only entries: model address and key, audio passthrough, Match Content, density. Pro entries are hidden. The app adds its own rows to the catalogue's sections (`LinuxSettingsCatalog`, §7.7) |
| Trakt, Seerr, Crucible Server | `Features/Trakt`, `Seerr`, `Companion` | Device code and QR as on the Apple TV; Crucible Server pairs by invite or QR (the Bonjour hand-off is Apple-only) |
| Player, Up Next, post-play, sleep timer, still watching | `CruciblePlayback`, `Features/Playback` | §7.5 |

- **Menu and shortcuts**, taken from the iPad's `AppCommand` and `AppMenu` with Ctrl for Command: a menu button in the tab bar (and F10) opens Go, View, Media and Settings, each item showing its shortcut. Ctrl+1 to 4 (tabs), Ctrl+F or `/` (search), Alt+Left and Alt+Right (back and forward), Ctrl+R (refresh), Ctrl+plus and minus (poster size), Ctrl+N (new window), Ctrl+comma (settings), F11 (fullscreen), and in the player Space or K, J and L, Left and Right, S (skip intro or credits), N (next episode), F (fullscreen), M (mute), Up and Down (volume) and Escape. Ctrl+? shows the full list, as the iPad's Command-key overlay does.
- **Windows:** several windows share one connection, as on the iPad (`SceneDelegate.launchLeader`); each restores its tab and screen, and a title opens in a new window from its context menu or by middle click.
- **Only on Linux:** web video, the YouTube destination and Open Link (§14).
- **Not on Linux:** Top Shelf, widgets, the Live Activity and downloads. Downloads can follow later; the others have no Linux equivalent worth building.

## 7. Playback

### 7.1 The engine seam

`PlaybackSession` (stream resolution, resume, timeline reporting, transcode keep-alive and restarts, fallback, skip markers, Up Next, self-healing) lives in `CrucibleMedia`, 2,295 lines of which eleven of twelve files touch AVFoundation. It moves to `CruciblePlayback` behind a `PlaybackEngine` protocol: load an item (URL, headers, start position), play, pause, seek, rate, audio and subtitle tracks, a stream of time, state, buffering and errors, and the item's end. The Apple side moves first and is checked with the Apple TV UI tests, the iPhone shots and `scripts/mac.sh bench`; then `MPVPlaybackEngine` implements the same protocol and the bench's 26 episode-flow behaviours run against it headless.

### 7.2 What plays directly

On Linux `PlaybackCapabilities` says mpv decodes every container and codec, so direct play is the default and the server transcodes only for bandwidth (a remote or relay route) or a chosen quality. Every text and image subtitle renders on the client (libass, PGS), so nothing is burned in.

### 7.3 Video and HDR

**The path (decided in P0):** mpv's `gpu-next` renders each frame through a Vulkan render API into a Kiln-owned FP16 image on Kiln's device: PQ BT.2020 for HDR sources, so absolute luminance survives, and BT.709 for SDR. Kiln composites that image under the player chrome in linear light, so glass panels blur the live picture as tvOS 26 does, video can shrink into a card or play behind the hero, and the window stays one scRGB surface. The render API is the andrewrabert/mpv `gpu-next` series rebased onto mpv 0.42 and kept in `linux/vendor/mpv` (built with libplacebo 7.387 or newer, also vendored while Arch ships 7.360) until it is accepted upstream; the P0 spike showed it renders Dolby Vision 5 identical to mpv's own player, where upstream's `gl_video` path does not. Dolby Vision 7 enhancement layers come with it, since they are a `gpu-next` feature of 0.42.

**HDR metadata:** mastering primaries and luminance, MaxCLL and MaxFALL come from mpv's `video-params` and go into the surface's image description, never as zeros (§3).

**Hand-off:** mpv renders into the view's texture without the main thread waiting for the GPU (mpv patch 0013): the texture's timeline semaphore tells mpv when Kiln's last use of it is done, mpv signals the next value when its frame is drawn, and Kiln's composite waits for that value on the GPU. Taking the texture back waits on the CPU for Kiln's previous use, so the GPU never runs more than a frame behind and the decoder's last surface is free before the next is mapped. `kiln_video.c` refuses to build against an mpv without the patch, since its semaphore would never be signalled. A picture shown at half its size or smaller gets mpv's bilinear chroma upscaler instead of Lanczos (§3); one shown larger keeps Lanczos. While the transport is hidden the player hears the playhead four times a second instead of every frame, so each frame of video draws the window once, not twice. `KILN_MPV_OPTIONS='name=value;…'` sets mpv options for a trial on a device without a rebuild.

**Fallback:** if the vendored series cannot follow mpv for a release, mpv runs its own `gpu-next` Wayland output, made a subsurface below Kiln's surface by a Wayland proxy (the Jellium pattern), with mpv 0.42's own colour management; the chrome then sits in a sibling surface and glass over video becomes a translucent plate without live blur. Rejected as the main path because upstream's OpenGL render API (`gl_video`) gets Dolby Vision 5 wrong (§3).

### 7.4 Match Content

Match Content in Settings › Playback, on by default, enables it; each show or movie then starts with it off and is turned on for that one in the player's Picture or This Show menu or on its Playback Settings page (a rule of its own, §7.7; a show's episodes share it; the rows hide or grey out while the setting is off). For a title it is on for, it acts whenever the player is fullscreen, and only on the output showing it, and a title it is off for puts back what an earlier one changed: an HDR title switches that output to HDR with wide colour gamut through `kde_output_management_v2` (the devices come from `kde_output_device_registry_v2` on KWin 6.5 and later) and it goes back when playback ends or leaves full screen, the same rule as `hdr-game`. The state to go back to is written to `$XDG_STATE_HOME/crucible/display-prior.json` first and `crucible --display-guard` watches the player's process, so a crash or a kill still ends with the output restored, and a launch restores what a guard could not. Frame rates match where the mode exists at the current size, a whole number of refreshes a frame within 0.05%: 23.976 and 29.97 fps to 119.88 Hz, 25 and 50 fps to 100 Hz, 24.000 stays on 144 Hz (exactly six refreshes a frame) (`MatchContentPlan`). Compositors other than KWin get no switching and tone-map or clip on their own. In the Steam Deck's Game Mode the refresh is Steam's to set (§3): Steam's per-game Refresh Rate for Crucible at 72 Hz shows film without the uneven cadence 90 Hz gives it.

### 7.5 Player chrome

Rebuilt in Kiln from the tvOS 26 player Crucible uses today: title and transport bar with scrubbing thumbnails (Plex's index thumbnails), time left, glass Info, Audio, Subtitles and speed menus, contextual Skip Intro and Skip Credits from Core's markers, the Up Next card with Watch Credits and Play Now, post-play, the sleep timer, Still Watching and Rewind After a Break. The rules all come from Core (skip distances, hold actions, countdowns); only drawing is new. Inputs: Space and K play and pause, Left and Right skip by Core's distances, Up and Down open the info panel, triggers scrub.

**Scrub previews:** the scrubber shows the server's preview stills when it has made them for the file (`ScrubStillLoader`: the whole index in one download). A file without them (one just added, which the server is still working through; a library with video preview thumbnails off) has them made in the player (`LocalStillMaker`): a second mpv with no sound opens the file, stays paused, and seeks to the keyframe nearest each moment, decoding as the player does and drawing that one picture 320 pixels wide through the player's own renderer, so HDR and Dolby Vision look as they do playing. `LocalStillPlan` (in Core, with tests) orders the work: where the scrubber points first, then three slots either side of where it rests, then an overview of 48 stills spread over the whole title, begun when the viewer first moves the pointer over the player, so a jump anywhere shows a still from nearby while its own is made; a bar is at most 1,000 slots, with the overview and 96 others held. The pointer's still overtakes one nobody is looking at, the stills give way while the title itself seeks, and nothing on the window's thread waits for mpv or the GPU: seeks go without waiting (a waiting call froze the window 200 ms whenever mpv was itself waiting for a picture to be drawn), pictures from before a seek landed are let go undrawn (`VideoPlayer.skipFrame`), and a still is shown only once the GPU has finished it (`Texture.isVideoDrawn`). Measured headless on the desktop against Marcus's own server through one script of 30 hovers, a sweep, a drag and ten skips: on a 4K HEVC 25 Mb/s file from an NVMe drive the first still is there 140 ms after the pointer moves, each later one takes 24 ms (30 ms at the 90th percentile; 63 ms decoding in software), the title's own seeks stay where they are with the server's stills (41 against 37 ms) and no frame of the window takes over 40 ms; from a spinning disk that others are reading, a still takes what the disk does, 0.6 s on a 1080p file and 1.3 s on a 4K 30 Mb/s one. `CRUCIBLE_LOCAL_STILLS=1` makes them in the player whatever the server has.

**Scanning without a pointer** (`PlayerScan`): a held d-pad or arrow key, the gamepad's triggers and the wheel or a trackpad set to scroll move the playhead, its time and the preview still at the display's rate while the title holds paused and its picture follows by keyframe seeks (one on its way at a time; the still over the picture when this file seeks slowly), then seek exactly once when let go, playing on if it was playing. A held d-pad starts at 10 s a second and speeds up over three seconds to a fortieth of the title (at least a minute a second); a tap still skips the distance Settings give. Seeks never wait on mpv. On a Steam Deck OLED through Steam, scanning a 4K HDR10 film from the server drew 52 to 67 frames a second (12 to 14 ms between frames, against 41 ms for the 24 fps picture at rest) with no dropped video frames.

### 7.6 Audio

mpv with `ao=pipewire` (other outputs only when PipeWire is missing). Audio Passthrough in Settings › Playback (Automatic, Always, Never) feeds `audio-spdif`: Automatic with the codecs the default sink is set to accept (its `iec958Codecs` in `pw-dump`), Always with every one, which the sink is then set to accept, so TrueHD with Atmos, DTS-HD, E-AC-3 and AC-3 reach the receiver or TV as bitstreams; otherwise mpv decodes to multichannel PCM. PipeWire forgets a sink's enabled IEC958 codecs when it reconnects (PipeWire issue 3462), so when a play starts Crucible remembers the sink's own choice and sets it again with `pw-cli` when it finds the sink back on PCM alone. Headless runs pass `KILN_AO=null` and stay silent.

### 7.7 Skipping, per-title rules and the mouse

Settings › Playback › Skipping decides each kind of stretch on its own: Intros, Recaps, Credits, Previews and Commercials (a file's "ending" chapter counts as credits), each Show Button, Skip Automatically, After the First Episode or Off (`SkipSettings`; credits have no After the First Episode, and Skip Automatically for them means Up Next starts the next episode as they roll). A kind never set follows the shared Skip Intro or Skip Credits setting that decided every kind before. After the First Episode offers the button in the episode the viewer started and skips in the ones that play on from it (`PlayerRun.titlesBefore`). The decision itself is Core's `SkipDecision`, tested there.

A show or movie can keep its own rules over Settings (`TitlePlaybackRules` in Core, `TitleRulesStore` on Linux, key `player.titleRules`, keyed like the player's tweaks by server and the show's or movie's rating key, so a show's episodes share them): a mode per kind of stretch, Autoplay Next Episode on or off, and Match Content. Three places set them: the player's right-click menu (This Show, This Movie or This Title), a right click on the skip button for the stretch it offers (the choice takes effect at once, so choosing Skip Automatically skips the intro on screen), and the title's Playback Settings page (an action on show, movie and episode pages, and Settings › Playback › Shows & Movies, which lists every title with rules of its own, the last changed first). That page also shows what the player remembered for the title on its own, its volume and a show's audio and subtitle languages, each of which can be forgotten. Up Next takes the credits and autoplay rules through `UpNextResolver.creditsMode` and `autoplaysNext`. Settings changed while a player is open reach it (`TitleRulesStore.didChange`, `PlayerTweakStore.tasteChanged`). The shows Match Content was turned on for in 0.19.0 (`player.matchContentTitles`) are read in once; their names come from the server the first time the list opens.

Settings › Controls (the Linux name of the shared Skip Buttons and Remote category) holds the skip distances and hold actions under Keyboard, Hide Controls After (1.5, 2.5, 4 or 6 seconds; 1.5 on a desk and 2.5 on a couch until chosen), and in the Desktop layout the Mouse: what a click on the picture does (Play or Pause, Show or Hide Controls, Nothing), a double click (Full Screen or Nothing), the wheel (seek 5 or 10 seconds a notch, turn the volume, nothing) and a middle click (nothing, mute, play or pause, full screen), kept in `PlayerMouse`. Playback's Subtitles and Audio sections also hold the player's taste that its menus change (style, position, subtitles while muted, dialogue, Volume Boost) and Remember Volume for Each Show.

In the Desktop layout Settings is laid out for the mouse: a search field heads the categories (typing anywhere on Settings searches, Ctrl+F focuses it, Return goes to the first match) and its matches replace the page, grouped by category; each section is a card down the page's leading side; a choice of up to four short options is a segmented control clicked in place, a longer one a pop-up button whose options hang from it (`RowItem.choice`, `RowView` hit-tests the segments and the button); a right click on a row offers its options and Restore Default. Appearance's light or dark, layout and poster size are rows like any other. The Steam Deck layout keeps the Apple TV's rows, a value with a chevron that opens a menu.

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
| Keep the screen awake | `zwp_idle_inhibit_v1` on the window while playing, with `org.freedesktop.ScreenSaver.Inhibit` as fallback (gamescope lacks idle inhibit; in Game Mode Steam itself owns that name and honours it) |
| Find servers | Plex GDM over UDP (an `M-SEARCH` to the multicast group 239.0.0.250 and the broadcast address on port 32414; 32412 is where players answer, not servers) beside plex.tv resources and the tailnet routes Core already probes, and on their own when plex.tv cannot be reached |
| `crucible://` links and one instance | A desktop entry with `MimeType=x-scheme-handler/crucible;` and the D-Bus name `org.guitaripod.Crucible`, which hands a second launch's link to the running app and Core's deep-link parser |
| Notifications | `org.freedesktop.Notifications` for `LibraryNews` while the app runs; a systemd user timer for background refresh can follow |
| Output HDR and refresh rate | `kde_output_management_v2` (§7.4) |
| Steam Deck layout | `crucible --steam-deck` as a non-Steam shortcut for Big Picture and Game Mode: `linux/scripts/steam-library.py` adds it to the running Steam with its library artwork (§9.1); `linux/scripts/steam-shortcut.py` does it with Steam closed on a desktop, picking Steam Input's own gamepad templates (gamepad and trackpad mouse on the Steam Deck and DualSense, gamepad elsewhere) |
| Clean exit | SIGTERM, SIGINT and SIGHUP save resume positions and send the stopped timeline before exiting (the Tailscode lesson that an unhandled SIGTERM counts as a crash); the position is also kept on the machine as playback goes (`PlaybackResumeStore`), so a crash, a logout or a power cut loses nothing: the next launch hands the server what its last report did not carry |

### 9.1 Steam Deck

Crucible runs in the Deck's Game Mode in the Steam Deck layout: the tvOS canvas at two thirds on the 1280 x 800 screen
(grown to 1920 x 1200 points), launched from Steam's library.

| Part | How |
| --- | --- |
| Build | SteamOS trails Arch (FFmpeg 8 where Arch has 9), so `linux/scripts/steamdeck.sh build` builds in a container made from SteamOS's own repositories (`linux/packaging/steamos`), with the vendored libmpv and libplacebo built against them; `install [HOST]` builds and installs on the Deck over SSH (`deck@steamdeck` by default) into `~/.local`, and refuses an install whose libraries the Deck lacks |
| Library | `linux/scripts/steam-library.py` adds the shortcut to the running Steam through its debugger port (no restart, so Game Mode is never interrupted) with the capsule, wide capsule, hero and logo of `linux/packaging/steamos/steam-art` (drawn by `make-steam-art.py` from the Apple TV icon's layers); `--run`, `--quit` and `--status` drive it |
| Window | Under gamescope Kiln opens an X11 window (`X11Window`, `CKiln/kiln_x11.c`) carrying the Steam app ID (`STEAM_GAME`), since Steam never focuses a Wayland toplevel there; gamescope's WSI layer takes its Vulkan swapchain straight to the compositor. X11 has no frame callbacks, so the swapchain presents FIFO at the RandR refresh (90 Hz on the OLED); `KILN_BACKEND=x11|wayland` overrides the choice |
| Colour | gamescope's colour state is read from its root XWayland server and followed as Steam changes it: on an HDR output the window draws SDR while nothing HDR shows, so gamescope keeps the panel in SDR and the menus are as bright as Steam's (in HDR mode gamescope shows SDR content at Steam's SDR content brightness, 203 cd/m², which made them look dim), and switches to scRGB while an HDR video plays, its light scaled so Kiln's 203 cd/m² white lands on Steam's SDR white under the slider's gains and the panel's peak stays for the picture; on an SDR output the window draws SDR |
| Input | Steam Input's virtual pad through SDL (polled at 60 Hz while in use and 20 Hz while idle), the trackpad as the pointer, and the touchscreen through XInput 2: a tap clicks, a drag scrolls with the touchpad's momentum |
| Sign-in | The browser does not open by itself in Game Mode, where it would cover Crucible; the code and QR code serve a phone, and Open plex.tv still opens the Deck's browser |
| Measure | `linux/scripts/steamdeck-bench.py ui|play|compare` on the Deck launches through Steam on a throwaway profile signed in to the bundled demo, scripts a launch, a resting Home and a browse, or plays a file, and samples CPU, memory, GPU and video decoder time (amdgpu `fdinfo`), APU power (`amdgpu` hwmon), GPU load and the bytes received beside Kiln's per-frame timings (`KILN_FRAMES`). `--signed-in` starts the profile from a copy of the Deck's own (its account, settings, Home snapshot and statistics) with an empty image cache, and `play --item RATINGKEY` plays a title from the server through the app and puts its watch state on the server back afterwards; Plex tokens are cut out of everything a run writes |

Measured on a Steam Deck OLED (SteamOS 3.9.5, 90 Hz, HDR on), warm launch, before (0.16.8) and after (0.17.0). 0.16.8 cannot show
in Game Mode at all, so its interface numbers come from forcing it onto gamescope's Wayland socket, where it draws unseen;
its playback numbers come from 0.16.8 with only the X11 window added.

| | 0.16.8 | 0.17.0 |
| --- | --- | --- |
| Launch, first 16 s: process CPU, APU power | 16.1 s, 8.1 W | 1.3 s, 2.9 W |
| Resting on Home: process CPU, APU power | 108%, 9.1 W | 2%, 3.0 W |
| Browsing (shelves, a title page, a library grid): process CPU, APU power | 95%, 8.6 W | 23%, 4.6 W |
| Browsing: frames late at 90 Hz, 99th percentile frame interval | 1.9%, 22.2 ms | 0.7%, 15.6 ms |
| 720p H.264: process CPU, APU power | 16.5%, 4.2 W | 10.7%, 4.2 W |
| 1080p H.264 at 10 Mb/s: process CPU, APU power | 21.4%, 4.3 W | 11.0%, 4.5 W |
| 4K HEVC 10-bit HDR10 at 25 Mb/s: process CPU, APU power, resident memory | 51%, 5.9 W, 639 MB | 12%, 5.5 W, 493 MB |

What moved them: the URLSession spin (both machines), a main loop that slept in 16 ms turns, an idle pad polled at 60 Hz,
ambient animations (spinner, skeletons, the welcome crystal) drawing the whole scene at the display's rate, lifted text
re-rasterised on nearly every frame of a spring, a glass luminance readback with its own submit every other frame, VA-API
copying every decoded frame, and memory-pressure purges set off by other programs' stalls. The artwork disk cache now
stops at 512 MB (the Deck's disk is small and shared with games).

Then signed in to a real server over Wi-Fi 6E (2026-11-16), `steamdeck-bench.py --signed-in` and `play --item`, direct play
throughout, before and after the playback hand-off, the chroma rule and the paced playhead reports (§7.3). Browsing the
real library (87 movies, 36 shows, 134 game cinematics) was already where the demo left it and stayed there: 1.4 s of CPU
to launch, 21% CPU and 4.2 W browsing, 1.1% of frames late, pages filled about 0.1 s after the press.

| Title (as stored on the server) | Before | After |
| --- | --- | --- |
| 4K HEVC HDR10 + Dolby Vision 8, TrueHD 7.1, 30 Mb/s: CPU, APU power, GPU, main thread per frame, frames drawn | 19.9%, 5.18 W, 28%, 8.9 ms, 46/s | 17.5%, 4.74 W, 19%, 3.2 ms, 27/s |
| 4K HEVC HDR10, DTS-HD 7.1, 25 Mb/s: CPU, APU power, GPU | 17.4%, 5.00 W, 27% | 15.3%, 4.56 W, 15% |
| 1080p VC-1, TrueHD 5.1, 30 Mb/s: CPU, APU power, GPU, main thread per frame | 17.2%, 4.75 W, 19%, 13 ms | 14.8%, 4.52 W, 14%, 3.1 ms |
| 1080p H.264, DTS 5.1, 15 Mb/s: CPU, APU power, GPU | 17.7%, 4.38 W, 18% | 15.8%, 3.94 W, 14% |
| 4K 60 fps AV1: frames shown, GPU, main thread per frame | 41/s, 43%, 10.9 ms | 59/s, 30%, 3.2 ms |
| 4K 60 fps VP9: frames shown, GPU | 48/s, 50% | 59/s, 31% |
| 1080p 60 fps H.264: CPU, frames drawn | 24.2%, 78/s | 21.9%, 64/s |
| 8K AV1 at 24 fps (the decoder is 83% busy either way): frames shown, APU power | 20/s, 6.9 W | 24/s, 6.0 W |

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
| A site changes and web video stops playing | Crucible carries no site's protocol: yt-dlp is the viewer's own, found on `PATH`, and updating it is the fix. A refused stream falls to the next best one, and Settings › Web Video shows the yt-dlp in use (§14) |
| Web video reaching a store build, where a site's terms and the stores' rules forbid it | Its code is in Linux-only targets, its words in `Web.xcstrings`, which no Apple project lists; the Apple apps have no web video and are not meant to get any (§14.1) |

## 14. Web video

The Linux client is free and open, so it can do what mpv and yt-dlp have long done on a desktop: play a site's video in a proper player. YouTube is a destination in the sidebar and the tab bar; any other link plays through Open Link. Playing a site's video outside its own player is against most sites' terms, YouTube's among them, which is why this stays a Linux feature of a free client and is said plainly in Settings where an account comes into it.

### 14.1 Where it lives

| Piece | Where | What it holds |
| --- | --- | --- |
| `CrucibleWeb` | `linux/Sources/CrucibleWeb`, a Linux-only library with no UI | The yt-dlp runner, what yt-dlp says of a video or a list, the stream picker, a channel's feed, SponsorBlock, links, the viewer's library and its imports |
| Screens | `linux/Sources/CrucibleApp/Web` | The YouTube destination, its notifications inbox, a channel's page, lists, card menus, Open Link, Settings › Web Video, `WebService` (yt-dlp's answers kept, the subscriptions feed, captions) |
| Player | `PlayerScreen+Web.swift` | The web source: it hands the player the same `ResolvedStream` a Plex title has, so chapters, skips, menus, Stream Info and Match Content need no second implementation |
| Words | `linux/Sources/CrucibleApp/Resources/Web.xcstrings` | Every string of the above in the sixteen languages, loaded after `Localizable.xcstrings` (`LocalizationCatalog.add`). The shared catalog, which the Apple apps ship, carries none of them |

Nothing here is declared outside `linuxClient()` in `Package.swift`, and `Sources/` gained one Linux-only function (`LocalizationCatalog.add`).

### 14.2 Facts that shape it

| Fact | Source | Consequence |
| --- | --- | --- |
| One `yt-dlp -J` run takes about 2.3 s for a YouTube video, 0.5 s of it Python starting | Measured on arch, yt-dlp 2026.11.16 | One run per video, shared by every asker and kept 90 minutes (`WebService.video`); at most three runs at once (`YtDlpGate`); lists and feeds never open each video |
| YouTube refuses some single-file streams for about four seconds after they were read (`available_at`); its segmented streams are served at once | Measured: HTTP 403 until then on one of two test videos | The picker ranks a stream that is ready before one that is held back, so playback starts with the segmented picture when the single file would mean waiting, and waits only when nothing else has the quality |
| A site hands out the same picture in more than one way | yt-dlp lists both families | A stream that fails is left out and the next best plays (`WebSession.failed`); only then is yt-dlp asked again |
| YouTube's WebVTT of automatic captions repeats every line as the words arrive; its SRT shows each line once; machine-translated captions answer 429 without an account | Measured | SRT first; automatic captions are offered only in the video's own language. Caption files are fetched into the cache and added from there, so mpv's command never waits on the network |
| A channel's newest uploads are public at `youtube.com/feeds/videos.xml?channel_id=` and mark Shorts by their link | The feed itself | The subscriptions row is a hundred small requests, sixteen at a time, and no yt-dlp run; Shorts are told from videos without opening one, and go to a shelf and a player of their own (§14.7) |
| yt-dlp's wiki puts a guest at about 300 videos an hour and warns that an account used with it can be restricted or closed | yt-dlp wiki, Extractors | Nothing is fetched per card. Signing in is off by default, optional, through the browser's cookies, and the warning is shown before it turns on |
| yt-dlp rounds frame rates (59.94 reads as 60) | Its JSON | Match Content engages on the site's rate, then again on the rate mpv measures once the file is open |

### 14.3 Playback

`WebFormatPicker` chooses as a web player's automatic quality would for a home screen: the tallest picture within the viewer's limit, the higher frame rate, HDR only on a screen that shows it, AV1 before VP9 before H.264, the original language, surround only when the sound output takes it (passthrough is set). A picture and a sound that come apart are joined for mpv as one title with an `edl://` address, as mpv's own yt-dlp hook does. The player's menu gains Quality, which ends in Sound Only (no picture is fetched, the thumbnail stands in, and the picture's view is hidden, since mpv takes its video output down for a file without a picture and crashes when asked to draw then); Audio lists the languages a video is dubbed in; Subtitles lists the publisher's tracks and the automatic one in the video's language. mpv reports the file it puts aside for another quality or language as ended, so the player ignores an end that comes between handing mpv a file and that file opening (`WebSession.isReplacing`).

SponsorBlock is asked by the first four characters of the video ID's SHA-256, so it never learns which video is watched. Its stretches become the player's skip markers: skipped once on their own with Undo by default, offered as a button, or off (Settings). Scrub previews are cut from the site's storyboard sheets, a still uploaded straight from its rows of a sheet.

### 14.4 The viewer's library

Followed channels, Watch Later, progress, downloads and what the inbox has read and muted are one file, `web/library.json` in the app's data folder, written a moment after each change and before quitting. Lookups of a video's progress go through an index kept beside the history rather than walking three thousand watches for every card, and the index is rebuilt only when the history changes. No site hears of any of it. A video's page (View Details) shows its description, its chapters and the top of its comments, which yt-dlp reads in a second, slower run. Download saves a video as one Matroska file with its chapters and the publisher's subtitles into `Crucible` in the viewer's Videos folder, within the quality set in Settings; a downloaded video plays from its file and keeps its place like any other. Subscriptions come in from Google Takeout, OPML, NewPipe, FreeTube and Invidious, and go out as OPML. With a browser's cookies set, the account's recommendations, Watch Later and liked videos become rows and chips, its channels can be followed in one step, and a finished video can be noted in its history.

### 14.5 What leaves the machine

| To | What | When |
| --- | --- | --- |
| The site (through yt-dlp) | The video, list or search asked for | On opening one. Search's words go to YouTube only when the viewer chooses Search YouTube |
| `youtube.com/feeds` | A followed channel's ID | When the subscriptions feed is read, at most every fifteen minutes |
| `www.youtube.com/youtubei/v1/notification/get_notification_menu` | The browser's YouTube cookies, and a request for the account's own notification menu | Only when a browser is signed in in Settings, at most every ten minutes. yt-dlp writes the cookies into a private file, which is read and deleted; the notes stay on this machine |
| The site's image hosts | Thumbnail and storyboard addresses | As cards and the scrubber draw them. `WebArtwork` marks these addresses and fetches them apart from the server's artwork, so the Plex headers never go with them, whatever their host or path |
| SponsorBlock | Four characters of a hash | Per video, unless Sponsor Segments is off |

### 14.6 Testing

`CrucibleWebTests` (50 tests) reads fixtures cut from real yt-dlp answers with every stream address replaced, since those carry the address of the machine that asked. `CRUCIBLE_PLAY_LINK=<address>` plays one link in a bare player for headless checks, and `linux/scripts/mock-session.sh` shows the destination beside the mock library. With `CRUCIBLE_OPEN_LINK=https://www.youtube.com/shorts/<id>` the mock session opens the Shorts player, which `--capture` then drives with keys, the pointer, the wheel and the virtual gamepad.

### 14.7 Shorts

Shorts never mix into the rows of videos. The YouTube page keeps the followed channels' on a shelf of upright cards, those not yet watched first (Settings › Web Video › Hide Shorts takes the shelf away), a channel's page has them under its Shorts chip, and a link to one opens it; each of these opens the Shorts player (`Web/Shorts`), a feed of upright pages over the whole window, in both layouts.

| Part | How |
| --- | --- |
| The feed | The clips of the shelf or the tab it was opened from, starting with the one picked. A clip opened alone (a link, a search result, History) is followed by its channel's other Shorts, read once yt-dlp has named the channel |
| Players | At most three (`WebShortSlot`): the clip playing, the next one opened and held at its first frame so moving on shows it at once, and the one just left. A clip landed on without being held ready is opened a third of a second later, so skimming asks yt-dlp for none of the clips passed; the next is opened only once the playing one is. A guest's allowance on the site (§14.2) is one run a clip |
| The picture | The smallest of the clip's pictures that fills the pane (`WebShorts.heightLimit`): a clip filmed in 4K plays at 1080 by 1920 in a pane 1,024 pixels tall and at 720 by 1280 on a Steam Deck. Never HDR; a stream the site refuses gives way to the next best, then yt-dlp is asked once more |
| The page | The clip's own upright picture until its first frame (`oardefault`, `sardefault` or `oar2`, whichever the site has), its channel with Follow, title, likes, views and age over its foot, the playhead along the lower edge, and the same picture blurred across the window behind it. A wide clip lies across its dimmed picture |
| Moving | Pages spring into place and the neighbours peek in above and below. `WebShortsPager` (tested) turns the wheel into one clip a notch with a pause between steps, and a touchpad's fingers or a drag into a pull that moves on when it went a fifth of a page or was flicked, and gives at the feed's ends |
| Sound | Every clip goes through `dynaudnorm` aiming its peaks at 0.85 over about a second either side, then a limiter run at 192 kHz holding them at 0.87, so true peaks stay just under -1 dBTP. On four NileRed Shorts that spanned -16.2 to -23.6 LUFS (true peaks up to +2.4 dBTP) this gives -15.1 to -17.3 LUFS and -1.2 to -1.4 dBTP for 0.6 s of CPU per 71 s clip |
| Smoothness | The players' mpv calls never wait on mpv (`VideoPlayer.loadLater`, `setLater`, `commandLater`); a picture is rendered at its page's size at rest, so the page scaling as it moves does not reallocate it or hold back mpv's frames; a clip's first frame (15 to 30 ms of mpv's time) waits until the feed stops moving, its thumbnail standing in; the third player is made while the feed rests; the window's wash reuses three blur passes. Wheeling through ten clips headless at 1920 x 1080: frames over 12 ms from 36 to 13, the 99th percentile from 33.5 to 12 ms |
| What is kept | A clip watched most of the way is noted finished in the viewer's own history, which is what puts it behind the unwatched ones on the shelf. The Shorts player has its own volume, mute and speed |

| Input | Does |
| --- | --- |
| Wheel, two-finger swipe, drag of the clip, click above or below it, Up and Down, Page Up and Page Down, P and N, the d-pad or stick, the shoulder buttons | Previous or next clip |
| Click, Space, K, Enter, A | Pause or play (the clip that failed: try again) |
| Double click, F | Full screen |
| Drag along the playhead, J and L, Left and Right in the Desktop layout, the triggers | Move through the clip |
| Right in the Steam Deck layout, Tab | Reach the rail: Watch Later (S), Description and Comments (C or I), Copy Link (Ctrl+C), the channel (O), the sound (M, Shift with Up and Down, the wheel over its button), the speed, Auto Scroll, More. A window too short for all eight leaves out the channel, then Copy Link, then the speed, which the page and the menu still offer |
| Click the channel's picture or name | The channel's page |
| Click the title, the facts or the comments line ("2.3K comments"), C or I, X on a gamepad | The description and comments sheet; it opens with the player again where the window has room for it. The comments are read as the pointer reaches the line or the Comments button, so the sheet usually opens on them |
| Hold the mouse button on the clip | Twice the set speed until it is let go |
| A, the rail's Auto button | Auto Scroll: off, after each play, after two plays; a right click on the button or the menu chooses directly. Off, a clip repeats |
| [ and ], the wheel over the rail's speed button, Backspace | Speed down and up through 0.5x to 3x, kept between sittings; Backspace goes back to 1x. A click on the button lists the speeds |
| 0 to 9 | Jump to that tenth of the clip |
| Right click, the Menu key, Y | The clip's menu: Open in the Player (quality, subtitles and speed, from where the clip is), Auto Scroll (A), Playback Speed, Download, Follow, Open in Browser |
| Escape, B, the mouse's back button | Close the details sheet, then leave the rail, then go back |

The details sheet reads the comments in a second yt-dlp run, begun once a clip has stayed over half a second, and is scrolled by the wheel or, with the keyboard or a gamepad on it, the arrows.

### 14.8 Notifications

The YouTube page's bell opens the inbox. New videos of every followed channel come from the public feeds; when a browser's cookies are set in Settings › Web Video, the account's own notification menu adds the replies, mentions and likes on the viewer's comments, and the live streams the feeds cannot mark. The menu is read with yt-dlp's own cookie export, a `SAPISIDHASH` request to YouTube, and nothing written back; without a browser signed in the screen says so and offers Sign In for Comments.

Each card shows the picture, the channel's face and name, the title on three lines and the facts under it, a Shorts or LIVE badge where it applies, and, on a comment, the sentence that happened. Unread cards carry the accent bar and a heavier title; watched ones dim their picture and say so. The pointer brings four actions out over the picture — Play, or Open Comments on a reply; Mark as Read; Watch Later; Mute the channel — with the keys Enter, M, S and B doing the same on the focused card. A right click has the whole web menu with the inbox's two additions.

The cards flow into as many columns as the window has room for — three at 1,600 points, four on a wide desk, two at the couch's size and two when the window narrows — under day headings. Only sixty are made at a time, so a thousand arrivals open as quickly as ten; Show More brings the next sixty, puts the focus on the first of them and says how many are left. The chips filter All, Videos, Shorts, Comments and Unread, choose one channel (with the muted ones under the channels, which restore from the same menu), mark everything read, or read the feeds again.

What was read and muted, and the notes themselves, stay in `web/library.json`; watching a video reads its notification, read ids beyond four thousand are forgotten, and videos older than sixty days leave the inbox whether or not they were read. The unread count sits on the YouTube tab and, on a desk, in the sidebar, and the YouTube page carries it in its Notifications chip; it is kept until the feed, the notes, a mute or a read changes, so a video’s progress does not sort the inbox again every ten seconds. A page of sixty cards is the only work opening the inbox does, and a feed is parsed with one date formatter rather than one for each of its fifteen entries. `WebService` reads the feeds and the account's menu every ten minutes while the app runs, so the badge is current without opening the page.
