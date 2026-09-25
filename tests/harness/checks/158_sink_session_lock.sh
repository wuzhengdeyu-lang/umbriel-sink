#!/usr/bin/env bash
# A Sunk projection must stay behind the session-lock scene and remain Sunk
# after unlock. Screencopy while locked must contain only the lock surface.
set -euo pipefail

readonly WINDOW_CLIENT="${UMBRIEL_SUBSURFACE_CLIENT:-./build-debug/tests/subsurface-client}"
readonly LOCK_CLIENT="${UMBRIEL_LOCK_CLIENT:-./build-debug/tests/lock-client}"
readonly LOCK_LOG="$UMBRIEL_RUNTIME_DIR/sink-lock.log"
readonly LOCK_FIFO="$UMBRIEL_RUNTIME_DIR/sink-lock-control"
readonly SHOT="$UMBRIEL_RUNTIME_DIR/sink-lock.png"

windows() { "$UMBRIEL" windows --json; }

EXIT_ON_CLOSE=1 "$WINDOW_CLIENT" sink-lock-window 640 480 > "$UMBRIEL_RUNTIME_DIR/sink-lock-window.log" 2>&1 &
for _ in $(seq 80); do
  windows | jq -e 'any(.[]; .title == "sink-lock-window")' > /dev/null && break
  sleep 0.05
done
id=$(windows | jq -r '.[] | select(.title == "sink-lock-window") | .id')
if [[ -z $id ]]; then
  echo "sink lock window did not map: $(windows)"
  exit 1
fi
"$UMBRIEL" msg "window-focus:$id" > /dev/null
"$UMBRIEL" msg window-sink > /dev/null
if ! windows | jq -e 'any(.[]; .title == "sink-lock-window" and .sunk and (.active == false))' > /dev/null; then
  echo "window did not become an inactive Sink entry: $(windows)"
  exit 1
fi

mkfifo "$LOCK_FIFO"
exec {lock_fd}<> "$LOCK_FIFO"
"$LOCK_CLIENT" <&"$lock_fd" > "$LOCK_LOG" 2>&1 &
for _ in $(seq 100); do
  grep -q '^locked$' "$LOCK_LOG" && break
  sleep 0.05
done
if ! grep -q '^locked$' "$LOCK_LOG"; then
  echo "session did not lock: $(< "$LOCK_LOG")"
  exit 1
fi

grim -o HEADLESS-1 "$SHOT"
read -r red green blue < <(
  magick "$SHOT" -crop 1x1+640+360 \
    -format '%[fx:round(255*mean.r)] %[fx:round(255*mean.g)] %[fx:round(255*mean.b)]\n' info:
)
if ((red < 13 || red > 19 || green < 29 || green > 35 || blue < 45 || blue > 51)); then
  echo "locked capture exposed non-lock content at centre: rgb=$red,$green,$blue"
  exit 1
fi
if [[ -n $(windows | jq -r '.[] | select(.active) | .title') ]]; then
  echo "session lock activated a normal window: $(windows)"
  exit 1
fi

echo unlock >&"$lock_fd"
for _ in $(seq 100); do
  grep -q '^unlocked$' "$LOCK_LOG" && break
  sleep 0.05
done
if ! grep -q '^unlocked$' "$LOCK_LOG"; then
  echo "session did not unlock: $(< "$LOCK_LOG")"
  exit 1
fi
if ! windows | jq -e \
  'any(.[]; .title == "sink-lock-window" and .sunk and (.active == false) and .sink_depth == 0)' > /dev/null; then
  echo "unlock changed Sink membership or focus: $(windows)"
  exit 1
fi

"$UMBRIEL" msg "window-close:$id" > /dev/null
for _ in $(seq 60); do
  windows | jq -e 'all(.[]; .title != "sink-lock-window")' > /dev/null && break
  sleep 0.05
done
if ! windows | jq -e 'all(.[]; .title != "sink-lock-window")' > /dev/null; then
  echo "closing the locked Sink entry left stale state: $(windows)"
  exit 1
fi

echo "session lock hid Sink content from focus and capture, then preserved its stack entry"
