# Appearance

Configure Umbriel's colors, window decorations, blur, and shadows.

## Colors

```toml
[colors]
background = "#141419FF"
text_primary = "#E8E8EAFF"
text_muted = "#8A8A92FF"
accent_primary = "#7AA3FFFF"
accent_secondary = "#F5C96BFF"
warning = "#F5C96BFF"
error = "#FF6B6BFF"
insert_hint = "#7FC8FF80"
backdrop = "#000000FF"
shadow = "#0000007F"
```

Colors use `#RRGGBB` or `#RRGGBBAA`.

| Key | Description |
| --- | --- |
| `background` | Background for Umbriel panels and banners. |
| `text_primary` | Primary text. |
| `text_muted` | Secondary help and status text. |
| `accent_primary` | Titles, key chords, and primary emphasis. |
| `accent_secondary` | Secondary emphasis and group headings. |
| `warning` | Warning text and borders. |
| `error` | Error text and confirmation borders. |
| `insert_hint` | Drop-target preview during dragging. |
| `backdrop` | Fullscreen and lock-screen background. |
| `shadow` | Window shadow color. |

### Border colors

```toml
[colors.border]
focused = "#7AA3FFFF"
unfocused = "#292933FF"
scratchpad_focused = "#E5C07BFF"
scratchpad_unfocused = "#5C4A2AFF"
outer = "#1A1A1FFF"
```

The first four values select focused and unfocused colors for regular and
scratchpad windows. `outer` colors the optional outer border.

### Overview colors

```toml
[colors.overview]
background_tint = "#10101430"
workspace_background = "#00000044"
badge = "#7AA3FFFF"
```

| Key | Description |
| --- | --- |
| `background_tint` | Tint over the desktop behind the overview. |
| `workspace_background` | Background behind each workspace preview. |
| `badge` | Shortcut badge color. |

See [Workspaces Overview](workspaces-overview.md#settings-and-behavior) for
overview behavior.

## Window appearance

```toml
[appearance]
prefer_no_csd = true
border_width = 2
outer_border_width = 0
corner_radius = 10
drag_opacity = 0.75
```

| Key | Default | Description |
| --- | --- | --- |
| `prefer_no_csd` | `true` | Prefer Umbriel's border-only server decoration. |
| `border_width` | `2` | Inner border width in logical pixels. |
| `outer_border_width` | `0` | Outer ring width in logical pixels. |
| `corner_radius` | `10` | Radius of the complete decorated window. |
| `drag_opacity` | `0.75` | Opacity while dragging a window. |

Set `prefer_no_csd = false` to let newly connected applications draw their own
decorations. Restart applications after changing it because decoration protocol
availability is fixed when an application connects.

Borders render outside window content and are included in layout spacing.
`corner_radius = 0` keeps every contour square.

### Blur

```toml
[appearance.blur]
enabled = true
optimized = true
passes = 3
radius = 5
noise = 0.02
brightness = 0.9
contrast = 0.9
saturation = 1.1
```

`enabled` is the master switch. Individual surfaces still opt in through
[window rules](window-rules.md) or [layer rules](layer-rules.md). Blur appears
only where a surface is transparent.

| Key | Default | Description |
| --- | --- | --- |
| `enabled` | `true` | Enable blur rendering. |
| `optimized` | `true` | Share one cached background blur across surfaces on an output. |
| `passes` | `3` | Blur passes from 0 to 8. |
| `radius` | `5` | Blur radius from 0 to 100. |
| `noise` | `0.02` | Noise overlay from 0.0 to 1.0. |
| `brightness` | `0.9` | Brightness multiplier from 0.0 to 2.0. |
| `contrast` | `0.9` | Contrast multiplier from 0.0 to 2.0. |
| `saturation` | `1.1` | Saturation multiplier from 0.0 to 2.0. |

Optimized blur samples the background beneath the window stack. Set it to
`false` when translucent surfaces should blur the surfaces directly behind
them, at a higher rendering cost.

### Sink projection and self blur

```toml
[appearance.sink]
visible_depth = 2
# Optional: replace the per-depth styles (one table per visible layer).
# levels = [
#   { scale = 0.93, opacity = 0.82, blur_strength = 0.5 },
#   { scale = 0.85, opacity = 0.45, blur_strength = 1.0 },
# ]
self_blur = false
blur_radius = 6
blur_samples = 9
```

Sink self blur samples each visible Sink projection itself; it does not sample
the desktop behind the window. It remains disabled by default while the P4
performance and experience acceptance is still open. When disabled, unsupported,
or rejected by the renderer, Sink keeps its scale, opacity, LIFO, focus, and restore
semantics unchanged.

| Key | Default | Description |
| --- | --- | --- |
| `visible_depth` | `2` | Number of visible sunk windows, from 1 to 4; deeper windows remain in the logical stack but are hidden. |
| `levels` | Built-in styles | Optional array of 1–4 complete tables, with at least `visible_depth` entries. Depth 0 is nearest the desktop/front. Each table requires `scale` (0.1–1.0), `opacity` (0.0–1.0), and `blur_strength` (0.0–1.0). |
| `self_blur` | `false` | Enable the experimental persistent Self Blur. |
| `blur_radius` | `6` | Maximum kernel radius from 1 to 32 logical pixels. |
| `blur_samples` | `9` | Requested samples from 3 to 17; even values degrade to the next lower odd count. |

The normal path uses two separable passes. Reducing `blur_samples` is the first
quality fallback; setting `self_blur = false` removes the static effect without
disabling Sink animations.

The built-in level styles are `(scale, opacity, blur_strength)` =
`(0.93, 0.82, 0.5)`, `(0.85, 0.45, 1.0)`, `(0.77, 0.25, 1.0)`, and
`(0.69, 0.14, 1.0)`. Only the first two are visible by default. `blur_strength`
sets the fraction of `blur_radius` used at that depth when `self_blur` is enabled;
it does not turn blur on by itself. Changing these keys and reloading the config
updates existing Sink projections without changing their stack order.
Showing three or four layers can increase rendering cost, especially with
`self_blur = true`; the current GPU budget measurements cover the default
two-layer horizon only.

### Shadow

```toml
[appearance.shadow]
enabled = true
softness = 10
offset_x = 2
offset_y = 2
```

| Key | Default | Description |
| --- | --- | --- |
| `enabled` | `true` | Draw shadows behind tiled and floating windows. |
| `softness` | `10` | Blur softness from 0 to 200. |
| `offset_x` | `2` | Horizontal offset from -200 to 200. |
| `offset_y` | `2` | Vertical offset from -200 to 200. |

Shadows are hidden for fullscreen windows. During a
[custom window animation](animation.md#custom-glsl-shaders), the shadow follows
the visible shape produced by the shader.
