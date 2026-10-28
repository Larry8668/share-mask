# How it works

The proxy-display idea, the measured behaviour of the private API it relies on, and performance.

## The idea

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

## The proxy display exists only while capturing

The “sharemask” display is created when capture starts (you accept the meeting prompt or press
Start) and removed when it stops. Outside meetings there is no extra screen at all.

While it exists, macOS treats it as a real monitor: apps can open windows on it and macOS restores
windows onto it when it reappears. Those windows would be invisible to you (a Finder error dialog
hidden there once stopped a Mac from shutting down). sharemask watches for this every second:

- With **Accessibility** permission (optional, asked the first time it happens) it moves such
  windows back to your real screen automatically.
- Without it, it tells you and offers to remove the display, which makes macOS move them home.

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
7. Created on demand (when capture starts), after AppKit has enumerated displays, so
   `CGDisplayCopyDisplayMode` is NULL for it inside the app; nothing in the app needs it. Released
   asynchronously from the main run loop: the process's display list only refreshes when the main
   run loop turns, so a blocking poll on the main thread always times out.
8. Created at the real display's pixel size with a ~110 DPI physical size, so macOS enters the
   native 1× mode. With a Retina-like DPI it would come up at half size. Note that
   `CGDisplayPixelsWide` returns *points* on Retina displays; the pixel size is read from the mode.

## Performance

`FrameClock` logs every 5 s (unified log, subsystem `dev.sharemask.app`, or stderr when run from a
terminal) and the menu shows: fps, capture→present latency p50/p95, pipeline time, GPU time, drops.
Targets: < 40 ms p95 capture→present, < 4 ms GPU per frame on Apple Silicon.
Measured on an M-series MacBook at 2940×1912 (macOS 27.0.1): capture→present 4 ms p50 / 6–17 ms p95,
pipeline 2.6 ms, GPU 1.3–1.5 ms. The fps figure follows screen activity: ScreenCaptureKit only
delivers frames when content changes, so a static desktop reads ~8–10 fps and rises to 60 under motion.

### Battery and CPU

Measured on an Apple Silicon MacBook (0.2.5, steady state):

| State | CPU | Wake-ups/s |
|---|---|---|
| Standby, App lock on, window closed | 0.5% | ~6 |
| Standby, app window open | 2.3% | ~6.5 |
| Hiding notification previews for locked apps | 0.8% | ~7.5 |
| Capturing during a call (60 fps pipeline) | ~5% | ~31 |

Everything that polls runs only while it's needed: window tracking and the redraw/watchdog timers
only while the sharemask display exists; the notification watcher only while capturing or hiding
locked apps' previews (2×/s, 10×/s only while a banner is on screen); App lock's check 4×/s only
while a locked app is unlocked, otherwise once a second; menus and the app window rebuild only when
visible. The status orb animates only while sharing (a repeat-forever SwiftUI animation cost ~35%
of a core in 0.2.4).

## Source layout

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

## Other platforms

The resolver is also a platform-independent Rust crate (`core/`, `cargo test`), and
[`docs/PORTING.md`](PORTING.md) lays out what a Windows (IddCx + Windows.Graphics.Capture)
and Linux (PipeWire + headless output) port needs. Only macOS is implemented.

## Non-goals

No virtual camera, no browser extension, no OCR/ML detection (geometric presets only), no
per-window compositing, no App Store/notarisation.

---
[← Back to the README](../README.md)
