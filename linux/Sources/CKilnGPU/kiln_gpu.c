#include "kiln_gpu.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <wayland-client.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_wayland.h>
#include <libplacebo/dispatch.h>
#include <libplacebo/log.h>
#include <libplacebo/renderer.h>
#include <libplacebo/shaders/custom.h>
#include <libplacebo/swapchain.h>
#include <libplacebo/vulkan.h>

#include "kiln_gpu_internal.h"

static void fail(char *error, size_t size, const char *message) {
    if (error && size) snprintf(error, size, "%s", message);
}

/** The optional extensions and features mpv requests so FFmpeg's Vulkan hwcontext can decode (video/out/vulkan/context.c). */
static const char *const optional_extensions[] = {
    VK_EXT_SHADER_ATOMIC_FLOAT_EXTENSION_NAME,
    VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
    VK_KHR_VIDEO_DECODE_AV1_EXTENSION_NAME,
    VK_KHR_VIDEO_DECODE_H264_EXTENSION_NAME,
    VK_KHR_VIDEO_DECODE_H265_EXTENSION_NAME,
    VK_KHR_VIDEO_DECODE_QUEUE_EXTENSION_NAME,
    VK_KHR_VIDEO_MAINTENANCE_1_EXTENSION_NAME,
    VK_KHR_VIDEO_MAINTENANCE_2_EXTENSION_NAME,
    VK_KHR_VIDEO_QUEUE_EXTENSION_NAME,
    VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
    VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
#ifdef VK_KHR_video_decode_vp9
    VK_KHR_VIDEO_DECODE_VP9_EXTENSION_NAME,
#endif
#ifdef VK_KHR_maintenance9
    VK_KHR_MAINTENANCE_9_EXTENSION_NAME,
#endif
#ifdef VK_KHR_unified_image_layouts
    VK_KHR_UNIFIED_IMAGE_LAYOUTS_EXTENSION_NAME,
#endif
#ifdef VK_KHR_internally_synchronized_queues
    VK_KHR_INTERNALLY_SYNCHRONIZED_QUEUES_EXTENSION_NAME,
#endif
};

static pl_vulkan create_device(kiln_gpu *g) {
#ifdef VK_KHR_internally_synchronized_queues
    VkPhysicalDeviceInternallySynchronizedQueuesFeaturesKHR synchronized_queues = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_INTERNALLY_SYNCHRONIZED_QUEUES_FEATURES_KHR,
        .internallySynchronizedQueues = true,
    };
    void *chain = &synchronized_queues;
#else
    void *chain = NULL;
#endif
    VkPhysicalDeviceVideoMaintenance1FeaturesKHR video_maintenance_1 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VIDEO_MAINTENANCE_1_FEATURES_KHR, .pNext = chain, .videoMaintenance1 = true,
    };
    VkPhysicalDeviceVideoMaintenance2FeaturesKHR video_maintenance_2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VIDEO_MAINTENANCE_2_FEATURES_KHR, .pNext = &video_maintenance_1, .videoMaintenance2 = true,
    };
    VkPhysicalDeviceShaderAtomicFloatFeaturesEXT atomic_float = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_ATOMIC_FLOAT_FEATURES_EXT, .pNext = &video_maintenance_2,
        .shaderBufferFloat32Atomics = true, .shaderBufferFloat32AtomicAdd = true,
    };
    VkPhysicalDeviceVulkan13Features vk13 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .pNext = &atomic_float,
        .dynamicRendering = true, .subgroupSizeControl = true,
    };
    VkPhysicalDeviceVulkan12Features vk12 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &vk13,
        .scalarBlockLayout = true, .vulkanMemoryModelAvailabilityVisibilityChains = true, .shaderSubgroupExtendedTypes = true,
        .shaderSampledImageArrayNonUniformIndexing = true, .shaderStorageImageArrayNonUniformIndexing = true,
        .runtimeDescriptorArray = true, .shaderBufferInt64Atomics = true, .uniformBufferStandardLayout = true,
    };
    VkPhysicalDeviceVulkan11Features vk11 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &vk12,
        .storageBuffer16BitAccess = true, .uniformAndStorageBuffer16BitAccess = true,
    };
    VkPhysicalDeviceFeatures2 features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &vk11,
        .features = { .shaderInt16 = true, .shaderFloat64 = true },
    };
    return pl_vulkan_create(g->log, pl_vulkan_params(
        .instance = g->instance->instance,
        .get_proc_addr = g->instance->get_proc_addr,
        .surface = g->surface,
        .async_transfer = true,
        .async_compute = true,
        .extra_queues = VK_QUEUE_VIDEO_DECODE_BIT_KHR,
        .opt_extensions = optional_extensions,
        .num_opt_extensions = sizeof(optional_extensions) / sizeof(*optional_extensions),
        .features = &features,
    ));
}

