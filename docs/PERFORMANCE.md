# Performance

sharemask runs all day in the menu bar, so what it costs while you're *not* sharing matters more
than how fast it is while you are. This page has the current numbers, how they're measured, and how
the idle cost went from "noticeable" to "negligible" in 0.2.5.

## Current numbers

Apple Silicon MacBook Air, macOS 27, steady state (measured 25 s after launch, over 30 s):

| State | CPU (of one core) | Wake-ups / s |
|---|---|---|
| Standby, App lock on, window closed | **0.5%** | ~6 |
| Standby, sharemask window open | 2.3% | ~6.5 |
| App lock hiding notification previews | 0.8% | ~7.5 |
| Capturing during a call | ~5% | ~31 |

"Wake-ups" are how often the app makes the CPU leave its idle state; on a laptop they matter for
battery even when each one is tiny. While capturing, sharemask copies and redraws your screen up to
60 times a second on the GPU (about 4 ms per frame from capture to display, ~1.5 ms of GPU time), so
~5% is the expected price, and it is only paid during calls.

## How it went from 38% to 0.5% (0.2.4 → 0.2.5)

A user asked whether a notification check running "ten times a second" was a concern. Measuring
instead of guessing turned up something much bigger:

| | 0.2.4 | 0.2.5 |
|---|---|---|
| Standby, window open | **38% CPU** | 2.3% |
| Standby, window closed | 5.8% CPU, 24 wake-ups/s | 0.5%, 6 wake-ups/s |

What `sample` showed, and what changed:

1. **A forever-breathing status orb.** The window's orb ran a repeat-forever SwiftUI animation even
   in standby. Every frame made SwiftUI recompute layout and the window's drag regions (the
   window was movable by its background), which alone cost ~35% of a core.
   → The orb animates only while sharing; the window is no longer draggable by its background.
2. **A closed window that kept living.** Closing the window kept its SwiftUI view alive.
   → The view is released when the window closes.
3. **Timers with nothing to do.** In standby sharemask still tracked every window 10×/s, ran a
   10×/s re-render timer and a watchdog for a display that didn't exist, checked App lock 4×/s,
   and rebuilt every submenu and the window's data (app names, icons) once a second.
   → Window tracking, re-rendering and the watchdog start with the sharemask display and stop with
   it. App lock checks 4×/s only while a locked app is unlocked (reopen detection needs it),
   otherwise once a second, and not at all when App lock is off. Menus and the window rebuild only
   when you can see them. The menu-bar icon redraws only when its state changes.
4. **Coalescing.** Every remaining timer has a tolerance, so macOS can batch wake-ups.

The notification check that prompted the question costs ~0.3% when it runs, and it only runs while
you're sharing or hiding locked apps' previews: twice a second, ten times a second only while a
banner is actually on screen.

## Measuring it yourself

```sh
P=$(pgrep -f "sharemask.app/Contents/MacOS/sharemask$")
top -l 3 -s 10 -pid $P -stats cpu,idlew,power     # CPU %, wake-ups per sample, energy impact
sample $P 5 -file /tmp/sharemask.sample.txt        # where the time goes
```

Activity Monitor's Energy tab shows the same "Energy Impact". sharemask also logs a frame-clock line
(fps, latency, GPU time) every 15 s while capturing, in `~/Library/Logs/sharemask/sharemask.log`.

## Rules the code follows

- Nothing polls unless something visible or active needs it.
- Animations only while they carry information (sharing / panic).
- Prefer events (workspace notifications, Accessibility observers, display reconfiguration
  callbacks) over polling; where polling is needed, the rate follows the situation.
- Measure with `top` and `sample` before and after any change that adds a timer or animation.

---
[← Back to the README](../README.md)
