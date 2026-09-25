#!/usr/bin/env bash
# Self Blur samples the projection itself, keeps its output clipped to the
# projection box, and can be removed live without changing Sink state.
set -euo pipefail

readonly CLIENT="${UMBRIEL_SUBSURFACE_CLIENT:-./build-debug/tests/subsurface-client}"
readonly PLAIN="$UMBRIEL_RUNTIME_DIR/sink-blur-plain.png"
readonly BLURRED="$UMBRIEL_RUNTIME_DIR/sink-blur-enabled.png"
readonly RESTORED="$UMBRIEL_RUNTIME_DIR/sink-blur-restored.png"
readonly FAILURE_MODE="${UMBRIEL_TEST_SELF_BLUR_SHADER_FAILURE:-}"
readonly CAPTURE_FAILURE="${UMBRIEL_TEST_SELF_BLUR_CAPTURE_FAILURE:-}"

case $FAILURE_MODE in
  '' | axis | all) ;;
  *) echo "unexpected Self Blur shader failure mode: $FAILURE_MODE" >&2; exit 1 ;;
esac
case $CAPTURE_FAILURE in
  '' | first | second) ;;
  *) echo "unexpected Self Blur capture failure mode: $CAPTURE_FAILURE" >&2; exit 1 ;;
esac
if [[ -n $FAILURE_MODE && -n $CAPTURE_FAILURE ]]; then
  echo 'test only one Self Blur failure mode at a time' >&2
  exit 1
fi

if [[ ! -x $CLIENT ]]; then
  echo "sink self-blur client is not built"
  exit 1
fi

blue_at() {
  magick "$1" -crop "1x1+$2+$3" -colorspace RGB -format '%[fx:round(255*mean.b)]' info:
}

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0

[appearance.shadow]
enabled = false

[appearance.blur]
enabled = false

[appearance.sink]
self_blur = false
blur_radius = 10
blur_samples = 9

[animation]
enabled = false

[[window_rule]]
match.title = "^sink-self-blur$"
default_floating = true
default_floating_size_px = { width = 400, height = 300 }
EOF
"$UMBRIEL" msg config-reload > /dev/null

"$CLIENT" sink-self-blur 400 300 > "$UMBRIEL_RUNTIME_DIR/sink-self-blur.log" 2>&1 &
for _ in $(seq 100); do
  if "$UMBRIEL" windows --json | jq -e 'any(.[]; .title == "sink-self-blur")' > /dev/null; then
    break
  fi
  sleep 0.05
done
if ! "$UMBRIEL" windows --json | jq -e 'any(.[]; .title == "sink-self-blur")' > /dev/null; then
  echo "sink self-blur client did not map"
  exit 1
fi
"$UMBRIEL" msg window-sink > /dev/null
sleep 0.15
grim "$PLAIN"

# The 400x300 source becomes a centered 372x279 depth-0 projection on the
# 1280x720 harness output. Its centre remains uniform blue; a pixel just inside
# the left edge loses blue energy only when the projection capture is blurred.
plain_edge=$(blue_at "$PLAIN" 455 360)
plain_center=$(blue_at "$PLAIN" 640 360)
plain_outside=$(blue_at "$PLAIN" 450 360)
if ((plain_edge < 100 || plain_center < 150)); then
  echo "Self Blur baseline client is missing: edge=$plain_edge center=$plain_center"
  exit 1
fi

sed -i '/^\[appearance\.sink\]$/,/^\[/ s/^self_blur = false$/self_blur = true/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
sleep 0.15
grim "$BLURRED"
blurred_edge=$(blue_at "$BLURRED" 455 360)
blurred_center=$(blue_at "$BLURRED" 640 360)
blurred_outside=$(blue_at "$BLURRED" 450 360)

if [[ -n $CAPTURE_FAILURE ]] && ! grep -q \
  "Injected Self Blur capture allocation failure at index $([[ $CAPTURE_FAILURE == first ]] && echo 0 || echo 1)" \
  "$UMBRIEL_LOG"; then
  echo "Self Blur $CAPTURE_FAILURE capture failure was not injected"
  exit 1
fi
if [[ $FAILURE_MODE == all || $CAPTURE_FAILURE == first ]]; then
  if ((plain_edge - blurred_edge > 5 || blurred_edge - plain_edge > 5)); then
    echo "shader failure changed the unblurred projection edge: $plain_edge -> $blurred_edge"
    exit 1
  fi
else
  if ((plain_edge - blurred_edge < 20)); then
    echo "Self Blur did not attenuate the projection edge: $plain_edge -> $blurred_edge"
    exit 1
  fi
fi
if ((plain_center - blurred_center > 10 || blurred_center - plain_center > 10)); then
  echo "Self Blur changed the uniform projection centre: $plain_center -> $blurred_center"
  exit 1
fi
if ((plain_outside - blurred_outside > 5 || blurred_outside - plain_outside > 5)); then
  echo "Self Blur escaped its projection clip: $plain_outside -> $blurred_outside"
  exit 1
fi

sed -i '/^\[appearance\.sink\]$/,/^\[/ s/^self_blur = true$/self_blur = false/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
sleep 0.15
grim "$RESTORED"
restored_edge=$(blue_at "$RESTORED" 455 360)
if ((plain_edge - restored_edge > 5 || restored_edge - plain_edge > 5)); then
  echo "disabling Self Blur did not restore scale/opacity presentation: $plain_edge -> $restored_edge"
  exit 1
fi
if ! "$UMBRIEL" windows --json | jq -e \
  'any(.[]; .title == "sink-self-blur" and .sunk and .sink_depth == 0)' > /dev/null; then
  echo "Self Blur reload changed Sink semantics: $("$UMBRIEL" windows --json)"
  exit 1
fi

echo "Self Blur mode '${FAILURE_MODE:-${CAPTURE_FAILURE:-normal}}' preserved projection, edge policy, and Sink state"
