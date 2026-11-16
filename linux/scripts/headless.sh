#!/bin/bash
set -euo pipefail
width="${KILN_WIDTH:-3840}"
height="${KILN_HEIGHT:-2160}"
export KILN_AO="${KILN_AO:-null}"
session="$(mktemp --suffix=.sh)"
trap 'rm -f "$session"' EXIT
printf '#!/bin/bash\ncd %q\n' "$PWD" > "$session"
printf '%q ' "$@" >> "$session"
printf '\n' >> "$session"
chmod +x "$session"
launcher=()
command -v cleanmask >/dev/null && launcher=(cleanmask)
"${launcher[@]}" "$(command -v dbus-run-session)" -- env -u DISPLAY kwin_wayland --virtual --no-lockscreen --no-global-shortcuts --no-kactivities \
    --socket "kiln-headless-$$" --width "$width" --height "$height" --exit-with-session "$session"