/** Mailbox, so a present never blocks the main thread on vblank (frame callbacks pace the window); `KILN_PRESENT=fifo`
 * selects FIFO for comparison. */
static VkPresentModeKHR present_mode(void) {
    const char *mode = getenv("KILN_PRESENT");
    if (mode && strcmp(mode, "fifo") == 0) return VK_PRESENT_MODE_FIFO_KHR;
    if (mode && strcmp(mode, "immediate") == 0) return VK_PRESENT_MODE_IMMEDIATE_KHR;
    return VK_PRESENT_MODE_MAILBOX_KHR;
}

kiln_gpu *kiln_gpu_create(struct wl_display *display, struct wl_surface *surface, char *error, size_t error_size) {
    kiln_gpu *g = calloc(1, sizeof(*g));
    g->log = pl_log_create(PL_API_VER, pl_log_params(.log_cb = pl_log_color, .log_level = getenv("KILN_PL_TRACE") ? PL_LOG_TRACE : getenv("KILN_PL_DEBUG") ? PL_LOG_DEBUG : PL_LOG_WARN));
    const char *surface_extensions[] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME };
    const char *instance_optional[] = { VK_EXT_SWAPCHAIN_COLOR_SPACE_EXTENSION_NAME, VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME };
    g->instance = pl_vk_inst_create(g->log, pl_vk_inst_params(
        .extensions = surface ? surface_extensions : NULL,
        .num_extensions = surface ? 2 : 0,
        .opt_extensions = instance_optional,
        .num_opt_extensions = 2,
    ));
    if (!g->instance) { fail(error, error_size, "vulkan instance"); kiln_gpu_destroy(g); return NULL; }
    if (surface) {
        PFN_vkCreateWaylandSurfaceKHR create_surface = (PFN_vkCreateWaylandSurfaceKHR)
            g->instance->get_proc_addr(g->instance->instance, "vkCreateWaylandSurfaceKHR");
        VkWaylandSurfaceCreateInfoKHR info = { .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR, .display = display, .surface = surface };
        if (!create_surface || create_surface(g->instance->instance, &info, NULL, &g->surface) != VK_SUCCESS) {
            fail(error, error_size, "wayland surface");
            kiln_gpu_destroy(g);
            return NULL;
        }
    }
    g->vulkan = create_device(g);
    if (!g->vulkan) { fail(error, error_size, "vulkan device"); kiln_gpu_destroy(g); return NULL; }
    g->gpu = g->vulkan->gpu;
    if (g->surface) {
        g->swapchain = pl_vulkan_create_swapchain(g->vulkan, pl_vulkan_swapchain_params(
            .surface = g->surface,
            .present_mode = present_mode(),
            .swapchain_depth = 2,
        ));
        if (!g->swapchain) { fail(error, error_size, "swapchain"); kiln_gpu_destroy(g); return NULL; }
        pl_swapchain_colorspace_hint(g->swapchain, &(struct pl_color_space) {
            .primaries = PL_COLOR_PRIM_BT_709,
            .transfer = PL_COLOR_TRC_SCRGB,
        });
    }
    g->dispatch = pl_dispatch_create(g->log, g->gpu);
    g->renderer = pl_renderer_create(g->log, g->gpu);
    VkDeviceQueueInfo2 queue_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_INFO_2,
        .queueFamilyIndex = g->vulkan->queue_graphics.index,
        .queueIndex = 0,
