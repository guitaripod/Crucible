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

/** Keeps the screen awake through org.freedesktop.ScreenSaver, for compositors without idle-inhibit (gamescope); the
 * inhibit lasts while the bus connection stays open. Returns whether the service took it. */
bool crucible_screensaver_inhibit(const char *reason);
void crucible_screensaver_uninhibit(void);

/** Reads a desktop setting through the XDG settings portal (`org.freedesktop.portal.Settings`), such as
 * `org.freedesktop.appearance` `reduced-motion`: a boolean, a number or a numeric string, as a double in `value`. False
 * when there is no portal, no such key, or a value of another kind. */
bool crucible_portal_setting(const char *namespace_name, const char *key, double *value);

/** A pressure-stall trigger on memory (300 ms of stall within 2 s) that polls urgent when memory runs short, or -1 where
 * the kernel offers none. */
int crucible_memory_pressure_open(void);

#endif
