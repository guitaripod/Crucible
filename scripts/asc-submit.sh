#!/usr/bin/env bash
set -euo pipefail

APP=6822066419
IOS_VERSION=013d476f-8e27-4b55-b040-e1cd6585e0c3
TV_VERSION=36616e31-1747-4e73-a132-6875f4d9e0ce
LIFETIME_VERSION=53a3843a-78db-48ce-83f3-3f281ffc38ed
YEARLY_VERSION=8f66e9b6-5825-4cf0-a5d8-46dca14dd015
GROUP_VERSION=df3a75d3-fb2a-4ef2-b21e-8b356b06e6ec

usage() {
  cat << 'USAGE'
Put Crucible's App Store versions in review.

  scripts/asc-submit.sh ios        the iPhone version plus both Crucible Pro products (Apple's first-product rule: new products must ride a version submission)
  scripts/asc-submit.sh tv         the Apple TV version
  scripts/asc-submit.sh status     what App Store Connect says now

Run scripts/asc-setup.py with CRUCIBLE_DEMO_EMAIL, CRUCIBLE_DEMO_PASSWORD and CRUCIBLE_DEMO_SERVER first: the review notes need the demo Plex account.
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

case "${1:-}" in
  ios) submit IOS "$IOS_VERSION" inAppPurchaseVersions "$LIFETIME_VERSION" subscriptionVersions "$YEARLY_VERSION" subscriptionGroupVersions "$GROUP_VERSION" ;;
  tv) submit TV_OS "$TV_VERSION" ;;
  status) asc review status --app "$APP" ;;
  *) usage; exit 2 ;;
esac
