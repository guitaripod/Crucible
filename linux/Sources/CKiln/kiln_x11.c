#include "CKiln.h"

#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xcb/randr.h>
#include <xcb/xcb.h>
#include <xcb/xinput.h>
#include <xcb/xkb.h>
#include <xkbcommon/xkbcommon-x11.h>

enum { KILN_X11_TOUCHES = 10 };

/** A finger on the touchscreen, from XInput 2's touch events: where it went down and where it is now, in window pixels, and
 * whether it has moved far enough to be a drag rather than a tap. */
typedef struct {
    uint32_t id;
    bool active;
    bool dragging;
    double start_x;
    double start_y;
    double x;
    double y;
    uint32_t time_ms;
} kiln_x11_touch;

struct kiln_x11 {
    xcb_connection_t *connection;
    xcb_screen_t *screen;
    xcb_window_t window;
    xcb_atom_t wm_protocols;
    xcb_atom_t wm_delete_window;
    xcb_atom_t net_wm_state;
    xcb_atom_t net_wm_state_fullscreen;
    xcb_atom_t net_wm_name;
    xcb_atom_t net_wm_pid;
    xcb_atom_t utf8_string;
    xcb_atom_t steam_game;
    kiln_wl_callbacks callbacks;
    void *context;
    int32_t width;
    int32_t height;
    bool fullscreen;
    struct xkb_context *xkb;
    struct xkb_keymap *keymap;
    struct xkb_state *state;
    int32_t keyboard_device;
    uint8_t xkb_event_base;
    struct xkb_compose_table *compose_table;
    struct xkb_compose_state *compose_state;
    bool compose_loaded;
    /** X keycodes held down, so the server's autorepeat (made detectable) does not reach Kiln, which repeats by itself. */
    uint8_t held[32];
    uint8_t xinput_opcode;
    bool touch_events;
    kiln_x11_touch touches[KILN_X11_TOUCHES];
    xcb_cursor_t blank_cursor;
    enum kiln_cursor cursor;
    /** gamescope's root XWayland server (:0), where Steam writes the display's HDR state and brightness, opened on demand. */
    xcb_connection_t *root_connection;
    bool root_connection_tried;
    xcb_atom_t color_atoms[5];
    uint32_t color_serial;
};

static xcb_atom_t intern(xcb_connection_t *connection, const char *name) {
    xcb_intern_atom_reply_t *reply = xcb_intern_atom_reply(connection, xcb_intern_atom(connection, 0, (uint16_t) strlen(name), name), NULL);
    xcb_atom_t atom = reply ? reply->atom : XCB_ATOM_NONE;
    free(reply);
    return atom;
}

kiln_x11 *kiln_x11_connect(const char *name) {
    int screen_number = 0;
    xcb_connection_t *connection = xcb_connect(name, &screen_number);
    if (!connection || xcb_connection_has_error(connection)) {
        if (connection) xcb_disconnect(connection);
        return NULL;
    }
    kiln_x11 *x = calloc(1, sizeof(*x));
    x->connection = connection;
    xcb_screen_iterator_t screens = xcb_setup_roots_iterator(xcb_get_setup(connection));
    for (int i = 0; i < screen_number && screens.rem; i++) xcb_screen_next(&screens);
    x->screen = screens.data;
    x->wm_protocols = intern(connection, "WM_PROTOCOLS");
    x->wm_delete_window = intern(connection, "WM_DELETE_WINDOW");
    x->net_wm_state = intern(connection, "_NET_WM_STATE");
    x->net_wm_state_fullscreen = intern(connection, "_NET_WM_STATE_FULLSCREEN");
    x->net_wm_name = intern(connection, "_NET_WM_NAME");
    x->net_wm_pid = intern(connection, "_NET_WM_PID");
    x->utf8_string = intern(connection, "UTF8_STRING");
    x->steam_game = intern(connection, "STEAM_GAME");
    x->keyboard_device = -1;
    return x;
}

