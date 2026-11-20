#include "kiln_video.h"
#include "kiln_gpu_internal.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_vk.h>

#ifndef MPV_RENDER_VULKAN_SYNC_SIGNALS
#error "this libmpv leaves the Vulkan sync semaphore unsignalled, which would stall the GPU: rebuild it with linux/scripts/build-mpv.sh"
#endif

struct kiln_video {
    mpv_handle *mpv;
    mpv_render_context *render;
    int wakeup;
    atomic_bool frame_pending;
    VkPhysicalDeviceFeatures2 features;
};

enum { OBSERVE_POSITION = 1, OBSERVE_DURATION, OBSERVE_PAUSE, OBSERVE_BUFFERING, OBSERVE_CACHE, OBSERVE_WIDTH, OBSERVE_HEIGHT,
       OBSERVE_SEEKING, OBSERVE_HWDEC, OBSERVE_MUTE, OBSERVE_EOF };

/** The reply ids of the requests made without waiting: a property set mpv refuses is worth a line on stderr, while an
 * `af-command` sent before its filter runs fails as a matter of course. */
enum { REPLY_QUIET = 0, REPLY_REPORTED = 1 };

static void signal_wakeup(kiln_video *v) {
    uint64_t one = 1;
    ssize_t written = write(v->wakeup, &one, sizeof one);
    (void) written;
}

static void on_wakeup(void *context) { signal_wakeup(context); }

static void on_update(void *context) {
    kiln_video *v = context;
    atomic_store(&v->frame_pending, true);
    signal_wakeup(v);
}

/** Whether `KILN_VIDEO_TRACE` asks for the render steps on stderr, read once: the render path runs every frame. */
static bool tracing(void) {
    static int enabled = -1;
    if (enabled < 0) enabled = getenv("KILN_VIDEO_TRACE") != NULL;
    return enabled;
}

#define TRACE(...) do { if (tracing()) { fprintf(stderr, "kiln_video: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

/** Sets the mpv options `KILN_MPV_OPTIONS` names ("name=value;name=value"), after Kiln's own, for trying them on a device
 * without a rebuild. */
static void apply_option_overrides(mpv_handle *mpv) {
    const char *spec = getenv("KILN_MPV_OPTIONS");
    if (!spec) return;
    char *copy = strdup(spec), *save = NULL;
    for (char *pair = strtok_r(copy, ";", &save); pair; pair = strtok_r(NULL, ";", &save)) {
        char *equals = strchr(pair, '=');
        if (!equals) continue;
        *equals = '\0';
        if (mpv_set_option_string(mpv, pair, equals + 1) < 0) fprintf(stderr, "kiln_video: mpv did not take %s\n", pair);
    }
    free(copy);
}

static void fail(char *error, size_t size, const char *message) {
    if (error && size) snprintf(error, size, "%s", message);
}

/** The hardware decoding mpv tries first. On NVIDIA this libmpv has no CUDA interop, so `auto-safe` settles on
 * nvdec-copy, which brings every decoded frame back to system memory and uploads it again while the UI thread renders
 * (3.6 ms of it for each 4K HDR frame, against 0.8 ms with Vulkan Video). Vulkan Video decodes into images libplacebo
 * samples directly, and a codec it lacks (MPEG-2, VC-1) falls through to `auto-safe`. Other GPUs keep `auto-safe`, whose
 * VA-API already hands frames over without a copy (mpv patch 0012). */
static const char *preferred_hwdec(kiln_gpu *g) {
    kiln_vulkan_handles handles = kiln_gpu_vulkan_handles(g);
    PFN_vkGetInstanceProcAddr lookup = (PFN_vkGetInstanceProcAddr) handles.get_instance_proc_addr;
    PFN_vkGetPhysicalDeviceProperties properties = lookup && handles.instance
        ? (PFN_vkGetPhysicalDeviceProperties) lookup((VkInstance) handles.instance, "vkGetPhysicalDeviceProperties") : NULL;
    if (!properties || !handles.physical_device) return "auto-safe";
    VkPhysicalDeviceProperties device;
    properties((VkPhysicalDevice) handles.physical_device, &device);
    return device.vendorID == 0x10DE ? "vulkan,auto-safe" : "auto-safe";
}