#ifdef VK_KHR_internally_synchronized_queues
        .flags = g->vulkan->queue_graphics.flags,
#endif
    };
    PFN_vkGetDeviceQueue2 get_queue = (PFN_vkGetDeviceQueue2) g->instance->get_proc_addr(g->instance->instance, "vkGetDeviceQueue2");
    if (get_queue) get_queue(g->vulkan->device, &queue_info, &g->graphics_queue);
    if (!g->graphics_queue) {
        queue_info.flags = 0;
        if (get_queue) get_queue(g->vulkan->device, &queue_info, &g->graphics_queue);
    }
    if (getenv("KILN_VIDEO_TRACE")) fprintf(stderr, "kiln_gpu: graphics queue %p family %u flags %u\n", (void *) g->graphics_queue,
                                           g->vulkan->queue_graphics.index, (unsigned) queue_info.flags);
    return g;
}

void kiln_gpu_destroy(kiln_gpu *g) {
    if (!g) return;
    if (g->gpu) pl_gpu_finish(g->gpu);
    kiln_gpu_save_shader_cache(g);
    if (g->gpu && g->shader_cache) pl_gpu_set_cache(g->gpu, NULL);
    pl_cache_destroy(&g->shader_cache);
    free(g->shader_cache_path);
    for (int i = 0; i < g->timer_count; i++) pl_timer_destroy(g->gpu, &g->timers[i]);
    for (int i = 0; i < KILN_VERTEX_FRAMES; i++) pl_buf_destroy(g->gpu, &g->vertex_bufs[i]);
    pl_renderer_destroy(&g->renderer);
    pl_dispatch_destroy(&g->dispatch);
    pl_swapchain_destroy(&g->swapchain);
    pl_vulkan_destroy(&g->vulkan);
    if (g->surface && g->instance) {
        PFN_vkDestroySurfaceKHR destroy_surface = (PFN_vkDestroySurfaceKHR) g->instance->get_proc_addr(g->instance->instance, "vkDestroySurfaceKHR");
        if (destroy_surface) destroy_surface(g->instance->instance, g->surface, NULL);
    }
    pl_vk_inst_destroy(&g->instance);
    pl_log_destroy(&g->log);
    free(g);
}

void kiln_gpu_release_surface(kiln_gpu *g) {
    if (!g) return;
    if (g->gpu) pl_gpu_finish(g->gpu);
    pl_swapchain_destroy(&g->swapchain);
    if (g->surface && g->instance) {
        PFN_vkDestroySurfaceKHR destroy_surface = (PFN_vkDestroySurfaceKHR) g->instance->get_proc_addr(g->instance->instance, "vkDestroySurfaceKHR");
        if (destroy_surface) destroy_surface(g->instance->instance, g->surface, NULL);
        g->surface = VK_NULL_HANDLE;
    }
}

bool kiln_gpu_thread_safe(kiln_gpu *g) {
    return g && g->gpu && g->gpu->limits.thread_safe;
}

const char *kiln_gpu_device_name(kiln_gpu *g) {
    static char name[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE];
    VkPhysicalDeviceProperties properties;
    PFN_vkGetPhysicalDeviceProperties get = (PFN_vkGetPhysicalDeviceProperties) g->instance->get_proc_addr(g->instance->instance, "vkGetPhysicalDeviceProperties");
    get(g->vulkan->phys_device, &properties);
    snprintf(name, sizeof(name), "%s", properties.deviceName);
    return name;
}

