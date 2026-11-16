#include "CKiln.h"

#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../protocols/kde-output-device-v2-client-protocol.h"
#include "../protocols/kde-output-management-v2-client-protocol.h"

enum { MAX_DEVICES = 8, MAX_MODES = 96 };

typedef struct {
    struct kde_output_device_mode_v2 *proxy;
    int32_t width;
    int32_t height;
    int32_t refresh;
} display_mode;

typedef struct {
    struct kde_output_device_v2 *proxy;
    char name[64];
    struct kde_output_device_mode_v2 *current;
    uint32_t capabilities;
    bool hdr;
    bool wcg;
    display_mode modes[MAX_MODES];
    int mode_count;
} display_device;

struct kiln_display {
    struct wl_display *display;
    struct wl_registry *registry;
    /** KWin from 6.5 hands out its output devices through this registry rather than one global each. */
    struct kde_output_device_registry_v2 *device_registry;
    /** The version the devices were made with: 21 through the registry, at most 3 as globals. */
    uint32_t device_version;
    struct kde_output_management_v2 *management;
    uint32_t management_version;
    display_device devices[MAX_DEVICES];
    int answer;
};

static display_device *device_of(kiln_display *d, struct kde_output_device_v2 *proxy) {
    for (int index = 0; index < MAX_DEVICES; index++) {
        if (d->devices[index].proxy == proxy) return &d->devices[index];
    }
    return NULL;
}

static display_mode *mode_of(kiln_display *d, struct kde_output_device_mode_v2 *proxy) {
    for (int index = 0; index < MAX_DEVICES; index++) {
        for (int mode = 0; mode < d->devices[index].mode_count; mode++) {
            if (d->devices[index].modes[mode].proxy == proxy) return &d->devices[index].modes[mode];
        }
    }
    return NULL;
}

static void mode_size(void *data, struct kde_output_device_mode_v2 *proxy, int32_t width, int32_t height) {
    display_mode *mode = mode_of(data, proxy);
    if (mode) {
        mode->width = width;
        mode->height = height;
    }
}

static void mode_refresh(void *data, struct kde_output_device_mode_v2 *proxy, int32_t refresh) {
    display_mode *mode = mode_of(data, proxy);
    if (mode) mode->refresh = refresh;
}

static void mode_preferred(void *data, struct kde_output_device_mode_v2 *proxy) {}
static void mode_flags(void *data, struct kde_output_device_mode_v2 *proxy, uint32_t flags) {}
static void mode_cvt(void *data, struct kde_output_device_mode_v2 *proxy, uint32_t dot_clock, uint32_t hdisplay, uint32_t hsync_start,
                     uint32_t hsync_end, uint32_t htotal, uint32_t hskew, uint32_t vdisplay, uint32_t vsync_start, uint32_t vsync_end,
                     uint32_t vtotal, uint32_t vscan, uint32_t flags) {}

static void mode_removed(void *data, struct kde_output_device_mode_v2 *proxy) {
    kiln_display *d = data;
    for (int index = 0; index < MAX_DEVICES; index++) {
        display_device *device = &d->devices[index];
        for (int mode = 0; mode < device->mode_count; mode++) {
            if (device->modes[mode].proxy != proxy) continue;
            device->modes[mode] = device->modes[--device->mode_count];
            if (device->current == proxy) device->current = NULL;
        }
    }
    kde_output_device_mode_v2_destroy(proxy);
}

static const struct kde_output_device_mode_v2_listener mode_listener = {
    .size = mode_size, .refresh = mode_refresh, .preferred = mode_preferred, .removed = mode_removed, .flags = mode_flags, .cvt = mode_cvt,
};

static void device_geometry(void *data, struct kde_output_device_v2 *proxy, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t subpixel,
                            const char *make, const char *model, int32_t transform) {}

static void device_current_mode(void *data, struct kde_output_device_v2 *proxy, struct kde_output_device_mode_v2 *mode) {
    display_device *device = device_of(data, proxy);
    if (device) device->current = mode;
}

