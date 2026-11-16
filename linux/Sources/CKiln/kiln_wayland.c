#include "CKiln.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <linux/input-event-codes.h>
#include <sys/mman.h>

enum { KILN_MAX_OUTPUTS = 8 };

/** A screen the compositor announced, with the physical size its EDID reports. */
typedef struct {
    struct wl_output *output;
    uint32_t name;
    int32_t width_mm;
    int32_t height_mm;
    char connector[64];
} kiln_output;

struct kiln_wl {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct xdg_wm_base *wm_base;
    struct zxdg_decoration_manager_v1 *decoration_manager;
    struct wp_color_manager_v1 *color_manager;
    uint32_t color_features;
    struct wp_presentation *presentation;
    struct wp_fifo_manager_v1 *fifo_manager;
    struct wp_fractional_scale_manager_v1 *fractional_manager;
    struct wp_viewporter *viewporter;
    struct zwp_idle_inhibit_manager_v1 *idle_manager;
    struct wp_cursor_shape_manager_v1 *cursor_manager;
    struct xdg_activation_v1 *activation;
    struct wl_seat *seat;
    struct wl_pointer *pointer;
    struct wl_keyboard *keyboard;
    struct wp_cursor_shape_device_v1 *cursor_device;
    uint32_t pointer_serial;
    /** The latest key or button press, which a clipboard change must name. */
    uint32_t input_serial;
    struct wl_data_device_manager *data_manager;
    struct wl_data_device *data_device;
    /** What other clients offer as the clipboard, and the drag offered while one is over the window. */
    struct wl_data_offer *selection_offer;
    struct wl_data_offer *drag_offer;
    /** The clipboard this app set, answered from memory while it holds the selection. */
    struct wl_data_source *own_source;
    char *own_text;
    kiln_output outputs[KILN_MAX_OUTPUTS];
    /** The screen the window was last shown on. */
    struct wl_output *current_output;
    struct zwp_text_input_manager_v3 *text_input_manager;
    struct zwp_text_input_v3 *text_input;
    /** Whether the seat's text-input focus is on the window, and whether a text field there wants the input method. */
    bool text_input_entered;
    bool text_input_wanted;
    /** The field's state as last told, sent again on every enable. */
    char *text_input_surrounding;
    int32_t text_input_cursor;
    int32_t text_input_anchor;
    int32_t text_input_rect[4];
    uint32_t text_input_hint;
    uint32_t text_input_purpose;
    /** What the input method sent since its last done. */
    char *pending_preedit;
    int32_t pending_cursor_begin;
    int32_t pending_cursor_end;
    char *pending_commit;
    uint32_t pending_delete_before;
    uint32_t pending_delete_after;
    uint32_t cursor_shape;
    struct xkb_context *xkb;
    struct xkb_keymap *xkb_keymap;
    struct xkb_compose_table *compose_table;
    struct xkb_compose_state *compose_state;
    bool compose_loaded;
    struct xkb_state *xkb_state;
    struct {
        double value[2];
        int32_t value120[2];
        bool stop[2];
        bool inverted[2];
        uint32_t source;
        uint32_t time;
        bool pending;
    } axis;

    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct zxdg_toplevel_decoration_v1 *decoration;
    struct wp_color_management_surface_v1 *color_surface;
    struct wp_fifo_v1 *fifo;
    struct wp_fractional_scale_v1 *fractional;
    struct wp_viewport *viewport;
    struct zwp_idle_inhibitor_v1 *inhibitor;

    kiln_wl_callbacks callbacks;
    void *context;
    bool configured;
    int32_t pending_width;
    int32_t pending_height;
    uint32_t pending_states;

    int description_state;
};

static uint32_t kiln_min(uint32_t a, uint32_t b) { return a < b ? a : b; }

static void color_supported_intent(void *data, struct wp_color_manager_v1 *manager, uint32_t intent) {}

static void color_supported_feature(void *data, struct wp_color_manager_v1 *manager, uint32_t feature) {
    kiln_wl *wl = data;
    switch (feature) {
    case WP_COLOR_MANAGER_V1_FEATURE_PARAMETRIC: wl->color_features |= KILN_COLOR_PARAMETRIC; break;
    case WP_COLOR_MANAGER_V1_FEATURE_WINDOWS_SCRGB: wl->color_features |= KILN_COLOR_SCRGB; break;
    case WP_COLOR_MANAGER_V1_FEATURE_SET_MASTERING_DISPLAY_PRIMARIES: wl->color_features |= KILN_COLOR_MASTERING; break;
    case WP_COLOR_MANAGER_V1_FEATURE_SET_LUMINANCES: wl->color_features |= KILN_COLOR_LUMINANCES; break;
    default: break;
    }
}

static void color_supported_tf(void *data, struct wp_color_manager_v1 *manager, uint32_t tf) {
    kiln_wl *wl = data;
    if (tf == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ) wl->color_features |= KILN_COLOR_PQ;
}

static void color_supported_primaries(void *data, struct wp_color_manager_v1 *manager, uint32_t primaries) {
    kiln_wl *wl = data;
    if (primaries == WP_COLOR_MANAGER_V1_PRIMARIES_BT2020) wl->color_features |= KILN_COLOR_BT2020;
}

static void color_done(void *data, struct wp_color_manager_v1 *manager) {}

static const struct wp_color_manager_v1_listener color_listener = {
    .supported_intent = color_supported_intent,
    .supported_feature = color_supported_feature,
    .supported_tf_named = color_supported_tf,
    .supported_primaries_named = color_supported_primaries,
    .done = color_done,
};

static void wm_ping(void *data, struct xdg_wm_base *base, uint32_t serial) { xdg_wm_base_pong(base, serial); }

static const struct xdg_wm_base_listener wm_listener = { .ping = wm_ping };

static void pointer_enter(void *data, struct wl_pointer *pointer, uint32_t serial, struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y) {
    kiln_wl *wl = data;
    wl->pointer_serial = serial;
    if (wl->cursor_shape == 0) {
        wl_pointer_set_cursor(pointer, serial, NULL, 0, 0);
    } else if (wl->cursor_device) {
        wp_cursor_shape_device_v1_set_shape(wl->cursor_device, serial, wl->cursor_shape);
    }
    if (wl->callbacks.pointer_motion) wl->callbacks.pointer_motion(wl->context, wl_fixed_to_double(x), wl_fixed_to_double(y));
}

