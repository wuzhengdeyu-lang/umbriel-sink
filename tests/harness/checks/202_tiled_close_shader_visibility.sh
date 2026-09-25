#!/usr/bin/env bash
# A tiled close keeps its natural windows_out shader timeline while survivor geometry follows its independent
# windows_move clock. Exercise ordinary closure, interrupted consume and expel, plus disabled movement, where the
# survivor snaps immediately without shortening the close lifecycle.
set -euo pipefail

readonly SHOTS="$UMBRIEL_RUNTIME_DIR/tiled-close-shader-visibility"
readonly OUT_MS=1500
readonly MOVE_MS=1250
readonly REBASE_TOLERANCE=24
readonly SAMPLE_LAST=19
mkdir -p "$SHOTS"

cat > "$UMBRIEL_RUNTIME_DIR/phased-close.glsl" <<'GLSL'
vec4 animation(vec2 uv) {
    float progress = umbriel_clamped_progress;
    if (progress < 0.25) {
        return vec4(0.0, 0.0, 0.5, 0.5);
    }
    if (progress < 0.65) {
        return vec4(0.0, 0.5, 0.0, 0.5);
    }
    if (progress < 0.95) {
        return vec4(0.0, 0.5, 0.5, 0.5);
    }
    return vec4(0.0);
}
GLSL
cat > "$UMBRIEL_RUNTIME_DIR/move-marker.glsl" <<'GLSL'
vec4 animation(vec2 uv) {
    vec4 source = umbriel_sample(uv);
    return vec4(source.r, source.g, max(source.b, source.a * 0.4), source.a);
}
GLSL

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
mode = "master"
gap = 0

[layout.master]
default_width_fraction = 0.5

[layout.scrolling]
default_extent_fraction = 0.5
center_focused = "never"
center_underfull_strip = false

[animation.windows_in]
enabled = false

[animation.windows_out]
enabled = true
duration_ms = $OUT_MS
curve = "linear"
shader = "phased-close.glsl"

[animation.windows_move]
enabled = true
duration_ms = $MOVE_MS
curve = "snappy"
shader = "move-marker.glsl"

[animation.workspaces]
enabled = false
EOF
"$UMBRIEL" msg config-reload > /dev/null

spawn() {
  local title=$1 color=$2 windows
  FILL_COLOR="$color" "$UMBRIEL_UNMAP_CLIENT" "$title" 1280 720 > "$UMBRIEL_RUNTIME_DIR/$title.log" 2>&1 &
  for _ in $(seq 100); do
    windows=$("$UMBRIEL" windows --json 2> /dev/null || true)
    window=$(jq -c --arg title "$title" '.[] | select(.title == $title)' <<< "${windows:-[]}")
    [[ -n $window ]] && return 0
    sleep 0.025
  done
  echo "timed out waiting for $title"
  return 1
}

wait_unmapped() {
  local title=$1 windows
  for _ in $(seq 100); do
    if grep -q '^unmapped$' "$UMBRIEL_RUNTIME_DIR/$title.log"; then
      windows=$("$UMBRIEL" windows --json 2> /dev/null || true)
      if [[ -n $windows ]] && ! jq -e --arg title "$title" 'any(.[]; .title == $title)' <<< "$windows" > /dev/null; then
        return 0
      fi
    fi
    sleep 0.025
  done
  echo "timed out waiting for $title to unmap"
  return 1
}

color_pixels() {
  local image=$1 expression=$2
  magick "$image" -alpha off -fx "$expression ? 1 : 0" -format '%[fx:round(mean*w*h)]\n' info:
}

reload_config() {
  local attempt
  for attempt in 1 2 3; do
    if "$UMBRIEL" msg config-reload > /dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "config reload did not answer after $attempt attempts"
  return 1
}

msg_retry() {
  local action=$1 attempt
  for attempt in 1 2 3; do
    if "$UMBRIEL" msg "$action" > /dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "action did not answer after $attempt attempts: $action"
  return 1
}

red_bounds() {
  magick "$1" -alpha off -fx '(r > 0.08) ? 1 : 0' -bordercolor black -border 1 -trim \
    -format '%X %Y %w %h\n' info: 2> /dev/null
}

bounds_match() {
  local tolerance=$1
  local ax=$2 ay=$3 aw=$4 ah=$5
  local bx=$6 by=$7 bw=$8 bh=$9
  ((ax >= bx - tolerance && ax <= bx + tolerance \
    && ay >= by - tolerance && ay <= by + tolerance \
    && aw >= bw - tolerance && aw <= bw + tolerance \
    && ah >= bh - tolerance && ah <= bh + tolerance))
}

