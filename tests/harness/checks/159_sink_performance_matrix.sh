#!/usr/bin/env bash
# GPU timing is opt-in because querying timer results can synchronize with the
# renderer. Compare the same animated content and output mode across live,
# projection, and Top-2 Self Blur phases, then prove a static stack stays idle.
set -euo pipefail

readonly CLIENT="${UMBRIEL_SUBSURFACE_CLIENT:-./build-debug/tests/subsurface-client}"
readonly BASELINE="$(< "$UMBRIEL_CONFIG")"
PIDS=()

if [[ ${UMBRIEL_RENDER_TIMING:-0} != 1 ]]; then
  echo "159_sink_performance_matrix requires UMBRIEL_RENDER_TIMING=1"
  exit 1
fi
if [[ ! -x $CLIENT ]]; then
  echo "sink performance client is not built"
  exit 1
fi

cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

write_config() {
  local blur=$1 samples=$2
  printf '%s\n\n%s\n' "$BASELINE" "[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0

[appearance.shadow]
enabled = false

[appearance.blur]
enabled = false

[appearance.sink]
self_blur = $blur
blur_radius = 10
blur_samples = $samples

[animation]
enabled = false

[[window_rule]]
match.app_id = \"^sink-perf-\"
default_floating = true
default_floating_size_px = { width = 800, height = 600 }" > "$UMBRIEL_CONFIG"
  "$UMBRIEL" msg config-reload > /dev/null
}

wait_for_windows() {
  local query=$1 state=
  for _ in $(seq 100); do
    state=$("$UMBRIEL" windows --json)
    jq -e "$query" <<< "$state" > /dev/null && return 0
    sleep 0.05
  done
  echo "performance scene did not settle for $query: $state"
  return 1
}

start_pair() {
  local mode=${1:-}
  for suffix in a b; do
    "$CLIENT" "sink-perf-$suffix" 800 600 $mode > "$UMBRIEL_RUNTIME_DIR/sink-perf-$suffix.log" 2>&1 &
    PIDS+=("$!")
  done
  wait_for_windows 'length == 2'
}