static void device_mode(void *data, struct kde_output_device_v2 *proxy, struct kde_output_device_mode_v2 *mode) {
    display_device *device = device_of(data, proxy);
    if (!device || device->mode_count >= MAX_MODES) return;
    device->modes[device->mode_count++] = (display_mode) { .proxy = mode };
    kde_output_device_mode_v2_add_listener(mode, &mode_listener, data);
}

static void device_done(void *data, struct kde_output_device_v2 *proxy) {}
static void device_scale(void *data, struct kde_output_device_v2 *proxy, wl_fixed_t factor) {}
static void device_edid(void *data, struct kde_output_device_v2 *proxy, const char *raw) {}
static void device_enabled(void *data, struct kde_output_device_v2 *proxy, int32_t enabled) {}
static void device_uuid(void *data, struct kde_output_device_v2 *proxy, const char *uuid) {}
static void device_serial(void *data, struct kde_output_device_v2 *proxy, const char *serial) {}
static void device_eisa(void *data, struct kde_output_device_v2 *proxy, const char *eisa) {}

static void device_capabilities(void *data, struct kde_output_device_v2 *proxy, uint32_t flags) {
    display_device *device = device_of(data, proxy);
    if (device) device->capabilities = flags;
}

static void device_overscan(void *data, struct kde_output_device_v2 *proxy, uint32_t overscan) {}
static void device_vrr(void *data, struct kde_output_device_v2 *proxy, uint32_t policy) {}
static void device_rgb_range(void *data, struct kde_output_device_v2 *proxy, uint32_t range) {}

static void device_name(void *data, struct kde_output_device_v2 *proxy, const char *name) {
    display_device *device = device_of(data, proxy);
    if (device) snprintf(device->name, sizeof device->name, "%s", name);
}

static void device_hdr(void *data, struct kde_output_device_v2 *proxy, uint32_t enabled) {
    display_device *device = device_of(data, proxy);
    if (device) device->hdr = enabled;
}

static void device_sdr_brightness(void *data, struct kde_output_device_v2 *proxy, uint32_t brightness) {}

static void device_wcg(void *data, struct kde_output_device_v2 *proxy, uint32_t enabled) {
    display_device *device = device_of(data, proxy);
    if (device) device->wcg = enabled;
}

static void device_u32(void *data, struct kde_output_device_v2 *proxy, uint32_t value) {}
static void device_string(void *data, struct kde_output_device_v2 *proxy, const char *value) {}
static void device_brightness_metadata(void *data, struct kde_output_device_v2 *proxy, uint32_t peak, uint32_t average, uint32_t min) {}
static void device_brightness_overrides(void *data, struct kde_output_device_v2 *proxy, int32_t peak, int32_t average, int32_t min) {}
static void device_range(void *data, struct kde_output_device_v2 *proxy, uint32_t low, uint32_t high) {}

/** The device went away (registry devices only): its modes and the device itself are released. */
static void device_removed(void *data, struct kde_output_device_v2 *proxy) {
    display_device *device = device_of(data, proxy);
    if (!device) return;
    for (int mode = 0; mode < device->mode_count; mode++) kde_output_device_mode_v2_destroy(device->modes[mode].proxy);
    kde_output_device_v2_release(proxy);
    *device = (display_device) { 0 };
}

