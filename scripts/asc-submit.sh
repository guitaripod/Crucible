#!/usr/bin/env bash
set -euo pipefail

APP=6822066419
METADATA=$(cd "$(dirname "$0")/.." && pwd)/docs/asc-metadata.json
IOS_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["versions"]["IOS"])' "$METADATA")
TV_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["versions"]["TV_OS"])' "$METADATA")
LIFETIME_VERSION=3db7f938-c299-401e-b4fc-17040201ed56
YEARLY_VERSION=1fd3cc99-5e1d-4345-b7c9-e4275765f6de
GROUP_VERSION=d1c6a4b7-1629-4046-af2a-36edb3c4b513

usage() {
  cat << 'USAGE'
Put Crucible's App Store versions in review.

  scripts/asc-submit.sh ios        the iPhone version plus both Crucible Pro products and their group, at the pending version 2 of each (new products and edited localizations ride a version submission; App Review rejects 2.1(b) when they do not)
  scripts/asc-submit.sh ios-update the iPhone version alone, once the products are approved
  scripts/asc-submit.sh tv         the Apple TV version

The versions come from docs/asc-metadata.json.
  scripts/asc-submit.sh resubmit <submission-id>   after a rejection: resolve its rejected items and send it back (a rejected version cannot ride a new submission)
  scripts/asc-submit.sh status     what App Store Connect says now

Run scripts/asc-setup.py first so the review notes describe the demo mode.
The review submission is created, filled, listed and then submitted; nothing is submitted without the explicit platform argument.
USAGE
}

submission_id() {
  asc review submissions-create --app "$APP" --platform "$1" --output json | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])'
}

submit() {
  local platform=$1 version=$2; shift 2
  local submission
  submission=$(submission_id "$platform")
  echo "submission $submission ($platform)"
  asc review items add --submission "$submission" --item-type appStoreVersions --item-id "$version" > /dev/null
  while (($#)); do
    asc review items add --submission "$submission" --item-type "$1" --item-id "$2" > /dev/null
    shift 2
  done
  asc review items list --submission "$submission" --paginate --output table
  asc review submissions-submit --id "$submission" --confirm
}

resubmit() {
  local submission=$1 item
  for item in $(asc review items list --submission "$submission" --output json | python3 -c 'import json,sys; print(*[i["id"] for i in json.load(sys.stdin)["data"] if i["attributes"]["state"] == "REJECTED"])'); do
    asc review items update --id "$item" --resolved true > /dev/null
  done
  asc review submissions-submit --id "$submission" --confirm
}

case "${1:-}" in
  ios) submit IOS "$IOS_VERSION" inAppPurchaseVersions "$LIFETIME_VERSION" subscriptionVersions "$YEARLY_VERSION" subscriptionGroupVersions "$GROUP_VERSION" ;;
  ios-update) submit IOS "$IOS_VERSION" ;;
  tv) submit TV_OS "$TV_VERSION" ;;
  resubmit) resubmit "${2:?submission id}" ;;
  status) asc review status --app "$APP" ;;
  *) usage; exit 2 ;;
esac