static void pointer_leave(void *data, struct wl_pointer *pointer, uint32_t serial, struct wl_surface *surface) {
    kiln_wl *wl = data;
    if (wl->callbacks.pointer_leave) wl->callbacks.pointer_leave(wl->context);
}

static void pointer_motion(void *data, struct wl_pointer *pointer, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    kiln_wl *wl = data;
    if (wl->callbacks.pointer_motion) wl->callbacks.pointer_motion(wl->context, wl_fixed_to_double(x), wl_fixed_to_double(y));
}

static void pointer_button(void *data, struct wl_pointer *pointer, uint32_t serial, uint32_t time, uint32_t button, uint32_t state) {
    kiln_wl *wl = data;
    if (state == WL_POINTER_BUTTON_STATE_PRESSED) wl->input_serial = serial;
    if (wl->callbacks.pointer_button) wl->callbacks.pointer_button(wl->context, button, state == WL_POINTER_BUTTON_STATE_PRESSED);
}

static void pointer_axis(void *data, struct wl_pointer *pointer, uint32_t time, uint32_t axis, wl_fixed_t value) {
    kiln_wl *wl = data;
    if (axis > 1) return;
    wl->axis.value[axis] += wl_fixed_to_double(value);
    wl->axis.time = time;
    wl->axis.pending = true;
}

static void pointer_axis_source(void *data, struct wl_pointer *pointer, uint32_t source) {
    kiln_wl *wl = data;
    wl->axis.source = source;
}

static void pointer_axis_stop(void *data, struct wl_pointer *pointer, uint32_t time, uint32_t axis) {
    kiln_wl *wl = data;
    if (axis > 1) return;
    wl->axis.stop[axis] = true;
    wl->axis.time = time;
    wl->axis.pending = true;
}

static void pointer_axis_discrete(void *data, struct wl_pointer *pointer, uint32_t axis, int32_t discrete) {}

static void pointer_axis_value120(void *data, struct wl_pointer *pointer, uint32_t axis, int32_t value120) {
    kiln_wl *wl = data;
    if (axis > 1) return;
    wl->axis.value120[axis] += value120;
    wl->axis.pending = true;
}

static void pointer_axis_direction(void *data, struct wl_pointer *pointer, uint32_t axis, uint32_t direction) {
    kiln_wl *wl = data;
    if (axis > 1) return;
    wl->axis.inverted[axis] = direction == WL_POINTER_AXIS_RELATIVE_DIRECTION_INVERTED;
}

/** Hands one frame of scrolling to the owner: both axes together, with the device that produced them and whether the
 * fingers lifted, so the owner can tell a wheel's notches from a touchpad's glide and start momentum at the lift. */
static void pointer_frame(void *data, struct wl_pointer *pointer) {
    kiln_wl *wl = data;
    if (!wl->axis.pending) return;
    if (wl->callbacks.pointer_axis) {
        kiln_wl_axis_frame frame = {
            .dx = wl->axis.value[1],
            .dy = wl->axis.value[0],
            .dx120 = wl->axis.value120[1],
            .dy120 = wl->axis.value120[0],
            .source = wl->axis.source,
            .stop_x = wl->axis.stop[1],
            .stop_y = wl->axis.stop[0],
            .natural = wl->axis.inverted[0],
            .time_ms = wl->axis.time,
        };
        wl->callbacks.pointer_axis(wl->context, frame);
    }
    memset(&wl->axis, 0, sizeof wl->axis);
}

static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
    .frame = pointer_frame,
    .axis_source = pointer_axis_source,
    .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_discrete,
    .axis_value120 = pointer_axis_value120,
    .axis_relative_direction = pointer_axis_direction,
};

static void keyboard_keymap(void *data, struct wl_keyboard *keyboard, uint32_t format, int32_t fd, uint32_t size) {
    kiln_wl *wl = data;
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
        close(fd);
        return;
    }
    char *text = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (text == MAP_FAILED) return;
    struct xkb_keymap *keymap = xkb_keymap_new_from_string(wl->xkb, text, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(text, size);
    if (!keymap) return;
    struct xkb_state *state = xkb_state_new(keymap);
    if (!state) {
        xkb_keymap_unref(keymap);
        return;
    }
    if (wl->xkb_state) xkb_state_unref(wl->xkb_state);
    if (wl->xkb_keymap) xkb_keymap_unref(wl->xkb_keymap);
    wl->xkb_keymap = keymap;
    wl->xkb_state = state;
}

static uint32_t keyboard_modifier_mask(kiln_wl *wl) {
    if (!wl->xkb_state) return 0;
    uint32_t mask = 0;
    if (xkb_state_mod_name_is_active(wl->xkb_state, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) > 0) mask |= KILN_MOD_SHIFT;
    if (xkb_state_mod_name_is_active(wl->xkb_state, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE) > 0) mask |= KILN_MOD_CTRL;
    if (xkb_state_mod_name_is_active(wl->xkb_state, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE) > 0) mask |= KILN_MOD_ALT;
    if (xkb_state_mod_name_is_active(wl->xkb_state, XKB_MOD_NAME_LOGO, XKB_STATE_MODS_EFFECTIVE) > 0) mask |= KILN_MOD_SUPER;
    return mask;
}

static void keyboard_enter(void *data, struct wl_keyboard *keyboard, uint32_t serial, struct wl_surface *surface, struct wl_array *keys) {
    kiln_wl *wl = data;
    wl->input_serial = serial;
    if (wl->callbacks.keyboard_focus) wl->callbacks.keyboard_focus(wl->context, true);
}

static void keyboard_leave(void *data, struct wl_keyboard *keyboard, uint32_t serial, struct wl_surface *surface) {
    kiln_wl *wl = data;
    if (wl->callbacks.keyboard_focus) wl->callbacks.keyboard_focus(wl->context, false);
}

/** Translates an evdev key through the keymap into a keysym, the text it types and the modifiers held, and says whether
 * the keymap lets it repeat. */
bool kiln_compose_key(struct xkb_compose_state *state, kiln_wl_key *key) {
    if (xkb_compose_state_feed(state, key->keysym) != XKB_COMPOSE_FEED_ACCEPTED) return true;
    switch (xkb_compose_state_get_status(state)) {
    case XKB_COMPOSE_COMPOSING:
        return false;
    case XKB_COMPOSE_COMPOSED: {
        xkb_compose_state_get_utf8(state, key->text, sizeof key->text);
        xkb_keysym_t composed = xkb_compose_state_get_one_sym(state);
        if (composed != XKB_KEY_NoSymbol) key->keysym = composed;
        xkb_compose_state_reset(state);
        return true;
    }
    case XKB_COMPOSE_CANCELLED:
        xkb_compose_state_reset(state);
        return false;
    default:
        return true;
    }
}

