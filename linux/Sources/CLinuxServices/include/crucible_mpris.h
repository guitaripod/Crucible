#ifndef CRUCIBLE_MPRIS_H
#define CRUCIBLE_MPRIS_H

#include <stdbool.h>
#include <stdint.h>

typedef struct crucible_mpris crucible_mpris;

enum crucible_mpris_command {
    CRUCIBLE_MPRIS_PLAY_PAUSE = 0,
    CRUCIBLE_MPRIS_PLAY,
    CRUCIBLE_MPRIS_PAUSE,
    CRUCIBLE_MPRIS_STOP,
    CRUCIBLE_MPRIS_NEXT,
    CRUCIBLE_MPRIS_PREVIOUS,
    CRUCIBLE_MPRIS_SEEK,
    CRUCIBLE_MPRIS_SET_POSITION,
    CRUCIBLE_MPRIS_RAISE,
    CRUCIBLE_MPRIS_QUIT,
};

/** `value` is microseconds for SEEK (relative) and SET_POSITION (absolute). */
typedef void (*crucible_mpris_handler)(void *context, enum crucible_mpris_command command, int64_t value);

/** Claims org.mpris.MediaPlayer2.crucible on the session bus. NULL when there is no session bus. */
crucible_mpris *crucible_mpris_create(crucible_mpris_handler handler, void *context);
void crucible_mpris_destroy(crucible_mpris *mpris);
/** Readable when the bus has messages; then call `crucible_mpris_process`. */
int crucible_mpris_fd(crucible_mpris *mpris);
void crucible_mpris_process(crucible_mpris *mpris);

/** Publishes what plays: `status` is Playing, Paused or Stopped; times in microseconds; NULL strings are left out. */
void crucible_mpris_update(crucible_mpris *mpris, const char *status, const char *title, const char *show, const char *art_url,
                           int64_t length_us, int64_t position_us, bool can_go_next);
void crucible_mpris_seeked(crucible_mpris *mpris, int64_t position_us);

#endif
