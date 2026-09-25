#!/usr/bin/env bash
# A Sunk fullscreen surface remains live and projected, but it must stop owning
# foreground-only HDR, tearing, and fullscreen VRR policy until it is Pulled.
set -euo pipefail

readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly CLIENT_LOG="$UMBRIEL_RUNTIME_DIR/sink-foreground-policy.log"
CLIENT_PID=

if [[ ! -x $CLIENT ]]; then
  echo "sink foreground-policy client is not built"
  exit 1
fi

cleanup() {
  if [[ -n $CLIENT_PID ]]; then
    kill -TERM "$CLIENT_PID" 2>/dev/null || true
    wait "$CLIENT_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

windows() { "$UMBRIEL" windows --json; }

wait_for_windows() {
  local query=$1
  local state=
  for _ in $(seq 100); do
    state=$(windows)
    jq -e "$query" <<< "$state" > /dev/null && return 0
    sleep 0.05
  done
  echo "window state did not settle for $query: $state"
  return 1
}

wait_for_tearing() {
  local query=$1
  local state=
  for _ in $(seq 100); do
    state=$("$UMBRIEL" tearing --json)
    jq -e "$query" <<< "$state" > /dev/null && return 0
    sleep 0.05
  done
  echo "tearing/VRR state did not settle for $query: $state"
  return 1
}

wait_for_color() {
  local query=$1
  local state=
  for _ in $(seq 100); do
    state=$("$UMBRIEL" color --json)
    jq -e "$query" <<< "$state" > /dev/null && return 0
    sleep 0.05
  done
  echo "HDR state did not settle for $query: $state"
  return 1
}

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[animation]
enabled = false

[output.HEADLESS-1]
vrr = "fullscreen"
tearing = true
hdr = "auto"
EOF
"$UMBRIEL" msg config-reload > /dev/null

env APP_ID=sink-foreground-policy REQUEST_FULLSCREEN=1 COLOR_HDR=1 TEARING_HINT=async REDRAW_ON_CLOSE=1 \
  "$CLIENT" sink-foreground-policy > "$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!
for _ in $(seq 100); do
  grep -q '^mapped$' "$CLIENT_LOG" && break
  if ! kill -0 "$CLIENT_PID" 2>/dev/null; then
    wait "$CLIENT_PID" 2>/dev/null || true
    CLIENT_PID=
    echo "foreground-policy client exited before mapping: $(< "$CLIENT_LOG")"
    exit 1
  fi
  sleep 0.05
done
if ! grep -q '^mapped$' "$CLIENT_LOG"; then
  echo "foreground-policy client did not map: $(< "$CLIENT_LOG")"
  exit 1
fi

wait_for_windows 'any(.[]; .title == "sink-foreground-policy" and .focused and (.sunk == false))'
wait_for_tearing '
  .outputs[0].requested == true
  and .outputs[0].vrr_requested == true
  and (.surfaces[] | select(.title == "sink-foreground-policy")
    | .hint == "async" and .fullscreen == true and .eligible == true)
'
wait_for_color '
  .outputs[0].hdr_mode == "auto"
  and .outputs[0].hdr_requested == true
  and (.surfaces[] | select(.title == "sink-foreground-policy")
    | .transfer_function == "PQ" and .primaries == "BT.2020")
'

"$UMBRIEL" msg window-sink > /dev/null
wait_for_windows 'any(.[]; .title == "sink-foreground-policy" and .sunk and (.active == false))'
wait_for_tearing '
  .outputs[0].requested == false
  and .outputs[0].vrr_requested == false
  and (.surfaces[] | select(.title == "sink-foreground-policy")
    | .fullscreen == true and .eligible == false)
'
wait_for_color '
  .outputs[0].hdr_requested == false
  and (.surfaces[] | select(.title == "sink-foreground-policy")
    | .transfer_function == "PQ" and .primaries == "BT.2020")
'

"$UMBRIEL" msg window-pull > /dev/null
wait_for_windows 'any(.[]; .title == "sink-foreground-policy" and (.sunk == false) and .focused)'
wait_for_tearing '
  .outputs[0].requested == true
  and .outputs[0].vrr_requested == true
  and (.surfaces[] | select(.title == "sink-foreground-policy")
    | .fullscreen == true and .eligible == true)
'
wait_for_color '.outputs[0].hdr_requested == true'

kill -TERM "$CLIENT_PID"
wait "$CLIENT_PID" 2>/dev/null || true
CLIENT_PID=
trap - EXIT

echo "Sunk projection released HDR, tearing, and VRR ownership and Pull restored all three policies"
