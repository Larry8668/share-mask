# Configuration

Everything in `~/.config/sharemask/presets.json`. Most of it can also be set from the app window and the menu.

## presets.json

`~/.config/sharemask/presets.json` (seeded from `Resources/presets.example.json`):

```json
{
  "version": 1,
  "defaults": { "mode": "pixellate", "scale": 24 },
  "apps": {
    "net.whatsapp.WhatsApp": {
      "regions": [
        { "name": "chat list", "rect": [0.0, 0.0, 0.30, 1.0] },
        { "name": "header",    "rect": [0.0, 0.0, 1.0, 0.08], "mode": "solid", "color": "#000000" }
      ]
    },
    "com.tinyspeck.slackmacgap": {
      "whenFrontmostOnly": false,
      "regions": [ { "name": "sidebar", "rect": [0.0, 0.0, 0.22, 1.0], "mode": "blur", "radius": 30 } ]
    }
  },
  "hotkeys": { "panic": "cmd+shift+ctrl+B", "toggle": "cmd+shift+ctrl+M", "pick": "cmd+shift+ctrl+P" },
  "pointerGuard": true,
  "hud": false,
  "idleMode": false
}
```

- `rules`: `[{ "name": "wa-web", "titleContains": "WhatsApp", "bundleID": "optional", "regions": [...] }]`
  matches any window by title substring (web apps in a browser) and/or bundle ID.
- `allowlist`: bundle IDs that stay visible in allowlist mode, e.g. `["com.apple.Keynote"]`.
- `maskNotifications` (default true): black out macOS notification banners.
- `rect` is `[x, y, w, h]` normalised to the window frame, origin top-left; `"shape": "ellipse"`
  makes it an ellipse inside that box (kept only while nothing overlaps it, otherwise it falls back
  to rectangles — over-redaction, never under).
- Modes: `pixellate {scale}`, `blur {radius}`, `solid {color}`. Unknown bundle IDs are ignored.
- A malformed file keeps the last good config and shows a warning in the menu.
- `capture`: `ask` (default) · `auto` · `always` · `manual` — see "Capture only during meetings".
- `calendarLookahead`: prompt before calendar meetings (needs Calendar access). Off by default.

Occlusion is respected: if another window overlaps a masked region, the overlapping part is left
sharp (a Terminal dragged over WhatsApp stays readable). Windows that are themselves hidden from
capture (`sharingType = .none`, e.g. password managers) do **not** punch holes, because what is under
them is what the feed shows. On any overflow (> 64 rects/frame) sharemask over-redacts, never under.

---
[← Back to the README](../README.md)
