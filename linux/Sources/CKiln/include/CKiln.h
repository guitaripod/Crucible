#ifndef CKILN_H
#define CKILN_H

#include <stdbool.h>
#include <stdint.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>

#include "../protocols/xdg-shell-client-protocol.h"
#include "../protocols/xdg-decoration-unstable-v1-client-protocol.h"
#include "../protocols/color-management-v1-client-protocol.h"
#include "../protocols/presentation-time-client-protocol.h"
#include "../protocols/fifo-v1-client-protocol.h"
#include "../protocols/fractional-scale-v1-client-protocol.h"
#include "../protocols/viewporter-client-protocol.h"
#include "../protocols/idle-inhibit-unstable-v1-client-protocol.h"
#include "../protocols/cursor-shape-v1-client-protocol.h"
#include "../protocols/xdg-activation-v1-client-protocol.h"
#include "../protocols/text-input-unstable-v3-client-protocol.h"

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

enum {
    KILN_MOD_SHIFT = 1 << 0,
    KILN_MOD_CTRL = 1 << 1,
    KILN_MOD_ALT = 1 << 2,
    KILN_MOD_SUPER = 1 << 3,
};

enum kiln_cursor {
    KILN_CURSOR_DEFAULT = 0,
    KILN_CURSOR_POINTER = 1,
    KILN_CURSOR_TEXT = 2,
    KILN_CURSOR_HIDDEN = 3,
};

/** One wl_pointer frame of scrolling. Values are in surface points (dx and dy, positive right and down), wheel notches
 * in 120ths, `source` is WL_POINTER_AXIS_SOURCE_* (wheel, finger, continuous, wheel tilt), and a stop marks the fingers
 * lifting off a touchpad. */
typedef struct {
    double dx;
    double dy;
    int32_t dx120;
    int32_t dy120;
    uint32_t source;
    bool stop_x;
    bool stop_y;
    bool natural;
    uint32_t time_ms;
} kiln_wl_axis_frame;

/** A key through the keymap: the evdev code, the keysym, the UTF-8 it types (empty for none), the modifiers held and
 * whether the keymap repeats it. */
typedef struct {
    uint32_t code;
    uint32_t keysym;
    char text[16];
    uint32_t modifiers;
    bool pressed;
    bool repeats;
} kiln_wl_key;

/** One `done` of the input method (text-input-v3), to apply in this order: the composition shown so far goes, the bytes
 * around the caret are deleted, `commit` is inserted, then `preedit` shows at the caret with its cursor at byte offsets
 * `preedit_cursor_begin` to `preedit_cursor_end` (both -1 to hide the caret). Strings are NULL for none. */
typedef struct {
    const char *preedit;
    int32_t preedit_cursor_begin;
    int32_t preedit_cursor_end;
    const char *commit;
    uint32_t delete_before;
    uint32_t delete_after;
} kiln_wl_text_input_event;

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
    void (*pointer_axis)(void *context, kiln_wl_axis_frame frame);
    void (*key)(void *context, kiln_wl_key key);
    void (*modifiers)(void *context, uint32_t modifiers);
    void (*repeat_info)(void *context, int32_t rate, int32_t delay);
    void (*keyboard_focus)(void *context, bool focused);
    void (*text_input)(void *context, kiln_wl_text_input_event event);
} kiln_wl_callbacks;

/** Runs a pressed key through the compose state, for dead keys and the Compose key: false while a sequence is being typed
 * or once it is cancelled, when the key does nothing, and a finished sequence's character and keysym written into `key`. */
bool kiln_compose_key(struct xkb_compose_state *state, kiln_wl_key *key);

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

/** Holds the screen awake over the window (idle-inhibit-unstable-v1); false when the compositor lacks the protocol. */
bool kiln_wl_inhibit_idle(kiln_wl *wl, bool inhibit);

/** Raises and focuses the window with an xdg-activation token (one a launcher handed a second launch); false when the
 * compositor has no xdg_activation_v1. */
bool kiln_wl_activate(kiln_wl *wl, const char *token);
/** Asks the compositor for an activation token for the window itself and activates with it, for a raise nobody launched. */
bool kiln_wl_raise(kiln_wl *wl);

/** Sets the pointer's cursor over the window (a link hand over clickable content, hidden while video plays). */
void kiln_wl_set_cursor(kiln_wl *wl, enum kiln_cursor cursor);
/** The physical size in millimetres of the screen the window is on (the first screen before it shows), as the screen's
 * EDID reports it; false when the compositor gives none (a projector, a virtual output). */
bool kiln_wl_output_size_mm(kiln_wl *wl, int32_t *width_mm, int32_t *height_mm);
/** Makes `text` the clipboard, as of the latest key or button press. */
bool kiln_wl_set_clipboard(kiln_wl *wl, const char *text);
/** The clipboard as UTF-8 text, to free, or NULL when it holds none; another app's clipboard is read for up to half a
 * second without an answer. */
char *kiln_wl_clipboard_text(kiln_wl *wl);

/** Turns the input method on for a focused text field (text-input-v3), or off when no field has the focus. Each newly
 * focused field enables it again; while the window lacks the keyboard the wish waits for it. */
void kiln_wl_text_input_enable(kiln_wl *wl, bool enabled);
/** Tells the input method about the focused field: the text around the caret, the caret and the selection's other end as
 * byte offsets into it, the caret's rectangle in surface points, and the field's content hint and purpose
 * (ZWP_TEXT_INPUT_V3_CONTENT_*). */
void kiln_wl_text_input_update(kiln_wl *wl, const char *surrounding, int32_t cursor, int32_t anchor, int32_t x, int32_t y, int32_t width,
                               int32_t height, uint32_t hint, uint32_t purpose);

/** Hands libdispatch's main-queue handle to the event loop, as CoreFoundation's run loop does. */
int kiln_dispatch_main_queue_handle(void);
void kiln_dispatch_drain_main_queue(void);

#endif
