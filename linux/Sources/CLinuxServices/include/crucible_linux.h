#ifndef CRUCIBLE_LINUX_H
#define CRUCIBLE_LINUX_H

#include <stdbool.h>
#include <stdint.h>

/** Stores `value` under `key` in the Secret Service (KWallet or GNOME Keyring), in Crucible's schema. */
bool crucible_secret_store(const char *key, const char *value);
/** The value under `key`, to free with `crucible_secret_free`, or NULL when absent or the service is unreachable. */
char *crucible_secret_lookup(const char *key, bool *service_reachable);
bool crucible_secret_clear(const char *key);
bool crucible_secret_clear_all(void);
void crucible_secret_free(char *value);

/** Encodes `text` as a QR code (error correction M): `width` modules square, one byte per module (1 dark), to free with
 * `crucible_qr_free`. */
uint8_t *crucible_qr_encode(const char *text, int *width);
void crucible_qr_free(uint8_t *modules);

#endif
