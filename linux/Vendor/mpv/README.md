# Vendored mpv

Crucible for Linux plays through libmpv's `gpu-next` renderer drawing into Kiln's Vulkan images. Upstream libmpv's render API only offers the older `gl_video` renderer, which gets Dolby Vision 5 wrong, so this folder carries a patch series on mpv and libplacebo until it is accepted upstream.

- `VERSIONS`: the mpv tag, the libplacebo commit and the Vulkan-Headers commit the patches apply to.
- `patches/mpv`: 0001 to 0009 are the `gpu-next` render backend from andrewrabert/mpv (`feat/libplacebo-swapchain`), rebased onto 0.42.0; 0010 loads mpv's hardware decode interop in that backend.
- `patches/libplacebo`: `pl_vulkan_import` reports the host's device extensions.

`../../scripts/build-mpv.sh` clones, patches and builds libmpv into `.build/mpv` (about 35 s). To move to a new mpv release: rebase the series, rerun `Spikes/vulkan-video` on HDR10 patches and Dolby Vision 5, 8.1 and 7 clips (`scripts/make-test-media.sh`), and compare against mpv's own `gpu-next`.
