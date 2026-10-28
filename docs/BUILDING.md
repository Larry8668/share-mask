# Building from source

Build, sign and run sharemask yourself.

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

---
[← Back to the README](../README.md)