verify_close() {
  local phase=$1 closing_title=$2 movement=$3
  local expected_x=$4 expected_y=$5 expected_width=$6 expected_height=$7
  local closing id image i close_started_ms sample_ms
  local before="$SHOTS/$phase-before.png"
  closing=$("$UMBRIEL" windows --json | jq -c --arg title "$closing_title" '.[] | select(.title == $title)')
  if [[ -z $closing ]]; then
    echo "$phase: closing tile disappeared before the close request"
    return 1
  fi

  grim "$before"
  local before_box
  before_box=$(red_bounds "$before")

  id=$(jq -r .id <<< "$closing")
  close_started_ms=$(date +%s%3N)
  "$UMBRIEL" msg "window-close:$id" > /dev/null
  wait_unmapped "$closing_title"

  local -a elapsed_ms=()
  for i in $(seq 0 "$SAMPLE_LAST"); do
    sample_ms=$(date +%s%3N)
    elapsed_ms[$i]=$((sample_ms - close_started_ms))
    grim "$SHOTS/$phase-$i.png"
    sleep 0.1
  done

  local -a early=() middle=() late=() move=() red_boxes=()
  for i in $(seq 0 "$SAMPLE_LAST"); do
    image="$SHOTS/$phase-$i.png"
    early[$i]=$(color_pixels "$image" 'b > 0.3 && g < 0.08')
    middle[$i]=$(color_pixels "$image" 'g > 0.08 && b < 0.3')
    late[$i]=$(color_pixels "$image" 'g > 0.08 && b > 0.3')
    move[$i]=$(color_pixels "$image" 'r > 0.08 && g < 0.08 && b > 0.08')
    red_boxes[$i]=$(red_bounds "$image")
  done

  local first_middle=-1 first_late=-1 last_close=-1
  local first_middle_ms=-1 first_late_ms=-1 last_close_ms=-1
  for i in $(seq 0 "$SAMPLE_LAST"); do
    if ((middle[$i] >= 500 && first_middle < 0)); then
      first_middle=$i
      first_middle_ms=${elapsed_ms[$i]}
    fi
    if ((late[$i] >= 500 && first_late < 0)); then
      first_late=$i
      first_late_ms=${elapsed_ms[$i]}
    fi
    if ((early[$i] >= 500 || middle[$i] >= 500 || late[$i] >= 500)); then
      last_close=$i
      last_close_ms=${elapsed_ms[$i]}
    fi
  done

  if ((early[0] < 500)); then
    echo "$phase: windows_out did not begin at its natural early shader phase"
    return 1
  fi
  # grim and image import time varies substantially by GPU. Check the shader's
  # wall-clock phase instead of assuming each capture plus sleep takes 100 ms.
  if ((first_middle_ms < 225)); then
    echo "$phase: windows_out middle phase was skipped or accelerated: frame=$first_middle elapsed_ms=$first_middle_ms"
    return 1
  fi
  if ((first_late_ms < 825 || first_late_ms <= first_middle_ms)); then
    echo "$phase: windows_out late phase was skipped or accelerated: middle=$first_middle/$first_middle_ms ms late=$first_late/$first_late_ms ms"
    return 1
  fi
  if ((last_close_ms < first_late_ms || last_close_ms > 1800)); then
    echo "$phase: windows_out did not finish on its own timeline: late=$first_late/$first_late_ms ms last=$last_close/$last_close_ms ms"
    return 1
  fi

  local final_x final_y final_width final_height
  read -r final_x final_y final_width final_height <<< "${red_boxes[$SAMPLE_LAST]}"
  if ! bounds_match 2 "$final_x" "$final_y" "$final_width" "$final_height" \
      "$expected_x" "$expected_y" "$expected_width" "$expected_height"; then
    echo "$phase: survivor missed final geometry: got=${red_boxes[$SAMPLE_LAST]} expected=$expected_x $expected_y $expected_width $expected_height"
    return 1
  fi
  if [[ $movement == animated ]]; then
    local before_x before_y before_width before_height
    read -r before_x before_y before_width before_height <<< "$before_box"
    local initial_x initial_y initial_width initial_height
    read -r initial_x initial_y initial_width initial_height <<< "${red_boxes[0]}"
    if [[ $phase == ordinary ]]; then
      # No alignment delay: by the second sample the survivor has left the box it held before the close.
      local held_x held_y held_width held_height
      read -r held_x held_y held_width held_height <<< "${red_boxes[1]}"
      if bounds_match "$REBASE_TOLERANCE" "$held_x" "$held_y" "$held_width" "$held_height" \
          "$before_x" "$before_y" "$before_width" "$before_height"; then
        echo "$phase: survivor was still held at its pre-close box: before=$before_box frame1=${red_boxes[1]}"
        return 1
      fi
    fi

    local first_intermediate=-1 first_final=-1 move_first=-1 move_last=-1 concurrent=0
    # A rebased consume/expel can already have moved substantially by the first
    # screenshot. Count that as the first intermediate instead of requiring a
    # later frame to escape a broad tolerance around both frame zero and final.
    if ! bounds_match 6 "$initial_x" "$initial_y" "$initial_width" "$initial_height" \
        "$expected_x" "$expected_y" "$expected_width" "$expected_height" \
        && ! bounds_match "$REBASE_TOLERANCE" "$initial_x" "$initial_y" "$initial_width" "$initial_height" \
          "$before_x" "$before_y" "$before_width" "$before_height"; then
      first_intermediate=0
    fi
    for i in $(seq 0 "$SAMPLE_LAST"); do
      local x y width height
      read -r x y width height <<< "${red_boxes[$i]}"
      if bounds_match 6 "$x" "$y" "$width" "$height" \
          "$expected_x" "$expected_y" "$expected_width" "$expected_height"; then
        if ((first_final < 0)); then
          first_final=$i
        fi
      elif ! bounds_match "$REBASE_TOLERANCE" "$x" "$y" "$width" "$height" \
          "$initial_x" "$initial_y" "$initial_width" "$initial_height"; then
        if ((first_intermediate < 0)); then
          first_intermediate=$i
        fi
      fi
      if ((move[$i] >= 500)); then
        ((move_first < 0)) && move_first=$i
        move_last=$i
        if ((early[$i] >= 500 || middle[$i] >= 500 || late[$i] >= 500)); then
          concurrent=1
        fi
      fi
    done
    if ((first_intermediate < 0 || first_intermediate > 2)); then
      echo "$phase: survivor did not start windows_move immediately: frame=$first_intermediate"
      return 1
    fi
    if ((concurrent == 0)); then
      echo "$phase: windows_move did not overlap the active windows_out shader"
      return 1
    fi
    # An interrupted consume or expel already has a windows_move shader at frame zero. Geometry above still proves
    # when the rebased motion begins; this marker proves that its shader remains active through the close.
    if ((move_first < 0 || move_first > 2 || move_last < move_first)); then
      echo "$phase: windows_move shader did not run on its own timeline: frames=$move_first..$move_last"
      return 1
    fi
    if ((first_final < first_intermediate || first_final > last_close + 3)); then
      echo "$phase: survivor geometry did not settle during its windows_move clock: intermediate=$first_intermediate final=$first_final close=$last_close"
      return 1
    fi
  else
    for i in $(seq 0 "$SAMPLE_LAST"); do
      local x y width height
      read -r x y width height <<< "${red_boxes[$i]}"
      if ! bounds_match 2 "$x" "$y" "$width" "$height" \
          "$expected_x" "$expected_y" "$expected_width" "$expected_height"; then
        echo "$phase: disabled windows_move did not snap directly to final geometry at frame $i: ${red_boxes[$i]}"
        return 1
      fi
    done
  fi

  printf '%s: middle=%d/%dms late=%d/%dms close-end=%d/%dms before=%s final=%s\n' \
    "$phase" "$first_middle" "$first_middle_ms" "$first_late" "$first_late_ms" \
    "$last_close" "$last_close_ms" "$before_box" "${red_boxes[$SAMPLE_LAST]}"
}

