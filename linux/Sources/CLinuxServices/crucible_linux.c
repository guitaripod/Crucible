#include "crucible_linux.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <libsecret/secret.h>
#include <systemd/sd-bus.h>
#include <unistd.h>
#include <qrencode.h>

static const SecretSchema *schema(void) {
    static const SecretSchema value = {
        "org.guitaripod.Crucible", SECRET_SCHEMA_NONE,
        { { "key", SECRET_SCHEMA_ATTRIBUTE_STRING }, { NULL, 0 } },
    };
    return &value;
}

static GHashTable *attributes(const char *key) {
    GHashTable *table = g_hash_table_new(g_str_hash, g_str_equal);
    if (key) g_hash_table_insert(table, (gpointer) "key", (gpointer) key);
    return table;
}

bool crucible_secret_store(const char *key, const char *value) {
    GError *error = NULL;
    GHashTable *table = attributes(key);
    char label[256];
    snprintf(label, sizeof label, "Crucible: %s", key);
    gboolean ok = secret_password_storev_sync(schema(), table, SECRET_COLLECTION_DEFAULT, label, value, NULL, &error);
    g_hash_table_unref(table);
    if (error) g_error_free(error);
    return ok;
}

char *crucible_secret_lookup(const char *key, bool *service_reachable) {
    GError *error = NULL;
    GHashTable *table = attributes(key);
    gchar *found = secret_password_lookupv_sync(schema(), table, NULL, &error);
    g_hash_table_unref(table);
    if (service_reachable) *service_reachable = error == NULL;
    if (error) g_error_free(error);
    if (!found) return NULL;
    char *copy = strdup(found);
    secret_password_free(found);
    return copy;
}

bool crucible_secret_clear(const char *key) {
    GError *error = NULL;
    GHashTable *table = attributes(key);
    secret_password_clearv_sync(schema(), table, NULL, &error);
    g_hash_table_unref(table);
    bool ok = error == NULL;
    if (error) g_error_free(error);
    return ok;
}

bool crucible_secret_clear_all(void) {
    return crucible_secret_clear(NULL);
}

void crucible_secret_free(char *value) { free(value); }

uint8_t *crucible_qr_encode(const char *text, int *width) {
    QRcode *code = QRcode_encodeString(text, 0, QR_ECLEVEL_M, QR_MODE_8, 1);
    if (!code) return NULL;
    size_t count = (size_t) code->width * code->width;
    uint8_t *modules = malloc(count);
    for (size_t i = 0; i < count; i++) modules[i] = code->data[i] & 1;
    *width = code->width;
    QRcode_free(code);
    return modules;
}

void crucible_qr_free(uint8_t *modules) { free(modules); }

static sd_bus *screensaver_bus;
static uint32_t screensaver_cookie;

bool crucible_screensaver_inhibit(const char *reason) {
    if (screensaver_cookie) return true;
    if (!screensaver_bus && sd_bus_open_user(&screensaver_bus) < 0) {
        screensaver_bus = NULL;
        return false;
    }
    sd_bus_message *reply = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    int result = sd_bus_call_method(screensaver_bus, "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
                                    "org.freedesktop.ScreenSaver", "Inhibit", &error, &reply, "ss", "Crucible", reason ? reason : "Playing");
    sd_bus_error_free(&error);
    if (result < 0) return false;
    uint32_t cookie = 0;
    if (sd_bus_message_read(reply, "u", &cookie) >= 0) screensaver_cookie = cookie;
    sd_bus_message_unref(reply);
    return screensaver_cookie != 0;
}

void crucible_screensaver_uninhibit(void) {
    if (!screensaver_bus || !screensaver_cookie) return;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    sd_bus_call_method(screensaver_bus, "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver",
                       "UnInhibit", &error, NULL, "u", screensaver_cookie);
    sd_bus_error_free(&error);
    screensaver_cookie = 0;
}

int crucible_memory_pressure_open(void) {
    int fd = open("/proc/pressure/memory", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    const char trigger[] = "some 300000 2000000";
    if (write(fd, trigger, sizeof trigger) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static sd_bus *portal_bus;

/** Reads the value inside the variant the reply is positioned on, unwrapping the extra variant the older `Read` adds. */
static bool read_portal_value(sd_bus_message *reply, double *value) {
    char type = 0;
    const char *contents = NULL;
    if (sd_bus_message_peek_type(reply, &type, &contents) < 0) return false;
    if (type == 'v') {
        if (sd_bus_message_enter_container(reply, 'v', contents) < 0) return false;
        bool read = read_portal_value(reply, value);
        sd_bus_message_exit_container(reply);
        return read;
    }
    switch (type) {
    case 'b': { int flag = 0; if (sd_bus_message_read_basic(reply, 'b', &flag) < 0) return false; *value = flag ? 1 : 0; return true; }
    case 'u': { uint32_t number = 0; if (sd_bus_message_read_basic(reply, 'u', &number) < 0) return false; *value = number; return true; }
    case 'i': { int32_t number = 0; if (sd_bus_message_read_basic(reply, 'i', &number) < 0) return false; *value = number; return true; }
    case 'y': { uint8_t number = 0; if (sd_bus_message_read_basic(reply, 'y', &number) < 0) return false; *value = number; return true; }
    case 'd': { double number = 0; if (sd_bus_message_read_basic(reply, 'd', &number) < 0) return false; *value = number; return true; }
    case 's': {
        const char *text = NULL;
        if (sd_bus_message_read_basic(reply, 's', &text) < 0 || !text) return false;
        char *end = NULL;
        double number = strtod(text, &end);
        if (end == text) return false;
        *value = number;
        return true;
    }
    default:
        return false;
    }
}

bool crucible_portal_setting(const char *namespace_name, const char *key, double *value) {
    if (!namespace_name || !key || !value) return false;
    if (!portal_bus && sd_bus_open_user(&portal_bus) < 0) {
        portal_bus = NULL;
        return false;
    }
    const char *methods[] = {"ReadOne", "Read"};
    for (int index = 0; index < 2; index++) {
        sd_bus_message *call = NULL;
        if (sd_bus_message_new_method_call(portal_bus, &call, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                                           "org.freedesktop.portal.Settings", methods[index]) < 0) return false;
        sd_bus_message_set_auto_start(call, 0);
        if (sd_bus_message_append(call, "ss", namespace_name, key) < 0) {
            sd_bus_message_unref(call);
            return false;
        }
        sd_bus_message *reply = NULL;
        sd_bus_error error = SD_BUS_ERROR_NULL;
        int result = sd_bus_call(portal_bus, call, 300 * 1000, &error, &reply);
        sd_bus_message_unref(call);
        bool unknownMethod = result < 0 && sd_bus_error_has_name(&error, SD_BUS_ERROR_UNKNOWN_METHOD);
        sd_bus_error_free(&error);
        if (result < 0) {
            if (unknownMethod) continue;
            return false;
        }
        bool read = read_portal_value(reply, value);
        sd_bus_message_unref(reply);
        return read;
    }
    return false;
}
