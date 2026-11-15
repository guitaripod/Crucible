#include "CKiln.h"

#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <linux/input-event-codes.h>
#include <sys/mman.h>

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
    uint32_t cursor_shape;
    struct xkb_context *xkb;
    struct xkb_keymap *xkb_keymap;
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
    if (wl->callbacks.keyboard_focus) wl->callbacks.keyboard_focus(wl->context, true);
}

static void keyboard_leave(void *data, struct wl_keyboard *keyboard, uint32_t serial, struct wl_surface *surface) {
    kiln_wl *wl = data;
    if (wl->callbacks.keyboard_focus) wl->callbacks.keyboard_focus(wl->context, false);
}

/** Translates an evdev key through the keymap into a keysym, the text it types and the modifiers held, and says whether
 * the keymap lets it repeat. */
static void keyboard_key(void *data, struct wl_keyboard *keyboard, uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
    kiln_wl *wl = data;
    if (!wl->callbacks.key) return;
    kiln_wl_key event = { .code = key, .pressed = state == WL_KEYBOARD_KEY_STATE_PRESSED };
    if (wl->xkb_state) {
        xkb_keycode_t code = key + 8;
        event.keysym = xkb_state_key_get_one_sym(wl->xkb_state, code);
        xkb_state_key_get_utf8(wl->xkb_state, code, event.text, sizeof event.text);
        event.modifiers = keyboard_modifier_mask(wl);
        event.repeats = xkb_keymap_key_repeats(wl->xkb_keymap, code);
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

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    kiln_wl *wl = data;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
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
    } else if (strcmp(interface, wl_seat_interface.name) == 0 && !wl->seat) {
        wl->seat = wl_registry_bind(registry, name, &wl_seat_interface, kiln_min(version, 9));
        wl_seat_add_listener(wl->seat, &seat_listener, wl);
    }
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {}

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
    if (wl->pointer) wl_pointer_release(wl->pointer);
    if (wl->keyboard) wl_keyboard_release(wl->keyboard);
    if (wl->xkb_state) xkb_state_unref(wl->xkb_state);
    if (wl->xkb_keymap) xkb_keymap_unref(wl->xkb_keymap);
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

void kiln_wl_inhibit_idle(kiln_wl *wl, bool inhibit) {
    if (!wl->idle_manager) return;
    if (inhibit && !wl->inhibitor) {
        wl->inhibitor = zwp_idle_inhibit_manager_v1_create_inhibitor(wl->idle_manager, wl->surface);
    } else if (!inhibit && wl->inhibitor) {
        zwp_idle_inhibitor_v1_destroy(wl->inhibitor);
        wl->inhibitor = NULL;
    }
}

bool kiln_wl_activate(kiln_wl *wl, const char *token) {
    if (!wl->activation || !wl->surface || !token || !*token) return false;
    xdg_activation_v1_activate(wl->activation, token, wl->surface);
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