void kiln_x11_disconnect(kiln_x11 *x) {
    if (!x) return;
    if (x->root_connection) xcb_disconnect(x->root_connection);
    if (x->blank_cursor) xcb_free_cursor(x->connection, x->blank_cursor);
    if (x->window) xcb_destroy_window(x->connection, x->window);
    xcb_flush(x->connection);
    if (x->state) xkb_state_unref(x->state);
    if (x->keymap) xkb_keymap_unref(x->keymap);
    if (x->compose_state) xkb_compose_state_unref(x->compose_state);
    if (x->compose_table) xkb_compose_table_unref(x->compose_table);
    if (x->xkb) xkb_context_unref(x->xkb);
    xcb_disconnect(x->connection);
    free(x);
}

int kiln_x11_fd(kiln_x11 *x) {
    return xcb_get_file_descriptor(x->connection);
}

void *kiln_x11_connection(kiln_x11 *x) {
    return x->connection;
}

uint32_t kiln_x11_window(kiln_x11 *x) {
    return x->window;
}

/** Reads the keyboard's keymap and state from the server, which XKB then keeps up to date with its own events. */
static void load_keymap(kiln_x11 *x) {
    if (x->keyboard_device < 0) return;
    struct xkb_keymap *keymap = xkb_x11_keymap_new_from_device(x->xkb, x->connection, x->keyboard_device, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!keymap) return;
    struct xkb_state *state = xkb_x11_state_new_from_device(keymap, x->connection, x->keyboard_device);
    if (!state) {
        xkb_keymap_unref(keymap);
        return;
    }
    if (x->state) xkb_state_unref(x->state);
    if (x->keymap) xkb_keymap_unref(x->keymap);
    x->keymap = keymap;
    x->state = state;
}

/** XKB for the keyboard: its keymap, the events that keep it current, the server's repeat timing, and detectable
 * autorepeat so a held key sends one press and one release. */
static void set_up_keyboard(kiln_x11 *x) {
    x->xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!x->xkb) return;
    if (!xkb_x11_setup_xkb_extension(x->connection, XKB_X11_MIN_MAJOR_XKB_VERSION, XKB_X11_MIN_MINOR_XKB_VERSION,
                                     XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS, NULL, NULL, &x->xkb_event_base, NULL)) return;
    x->keyboard_device = xkb_x11_get_core_keyboard_device_id(x->connection);
    load_keymap(x);
    enum {
        events = XCB_XKB_EVENT_TYPE_NEW_KEYBOARD_NOTIFY | XCB_XKB_EVENT_TYPE_MAP_NOTIFY | XCB_XKB_EVENT_TYPE_STATE_NOTIFY,
        map_parts = XCB_XKB_MAP_PART_KEY_TYPES | XCB_XKB_MAP_PART_KEY_SYMS | XCB_XKB_MAP_PART_MODIFIER_MAP | XCB_XKB_MAP_PART_EXPLICIT_COMPONENTS
            | XCB_XKB_MAP_PART_KEY_ACTIONS | XCB_XKB_MAP_PART_VIRTUAL_MODS | XCB_XKB_MAP_PART_VIRTUAL_MOD_MAP,
    };
    xcb_xkb_select_events(x->connection, (xcb_xkb_device_spec_t) x->keyboard_device, events, 0, events, map_parts, map_parts, NULL);
    xcb_xkb_per_client_flags_reply_t *flags = xcb_xkb_per_client_flags_reply(x->connection,
        xcb_xkb_per_client_flags(x->connection, XCB_XKB_ID_USE_CORE_KBD, XCB_XKB_PER_CLIENT_FLAG_DETECTABLE_AUTO_REPEAT,
                                 XCB_XKB_PER_CLIENT_FLAG_DETECTABLE_AUTO_REPEAT, 0, 0, 0), NULL);
    free(flags);
    xcb_xkb_get_controls_reply_t *controls = xcb_xkb_get_controls_reply(x->connection, xcb_xkb_get_controls(x->connection, XCB_XKB_ID_USE_CORE_KBD), NULL);
    if (controls) {
        if (x->callbacks.repeat_info && controls->repeatInterval > 0)
            x->callbacks.repeat_info(x->context, (int32_t) (1000 / controls->repeatInterval), (int32_t) controls->repeatDelay);
        free(controls);
    }
}

/** Touch events from the touchscreen (XInput 2.2): with them selected the server sends no pointer emulation, so a tap and
 * a drag can be told apart and a drag scrolls like a touchpad instead of pressing a card. */
