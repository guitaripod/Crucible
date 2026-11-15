# Crucible for Linux

The Linux client's sources. Its targets are declared in the repository's root `Package.swift` (on Linux only), so they
reach CrucibleCore's package-level API. Design and plan: `../docs/LINUX.md`.

- `Kiln`: the UI engine. The Wayland window (`CKiln`, with xkbcommon keys and touchpad scroll frames), the GPU layer on
  libplacebo and Vulkan (`CKilnGPU`), Pango text (`CKilnText`), JPEG, PNG, WebP and SVG decoding (`CKilnImage`), views,
  focus, animation, scrolling and Liquid Glass.
- `CrucibleUI`: the Apple TV design system on Kiln: tokens, cards, shelves, grids, backdrop, hero, buttons, chips, the
  glass tab bar, rows and states.
- `crucible-gallery`: every component with fixture content, in a window (keys 1 to 5 switch pages) or captured to PNG.
- `kiln-spike`: the P0 spike, an FP16 scRGB window with a glass tab bar over a moving HDR scene, printing timings.
- `Spikes/vulkan-video`: libmpv's `gpu-next` Vulkan render API on a Kiln-style device, with zero-copy decode.

From the repository root:

```bash
linux/scripts/build-mpv.sh                      # libmpv and libplacebo from linux/Vendor/mpv into linux/.build/mpv (once, about 35 s)
export PKG_CONFIG_PATH=$PWD/linux/.build/mpv/lib/pkgconfig LD_LIBRARY_PATH=$PWD/linux/.build/mpv/lib
swift build --product crucible-gallery
swift test --filter 'KilnTests|CrucibleUITests'  # needs a Vulkan GPU; CRUCIBLE_CORE_ONLY=1 swift test runs Core alone, as CI does
.build/debug/crucible-gallery --capture /tmp/gallery --size 1600x900 --scale 1.5
.build/debug/crucible-gallery --bench --size 1920x1080 --scale 2
linux/scripts/make-test-media.sh                # HDR10 patches and a Dolby Vision 5 clip (needs ffmpeg with libx265 and dovi_tool)
linux/scripts/headless.sh .build/debug/kiln-spike --frames 300   # a private headless KWin, 3840x2160 unless KILN_WIDTH/KILN_HEIGHT say otherwise
```

`linux/scripts/gen-protocols.sh` regenerates the Wayland protocol code in `Sources/CKiln/protocols` from `Protocols/*.xml`
(wayland-protocols and plasma-wayland-protocols, as vendored in their Rust crates 0.32.13 and 0.3.12).