readonly SURVIVOR_COLOR=0x80800000
readonly CLOSER_COLOR=0x80000080

spawn shader-visible-master-survivor "$SURVIVOR_COLOR"
sleep 1.4
spawn shader-visible-master-close "$CLOSER_COLOR"
sleep 1.4
verify_close ordinary shader-visible-master-close animated 0 0 1280 720

"$UMBRIEL" msg workspace-switch:2 > /dev/null
msg_retry workspace-set-layout:scrolling
sleep 0.2
spawn shader-visible-consume-survivor "$SURVIVOR_COLOR"
sleep 1.4
spawn shader-visible-consume-close "$CLOSER_COLOR"
sleep 1.4
"$UMBRIEL" msg window-consume-left > /dev/null
sleep 0.28
verify_close consume shader-visible-consume-close animated 0 0 640 720

"$UMBRIEL" msg workspace-switch:3 > /dev/null
msg_retry workspace-set-layout:scrolling
sleep 0.2
spawn shader-visible-expel-survivor "$SURVIVOR_COLOR"
sleep 1.4
spawn shader-visible-expel-close "$CLOSER_COLOR"
sleep 1.4
"$UMBRIEL" msg window-consume-left > /dev/null
sleep 1.4
"$UMBRIEL" msg window-consume-or-expel-right > /dev/null
sleep 0.08
verify_close expel shader-visible-expel-close animated 0 0 640 720

"$UMBRIEL" msg workspace-switch:4 > /dev/null
msg_retry workspace-set-layout:master
sed -i '/\[animation.windows_move\]/,/^$/s/^enabled = true$/enabled = false/' "$UMBRIEL_CONFIG"
reload_config
sleep 0.2
spawn shader-visible-disabled-survivor "$SURVIVOR_COLOR"
sleep 0.2
spawn shader-visible-disabled-close "$CLOSER_COLOR"
sleep 0.2
verify_close disabled shader-visible-disabled-close disabled 0 0 1280 720

echo "tiled closes preserved natural windows_out phases while animated reflow overlapped and disabled movement snapped"