/** The compose sequences of the user's locale, as GTK and Qt read them (~/.XCompose included). */
static void load_compose(kiln_wl *wl) {
    wl->compose_loaded = true;
    const char *locale = getenv("LC_ALL");
    if (!locale || !*locale) locale = getenv("LC_CTYPE");
    if (!locale || !*locale) locale = getenv("LANG");
    if (!locale || !*locale) locale = "C";
    wl->compose_table = xkb_compose_table_new_from_locale(wl->xkb, locale, XKB_COMPOSE_COMPILE_NO_FLAGS);
    if (wl->compose_table) wl->compose_state = xkb_compose_state_new(wl->compose_table, XKB_COMPOSE_STATE_NO_FLAGS);
}

static void keyboard_key(void *data, struct wl_keyboard *keyboard, uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
    kiln_wl *wl = data;
    if (state == WL_KEYBOARD_KEY_STATE_PRESSED) wl->input_serial = serial;
    if (!wl->callbacks.key) return;
    kiln_wl_key event = { .code = key, .pressed = state == WL_KEYBOARD_KEY_STATE_PRESSED };
    if (wl->xkb_state) {
        xkb_keycode_t code = key + 8;
        event.keysym = xkb_state_key_get_one_sym(wl->xkb_state, code);
        xkb_state_key_get_utf8(wl->xkb_state, code, event.text, sizeof event.text);
        event.modifiers = keyboard_modifier_mask(wl);
        event.repeats = xkb_keymap_key_repeats(wl->xkb_keymap, code);
        if (!wl->compose_loaded) load_compose(wl);
        if (event.pressed && wl->compose_state && !kiln_compose_key(wl->compose_state, &event)) return;
    }
    wl->callbacks.key(wl->context, event);
}

static void keyboard_modifiers(void *data, struct wl_keyboard *keyboard, uint32_t serial, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
    kiln_wl *wl = data;
    if (!wl->xkb_state) return;
    xkb_state_update_mask(wl->xkb_state, depressed, latched, locked, 0, 0, group);
    if (wl->callbacks.modifiers) wl->callbacks.modifiers(wl->context, keyboard_modifier_mask(wl));
}

static void keyboard_repeat(void *data, struct wl_keyboard *keyboard, int32_t rate, int32_t delay) {
    kiln_wl *wl = data;
    if (wl->callbacks.repeat_info) wl->callbacks.repeat_info(wl->context, rate, delay);
}

static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers,
    .repeat_info = keyboard_repeat,
};

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t capabilities) {
    kiln_wl *wl = data;
    if ((capabilities & WL_SEAT_CAPABILITY_POINTER) && !wl->pointer) {
        wl->pointer = wl_seat_get_pointer(seat);
        wl_pointer_add_listener(wl->pointer, &pointer_listener, wl);
        if (wl->cursor_manager) wl->cursor_device = wp_cursor_shape_manager_v1_get_pointer(wl->cursor_manager, wl->pointer);
    }
    if ((capabilities & WL_SEAT_CAPABILITY_KEYBOARD) && !wl->keyboard) {
        wl->keyboard = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(wl->keyboard, &keyboard_listener, wl);
    }
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {}

static const struct wl_seat_listener seat_listener = { .capabilities = seat_capabilities, .name = seat_name };

static void add_output(kiln_wl *wl, struct wl_registry *registry, uint32_t name, uint32_t version);

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    kiln_wl *wl = data;
    if (strcmp(interface, wl_output_interface.name) == 0) {
        add_output(wl, registry, name, version);
    } else if (strcmp(interface, wl_compositor_interface.name) == 0) {
        wl->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, kiln_min(version, 6));
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        wl->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, kiln_min(version, 6));
        xdg_wm_base_add_listener(wl->wm_base, &wm_listener, wl);
    } else if (strcmp(interface, zxdg_decoration_manager_v1_interface.name) == 0) {
        wl->decoration_manager = wl_registry_bind(registry, name, &zxdg_decoration_manager_v1_interface, 1);
    } else if (strcmp(interface, wp_color_manager_v1_interface.name) == 0) {
        wl->color_manager = wl_registry_bind(registry, name, &wp_color_manager_v1_interface, kiln_min(version, 2));
        wp_color_manager_v1_add_listener(wl->color_manager, &color_listener, wl);
    } else if (strcmp(interface, wp_presentation_interface.name) == 0) {
        wl->presentation = wl_registry_bind(registry, name, &wp_presentation_interface, 1);
    } else if (strcmp(interface, wp_fifo_manager_v1_interface.name) == 0) {
        wl->fifo_manager = wl_registry_bind(registry, name, &wp_fifo_manager_v1_interface, 1);
    } else if (strcmp(interface, wp_fractional_scale_manager_v1_interface.name) == 0) {
        wl->fractional_manager = wl_registry_bind(registry, name, &wp_fractional_scale_manager_v1_interface, 1);
    } else if (strcmp(interface, wp_viewporter_interface.name) == 0) {
        wl->viewporter = wl_registry_bind(registry, name, &wp_viewporter_interface, 1);
    } else if (strcmp(interface, zwp_idle_inhibit_manager_v1_interface.name) == 0) {
        wl->idle_manager = wl_registry_bind(registry, name, &zwp_idle_inhibit_manager_v1_interface, 1);
    } else if (strcmp(interface, wp_cursor_shape_manager_v1_interface.name) == 0) {
        wl->cursor_manager = wl_registry_bind(registry, name, &wp_cursor_shape_manager_v1_interface, 1);
    } else if (strcmp(interface, xdg_activation_v1_interface.name) == 0) {
        wl->activation = wl_registry_bind(registry, name, &xdg_activation_v1_interface, 1);
    } else if (strcmp(interface, zwp_text_input_manager_v3_interface.name) == 0) {
        wl->text_input_manager = wl_registry_bind(registry, name, &zwp_text_input_manager_v3_interface, 1);
    } else if (strcmp(interface, wl_data_device_manager_interface.name) == 0) {
        wl->data_manager = wl_registry_bind(registry, name, &wl_data_device_manager_interface, kiln_min(version, 3));
    } else if (strcmp(interface, wl_seat_interface.name) == 0 && !wl->seat) {
        wl->seat = wl_registry_bind(registry, name, &wl_seat_interface, kiln_min(version, 9));
        wl_seat_add_listener(wl->seat, &seat_listener, wl);
    }
}

