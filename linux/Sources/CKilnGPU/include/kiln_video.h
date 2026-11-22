#ifndef KILN_VIDEO_H
#define KILN_VIDEO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "kiln_gpu.h"

typedef struct kiln_video kiln_video;

enum {
    KILN_VIDEO_FRAME = 1 << 0,
    KILN_VIDEO_STATE = 1 << 1,
    KILN_VIDEO_LOADED = 1 << 2,
    KILN_VIDEO_ENDED = 1 << 3,
    KILN_VIDEO_FAILED = 1 << 4,
    KILN_VIDEO_SEEKED = 1 << 5,
};

/** What the player reports, refreshed by `kiln_video_poll`. Times are seconds; `end_reason` is mpv's (0 eof, 2 stop, 4 error). */
typedef struct {
    double position;
    double duration;
    double cache_seconds;
    bool paused;
    bool buffering;
    bool seeking;
    bool muted;
    int width;
    int height;
    int end_reason;
    char hwdec[32];
    char error[256];
} kiln_video_state;

/** Creates libmpv on Kiln's Vulkan device with gpu-next rendering into linear BT.709 light (1.0 = 203 cd/m2), so frames
 * composite with the UI unchanged; hardware decoding on the same device. */
kiln_video *kiln_video_create(kiln_gpu *gpu, char *error, size_t error_size);
void kiln_video_destroy(kiln_video *video);

/** A file descriptor that becomes readable when mpv has events or a new frame; read it with `kiln_video_poll`. */
int kiln_video_wakeup_fd(kiln_video *video);

/** Drains mpv's events into `state` and returns what happened (KILN_VIDEO_*). */
uint32_t kiln_video_poll(kiln_video *video, kiln_video_state *state);

/** Renders the current frame into `target` (a renderable FP16 texture of the size the video should fill). */
bool kiln_video_render(kiln_video *video, kiln_gpu *gpu, kiln_tex *target);
/** Takes the frame mpv waits to have drawn without drawing it, so mpv goes on; a later render still draws that frame. */
void kiln_video_skip_frame(kiln_video *video);

/** Tells mpv a frame it rendered reached the screen, for its timing. */
void kiln_video_report_swap(kiln_video *video);

/** Runs an mpv command (`loadfile`, `seek`, `set`, ...) given as a NULL-terminated argument list. */
int kiln_video_command(kiln_video *video, const char **arguments);
int kiln_video_set_property(kiln_video *video, const char *name, const char *value);
/** Sets an mpv property, or runs an mpv command, without waiting for mpv's core thread, which a playing stream can keep
 * busy for hundreds of milliseconds. mpv runs such requests in the order they were made, but a request that waits can run
 * before them. A property mpv refuses is reported on stderr. */
void kiln_video_set_property_async(kiln_video *video, const char *name, const char *value);
void kiln_video_command_async(kiln_video *video, const char **arguments);
/** Reads an mpv property as text into `value` (`size` bytes); false when mpv has no such property now. */
bool kiln_video_get_property(kiln_video *video, const char *name, char *value, size_t size);

#endif
