# sharemask

**Share your screen without sharing your chats.** sharemask is a macOS menu-bar app that lets you
screen-share in Zoom, Meet, Teams, Slack or FaceTime while the parts you choose (the WhatsApp chat
list, a Slack sidebar, every notification banner, or everything except the one app you're
presenting) are pixellated **only on the shared feed**. Your own screen stays exactly as it is.

- Pixellate, blur or black out regions of any app — drawn with an overlay editor (rectangles,
  squares, circles) directly over the window.
- Masks follow windows as they move and resize, and respect whatever overlaps them.
- **Allowlist mode**: mask the entire screen except the apps you name.
- **Hold a key to reveal** an app for a moment, or untick a single mask, without stopping the share.
- **Panic key** blacks out the whole feed on the next frame.
- Captures only while you're in a meeting (microphone in use or a share in progress), so macOS's
  recording indicator isn't on all day.
- Fails closed: if capture stalls, viewers see black, not a stale frame, and one key removes the
  shared display to end the share outright.
- A "what others see" preview window, and persistent logs for when something looks off.

macOS 14+ (built and measured on macOS 27.0.1), Apple Silicon, Swift 5.9+/SwiftPM. Not sandboxed,
not notarised, uses private CoreGraphics API. Single user, single machine.

## Install

Requires macOS 14 or later on Apple Silicon.

**Homebrew**

```sh
brew tap Larry8668/sharemask
brew trust Larry8668/sharemask     # Homebrew 7+: third-party taps must be trusted
brew install --cask sharemask
```

