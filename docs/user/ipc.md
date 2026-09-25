# IPC

Umbriel exposes a local UNIX socket for queries, actions, and event
subscriptions. Most users should use the `umbriel` command rather than connect
to the socket directly.

`UMBRIEL_SOCKET` contains the socket path. Without it, use
`$XDG_RUNTIME_DIR/umbriel-$WAYLAND_DISPLAY.sock`.

Each request and reply is one JSON object per line:

```sh
printf '{"cmd":"workspaces"}\n' | socat -t 5 STDIO "$UMBRIEL_SOCKET"
```

Replies use `{"ok": ...}` or `{"err": "..."}`.

## Queries

| Request | CLI |
| --- | --- |
| `{"cmd":"windows"}` | `umbriel windows --json` |
| `{"cmd":"workspaces"}` | `umbriel workspaces --json` |
| `{"cmd":"submap"}` | `umbriel submap --json` |
| `{"cmd":"layers"}` | `umbriel layers --json` |
| `{"cmd":"msg","arg":"<action>"}` | `umbriel msg <action>` |

Window entries include IDs, application identity, process ID, geometry,
workspace, scratchpad membership, and Sink state. `floating` and
`base_placement` continue to describe the window's underlying placement while
`sunk` is true; `sink_depth` is `0` for the stack top and `null` for a normal
window. XWayland windows report an unknown client PID because they share the
xwayland-satellite connection.

Workspace entries include a stable ID, display name, index, output, layout,
occupancy, `sink_count`, and active and focused states. A workspace containing
only sunk windows remains occupied. Use the `named` boolean instead of
guessing from the display name; an explicitly named workspace may still be
called `"2"`.

Sink depth is logical rather than a visibility guarantee: by default depths zero
and one are projected, while depth two and below stay in the stack behind the
visual horizon. `[appearance.sink].visible_depth` can move that horizon from
one to four layers. During Pull, `sunk` becomes false as soon as layout membership is
restored; the compositor may briefly keep the passive projection as the sole
presentation owner while it waits for the compatible client commit.

Workspace and output transfers preserve Sink membership. A destination keeps
its existing stack at the bottom, then appends each source stack from oldest to
newest; when several workspaces are evacuated together they are processed in
stable workspace order. Consequently each source's top entry remains above its
older entries, including after an output disappears and later returns.

## Event stream

Subscribe with:

```json
{"cmd":"subscribe","events":["workspaces","windows"]}
```

The connection first receives the current state of each family, then a new
snapshot whenever that family changes:

```json
{"event":"workspaces","data":[]}
```

| Family | Changes reported |
| --- | --- |
| `theme` | Colors and corner radius |
| `overview` | Overview open or closed |
| `keyboard_layout` | Active keyboard layout |
| `windows` | Window identity, geometry, focus, state, workspace, or scratchpad |
| `workspaces` | Inventory, layout, activity, occupancy, output, or focus |
| `submap` | Active keybind submap |

Payloads are full snapshots rather than deltas. Replace local state with the
newest event instead of trying to merge increments. Identical consecutive
payloads are omitted.

An unknown family returns an error and closes the subscription.

### Theme payload

The `theme` event mirrors `[colors]`, `[colors.border]`,
`[colors.overview]`, and `appearance.corner_radius`:

```json
{"event":"theme","data":{
  "background":"#141419FF",
  "text_primary":"#E8E8EAFF",
  "text_muted":"#8A8A92FF",
  "accent_primary":"#7AA3FFFF",
  "accent_secondary":"#F5C96BFF",
  "warning":"#F5C96BFF",
  "error":"#FF6B6BFF",
  "insert_hint":"#7FC8FF80",
  "backdrop":"#000000FF",
  "shadow":"#0000007F",
  "border":{
    "focused":"#7AA3FFFF",
    "unfocused":"#292933FF",
    "scratchpad_focused":"#E5C07BFF",
    "scratchpad_unfocused":"#5C4A2AFF",
    "outer":"#1A1A1FFF"
  },
  "overview":{
    "background_tint":"#10101430",
    "workspace_background":"#00000044",
    "badge":"#7AA3FFFF"
  },
  "corner_radius":10
}}
```

See [Appearance](appearance.md#colors) for the meaning of each value.

### From the command line

The CLI exposes the same event stream:

```sh
umbriel subscribe workspaces
umbriel subscribe workspaces,windows
umbriel subscribe submap
```

It writes one JSON line per event until Umbriel exits or the reader closes:

```sh
umbriel subscribe workspaces |
  jq -r '.data[] | select(.focused) | "\(.output) \(.name) \(.layout)"'
```

## Inspection commands

`umbriel outputs`, `umbriel color`, `umbriel tearing`, `umbriel layers`,
`umbriel keyboard-layouts`, and `umbriel render-stats` print human-readable
state. Each accepts `--json`. Render timing is disabled by default; start the
compositor with `UMBRIEL_RENDER_TIMING=1` to collect frame duration samples for
`render-stats`. The command reports both CPU render-and-commit duration and GPU
timer results. When the driver marks GPU queries disjoint, `gpu_samples`
remains zero and the CPU values are the available fallback rather than a GPU
measurement.
`umbriel validate` checks a configuration without a running compositor.