bool kiln_gpu_use_shader_cache(kiln_gpu *g, const char *path) {
    if (!g || !path) return false;
    if (!g->shader_cache) {
        g->shader_cache = pl_cache_create(pl_cache_params(.log = g->log, .max_total_size = 64 << 20, .max_object_size = 8 << 20));
        pl_gpu_set_cache(g->gpu, g->shader_cache);
    }
    free(g->shader_cache_path);
    g->shader_cache_path = strdup(path);
    FILE *file = fopen(path, "rb");
    if (!file) return false;
    int loaded = pl_cache_load_file(g->shader_cache, file);
    fclose(file);
    g->shader_cache_objects = pl_cache_objects(g->shader_cache);
    return loaded > 0;
}

bool kiln_gpu_save_shader_cache(kiln_gpu *g) {
    if (!g || !g->shader_cache || !g->shader_cache_path) return false;
    int objects = pl_cache_objects(g->shader_cache);
    if (objects == g->shader_cache_objects) return true;
    size_t length = strlen(g->shader_cache_path);
    char *temporary = malloc(length + 5);
    snprintf(temporary, length + 5, "%s.new", g->shader_cache_path);
    FILE *file = fopen(temporary, "wb");
    if (!file) {
        free(temporary);
        return false;
    }
    pl_cache_save_file(g->shader_cache, file);
    bool ok = fclose(file) == 0 && rename(temporary, g->shader_cache_path) == 0;
    free(temporary);
    if (ok) g->shader_cache_objects = objects;
    return ok;
}

kiln_vulkan_handles kiln_gpu_vulkan_handles(kiln_gpu *g) {
    return (kiln_vulkan_handles) {
        .instance = g->vulkan->instance,
        .physical_device = g->vulkan->phys_device,
        .device = g->vulkan->device,
        .graphics_queue = g->graphics_queue,
        .graphics_family = g->vulkan->queue_graphics.index,
        .get_instance_proc_addr = (void *) g->vulkan->get_proc_addr,
        .features = g->vulkan->features,
        .extensions = g->vulkan->extensions,
        .num_extensions = g->vulkan->num_extensions,
#ifdef VK_KHR_internally_synchronized_queues
        .graphics_queue_flags = g->vulkan->queue_graphics.flags,
#endif
    };
}

bool kiln_gpu_resize(kiln_gpu *g, int *width, int *height) {
    return g->swapchain && pl_swapchain_resize(g->swapchain, width, height);
}

static pl_fmt find_format(kiln_gpu *g, enum kiln_format format, bool renderable) {
    enum pl_fmt_caps caps = PL_FMT_CAP_SAMPLEABLE | PL_FMT_CAP_LINEAR | (renderable ? PL_FMT_CAP_RENDERABLE | PL_FMT_CAP_BLITTABLE : 0);
    switch (format) {
    case KILN_FORMAT_RGBA16F: return pl_find_fmt(g->gpu, PL_FMT_FLOAT, 4, 16, 16, caps);
    case KILN_FORMAT_RGBA8: return pl_find_fmt(g->gpu, PL_FMT_UNORM, 4, 8, 8, caps);
    case KILN_FORMAT_R8: return pl_find_fmt(g->gpu, PL_FMT_UNORM, 1, 8, 8, caps);
    }
    return NULL;
}

kiln_tex *kiln_tex_create(kiln_gpu *g, int width, int height, enum kiln_format format, bool renderable) {
    pl_fmt fmt = find_format(g, format, renderable);
    if (!fmt) return NULL;
    pl_tex tex = pl_tex_create(g->gpu, pl_tex_params(
        .w = width, .h = height, .format = fmt,
        .sampleable = true, .renderable = renderable, .blit_dst = renderable, .blit_src = renderable,
        .host_writable = !renderable, .host_readable = true, .storable = renderable && (fmt->caps & PL_FMT_CAP_STORABLE),
    ));
    if (!tex) return NULL;
    kiln_tex *t = calloc(1, sizeof(*t));
    t->tex = tex;
    return t;
}

