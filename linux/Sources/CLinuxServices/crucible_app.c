#include "crucible_app.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <systemd/sd-bus.h>

#define APP_NAME "org.guitaripod.Crucible"
#define APP_PATH "/org/guitaripod/Crucible"
#define APP_INTERFACE "org.freedesktop.Application"

struct crucible_app {
    sd_bus *bus;
    sd_bus_slot *slot;
    crucible_app_handler handler;
    void *context;
};

/** Reads an a{sv} platform-data dictionary and returns its activation-token, to free, or NULL. */
static char *read_activation_token(sd_bus_message *message) {
    char *token = NULL;
    if (sd_bus_message_enter_container(message, 'a', "{sv}") < 0) return NULL;
    while (sd_bus_message_enter_container(message, 'e', "sv") > 0) {
        const char *key = NULL;
        if (sd_bus_message_read(message, "s", &key) < 0) break;
        if (key && strcmp(key, "activation-token") == 0 && !token) {
            const char *value = NULL;
            if (sd_bus_message_read(message, "v", "s", &value) >= 0 && value) token = strdup(value);
        } else if (sd_bus_message_skip(message, "v") < 0) {
            break;
        }
        sd_bus_message_exit_container(message);
    }
    sd_bus_message_exit_container(message);
    return token;
}

static int method_activate(sd_bus_message *message, void *userdata, sd_bus_error *error) {
    crucible_app *app = userdata;
    char *token = read_activation_token(message);
    if (app->handler) app->handler(app->context, NULL, 0, token);
    free(token);
    return sd_bus_reply_method_return(message, "");
}

static int method_open(sd_bus_message *message, void *userdata, sd_bus_error *error) {
    crucible_app *app = userdata;
    char **uris = NULL;
    int r = sd_bus_message_read_strv(message, &uris);
    if (r < 0) return r;
    int count = 0;
    while (uris && uris[count]) count++;
    char *token = read_activation_token(message);
    if (app->handler) app->handler(app->context, (const char *const *) uris, count, token);
    free(token);
    for (int i = 0; i < count; i++) free(uris[i]);
    free(uris);
    return sd_bus_reply_method_return(message, "");
}

static int method_activate_action(sd_bus_message *message, void *userdata, sd_bus_error *error) {
    return method_activate(message, userdata, error);
}

static const sd_bus_vtable app_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("Activate", "a{sv}", "", method_activate, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("Open", "asa{sv}", "", method_open, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("ActivateAction", "sava{sv}", "", method_activate_action, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_VTABLE_END,
};

crucible_app *crucible_app_claim(crucible_app_handler handler, void *context, bool *already_running) {
    if (already_running) *already_running = false;
    crucible_app *app = calloc(1, sizeof(*app));
    app->handler = handler;
    app->context = context;
    if (sd_bus_open_user(&app->bus) < 0
        || sd_bus_add_object_vtable(app->bus, &app->slot, APP_PATH, APP_INTERFACE, app_vtable, app) < 0) {
        crucible_app_destroy(app);
        return NULL;
    }
    int r = sd_bus_request_name(app->bus, APP_NAME, 0);
    if (r < 0) {
        if (already_running) *already_running = r == -EEXIST;
        crucible_app_destroy(app);
        return NULL;
    }
    return app;
}

/** Appends platform data carrying `token` (an empty dictionary without one). */
static int append_platform_data(sd_bus_message *message, const char *token) {
    int r = sd_bus_message_open_container(message, 'a', "{sv}");
    if (r >= 0 && token && *token) r = sd_bus_message_append(message, "{sv}", "activation-token", "s", token);
    if (r >= 0) r = sd_bus_message_close_container(message);
    return r;
}

bool crucible_app_forward(const char *const *uris, int count, const char *activation_token) {
    sd_bus *bus = NULL;
    sd_bus_message *call = NULL;
    sd_bus_message *reply = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    bool ok = false;
    if (sd_bus_open_user(&bus) < 0) return false;
    int r = sd_bus_message_new_method_call(bus, &call, APP_NAME, APP_PATH, APP_INTERFACE, count > 0 ? "Open" : "Activate");
    if (r >= 0 && count > 0) {
        r = sd_bus_message_open_container(call, 'a', "s");
        for (int i = 0; r >= 0 && i < count; i++) r = sd_bus_message_append(call, "s", uris[i]);
        if (r >= 0) r = sd_bus_message_close_container(call);
    }
    if (r >= 0) r = append_platform_data(call, activation_token);
    if (r >= 0) ok = sd_bus_call(bus, call, 5 * 1000 * 1000, &error, &reply) >= 0;
    sd_bus_error_free(&error);
    sd_bus_message_unref(reply);
    sd_bus_message_unref(call);
    sd_bus_flush_close_unref(bus);
    return ok;
}

void crucible_app_destroy(crucible_app *app) {
    if (!app) return;
    sd_bus_slot_unref(app->slot);
    if (app->bus) sd_bus_flush_close_unref(app->bus);
    free(app);
}

int crucible_app_fd(crucible_app *app) { return sd_bus_get_fd(app->bus); }

void crucible_app_process(crucible_app *app) {
    while (sd_bus_process(app->bus, NULL) > 0) {}
    sd_bus_flush(app->bus);
}
