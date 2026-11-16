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
/** Whether the window's buffers can be larger than it, cropped by `kiln_wl_crop_buffer` (the compositor has a viewporter). */
bool kiln_wl_can_crop_buffer(kiln_wl *wl);
/** Shows only the top-left `width` by `height` pixels of the buffers the window commits (wp_viewport's source), which
 * must lie inside the buffer committed next. */
void kiln_wl_crop_buffer(kiln_wl *wl, int32_t width, int32_t height);

uint32_t kiln_wl_color_features(kiln_wl *wl);

/** Describes the window surface as Windows-scRGB (BT.709 primaries, extended linear, 1.0 = 80 cd/m2). */
bool kiln_wl_describe_scrgb(kiln_wl *wl);

/** What the compositor prefers for the window's surface (color-management-v1's preferred image description): its transfer
 * function (the protocol's transfer_function value, 0 when it named none), the luminances of its signal and of the display
 * it targets in cd/m2, 0 when not given. The user's display calibration on the desktop reaches clients here. */
typedef struct {
    uint32_t transfer;
    double min_luminance;
    double max_luminance;
    double reference_luminance;
    double target_min_luminance;
    double target_max_luminance;
    double target_max_cll;
} kiln_display_color;

/** Reads the preferred description into `color`, waiting on the compositor; false without color management. */
bool kiln_wl_display_color(kiln_wl *wl, kiln_display_color *color);
/** Counts the compositor's announcements that the preferred description changed (the window moved to another screen, HDR
 * went on or off, the brightness or calibration changed), so a caller reads it again when the count moves. */
uint32_t kiln_wl_display_color_serial(kiln_wl *wl);

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
/** Makes `length` bytes of type `mime` ("image/png") the clipboard, as of the latest key or button press. */
bool kiln_wl_set_clipboard_data(kiln_wl *wl, const char *mime, const uint8_t *bytes, size_t length);
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

/** The name of the screen the window is on ("DP-3"), as KWin's output devices name it too; NULL before it shows. */
const char *kiln_wl_output_name(kiln_wl *wl);
/** The compositor's description of that screen (make, model and connector, as wl_output describes it); NULL when unknown. */
const char *kiln_wl_output_description(kiln_wl *wl);

/** KWin's output management on a connection of its own (kde_output_management_v2), for Match Content and its guard: the
 * modes, HDR and wide colour gamut of a screen, and switching them. Blocking; use it off the main thread. */
typedef struct kiln_display kiln_display;

enum { KILN_DISPLAY_MODES = 96 };

typedef struct {
    int32_t width;
    int32_t height;
    /** Millihertz. */
    int32_t refresh;
} kiln_display_mode;

typedef struct {
    kiln_display_mode current;
    bool hdr_capable;
    bool hdr;
    bool wide_color_gamut;
    /** The screen follows a fullscreen window's frame rate (variable refresh, KWin's policy Automatic or Always). */
    bool adaptive_sync;
    int mode_count;
    kiln_display_mode modes[KILN_DISPLAY_MODES];
} kiln_display_state;

/** Connects and reads the screens; NULL when the compositor has no output management (not KWin). */
kiln_display *kiln_display_open(void);
void kiln_display_close(kiln_display *display);
/** The state of the screen named `output`; false when there is none. */
bool kiln_display_read(kiln_display *display, const char *output, kiln_display_state *state);
/** Switches the screen to `mode` (a refresh of 0 keeps the mode) and HDR and wide colour gamut (-1 keeps each), waiting up
 * to five seconds for KWin; true when it applied or nothing needed changing. */
bool kiln_display_apply(kiln_display *display, const char *output, kiln_display_mode mode, int hdr, int wide_color_gamut);

/** An X11 window (through XWayland), for gamescope's Game Mode: Steam hands focus only to windows XWayland reports, so a
 * Wayland toplevel there is never shown. It takes the same callbacks as the Wayland window; there are no frame callbacks,
 * presentation feedback, colour management, input method or clipboard on it. */
typedef struct kiln_x11 kiln_x11;

/** Connects to the named X display (NULL for $DISPLAY). */
kiln_x11 *kiln_x11_connect(const char *name);
void kiln_x11_disconnect(kiln_x11 *x);
int kiln_x11_fd(kiln_x11 *x);
/** The `xcb_connection_t` and window, for a Vulkan surface. */
void *kiln_x11_connection(kiln_x11 *x);
uint32_t kiln_x11_window(kiln_x11 *x);
/** Creates and maps a window the size of the screen and reports it through `configure` before returning. `steam_app_id`,
 * when not 0, goes on the window as STEAM_GAME, which tells gamescope and Steam whose window it is. */
bool kiln_x11_create_window(kiln_x11 *x, const char *title, const char *app_id, uint32_t steam_app_id, kiln_wl_callbacks callbacks, void *context);
/** Handles every event the connection holds, then flushes; -1 once the connection has failed. */
int kiln_x11_pump(kiln_x11 *x);
void kiln_x11_flush(kiln_x11 *x);
void kiln_x11_set_fullscreen(kiln_x11 *x, bool fullscreen);
void kiln_x11_set_cursor(kiln_x11 *x, enum kiln_cursor cursor);
uint32_t kiln_x11_refresh_millihertz(kiln_x11 *x);

/** How gamescope composes the screen, as Steam set it on the root window: whether the output is HDR, the brightness SDR
 * content is shown at on an HDR output, and the gains Steam's brightness slider applies to SDR and to HDR content (in HDR
 * mode the slider scales content instead of the backlight). `display_nits` is the panel's brightness, 0 when not given. */
typedef struct {
    bool hdr;
    float sdr_on_hdr_nits;
    float sdr_gain;
    float hdr_gain;
    float display_nits;
} kiln_gamescope_color;

/** Reads gamescope's colour state; false outside gamescope. */
bool kiln_x11_gamescope_color(kiln_x11 *x, kiln_gamescope_color *out);
/** Moves whenever the colour state may have changed: the window was shown or came back from Steam's overlay, or Steam
 * changed one of gamescope's colour properties (the brightness slider, the HDR switch). */
uint32_t kiln_x11_color_serial(kiln_x11 *x);
/** The connection to gamescope's root XWayland server when the window lives on another one, to watch for those changes;
 * -1 when there is none (it opens with the first colour reading). `kiln_x11_pump` handles its events too. */
int kiln_x11_root_fd(kiln_x11 *x);

/** Hands libdispatch's main-queue handle to the event loop, as CoreFoundation's run loop does. */
int kiln_dispatch_main_queue_handle(void);
void kiln_dispatch_drain_main_queue(void);

#endif