sink_pair() {
  local a b
  b=$("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "sink-perf-b") | .id')
  "$UMBRIEL" msg "window-focus:$b" > /dev/null
  "$UMBRIEL" msg window-sink > /dev/null
  a=$("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "sink-perf-a") | .id')
  "$UMBRIEL" msg "window-focus:$a" > /dev/null
  "$UMBRIEL" msg window-sink > /dev/null
  wait_for_windows 'length == 2 and all(.[]; .sunk)'
}

stats() { "$UMBRIEL" render-stats --json | jq -c '.[0]'; }
current_mode_json() {
  jq -ce '
    [.[] | select(.enabled) | . as $output | .modes[] | select(.current) |
      {name: $output.name, width, height, refresh_mhz}] |
    if length == 1 then .[0] else error("expected one active output mode") end'
}
output_mode() { "$UMBRIEL" outputs --json | current_mode_json; }
parent_output_mode() {
  env -u UMBRIEL_SOCKET WAYLAND_DISPLAY="$UMBRIEL_PARENT_WAYLAND_SOCKET" \
    "$UMBRIEL" outputs --json | current_mode_json
}
check_parent_mode() {
  if [[ ${CHECK_BACKEND:-headless} == wayland && $(parent_output_mode) != "$PARENT_OUTPUT_MODE" ]]; then
    echo 'host output mode changed during performance sampling' >&2
    return 1
  fi
}

measure() {
  local label=$1 before after samples total frames rss_kb gpu_samples gpu_total mode_before mode_after
  sleep 0.25
  mode_before=$(output_mode)
  if [[ $mode_before != "$OUTPUT_MODE" ]]; then
    echo "$label output mode changed before sampling: $OUTPUT_MODE -> $mode_before" >&2
    return 1
  fi
  check_parent_mode
  before=$(stats)
  sleep 2
  after=$(stats)
  mode_after=$(output_mode)
  if [[ $mode_after != "$OUTPUT_MODE" ]]; then
    echo "$label output mode changed during sampling: $OUTPUT_MODE -> $mode_after" >&2
    return 1
  fi
  check_parent_mode
  samples=$(jq -n --argjson a "$after" --argjson b "$before" '$a.cpu_samples - $b.cpu_samples')
  total=$(jq -n --argjson a "$after" --argjson b "$before" '$a.cpu_total_ns - $b.cpu_total_ns')
  frames=$(jq -n --argjson a "$after" --argjson b "$before" '$a.rendered_frames - $b.rendered_frames')
  gpu_samples=$(jq -n --argjson a "$after" --argjson b "$before" '$a.gpu_samples - $b.gpu_samples')
  gpu_total=$(jq -n --argjson a "$after" --argjson b "$before" '$a.gpu_total_ns - $b.gpu_total_ns')
  rss_kb=$(awk '/^VmRSS:/ { print $2 }' "/proc/$UMBRIEL_SERVER_PID/status")
  if ((samples < 30 || frames < 30)); then
    echo "$label produced too few timed frames: samples=$samples frames=$frames" >&2
    return 1
  fi
  if [[ ${CHECK_BACKEND:-headless} == wayland ]] && ((gpu_samples < 30)); then
    echo "$label produced too few GPU timer samples: $gpu_samples" >&2
    return 1
  fi
  jq -cn \
    --arg phase "$label" \
    --arg backend "${CHECK_BACKEND:-headless}" \
    --argjson output_mode "$OUTPUT_MODE" \
    --argjson parent_output_mode "$PARENT_OUTPUT_MODE" \
    --argjson samples "$samples" \
    --argjson total_ns "$total" \
    --argjson rendered_frames "$frames" \
    --argjson gpu_samples "$gpu_samples" \
    --argjson gpu_total_ns "$gpu_total" \
    --argjson rss_kb "$rss_kb" \
    '{phase: $phase, backend: $backend, output_mode: $output_mode,
      parent_output_mode: $parent_output_mode,
      samples: $samples, rendered_frames: $rendered_frames,
      average_cpu_ms: ($total_ns / $samples / 1000000), gpu_samples: $gpu_samples,
      average_gpu_ms: (if $gpu_samples > 0 then $gpu_total_ns / $gpu_samples / 1000000 else null end),
      rss_kb: $rss_kb}'
}

write_config false 9
start_pair animate
OUTPUT_MODE=$(output_mode)
PARENT_OUTPUT_MODE=null
if [[ ${CHECK_BACKEND:-headless} == wayland ]]; then
  PARENT_OUTPUT_MODE=$(parent_output_mode)
fi
live=$(measure live)

sink_pair
projected=$(measure top2-no-blur)

write_config true 9
blur9=$(measure top2-blur-9)

write_config true 17
blur17=$(measure top2-blur-17)

cleanup
PIDS=()
wait_for_windows 'length == 0'

# Recreate the same Top-2 projection with static clients. Once config reload and
# Sink settle, a one-second observation must not render another frame.
start_pair
sink_pair
sleep 0.25
[[ $(output_mode) == "$OUTPUT_MODE" ]] || { echo 'output mode changed before idle sampling' >&2; exit 1; }
check_parent_mode
idle_before=$(stats)
sleep 1
idle_after=$(stats)
[[ $(output_mode) == "$OUTPUT_MODE" ]] || { echo 'output mode changed during idle sampling' >&2; exit 1; }
check_parent_mode
idle_renders=$(jq -n --argjson a "$idle_after" --argjson b "$idle_before" '$a.rendered_frames - $b.rendered_frames')
idle_callbacks=$(jq -n --argjson a "$idle_after" --argjson b "$idle_before" '$a.frame_callbacks - $b.frame_callbacks')
if ((idle_renders != 0)); then
  echo "static Top-2 Self Blur redrew while idle: renders=$idle_renders callbacks=$idle_callbacks"
  exit 1
fi

printf '%s\n%s\n%s\n%s\n' "$live" "$projected" "$blur9" "$blur17"
echo "idle: rendered_frames=$idle_renders frame_callbacks=$idle_callbacks over 1s"