static void set_up_touch(kiln_x11 *x) {
    const xcb_query_extension_reply_t *extension = xcb_get_extension_data(x->connection, &xcb_input_id);
    if (!extension || !extension->present) return;
    xcb_input_xi_query_version_reply_t *version = xcb_input_xi_query_version_reply(x->connection,
        xcb_input_xi_query_version(x->connection, 2, 2), NULL);
    bool usable = version && (version->major_version > 2 || (version->major_version == 2 && version->minor_version >= 2));
    free(version);
    if (!usable) return;
    x->xinput_opcode = extension->major_opcode;
    struct {
        xcb_input_event_mask_t head;
        uint32_t mask;
    } selection = {
        .head = { .deviceid = XCB_INPUT_DEVICE_ALL_MASTER, .mask_len = 1 },
        .mask = XCB_INPUT_XI_EVENT_MASK_TOUCH_BEGIN | XCB_INPUT_XI_EVENT_MASK_TOUCH_UPDATE | XCB_INPUT_XI_EVENT_MASK_TOUCH_END,
    };
    xcb_void_cookie_t cookie = xcb_input_xi_select_events_checked(x->connection, x->window, 1, &selection.head);
    xcb_generic_error_t *error = xcb_request_check(x->connection, cookie);
    x->touch_events = error == NULL;
    free(error);
}

static void set_property(kiln_x11 *x, xcb_atom_t property, xcb_atom_t type, uint8_t format, uint32_t count, const void *data) {
    xcb_change_property(x->connection, XCB_PROP_MODE_REPLACE, x->window, property, type, format, count, data);
}

bool kiln_x11_create_window(kiln_x11 *x, const char *title, const char *app_id, uint32_t steam_app_id, kiln_wl_callbacks callbacks, void *context) {
    x->callbacks = callbacks;
    x->context = context;
    x->width = x->screen->width_in_pixels;
    x->height = x->screen->height_in_pixels;
    x->window = xcb_generate_id(x->connection);
    uint32_t values[] = {
        x->screen->black_pixel,
        XCB_EVENT_MASK_KEY_PRESS | XCB_EVENT_MASK_KEY_RELEASE | XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE
            | XCB_EVENT_MASK_POINTER_MOTION | XCB_EVENT_MASK_ENTER_WINDOW | XCB_EVENT_MASK_LEAVE_WINDOW | XCB_EVENT_MASK_FOCUS_CHANGE
            | XCB_EVENT_MASK_STRUCTURE_NOTIFY,
    };
    xcb_void_cookie_t created = xcb_create_window_checked(x->connection, XCB_COPY_FROM_PARENT, x->window, x->screen->root, 0, 0,
        (uint16_t) x->width, (uint16_t) x->height, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT, x->screen->root_visual,
        XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK, values);
    xcb_generic_error_t *error = xcb_request_check(x->connection, created);
    if (error) {
        free(error);
        x->window = 0;
        return false;
    }
    set_property(x, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8, (uint32_t) strlen(title), title);
    set_property(x, x->net_wm_name, x->utf8_string, 8, (uint32_t) strlen(title), title);
    size_t class_length = strlen(app_id) * 2 + 2;
    char *class_names = calloc(1, class_length);
    memcpy(class_names, app_id, strlen(app_id));
    memcpy(class_names + strlen(app_id) + 1, app_id, strlen(app_id));
    set_property(x, XCB_ATOM_WM_CLASS, XCB_ATOM_STRING, 8, (uint32_t) class_length, class_names);
    free(class_names);
    set_property(x, x->wm_protocols, XCB_ATOM_ATOM, 32, 1, &x->wm_delete_window);
    uint32_t pid = (uint32_t) getpid();
    set_property(x, x->net_wm_pid, XCB_ATOM_CARDINAL, 32, 1, &pid);
    if (steam_app_id) set_property(x, x->steam_game, XCB_ATOM_CARDINAL, 32, 1, &steam_app_id);
    if (x->fullscreen) set_property(x, x->net_wm_state, XCB_ATOM_ATOM, 32, 1, &x->net_wm_state_fullscreen);
    set_up_keyboard(x);
    set_up_touch(x);
    xcb_map_window(x->connection, x->window);
    xcb_flush(x->connection);
    x->color_serial++;
    if (x->callbacks.configure) x->callbacks.configure(x->context, x->width, x->height, KILN_STATE_ACTIVATED | (x->fullscreen ? KILN_STATE_FULLSCREEN : 0));
    return true;
}