**Manual**: download `sharemask-<version>.zip` from the
[releases page](https://github.com/Larry8668/share-mask/releases), unzip, move `sharemask.app` to
Applications, then right-click → Open the first time (the app is signed but not notarised).

**From source**: `make identity && make run` (see Build below).

First launch: grant **Screen Recording** when asked (System Settings → Privacy & Security → Screen &
System Audio Recording), then relaunch if macOS asks you to. The app lives in the menu bar as a
crossed-eye icon; in your call app, share the display named **sharemask**.

## How it works

macOS offers no "visible to capture but invisible locally" window. So sharemask is a **proxy display**:

```
real display ──SCStream 60fps──▶ Redactor (Core Image, GPU) ──▶ CAMetalLayer window on a
                                  rects from live window geometry   virtual display "sharemask"
                                                                    ◀── you share THIS in Zoom/Meet
```

1. A virtual display named **sharemask** is created with the private `CGVirtualDisplay` API at the
   real main display's pixel size (e.g. 2940×1912, 1×).
2. ScreenCaptureKit captures the real display (cursor, menu bar, Spaces, z-order for free).
3. Every frame, the window list (`CGWindowListCopyWindowInfo`) is matched against your presets;
   regions of matching windows are pixellated/blurred/blacked, minus anything that overlaps them.
4. The result is drawn into a fullscreen window on the virtual display. In your call, pick the
   display called **sharemask** when choosing what to share.

Pixellation at a coarse block size (default 24 px) is the default mode on purpose: a Gaussian blur
at small radius is partially invertible; coarse pixellation is not.

## Build

```sh
make identity   # once: creates a stable self-signed "sharemask-dev" signing identity (no GUI)
make            # swift build + bundle + sign → build/sharemask.app
make run        # build and launch
make test       # RegionResolver / preset unit tests (pure, no window server)
make probe      # CLI: list displays, create + remove a virtual display, print timings
```

Why the identity matters: ad-hoc signatures change on every build and macOS silently revokes the
Screen Recording grant. `make identity` puts the certificate in its own keychain
(`~/Library/Keychains/sharemask-dev.keychain-db`) with codesign pre-authorised so builds never
prompt. `make` falls back to ad-hoc with a warning if the identity is missing.

Always launch through LaunchServices (`make run` / `open build/sharemask.app` / double-click). If you
run the binary directly from a terminal, macOS attributes the Screen Recording request to the
*terminal* (the "responsible process"), prompts for the terminal instead, and sharemask's own grant
is never consulted. Logs: `/usr/bin/log show --last 5m --info --predicate 'subsystem == "dev.sharemask.app"'`
(note `log` is also a zsh builtin).

First launch: grant **Screen Recording** to sharemask (System Settings → Privacy & Security →
Screen & System Audio Recording). If macOS asks for a relaunch, use *Relaunch sharemask* in the menu.

## Using it

Menu bar icon: grey = stopped, green = proxy active, red = PANIC, yellow = error (hover for details).

| Menu item | Default hotkey | What it does |
|---|---|---|
| Panic | ⌘⇧⌃B | Pixellates the **whole** feed on the next frame (≤ 17 ms). Press again to restore. |
| Regions: enabled/disabled | ⌘⇧⌃M | Turns per-app regions on/off (panic unaffected). |
| Hold to reveal | ⌘⇧⌃R (hold) | Shows the frontmost app unmasked while the key is held. |
| Allowlist mode | ⌘⇧⌃A | Masks everything except the `allowlist` apps. |
| End share now | ⌘⇧⌃X | Removes the “sharemask” display, which ends the share in your call app. |
| Masks ▸ | | Tick/untick individual apps, regions, rules and notification masking for this session. |
| Show “what others see” preview | | Small floating window with the live proxy output (never captured). |
| Pick region for frontmost app… | ⌘⇧⌃P | Opens the **region editor** over the frontmost window. |
| Pick regions for app ▸ | | Same editor for any running app. |
| Configured apps ▸ | | Edit or remove the regions of each app in presets.json. |
| Start/Stop capturing | | Forces capture on/off (the virtual display stays until quit). |
| Show log file | | Reveals `~/Library/Logs/sharemask/sharemask.log`. |
| Shortcuts ▸ | | Remap any shortcut: pick it, press the new keys. Stored in presets.json. |
| Open presets.json / Reload | | Config lives at `~/.config/sharemask/presets.json`, live-reloaded. |
| Pointer guard | | Warps the cursor back if it wanders onto the virtual display (default on). |
| Show status HUD | | Small "● sharing-safe / PANIC" panel on your real display; never captured. |

### Region editor
A transparent overlay sits exactly over the app's window (and follows it if it moves). Drag on
empty space to draw a **rectangle, square or circle**; drag a shape to move it; drag its handles to
resize; arrow keys nudge; Delete removes; Esc cancels; Enter saves. Each shape shows the actual
pixellation preview, and the toolbar sets its mode (pixellate / blur / black) or drops in a
template (left/right sidebar, top bar, whole window, centre circle). Regions are stored
normalised to the window, so they keep fitting when the window is resized.

### Capture only during meetings
macOS shows its purple "recording" indicator whenever sharemask captures, and that cannot be
hidden. By default (`"capture": "ask"`) sharemask therefore stays in **standby** and only captures
when a meeting is detected:

- **microphone in use** (CoreAudio "device is running somewhere", no permission needed; the app
  using it is named on macOS 14.2+), or
- **another app is capturing the screen** (private `CGSIsScreenWatcherPresent`, checked while our
  own capture is off), or
- optionally (`"calendarLookahead": true`, asks for Calendar access) an event with attendees or a
  video-call link starting within 5 minutes.

A floating prompt asks "Meeting detected — start sharemask proxy?"; `"capture": "auto"` starts
without asking. When the mic goes quiet for 15 s sharemask pauses capture for half a second to
check that nobody else is still capturing, then stops and says so. `"always"` captures whenever the
proxy is running; `"manual"` only via the menu. The virtual display itself always exists while
the app runs, so the "sharemask" display is always there to pick in Zoom/Meet.

Launch flags: `--demo` adds a hard-coded pixellate rect at (100,100,400,300) px for testing;
`--probe` runs the display diagnostics CLI.

## Presets

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

## Layout

```
Sources/CGVirtualDisplayShim   ObjC: private CGVirtualDisplay* declarations + SM* façade (only private API here)
Sources/CGSPrivate             ObjC: dlsym'd CGSIsScreenWatcherPresent (idle mode)
Sources/sharemask
  App.swift                    @main, launch order, NSApplicationDelegate
  Probe.swift                  `--probe` CLI
  Pipeline/                    Pipeline (lifecycle), Capture (SCStream), Redactor (Core Image),
                               Presenter (CAMetalLayer on the virtual display), FrameClock, SourceDisplay
  VirtualDisplay/              Swift owner of the virtual display + the measured invariants
  Regions/                     Preset (schema), RegionResolver (pure geometry), WindowTracker, ConfigStore
  Hotkeys/  Picker/  UI/       Carbon hotkeys, region picker, menu bar, HUD, pointer guard
Tests/sharemaskTests           RegionResolver + preset tests (`swift test`)
```

Capture and output sit behind `FrameSource` / `FrameProcessor` / `FrameSink` protocols so another
OS could swap them in; only macOS is implemented.

## Virtual display invariants (measured, non-negotiable)

Encoded in `VirtualDisplay.swift`; measured on macOS 27.0.1 with `make probe`:

1. Every private class/selector is verified at launch (`objc_getClass` + `class_getInstanceMethod`).
   A missing one shows an alert naming it and the pipeline refuses to start.
2. The virtual display's mode is **never** changed after creation. A mode change (even from System
   Settings) makes it un-removable until the process exits; the menu warns when that happened.