static void output_geometry(void *data, struct wl_output *output, int32_t x, int32_t y, int32_t width_mm, int32_t height_mm,
                            int32_t subpixel, const char *make, const char *model, int32_t transform) {
    kiln_wl *wl = data;
    for (int index = 0; index < KILN_MAX_OUTPUTS; index++) {
        if (wl->outputs[index].output != output) continue;
        wl->outputs[index].width_mm = width_mm;
        wl->outputs[index].height_mm = height_mm;
    }
}

static void output_mode(void *data, struct wl_output *output, uint32_t flags, int32_t width, int32_t height, int32_t refresh) {}
static void output_done(void *data, struct wl_output *output) {}
static void output_scale(void *data, struct wl_output *output, int32_t factor) {}
static void output_name(void *data, struct wl_output *output, const char *name) {
    kiln_wl *wl = data;
    for (int index = 0; index < KILN_MAX_OUTPUTS; index++) {
        if (wl->outputs[index].output == output) snprintf(wl->outputs[index].connector, sizeof wl->outputs[index].connector, "%s", name);
    }
}
static void output_description(void *data, struct wl_output *output, const char *description) {}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

static void add_output(kiln_wl *wl, struct wl_registry *registry, uint32_t name, uint32_t version) {
    for (int index = 0; index < KILN_MAX_OUTPUTS; index++) {
        if (wl->outputs[index].output) continue;
        wl->outputs[index] = (kiln_output) { .output = wl_registry_bind(registry, name, &wl_output_interface, kiln_min(version, 4)), .name = name };
        wl_output_add_listener(wl->outputs[index].output, &output_listener, wl);
        return;
    }
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    kiln_wl *wl = data;
    for (int index = 0; index < KILN_MAX_OUTPUTS; index++) {
        if (!wl->outputs[index].output || wl->outputs[index].name != name) continue;
        if (wl->current_output == wl->outputs[index].output) wl->current_output = NULL;
        wl_output_destroy(wl->outputs[index].output);
        wl->outputs[index] = (kiln_output) { 0 };
    }
}

static void surface_enter(void *data, struct wl_surface *surface, struct wl_output *output) {
    kiln_wl *wl = data;
    wl->current_output = output;
}

static void surface_leave(void *data, struct wl_surface *surface, struct wl_output *output) {
    kiln_wl *wl = data;
    if (wl->current_output == output) wl->current_output = NULL;
}

static void surface_preferred_scale(void *data, struct wl_surface *surface, int32_t factor) {}
static void surface_preferred_transform(void *data, struct wl_surface *surface, uint32_t transform) {}

static const struct wl_surface_listener surface_listener = {
    .enter = surface_enter,
    .leave = surface_leave,
    .preferred_buffer_scale = surface_preferred_scale,
    .preferred_buffer_transform = surface_preferred_transform,
};

const char *kiln_wl_output_name(kiln_wl *wl) {
    for (int index = 0; index < KILN_MAX_OUTPUTS; index++) {
        const kiln_output *output = &wl->outputs[index];
        if (output->output && output->output == wl->current_output && output->connector[0]) return output->connector;
    }
    for (int index = 0; index < KILN_MAX_OUTPUTS; index++) {
        if (wl->outputs[index].output && wl->outputs[index].connector[0]) return wl->outputs[index].connector;
    }
    return NULL;
}

bool kiln_wl_output_size_mm(kiln_wl *wl, int32_t *width_mm, int32_t *height_mm) {
    const kiln_output *found = NULL;
    for (int index = 0; index < KILN_MAX_OUTPUTS; index++) {
        const kiln_output *output = &wl->outputs[index];
        if (!output->output) continue;
        if (output->output == wl->current_output || !found) found = output;
        if (output->output == wl->current_output) break;
    }
    if (!found || found->width_mm <= 0 || found->height_mm <= 0) return false;
    *width_mm = found->width_mm;
    *height_mm = found->height_mm;
    return true;
}

enum { OFFER_UTF8 = 1, OFFER_UTF8_STRING = 2, OFFER_PLAIN = 4 };

static void offer_offer(void *data, struct wl_data_offer *offer, const char *mime) {
    uintptr_t kinds = (uintptr_t) wl_data_offer_get_user_data(offer);
    if (strcmp(mime, "text/plain;charset=utf-8") == 0) kinds |= OFFER_UTF8;
    else if (strcmp(mime, "UTF8_STRING") == 0) kinds |= OFFER_UTF8_STRING;
    else if (strcmp(mime, "text/plain") == 0) kinds |= OFFER_PLAIN;
    wl_data_offer_set_user_data(offer, (void *) kinds);
}

static void offer_source_actions(void *data, struct wl_data_offer *offer, uint32_t actions) {}
static void offer_action(void *data, struct wl_data_offer *offer, uint32_t action) {}

static const struct wl_data_offer_listener offer_listener = {
    .offer = offer_offer,
    .source_actions = offer_source_actions,
    .action = offer_action,
};

static void device_data_offer(void *data, struct wl_data_device *device, struct wl_data_offer *offer) {
    wl_data_offer_set_user_data(offer, (void *) 0);
    wl_data_offer_add_listener(offer, &offer_listener, (void *) 0);
}

static void device_enter(void *data, struct wl_data_device *device, uint32_t serial, struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y,
                         struct wl_data_offer *offer) {
    kiln_wl *wl = data;
    if (wl->drag_offer) wl_data_offer_destroy(wl->drag_offer);
    wl->drag_offer = offer;
}

static void device_leave(void *data, struct wl_data_device *device) {
    kiln_wl *wl = data;
    if (wl->drag_offer) wl_data_offer_destroy(wl->drag_offer);
    wl->drag_offer = NULL;
}

static void device_motion(void *data, struct wl_data_device *device, uint32_t time, wl_fixed_t x, wl_fixed_t y) {}
static void device_drop(void *data, struct wl_data_device *device) {}

static void device_selection(void *data, struct wl_data_device *device, struct wl_data_offer *offer) {
    kiln_wl *wl = data;
    if (wl->selection_offer && wl->selection_offer != offer) wl_data_offer_destroy(wl->selection_offer);
    wl->selection_offer = offer;
}

static const struct wl_data_device_listener device_listener = {
    .data_offer = device_data_offer,
    .enter = device_enter,
    .leave = device_leave,
    .motion = device_motion,
    .drop = device_drop,
    .selection = device_selection,
};

static void source_target(void *data, struct wl_data_source *source, const char *mime) {}