void kiln_tex_destroy(kiln_gpu *g, kiln_tex *t) {
    if (!t) return;
    if (t->view) {
        PFN_vkDestroyImageView destroy = (PFN_vkDestroyImageView) g->instance->get_proc_addr(g->instance->instance, "vkDestroyImageView");
        destroy(g->vulkan->device, t->view, NULL);
    }
    if (t->semaphore) pl_vulkan_sem_destroy(g->gpu, &t->semaphore);
    pl_tex_destroy(g->gpu, &t->tex);
    free(t);
}

int kiln_tex_width(kiln_tex *t) { return t->tex->params.w; }
int kiln_tex_height(kiln_tex *t) { return t->tex->params.h; }

bool kiln_tex_upload(kiln_gpu *g, kiln_tex *t, const void *pixels, size_t row_bytes) {
    return pl_tex_upload(g->gpu, pl_tex_transfer_params(.tex = t->tex, .ptr = (void *) pixels, .row_pitch = row_bytes));
}

static float half_to_float(uint16_t h) {
    uint32_t sign = (uint32_t)(h >> 15) << 31, exponent = (h >> 10) & 31, mantissa = h & 1023, bits;
    if (exponent == 0) {
        if (mantissa == 0) bits = sign;
        else {
            exponent = 127 - 15 + 1;
            while (!(mantissa & 1024)) { mantissa <<= 1; exponent--; }
            bits = sign | (exponent << 23) | ((mantissa & 1023) << 13);
        }
    } else if (exponent == 31) bits = sign | 0x7f800000 | (mantissa << 13);
    else bits = sign | ((exponent - 15 + 127) << 23) | (mantissa << 13);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

bool kiln_tex_download(kiln_gpu *g, kiln_tex *t, float *rgba) {
    const struct pl_fmt_t *fmt = t->tex->params.format;
    int w = t->tex->params.w, h = t->tex->params.h;
    size_t texel = fmt->texel_size;
    uint8_t *raw = malloc((size_t) w * h * texel);
    bool ok = pl_tex_download(g->gpu, pl_tex_transfer_params(.tex = t->tex, .ptr = raw));
    if (ok) {
        for (size_t i = 0; i < (size_t) w * h; i++) {
            for (int c = 0; c < 4; c++) {
                float v = 0;
                if (fmt->type == PL_FMT_FLOAT && c < fmt->num_components) v = half_to_float(((uint16_t *) raw)[i * fmt->num_components + c]);
                else if (c < fmt->num_components) v = raw[i * fmt->num_components + c] / 255.0f;
                else if (c == 3) v = 1;
                rgba[i * 4 + c] = v;
            }
        }
    }
    free(raw);
    return ok;
}

struct kiln_readback {
    pl_buf buf;
    pl_fmt fmt;
    int w, h;
};

kiln_readback *kiln_tex_readback_begin(kiln_gpu *g, kiln_tex *t) {
    pl_fmt fmt = t->tex->params.format;
    int w = t->tex->params.w, h = t->tex->params.h;
    pl_buf buf = pl_buf_create(g->gpu, pl_buf_params(.size = (size_t) w * h * fmt->texel_size, .host_readable = true));
    if (!buf) return NULL;
    if (!pl_tex_download(g->gpu, pl_tex_transfer_params(.tex = t->tex, .buf = buf))) {
        pl_buf_destroy(g->gpu, &buf);
        return NULL;
    }
    pl_gpu_flush(g->gpu);
    kiln_readback *r = calloc(1, sizeof(*r));
    r->buf = buf;
    r->fmt = fmt;
    r->w = w;
    r->h = h;
    return r;
}

bool kiln_readback_poll(kiln_gpu *g, kiln_readback *r, float *rgba) {
    if (pl_buf_poll(g->gpu, r->buf, 0)) return false;
    size_t texels = (size_t) r->w * r->h;
    uint8_t *raw = malloc(texels * r->fmt->texel_size);
    bool ok = pl_buf_read(g->gpu, r->buf, 0, raw, texels * r->fmt->texel_size);
    if (ok) {
        int n = r->fmt->num_components;
        for (size_t i = 0; i < texels; i++) {
            for (int c = 0; c < 4; c++) {
                float v = c == 3 ? 1 : 0;
                if (c < n) v = r->fmt->type == PL_FMT_FLOAT ? half_to_float(((uint16_t *) raw)[i * n + c]) : raw[i * n + c] / 255.0f;
                rgba[i * 4 + c] = v;
            }
        }
    }
    free(raw);
    return ok;
}

int kiln_readback_width(kiln_readback *r) { return r->w; }
int kiln_readback_height(kiln_readback *r) { return r->h; }

void kiln_readback_destroy(kiln_gpu *g, kiln_readback *r) {
    if (!r) return;
    pl_buf_destroy(g->gpu, &r->buf);
    free(r);
}

bool kiln_tex_hold_vulkan(kiln_gpu *g, kiln_tex *t, void **image, void **view, uint32_t *format, uint32_t *layout) {
    VkFormat vk_format;
    VkImageUsageFlags usage;
    VkImage vk_image = pl_vulkan_unwrap(g->gpu, t->tex, &vk_format, &usage);
    if (!vk_image) return false;
    if (!t->view) {
        VkImageViewCreateInfo info = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = vk_image, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = vk_format,
            .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        };
        PFN_vkCreateImageView create = (PFN_vkCreateImageView) g->instance->get_proc_addr(g->instance->instance, "vkCreateImageView");
        if (create(g->vulkan->device, &info, NULL, &t->view) != VK_SUCCESS) return false;
    }
    if (!t->semaphore) {
        t->semaphore = pl_vulkan_sem_create(g->gpu, pl_vulkan_sem_params(.type = VK_SEMAPHORE_TYPE_TIMELINE));
        if (!t->semaphore) return false;
    }
    VkImageLayout current;
    t->semaphore_value++;
    if (!pl_vulkan_hold_ex(g->gpu, pl_vulkan_hold_params(
            .tex = t->tex, .out_layout = &current, .qf = VK_QUEUE_FAMILY_IGNORED,
            .semaphore = { .sem = t->semaphore, .value = t->semaphore_value }))) return false;
    PFN_vkWaitSemaphores wait = (PFN_vkWaitSemaphores) g->instance->get_proc_addr(g->instance->instance, "vkWaitSemaphores");
    VkSemaphoreWaitInfo wait_info = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO, .semaphoreCount = 1, .pSemaphores = &t->semaphore, .pValues = &t->semaphore_value };
    wait(g->vulkan->device, &wait_info, UINT64_MAX);
    *image = vk_image;
    *view = t->view;
    *format = vk_format;
    *layout = current;
    return true;
}

