#ifndef KILN_GPU_INTERNAL_H
#define KILN_GPU_INTERNAL_H

#include <vulkan/vulkan.h>
#include <libplacebo/dispatch.h>
#include <libplacebo/renderer.h>
#include <libplacebo/swapchain.h>
#include <libplacebo/vulkan.h>

#define KILN_MAX_TIMERS 64

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
};

#endif
