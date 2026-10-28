# Using sharemask

How to use sharemask day to day: the menu, the keys, drawing masks, and how capture follows your meetings.

## The app window

Open sharemask from Finder, Launchpad or the Dock (or **Open sharemask…**, ⌘O, in the menu):

- **Status orb**: grey and breathing in standby, green and pulsing while you're sharing, red in panic.
- **Start sharing / Stop**, **Panic** and **What others see** (a live preview of the shared feed).
- **Masks**: every app you've drawn masks for, each with an on/off switch and an edit button;
  **Add an app** opens the region editor for it.
- **App lock**: each locked app with its status and a summary of its settings; click one to change
  when it relocks, hide its notification previews, lock it now or stop locking it. **Add an app**
  (running apps or any app in Applications) and *Defaults* for new apps.
  See [App lock](APP-LOCK.md).
- **Present**: appears with Extend / Mirror buttons when a TV or projector is connected.
  See [Presenting in a room](PRESENTING.md).

The window shows sharemask in the Dock while it's open; close it and sharemask keeps running in
the menu bar.

## The menu and its shortcuts

Menu bar icon: grey = stopped, green = proxy active, red = PANIC, yellow = error (hover for details).

The menu keeps the essentials on top; everything else is one level down.

| Menu item | Default hotkey | What it does |
|---|---|---|
| Open sharemask… | ⌘O (in the menu) | The app window described above. |
| Start capturing / Stop | | Starts capture (creating the “sharemask” display), or stops capture or presenting and returns to standby. |
| Panic | ⌘⇧⌃B | Pixellates the **whole** feed on the next frame (≤ 17 ms). Press again to restore. |
| End share now (Troubleshooting ▸) | ⌃⌥X, ⌘⇧⌃X | Emergency stop: removes the “sharemask” display (ends the share in your call app) or stops presenting; back to standby, no relaunch needed. |
| Masks ▸ | ⌘⇧⌃M, ⌘⇧⌃A | Per-app masks on/off, allowlist mode, and ticks for each app, region, rule and notification masking (session only). Hold ⌘⇧⌃R to reveal the frontmost app. |
| Edit regions ▸ | ⌘⇧⌃P | Region editor for the frontmost app or any running app, configured apps (edit/remove), presets.json. |
| What others see | | Floating preview of the live proxy output (never captured). |
| App lock ▸ | ⌃⌘L, ⌃⇧⌘L | Lock the current app / all apps, the list of locked apps, relock timing, quit guard, keep-alive, sharemask password. |
| Settings ▸ | | Setup & permissions (the welcome), Shortcuts (press-to-remap), Launch at login, Pointer guard, status HUD, daily update check. |
| Troubleshooting ▸ | | Remove proxy display now, show log file, dump window list, relaunch. |
| ⚠ Bring back N windows… | | Appears only if another app put a window on the hidden display. |
| sharemask 0.2.x ▸ | | Version and update status. **Check for updates now**, release notes, copy the update command, and **Update now** when a newer release exists (runs `brew upgrade --cask sharemask` in Terminal and relaunches). |

## Keys while sharing
While sharemask is capturing or presenting, simple ⌃⌥ keys are live (they're released again when it
stops, so they never clash with other apps day to day). A card listing them appears the first time
a session starts; ⌃⌥K shows it again.

| Key | Action |
|---|---|
| ⌃⌥B | Panic: pixellate everything / restore |
| ⌃⌥M | All per-app masks off / on |
| ⌃⌥R (hold) | Reveal the frontmost app while held |
| ⌃⌥1 … ⌃⌥9 | Unmask / re-mask app #1–9 (numbered in Masks ▸) |
| ⌃⌥0 | Re-enable every mask |
| ⌃⌥A | Allowlist mode on / off |
| ⌃⌥X | End share / stop presenting |
| ⌃⌥K | Show the key card |

The ⌃⇧⌘ shortcuts (panic, toggle, pick, reveal, allowlist, end share) stay active all the time and
can be remapped under Settings ▸ Shortcuts.

## Region editor
A transparent overlay sits exactly over the app's window (and follows it if it moves). Drag on
empty space to draw a **rectangle, square or circle**; drag a shape to move it; drag its handles to
resize; arrow keys nudge; Delete removes; Esc cancels; Enter saves. Each shape shows the actual
pixellation preview, and the toolbar sets its mode (pixellate / blur / black) or drops in a
template (left/right sidebar, top bar, whole window, centre circle). Regions are stored
normalised to the window, so they keep fitting when the window is resized.

## Capture only during meetings
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
proxy is running; `"manual"` only via the menu. The "sharemask" display exists only while
capturing, so it appears in Zoom/Meet's share picker once you've started (accept the prompt or
press Start).

Launch flags: `--demo` adds a hard-coded pixellate rect at (100,100,400,300) px for testing;
`--probe` runs the display diagnostics CLI.

## Notification banners while sharing

"Notification banners" (Masks ▸, on by default) blacks out any banner that appears while you share.
sharemask reads each banner's position through Accessibility and masks just that box; without
Accessibility it masks Notification Center's whole window (on recent macOS that's the full
screen, so the feed goes black for a few seconds — granting Accessibility avoids that).

See also: [App lock](APP-LOCK.md) · [Presenting in a room](PRESENTING.md) · [Configuration](CONFIGURATION.md)

---
[← Back to the README](../README.md)
