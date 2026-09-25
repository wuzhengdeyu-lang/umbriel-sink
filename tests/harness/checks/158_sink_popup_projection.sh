#!/usr/bin/env bash
# A live non-grabbed popup is part of its owner's Sink projection, while an
# active popup grab is dismissed when Sink clears normal focus.
set -euo pipefail

readonly OUTPUT_W=1280
readonly OUTPUT_H=720
readonly BTN_LEFT=272
readonly POPUP_CLIENT="${UMBRIEL_POPUP_CLIENT:-./build-debug/tests/popup-client}"
readonly POINTER="${UMBRIEL_POINTER_CLIENT:-./build-debug/tests/pointer-client}"
readonly CLIENT_LOG="$UMBRIEL_RUNTIME_DIR/sink-popup.log"
readonly SHOT="$UMBRIEL_RUNTIME_DIR/sink-popup.png"

wait_for_log() {
  local expected=$1
  for _ in $(seq 80); do
    grep -qx "$expected" "$CLIENT_LOG" 2>/dev/null && return 0
    sleep 0.05
  done
  echo "timed out waiting for '$expected': $(< "$CLIENT_LOG")"
  return 1
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
EOF
"$UMBRIEL" msg config-reload > /dev/null

POPUP_NO_GRAB=1 "$POPUP_CLIENT" > "$CLIENT_LOG" 2>&1 &
client_pid=$!
wait_for_log ready

window=''
for _ in $(seq 80); do
  window=$("$UMBRIEL" windows --json | jq -c '.[] | select(.title == "popup-focus-regression")')
  [[ -n $window ]] && break
  sleep 0.05
done
id=$(jq -r '.id' <<< "$window")
if [[ -z $id || $id == null ]]; then
  echo "popup owner did not map: $("$UMBRIEL" windows --json)"
  exit 1
fi

"$POINTER" "$OUTPUT_W" "$OUTPUT_H" move 640 360 click "$BTN_LEFT"
wait_for_log popup-mapped
"$UMBRIEL" msg "window-focus:$id" > /dev/null
"$UMBRIEL" msg window-sink > /dev/null
for _ in $(seq 80); do
  "$UMBRIEL" windows --json \
    | jq -e 'any(.[]; .title == "popup-focus-regression" and .sunk and .sink_depth == 0)' > /dev/null \
    && break
  sleep 0.05
done
if ! "$UMBRIEL" windows --json \
  | jq -e 'any(.[]; .title == "popup-focus-regression" and .sunk and .sink_depth == 0)' > /dev/null; then
  echo "popup owner did not sink: $("$UMBRIEL" windows --json)"
  exit 1
fi

grim -o HEADLESS-1 "$SHOT"
# The 1260x700 owner settles at 1172x651 around (54,34). Its popup begins
# around (73,53), remains orange, and must render above the blue owner.
read -r popup_r popup_g popup_b < <(
  magick "$SHOT" -crop 8x8+82+62 \
    -format '%[fx:round(255*mean.r)] %[fx:round(255*mean.g)] %[fx:round(255*mean.b)]\n' info:
)
read -r owner_r owner_g owner_b < <(
  magick "$SHOT" -crop 8x8+630+350 \
    -format '%[fx:round(255*mean.r)] %[fx:round(255*mean.g)] %[fx:round(255*mean.b)]\n' info:
)
if ((popup_r < popup_g + 20 || popup_g < popup_b + 20)); then
  echo "Sink projection lost or covered its popup: popup=$popup_r,$popup_g,$popup_b"
  exit 1
fi
if ((owner_b < owner_r + 30 || owner_b < owner_g + 20)); then
  echo "Sink projection owner content is missing: owner=$owner_r,$owner_g,$owner_b"
  exit 1
fi

kill "$client_pid"
wait "$client_pid" 2>/dev/null || true
for _ in $(seq 80); do
  "$UMBRIEL" windows --json | jq -e 'all(.[]; .title != "popup-focus-regression")' > /dev/null && break
  sleep 0.05
done
if ! "$UMBRIEL" windows --json | jq -e 'all(.[]; .title != "popup-focus-regression")' > /dev/null; then
  echo "destroying popup owner left a stale Sink entry: $("$UMBRIEL" windows --json)"
  exit 1
fi

echo "Sink projection kept a live popup above its owner and cleaned both on destroy"