static uint32_t modifier_mask(kiln_x11 *x) {
    uint32_t mask = 0;
    if (!x->state) return 0;
    if (xkb_state_mod_name_is_active(x->state, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) > 0) mask |= KILN_MOD_SHIFT;
    if (xkb_state_mod_name_is_active(x->state, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE) > 0) mask |= KILN_MOD_CTRL;
    if (xkb_state_mod_name_is_active(x->state, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE) > 0) mask |= KILN_MOD_ALT;
    if (xkb_state_mod_name_is_active(x->state, XKB_MOD_NAME_LOGO, XKB_STATE_MODS_EFFECTIVE) > 0) mask |= KILN_MOD_SUPER;
    return mask;
}

/** The compose sequences of the user's locale, as on Wayland. */
static void load_compose(kiln_x11 *x) {
    x->compose_loaded = true;
    if (!x->xkb) return;
    const char *locale = getenv("LC_ALL");
    if (!locale || !*locale) locale = getenv("LC_CTYPE");
    if (!locale || !*locale) locale = getenv("LANG");
    if (!locale || !*locale) locale = "C";
    x->compose_table = xkb_compose_table_new_from_locale(x->xkb, locale, XKB_COMPOSE_COMPILE_NO_FLAGS);
    if (x->compose_table) x->compose_state = xkb_compose_state_new(x->compose_table, XKB_COMPOSE_STATE_NO_FLAGS);
}

static void handle_key(kiln_x11 *x, xcb_keycode_t keycode, bool pressed) {
    uint8_t bit = (uint8_t) (1u << (keycode & 7));
    bool held = x->held[keycode >> 3] & bit;
    if (pressed && held) return;
    if (pressed) x->held[keycode >> 3] |= bit;
    else x->held[keycode >> 3] &= (uint8_t) ~bit;
    if (!x->callbacks.key) return;
    kiln_wl_key event = { .code = keycode >= 8 ? keycode - 8u : 0, .pressed = pressed };
    if (x->state) {
        event.keysym = xkb_state_key_get_one_sym(x->state, keycode);
        xkb_state_key_get_utf8(x->state, keycode, event.text, sizeof event.text);
        event.modifiers = modifier_mask(x);
        event.repeats = xkb_keymap_key_repeats(x->keymap, keycode);
        if (!x->compose_loaded) load_compose(x);
        if (event.pressed && x->compose_state && !kiln_compose_key(x->compose_state, &event)) return;
    }
    x->callbacks.key(x->context, event);
}

/** X's core buttons as the evdev codes Wayland reports; the wheel's buttons 4 to 7 become scroll frames instead. */
static void handle_button(kiln_x11 *x, uint8_t detail, bool pressed, uint32_t time) {
    if (detail >= 4 && detail <= 7) {
        if (!pressed || !x->callbacks.pointer_axis) return;
        kiln_wl_axis_frame frame = { .source = 0, .time_ms = time };
        int32_t sign = detail == 4 || detail == 6 ? -1 : 1;
        if (detail <= 5) {
            frame.dy120 = sign * 120;
            frame.dy = sign * 15.0;
        } else {
            frame.dx120 = sign * 120;
            frame.dx = sign * 15.0;
        }
        x->callbacks.pointer_axis(x->context, frame);
        return;
    }
    uint32_t code;
    switch (detail) {
    case 1: code = BTN_LEFT; break;
    case 2: code = BTN_MIDDLE; break;
    case 3: code = BTN_RIGHT; break;
    case 8: code = BTN_SIDE; break;
    case 9: code = BTN_EXTRA; break;
    default: return;
    }
    if (x->callbacks.pointer_button) x->callbacks.pointer_button(x->context, code, pressed);
}

static double fixed_to_double(xcb_input_fp1616_t value) {
    return (double) value / 65536.0;
}

/** How far a finger travels, in window pixels, before a touch is a drag. */
static const double drag_threshold = 12;

