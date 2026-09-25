#!/usr/bin/env bash
# Foreign-toplevel capture must keep using the isolated client-surface scene.
# Sink may project the window in the desktop scene, but must not scale, fade,
# duplicate, or replace the pixels returned to a portal-style capture client.
set -euo pipefail

readonly CLIENT="${UMBRIEL_SUBSURFACE_CLIENT:-./build-debug/tests/subsurface-client}"
readonly CAPTURE="${UMBRIEL_TOPLEVEL_CAPTURE_CLIENT:-./build-debug/tests/toplevel-capture-client}"
readonly TITLE=sink-toplevel-capture
readonly CLIENT_LOG="$UMBRIEL_RUNTIME_DIR/$TITLE.log"
CLIENT_PID=

if [[ ! -x $CLIENT || ! -x $CAPTURE ]]; then
  echo "sink capture clients are not built"
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

wait_for_window() {
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

capture_sample() {
  local label=$1
  local sample width height red green blue alpha
  sample=$("$CAPTURE" "$TITLE")
  read -r width height red green blue alpha <<< "$sample"
  if [[ -z $alpha ]] || ((width != 400 || height != 300)); then
    echo "$label capture returned unexpected geometry/sample: $sample"
    return 1
  fi
  if ((blue < 245 || red > 10 || green > 10 || alpha < 245)); then
    echo "$label capture leaked non-client content: $sample"
    return 1
  fi
  printf '%s\n' "$sample"
}

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[animation]
enabled = false

[[window_rule]]
match.app_id = "^sink-toplevel-capture$"
default_floating = true
default_floating_size_px = { width = 400, height = 300 }
EOF
"$UMBRIEL" msg config-reload > /dev/null

"$CLIENT" "$TITLE" 400 300 > "$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!
for _ in $(seq 100); do
  grep -q '^mapped$' "$CLIENT_LOG" && break
  sleep 0.05
done
if ! grep -q '^mapped$' "$CLIENT_LOG"; then
  echo "capture source client did not map: $(< "$CLIENT_LOG")"
  exit 1
fi
wait_for_window 'any(.[]; .title == "sink-toplevel-capture" and .focused and (.sunk == false))'

before=$(capture_sample before-Sink)
"$UMBRIEL" msg window-sink > /dev/null
wait_for_window 'any(.[]; .title == "sink-toplevel-capture" and .sunk and (.active == false))'
sunk=$(capture_sample Sunk)
"$UMBRIEL" msg window-pull > /dev/null
wait_for_window 'any(.[]; .title == "sink-toplevel-capture" and (.sunk == false) and .focused)'
pulled=$(capture_sample Pulled)

if [[ $before != "$sunk" || $before != "$pulled" ]]; then
  echo "capture pixels changed across Sink/Pull: before=$before sunk=$sunk pulled=$pulled"
  exit 1
fi

kill -TERM "$CLIENT_PID"
wait "$CLIENT_PID" 2>/dev/null || true
CLIENT_PID=
trap - EXIT

echo "foreign-toplevel capture remained an isolated 400x300 client surface across Sink and Pull"
