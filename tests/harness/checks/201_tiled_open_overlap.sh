#!/usr/bin/env bash
# A new tiled window paints while established windows move into their new slots. Its entry animation must not wait for
# windows_move to finish, or the slot stays blank for the entire reflow.
set -euo pipefail

readonly IMAGE="$UMBRIEL_RUNTIME_DIR/tiled-open-overlap.png"
readonly MOVE_MS=2000

cat >> "$UMBRIEL_CONFIG" <<EOF

[colors]
backdrop = "#000000FF"

[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0

[appearance.shadow]
enabled = false

[layout]
mode = "dwindle"
gap = 0

[animation.windows_in]
enabled = true
style = "fade"
duration_ms = 250
curve = "linear"

[animation.windows_move]
enabled = true
duration_ms = $MOVE_MS
curve = "linear"
EOF
"$UMBRIEL" msg config-reload > /dev/null

spawn() {
  local title=$1 color=$2
  FILL_COLOR="$color" "$UMBRIEL_UNMAP_CLIENT" "$title" 1280 720 > "$UMBRIEL_RUNTIME_DIR/$title.log" 2>&1 &
  for _ in $(seq 100); do
    if "$UMBRIEL" windows --json | jq -e --arg title "$title" 'any(.[]; .title == $title)' > /dev/null; then
      return 0
    fi
    sleep 0.025
  done
  echo "timed out waiting for $title"
  return 1
}

spawn tiled-open-existing 0xFFFF0000
sleep 0.4
start_ms=$(date +%s%3N)
spawn tiled-open-new 0xFF0000FF
sleep 0.35
grim "$IMAGE"
capture_ms=$(date +%s%3N)

# Confirm the screenshot still belongs to the move transition, even on a slow test host.
if ((capture_ms - start_ms >= MOVE_MS - 300)); then
  echo "capture missed the moving phase: elapsed=$((capture_ms - start_ms))ms"
  exit 1
fi
blue_pixels=$(magick "$IMAGE" -alpha off -fx '(b > 0.3 && r < 0.1 && g < 0.1) ? 1 : 0' \
  -format '%[fx:round(mean*w*h)]\n' info:)
if ((blue_pixels < 10000)); then
  echo "new tiled window stayed hidden while peers moved: blue_pixels=$blue_pixels elapsed=$((capture_ms - start_ms))ms"
  exit 1
fi

echo "new tiled content appeared during the existing-window reflow"