void kiln_tex_release_vulkan(kiln_gpu *g, kiln_tex *t, uint32_t layout) {
    pl_vulkan_release_ex(g->gpu, pl_vulkan_release_params(.tex = t->tex, .layout = (VkImageLayout) layout, .qf = VK_QUEUE_FAMILY_IGNORED));
}

static pl_timer next_timer(kiln_gpu *g) {
    if (g->pass_index == KILN_MAX_TIMERS) return NULL;
    if (g->pass_index == g->timer_count) g->timers[g->timer_count++] = pl_timer_create(g->gpu);
    return g->timers[g->pass_index++];
}

static void collect_timers(kiln_gpu *g) {
    for (int i = 0; i < g->timer_count; i++) {
        uint64_t ns;
        while ((ns = pl_timer_query(g->gpu, g->timers[i]))) g->pending_ms += ns / 1e6;
    }
}

static bool fill_descriptors(struct pl_shader_desc *descriptors, const kiln_sampler *samplers, int sampler_count) {
    if (sampler_count > 16) return false;
    for (int i = 0; i < sampler_count; i++) {
        descriptors[i] = (struct pl_shader_desc) {
            .desc = { .name = samplers[i].name, .type = PL_DESC_SAMPLED_TEX },
            .binding = {
                .object = samplers[i].tex->tex,
                .sample_mode = samplers[i].nearest ? PL_TEX_SAMPLE_NEAREST : PL_TEX_SAMPLE_LINEAR,
                .address_mode = PL_TEX_ADDRESS_CLAMP,
            },
        };
    }
    return true;
}

