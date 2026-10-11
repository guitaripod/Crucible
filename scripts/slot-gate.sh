GATE_TEMPLATE='slot=""; waited=""; while [ -z "$slot" ]; do for n in $(seq 1 $(cat /tmp/crucible-slots-@POOL@ 2>/dev/null || echo @COUNT@)); do d=/tmp/crucible-@POOL@-slot-$n; if mkdir "$d" 2>/dev/null; then echo $$ > "$d/pid"; slot=$d; break; fi; p=$(cat "$d/pid" 2>/dev/null); if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$d"; fi; done; if [ -z "$slot" ]; then [ -n "$waited" ] || echo "waiting for @LABEL@ on the Mac" >&2; waited=1; sleep 4; fi; done; trap "rm -rf $slot" EXIT HUP INT TERM; '

BUILD_SLOTS=${BUILD_SLOTS:-3}
UITEST_SLOTS=${UITEST_SLOTS:-3}

slot_gate() {
  local pool=$1 count=$2 label=$3 snippet=$GATE_TEMPLATE
  snippet=${snippet//@POOL@/$pool}
  snippet=${snippet//@COUNT@/$count}
  snippet=${snippet//@LABEL@/$label}
  printf '%s' "$snippet"
}

build_gate() {
  slot_gate build "$BUILD_SLOTS" "a build slot"
}

uitest_gate() {
  slot_gate uitest "$UITEST_SLOTS" "a UI test slot"
}