static kiln_x11_touch *find_touch(kiln_x11 *x, uint32_t id, bool create) {
    for (int i = 0; i < KILN_X11_TOUCHES; i++) {
        if (x->touches[i].active && x->touches[i].id == id) return &x->touches[i];
    }
    if (!create) return NULL;
    for (int i = 0; i < KILN_X11_TOUCHES; i++) {
        if (!x->touches[i].active) return &x->touches[i];
    }
    return NULL;
}

static bool is_primary_touch(kiln_x11 *x, kiln_x11_touch *touch) {
    for (int i = 0; i < KILN_X11_TOUCHES; i++) {
        if (x->touches[i].active) return &x->touches[i] == touch;
    }
    return false;
}

/** The first finger drives the window: it moves the pointer, a short touch clicks where it lifted, and a drag scrolls the
 * content under it with the fingers' own speed (a touchpad's finger scroll, so momentum follows the lift). Further
 * fingers are ignored. */
static void handle_touch(kiln_x11 *x, xcb_input_touch_begin_event_t *event) {
    uint32_t id = event->detail;
    double px = fixed_to_double(event->event_x);
    double py = fixed_to_double(event->event_y);
    uint32_t time = event->time;
    switch (event->event_type) {
    case XCB_INPUT_TOUCH_BEGIN: {
        kiln_x11_touch *touch = find_touch(x, id, true);
        if (!touch) return;
        *touch = (kiln_x11_touch) { .id = id, .active = true, .start_x = px, .start_y = py, .x = px, .y = py, .time_ms = time };
        if (is_primary_touch(x, touch) && x->callbacks.pointer_motion) x->callbacks.pointer_motion(x->context, px, py);
        break;
    }
    case XCB_INPUT_TOUCH_UPDATE: {
        kiln_x11_touch *touch = find_touch(x, id, false);
        if (!touch || !is_primary_touch(x, touch)) return;
        double dx = px - touch->x;
        double dy = py - touch->y;
        if (!touch->dragging) {
            double tx = px - touch->start_x;
            double ty = py - touch->start_y;
            if (tx * tx + ty * ty < drag_threshold * drag_threshold) return;
            touch->dragging = true;
            dx = px - touch->start_x;
            dy = py - touch->start_y;
        }
        touch->x = px;
        touch->y = py;
        touch->time_ms = time;
        if (x->callbacks.pointer_axis) {
            kiln_wl_axis_frame frame = { .dx = -dx, .dy = -dy, .source = 1, .time_ms = time };
            x->callbacks.pointer_axis(x->context, frame);
        }
        break;
    }
    case XCB_INPUT_TOUCH_END: {
        kiln_x11_touch *touch = find_touch(x, id, false);
        if (!touch) return;
        bool primary = is_primary_touch(x, touch);
        bool dragging = touch->dragging;
        touch->active = false;
        if (!primary) return;
        if (dragging) {
            if (x->callbacks.pointer_axis) {
                kiln_wl_axis_frame frame = { .source = 1, .stop_x = true, .stop_y = true, .time_ms = time };
                x->callbacks.pointer_axis(x->context, frame);
            }
        } else if (x->callbacks.pointer_button) {
            if (x->callbacks.pointer_motion) x->callbacks.pointer_motion(x->context, touch->start_x, touch->start_y);
            x->callbacks.pointer_button(x->context, BTN_LEFT, true);
            x->callbacks.pointer_button(x->context, BTN_LEFT, false);
        }
        break;
    }
    default:
        break;
    }
}

static void handle_xkb(kiln_x11 *x, xcb_generic_event_t *event) {
    union {
        struct {
            uint8_t response_type;
            uint8_t xkbType;
            uint16_t sequence;
            xcb_timestamp_t time;
            uint8_t deviceID;
        } any;
        xcb_xkb_new_keyboard_notify_event_t new_keyboard;
        xcb_xkb_map_notify_event_t map;
        xcb_xkb_state_notify_event_t state;
    } *xkb = (void *) event;
    if (xkb->any.deviceID != x->keyboard_device) return;
    switch (xkb->any.xkbType) {
    case XCB_XKB_NEW_KEYBOARD_NOTIFY:
        if (xkb->new_keyboard.changed & XCB_XKB_NKN_DETAIL_KEYCODES) load_keymap(x);
        break;
    case XCB_XKB_MAP_NOTIFY:
        load_keymap(x);
        break;
    case XCB_XKB_STATE_NOTIFY:
        if (!x->state) break;
        xkb_state_update_mask(x->state, xkb->state.baseMods, xkb->state.latchedMods, xkb->state.lockedMods, (xkb_layout_index_t) xkb->state.baseGroup,
                              (xkb_layout_index_t) xkb->state.latchedGroup, xkb->state.lockedGroup);
        if (x->callbacks.modifiers) x->callbacks.modifiers(x->context, modifier_mask(x));
        break;
    default:
        break;
    }
}

