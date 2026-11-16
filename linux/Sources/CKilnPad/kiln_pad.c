#include "CKilnPad.h"

#include <SDL3/SDL.h>

enum { MAX_PADS = 8 };

static SDL_Gamepad *pads[MAX_PADS];
static SDL_JoystickID virtual_pad;
static float axes[SDL_GAMEPAD_AXIS_COUNT];

static float stick_value(Sint16 value) { return value < 0 ? value / 32768.0f : value / 32767.0f; }

bool kiln_pads_open(void) {
    SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    return SDL_InitSubSystem(SDL_INIT_GAMEPAD);
}

void kiln_pads_close(void) {
    for (int index = 0; index < MAX_PADS; index++) {
        if (pads[index]) SDL_CloseGamepad(pads[index]);
        pads[index] = NULL;
    }
    if (virtual_pad) SDL_DetachVirtualJoystick(virtual_pad);
    virtual_pad = 0;
    SDL_QuitSubSystem(SDL_INIT_GAMEPAD);
}

int kiln_pads_count(void) {
    int count = 0;
    for (int index = 0; index < MAX_PADS; index++) count += pads[index] != NULL;
    return count;
}

static void open_pad(SDL_JoystickID id) {
    for (int index = 0; index < MAX_PADS; index++) {
        if (pads[index] && SDL_GetGamepadID(pads[index]) == id) return;
    }
    for (int index = 0; index < MAX_PADS; index++) {
        if (!pads[index]) {
            pads[index] = SDL_OpenGamepad(id);
            return;
        }
    }
}

static void close_pad(SDL_JoystickID id) {
    for (int index = 0; index < MAX_PADS; index++) {
        if (pads[index] && SDL_GetGamepadID(pads[index]) == id) {
            SDL_CloseGamepad(pads[index]);
            pads[index] = NULL;
        }
    }
}

/** The stick or trigger pair an axis belongs to, as one event with both values. */
static kiln_pad_event axis_event(int axis) {
    switch (axis) {
    case SDL_GAMEPAD_AXIS_LEFTX:
    case SDL_GAMEPAD_AXIS_LEFTY:
        return (kiln_pad_event) { .kind = KILN_PAD_LEFT_STICK, .x = axes[SDL_GAMEPAD_AXIS_LEFTX], .y = axes[SDL_GAMEPAD_AXIS_LEFTY] };
    case SDL_GAMEPAD_AXIS_RIGHTX:
    case SDL_GAMEPAD_AXIS_RIGHTY:
        return (kiln_pad_event) { .kind = KILN_PAD_RIGHT_STICK, .x = axes[SDL_GAMEPAD_AXIS_RIGHTX], .y = axes[SDL_GAMEPAD_AXIS_RIGHTY] };
    default:
        return (kiln_pad_event) { .kind = KILN_PAD_TRIGGERS, .x = axes[SDL_GAMEPAD_AXIS_LEFT_TRIGGER], .y = axes[SDL_GAMEPAD_AXIS_RIGHT_TRIGGER] };
    }
}

int kiln_pads_poll(kiln_pad_event *events, int capacity) {
    int count = 0;
    SDL_Event event;
    while (count < capacity && SDL_PollEvent(&event)) {
        switch (event.type) {
        case SDL_EVENT_GAMEPAD_ADDED:
            open_pad(event.gdevice.which);
            events[count++] = (kiln_pad_event) { .kind = KILN_PAD_ADDED };
            break;
        case SDL_EVENT_GAMEPAD_REMOVED:
            close_pad(event.gdevice.which);
            events[count++] = (kiln_pad_event) { .kind = KILN_PAD_REMOVED };
            break;
        case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
        case SDL_EVENT_GAMEPAD_BUTTON_UP:
            if (event.gbutton.button > SDL_GAMEPAD_BUTTON_DPAD_RIGHT) break;
            events[count++] = (kiln_pad_event) { .kind = KILN_PAD_BUTTON, .button = event.gbutton.button, .down = event.gbutton.down };
            break;
        case SDL_EVENT_GAMEPAD_AXIS_MOTION:
            if (event.gaxis.axis >= SDL_GAMEPAD_AXIS_COUNT) break;
            axes[event.gaxis.axis] = stick_value(event.gaxis.value);
            events[count++] = axis_event(event.gaxis.axis);
            break;
        default:
            break;
        }
    }
    return count;
}

bool kiln_pads_attach_virtual(void) {
    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
    desc.nbuttons = SDL_GAMEPAD_BUTTON_DPAD_RIGHT + 1;
    desc.name = "Kiln Test Pad";
    virtual_pad = SDL_AttachVirtualJoystick(&desc);
    return virtual_pad != 0;
}

void kiln_pads_virtual_button(int button, bool down) {
    SDL_Joystick *joystick = SDL_GetJoystickFromID(virtual_pad);
    if (joystick) SDL_SetJoystickVirtualButton(joystick, button, down);
}

void kiln_pads_virtual_axis(int axis, float value) {
    SDL_Joystick *joystick = SDL_GetJoystickFromID(virtual_pad);
    if (!joystick) return;
    float clamped = value < -1 ? -1 : value > 1 ? 1 : value;
    SDL_SetJoystickVirtualAxis(joystick, axis, (Sint16) (clamped < 0 ? clamped * 32768 : clamped * 32767));
}
