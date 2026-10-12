#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VAULT=${MIDGAR_CREDENTIALS:-$HOME/.config/midgar/credentials.env}
TARGET="$ROOT/Sources/CrucibleStore/StoreSecrets.swift"

usage() {
  cat << 'USAGE'
Write Sources/CrucibleStore/StoreSecrets.swift (git-ignored) with Crucible's RevenueCat public SDK key.

  scripts/bootstrap-secrets.sh            read RC_PUBLIC_CRUCIBLE from ~/.config/midgar/credentials.env
  RC_PUBLIC_CRUCIBLE=appl_... scripts/bootstrap-secrets.sh

Only the App Store builds link CrucibleStore. Source and sideload builds never need the key.
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

key=${RC_PUBLIC_CRUCIBLE:-}
if [[ -z "$key" && -r "$VAULT" ]]; then
  key=$(grep -E '^RC_PUBLIC_CRUCIBLE=' "$VAULT" | head -1 | cut -d= -f2-)
fi
[[ "$key" == appl_* ]] || { echo "RC_PUBLIC_CRUCIBLE is missing or is not an appl_ public SDK key" >&2; exit 1; }

sed "s|__RC_PUBLIC_KEY__|$key|" "$ROOT/scripts/StoreSecrets.swift.template" > "$TARGET"
echo "wrote ${TARGET#$ROOT/}"
