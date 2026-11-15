#ifndef KILN_GPU_H
#define KILN_GPU_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct wl_display;
struct wl_surface;

typedef struct kiln_gpu kiln_gpu;
typedef struct kiln_tex kiln_tex;

enum kiln_format {
    KILN_FORMAT_RGBA16F = 0,
    KILN_FORMAT_RGBA8 = 1,
    KILN_FORMAT_R8 = 2,
};

typedef struct {
    const char *name;
    kiln_tex *tex;
    bool nearest;
} kiln_sampler;

typedef struct {
    const char *name;
    int components;
    float value[4];
} kiln_uniform;

typedef struct {
    void *instance;
    void *physical_device;
    void *device;
    void *graphics_queue;
    uint32_t graphics_family;
    void *get_instance_proc_addr;
    const void *features;
    const char *const *extensions;
    int num_extensions;
    uint32_t graphics_queue_flags;
} kiln_vulkan_handles;

/** Creates the Vulkan device (mpv's recipe: Vulkan Video decode queues, internally synchronised queues) and, when a
 * Wayland surface is given, an FP16 swapchain on it hinted as scRGB. Writes a reason into `error` on failure. */
kiln_gpu *kiln_gpu_create(struct wl_display *display, struct wl_surface *surface, char *error, size_t error_size);
void kiln_gpu_destroy(kiln_gpu *gpu);
/** Destroys the swapchain and the Vulkan surface, so the Wayland connection under them can close while the device
 * lives on until its last texture goes. Presenting afterwards does nothing. */
void kiln_gpu_release_surface(kiln_gpu *gpu);
const char *kiln_gpu_device_name(kiln_gpu *gpu);

/** Whether textures may be created, uploaded and destroyed from any thread (true on Vulkan). */
bool kiln_gpu_thread_safe(kiln_gpu *gpu);
kiln_vulkan_handles kiln_gpu_vulkan_handles(kiln_gpu *gpu);

/** Compiles shaders through a cache kept at `path` (loaded now, saved by `kiln_gpu_save_shader_cache` and on destroy), so
 * a pass compiled once never stalls a frame again, across launches too. */
bool kiln_gpu_use_shader_cache(kiln_gpu *gpu, const char *path);
bool kiln_gpu_save_shader_cache(kiln_gpu *gpu);

/** Resizes the swapchain; width and height come back as the swapchain chose them. */
bool kiln_gpu_resize(kiln_gpu *gpu, int *width, int *height);

kiln_tex *kiln_tex_create(kiln_gpu *gpu, int width, int height, enum kiln_format format, bool renderable);
void kiln_tex_destroy(kiln_gpu *gpu, kiln_tex *tex);
int kiln_tex_width(kiln_tex *tex);
int kiln_tex_height(kiln_tex *tex);
bool kiln_tex_upload(kiln_gpu *gpu, kiln_tex *tex, const void *pixels, size_t row_bytes);
/** Downloads as RGBA floats, top row first. */
bool kiln_tex_download(kiln_gpu *gpu, kiln_tex *tex, float *rgba);

typedef struct kiln_readback kiln_readback;

/** Starts copying `tex` into host memory without waiting; poll until it lands. For small textures read every frame (the
 * glass pyramid's smallest level, whose luminance picks light or dark glass). */
kiln_readback *kiln_tex_readback_begin(kiln_gpu *gpu, kiln_tex *tex);
/** Fills `rgba` (width * height * 4 floats) and returns true once the copy finished; false while it is in flight. */
bool kiln_readback_poll(kiln_gpu *gpu, kiln_readback *readback, float *rgba);
int kiln_readback_width(kiln_readback *readback);
int kiln_readback_height(kiln_readback *readback);
void kiln_readback_destroy(kiln_gpu *gpu, kiln_readback *readback);

/** The VkImage behind a renderable texture, held for an external user (mpv) until `kiln_tex_release_vulkan`. */
bool kiln_tex_hold_vulkan(kiln_gpu *gpu, kiln_tex *tex, void **image, void **view, uint32_t *format, uint32_t *layout);
void kiln_tex_release_vulkan(kiln_gpu *gpu, kiln_tex *tex, uint32_t layout);

/** Runs a full-screen (or `rect`) GLSL pass into `target`. `body` writes `color` (vec4); samplers and uniforms are
 * declared by name; gl_FragCoord is in target pixels. */
bool kiln_gpu_pass(kiln_gpu *gpu, kiln_tex *target, const char *header, const char *body,
                   const kiln_sampler *samplers, int sampler_count,
                   const kiln_uniform *uniforms, int uniform_count,
                   const float *rect, bool blend);

/** Starts a swapchain frame, draws `source` onto it, submits and swaps. */
bool kiln_gpu_present(kiln_gpu *gpu, kiln_tex *source);

/** GPU time of the passes since the last call, in milliseconds (a frame or two late). */
double kiln_gpu_take_gpu_ms(kiln_gpu *gpu);
void kiln_gpu_finish(kiln_gpu *gpu);

#endif
