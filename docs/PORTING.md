# Porting sharemask to Windows and Linux

sharemask is three things: a **frame source**, a **redactor** driven by a pure **region resolver**,
and a **sink** that is a virtual display the user shares. Only macOS is implemented, but the shape
of a port is clear, and the resolver already exists as a platform-independent Rust crate in
[`core/`](../core) (`cargo test` runs the same cases as the Swift tests).

## What each platform needs

| Piece | macOS (done) | Windows | Linux |
|---|---|---|---|
| Virtual display | private `CGVirtualDisplay` | an **Indirect Display Driver** (IddCx). Open-source base: Microsoft's IddSampleDriver / the "Virtual Display Driver" projects (MTT's `Virtual-Display-Driver`, `usbmmidd`). Needs a signed driver (test-signing or an EV cert) and an install step. | **Wayland**: wlroots compositors expose headless outputs (`wlr-output-management`, Sway `create_output`); GNOME/KDE have no public API, so a virtual output is compositor-specific. **X11**: `xrandr --setmonitor` virtual monitor or a dummy `VIRTUAL1` output (Intel) is enough. |
| Capture of the real display | ScreenCaptureKit | `Windows.Graphics.Capture` (WinRT, Win10 1903+), 60 fps, includes cursor; or DXGI Desktop Duplication. | PipeWire via the xdg-desktop-portal ScreenCast (Wayland + X11), DMA-BUF frames; or X11 `XShm`/`XComposite`. |
| Window list with z-order | `CGWindowListCopyWindowInfo` | `EnumWindows` + `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)` + `IsWindowVisible` + cloaked check; z-order is enumeration order. Process → exe path via `QueryFullProcessImageName`. | X11: `_NET_CLIENT_LIST_STACKING` + `XGetWindowAttributes`. Wayland: **no global window list** for third parties (only `wlr-foreign-toplevel-management` on wlroots, and it lacks geometry). This is the real blocker; the fallback is allowlist-free "mask whole screen except the shared app's own surface" or an X11 session. |
| Redaction | Core Image on Metal | Direct3D 11 compute shader (pixellate = box average per block) or DirectCompute via `windows-rs`; wgpu works too. | wgpu (Vulkan/GL) compute shader. |
| Output to the virtual display | CAMetalLayer window | a borderless fullscreen window on the IDD monitor, DXGI swap chain; or feed the IDD driver's swap chain directly (the driver receives the composited desktop anyway). | fullscreen surface on the headless output. |
| Global hotkeys | Carbon `RegisterEventHotKey` | `RegisterHotKey` | X11 `XGrabKey`; Wayland needs the compositor's global-shortcuts portal. |
| "Only capture in meetings" | CoreAudio "running somewhere" | `IAudioSessionManager2` enumerate sessions with state Active on a capture endpoint (per-process!) | PipeWire/PulseAudio source-output list (per-process). |
| Hide our own windows from capture | `sharingType = .none` + filter | `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` (Win10 2004+) | none generally; keep UI on the virtual output or in a tray only. |

## Suggested structure

```
core/            Rust: presets, resolver (done), later: pipeline scheduling + tests
platform/macos   (today's Swift app; could call into core via a C ABI from the cdylib)
platform/windows Rust: windows-rs for WGC + D3D11 + IDD client, tray via tray-icon
platform/linux   Rust: pipewire-rs + wgpu + compositor-specific virtual output
```

Start with Windows: the IDD route is well-trodden (several "virtual monitor" products ship it),
`Windows.Graphics.Capture` is stable, and per-process audio session state makes meeting detection
better than on macOS. Linux-Wayland should be treated as experimental until a window-geometry
source exists for the user's compositor.

## Measured macOS behaviour the ports should copy
- Fail closed: no frames for 3 s → black proxy, restart capture, alert. Never show a stale frame.
- One stable virtual-display identity (name/vendor/product/serial) so arrangement and profiles
  persist and nothing litters the system.
- Over-redact on any doubt: occluders that are invisible to capture must not punch holes; overflow
  collapses to bounding boxes.
