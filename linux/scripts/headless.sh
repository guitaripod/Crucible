#!/bin/bash
set -euo pipefail
width="${KILN_WIDTH:-3840}"
height="${KILN_HEIGHT:-2160}"
export KILN_AO="${KILN_AO:-null}"
session="$(mktemp --suffix=.sh)"
kwin_config="$(mktemp -d)"
remove_scratch_after_kwin() {
    for _ in $(seq 50); do
        pgrep -f "kiln-headless-$$" >/dev/null || break
        sleep 0.1
    done
    rm -f "$session"
    rm -rf "$kwin_config"
}
trap remove_scratch_after_kwin EXIT
trap 'exit 143' TERM INT HUP
printf '#!/bin/bash\nexport XDG_CONFIG_HOME=%q\ncd %q\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$PWD" > "$session"
printf '%q ' "$@" >> "$session"
printf '\n' >> "$session"
chmod +x "$session"
launcher=()
command -v cleanmask >/dev/null && launcher=(cleanmask)
"${launcher[@]}" "$(command -v dbus-run-session)" -- env -u DISPLAY XDG_CONFIG_HOME="$kwin_config" kwin_wayland --virtual --no-lockscreen --no-global-shortcuts --no-kactivities \
    --socket "kiln-headless-$$" --width "$width" --height "$height" --exit-with-session "$session"
