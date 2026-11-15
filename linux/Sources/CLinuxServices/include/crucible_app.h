#ifndef CRUCIBLE_APP_H
#define CRUCIBLE_APP_H

#include <stdbool.h>

typedef struct crucible_app crucible_app;

/** A later launch reached the running app: `uris` (possibly none) to open and the launcher's xdg-activation token
 * (NULL when it gave none). */
typedef void (*crucible_app_handler)(void *context, const char *const *uris, int count, const char *activation_token);

/** Owns org.guitaripod.Crucible on the session bus and serves org.freedesktop.Application at /org/guitaripod/Crucible.
 * NULL with `*already_running` set when another instance owns the name, or NULL alone when there is no session bus. */
crucible_app *crucible_app_claim(crucible_app_handler handler, void *context, bool *already_running);
/** Hands `uris` and the activation token to the instance that owns the name (Open, or Activate when there are none). */
bool crucible_app_forward(const char *const *uris, int count, const char *activation_token);
void crucible_app_destroy(crucible_app *app);
/** Readable when the bus has messages; then call `crucible_app_process`. */
int crucible_app_fd(crucible_app *app);
void crucible_app_process(crucible_app *app);

#endif
