#!/usr/bin/env bash
# Sink/Pull is per-workspace LIFO state: it preserves base placement, unwinds explicit activation, and cleans up closes.
set -euo pipefail

readonly CLIENT="${UMBRIEL_SUBSURFACE_CLIENT:-./build-debug/tests/subsurface-client}"

if [[ ! -x $CLIENT ]]; then
  echo "sink logic client is not built"
  exit 1
fi

spawn_client() {
  EXIT_ON_CLOSE=1 "$CLIENT" "sink-$1" 640 480 > "$UMBRIEL_RUNTIME_DIR/sink-$1.log" 2>&1 &
}

windows() { "$UMBRIEL" windows --json; }
surfaces() { "$UMBRIEL" tearing --json | jq '.surfaces'; }

wait_for_query() {
  local query=$1 message=$2
  for _ in $(seq 80); do
    if windows | jq -e "$query" > /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "$message: $(windows)"
  return 1
}

wait_for_surface_query() {
  local query=$1 message=$2
  for _ in $(seq 80); do
    if surfaces | jq -e "$query" > /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "$message: $(surfaces)"
  return 1
}

id_for() {
  windows | jq -r --arg title "sink-$1" '.[] | select(.title == $title) | .id'
}

for name in a b c; do
  spawn_client "$name"
done
wait_for_query 'length == 3' "sink clients did not map"

for name in a b c; do
  id=$(id_for "$name")
  "$UMBRIEL" msg "window-focus:$id" > /dev/null
  "$UMBRIEL" msg window-sink > /dev/null
done

wait_for_query '
  any(.[]; .title == "sink-c" and .sunk and .sink_depth == 0 and .base_placement == "tiled")
  and any(.[]; .title == "sink-b" and .sunk and .sink_depth == 1)
  and any(.[]; .title == "sink-a" and .sunk and .sink_depth == 2)
  and all(.[]; .focused == false)
' "three sunk windows did not form a strict LIFO stack"

if ! "$UMBRIEL" workspaces --json | jq -e 'any(.[]; .active and .occupied and .sink_count == 3)' > /dev/null; then
  echo "a sink-only workspace lost occupancy: $("$UMBRIEL" workspaces --json)"
  exit 1
fi

# Explicit IPC activation of the oldest entry is an unwind, not a middle removal.
a_id=$(id_for a)
"$UMBRIEL" msg "window-focus:$a_id" > /dev/null
wait_for_query '
  all(.[]; (.sunk == false) and (.sink_depth == null))
  and any(.[]; .title == "sink-a" and .focused == true)
' "explicit activation did not unwind through the requested entry"

# The same attach/detach seam is used by all three tiled layouts.
for layout in master dwindle scrolling; do
  "$UMBRIEL" msg "workspace-set-layout:$layout" > /dev/null
  b_id=$(id_for b)
  "$UMBRIEL" msg "window-focus:$b_id" > /dev/null
  "$UMBRIEL" msg window-sink > /dev/null
  wait_for_query 'any(.[]; .title == "sink-b" and .sunk and .sink_depth == 0)' "$layout did not sink"
  "$UMBRIEL" msg window-pull > /dev/null
  wait_for_query 'any(.[]; .title == "sink-b" and (.sunk == false) and .focused)' "$layout did not pull"
done

# Floating geometry and base placement survive the round trip.
"$UMBRIEL" msg window-toggle-floating > /dev/null
wait_for_query 'any(.[]; .title == "sink-b" and .floating)' "floating setup failed"
before=$(windows | jq -c '.[] | select(.title == "sink-b") | [.x,.y,.w,.h]')
"$UMBRIEL" msg window-sink > /dev/null
wait_for_query 'any(.[]; .title == "sink-b" and .sunk and .floating and .base_placement == "floating")' \
  "floating sink lost base placement"
"$UMBRIEL" msg window-pull > /dev/null
wait_for_query 'any(.[]; .title == "sink-b" and (.sunk == false) and .floating)' "floating pull failed"
after=$(windows | jq -c '.[] | select(.title == "sink-b") | [.x,.y,.w,.h]')
if [[ $before != "$after" ]]; then
  echo "floating geometry changed across sink/pull: before=$before after=$after"
  exit 1
fi
"$UMBRIEL" msg window-toggle-floating > /dev/null

# Fullscreen is an orthogonal state in the MVP: Sink removes its live backdrop
# from the foreground, while Pull restores the same fullscreen state.
"$UMBRIEL" msg "window-focus:$a_id" > /dev/null
"$UMBRIEL" msg window-toggle-fullscreen > /dev/null
"$UMBRIEL" msg window-sink > /dev/null
wait_for_query 'any(.[]; .title == "sink-a" and .sunk)' "fullscreen window did not sink"
wait_for_surface_query 'any(.[]; .title == "sink-a" and .fullscreen)' "fullscreen state was not retained while sunk"
"$UMBRIEL" msg window-pull > /dev/null
wait_for_query 'any(.[]; .title == "sink-a" and (.sunk == false) and .focused)' \
  "Pull did not restore the fullscreen window"
wait_for_surface_query 'any(.[]; .title == "sink-a" and .fullscreen)' \
  "Pull did not restore the fullscreen presentation"
"$UMBRIEL" msg window-toggle-fullscreen > /dev/null

# Arbitrary lifecycle removal keeps survivor depths valid.
for name in a b c; do
  id=$(id_for "$name")
  "$UMBRIEL" msg "window-focus:$id" > /dev/null
  "$UMBRIEL" msg window-sink > /dev/null
done
b_id=$(id_for b)
c_id=$(id_for c)
"$UMBRIEL" msg "window-close:$b_id" > /dev/null
wait_for_query '
  length == 2
  and any(.[]; .title == "sink-c" and .sink_depth == 0)
  and any(.[]; .title == "sink-a" and .sink_depth == 1)
' "closing a middle entry corrupted the sink stack"
"$UMBRIEL" msg "window-close:$c_id" > /dev/null
wait_for_query 'length == 1 and .[0].title == "sink-a" and .[0].sink_depth == 0' \
  "closing the top entry did not expose the next entry"
"$UMBRIEL" msg "window-close:$a_id" > /dev/null
wait_for_query 'length == 0' "closing the last sunk entry left a dangling window"
if ! "$UMBRIEL" workspaces --json | jq -e 'all(.[]; .sink_count == 0)' > /dev/null; then
  echo "closing the sink stack left stale workspace membership: $("$UMBRIEL" workspaces --json)"
  exit 1
fi

# Empty pull is a safe no-op.
"$UMBRIEL" msg window-pull > /dev/null

echo "sink/pull preserves LIFO, activation unwind, layout membership, floating geometry, and lifecycle cleanup"
