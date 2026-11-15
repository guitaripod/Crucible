#include "crucible_session.h"

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <systemd/sd-bus.h>
#include <unistd.h>

#define LOGIN1 "org.freedesktop.login1"
#define LOGIN1_PATH "/org/freedesktop/login1"
#define LOGIN1_MANAGER "org.freedesktop.login1.Manager"

struct crucible_session {
    sd_bus *bus;
    sd_bus_slot *sleep_slot;
    sd_bus_slot *lock_slot;
    crucible_session_handler handler;
    void *context;
    bool wants_hold;
    bool locked;
    int inhibitor;
};

static void take_inhibitor(crucible_session *s) {
    if (s->inhibitor >= 0 || !s->wants_hold) return;
    sd_bus_message *reply = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    int result = sd_bus_call_method(s->bus, LOGIN1, LOGIN1_PATH, LOGIN1_MANAGER, "Inhibit", &error, &reply, "ssss", "sleep", "Crucible",
                                    "Pausing playback and saving where it stopped", "delay");
    sd_bus_error_free(&error);
    if (result < 0) return;
    int fd = -1;
    if (sd_bus_message_read(reply, "h", &fd) >= 0 && fd >= 0) s->inhibitor = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    sd_bus_message_unref(reply);
}

static void release_inhibitor(crucible_session *s) {
    if (s->inhibitor < 0) return;
    close(s->inhibitor);
    s->inhibitor = -1;
}

static void emit(crucible_session *s, enum crucible_session_event event) {
    if (s->handler) s->handler(s->context, event);
}

static int on_prepare_for_sleep(sd_bus_message *message, void *userdata, sd_bus_error *error) {
    crucible_session *s = userdata;
    int start = 0;
    if (sd_bus_message_read(message, "b", &start) < 0) return 0;
    if (start) {
        emit(s, CRUCIBLE_SESSION_SLEEP);
    } else {
        take_inhibitor(s);
        emit(s, CRUCIBLE_SESSION_WAKE);
    }
    return 0;
}

/** Reads `LockedHint` out of a PropertiesChanged signal's changed properties, when it is among them. */
static int read_locked_hint(sd_bus_message *message, int *locked) {
    const char *interface = NULL;
    if (sd_bus_message_read(message, "s", &interface) < 0) return -1;
    if (sd_bus_message_enter_container(message, 'a', "{sv}") < 0) return -1;
    int found = 0;
    while (sd_bus_message_enter_container(message, 'e', "sv") > 0) {
        const char *name = NULL;
        if (sd_bus_message_read(message, "s", &name) < 0) return -1;
        if (name && strcmp(name, "LockedHint") == 0) {
            if (sd_bus_message_read(message, "v", "b", locked) < 0) return -1;
            found = 1;
        } else if (sd_bus_message_skip(message, "v") < 0) {
            return -1;
        }
        sd_bus_message_exit_container(message);
    }
    sd_bus_message_exit_container(message);
    return found;
}

static int on_session_properties(sd_bus_message *message, void *userdata, sd_bus_error *error) {
    crucible_session *s = userdata;
    int locked = 0;
    if (read_locked_hint(message, &locked) <= 0 || (bool) locked == s->locked) return 0;
    s->locked = locked;
    emit(s, locked ? CRUCIBLE_SESSION_LOCK : CRUCIBLE_SESSION_UNLOCK);
    return 0;
}

/** The object path of this desktop's session: the caller's own, or the user's display session when the app runs outside one
 * (started by the systemd user manager). */
static char *session_path(sd_bus *bus) {
    sd_bus_message *reply = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    int result = sd_bus_call_method(bus, LOGIN1, LOGIN1_PATH, LOGIN1_MANAGER, "GetSession", &error, &reply, "s", "auto");
    sd_bus_error_free(&error);
    if (result < 0) return NULL;
    const char *path = NULL;
    char *copy = NULL;
    if (sd_bus_message_read(reply, "o", &path) >= 0 && path) copy = strdup(path);
    sd_bus_message_unref(reply);
    return copy;
}

crucible_session *crucible_session_create(crucible_session_handler handler, void *context) {
    crucible_session *s = calloc(1, sizeof(*s));
    s->handler = handler;
    s->context = context;
    s->inhibitor = -1;
    if (sd_bus_open_system(&s->bus) < 0
        || sd_bus_match_signal(s->bus, &s->sleep_slot, LOGIN1, LOGIN1_PATH, LOGIN1_MANAGER, "PrepareForSleep", on_prepare_for_sleep, s) < 0) {
        crucible_session_destroy(s);
        return NULL;
    }
    char *path = session_path(s->bus);
    if (path) {
        sd_bus_match_signal(s->bus, &s->lock_slot, LOGIN1, path, "org.freedesktop.DBus.Properties", "PropertiesChanged", on_session_properties, s);
        free(path);
    }
    return s;
}

void crucible_session_destroy(crucible_session *s) {
    if (!s) return;
    release_inhibitor(s);
    sd_bus_slot_unref(s->lock_slot);
    sd_bus_slot_unref(s->sleep_slot);
    sd_bus_flush_close_unref(s->bus);
    free(s);
}

int crucible_session_fd(crucible_session *s) { return sd_bus_get_fd(s->bus); }

void crucible_session_process(crucible_session *s) {
    while (sd_bus_process(s->bus, NULL) > 0) {}
    sd_bus_flush(s->bus);
}

void crucible_session_hold_sleep(crucible_session *s, bool hold) {
    s->wants_hold = hold;
    if (hold) take_inhibitor(s); else release_inhibitor(s);
}

void crucible_session_slept(crucible_session *s) { release_inhibitor(s); }