static void handle_event(kiln_x11 *x, xcb_generic_event_t *event) {
    uint8_t type = event->response_type & 0x7f;
    if (x->xkb && type == x->xkb_event_base) {
        handle_xkb(x, event);
        return;
    }
    switch (type) {
    case XCB_CONFIGURE_NOTIFY: {
        xcb_configure_notify_event_t *configure = (void *) event;
        if (configure->window != x->window) break;
        if (configure->width == x->width && configure->height == x->height) break;
        x->width = configure->width;
        x->height = configure->height;
        if (x->callbacks.configure) x->callbacks.configure(x->context, x->width, x->height, KILN_STATE_ACTIVATED | (x->fullscreen ? KILN_STATE_FULLSCREEN : 0));
        break;
    }
    case XCB_KEY_PRESS:
    case XCB_KEY_RELEASE: {
        xcb_key_press_event_t *key = (void *) event;
        handle_key(x, key->detail, type == XCB_KEY_PRESS);
        break;
    }
    case XCB_BUTTON_PRESS:
    case XCB_BUTTON_RELEASE: {
        xcb_button_press_event_t *button = (void *) event;
        if (x->callbacks.pointer_motion) x->callbacks.pointer_motion(x->context, button->event_x, button->event_y);
        handle_button(x, button->detail, type == XCB_BUTTON_PRESS, button->time);
        break;
    }
    case XCB_MOTION_NOTIFY: {
        xcb_motion_notify_event_t *motion = (void *) event;
        if (x->callbacks.pointer_motion) x->callbacks.pointer_motion(x->context, motion->event_x, motion->event_y);
        break;
    }
    case XCB_ENTER_NOTIFY: {
        xcb_enter_notify_event_t *enter = (void *) event;
        if (x->callbacks.pointer_motion) x->callbacks.pointer_motion(x->context, enter->event_x, enter->event_y);
        break;
    }
    case XCB_LEAVE_NOTIFY:
        if (x->callbacks.pointer_leave) x->callbacks.pointer_leave(x->context);
        break;
    case XCB_FOCUS_IN:
    case XCB_FOCUS_OUT: {
        xcb_focus_in_event_t *focus = (void *) event;
        if (focus->detail == XCB_NOTIFY_DETAIL_POINTER) break;
        if (type == XCB_FOCUS_OUT) memset(x->held, 0, sizeof x->held);
        else x->color_serial++;
        if (x->callbacks.keyboard_focus) x->callbacks.keyboard_focus(x->context, type == XCB_FOCUS_IN);
        break;
    }
    case XCB_CLIENT_MESSAGE: {
        xcb_client_message_event_t *message = (void *) event;
        if (message->type == x->wm_protocols && message->data.data32[0] == x->wm_delete_window && x->callbacks.close)
            x->callbacks.close(x->context);
        break;
    }
    case XCB_GE_GENERIC: {
        xcb_ge_generic_event_t *generic = (void *) event;
        if (x->touch_events && generic->extension == x->xinput_opcode) {
            if (generic->event_type == XCB_INPUT_TOUCH_BEGIN || generic->event_type == XCB_INPUT_TOUCH_UPDATE || generic->event_type == XCB_INPUT_TOUCH_END)
                handle_touch(x, (xcb_input_touch_begin_event_t *) event);
        }
        break;
    }
    default:
        break;
    }
}

static bool is_color_atom(kiln_x11 *x, xcb_atom_t atom) {
    for (size_t i = 0; i < sizeof x->color_atoms / sizeof *x->color_atoms; i++) {
        if (x->color_atoms[i] != XCB_ATOM_NONE && x->color_atoms[i] == atom) return true;
    }
    return false;
}

