# Crucible for Linux

The Linux client's sources. Its targets are declared in the repository's root `Package.swift` (on Linux only), so they
reach CrucibleCore's package-level API. Design and plan: `../docs/LINUX.md`.

- `Kiln`: the UI engine. The Wayland window (`CKiln`, with xkbcommon keys and touchpad scroll frames), the GPU layer on
  libplacebo and Vulkan (`CKilnGPU`), Pango text (`CKilnText`), JPEG, PNG, WebP and SVG decoding (`CKilnImage`), views,
  focus, animation, scrolling and Liquid Glass.
- `CrucibleUI`: the Apple TV design system on Kiln: tokens, cards, shelves, grids, backdrop, hero, buttons, chips, the
  glass tab bar, rows and states.
- `crucible`: the app. Sign-in through plex.tv in the browser (code and QR code for another device), server choice,
  Home, the libraries, title pages, Search, You and the player (libmpv's gpu-next on Kiln's Vulkan device).
  `linux/scripts/install.sh` builds it in release with a static Swift runtime and installs it to `~/.local/lib/crucible`
  with `~/.local/bin/crucible`, a desktop entry and the icon.
- `crucible-gallery`: every component with fixture content, in a window (keys 1 to 5 switch pages) or captured to PNG.
- `kiln-spike`: the P0 spike, an FP16 scRGB window with a glass tab bar over a moving HDR scene, printing timings.
- `Spikes/vulkan-video`: libmpv's `gpu-next` Vulkan render API on a Kiln-style device, with zero-copy decode.

From the repository root:

```bash
linux/scripts/build-mpv.sh                      # libmpv and libplacebo from linux/Vendor/mpv into linux/.build/mpv (once, about 35 s)
export PKG_CONFIG_PATH=$PWD/linux/.build/mpv/lib/pkgconfig LD_LIBRARY_PATH=$PWD/linux/.build/mpv/lib
swift build --product crucible-gallery
linux/scripts/test.sh --filter 'KilnTests|CrucibleUITests'  # needs a Vulkan GPU; with no filter it runs Core too, its defaults kept out of ~/.config
.build/debug/crucible-gallery --capture /tmp/gallery --size 1600x900 --scale 1.5
.build/debug/crucible-gallery --bench --size 1920x1080 --scale 2
linux/scripts/make-test-media.sh                # HDR10 patches and a Dolby Vision 5 clip (needs ffmpeg with libx265 and dovi_tool)
linux/scripts/headless.sh .build/debug/kiln-spike --frames 300   # a private headless KWin, 3840x2160 unless KILN_WIDTH/KILN_HEIGHT say otherwise
```

Frame timing: `KILN_TRACE=/path/trace.txt crucible` writes a line per second of drawing and per burst of frames (CPU per
phase, GPU, compositor waits, input latency, and the text, symbols, textures and passes behind any frame over 12 ms), and
Ctrl+Shift+P shows the last second in a HUD. `KILN_PRESENT=fifo` swaps the mailbox swapchain for FIFO to compare, and
`KILN_PL_DEBUG=1` or `KILN_PL_TRACE=1` turn on libplacebo's debug or trace log (the trace names every GPU wait).

`linux/scripts/gen-protocols.sh` regenerates the Wayland protocol code in `Sources/CKiln/protocols` from `Protocols/*.xml`
(wayland-protocols and plasma-wayland-protocols, as vendored in their Rust crates 0.32.13 and 0.3.12).
