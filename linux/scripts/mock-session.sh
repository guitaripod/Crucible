#!/bin/bash
# Runs a command (arguments as for headless.sh) in a private headless KWin, signed in to the fictional library of
# marketing/mock/server.py through a throwaway profile, so screens and actions can be exercised without a real account:
#   linux/scripts/mock-session.sh .build/release/crucible --capture 6::/tmp/home.png
# MOCK_PORT picks the mock's port (32499 by default); MOCK_OWNER=1 makes the account the server's owner, so Manage and the
# owner screens show; MOCK_DEFAULTS (a JSON object) adds settings to the profile, such as
# '{"ownModel.address": "http://localhost:8081/v1", "ownModel.model": "qwen3"}'; the other MOCK_* switches (see
# marketing/mock/README.md) pass through.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
port="${MOCK_PORT:-32499}"
profile="$(mktemp -d)"
mock_pid=""
cleanup() {
    [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null || true
    rm -rf "$profile"
}
trap cleanup EXIT
mkdir -p "$profile/config" "$profile/data/crucible" "$profile/cache" "$profile/state"
launcher=()
command -v cleanmask >/dev/null && launcher=(cleanmask)
(cd "$root/marketing/mock" && PORT="$port" exec "${launcher[@]}" "$(command -v python3)" server.py) > "$profile/mock.log" 2>&1 &
mock_pid=$!
for _ in $(seq 50); do
    curl -sf -o /dev/null "http://127.0.0.1:$port/identity" && break
    sleep 0.1
done
machine="$(sed -n 's/^MACHINE_ID = "\(.*\)"/\1/p' "$root/marketing/mock/library.py")"
python3 - "$profile" "$port" "$machine" "${MOCK_OWNER:-0}" <<'PY'
import json, os, plistlib, sys
profile, port, machine, owner = sys.argv[1:5]
uri = f"http://127.0.0.1:{port}"
defaults = {"plex_server_uri": uri, "plex_server_name": "Marcus-PC", "plex_machine_id": machine,
            "plex_candidate_uris": [uri], "plex_session_machine_id": machine}
if owner == "1":
    defaults["serverOwnership.v1"] = {machine: True}
defaults.update(json.loads(os.environ.get("MOCK_DEFAULTS") or "{}"))
plistlib.dump(defaults, open(f"{profile}/config/crucible.plist", "wb"), fmt=plistlib.FMT_XML)
json.dump({"plex_auth_token": "mock-token", "plex_client_id": "mock-client"}, open(f"{profile}/data/crucible/secrets.json", "w"))
PY
"$root/linux/scripts/headless.sh" env XDG_CONFIG_HOME="$profile/config" XDG_DATA_HOME="$profile/data" XDG_CACHE_HOME="$profile/cache" \
    XDG_STATE_HOME="$profile/state" CRUCIBLE_NO_BROWSER=1 LD_LIBRARY_PATH="$root/linux/.build/mpv/lib" "$@"
