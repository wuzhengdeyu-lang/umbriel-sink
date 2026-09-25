#!/usr/bin/env bash
# Isolated real-application Sink/Pull smoke run. This is intentionally separate
# from the synthetic harness: Firefox and an X11 GTK dialog are optional apps.
set -euo pipefail

readonly UMBRIEL_BINARY=$(realpath "${1:-./build-debug/umbriel}")
readonly RUN_DIR=$(mktemp -d /tmp/umbriel-sink-apps.XXXXXXXX)
readonly DWELL_TICKS=${UMBRIEL_APP_DWELL_TICKS:-12}
readonly APP_BACKEND=${UMBRIEL_APP_BACKEND:-headless}
readonly PARENT_RUNTIME=${XDG_RUNTIME_DIR:-}
readonly PARENT_DISPLAY=${WAYLAND_DISPLAY:-}
readonly SOCKET="$RUN_DIR/umbriel-wayland-0.sock"
readonly CONFIG="$RUN_DIR/config.toml"
readonly SERVER_LOG="$RUN_DIR/compositor.log"
SERVER_PID=
APP_PIDS=()

for app in foot firefox zenity xwayland-satellite jq grim; do
  command -v "$app" > /dev/null || { echo "missing application: $app" >&2; exit 1; }
done
[[ -x $UMBRIEL_BINARY ]] || { echo "missing compositor: $UMBRIEL_BINARY" >&2; exit 1; }
[[ $DWELL_TICKS =~ ^[1-9][0-9]*$ ]] || { echo "invalid UMBRIEL_APP_DWELL_TICKS: $DWELL_TICKS" >&2; exit 1; }
case $APP_BACKEND in
  headless | wayland) ;;
  *) echo "invalid UMBRIEL_APP_BACKEND: $APP_BACKEND" >&2; exit 1 ;;
esac

