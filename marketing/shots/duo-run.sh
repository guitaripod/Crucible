#!/usr/bin/env bash
# Captures Crucible on an iPhone Duo simulator, on this Mac, in one Duo state and one or more app languages.
#
#   marketing/shots/duo-run.sh STATE [LANGUAGE ...]
#
# STATE is inner-landscape, inner-portrait, outer-portrait or outer-landscape; LANGUAGE is an app language such as
# en, de or pt-BR (en when none is given). Captures land in marketing/shots/out/duo/<state>-<language>/, where
# marketing/store/compose_duo.py reads them. SHOT_SCRIPT picks the harness script as in mac-run.sh (the whole tour
# when unset, watch for What to Watch and Previously On alone). UDID names a Duo simulator to use; without it one
# named CrucibleShots-<NAME> is created on the newest runtime that has the device.
#
# mac-run.sh rewrites a few sources for the harness, so the tree is first copied to ~/Dev/ios/<NAME> and built
# there; NAME must hold no hyphen (the package name is taken from it). The device is folded and turned with duoctl
# (the iphone-duo skill installs it), which also takes the screenshots: simctl captures the inner display even
# while the device is closed. The harness is built once and reused for the languages after the first. The mock
# library's artwork comes from MOCK_ASSETS (~/Dev/ios/_mock-assets when unset), as marketing/mock/README.md says.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STATE=${1:?usage: duo-run.sh STATE [LANGUAGE ...]}
shift
NAME=${NAME:-crucibleduo}
STAGE=$HOME/Dev/ios/$NAME
LOCALES="en:en_US de:de_DE es:es_ES fr:fr_FR it:it_IT ja:ja_JP ko:ko_KR pl:pl_PL pt-BR:pt_BR zh-Hans:zh_CN zh-Hant:zh_TW sv:sv_SE da:da_DK nb:nb_NO fi:fi_FI is:is_IS"

command -v duoctl > /dev/null || { echo "duoctl is not on PATH (see the iphone-duo skill)" >&2; exit 1; }
case "$NAME" in *-*) echo "NAME must hold no hyphen" >&2; exit 1 ;; esac

locale_of() {
  for pair in $LOCALES; do
    if [ "${pair%%:*}" = "$1" ]; then echo "${pair#*:}"; return 0; fi
  done
  echo "no locale known for language $1" >&2
  return 1
}

rsync -a --delete --exclude .build --exclude .git --exclude .claude --exclude .dd --exclude 'marketing/shots/out' \
  --exclude 'marketing/appstore' --exclude 'marketing/mock/assets' "$ROOT/" "$STAGE/"
ASSETS=${MOCK_ASSETS:-$HOME/Dev/ios/_mock-assets}
[ -d "$ASSETS" ] || { echo "the mock library's artwork is not at $ASSETS (marketing/mock/README.md); set MOCK_ASSETS" >&2; exit 1; }
[ -e "$STAGE/marketing/mock/assets" ] || ln -s "$ASSETS" "$STAGE/marketing/mock/assets"

skip=${SKIP_BUILD:-0}
for language in "${@:-en}"; do
  locale=$(locale_of "$language")
  out=$ROOT/marketing/shots/out/duo/$STATE-$language
  mkdir -p "$out"
  NAME=$NAME DEVICE_TYPE="iPhone Duo" DUO_STATE=$STATE RAW=$STAGE/marketing/shots/out/duo-raw MODE=dark \
    APP_LANGUAGE=$language APP_LOCALE=$locale SKIP_BUILD=$skip KEEP_INSTALL=0 \
    bash "$STAGE/marketing/shots/mac-run.sh"
  cp "$STAGE"/marketing/shots/out/duo-raw/*.png "$out"/
  echo "captured $STATE $language -> $out"
  skip=1
done
