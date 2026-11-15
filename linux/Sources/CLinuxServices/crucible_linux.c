#include "crucible_linux.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libsecret/secret.h>
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