bool kiln_gpu_pass(kiln_gpu *g, kiln_tex *target, const char *header, const char *body,
                   const kiln_sampler *samplers, int sampler_count,
                   const kiln_uniform *uniforms, int uniform_count,
                   const float *rect, bool blend) {
    struct pl_shader_desc descriptors[16];
    struct pl_shader_var variables[32];
    if (uniform_count > 32 || !fill_descriptors(descriptors, samplers, sampler_count)) return false;
    for (int i = 0; i < uniform_count; i++) {
        struct pl_var var;
        switch (uniforms[i].components) {
        case 1: var = pl_var_float(uniforms[i].name); break;
        case 2: var = pl_var_vec2(uniforms[i].name); break;
        case 3: var = pl_var_vec3(uniforms[i].name); break;
        default: var = pl_var_vec4(uniforms[i].name); break;
        }
        variables[i] = (struct pl_shader_var) { .var = var, .data = uniforms[i].value, .dynamic = true };
    }
    pl_shader sh = pl_dispatch_begin(g->dispatch);
    bool ok = pl_shader_custom(sh, &(struct pl_custom_shader) {
        .header = header, .body = body,
        .input = PL_SHADER_SIG_NONE, .output = PL_SHADER_SIG_COLOR,
        .descriptors = descriptors, .num_descriptors = sampler_count,
        .variables = variables, .num_variables = uniform_count,
    });
    if (!ok) { pl_dispatch_abort(g->dispatch, &sh); return false; }
    pl_rect2d area = rect ? (pl_rect2d) { (int) rect[0], (int) rect[1], (int) rect[2], (int) rect[3] } : (pl_rect2d) { 0 };
    return pl_dispatch_finish(g->dispatch, pl_dispatch_params(
        .shader = &sh, .target = target->tex, .rect = area,
        .blend_params = blend ? &pl_alpha_overlay : NULL,
        .timer = next_timer(g),
    ));
}

/* Moves vertex data to the next frame's buffer: each frame (or each 4 MB, for windows that never present) writes its
 * own host-mapped buffer, which the GPU finished reading frames ago. */
static void next_vertex_buffer(kiln_gpu *g) {
    g->vertex_frame = (g->vertex_frame + 1) % KILN_VERTEX_FRAMES;
    g->vertex_used = 0;
    g->vertex_ready = false;
}

/* Room for `size` bytes of vertices in this frame's buffer, mapped; NULL when it cannot be had (the draw then hands its
 * vertices to libplacebo, which makes a buffer for them). */
static pl_buf vertex_space(kiln_gpu *g, size_t size, size_t *offset) {
    if (size > KILN_VERTEX_BYTES) return NULL;
    if (g->vertex_used + size > KILN_VERTEX_BYTES) next_vertex_buffer(g);
    pl_buf buf = g->vertex_bufs[g->vertex_frame];
    if (!buf) {
        buf = pl_buf_create(g->gpu, pl_buf_params(.size = KILN_VERTEX_BYTES, .host_mapped = true, .drawable = true));
        if (!buf || !buf->data) {
            pl_buf_destroy(g->gpu, &buf);
            return NULL;
        }
        g->vertex_bufs[g->vertex_frame] = buf;
        g->vertex_ready = true;
    }
    if (!g->vertex_ready) {
        while (pl_buf_poll(g->gpu, buf, UINT64_MAX)) {}
        g->vertex_ready = true;
    }
    *offset = g->vertex_used;
    g->vertex_used += (size + 15) & ~(size_t) 15;
    return buf;
}

