# Presenting in a room

Show your screen on a TV or projector (HDMI, AirPlay, Sidecar) with masks applied.

## Two ways to present

When a TV or projector connects (cable, or AirPlay from Control Center ▸ Screen Mirroring), sharemask
asks whether to present with masks, in one of two ways (also under **Present to <screen> ▸**):

- **Masked extend**: keep extending as usual and drag windows onto the TV; masked parts of those
  windows come out pixellated on the TV. Your laptop stays private.
- **Masked mirror**: the TV shows your whole laptop screen, masked. Nothing else can appear on the
  TV, and your cursor stays on the laptop.

macOS's own mirror mode can't carry masks (the system copies the pixels itself), so if the TV
connects mirrored, sharemask switches it to a separate display after you confirm, and switches it
back when you stop or quit. Unplugging the TV stops presenting automatically.

## Multiple monitors

With more than one screen connected, the menu shows **Share screen: <name> ▸** and the meeting
prompt has a screen picker; the proxy display is sized to whichever screen you pick, and the
choice is remembered.

macOS places a new display next to the existing ones, sometimes *between* two real screens. The
first time that happens for a given monitor setup, sharemask moves the proxy display to a corner
where it touches your screens only diagonally (using a short-lived helper process, because moving
it from the app itself would make it impossible to remove until quit). macOS remembers that spot
for next time. If placement ever fails, the pointer guard switches itself off rather than block
your cursor.

---
[← Back to the README](../README.md)
