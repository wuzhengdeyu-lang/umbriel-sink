#!/usr/bin/env bash
# A visible toplevel inhibits idle, stops inhibiting in Sink, resumes after
# Pull, and stops again on an inactive workspace while its protocol stays alive.
set -euo pipefail

readonly CLIENT="${UMBRIEL_IDLE_INHIBIT_CLIENT:-./build-debug/tests/idle-inhibit-client}"
CLIENT_LOG="$UMBRIEL_RUNTIME_DIR/idle-inhibit-client.log"

"$CLIENT" > "$CLIENT_LOG" 2>&1 &

for _ in $(seq 40); do
  grep -q '^mapped$' "$CLIENT_LOG" && break
  sleep 0.05
done
if ! grep -q '^mapped$' "$CLIENT_LOG"; then
  echo "idle inhibitor client never mapped: $(cat "$CLIENT_LOG")"
  exit 1
fi

sleep 0.35
if grep -q '^idled$' "$CLIENT_LOG"; then
  echo "visible surface failed to inhibit idle"
  exit 1
fi

"$UMBRIEL" msg window-sink > /dev/null
for _ in $(seq 40); do
  grep -q '^idled$' "$CLIENT_LOG" && break
  sleep 0.05
done
if ! grep -q '^idled$' "$CLIENT_LOG"; then
  echo "Sunk surface continued to inhibit idle: $(cat "$CLIENT_LOG")"
  exit 1
fi

"$UMBRIEL" msg window-pull > /dev/null
for _ in $(seq 40); do
  grep -q '^resumed$' "$CLIENT_LOG" && break
  sleep 0.05
done
if ! grep -q '^resumed$' "$CLIENT_LOG"; then
  echo "Pull did not restore the visible idle inhibitor: $(cat "$CLIENT_LOG")"
  exit 1
fi

"$UMBRIEL" msg workspace-switch:2 > /dev/null
for _ in $(seq 40); do
  [[ $(grep -c '^idled$' "$CLIENT_LOG") -ge 2 ]] && break
  sleep 0.05
done
if [[ $(grep -c '^idled$' "$CLIENT_LOG") -lt 2 ]]; then
  echo "inactive workspace continued to inhibit idle: $(cat "$CLIENT_LOG")"
  exit 1
fi

echo "idle inhibitor follows Sink and workspace visibility"