/** Writes `text` into a pipe another client reads: never raising the SIGPIPE that would end the app when the reader has
 * gone, and giving up after half a second without progress rather than stalling the window. */
static void write_to_reader(int fd, const char *text, size_t left) {
    sigset_t pipe_signal, previous;
    sigemptyset(&pipe_signal);
    sigaddset(&pipe_signal, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &pipe_signal, &previous);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    bool broken = false;
    struct pollfd writer = { .fd = fd, .events = POLLOUT };
    while (left > 0) {
        ssize_t written = write(fd, text, left);
        if (written > 0) {
            text += written;
            left -= (size_t) written;
        } else if (written < 0 && (errno == EAGAIN || errno == EINTR)) {
            if (errno == EAGAIN && poll(&writer, 1, 500) <= 0) break;
        } else {
            broken = written < 0 && errno == EPIPE;
            break;
        }
    }
    if (broken && !sigismember(&previous, SIGPIPE)) {
        struct timespec now = { 0, 0 };
        sigtimedwait(&pipe_signal, NULL, &now);
    }
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
}

/** Answers another client's paste with this app's clipboard text. */
static void source_send(void *data, struct wl_data_source *source, const char *mime, int32_t fd) {
    kiln_wl *wl = data;
    const char *text = wl->own_source == source && wl->own_text ? wl->own_text : "";
    write_to_reader(fd, text, strlen(text));
    close(fd);
}

static void source_cancelled(void *data, struct wl_data_source *source) {
    kiln_wl *wl = data;
    if (wl->own_source == source) {
        wl->own_source = NULL;
        free(wl->own_text);
        wl->own_text = NULL;
    }
    wl_data_source_destroy(source);
}

static const struct wl_data_source_listener source_listener = { .target = source_target, .send = source_send, .cancelled = source_cancelled };

bool kiln_wl_set_clipboard(kiln_wl *wl, const char *text) {
    if (!wl->data_device || !text) return false;
    struct wl_data_source *source = wl_data_device_manager_create_data_source(wl->data_manager);
    if (!source) return false;
    wl_data_source_add_listener(source, &source_listener, wl);
    wl_data_source_offer(source, "text/plain;charset=utf-8");
    wl_data_source_offer(source, "UTF8_STRING");
    wl_data_source_offer(source, "text/plain");
    if (wl->own_source) wl_data_source_destroy(wl->own_source);
    free(wl->own_text);
    wl->own_source = source;
    wl->own_text = strdup(text);
    wl_data_device_set_selection(wl->data_device, source, wl->input_serial);
    wl_display_flush(wl->display);
    return true;
}

char *kiln_wl_clipboard_text(kiln_wl *wl) {
    if (wl->own_source && wl->own_text) return strdup(wl->own_text);
    struct wl_data_offer *offer = wl->selection_offer;
    if (!offer) return NULL;
    uintptr_t kinds = (uintptr_t) wl_data_offer_get_user_data(offer);
    const char *mime = kinds & OFFER_UTF8 ? "text/plain;charset=utf-8" : kinds & OFFER_UTF8_STRING ? "UTF8_STRING" : kinds & OFFER_PLAIN ? "text/plain" : NULL;
    if (!mime) return NULL;
    int fds[2];
    if (pipe(fds) != 0) return NULL;
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    wl_data_offer_receive(offer, mime, fds[1]);
    close(fds[1]);
    wl_display_flush(wl->display);
    size_t length = 0, capacity = 4096;
    char *text = malloc(capacity);
    struct pollfd reader = { .fd = fds[0], .events = POLLIN };
    while (text && poll(&reader, 1, 500) > 0) {
        if (length + 1024 >= capacity) {
            if (capacity >= (1 << 20)) break;
            char *grown = realloc(text, capacity * 2);
            if (!grown) break;
            text = grown;
            capacity *= 2;
        }
        ssize_t got = read(fds[0], text + length, capacity - length - 1);
        if (got <= 0) break;
        length += (size_t) got;
    }
    close(fds[0]);
    if (text) text[length] = 0;
    return text;
}

/** Sends the field's state and commits it. The state goes out as it changes rather than after the input method's next
 * done, as GTK and Chromium do, because a compositor sends done only when the input method acts and the caret's
 * rectangle must follow arrow keys too. */
static void text_input_send_state(kiln_wl *wl) {
    if (wl->text_input_surrounding) {
        zwp_text_input_v3_set_surrounding_text(wl->text_input, wl->text_input_surrounding, wl->text_input_cursor, wl->text_input_anchor);
    }
    zwp_text_input_v3_set_content_type(wl->text_input, wl->text_input_hint, wl->text_input_purpose);
    zwp_text_input_v3_set_cursor_rectangle(wl->text_input, wl->text_input_rect[0], wl->text_input_rect[1], wl->text_input_rect[2], wl->text_input_rect[3]);
    zwp_text_input_v3_commit(wl->text_input);
    wl_display_flush(wl->display);
}

static void text_input_clear_pending(kiln_wl *wl) {
    free(wl->pending_preedit);
    free(wl->pending_commit);
    wl->pending_preedit = NULL;
    wl->pending_commit = NULL;
    wl->pending_cursor_begin = 0;
    wl->pending_cursor_end = 0;
    wl->pending_delete_before = 0;
    wl->pending_delete_after = 0;
}

static void text_input_enter(void *data, struct zwp_text_input_v3 *input, struct wl_surface *surface) {
    kiln_wl *wl = data;
    if (surface != wl->surface) return;
    wl->text_input_entered = true;
    if (!wl->text_input_wanted) return;
    zwp_text_input_v3_enable(input);
    text_input_send_state(wl);
}

/** The text-input focus left: the composition on screen goes, as the protocol asks. */
static void text_input_leave(void *data, struct zwp_text_input_v3 *input, struct wl_surface *surface) {
    kiln_wl *wl = data;
    wl->text_input_entered = false;
    text_input_clear_pending(wl);
    if (wl->callbacks.text_input) wl->callbacks.text_input(wl->context, (kiln_wl_text_input_event) { 0 });
}

static void text_input_preedit(void *data, struct zwp_text_input_v3 *input, const char *text, int32_t begin, int32_t end) {
    kiln_wl *wl = data;
    free(wl->pending_preedit);
    wl->pending_preedit = text && *text ? strdup(text) : NULL;
    wl->pending_cursor_begin = begin;
    wl->pending_cursor_end = end;
}

static void text_input_commit_string(void *data, struct zwp_text_input_v3 *input, const char *text) {
    kiln_wl *wl = data;
    free(wl->pending_commit);
    wl->pending_commit = text && *text ? strdup(text) : NULL;
}

