#include "crucible_mpris.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <systemd/sd-bus.h>

#define MPRIS_PATH "/org/mpris/MediaPlayer2"
#define ROOT_INTERFACE "org.mpris.MediaPlayer2"
#define PLAYER_INTERFACE "org.mpris.MediaPlayer2.Player"

struct crucible_mpris {
    sd_bus *bus;
    sd_bus_slot *root_slot;
    sd_bus_slot *player_slot;
    crucible_mpris_handler handler;
    void *context;
    char status[16];
    char *title;
    char *show;
    char *art_url;
    int64_t length_us;
    int64_t position_us;
    bool can_go_next;
    unsigned track;
};

static int reply_command(sd_bus_message *message, void *userdata, enum crucible_mpris_command command, int64_t value) {
    crucible_mpris *m = userdata;
    if (m->handler) m->handler(m->context, command, value);
    return sd_bus_reply_method_return(message, "");
}

static int method_raise(sd_bus_message *message, void *userdata, sd_bus_error *error) { return reply_command(message, userdata, CRUCIBLE_MPRIS_RAISE, 0); }
static int method_quit(sd_bus_message *message, void *userdata, sd_bus_error *error) { return sd_bus_reply_method_return(message, ""); }
static int method_play_pause(sd_bus_message *message, void *userdata, sd_bus_error *error) { return reply_command(message, userdata, CRUCIBLE_MPRIS_PLAY_PAUSE, 0); }
static int method_play(sd_bus_message *message, void *userdata, sd_bus_error *error) { return reply_command(message, userdata, CRUCIBLE_MPRIS_PLAY, 0); }
static int method_pause(sd_bus_message *message, void *userdata, sd_bus_error *error) { return reply_command(message, userdata, CRUCIBLE_MPRIS_PAUSE, 0); }
static int method_stop(sd_bus_message *message, void *userdata, sd_bus_error *error) { return reply_command(message, userdata, CRUCIBLE_MPRIS_STOP, 0); }
static int method_next(sd_bus_message *message, void *userdata, sd_bus_error *error) { return reply_command(message, userdata, CRUCIBLE_MPRIS_NEXT, 0); }
static int method_previous(sd_bus_message *message, void *userdata, sd_bus_error *error) { return reply_command(message, userdata, CRUCIBLE_MPRIS_PREVIOUS, 0); }

static int method_seek(sd_bus_message *message, void *userdata, sd_bus_error *error) {
    int64_t offset = 0;
    int r = sd_bus_message_read(message, "x", &offset);
    if (r < 0) return r;
    return reply_command(message, userdata, CRUCIBLE_MPRIS_SEEK, offset);
}

static int method_set_position(sd_bus_message *message, void *userdata, sd_bus_error *error) {
    const char *track = NULL;
    int64_t position = 0;
    int r = sd_bus_message_read(message, "ox", &track, &position);
    if (r < 0) return r;
    return reply_command(message, userdata, CRUCIBLE_MPRIS_SET_POSITION, position);
}

static int method_open_uri(sd_bus_message *message, void *userdata, sd_bus_error *error) {
    return sd_bus_error_set(error, SD_BUS_ERROR_NOT_SUPPORTED, "Crucible plays what is on the Plex server");
}

static int get_string(sd_bus *bus, const char *path, const char *interface, const char *property, sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    crucible_mpris *m = userdata;
    if (strcmp(property, "Identity") == 0) return sd_bus_message_append(reply, "s", "Crucible");
    if (strcmp(property, "DesktopEntry") == 0) return sd_bus_message_append(reply, "s", "org.guitaripod.Crucible");
    if (strcmp(property, "PlaybackStatus") == 0) return sd_bus_message_append(reply, "s", m->status);
    return sd_bus_message_append(reply, "s", "");
}

static int get_bool(sd_bus *bus, const char *path, const char *interface, const char *property, sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    crucible_mpris *m = userdata;
    int value = 0;
    bool active = strcmp(m->status, "Stopped") != 0;
    if (strcmp(property, "CanRaise") == 0) value = 1;
    else if (strcmp(property, "CanGoNext") == 0) value = m->can_go_next;
    else if (strcmp(property, "CanPlay") == 0 || strcmp(property, "CanPause") == 0 || strcmp(property, "CanSeek") == 0) value = active;
    else if (strcmp(property, "CanControl") == 0) value = 1;
    return sd_bus_message_append(reply, "b", value);
}

static int get_double(sd_bus *bus, const char *path, const char *interface, const char *property, sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    return sd_bus_message_append(reply, "d", 1.0);
}

static int get_position(sd_bus *bus, const char *path, const char *interface, const char *property, sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    crucible_mpris *m = userdata;
    return sd_bus_message_append(reply, "x", m->position_us);
}

static int get_strings(sd_bus *bus, const char *path, const char *interface, const char *property, sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    return sd_bus_message_append(reply, "as", 0);
}

static int append_entry(sd_bus_message *reply, const char *key, const char *type, const void *value) {
    int r = sd_bus_message_open_container(reply, 'e', "sv");
    if (r < 0) return r;
    r = sd_bus_message_append(reply, "s", key);
    if (r < 0) return r;
    r = sd_bus_message_open_container(reply, 'v', type);
    if (r < 0) return r;
    if (strcmp(type, "as") == 0) r = sd_bus_message_append(reply, "as", 1, (const char *) value);
    else if (strcmp(type, "x") == 0) r = sd_bus_message_append(reply, "x", *(const int64_t *) value);
    else r = sd_bus_message_append(reply, type, (const char *) value);
    if (r < 0) return r;
    r = sd_bus_message_close_container(reply);
    if (r < 0) return r;
    return sd_bus_message_close_container(reply);
}

