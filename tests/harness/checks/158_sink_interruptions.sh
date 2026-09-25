#!/usr/bin/env bash
# Rapid reversal, reload, animation disable, close, and a client maximize
# request must not leave a stale Sink projection or presentation owner.
set -euo pipefail

readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly CONTROL="$UMBRIEL_RUNTIME_DIR/sink-interrupt-control"
readonly CLIENT_LOG="$UMBRIEL_RUNTIME_DIR/sink-interrupt.log"

if [[ ! -x $CLIENT ]]; then
  echo "sink interruption client is not built"
  exit 1
fi

windows() { "$UMBRIEL" windows --json; }

wait_for_query() {
  local query=$1 message=$2
  for _ in $(seq 100); do
    if windows | jq -e "$query" > /dev/null; then
      return 0
    fi
    sleep 0.05
  done
  echo "$message: $(windows)"
  return 1
}

id_for() {
  windows | jq -r --arg title "$1" '.[] | select(.title == $title) | .id'
}

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[animation]
enabled = true

[animation.windows_in]
enabled = false

[animation.windows_move]
enabled = true
duration_ms = 800
curve = "linear"
EOF
"$UMBRIEL" msg config-reload > /dev/null

mkfifo "$CONTROL"
exec {control_fd}<>"$CONTROL"
MAXIMIZE_ON_STDIN=1 LOG_CONFIGURES=1 "$CLIENT" sink-interrupt 640 480 \
  <&"$control_fd" > "$CLIENT_LOG" 2>&1 &
wait_for_query 'any(.[]; .title == "sink-interrupt")' "interruption client did not map"
id=$(id_for sink-interrupt)

# Reverse the in-flight Sink immediately. The Pull must eventually return the
# live owner and focus; no stale Sink animation may win later.
"$UMBRIEL" msg "window-focus:$id" > /dev/null
"$UMBRIEL" msg window-sink > /dev/null
"$UMBRIEL" msg window-pull > /dev/null
wait_for_query 'any(.[]; .title == "sink-interrupt" and (.sunk == false) and .focused)' \
  "rapid Sink/Pull did not settle on the live owner"

# Start another Sink, reload while it is moving, then ask the client to change
# maximized state while no live window has focus. Pull must replay that state.
"$UMBRIEL" msg window-sink > /dev/null
wait_for_query 'any(.[]; .title == "sink-interrupt" and .sunk)' "second Sink did not start"
"$UMBRIEL" msg config-reload > /dev/null
printf m >&"$control_fd"
for _ in $(seq 100); do
  grep -q '^configured-maximized$' "$CLIENT_LOG" && break
  sleep 0.05
done
if ! grep -q '^configured-maximized$' "$CLIENT_LOG"; then
  echo "a Sunk client maximize request was not retained: $(< "$CLIENT_LOG")"
  exit 1
fi

# Disabling animations is a supported degradation. It settles geometry but
# does not bypass the configure/commit handoff before focus is restored.
sed -i '/^\[animation\]$/,/^\[animation\.windows_in\]$/ s/^enabled = true$/enabled = false/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
"$UMBRIEL" msg window-pull > /dev/null
wait_for_query 'any(.[]; .title == "sink-interrupt" and (.sunk == false) and .focused)' \
  "animation-disable Pull did not settle after the client commit"

# Closing while the projection is moving must invalidate every callback and
# deadline owned by that presentation.
"$UMBRIEL" msg window-sink > /dev/null
"$UMBRIEL" msg "window-close:$id" > /dev/null
wait_for_query 'all(.[]; .title != "sink-interrupt")' "closing an animating Sink left a live window"
exec {control_fd}>&-

echo "Sink reversal, reload, animation disable, maximized state, and close cleanup settled without stale owners"
