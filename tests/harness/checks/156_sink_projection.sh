#!/usr/bin/env bash
# WindowProjection keeps only the top two Sink entries visible, mirrors full-window subsurface content, and holds focus
# during Pull until the resize commit barrier completes or its bounded fallback expires.
set -euo pipefail

readonly CLIENT="${UMBRIEL_SUBSURFACE_CLIENT:-./build-debug/tests/subsurface-client}"
readonly SLOW_CLIENT="${UMBRIEL_SEAT_LOG_CLIENT:-./build-debug/tests/seat-log-client}"
readonly SHOT="$UMBRIEL_RUNTIME_DIR/sink-projection.png"
readonly REVEALED="$UMBRIEL_RUNTIME_DIR/sink-projection-revealed.png"
readonly DEPTH_THREE="$UMBRIEL_RUNTIME_DIR/sink-projection-depth-three.png"
readonly LEVEL_HIDDEN="$UMBRIEL_RUNTIME_DIR/sink-projection-level-hidden.png"

if [[ ! -x $CLIENT || ! -x $SLOW_CLIENT ]]; then
  echo "sink projection clients are not built"
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

blue_at() {
  magick "$1" -crop "1x1+$2+$3" -colorspace RGB -format '%[fx:round(255*mean.b)]' info:
}

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[colors]
backdrop = "#000000FF"

[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0

[appearance.sink]
visible_depth = 2
levels = [
  { scale = 0.93, opacity = 0.82, blur_strength = 0.5 },
  { scale = 0.85, opacity = 0.45, blur_strength = 1.0 },
  { scale = 0.85, opacity = 0.65, blur_strength = 1.0 },
]

[appearance.shadow]
enabled = false

[appearance.blur]
enabled = false

[animation]
enabled = true

[animation.windows_in]
enabled = false

[animation.windows_move]
enabled = true
duration_ms = 160
curve = "linear"

[[window_rule]]
match.title = "^sink-proj-a$"
default_floating = true
default_floating_size_px = { width = 800, height = 600 }
default_position = { x = 10, y = 10, anchor = "top_left" }

[[window_rule]]
match.title = "^sink-proj-b$"
default_floating = true
default_floating_size_px = { width = 600, height = 400 }
default_position = { x = 10, y = 10, anchor = "top_left" }

[[window_rule]]
match.title = "^sink-proj-c$"
default_floating = true
default_floating_size_px = { width = 400, height = 300 }
default_position = { x = 10, y = 10, anchor = "top_left" }
EOF
"$UMBRIEL" msg config-reload > /dev/null

for spec in "a 800 600" "b 600 400" "c 400 300"; do
  read -r name width height <<< "$spec"
  EXIT_ON_CLOSE=1 "$CLIENT" "sink-proj-$name" "$width" "$height" \
    > "$UMBRIEL_RUNTIME_DIR/sink-proj-$name.log" 2>&1 &
  wait_for_query "any(.[]; .title == \"sink-proj-$name\")" "sink-proj-$name did not map"
  id=$(id_for "sink-proj-$name")
  "$UMBRIEL" msg "window-focus:$id" > /dev/null
  "$UMBRIEL" msg window-sink > /dev/null
done

wait_for_query '
  any(.[]; .title == "sink-proj-c" and .sink_depth == 0)
  and any(.[]; .title == "sink-proj-b" and .sink_depth == 1)
  and any(.[]; .title == "sink-proj-a" and .sink_depth == 2)
' "sink projection depths did not settle"
sleep 0.4
grim "$SHOT"

# A is 800x600. At depth 2 its 680x510 projection would cover (320,360), but Horizon must disable it. B covers
# (400,360) at depth 1, and B+C overlap at the centre.
outer_blue=$(blue_at "$SHOT" 320 360)
cue_blue=$(blue_at "$SHOT" 400 360)
centre_blue=$(blue_at "$SHOT" 640 360)
if ((outer_blue > 20)); then
  echo "depth-2 projection crossed Horizon: blue=$outer_blue"
  exit 1
fi
if ((cue_blue < 35)); then
  echo "depth-1 context projection is missing: blue=$cue_blue"
  exit 1
fi
if ((centre_blue < 170)); then
  echo "top projection or mirrored subsurface is missing: blue=$centre_blue"
  exit 1
fi

# Reloading the horizon reveals A without changing the logical stack; changing
# its level opacity then hides only that projection. Restore depth 2 for Pull.
sed -i 's/^visible_depth = 2$/visible_depth = 3/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
sleep 0.2
grim "$DEPTH_THREE"
if (( $(blue_at "$DEPTH_THREE" 320 360) < 60 )); then
  echo "visible_depth=3 did not reveal the third projection"
  exit 1
fi
sed -i 's/scale = 0.85, opacity = 0.65/scale = 0.85, opacity = 0.0/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
sleep 0.2
grim "$LEVEL_HIDDEN"
if (( $(blue_at "$LEVEL_HIDDEN" 320 360) > 20 )); then
  echo "levels[2].opacity=0 did not hide the third projection"
  exit 1
fi
sed -i 's/^visible_depth = 3$/visible_depth = 2/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null

# Pulling C advances A into the visible horizon. The point previously covered only by hidden A must become blue.
"$UMBRIEL" msg window-pull > /dev/null
wait_for_query 'any(.[]; .title == "sink-proj-c" and (.sunk == false) and .focused)' \
  "top projection did not return to its live owner"
sleep 0.3
grim "$REVEALED"
revealed_blue=$(blue_at "$REVEALED" 320 360)
if ((revealed_blue < 35)); then
  echo "Pull did not reveal the entry crossing Horizon: blue=$revealed_blue"
  exit 1
fi

for title in sink-proj-a sink-proj-b sink-proj-c; do
  "$UMBRIEL" msg "window-close:$(id_for "$title")" > /dev/null
done
wait_for_query 'length == 0' "projection clients did not close"

# A mapped client that deliberately withholds its resize commit exercises the Pull barrier. Focus must remain away
# during the normal animation, then recover through the bounded 1.2 s degradation instead of hanging forever.
"$UMBRIEL" msg workspace-set-layout:master > /dev/null
control_fifo="$UMBRIEL_RUNTIME_DIR/sink-slow-control"
mkfifo "$control_fifo"
exec {control_fd}<>"$control_fifo"
HOLD_RESIZE=1 "$SLOW_CLIENT" sink-slow <&"$control_fd" > "$UMBRIEL_RUNTIME_DIR/sink-slow.log" 2>&1 &
wait_for_query 'any(.[]; .title == "sink-slow")' "slow client did not map"
slow_id=$(id_for sink-slow)
"$UMBRIEL" msg "window-focus:$slow_id" > /dev/null
"$UMBRIEL" msg window-sink > /dev/null

"$CLIENT" sink-peer 640 480 > "$UMBRIEL_RUNTIME_DIR/sink-peer.log" 2>&1 &
wait_for_query 'any(.[]; .title == "sink-peer")' "barrier peer did not map"
"$UMBRIEL" msg window-pull > /dev/null
sleep 0.4
if windows | jq -e 'any(.[]; .title == "sink-slow" and .focused)' > /dev/null; then
  echo "Pull focused a client before its held resize commit or deadline"
  exit 1
fi
wait_for_query 'any(.[]; .title == "sink-slow" and .focused)' \
  "Pull commit deadline did not provide bounded focus recovery"
printf x >&"$control_fd"
exec {control_fd}>&-

echo "Sink projection mirrors subsurfaces, reloads visible depth/levels, reveals on Pull, and bounds a slow commit barrier"
