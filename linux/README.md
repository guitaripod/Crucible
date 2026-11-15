# Crucible for Linux

The Linux client: a Swift package beside the Apple apps, sharing CrucibleCore. Design and plan: `../docs/LINUX.md`.

Today it holds Kiln's P0 spikes:

- `kiln-spike`: an FP16 scRGB window on KWin with a Liquid Glass tab bar over a moving HDR scene; prints GPU and presentation timings and writes readbacks.
- `kiln-video-spike`: renders clips through libmpv into a half-float Kiln target as PQ BT.2020, samples known points and writes previews. `MPV_RENDER_BACKEND=gpu-next` selects the `gpu-next` render backend of a patched libmpv on `LD_LIBRARY_PATH`.

```bash
swift build
scripts/make-test-media.sh                      # HDR10 patches and a Dolby Vision 5 clip (needs ffmpeg with libx265 and dovi_tool)
scripts/headless.sh .build/debug/kiln-spike --frames 300   # a private headless KWin, 3840x2160 unless KILN_WIDTH/KILN_HEIGHT say otherwise
.build/debug/kiln-video-spike /path/to/hdr10-patches.mkv
```

`scripts/gen-protocols.sh` regenerates the Wayland protocol code in `Sources/CKiln/protocols` from `Protocols/*.xml` (wayland-protocols and plasma-wayland-protocols, as vendored in their Rust crates 0.32.13 and 0.3.12).
