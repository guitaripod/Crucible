#ifndef CRUCIBLE_SESSION_H
#define CRUCIBLE_SESSION_H

#include <stdbool.h>

typedef struct crucible_session crucible_session;

enum crucible_session_event {
    CRUCIBLE_SESSION_SLEEP = 0,
    CRUCIBLE_SESSION_WAKE,
    CRUCIBLE_SESSION_LOCK,
    CRUCIBLE_SESSION_UNLOCK,
};

typedef void (*crucible_session_handler)(void *context, enum crucible_session_event event);

/** Watches logind on the system bus: the machine about to sleep and waking (`PrepareForSleep`), and this desktop session
 * locking and unlocking (its `LockedHint`). NULL when there is no system bus or no logind. */
crucible_session *crucible_session_create(crucible_session_handler handler, void *context);
void crucible_session_destroy(crucible_session *session);
/** Readable when the bus has messages; then call `crucible_session_process`. */
int crucible_session_fd(crucible_session *session);
void crucible_session_process(crucible_session *session);
/** Holds or lets go of a delay lock on sleep, so a SLEEP event has a moment to be acted on before the machine sleeps; it is
 * let go after each SLEEP once `crucible_session_slept` says the work is done, and taken again on WAKE while held. */
void crucible_session_hold_sleep(crucible_session *session, bool hold);
/** The work for a SLEEP event is done: lets the machine sleep now. */
void crucible_session_slept(crucible_session *session);

#endif