static const struct kde_output_device_v2_listener device_listener = {
    .geometry = device_geometry, .current_mode = device_current_mode, .mode = device_mode, .done = device_done, .scale = device_scale,
    .edid = device_edid, .enabled = device_enabled, .uuid = device_uuid, .serial_number = device_serial, .eisa_id = device_eisa,
    .capabilities = device_capabilities, .overscan = device_overscan, .vrr_policy = device_vrr, .rgb_range = device_rgb_range,
    .name = device_name, .high_dynamic_range = device_hdr, .sdr_brightness = device_sdr_brightness, .wide_color_gamut = device_wcg,
    .auto_rotate_policy = device_u32, .icc_profile_path = device_string, .brightness_metadata = device_brightness_metadata,
    .brightness_overrides = device_brightness_overrides, .sdr_gamut_wideness = device_u32, .color_profile_source = device_u32,
    .brightness = device_u32, .color_power_tradeoff = device_u32, .dimming = device_u32, .replication_source = device_string,
    .ddc_ci_allowed = device_u32, .max_bits_per_color = device_u32, .max_bits_per_color_range = device_range,
    .automatic_max_bits_per_color_limit = device_u32, .edr_policy = device_u32, .sharpness = device_u32, .priority = device_u32,
    .auto_brightness = device_u32, .removed = device_removed, .hdr_icc_profile_path = device_string, .hdr_color_profile_source = device_u32,
    .abm_level = device_u32,
};

static void add_device(kiln_display *d, struct kde_output_device_v2 *proxy) {
    for (int index = 0; index < MAX_DEVICES; index++) {
        if (d->devices[index].proxy) continue;
        d->devices[index].proxy = proxy;
        kde_output_device_v2_add_listener(proxy, &device_listener, d);
        return;
    }
}

static void registry_output(void *data, struct kde_output_device_registry_v2 *registry, struct kde_output_device_v2 *output) {
    add_device(data, output);
}

static void registry_finished(void *data, struct kde_output_device_registry_v2 *registry) {
    kiln_display *d = data;
    d->device_registry = NULL;
}

