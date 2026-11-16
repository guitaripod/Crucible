#ifndef KILN_GPU_INTERNAL_H
#define KILN_GPU_INTERNAL_H

#include <vulkan/vulkan.h>
#include <libplacebo/dispatch.h>
#include <libplacebo/renderer.h>
#include <libplacebo/swapchain.h>
#include <libplacebo/vulkan.h>
#include <libplacebo/cache.h>

#define KILN_MAX_TIMERS 1024
#define KILN_VERTEX_FRAMES 4
#define KILN_VERTEX_BYTES (4u << 20)

struct kiln_tex {
    pl_tex tex;
    VkImageView view;
    VkSemaphore semaphore;
    uint64_t semaphore_value;
};

struct kiln_gpu {
    pl_log log;
    pl_vk_inst instance;
    VkSurfaceKHR surface;
    pl_vulkan vulkan;
    pl_gpu gpu;
    pl_swapchain swapchain;
    pl_dispatch dispatch;
    pl_renderer renderer;
    pl_timer timers[KILN_MAX_TIMERS];
    int timer_count;
    int pass_index;
    double pending_ms;
    VkQueue graphics_queue;
    pl_cache shader_cache;
    char *shader_cache_path;
    int shader_cache_objects;
    pl_buf vertex_bufs[KILN_VERTEX_FRAMES];
    int vertex_frame;
    size_t vertex_used;
    bool vertex_ready;
    float output_gain;
    bool sdr_output;
};

#endif
