# Vulkan video spike

A Kiln-style Vulkan device (one graphics queue, libplacebo's recommended extensions, external memory and Vulkan Video decode) hands a half-float `VkImage` to libmpv's `gpu-next` Vulkan render API (the andrewrabert/mpv `feat/libplacebo-swapchain` series) and samples the PQ result.

```bash
MPV=/path/to/patched/mpv/install
cc -O2 -std=gnu11 -I/path/to/Vulkan-Headers/include -I$MPV/include main.c -o kiln-vulkan-video-spike \
   -L$MPV/lib -Wl,-rpath,$MPV/lib -lmpv -lplacebo -lvulkan -lm
HWDEC=vulkan SPIKE_OUT=/tmp ./kiln-vulkan-video-spike hdr10-patches.mkv p5.hevc
```

`MPV_LOG=1` prints decoder and interop messages.