static const struct kde_output_device_registry_v2_listener device_registry_listener = {
    .finished = registry_finished, .output = registry_output,
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    kiln_display *d = data;
    if (strcmp(interface, kde_output_device_registry_v2_interface.name) == 0 && version >= 21) {
        d->device_version = 21;
        d->device_registry = wl_registry_bind(registry, name, &kde_output_device_registry_v2_interface, 21);
        kde_output_device_registry_v2_add_listener(d->device_registry, &device_registry_listener, d);
    } else if (strcmp(interface, kde_output_device_v2_interface.name) == 0) {
        d->device_version = version < 3 ? version : 3;
        add_device(d, wl_registry_bind(registry, name, &kde_output_device_v2_interface, d->device_version));
    } else if (strcmp(interface, kde_output_management_v2_interface.name) == 0) {
        d->management_version = version < 4 ? version : 4;
        d->management = wl_registry_bind(registry, name, &kde_output_management_v2_interface, d->management_version);
    }
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {}

static const struct wl_registry_listener registry_listener = { .global = registry_global, .global_remove = registry_remove };

kiln_display *kiln_display_open(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return NULL;
    kiln_display *d = calloc(1, sizeof *d);
    d->display = display;
    d->registry = wl_display_get_registry(display);
    wl_registry_add_listener(d->registry, &registry_listener, d);
    wl_display_roundtrip(display);
    wl_display_roundtrip(display);
    wl_display_roundtrip(display);
    if (!d->management) {
        kiln_display_close(d);
        return NULL;
    }
    return d;
}

void kiln_display_close(kiln_display *d) {
    if (!d) return;
    for (int index = 0; index < MAX_DEVICES; index++) {
        display_device *device = &d->devices[index];
        for (int mode = 0; mode < device->mode_count; mode++) kde_output_device_mode_v2_destroy(device->modes[mode].proxy);
        if (!device->proxy) continue;
        if (d->device_version >= 21) kde_output_device_v2_release(device->proxy);
        else kde_output_device_v2_destroy(device->proxy);
    }
    if (d->device_registry) kde_output_device_registry_v2_stop(d->device_registry);
    if (d->management) kde_output_management_v2_destroy(d->management);
    if (d->registry) wl_registry_destroy(d->registry);
    wl_display_disconnect(d->display);
    free(d);
}

static display_device *named(kiln_display *d, const char *name) {
    for (int index = 0; index < MAX_DEVICES; index++) {
        if (d->devices[index].proxy && name && strcmp(d->devices[index].name, name) == 0) return &d->devices[index];
    }
    return NULL;
}

bool kiln_display_read(kiln_display *d, const char *output, kiln_display_state *state) {
    wl_display_roundtrip(d->display);
    display_device *device = named(d, output);
    memset(state, 0, sizeof *state);
    if (!device) return false;
    display_mode *current = mode_of(d, device->current);
    if (current) state->current = (kiln_display_mode) { current->width, current->height, current->refresh };
    state->hdr_capable = (device->capabilities & KDE_OUTPUT_DEVICE_V2_CAPABILITY_HIGH_DYNAMIC_RANGE) != 0 && d->management_version >= 4;
    state->hdr = device->hdr;
    state->wide_color_gamut = device->wcg;
    for (int mode = 0; mode < device->mode_count && state->mode_count < KILN_DISPLAY_MODES; mode++) {
        display_mode *each = &device->modes[mode];
        state->modes[state->mode_count++] = (kiln_display_mode) { each->width, each->height, each->refresh };
    }
    return true;
}

static void configuration_applied(void *data, struct kde_output_configuration_v2 *configuration) { ((kiln_display *) data)->answer = 1; }
static void configuration_failed(void *data, struct kde_output_configuration_v2 *configuration) { ((kiln_display *) data)->answer = -1; }
static void configuration_reason(void *data, struct kde_output_configuration_v2 *configuration, const char *reason) {}

static const struct kde_output_configuration_v2_listener configuration_listener = {
    .applied = configuration_applied, .failed = configuration_failed, .failure_reason = configuration_reason,
};

static double seconds_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

bool kiln_display_apply(kiln_display *d, const char *output, kiln_display_mode mode, int hdr, int wide_color_gamut) {
    display_device *device = named(d, output);
    if (!device) return false;
    struct kde_output_configuration_v2 *configuration = kde_output_management_v2_create_configuration(d->management);
    kde_output_configuration_v2_add_listener(configuration, &configuration_listener, d);
    bool changed = false;
    if (mode.refresh > 0) {
        for (int index = 0; index < device->mode_count; index++) {
            display_mode *each = &device->modes[index];
            if (each->width != mode.width || each->height != mode.height || each->refresh != mode.refresh) continue;
            if (each->proxy != device->current) {
                kde_output_configuration_v2_mode(configuration, device->proxy, each->proxy);
                changed = true;
            }
            break;
        }
    }
    if (d->management_version >= 4 && hdr >= 0 && (bool) hdr != device->hdr) {
        kde_output_configuration_v2_set_high_dynamic_range(configuration, device->proxy, (uint32_t) hdr);
        changed = true;
    }
    if (d->management_version >= 4 && wide_color_gamut >= 0 && (bool) wide_color_gamut != device->wcg) {
        kde_output_configuration_v2_set_wide_color_gamut(configuration, device->proxy, (uint32_t) wide_color_gamut);
        changed = true;
    }
    if (!changed) {
        kde_output_configuration_v2_destroy(configuration);
        return true;
    }
    d->answer = 0;
    kde_output_configuration_v2_apply(configuration);
    wl_display_flush(d->display);
    double deadline = seconds_now() + 5;
    while (d->answer == 0 && seconds_now() < deadline) {
        struct pollfd reader = { .fd = wl_display_get_fd(d->display), .events = POLLIN };
        while (wl_display_prepare_read(d->display) != 0) wl_display_dispatch_pending(d->display);
        wl_display_flush(d->display);
        if (poll(&reader, 1, 200) > 0) wl_display_read_events(d->display);
        else wl_display_cancel_read(d->display);
        wl_display_dispatch_pending(d->display);
    }
    kde_output_configuration_v2_destroy(configuration);
    wl_display_roundtrip(d->display);
    return d->answer == 1;
}