3. One fixed identity: name `sharemask`, vendor `0x534D`, product `0x0001`, serial = FNV-1a of
   `(name, w, h)`. macOS writes a root-owned ICC profile per identity under
   `/Library/ColorSync/Profiles/Displays` and never deletes it; a stable identity means one file and
   a stable arrangement across launches.
4. Mode reporting (`CGDisplayCopyDisplayMode`) is NULL in the creating process if it enumerated
   displays first, so the display is created before AppKit starts and diagnostics run in a child
   process (`sharemask --probe <id>`). `CGDisplayBounds`/`CGDisplayPixelsWide` work regardless.
5. Removal is asynchronous (measured 20–100 ms for one display); `release()` polls up to 5 s.
6. The window server reclaims the display if the process dies; it is still released on quit.
7. Created at the real display's pixel size with a ~110 DPI physical size, so macOS enters the
   native 1× mode. With a Retina-like DPI it would come up at half size. Note that
   `CGDisplayPixelsWide` returns *points* on Retina displays; the pixel size is read from the mode.

## Logs

Everything goes to `~/Library/Logs/sharemask/sharemask.log` (rotated at 5 MB), to the unified log
(subsystem `dev.sharemask.app`, notice level) and to stderr when run from a terminal. Crashes write
a final `[FATAL]` line; macOS crash reports are in `~/Library/Logs/DiagnosticReports`.

## Performance

`FrameClock` logs every 5 s (unified log, subsystem `dev.sharemask.app`, or stderr when run from a
terminal) and the menu shows: fps, capture→present latency p50/p95, pipeline time, GPU time, drops.
Targets: < 40 ms p95 capture→present, < 4 ms GPU per frame on Apple Silicon.
Measured on an M-series MacBook at 2940×1912 (macOS 27.0.1): capture→present 4 ms p50 / 6–17 ms p95,
pipeline 2.6 ms, GPU 1.3–1.5 ms. The fps figure follows screen activity: ScreenCaptureKit only
delivers frames when content changes, so a static desktop reads ~8–10 fps and rises to 60 under motion.

## Other platforms

The resolver is also a platform-independent Rust crate (`core/`, `cargo test`), and
[`docs/PORTING.md`](docs/PORTING.md) lays out what a Windows (IddCx + Windows.Graphics.Capture)
and Linux (PipeWire + headless output) port needs. Only macOS is implemented.

## Non-goals

No virtual camera, no browser extension, no OCR/ML detection (geometric presets only), no
per-window compositing, no App Store/notarisation.
