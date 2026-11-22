#ifndef CRUCIBLE_PORTAL_WATCH_H
#define CRUCIBLE_PORTAL_WATCH_H

typedef struct crucible_portal_watch crucible_portal_watch;

/** A desktop setting changed: its namespace and key, such as `org.freedesktop.appearance` `color-scheme`. */
typedef void (*crucible_portal_watch_handler)(void *context, const char *namespace_name, const char *key);

/** Listens for the settings portal's `SettingChanged` on the session bus, without starting the portal. NULL when there is
 * no session bus. */
crucible_portal_watch *crucible_portal_watch_create(crucible_portal_watch_handler handler, void *context);
void crucible_portal_watch_destroy(crucible_portal_watch *watch);
/** Readable when the bus has messages; then call `crucible_portal_watch_process`. */
int crucible_portal_watch_fd(crucible_portal_watch *watch);
void crucible_portal_watch_process(crucible_portal_watch *watch);

#endif
