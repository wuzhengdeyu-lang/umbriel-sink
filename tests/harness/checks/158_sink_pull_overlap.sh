#!/usr/bin/env bash
# Pull reveals a scrolling column while its projection moves into place. The established column must start scrolling
# in the same transition, without waiting for the projection's animation and deferred keyboard focus.
set -euo pipefail

readonly MOVE_MS=1500
readonly BEFORE="$UMBRIEL_RUNTIME_DIR/sink-pull-overlap-before.png"
readonly DURING="$UMBRIEL_RUNTIME_DIR/sink-pull-overlap-during.png"

cat >> "$UMBRIEL_CONFIG" <<EOF

[colors]
backdrop = "#000000FF"

[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0

[appearance.shadow]
enabled = false

[appearance.blur]
enabled = false

[layout]
mode = "scrolling"
gap = 0

[layout.scrolling]
default_extent_fraction = 0.75
center_focused = "never"
center_underfull_strip = false

[animation.windows_in]
enabled = false

[animation.windows_move]
enabled = true
duration_ms = $MOVE_MS
curve = "linear"

[animation.dim_unfocused]
enabled = false
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

red_at_right() {
  magick "$1" -format '%[fx:round(255*p{880,10}.r)]\n' info:
}

spawn sink-pull-peer 0xFFFF0000
spawn sink-pull-returning 0xFF0000FF
returning_id=$("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "sink-pull-returning") | .id')
"$UMBRIEL" msg "window-focus:$returning_id" > /dev/null
sleep 1.7
"$UMBRIEL" msg window-sink > /dev/null
sleep 1.7
grim "$BEFORE"
red_before=$(red_at_right "$BEFORE")
if ((red_before < 200)); then
  echo "setup did not leave the red peer across the right sample: red=$red_before"
  exit 1
fi

start_ms=$(date +%s%3N)
"$UMBRIEL" msg window-pull > /dev/null
sleep 0.45
grim "$DURING"
elapsed_ms=$(($(date +%s%3N) - start_ms))
if ((elapsed_ms >= MOVE_MS - 200)); then
  echo "capture missed the Pull transition: elapsed=${elapsed_ms}ms"
  exit 1
fi
red_during=$(red_at_right "$DURING")
if ((red_during > 100)); then
  echo "scrolling peer waited for Pull to finish before moving: before=$red_before during=$red_during elapsed=${elapsed_ms}ms"
  exit 1
fi
if "$UMBRIEL" windows --json | jq -e \
  'any(.[]; .title == "sink-pull-returning" and .focused)' > /dev/null; then
  echo "Pull handed focus to its live window before the projection finished"
  exit 1
fi

echo "scrolling peers made room while the Pull projection was still moving"