bool kiln_gpu_draw(kiln_gpu *g, kiln_tex *target, const char *header, const char *body,
                   const kiln_sampler *samplers, int sampler_count,
                   const kiln_attribute *attributes, int attribute_count,
                   const float *vertices, int vertex_count, bool blend) {
    struct pl_shader_desc descriptors[16];
    struct pl_vertex_attrib attribs[16];
    if (attribute_count < 1 || attribute_count > 16 || vertex_count <= 0) return false;
    if (!fill_descriptors(descriptors, samplers, sampler_count)) return false;
    size_t stride = 0;
    for (int i = 0; i < attribute_count; i++) {
        pl_fmt fmt = pl_find_vertex_fmt(g->gpu, PL_FMT_FLOAT, attributes[i].components);
        if (!fmt) return false;
        attribs[i] = (struct pl_vertex_attrib) { .name = attributes[i].name, .fmt = fmt, .offset = stride, .location = i };
        stride += (size_t) attributes[i].components * sizeof(float);
    }
    pl_shader sh = pl_dispatch_begin(g->dispatch);
    bool ok = pl_shader_custom(sh, &(struct pl_custom_shader) {
        .header = header, .body = body,
        .input = PL_SHADER_SIG_NONE, .output = PL_SHADER_SIG_COLOR,
        .descriptors = descriptors, .num_descriptors = sampler_count,
    });
    if (!ok) { pl_dispatch_abort(g->dispatch, &sh); return false; }
    size_t size = stride * (size_t) vertex_count;
    size_t offset = 0;
    pl_buf buf = vertex_space(g, size, &offset);
    if (buf) memcpy((uint8_t *) buf->data + offset, vertices, size);
    return pl_dispatch_vertex(g->dispatch, pl_dispatch_vertex_params(
        .shader = &sh, .target = target->tex,
        .blend_params = blend ? &pl_alpha_overlay : NULL,
        .vertex_attribs = attribs, .num_vertex_attribs = attribute_count, .vertex_stride = stride,
        .vertex_position_idx = 0, .vertex_coords = PL_COORDS_ABSOLUTE,
        .vertex_type = PL_PRIM_TRIANGLE_LIST, .vertex_count = vertex_count,
        .vertex_data = buf ? NULL : vertices, .vertex_buf = buf, .buf_offset = offset,
        .timer = next_timer(g),
    ));
}

bool kiln_gpu_present(kiln_gpu *g, kiln_tex *source, int width, int height) {
    if (!g->swapchain) return false;
    struct pl_swapchain_frame frame;
    if (!pl_swapchain_start_frame(g->swapchain, &frame)) return false;
    struct pl_frame image = {
        .num_planes = 1,
        .planes = { { .texture = source->tex, .components = 4, .component_mapping = { 0, 1, 2, 3 } } },
        .repr = pl_color_repr_rgb,
        .color = { .primaries = PL_COLOR_PRIM_BT_709, .transfer = PL_COLOR_TRC_LINEAR, .hdr = { .max_luma = 10000.0f } },
        .crop = { 0, 0, (float) width, (float) height },
    };
    struct pl_frame target;
    pl_frame_from_swapchain(&target, &frame);
    struct pl_color_map_params color_map = pl_color_map_default_params;
    color_map.tone_mapping_function = &pl_tone_map_clip;
    color_map.gamut_mapping = &pl_gamut_map_clip;
    pl_render_image(g->renderer, &image, &target, pl_render_params(
        .upscaler = &pl_filter_bilinear, .downscaler = &pl_filter_bilinear,
        .skip_anti_aliasing = true, .disable_linear_scaling = true,
        .color_map_params = &color_map,
    ));
    bool ok = pl_swapchain_submit_frame(g->swapchain);
    if (ok) pl_swapchain_swap_buffers(g->swapchain);
    collect_timers(g);
    g->pass_index = 0;
    next_vertex_buffer(g);
    return ok;
}

double kiln_gpu_take_gpu_ms(kiln_gpu *g) {
    collect_timers(g);
    double value = g->pending_ms;
    g->pending_ms = 0;
    return value;
}

void kiln_gpu_finish(kiln_gpu *g) { pl_gpu_finish(g->gpu); }