/** Moves the colour serial when Steam changes one of gamescope's colour properties on the root window (the brightness
 * slider in HDR, the HDR switch, dimming). */
static void handle_root_events(kiln_x11 *x, xcb_connection_t *connection) {
    xcb_generic_event_t *event;
    while ((event = xcb_poll_for_event(connection))) {
        if ((event->response_type & 0x7f) == XCB_PROPERTY_NOTIFY && is_color_atom(x, ((xcb_property_notify_event_t *) event)->atom)) x->color_serial++;
        else if (connection == x->connection) handle_event(x, event);
        free(event);
    }
}

int kiln_x11_pump(kiln_x11 *x) {
    handle_root_events(x, x->connection);
    xcb_flush(x->connection);
    if (x->root_connection) handle_root_events(x, x->root_connection);
    return xcb_connection_has_error(x->connection) ? -1 : 0;
}

void kiln_x11_flush(kiln_x11 *x) {
    xcb_flush(x->connection);
}

void kiln_x11_set_fullscreen(kiln_x11 *x, bool fullscreen) {
    x->fullscreen = fullscreen;
    if (!x->window) return;
    xcb_client_message_event_t message = {
        .response_type = XCB_CLIENT_MESSAGE,
        .format = 32,
        .window = x->window,
        .type = x->net_wm_state,
        .data.data32 = { fullscreen ? 1 : 0, x->net_wm_state_fullscreen, 0, 1, 0 },
    };
    xcb_send_event(x->connection, 0, x->screen->root, XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY, (const char *) &message);
    xcb_flush(x->connection);
}

/** Shows the screen's default arrow over the window, or nothing; X has no shape names, so a link hand is the arrow. */
void kiln_x11_set_cursor(kiln_x11 *x, enum kiln_cursor cursor) {
    if (!x->window || cursor == x->cursor) return;
    x->cursor = cursor;
    uint32_t value = XCB_NONE;
    if (cursor == KILN_CURSOR_HIDDEN) {
        if (!x->blank_cursor) {
            xcb_pixmap_t pixmap = xcb_generate_id(x->connection);
            xcb_create_pixmap(x->connection, 1, pixmap, x->window, 1, 1);
            x->blank_cursor = xcb_generate_id(x->connection);
            xcb_create_cursor(x->connection, x->blank_cursor, pixmap, pixmap, 0, 0, 0, 0, 0, 0, 0, 0);
            xcb_free_pixmap(x->connection, pixmap);
        }
        value = x->blank_cursor;
    }
    xcb_change_window_attributes(x->connection, x->window, XCB_CW_CURSOR, &value);
    xcb_flush(x->connection);
}

/** The refresh rate of the first lit screen in millihertz (RandR), 0 when the server does not say. */
uint32_t kiln_x11_refresh_millihertz(kiln_x11 *x) {
    xcb_randr_get_screen_resources_current_reply_t *resources = xcb_randr_get_screen_resources_current_reply(x->connection,
        xcb_randr_get_screen_resources_current(x->connection, x->screen->root), NULL);
    if (!resources) return 0;
    uint32_t refresh = 0;
    xcb_randr_crtc_t *crtcs = xcb_randr_get_screen_resources_current_crtcs(resources);
    xcb_randr_mode_info_t *modes = xcb_randr_get_screen_resources_current_modes(resources);
    int mode_count = xcb_randr_get_screen_resources_current_modes_length(resources);
    for (int i = 0; i < resources->num_crtcs && !refresh; i++) {
        xcb_randr_get_crtc_info_reply_t *crtc = xcb_randr_get_crtc_info_reply(x->connection,
            xcb_randr_get_crtc_info(x->connection, crtcs[i], resources->config_timestamp), NULL);
        if (!crtc) continue;
        for (int m = 0; m < mode_count && crtc->mode; m++) {
            if (modes[m].id != crtc->mode || !modes[m].htotal || !modes[m].vtotal) continue;
            refresh = (uint32_t) ((uint64_t) modes[m].dot_clock * 1000 / ((uint64_t) modes[m].htotal * modes[m].vtotal));
        }
        free(crtc);
    }
    free(resources);
    return refresh;
}