kiln_video *kiln_video_create(kiln_gpu *g, char *error, size_t error_size) {
    kiln_video *v = calloc(1, sizeof(*v));
    v->wakeup = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    v->mpv = mpv_create();
    if (!v->mpv || v->wakeup < 0) {
        fail(error, error_size, "mpv_create");
        kiln_video_destroy(v);
        return NULL;
    }
    const char *options[][2] = {
        { "vo", "libmpv" }, { "terminal", "no" }, { "idle", "yes" }, { "keep-open", "yes" },
        { "target-trc", "linear" }, { "target-prim", "bt.709" }, { "target-peak", "10000" }, { "target-min-luma", "0.000001" },
        { "target-colorspace-hint", "no" },
        { "tone-mapping", "clip" }, { "gamut-mapping-mode", "clip" }, { "hdr-compute-peak", "no" }, { "dither", "no" },
        { "video-sync", "audio" }, { "cache", "yes" }, { "demuxer-max-bytes", "256MiB" }, { "demuxer-readahead-secs", "30" },
        { "input-default-bindings", "no" }, { "input-vo-keyboard", "no" }, { "osc", "no" }, { "ytdl", "no" },
        { "sub-font", "Inter Variable" }, { "sub-font-size", "46" }, { "sub-border-size", "2.5" }, { "sub-shadow-offset", "1" },
        { "audio-client-name", "Crucible" }, { "ao", "pipewire," },
    };
    for (size_t i = 0; i < sizeof options / sizeof *options; i++) mpv_set_option_string(v->mpv, options[i][0], options[i][1]);
    mpv_set_option_string(v->mpv, "hwdec", preferred_hwdec(g));
    if (getenv("KILN_HWDEC")) mpv_set_option_string(v->mpv, "hwdec", getenv("KILN_HWDEC"));
    if (getenv("KILN_AO")) mpv_set_option_string(v->mpv, "ao", getenv("KILN_AO"));
    apply_option_overrides(v->mpv);
    if (mpv_initialize(v->mpv) < 0) {
        fail(error, error_size, "mpv_initialize");
        kiln_video_destroy(v);
        return NULL;
    }
    if (getenv("KILN_MPV_LOG")) mpv_request_log_messages(v->mpv, "v");
    kiln_vulkan_handles handles = kiln_gpu_vulkan_handles(g);
    mpv_vulkan_init_params init = {
        .instance = handles.instance, .physical_device = handles.physical_device, .device = handles.device,
        .graphics_queue = handles.graphics_queue, .graphics_queue_family = handles.graphics_family,
        .get_instance_proc_addr = (PFN_vkGetInstanceProcAddr) handles.get_instance_proc_addr,
        .features = handles.features, .extensions = handles.extensions, .num_extensions = handles.num_extensions,
        .graphics_queue_flags = handles.graphics_queue_flags,
    };
    mpv_render_param create[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *) "vulkan" },
        { MPV_RENDER_PARAM_BACKEND, (void *) "gpu-next" },
        { MPV_RENDER_PARAM_VULKAN_INIT_PARAMS, &init },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    TRACE("creating render context: %d extensions, features %p", init.num_extensions, init.features);
    int created = mpv_render_context_create(&v->render, v->mpv, create);
    TRACE("render context %d", created);
    if (created < 0) {
        fail(error, error_size, mpv_error_string(created));
        kiln_video_destroy(v);
        return NULL;
    }
    mpv_render_context_set_update_callback(v->render, on_update, v);
    mpv_set_wakeup_callback(v->mpv, on_wakeup, v);
    mpv_observe_property(v->mpv, OBSERVE_POSITION, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(v->mpv, OBSERVE_DURATION, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(v->mpv, OBSERVE_PAUSE, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(v->mpv, OBSERVE_BUFFERING, "paused-for-cache", MPV_FORMAT_FLAG);
    mpv_observe_property(v->mpv, OBSERVE_CACHE, "demuxer-cache-duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(v->mpv, OBSERVE_WIDTH, "dwidth", MPV_FORMAT_INT64);
    mpv_observe_property(v->mpv, OBSERVE_HEIGHT, "dheight", MPV_FORMAT_INT64);
    mpv_observe_property(v->mpv, OBSERVE_SEEKING, "seeking", MPV_FORMAT_FLAG);
    mpv_observe_property(v->mpv, OBSERVE_HWDEC, "hwdec-current", MPV_FORMAT_STRING);
    mpv_observe_property(v->mpv, OBSERVE_MUTE, "mute", MPV_FORMAT_FLAG);
    mpv_observe_property(v->mpv, OBSERVE_EOF, "eof-reached", MPV_FORMAT_FLAG);
    return v;
}

void kiln_video_destroy(kiln_video *v) {
    if (!v) return;
    if (v->render) mpv_render_context_free(v->render);
    if (v->mpv) mpv_terminate_destroy(v->mpv);
    if (v->wakeup >= 0) close(v->wakeup);
    free(v);
}

int kiln_video_wakeup_fd(kiln_video *v) { return v->wakeup; }

static void apply_property(kiln_video_state *state, mpv_event_property *property, uint64_t id) {
    if (!property->data) {
        if (id == OBSERVE_POSITION) state->position = 0;
        return;
    }
    switch (id) {
    case OBSERVE_POSITION: state->position = *(double *) property->data; break;
    case OBSERVE_DURATION: state->duration = *(double *) property->data; break;
    case OBSERVE_PAUSE: state->paused = *(int *) property->data; break;
    case OBSERVE_BUFFERING: state->buffering = *(int *) property->data; break;
    case OBSERVE_CACHE: state->cache_seconds = *(double *) property->data; break;
    case OBSERVE_WIDTH: state->width = (int) *(int64_t *) property->data; break;
    case OBSERVE_HEIGHT: state->height = (int) *(int64_t *) property->data; break;
    case OBSERVE_SEEKING: state->seeking = *(int *) property->data; break;
    case OBSERVE_HWDEC: snprintf(state->hwdec, sizeof state->hwdec, "%s", *(char **) property->data); break;
    case OBSERVE_MUTE: state->muted = *(int *) property->data; break;
    }
}

uint32_t kiln_video_poll(kiln_video *v, kiln_video_state *state) {
    uint64_t count;
    while (read(v->wakeup, &count, sizeof count) > 0) {}
    uint32_t happened = 0;
    for (;;) {
        mpv_event *event = mpv_wait_event(v->mpv, 0);
        if (event->event_id == MPV_EVENT_NONE) break;
        switch (event->event_id) {
        case MPV_EVENT_PROPERTY_CHANGE: {
            mpv_event_property *property = event->data;
            if (event->reply_userdata == OBSERVE_EOF) {
                if (property->data && *(int *) property->data) happened |= KILN_VIDEO_ENDED;
                break;
            }
            apply_property(state, property, event->reply_userdata);
            happened |= KILN_VIDEO_STATE;
            break;
        }
        case MPV_EVENT_FILE_LOADED:
            happened |= KILN_VIDEO_LOADED;
            state->end_reason = -1;
            state->error[0] = 0;
            break;
        case MPV_EVENT_PLAYBACK_RESTART:
            happened |= KILN_VIDEO_SEEKED;
            break;
        case MPV_EVENT_END_FILE: {
            mpv_event_end_file *end = event->data;
            state->end_reason = end->reason;
            if (end->reason == MPV_END_FILE_REASON_ERROR) {
                snprintf(state->error, sizeof state->error, "%s", mpv_error_string(end->error));
                happened |= KILN_VIDEO_FAILED;
            } else {
                happened |= KILN_VIDEO_ENDED;
            }
            break;
        }
        case MPV_EVENT_SET_PROPERTY_REPLY:
            if (event->error < 0 && event->reply_userdata == REPLY_REPORTED)
                fprintf(stderr, "kiln_video: mpv refused a property: %s\n", mpv_error_string(event->error));
            break;
        case MPV_EVENT_LOG_MESSAGE: {
            mpv_event_log_message *message = event->data;
            fprintf(stderr, "mpv[%s] %s: %s", message->level, message->prefix, message->text);
            break;
        }
        default:
            break;
        }
    }
    if (atomic_exchange(&v->frame_pending, false)) {
        if (mpv_render_context_update(v->render) & MPV_RENDER_UPDATE_FRAME) happened |= KILN_VIDEO_FRAME;
    }
    return happened;
}

/** Renders mpv's frame into `t` without waiting for the GPU: mpv starts once `t`'s timeline semaphore says Kiln's last use
 * of it is done, signals the next value when its frame is drawn, and Kiln's own next use waits for that value on the GPU.
 * The hold waits on the CPU for Kiln's previous use of `t`, which in turn waited for mpv's previous frame, so the GPU never
 * runs more than a frame behind and mpv's last decoded surface is free before the next one is mapped. */
bool kiln_video_render(kiln_video *v, kiln_gpu *g, kiln_tex *t) {
    void *image, *view;
    uint32_t format, layout;
    TRACE("hold");
    if (!kiln_tex_hold_vulkan(g, t, &image, &view, &format, &layout)) return false;
    TRACE("held layout %u format %u", layout, format);
    mpv_vulkan_fbo fbo = {
        .image = image, .image_view = view, .width = (uint32_t) t->tex->params.w, .height = (uint32_t) t->tex->params.h,
        .format = (VkFormat) format, .current_layout = (VkImageLayout) layout, .target_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    uint64_t free_value = t->semaphore_value, drawn_value = free_value + 1;
    mpv_vulkan_sync sync = {
        .wait_semaphore = t->semaphore, .wait_value = free_value, .signal_semaphore = t->semaphore, .signal_value = drawn_value,
    };
    int flip = 0;
    int block = 0;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_VULKAN_FBO, &fbo },
        { MPV_RENDER_PARAM_VULKAN_SYNC, &sync },
        { MPV_RENDER_PARAM_FLIP_Y, &flip },
        { MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    int rendered = mpv_render_context_render(v->render, params);
    TRACE("rendered %d", rendered);
    if (rendered < 0) {
        pl_vulkan_release_ex(g->gpu, pl_vulkan_release_params(.tex = t->tex, .layout = (VkImageLayout) layout, .qf = VK_QUEUE_FAMILY_IGNORED));
        return false;
    }
    t->semaphore_value = drawn_value;
    pl_vulkan_release_ex(g->gpu, pl_vulkan_release_params(
        .tex = t->tex, .layout = fbo.target_layout, .qf = VK_QUEUE_FAMILY_IGNORED,
        .semaphore = { .sem = t->semaphore, .value = drawn_value }));
    return true;
}

void kiln_video_report_swap(kiln_video *v) { mpv_render_context_report_swap(v->render); }

int kiln_video_command(kiln_video *v, const char **arguments) { return mpv_command(v->mpv, arguments); }

int kiln_video_set_property(kiln_video *v, const char *name, const char *value) { return mpv_set_property_string(v->mpv, name, value); }

void kiln_video_set_property_async(kiln_video *v, const char *name, const char *value) {
    mpv_set_property_async(v->mpv, REPLY_REPORTED, name, MPV_FORMAT_STRING, (void *) &value);
}

void kiln_video_command_async(kiln_video *v, const char **arguments) { mpv_command_async(v->mpv, REPLY_QUIET, arguments); }

bool kiln_video_get_property(kiln_video *v, const char *name, char *value, size_t size) {
    char *text = mpv_get_property_string(v->mpv, name);
    if (!text) return false;
    snprintf(value, size, "%s", text);
    mpv_free(text);
    return true;
}
