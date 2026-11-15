#include "crucible_notify.h"

#include <stdlib.h>
#include <string.h>
#include <systemd/sd-bus.h>

#define NOTIFICATIONS "org.freedesktop.Notifications"
#define NOTIFICATIONS_PATH "/org/freedesktop/Notifications"
#define APP_ID "org.guitaripod.Crucible"

/** How many tokens are kept for notifications not clicked yet; the oldest go first. */
#define TOKEN_SLOTS 16

struct pending_token {
    uint32_t id;
    char *token;
};

struct crucible_notifier {
    sd_bus *bus;
    sd_bus_slot *action_slot;
    sd_bus_slot *token_slot;
    crucible_notify_handler handler;
    void *context;
    struct pending_token tokens[TOKEN_SLOTS];
    unsigned next_slot;
};

/** Keeps the activation token that arrives just before a click, so the click can raise the window with it. */
static int on_activation_token(sd_bus_message *message, void *userdata, sd_bus_error *error) {
    crucible_notifier *n = userdata;
    uint32_t id = 0;
    const char *token = NULL;
    if (sd_bus_message_read(message, "us", &id, &token) < 0 || !token) return 0;
    struct pending_token *slot = &n->tokens[n->next_slot++ % TOKEN_SLOTS];
    free(slot->token);
    slot->id = id;
    slot->token = strdup(token);
    return 0;
}

static int on_action(sd_bus_message *message, void *userdata, sd_bus_error *error) {
    crucible_notifier *n = userdata;
    uint32_t id = 0;
    const char *action = NULL;
    if (sd_bus_message_read(message, "us", &id, &action) < 0 || !action) return 0;
    const char *token = NULL;
    for (unsigned i = 0; i < TOKEN_SLOTS; i++) {
        if (n->tokens[i].token && n->tokens[i].id == id) token = n->tokens[i].token;
    }
    if (n->handler) n->handler(n->context, id, action, token);
    return 0;
}

crucible_notifier *crucible_notifier_create(crucible_notify_handler handler, void *context) {
    crucible_notifier *n = calloc(1, sizeof(*n));
    n->handler = handler;
    n->context = context;
    if (sd_bus_open_user(&n->bus) < 0
        || sd_bus_match_signal(n->bus, &n->action_slot, NOTIFICATIONS, NOTIFICATIONS_PATH, NOTIFICATIONS, "ActionInvoked", on_action, n) < 0
        || sd_bus_match_signal(n->bus, &n->token_slot, NOTIFICATIONS, NOTIFICATIONS_PATH, NOTIFICATIONS, "ActivationToken", on_activation_token, n) < 0) {
        crucible_notifier_destroy(n);
        return NULL;
    }
    return n;
}

void crucible_notifier_destroy(crucible_notifier *n) {
    if (!n) return;
    for (unsigned i = 0; i < TOKEN_SLOTS; i++) free(n->tokens[i].token);
    sd_bus_slot_unref(n->action_slot);
    sd_bus_slot_unref(n->token_slot);
    sd_bus_flush_close_unref(n->bus);
    free(n);
}

int crucible_notifier_fd(crucible_notifier *n) { return sd_bus_get_fd(n->bus); }

void crucible_notifier_process(crucible_notifier *n) {
    while (sd_bus_process(n->bus, NULL) > 0) {}
    sd_bus_flush(n->bus);
}

/** The hints: the desktop entry that owns the notification and, when there is one, its picture. */
static int append_hints(sd_bus_message *message, const char *image_path) {
    int result = sd_bus_message_open_container(message, 'a', "{sv}");
    if (result < 0) return result;
    if ((result = sd_bus_message_append(message, "{sv}", "desktop-entry", "s", APP_ID)) < 0) return result;
    if (image_path && *image_path && (result = sd_bus_message_append(message, "{sv}", "image-path", "s", image_path)) < 0) return result;
    return sd_bus_message_close_container(message);
}

uint32_t crucible_notify(crucible_notifier *n, const char *summary, const char *body, const char *image_path) {
    sd_bus_message *call = NULL, *reply = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    uint32_t id = 0;
    if (sd_bus_message_new_method_call(n->bus, &call, NOTIFICATIONS, NOTIFICATIONS_PATH, NOTIFICATIONS, "Notify") < 0) return 0;
    if (sd_bus_message_append(call, "susss", "Crucible", (uint32_t) 0, APP_ID, summary ? summary : "", body ? body : "") >= 0
        && sd_bus_message_append(call, "as", 2, "default", "Open") >= 0
        && append_hints(call, image_path) >= 0
        && sd_bus_message_append(call, "i", (int32_t) -1) >= 0
        && sd_bus_call(n->bus, call, 5 * 1000 * 1000, &error, &reply) >= 0) {
        sd_bus_message_read(reply, "u", &id);
    }
    sd_bus_error_free(&error);
    sd_bus_message_unref(reply);
    sd_bus_message_unref(call);
    return id;
}
