#!/usr/bin/env bash
# Render the per-user launcher path into the desktop-entry template, then
# install only the separately named Umbriel Sink login entry.
set -euo pipefail

render_only=false
if [[ ${1:-} == --render ]]; then
  render_only=true
  shift
fi
launcher=${1:-"$HOME/.local/bin/start-umbriel-sink"}
if [[ ! $launcher =~ ^/[A-Za-z0-9_./-]+$ ]]; then
  echo "launcher must be an absolute path using letters, digits, _, -, . and /" >&2
  exit 2
fi
if [[ ! -x $launcher ]]; then
  echo "launcher is not executable: $launcher" >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
entry=$(mktemp --suffix=.desktop)
trap 'rm -f -- "$entry"' EXIT
sed "s|@UMBRIEL_SINK_LAUNCHER@|$launcher|" "$script_dir/umbriel-sink.desktop.in" > "$entry"
if [[ $render_only == true ]]; then
  cat "$entry"
  exit 0
fi
sudo install -m 0644 "$entry" /usr/share/wayland-sessions/umbriel-sink.desktop
