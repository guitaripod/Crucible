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

struct kiln_video {
    mpv_handle *mpv;
    mpv_render_context *render;
    int wakeup;
    atomic_bool frame_pending;
    VkPhysicalDeviceFeatures2 features;
};

enum { OBSERVE_POSITION = 1, OBSERVE_DURATION, OBSERVE_PAUSE, OBSERVE_BUFFERING, OBSERVE_CACHE, OBSERVE_WIDTH, OBSERVE_HEIGHT,
       OBSERVE_SEEKING, OBSERVE_HWDEC, OBSERVE_VOLUME, OBSERVE_MUTE, OBSERVE_EOF };

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

#define TRACE(...) do { if (getenv("KILN_VIDEO_TRACE")) { fprintf(stderr, "kiln_video: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

static void fail(char *error, size_t size, const char *message) {
    if (error && size) snprintf(error, size, "%s", message);
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
        { "vo", "libmpv" }, { "hwdec", "auto-safe" }, { "terminal", "no" }, { "idle", "yes" }, { "keep-open", "yes" },
        { "target-trc", "linear" }, { "target-prim", "bt.709" }, { "target-peak", "10000" }, { "target-colorspace-hint", "no" },
        { "tone-mapping", "clip" }, { "gamut-mapping-mode", "clip" }, { "hdr-compute-peak", "no" }, { "dither", "no" },
        { "video-sync", "audio" }, { "cache", "yes" }, { "demuxer-max-bytes", "256MiB" }, { "demuxer-readahead-secs", "30" },
        { "input-default-bindings", "no" }, { "input-vo-keyboard", "no" }, { "osc", "no" }, { "ytdl", "no" },
        { "sub-font", "Inter Variable" }, { "sub-font-size", "46" }, { "sub-border-size", "2.5" }, { "sub-shadow-offset", "1" },
        { "audio-client-name", "Crucible" }, { "ao", "pipewire," },
    };
    for (size_t i = 0; i < sizeof options / sizeof *options; i++) mpv_set_option_string(v->mpv, options[i][0], options[i][1]);
    if (getenv("KILN_HWDEC")) mpv_set_option_string(v->mpv, "hwdec", getenv("KILN_HWDEC"));
    if (getenv("KILN_AO")) mpv_set_option_string(v->mpv, "ao", getenv("KILN_AO"));
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
    mpv_observe_property(v->mpv, OBSERVE_VOLUME, "volume", MPV_FORMAT_DOUBLE);
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
    case OBSERVE_VOLUME: state->volume = *(double *) property->data; break;
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
    int flip = 0;
    int block = 0;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_VULKAN_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flip },
        { MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    int rendered = mpv_render_context_render(v->render, params);
    TRACE("rendered %d", rendered);
    pl_vulkan_release_ex(g->gpu, pl_vulkan_release_params(
        .tex = t->tex, .layout = rendered >= 0 ? VK_IMAGE_LAYOUT_GENERAL : (VkImageLayout) layout, .qf = VK_QUEUE_FAMILY_IGNORED));
    return rendered >= 0;
}

void kiln_video_report_swap(kiln_video *v) { mpv_render_context_report_swap(v->render); }

int kiln_video_command(kiln_video *v, const char **arguments) { return mpv_command(v->mpv, arguments); }

int kiln_video_set_property(kiln_video *v, const char *name, const char *value) { return mpv_set_property_string(v->mpv, name, value); }

bool kiln_video_get_property(kiln_video *v, const char *name, char *value, size_t size) {
    char *text = mpv_get_property_string(v->mpv, name);
    if (!text) return false;
    snprintf(value, size, "%s", text);
    mpv_free(text);
    return true;
}
