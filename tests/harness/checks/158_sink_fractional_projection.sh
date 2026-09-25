#!/usr/bin/env bash
# Fractional output scale must not leave a one-pixel gap around the scaled Sink
# projection or leak the projection outside its computed physical bounds.
set -euo pipefail

readonly CLIENT="${UMBRIEL_SUBSURFACE_CLIENT:-./build-debug/tests/subsurface-client}"
readonly SHOT="$UMBRIEL_RUNTIME_DIR/sink-fractional.png"

blue_at() {
  magick "$1" -crop "1x1+$2+$3" -format '%[fx:round(255*mean.b)]' info:
}

cat >> "$UMBRIEL_CONFIG" <<'EOF'

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

[animation]
enabled = false

[output."HEADLESS-1"]
scale = 1.25

[[window_rule]]
match.title = "^sink-fractional$"
default_floating = true
default_floating_size_px = { width = 400, height = 300 }
EOF
"$UMBRIEL" msg config-reload > /dev/null

EXIT_ON_CLOSE=1 "$CLIENT" sink-fractional 400 300 > "$UMBRIEL_RUNTIME_DIR/sink-fractional.log" 2>&1 &
for _ in $(seq 80); do
  "$UMBRIEL" windows --json | jq -e 'any(.[]; .title == "sink-fractional")' > /dev/null && break
  sleep 0.05
done
id=$("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "sink-fractional") | .id')
if [[ -z $id ]]; then
  echo "fractional Sink client did not map"
  exit 1
fi
"$UMBRIEL" msg "window-focus:$id" > /dev/null
"$UMBRIEL" msg window-sink > /dev/null
sleep 0.15
grim -o HEADLESS-1 "$SHOT"

# Logical output 1024x576: a 400x300 source at depth 0 becomes 372x279 at
# (326,148). Scaling each edge by 5/4 produces [408,873) x [185,534).
left_inside=$(blue_at "$SHOT" 408 360)
right_inside=$(blue_at "$SHOT" 872 360)
top_inside=$(blue_at "$SHOT" 640 185)
bottom_inside=$(blue_at "$SHOT" 640 533)
left_outside=$(blue_at "$SHOT" 407 360)
right_outside=$(blue_at "$SHOT" 873 360)
top_outside=$(blue_at "$SHOT" 640 184)
bottom_outside=$(blue_at "$SHOT" 640 534)

for sample in "$left_inside" "$right_inside" "$top_inside" "$bottom_inside"; do
  if ((sample < 80)); then
    echo "fractional Sink projection left an uncovered inside edge: inside=$left_inside,$right_inside,$top_inside,$bottom_inside"
    exit 1
  fi
done
for sample in "$left_outside" "$right_outside" "$top_outside" "$bottom_outside"; do
  if ((sample > 10)); then
    echo "fractional Sink projection escaped its physical bounds: outside=$left_outside,$right_outside,$top_outside,$bottom_outside"
    exit 1
  fi
done

echo "fractional Sink projection exactly covered its 465x349 physical bounds"
