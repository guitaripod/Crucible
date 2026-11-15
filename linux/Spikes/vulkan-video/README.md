# Vulkan video spike

A Kiln-style Vulkan device (one graphics queue, libplacebo's recommended extensions, external memory and Vulkan Video decode) hands a half-float `VkImage` to libmpv's `gpu-next` Vulkan render API (the vendored series in `../../Vendor/mpv`) and samples the PQ result.

```bash
../../scripts/build-mpv.sh
MPV=../../.build/mpv; SRC=../../.build/mpv-src
cc -O2 -std=gnu11 -I$SRC/vulkan-headers/include -I$MPV/include -I$SRC/mpv/subprojects/libplacebo/src/include \
   -I$SRC/mpv/build/subprojects/libplacebo/src/include main.c -o kiln-vulkan-video-spike \
   -L$MPV/lib -Wl,-rpath,$MPV/lib -lmpv -L$SRC/mpv/build/subprojects/libplacebo/src -lplacebo -lvulkan -lm
HWDEC=vulkan SPIKE_OUT=/tmp ./kiln-vulkan-video-spike hdr10-patches.mkv p5.hevc
```

`MPV_LOG=1` prints decoder and interop messages.
