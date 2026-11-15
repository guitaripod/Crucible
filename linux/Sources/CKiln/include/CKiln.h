#ifndef CKILN_H
#define CKILN_H

#include <stdbool.h>
#include <stdint.h>
#include <wayland-client.h>

#include "../protocols/xdg-shell-client-protocol.h"
#include "../protocols/xdg-decoration-unstable-v1-client-protocol.h"
#include "../protocols/color-management-v1-client-protocol.h"
#include "../protocols/presentation-time-client-protocol.h"
#include "../protocols/fifo-v1-client-protocol.h"
#include "../protocols/fractional-scale-v1-client-protocol.h"
#include "../protocols/viewporter-client-protocol.h"
#include "../protocols/idle-inhibit-unstable-v1-client-protocol.h"
#include "../protocols/cursor-shape-v1-client-protocol.h"

typedef struct kiln_wl kiln_wl;

enum {
    KILN_STATE_MAXIMIZED = 1 << 0,
    KILN_STATE_FULLSCREEN = 1 << 1,
    KILN_STATE_ACTIVATED = 1 << 2,
    KILN_STATE_RESIZING = 1 << 3,
};

enum {
    KILN_COLOR_PARAMETRIC = 1 << 0,
    KILN_COLOR_SCRGB = 1 << 1,
    KILN_COLOR_PQ = 1 << 2,
    KILN_COLOR_BT2020 = 1 << 3,
    KILN_COLOR_MASTERING = 1 << 4,
    KILN_COLOR_LUMINANCES = 1 << 5,
};

typedef struct {
    void (*configure)(void *context, int32_t width, int32_t height, uint32_t states);
    void (*close)(void *context);
    void (*scale)(void *context, uint32_t scale120);
    void (*presented)(void *context, uint64_t nanoseconds, uint32_t refresh_ns, uint64_t sequence, uint32_t flags);
    void (*discarded)(void *context);
    void (*frame)(void *context, uint32_t milliseconds);
    void (*pointer_motion)(void *context, double x, double y);
    void (*pointer_leave)(void *context);
    void (*pointer_button)(void *context, uint32_t button, uint32_t pressed);
    void (*pointer_axis)(void *context, uint32_t axis, double value, int32_t discrete120);
    void (*key)(void *context, uint32_t key, uint32_t pressed);
} kiln_wl_callbacks;

/** Connects to the named Wayland display (NULL for $WAYLAND_DISPLAY) and binds every global Kiln uses. */
kiln_wl *kiln_wl_connect(const char *name);
void kiln_wl_disconnect(kiln_wl *wl);
int kiln_wl_fd(kiln_wl *wl);
struct wl_display *kiln_wl_display(kiln_wl *wl);
struct wl_surface *kiln_wl_surface(kiln_wl *wl);

/** Runs one non-blocking read of the display: prepare, read what the socket holds, dispatch, flush. */
int kiln_wl_pump(kiln_wl *wl, bool readable);
int kiln_wl_flush(kiln_wl *wl);
int kiln_wl_roundtrip(kiln_wl *wl);

/** Creates the toplevel and waits for its first configure. */
bool kiln_wl_create_window(kiln_wl *wl, const char *title, const char *app_id, kiln_wl_callbacks callbacks, void *context);
void kiln_wl_set_fullscreen(kiln_wl *wl, bool fullscreen);
void kiln_wl_set_buffer_scale120(kiln_wl *wl, uint32_t scale120, int32_t logical_width, int32_t logical_height);

uint32_t kiln_wl_color_features(kiln_wl *wl);

/** Describes the window surface as Windows-scRGB (BT.709 primaries, extended linear, 1.0 = 80 cd/m2). */
bool kiln_wl_describe_scrgb(kiln_wl *wl);

/** Asks for presentation feedback and a frame callback for the next commit. The colour description and FIFO barrier are
 * opt-in: a Vulkan swapchain creates its own wp_fifo_v1 and colour-management surface, and a second one is a protocol
 * error. */
void kiln_wl_request_frame(kiln_wl *wl);
void kiln_wl_set_fifo_barrier(kiln_wl *wl);

void kiln_wl_inhibit_idle(kiln_wl *wl, bool inhibit);

/** Hands libdispatch's main-queue handle to the event loop, as CoreFoundation's run loop does. */
int kiln_dispatch_main_queue_handle(void);
void kiln_dispatch_drain_main_queue(void);

#endif