static void text_input_delete(void *data, struct zwp_text_input_v3 *input, uint32_t before, uint32_t after) {
    kiln_wl *wl = data;
    wl->pending_delete_before = before;
    wl->pending_delete_after = after;
}

static void text_input_done(void *data, struct zwp_text_input_v3 *input, uint32_t serial) {
    kiln_wl *wl = data;
    kiln_wl_text_input_event event = {
        .preedit = wl->pending_preedit,
        .preedit_cursor_begin = wl->pending_cursor_begin,
        .preedit_cursor_end = wl->pending_cursor_end,
        .commit = wl->pending_commit,
        .delete_before = wl->pending_delete_before,
        .delete_after = wl->pending_delete_after,
    };
    if (wl->callbacks.text_input) wl->callbacks.text_input(wl->context, event);
    text_input_clear_pending(wl);
}

static void text_input_action(void *data, struct zwp_text_input_v3 *input, uint32_t action, uint32_t serial) {}
static void text_input_language(void *data, struct zwp_text_input_v3 *input, const char *language) {}
static void text_input_preedit_hint(void *data, struct zwp_text_input_v3 *input, uint32_t begin, uint32_t end, uint32_t hint) {}

static const struct zwp_text_input_v3_listener text_input_listener = {
    .enter = text_input_enter,
    .leave = text_input_leave,
    .preedit_string = text_input_preedit,
    .commit_string = text_input_commit_string,
    .delete_surrounding_text = text_input_delete,
    .done = text_input_done,
    .action = text_input_action,
    .language = text_input_language,
    .preedit_hint = text_input_preedit_hint,
};

void kiln_wl_text_input_enable(kiln_wl *wl, bool enabled) {
    if (!wl->text_input) return;
    bool was = wl->text_input_wanted;
    wl->text_input_wanted = enabled;
    if (!wl->text_input_entered || (!enabled && !was)) return;
    if (enabled) {
        zwp_text_input_v3_enable(wl->text_input);
        text_input_send_state(wl);
    } else {
        zwp_text_input_v3_disable(wl->text_input);
        zwp_text_input_v3_commit(wl->text_input);
        wl_display_flush(wl->display);
    }
}

void kiln_wl_text_input_update(kiln_wl *wl, const char *surrounding, int32_t cursor, int32_t anchor, int32_t x, int32_t y, int32_t width,
                               int32_t height, uint32_t hint, uint32_t purpose) {
    if (!wl->text_input) return;
    free(wl->text_input_surrounding);
    wl->text_input_surrounding = surrounding ? strdup(surrounding) : NULL;
    wl->text_input_cursor = cursor;
    wl->text_input_anchor = anchor;
    wl->text_input_rect[0] = x;
    wl->text_input_rect[1] = y;
    wl->text_input_rect[2] = width;
    wl->text_input_rect[3] = height;
    wl->text_input_hint = hint;
    wl->text_input_purpose = purpose;
    if (wl->text_input_entered && wl->text_input_wanted) text_input_send_state(wl);
}

static const struct wl_registry_listener registry_listener = { .global = registry_global, .global_remove = registry_remove };

kiln_wl *kiln_wl_connect(const char *name) {
    struct wl_display *display = wl_display_connect(name);
    if (!display) return NULL;
    kiln_wl *wl = calloc(1, sizeof(kiln_wl));
    wl->display = display;
    wl->cursor_shape = WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT;
    wl->xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    wl->registry = wl_display_get_registry(display);
    wl_registry_add_listener(wl->registry, &registry_listener, wl);
    wl_display_roundtrip(display);
    wl_display_roundtrip(display);
    if (wl->data_manager && wl->seat) {
        wl->data_device = wl_data_device_manager_get_data_device(wl->data_manager, wl->seat);
        wl_data_device_add_listener(wl->data_device, &device_listener, wl);
    }
    if (wl->text_input_manager && wl->seat) {
        wl->text_input = zwp_text_input_manager_v3_get_text_input(wl->text_input_manager, wl->seat);
        zwp_text_input_v3_add_listener(wl->text_input, &text_input_listener, wl);
    }
    if (!wl->compositor || !wl->wm_base) {
        kiln_wl_disconnect(wl);
        return NULL;
    }
    return wl;
}

void kiln_wl_disconnect(kiln_wl *wl) {
    if (!wl) return;
    if (wl->inhibitor) zwp_idle_inhibitor_v1_destroy(wl->inhibitor);
    if (wl->activation) xdg_activation_v1_destroy(wl->activation);
    if (wl->viewport) wp_viewport_destroy(wl->viewport);
    if (wl->fractional) wp_fractional_scale_v1_destroy(wl->fractional);
    if (wl->fifo) wp_fifo_v1_destroy(wl->fifo);
    if (wl->color_surface) wp_color_management_surface_v1_destroy(wl->color_surface);
    if (wl->decoration) zxdg_toplevel_decoration_v1_destroy(wl->decoration);
    if (wl->toplevel) xdg_toplevel_destroy(wl->toplevel);
    if (wl->xdg_surface) xdg_surface_destroy(wl->xdg_surface);
    if (wl->surface) wl_surface_destroy(wl->surface);
    if (wl->cursor_device) wp_cursor_shape_device_v1_destroy(wl->cursor_device);
    if (wl->own_source) wl_data_source_destroy(wl->own_source);
    free(wl->own_text);
    if (wl->selection_offer) wl_data_offer_destroy(wl->selection_offer);
    if (wl->drag_offer) wl_data_offer_destroy(wl->drag_offer);
    if (wl->data_device) {
        if (wl_data_device_get_version(wl->data_device) >= WL_DATA_DEVICE_RELEASE_SINCE_VERSION) wl_data_device_release(wl->data_device);
        else wl_data_device_destroy(wl->data_device);
    }
    if (wl->data_manager) wl_data_device_manager_destroy(wl->data_manager);
    if (wl->text_input) zwp_text_input_v3_destroy(wl->text_input);
    if (wl->text_input_manager) zwp_text_input_manager_v3_destroy(wl->text_input_manager);
    free(wl->text_input_surrounding);
    text_input_clear_pending(wl);
    for (int index = 0; index < KILN_MAX_OUTPUTS; index++) {
        if (wl->outputs[index].output) wl_output_destroy(wl->outputs[index].output);
    }
    if (wl->pointer) wl_pointer_release(wl->pointer);
    if (wl->keyboard) wl_keyboard_release(wl->keyboard);
    if (wl->xkb_state) xkb_state_unref(wl->xkb_state);
    if (wl->xkb_keymap) xkb_keymap_unref(wl->xkb_keymap);
    if (wl->compose_state) xkb_compose_state_unref(wl->compose_state);
    if (wl->compose_table) xkb_compose_table_unref(wl->compose_table);
    if (wl->xkb) xkb_context_unref(wl->xkb);
    wl_display_flush(wl->display);
    wl_display_disconnect(wl->display);
    free(wl);
}