stop_group() {
  local pid=$1
  if [[ $pid =~ ^[0-9]+$ ]] && ((pid > 1)) && kill -0 -- "-$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

cleanup() {
  local pid
  for pid in "${APP_PIDS[@]}"; do stop_group "$pid"; done
  [[ -z $SERVER_PID ]] || stop_group "$SERVER_PID"
}
trap cleanup EXIT

cat > "$CONFIG" <<'EOF'
[general]
xwayland = true
show_cheatsheet = false
autostart = []

[animation]
enabled = false
EOF

if [[ $APP_BACKEND == wayland ]]; then
  if [[ $PARENT_DISPLAY == /* ]]; then
    parent_socket=$PARENT_DISPLAY
  else
    parent_socket=$PARENT_RUNTIME/$PARENT_DISPLAY
  fi
  [[ -S $parent_socket ]] || { echo "parent Wayland socket unavailable: $parent_socket" >&2; exit 1; }
  setsid env -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
    XDG_RUNTIME_DIR="$RUN_DIR" WAYLAND_DISPLAY="$parent_socket" WLR_BACKENDS=wayland \
    "$UMBRIEL_BINARY" -c "$CONFIG" > "$SERVER_LOG" 2>&1 &
else
  setsid env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
    XDG_RUNTIME_DIR="$RUN_DIR" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    WLR_HEADLESS_OUTPUTS=1 "$UMBRIEL_BINARY" -c "$CONFIG" > "$SERVER_LOG" 2>&1 &
fi
SERVER_PID=$!

for _ in $(seq 200); do
  [[ -S $SOCKET ]] && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "compositor exited: $SERVER_LOG" >&2; exit 1; }
  sleep 0.05
done
[[ -S $SOCKET ]] || { echo "compositor socket did not appear: $SERVER_LOG" >&2; exit 1; }

export XDG_RUNTIME_DIR="$RUN_DIR" WAYLAND_DISPLAY=wayland-0 UMBRIEL_SOCKET="$SOCKET"
unset DBUS_SESSION_BUS_ADDRESS DISPLAY
OUTPUT_NAME=
for _ in $(seq 100); do
  OUTPUT_NAME=$("$UMBRIEL_BINARY" outputs --json 2>/dev/null | jq -r '.[0].name // empty' 2>/dev/null || true)
  [[ -n $OUTPUT_NAME ]] && break
  sleep 0.1
done
[[ -n $OUTPUT_NAME && $OUTPUT_NAME != null ]] || { echo "nested output did not appear" >&2; exit 1; }

windows() { "$UMBRIEL_BINARY" windows --json; }
wait_window() {
  local query=$1 label=$2 state=
  shift 2
  for _ in $(seq 200); do
    state=$(windows)
    jq -e "$@" "$query" <<< "$state" > /dev/null && return 0
    sleep 0.1
  done
  echo "$label did not reach expected state: $state" >&2
  return 1
}
window_id() { windows | jq -r --arg title "$1" '.[] | select(.title == $title) | .id'; }
focus() { "$UMBRIEL_BINARY" msg "window-focus:$1" > /dev/null; }
action() { "$UMBRIEL_BINARY" msg "$1" > /dev/null; }

echo "runtime=$RUN_DIR"
echo "backend=$APP_BACKEND output=$OUTPUT_NAME"
NESTED_DISPLAY=
for _ in $(seq 100); do
  NESTED_DISPLAY=$(sed -n 's/.*using DISPLAY=\(:[0-9][0-9]*\).*/\1/p' "$SERVER_LOG" | tail -1)
  [[ -n $NESTED_DISPLAY ]] && break
  sleep 0.05
done
[[ -n $NESTED_DISPLAY ]] || { echo "Xwayland display did not start: $SERVER_LOG" >&2; exit 1; }
echo "xwayland_display=$NESTED_DISPLAY"

setsid foot --title=sink-real-terminal sh -c 'i=0; while [ "$i" -lt 30 ]; do printf "Sink terminal tick %s\n" "$i"; i=$((i + 1)); sleep 1; done; sleep 90' \
  > "$RUN_DIR/foot.log" 2>&1 &
APP_PIDS+=("$!")
wait_window 'any(.[]; .title == "sink-real-terminal" and .xwayland == false)' terminal
terminal_id=$(window_id sink-real-terminal)
focus "$terminal_id"
action window-sink
wait_window 'any(.[]; .title == "sink-real-terminal" and .sunk and .sink_depth == 0)' 'terminal Sink'
sleep 1
grim -o "$OUTPUT_NAME" "$RUN_DIR/terminal-sunk.png"
action window-pull
wait_window 'any(.[]; .title == "sink-real-terminal" and (.sunk == false) and .focused)' 'terminal Pull'
echo 'terminal: Sink/Pull passed'

mkdir -p "$RUN_DIR/firefox-profile"
setsid env -u GDK_BACKEND MOZ_ENABLE_WAYLAND=1 firefox --no-remote --profile "$RUN_DIR/firefox-profile" about:blank \
  > "$RUN_DIR/firefox.log" 2>&1 &
APP_PIDS+=("$!")
wait_window 'any(.[]; ((.app_id // "") | test("firefox"; "i")) and .xwayland == false)' browser
browser_id=$(windows | jq -r '.[] | select(((.app_id // "") | test("firefox"; "i")) and .xwayland == false) | .id' | head -1)
focus "$browser_id"
action window-sink
wait_window 'any(.[]; .id == $id and .sunk)' 'browser Sink' --arg id "$browser_id"
sleep 1
grim -o "$OUTPUT_NAME" "$RUN_DIR/browser-sunk.png"
action window-pull
wait_window 'any(.[]; .id == $id and (.sunk == false) and .focused)' 'browser Pull' --arg id "$browser_id"
action window-toggle-fullscreen
action window-sink
wait_window 'any(.[]; .id == $id and .sunk)' 'fullscreen browser Sink' --arg id "$browser_id"
action window-pull
wait_window 'any(.[]; .id == $id and (.sunk == false))' 'fullscreen browser Pull' --arg id "$browser_id"
action window-toggle-fullscreen
echo 'browser: Sink/Pull and fullscreen round trip passed'

setsid env -u WAYLAND_DISPLAY GDK_BACKEND=x11 DISPLAY="$NESTED_DISPLAY" \
  zenity --info --title=sink-real-x11-dialog --text='Sink Xwayland dialog' --width=320 --height=180 \
  > "$RUN_DIR/zenity.log" 2>&1 &
APP_PIDS+=("$!")
wait_window 'any(.[]; .title == "sink-real-x11-dialog" and .xwayland)' 'Xwayland dialog'
dialog_id=$(window_id sink-real-x11-dialog)
focus "$dialog_id"
if ! windows | jq -e --arg id "$dialog_id" 'any(.[]; .id == $id and .floating)' > /dev/null; then
  action window-toggle-floating
fi
wait_window 'any(.[]; .id == $id and .floating)' 'floating Xwayland dialog' --arg id "$dialog_id"
action window-sink
wait_window 'any(.[]; .id == $id and .sunk and .floating)' 'floating Xwayland Sink' --arg id "$dialog_id"
sleep 1
grim -o "$OUTPUT_NAME" "$RUN_DIR/xwayland-sunk.png"
action window-pull
wait_window 'any(.[]; .id == $id and (.sunk == false) and .floating and .focused)' 'floating Xwayland Pull' --arg id "$dialog_id"
echo 'Xwayland Floating dialog: Sink/Pull passed'

focus "$terminal_id"
action window-sink
focus "$browser_id"
action window-sink
focus "$dialog_id"
action window-sink
wait_window 'length == 3 and all(.[]; .sunk) and any(.[]; .app_id == "zenity" and .sink_depth == 0 and .xwayland and .floating) and any(.[]; .app_id == "firefox" and .sink_depth == 1) and any(.[]; .app_id == "foot" and .sink_depth == 2)' 'mixed application Top 2/Horizon'
sleep 1
grim -o "$OUTPUT_NAME" "$RUN_DIR/mixed-stack.png"
action window-pull
action window-pull
action window-pull
wait_window 'length == 3 and all(.[]; .sunk == false)' 'mixed application unwind'
echo 'mixed application LIFO and Horizon passed'

for _ in $(seq "$DWELL_TICKS"); do
  sleep 5
  wait_window 'length == 3 and all(.[]; .sunk == false) and any(.[]; .app_id == "foot") and any(.[]; .app_id == "firefox") and any(.[]; .app_id == "zenity" and .xwayland and .floating)' 'mixed application dwell'
done
windows > "$RUN_DIR/final-windows.json"
"$UMBRIEL_BINARY" render-stats --json > "$RUN_DIR/final-render-stats.json"
echo "$((DWELL_TICKS * 5))-second mixed-client dwell passed"
if [[ ${UMBRIEL_RENDER_TIMING:-0} == 1 ]]; then
  jq -c '.[] | {name, cpu_samples, gpu_samples, gpu_average_ms}' "$RUN_DIR/final-render-stats.json"
fi

for pid in "${APP_PIDS[@]}"; do stop_group "$pid"; done
APP_PIDS=()
kill -TERM "$SERVER_PID"
server_status=0
wait "$SERVER_PID" || server_status=$?
SERVER_PID=
if ((server_status != 0)); then
  echo "compositor exited with status $server_status: $SERVER_LOG" >&2
  exit 1
fi
echo 'compositor shutdown clean'
