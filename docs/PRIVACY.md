# Privacy & data

What sharemask stores, what it sends, and where its logs are.

## What sharemask stores

- `~/.config/sharemask/presets.json`: masks, rules, shortcuts.
- `~/Library/Logs/sharemask/`: logs (≤ ~10 MB).
- `~/.config/sharemask/applock.json`: App lock's list of apps and settings (no secrets).
- Keychain item `dev.sharemask.applock` / `password`: the hashed sharemask password, only if you set one.
- `~/Library/LaunchAgents/dev.sharemask.keepalive.plist`: only while App lock's relaunch option is on.

## Network use

sharemask makes exactly one kind of network request: once a day (and when you click "Check for
updates now") it asks `api.github.com` for the latest release tag of this repo. Nothing about you or
your screen is sent. Turn the daily check off under Settings ▸ Check for updates daily.

## Logs

Everything goes to `~/Library/Logs/sharemask/sharemask.log` (rotated at 5 MB, one previous file
kept, so never more than ~10 MB on disk; the folder is pruned at launch), to the unified log
(subsystem `dev.sharemask.app`, notice level) and to stderr when run from a terminal. Crashes write
a final `[FATAL]` line; macOS crash reports are in `~/Library/Logs/DiagnosticReports`.

---
[← Back to the README](../README.md)
