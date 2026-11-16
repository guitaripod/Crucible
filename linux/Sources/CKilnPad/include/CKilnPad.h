#ifndef CKILNPAD_H
#define CKILNPAD_H

#include <stdbool.h>

/** What a gamepad did, in SDL3's standard layout (A south, B east, X west, Y north): a button, the state of a stick or of
 * the triggers after it moved (sticks -1 to 1 with y down, triggers 0 to 1), or a pad arriving or leaving. */
typedef enum {
    KILN_PAD_BUTTON = 0,
    KILN_PAD_LEFT_STICK = 1,
    KILN_PAD_RIGHT_STICK = 2,
    KILN_PAD_TRIGGERS = 3,
    KILN_PAD_ADDED = 4,
    KILN_PAD_REMOVED = 5,
} kiln_pad_kind;

typedef enum {
    KILN_PAD_SOUTH = 0,
    KILN_PAD_EAST = 1,
    KILN_PAD_WEST = 2,
    KILN_PAD_NORTH = 3,
    KILN_PAD_BACK = 4,
    KILN_PAD_GUIDE = 5,
    KILN_PAD_START = 6,
    KILN_PAD_LEFT_STICK_PRESS = 7,
    KILN_PAD_RIGHT_STICK_PRESS = 8,
    KILN_PAD_LEFT_SHOULDER = 9,
    KILN_PAD_RIGHT_SHOULDER = 10,
    KILN_PAD_DPAD_UP = 11,
    KILN_PAD_DPAD_DOWN = 12,
    KILN_PAD_DPAD_LEFT = 13,
    KILN_PAD_DPAD_RIGHT = 14,
} kiln_pad_button;

typedef struct {
    kiln_pad_kind kind;
    int button;
    bool down;
    float x;
    float y;
} kiln_pad_event;

/** Starts SDL's gamepad subsystem without its signal handlers and with events while no SDL window has focus (Kiln's
 * windows are not SDL's); false when it cannot start. */
bool kiln_pads_open(void);
void kiln_pads_close(void);
/** Pumps SDL and writes up to `capacity` events; pads arriving are opened and pads leaving closed. */
int kiln_pads_poll(kiln_pad_event *events, int capacity);
/** How many pads are open. */
int kiln_pads_count(void);

/** A virtual pad for tests, with the standard buttons, sticks and triggers; false when SDL refused it. */
bool kiln_pads_attach_virtual(void);
void kiln_pads_virtual_button(int button, bool down);
/** Sets one of the virtual pad's axes, in SDL's order (left x and y, right x and y, left and right trigger), -1 to 1. */
void kiln_pads_virtual_axis(int axis, float value);

#endif