static const char *const color_atom_names[5] = {
    "GAMESCOPE_DISPLAY_HDR_ENABLED", "GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS", "GAMESCOPE_SDR_INPUT_GAIN", "GAMESCOPE_HDR_INPUT_GAIN",
    "GAMESCOPE_INTERNAL_DISPLAY_BRIGHTNESS",
};

static bool read_cardinal(xcb_connection_t *connection, xcb_window_t root, const char *name, uint32_t *value) {
    xcb_atom_t atom = intern(connection, name);
    if (atom == XCB_ATOM_NONE) return false;
    xcb_get_property_reply_t *reply = xcb_get_property_reply(connection, xcb_get_property(connection, 0, root, atom, XCB_ATOM_CARDINAL, 0, 1), NULL);
    bool found = reply && reply->format == 32 && xcb_get_property_value_length(reply) >= 4;
    if (found) memcpy(value, xcb_get_property_value(reply), 4);
    free(reply);
    return found;
}

static float as_float(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

/** Reads gamescope's colour state from the server that holds it: this window's own, or the root server :0 when the window
 * lives on a second XWayland (Steam starts titles on :1). */
static bool read_gamescope_color(xcb_connection_t *connection, kiln_gamescope_color *out) {
    xcb_window_t root = xcb_setup_roots_iterator(xcb_get_setup(connection)).data->root;
    uint32_t hdr = 0;
    if (!read_cardinal(connection, root, "GAMESCOPE_DISPLAY_HDR_ENABLED", &hdr)) return false;
    uint32_t bits = 0;
    *out = (kiln_gamescope_color) { .hdr = hdr != 0, .sdr_on_hdr_nits = 203, .sdr_gain = 1, .hdr_gain = 1, .display_nits = 0 };
    if (read_cardinal(connection, root, "GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS", &bits) && as_float(bits) > 1) out->sdr_on_hdr_nits = as_float(bits);
    if (read_cardinal(connection, root, "GAMESCOPE_SDR_INPUT_GAIN", &bits) && as_float(bits) > 0) out->sdr_gain = as_float(bits);
    if (read_cardinal(connection, root, "GAMESCOPE_HDR_INPUT_GAIN", &bits) && as_float(bits) > 0) out->hdr_gain = as_float(bits);
    if (read_cardinal(connection, root, "GAMESCOPE_INTERNAL_DISPLAY_BRIGHTNESS", &bits) && as_float(bits) > 1) out->display_nits = as_float(bits);
    return true;
}

/** Asks `connection`'s root window for property changes, so the colour state is read again whenever Steam moves it. */
static void watch_root(kiln_x11 *x, xcb_connection_t *connection) {
    xcb_window_t root = xcb_setup_roots_iterator(xcb_get_setup(connection)).data->root;
    for (size_t i = 0; i < sizeof x->color_atoms / sizeof *x->color_atoms; i++) x->color_atoms[i] = intern(connection, color_atom_names[i]);
    uint32_t mask = XCB_EVENT_MASK_PROPERTY_CHANGE;
    xcb_change_window_attributes(connection, root, XCB_CW_EVENT_MASK, &mask);
    xcb_flush(connection);
}

bool kiln_x11_gamescope_color(kiln_x11 *x, kiln_gamescope_color *out) {
    if (read_gamescope_color(x->connection, out)) {
        if (!x->root_connection_tried) {
            x->root_connection_tried = true;
            watch_root(x, x->connection);
        }
        return true;
    }
    if (!x->root_connection_tried) {
        x->root_connection_tried = true;
        xcb_connection_t *root = xcb_connect(":0", NULL);
        if (root && !xcb_connection_has_error(root)) {
            x->root_connection = root;
            watch_root(x, root);
        } else if (root) {
            xcb_disconnect(root);
        }
    }
    return x->root_connection && read_gamescope_color(x->root_connection, out);
}

int kiln_x11_root_fd(kiln_x11 *x) {
    return x->root_connection ? xcb_get_file_descriptor(x->root_connection) : -1;
}

uint32_t kiln_x11_color_serial(kiln_x11 *x) {
    return x->color_serial;
}