int kiln_wl_fd(kiln_wl *wl) { return wl_display_get_fd(wl->display); }
struct wl_display *kiln_wl_display(kiln_wl *wl) { return wl->display; }
struct wl_surface *kiln_wl_surface(kiln_wl *wl) { return wl->surface; }
uint32_t kiln_wl_color_features(kiln_wl *wl) { return wl->color_manager ? wl->color_features : 0; }

int kiln_wl_pump(kiln_wl *wl, bool readable) {
    while (wl_display_prepare_read(wl->display) != 0) {
        if (wl_display_dispatch_pending(wl->display) < 0) return -1;
    }
    if (readable) {
        if (wl_display_read_events(wl->display) < 0) return -1;
    } else {
        wl_display_cancel_read(wl->display);
    }
    if (wl_display_dispatch_pending(wl->display) < 0) return -1;
    return kiln_wl_flush(wl);
}

int kiln_wl_flush(kiln_wl *wl) {
    int result = wl_display_flush(wl->display);
    if (result < 0 && errno == EAGAIN) return 0;
    return result < 0 ? -1 : 0;
}

int kiln_wl_roundtrip(kiln_wl *wl) { return wl_display_roundtrip(wl->display); }

static void xdg_surface_configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    kiln_wl *wl = data;
    xdg_surface_ack_configure(surface, serial);
    wl->configured = true;
    if (wl->callbacks.configure) wl->callbacks.configure(wl->context, wl->pending_width, wl->pending_height, wl->pending_states);
}

static const struct xdg_surface_listener xdg_surface_listener = { .configure = xdg_surface_configure };

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel, int32_t width, int32_t height, struct wl_array *states) {
    kiln_wl *wl = data;
    wl->pending_width = width;
    wl->pending_height = height;
    wl->pending_states = 0;
    uint32_t *state;
    wl_array_for_each(state, states) {
        switch (*state) {
        case XDG_TOPLEVEL_STATE_MAXIMIZED: wl->pending_states |= KILN_STATE_MAXIMIZED; break;
        case XDG_TOPLEVEL_STATE_FULLSCREEN: wl->pending_states |= KILN_STATE_FULLSCREEN; break;
        case XDG_TOPLEVEL_STATE_ACTIVATED: wl->pending_states |= KILN_STATE_ACTIVATED; break;
        case XDG_TOPLEVEL_STATE_RESIZING: wl->pending_states |= KILN_STATE_RESIZING; break;
        default: break;
        }
    }
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
    kiln_wl *wl = data;
    if (wl->callbacks.close) wl->callbacks.close(wl->context);
}

static void toplevel_bounds(void *data, struct xdg_toplevel *toplevel, int32_t width, int32_t height) {}
static void toplevel_capabilities(void *data, struct xdg_toplevel *toplevel, struct wl_array *capabilities) {}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
    .configure_bounds = toplevel_bounds,
    .wm_capabilities = toplevel_capabilities,
};

static void fractional_preferred(void *data, struct wp_fractional_scale_v1 *fractional, uint32_t scale) {
    kiln_wl *wl = data;
    if (wl->callbacks.scale) wl->callbacks.scale(wl->context, scale);
}

static const struct wp_fractional_scale_v1_listener fractional_listener = { .preferred_scale = fractional_preferred };

