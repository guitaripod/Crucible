#include "crucible_portal_watch.h"

#include <stdlib.h>
#include <systemd/sd-bus.h>

struct crucible_portal_watch {
    sd_bus *bus;
    sd_bus_slot *slot;
    crucible_portal_watch_handler handler;
    void *context;
};

static int on_setting_changed(sd_bus_message *message, void *userdata, sd_bus_error *error) {
    crucible_portal_watch *w = userdata;
    const char *namespace_name = NULL;
    const char *key = NULL;
    if (sd_bus_message_read(message, "ss", &namespace_name, &key) < 0 || !namespace_name || !key) return 0;
    if (w->handler) w->handler(w->context, namespace_name, key);
    return 0;
}

crucible_portal_watch *crucible_portal_watch_create(crucible_portal_watch_handler handler, void *context) {
    crucible_portal_watch *w = calloc(1, sizeof(*w));
    w->handler = handler;
    w->context = context;
    if (sd_bus_open_user(&w->bus) < 0
        || sd_bus_match_signal(w->bus, &w->slot, NULL, "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "SettingChanged",
                               on_setting_changed, w) < 0) {
        crucible_portal_watch_destroy(w);
        return NULL;
    }
    return w;
}

void crucible_portal_watch_destroy(crucible_portal_watch *w) {
    if (!w) return;
    sd_bus_slot_unref(w->slot);
    sd_bus_flush_close_unref(w->bus);
    free(w);
}

int crucible_portal_watch_fd(crucible_portal_watch *w) { return sd_bus_get_fd(w->bus); }

void crucible_portal_watch_process(crucible_portal_watch *w) {
    while (sd_bus_process(w->bus, NULL) > 0) {}
    sd_bus_flush(w->bus);
}
