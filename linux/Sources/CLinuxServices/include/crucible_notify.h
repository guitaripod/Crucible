#ifndef CRUCIBLE_NOTIFY_H
#define CRUCIBLE_NOTIFY_H

#include <stdint.h>

typedef struct crucible_notifier crucible_notifier;

/** A notification was clicked (`action` "default") or one of its buttons chosen; `activation_token` is the token the
 * notification server handed over for raising the window, or NULL when it sent none. */
typedef void (*crucible_notify_handler)(void *context, uint32_t id, const char *action, const char *activation_token);

/** Talks to org.freedesktop.Notifications on the session bus. NULL when there is no session bus. */
crucible_notifier *crucible_notifier_create(crucible_notify_handler handler, void *context);
void crucible_notifier_destroy(crucible_notifier *notifier);
/** Readable when the bus has messages; then call `crucible_notifier_process`. */
int crucible_notifier_fd(crucible_notifier *notifier);
void crucible_notifier_process(crucible_notifier *notifier);
/** Shows a notification from Crucible's desktop entry with `summary`, `body` and, when given, the picture at `image_path`;
 * clicking it reports the action "default". Returns the server's id for it, or 0 when it could not be shown. */
uint32_t crucible_notify(crucible_notifier *notifier, const char *summary, const char *body, const char *image_path);

#endif