bool kiln_wl_create_window(kiln_wl *wl, const char *title, const char *app_id, kiln_wl_callbacks callbacks, void *context) {
    wl->callbacks = callbacks;
    wl->context = context;
    wl->surface = wl_compositor_create_surface(wl->compositor);
    wl_surface_add_listener(wl->surface, &surface_listener, wl);
    wl->xdg_surface = xdg_wm_base_get_xdg_surface(wl->wm_base, wl->surface);
    xdg_surface_add_listener(wl->xdg_surface, &xdg_surface_listener, wl);
    wl->toplevel = xdg_surface_get_toplevel(wl->xdg_surface);
    xdg_toplevel_add_listener(wl->toplevel, &toplevel_listener, wl);
    xdg_toplevel_set_title(wl->toplevel, title);
    xdg_toplevel_set_app_id(wl->toplevel, app_id);
    if (wl->decoration_manager) {
        wl->decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(wl->decoration_manager, wl->toplevel);
        zxdg_toplevel_decoration_v1_set_mode(wl->decoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    }
    if (wl->fractional_manager && wl->viewporter) {
        wl->fractional = wp_fractional_scale_manager_v1_get_fractional_scale(wl->fractional_manager, wl->surface);
        wp_fractional_scale_v1_add_listener(wl->fractional, &fractional_listener, wl);
        wl->viewport = wp_viewporter_get_viewport(wl->viewporter, wl->surface);
    }
    wl_surface_commit(wl->surface);
    while (!wl->configured) {
        if (wl_display_dispatch(wl->display) < 0) return false;
    }
    return true;
}

void kiln_wl_set_fullscreen(kiln_wl *wl, bool fullscreen) {
    if (fullscreen) xdg_toplevel_set_fullscreen(wl->toplevel, NULL);
    else xdg_toplevel_unset_fullscreen(wl->toplevel);
}

void kiln_wl_set_buffer_scale120(kiln_wl *wl, uint32_t scale120, int32_t logical_width, int32_t logical_height) {
    if (wl->viewport) {
        wp_viewport_set_destination(wl->viewport, logical_width, logical_height);
    } else {
        wl_surface_set_buffer_scale(wl->surface, (int32_t)((scale120 + 119) / 120));
    }
}

static void description_failed(void *data, struct wp_image_description_v1 *description, uint32_t cause, const char *message) {
    kiln_wl *wl = data;
    wl->description_state = -1;
}

static void description_ready(void *data, struct wp_image_description_v1 *description, uint32_t identity) {
    kiln_wl *wl = data;
    wl->description_state = 1;
}

static void description_ready2(void *data, struct wp_image_description_v1 *description, uint32_t identity_hi, uint32_t identity_lo) {
    kiln_wl *wl = data;
    wl->description_state = 1;
}

static const struct wp_image_description_v1_listener description_listener = {
    .failed = description_failed,
    .ready = description_ready,
    .ready2 = description_ready2,
};

bool kiln_wl_describe_scrgb(kiln_wl *wl) {
    if (!wl->color_manager || !(wl->color_features & KILN_COLOR_SCRGB)) return false;
    if (!wl->color_surface) wl->color_surface = wp_color_manager_v1_get_surface(wl->color_manager, wl->surface);
    struct wp_image_description_v1 *description = wp_color_manager_v1_create_windows_scrgb(wl->color_manager);
    wl->description_state = 0;
    wp_image_description_v1_add_listener(description, &description_listener, wl);
    while (wl->description_state == 0) {
        if (wl_display_roundtrip(wl->display) < 0) break;
    }
    bool ready = wl->description_state == 1;
    if (ready) {
        wp_color_management_surface_v1_set_image_description(wl->color_surface, description, WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
    }
    wp_image_description_v1_destroy(description);
    return ready;
}

static void feedback_sync(void *data, struct wp_presentation_feedback *feedback, struct wl_output *output) {}

static void feedback_presented(void *data, struct wp_presentation_feedback *feedback, uint32_t sec_hi, uint32_t sec_lo, uint32_t nsec, uint32_t refresh, uint32_t seq_hi, uint32_t seq_lo, uint32_t flags) {
    kiln_wl *wl = data;
    uint64_t seconds = ((uint64_t)sec_hi << 32) | sec_lo;
    uint64_t sequence = ((uint64_t)seq_hi << 32) | seq_lo;
    if (wl->callbacks.presented) wl->callbacks.presented(wl->context, seconds * 1000000000ull + nsec, refresh, sequence, flags);
    wp_presentation_feedback_destroy(feedback);
}

static void feedback_discarded(void *data, struct wp_presentation_feedback *feedback) {
    kiln_wl *wl = data;
    if (wl->callbacks.discarded) wl->callbacks.discarded(wl->context);
    wp_presentation_feedback_destroy(feedback);
}

static const struct wp_presentation_feedback_listener feedback_listener = {
    .sync_output = feedback_sync,
    .presented = feedback_presented,
    .discarded = feedback_discarded,
};

static void frame_done(void *data, struct wl_callback *callback, uint32_t time) {
    kiln_wl *wl = data;
    wl_callback_destroy(callback);
    if (wl->callbacks.frame) wl->callbacks.frame(wl->context, time);
}

static const struct wl_callback_listener frame_listener = { .done = frame_done };

void kiln_wl_request_frame(kiln_wl *wl) {
    struct wl_callback *callback = wl_surface_frame(wl->surface);
    wl_callback_add_listener(callback, &frame_listener, wl);
    if (wl->presentation) {
        struct wp_presentation_feedback *feedback = wp_presentation_feedback(wl->presentation, wl->surface);
        wp_presentation_feedback_add_listener(feedback, &feedback_listener, wl);
    }
}

void kiln_wl_set_fifo_barrier(kiln_wl *wl) {
    if (!wl->fifo && wl->fifo_manager) wl->fifo = wp_fifo_manager_v1_get_fifo(wl->fifo_manager, wl->surface);
    if (!wl->fifo) return;
    wp_fifo_v1_wait_barrier(wl->fifo);
    wp_fifo_v1_set_barrier(wl->fifo);
}

bool kiln_wl_inhibit_idle(kiln_wl *wl, bool inhibit) {
    if (!wl->idle_manager || !wl->surface) return false;
    if (inhibit && !wl->inhibitor) {
        wl->inhibitor = zwp_idle_inhibit_manager_v1_create_inhibitor(wl->idle_manager, wl->surface);
    } else if (!inhibit && wl->inhibitor) {
        zwp_idle_inhibitor_v1_destroy(wl->inhibitor);
        wl->inhibitor = NULL;
    }
    wl_display_flush(wl->display);
    return true;
}

bool kiln_wl_activate(kiln_wl *wl, const char *token) {
    if (!wl->activation || !wl->surface || !token || !*token) return false;
    xdg_activation_v1_activate(wl->activation, token, wl->surface);
    wl_display_flush(wl->display);
    return true;
}

static void activation_token_done(void *data, struct xdg_activation_token_v1 *token, const char *value) {
    kiln_wl *wl = data;
    if (wl->activation && wl->surface && value && *value) xdg_activation_v1_activate(wl->activation, value, wl->surface);
    xdg_activation_token_v1_destroy(token);
    wl_display_flush(wl->display);
}

static const struct xdg_activation_token_v1_listener activation_token_listener = { .done = activation_token_done };

bool kiln_wl_raise(kiln_wl *wl) {
    if (!wl->activation || !wl->surface) return false;
    struct xdg_activation_token_v1 *token = xdg_activation_v1_get_activation_token(wl->activation);
    if (!token) return false;
    xdg_activation_token_v1_add_listener(token, &activation_token_listener, wl);
    xdg_activation_token_v1_set_surface(token, wl->surface);
    if (wl->seat && wl->pointer_serial) xdg_activation_token_v1_set_serial(token, wl->pointer_serial, wl->seat);
    xdg_activation_token_v1_commit(token);
    wl_display_flush(wl->display);
    return true;
}

extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *message);

int kiln_dispatch_main_queue_handle(void) { return _dispatch_get_main_queue_handle_4CF(); }

void kiln_dispatch_drain_main_queue(void) {
    uint64_t count;
    int fd = _dispatch_get_main_queue_handle_4CF();
    while (read(fd, &count, sizeof(count)) == sizeof(count)) {}
    _dispatch_main_queue_callback_4CF(NULL);
}

void kiln_wl_set_cursor(kiln_wl *wl, enum kiln_cursor cursor) {
    uint32_t shape = WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT;
    switch (cursor) {
    case KILN_CURSOR_DEFAULT: shape = WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT; break;
    case KILN_CURSOR_POINTER: shape = WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER; break;
    case KILN_CURSOR_TEXT: shape = WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT; break;
    case KILN_CURSOR_HIDDEN: shape = 0; break;
    }
    if (shape == wl->cursor_shape) return;
    wl->cursor_shape = shape;
    if (!wl->pointer || !wl->pointer_serial) return;
    if (shape == 0) {
        wl_pointer_set_cursor(wl->pointer, wl->pointer_serial, NULL, 0, 0);
    } else if (wl->cursor_device) {
        wp_cursor_shape_device_v1_set_shape(wl->cursor_device, wl->pointer_serial, shape);
    }
}