static int get_metadata(sd_bus *bus, const char *path, const char *interface, const char *property, sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    crucible_mpris *m = userdata;
    int r = sd_bus_message_open_container(reply, 'a', "{sv}");
    if (r < 0) return r;
    char track[64];
    snprintf(track, sizeof track, "/org/guitaripod/Crucible/track/%u", m->track);
    if ((r = append_entry(reply, "mpris:trackid", "o", track)) < 0) return r;
    if (m->length_us > 0 && (r = append_entry(reply, "mpris:length", "x", &m->length_us)) < 0) return r;
    if (m->title && (r = append_entry(reply, "xesam:title", "s", m->title)) < 0) return r;
    if (m->show && (r = append_entry(reply, "xesam:artist", "as", m->show)) < 0) return r;
    if (m->show && (r = append_entry(reply, "xesam:album", "s", m->show)) < 0) return r;
    if (m->art_url && (r = append_entry(reply, "mpris:artUrl", "s", m->art_url)) < 0) return r;
    return sd_bus_message_close_container(reply);
}

static const sd_bus_vtable root_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("Raise", "", "", method_raise, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("Quit", "", "", method_quit, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_PROPERTY("CanQuit", "b", get_bool, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("CanRaise", "b", get_bool, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("HasTrackList", "b", get_bool, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("Identity", "s", get_string, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("DesktopEntry", "s", get_string, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("SupportedUriSchemes", "as", get_strings, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("SupportedMimeTypes", "as", get_strings, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_VTABLE_END,
};

static const sd_bus_vtable player_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("Next", "", "", method_next, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("Previous", "", "", method_previous, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("Pause", "", "", method_pause, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("PlayPause", "", "", method_play_pause, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("Stop", "", "", method_stop, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("Play", "", "", method_play, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("Seek", "x", "", method_seek, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("SetPosition", "ox", "", method_set_position, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("OpenUri", "s", "", method_open_uri, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_SIGNAL("Seeked", "x", 0),
    SD_BUS_PROPERTY("PlaybackStatus", "s", get_string, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("Rate", "d", get_double, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("Metadata", "a{sv}", get_metadata, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("Volume", "d", get_double, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("Position", "x", get_position, 0, 0),
    SD_BUS_PROPERTY("MinimumRate", "d", get_double, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("MaximumRate", "d", get_double, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("CanGoNext", "b", get_bool, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("CanGoPrevious", "b", get_bool, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("CanPlay", "b", get_bool, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("CanPause", "b", get_bool, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("CanSeek", "b", get_bool, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("CanControl", "b", get_bool, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_VTABLE_END,
};

crucible_mpris *crucible_mpris_create(crucible_mpris_handler handler, void *context) {
    crucible_mpris *m = calloc(1, sizeof(*m));
    m->handler = handler;
    m->context = context;
    snprintf(m->status, sizeof m->status, "Stopped");
    if (sd_bus_open_user(&m->bus) < 0
        || sd_bus_add_object_vtable(m->bus, &m->root_slot, MPRIS_PATH, ROOT_INTERFACE, root_vtable, m) < 0
        || sd_bus_add_object_vtable(m->bus, &m->player_slot, MPRIS_PATH, PLAYER_INTERFACE, player_vtable, m) < 0
        || sd_bus_request_name(m->bus, "org.mpris.MediaPlayer2.crucible", SD_BUS_NAME_ALLOW_REPLACEMENT | SD_BUS_NAME_REPLACE_EXISTING) < 0) {
        crucible_mpris_destroy(m);
        return NULL;
    }
    return m;
}

void crucible_mpris_destroy(crucible_mpris *m) {
    if (!m) return;
    sd_bus_slot_unref(m->root_slot);
    sd_bus_slot_unref(m->player_slot);
    if (m->bus) sd_bus_flush_close_unref(m->bus);
    free(m->title);
    free(m->show);
    free(m->art_url);
    free(m);
}

int crucible_mpris_fd(crucible_mpris *m) { return sd_bus_get_fd(m->bus); }

void crucible_mpris_process(crucible_mpris *m) {
    while (sd_bus_process(m->bus, NULL) > 0) {}
    sd_bus_flush(m->bus);
}

static bool replace(char **field, const char *value) {
    if ((*field == NULL && value == NULL) || (*field && value && strcmp(*field, value) == 0)) return false;
    free(*field);
    *field = value ? strdup(value) : NULL;
    return true;
}

void crucible_mpris_update(crucible_mpris *m, const char *status, const char *title, const char *show, const char *art_url,
                           int64_t length_us, int64_t position_us, bool can_go_next) {
    bool status_changed = strcmp(m->status, status) != 0;
    if (status_changed) snprintf(m->status, sizeof m->status, "%s", status);
    bool metadata_changed = replace(&m->title, title);
    metadata_changed |= replace(&m->show, show);
    metadata_changed |= replace(&m->art_url, art_url);
    if (m->length_us != length_us) {
        m->length_us = length_us;
        metadata_changed = true;
    }
    if (metadata_changed) m->track++;
    m->position_us = position_us;
    bool next_changed = m->can_go_next != can_go_next;
    m->can_go_next = can_go_next;
    if (status_changed || metadata_changed || next_changed) {
        sd_bus_emit_properties_changed(m->bus, MPRIS_PATH, PLAYER_INTERFACE, "PlaybackStatus", "Metadata", "CanGoNext", "CanPlay", "CanPause",
                                       "CanSeek", NULL);
        sd_bus_flush(m->bus);
    }
}

void crucible_mpris_seeked(crucible_mpris *m, int64_t position_us) {
    m->position_us = position_us;
    sd_bus_emit_signal(m->bus, MPRIS_PATH, PLAYER_INTERFACE, "Seeked", "x", position_us);
    sd_bus_flush(m->bus);
}
