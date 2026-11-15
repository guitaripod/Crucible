# Crucible for Linux

The Linux client: a Swift package beside the Apple apps, sharing CrucibleCore. Design and plan: `../docs/LINUX.md`.

Today it holds Kiln's foundation and the P0 spikes:

- `Kiln`: the Wayland window (`CKiln`), the GPU layer on libplacebo and Vulkan (`CKilnGPU`, `Render/GPU.swift`), the event loop that runs the main actor, and Liquid Glass.
- `kiln-spike`: an FP16 scRGB window on KWin with a Liquid Glass tab bar over a moving HDR scene; prints GPU and presentation timings and writes readbacks.
- `Spikes/vulkan-video`: libmpv's `gpu-next` Vulkan render API on a Kiln-style device, with zero-copy decode.

```bash
scripts/build-mpv.sh                            # libmpv and libplacebo from Vendor/mpv into .build/mpv (once, about 35 s)
export PKG_CONFIG_PATH=$PWD/.build/mpv/lib/pkgconfig LD_LIBRARY_PATH=$PWD/.build/mpv/lib
swift build
scripts/make-test-media.sh                      # HDR10 patches and a Dolby Vision 5 clip (needs ffmpeg with libx265 and dovi_tool)
scripts/headless.sh .build/debug/kiln-spike --frames 300   # a private headless KWin, 3840x2160 unless KILN_WIDTH/KILN_HEIGHT say otherwise
```

`scripts/gen-protocols.sh` regenerates the Wayland protocol code in `Sources/CKiln/protocols` from `Protocols/*.xml` (wayland-protocols and plasma-wayland-protocols, as vendored in their Rust crates 0.32.13 and 0.3.12).
