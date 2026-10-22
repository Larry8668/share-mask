# sharemask

A personal macOS menu-bar app that lets you share your screen in any video-call app (Zoom, Meet,
Teams, Slack, FaceTime) while chosen regions of chosen apps are pixellated **only on the shared
feed**. Your own display is never touched.

macOS 14+ (built and measured on macOS 27.0.1), Apple Silicon, Swift 5.9+/SwiftPM. Not sandboxed,
not notarised, uses private CoreGraphics API. Single user, single machine.

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

First launch: grant **Screen Recording** to sharemask (System Settings → Privacy & Security →
Screen & System Audio Recording). If macOS asks for a relaunch, use *Relaunch sharemask* in the menu.

## Using it

Menu bar icon: grey = stopped, green = proxy active, red = PANIC, yellow = error (hover for details).

| Menu item | Default hotkey | What it does |
|---|---|---|
| Panic | ⌘⇧⌃B | Pixellates the **whole** feed on the next frame (≤ 17 ms). Press again to restore. |
| Regions: enabled/disabled | ⌘⇧⌃M | Turns per-app regions on/off (panic unaffected). |
| Pick region for frontmost app… | ⌘⇧⌃P | Drag rectangles on a frozen screenshot of the frontmost window; saved to presets. |
| Start/Stop proxy display | | Starts/stops capture (the virtual display stays until quit). |
| Open presets.json / Reload | | Config lives at `~/.config/sharemask/presets.json`, live-reloaded. |
| Pointer guard | | Warps the cursor back if it wanders onto the virtual display (default on). |
| Show status HUD | | Small "● sharing-safe / PANIC" panel on your real display; never captured. |

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

- `rect` is `[x, y, w, h]` normalised to the window frame, origin top-left.
- Modes: `pixellate {scale}`, `blur {radius}`, `solid {color}`. Unknown bundle IDs are ignored.
- A malformed file keeps the last good config and shows a warning in the menu.
- `idleMode` (optional): only capture while some process has a screen-recording session open,
  detected with the private `CGSIsScreenWatcherPresent`. Because sharemask's own stream counts as a
  watcher, the check pauses capture for ~0.5 s every 2 minutes. Off by default.

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

## Performance

`FrameClock` logs every 5 s (unified log, subsystem `dev.sharemask.app`, or stderr when run from a
terminal) and the menu shows: fps, capture→present latency p50/p95, pipeline time, GPU time, drops.
Targets: < 40 ms p95 capture→present, < 4 ms GPU per frame on Apple Silicon.

## Non-goals

No virtual camera, no browser extension, no OCR/ML detection (geometric presets only), no
per-window compositing, no App Store/notarisation, no Windows/Linux (yet).
