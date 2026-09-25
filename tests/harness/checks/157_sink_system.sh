#!/usr/bin/env bash
# harness: outputs=2
# P3 keeps Sink orthogonal to system state: Overview selection unwinds explicitly,
# output evacuation preserves each source LIFO order, and returning outputs restore it.
set -euo pipefail

readonly CLIENT="${UMBRIEL_SUBSURFACE_CLIENT:-./build-debug/tests/subsurface-client}"
readonly POINTER="${UMBRIEL_POINTER_CLIENT:-./build-debug/tests/pointer-client}"
readonly OUTPUT_MANAGEMENT="${UMBRIEL_OUTPUT_MANAGEMENT_CLIENT:-./build-debug/tests/output-management-client}"
readonly BTN_LEFT=272

if [[ ! -x $CLIENT || ! -x $POINTER || ! -x $OUTPUT_MANAGEMENT ]]; then
  echo "sink system clients are not built"
  exit 1
fi

windows() { "$UMBRIEL" windows --json; }

wait_for_query() {
  local query=$1 message=$2
  for _ in $(seq 100); do
    if windows | jq -e "$query" > /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "$message: $(windows)"
  return 1
}

id_for() {
  windows | jq -r --arg title "$1" '.[] | select(.title == $title) | .id'
}

spawn_client() {
  EXIT_ON_CLOSE=1 "$CLIENT" "$1" 400 300 > "$UMBRIEL_RUNTIME_DIR/$1.log" 2>&1 &
  wait_for_query "any(.[]; .title == \"$1\")" "$1 did not map"
}

move_to() {
  local title=$1 selector=$2
  "$UMBRIEL" msg "window-focus:$(id_for "$title")" > /dev/null
  "$UMBRIEL" msg "window-move-to-workspace:$selector" > /dev/null
  wait_for_query \
    "any(.[]; .title == \"$title\" and (.workspace | startswith(\"${selector#*/}:\")))" \
    "$title did not move to $selector"
}

sink_named() {
  local title=$1
  "$UMBRIEL" msg "window-focus:$(id_for "$title")" > /dev/null
  "$UMBRIEL" msg window-sink > /dev/null
  wait_for_query "any(.[]; .title == \"$title\" and .sunk)" "$title did not sink"
}

# A known floating box makes its settled Overview card deterministic on the
# first 1280x720 output: default zoom 0.5 places its centre at (470, 305).
cat >> "$UMBRIEL_CONFIG" <<'EOF'

[[window_rule]]
match.title = "^sink-overview$"
default_floating = true
default_floating_size_px = { width = 400, height = 300 }
default_position = { x = 100, y = 100, anchor = "top_left" }
EOF
"$UMBRIEL" msg config-reload > /dev/null

"$UMBRIEL" msg workspace-switch:1/HEADLESS-1 > /dev/null
spawn_client sink-overview
sink_named sink-overview
"$UMBRIEL" msg overview-open > /dev/null
sleep 0.6
read -r overview_x overview_y < <(
  "$UMBRIEL" outputs --json \
    | jq -r '.[] | select(.name == "HEADLESS-1") | "\(.position.x) \(.position.y)"'
)
"$POINTER" 2560 720 move "$((overview_x + 470))" "$((overview_y + 305))" click "$BTN_LEFT"
wait_for_query 'any(.[]; .title == "sink-overview" and (.sunk == false) and .focused)' \
  "selecting a Sunk Overview card did not unwind it"
"$UMBRIEL" msg "window-close:$(id_for sink-overview)" > /dev/null
wait_for_query 'all(.[]; .title != "sink-overview")' "overview client did not close"

# Give the refuge output an existing bottom entry, then build A/B/C on the
# source. Evacuation must append A,B,C bottom-to-top, so C remains the top.
spawn_client sink-target
move_to sink-target 1/HEADLESS-2
sink_named sink-target

"$UMBRIEL" msg workspace-switch:1/HEADLESS-1 > /dev/null
for name in a b c; do
  spawn_client "sink-migrate-$name"
  sink_named "sink-migrate-$name"
done

"$UMBRIEL" output-destroy HEADLESS-1 > /dev/null
wait_for_query '
  any(.[]; .title == "sink-migrate-c" and .sunk and .sink_depth == 0 and (.workspace | startswith("HEADLESS-2:")))
  and any(.[]; .title == "sink-migrate-b" and .sink_depth == 1)
  and any(.[]; .title == "sink-migrate-a" and .sink_depth == 2)
  and any(.[]; .title == "sink-target" and .sink_depth == 3)
' "output evacuation did not append the source Sink stack deterministically"

created=$("$UMBRIEL" output-create HEADLESS-1)
if [[ $created != HEADLESS-1 ]]; then
  echo "expected restored output HEADLESS-1, got '$created'"
  exit 1
fi
wait_for_query '
  any(.[]; .title == "sink-migrate-c" and .sunk and .sink_depth == 0 and (.workspace | startswith("HEADLESS-1:")))
  and any(.[]; .title == "sink-migrate-b" and .sink_depth == 1)
  and any(.[]; .title == "sink-migrate-a" and .sink_depth == 2)
  and any(.[]; .title == "sink-target" and .sink_depth == 0 and (.workspace | startswith("HEADLESS-2:")))
' "returning output did not restore the source Sink stack"

# Protocol disable follows the same displaced-home contract as physical
# removal, but keeps the output object alive. It must neither retain sampling
# on the disabled output nor reverse the stack when the output is enabled.
read -r first_x first_y < <(
  "$UMBRIEL" outputs --json \
    | jq -r '.[] | select(.name == "HEADLESS-1") | "\(.position.x) \(.position.y)"'
)
"$OUTPUT_MANAGEMENT" apply disable HEADLESS-1 > /dev/null
wait_for_query '
  any(.[]; .title == "sink-migrate-c" and .sunk and .sink_depth == 0 and (.workspace | startswith("HEADLESS-2:")))
  and any(.[]; .title == "sink-migrate-b" and .sink_depth == 1)
  and any(.[]; .title == "sink-migrate-a" and .sink_depth == 2)
  and any(.[]; .title == "sink-target" and .sink_depth == 3)
' "protocol output disable did not evacuate the Sink stack"
"$OUTPUT_MANAGEMENT" apply enable HEADLESS-1 "$first_x" "$first_y" > /dev/null
wait_for_query '
  any(.[]; .title == "sink-migrate-c" and .sunk and .sink_depth == 0 and (.workspace | startswith("HEADLESS-1:")))
  and any(.[]; .title == "sink-migrate-b" and .sink_depth == 1)
  and any(.[]; .title == "sink-migrate-a" and .sink_depth == 2)
  and any(.[]; .title == "sink-target" and .sink_depth == 0 and (.workspace | startswith("HEADLESS-2:")))
' "protocol output enable did not restore the Sink stack"

echo "Overview selection, output hotplug, and protocol disable preserved deterministic LIFO stacks"
