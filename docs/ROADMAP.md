# Roadmap

Soprano Mix copies SoundSource's per-app and system-device controls. What is left out,
and why, is listed below, followed by what comes after phase 1.

## Not copied (family conventions)

- Preferences window beyond the panel: `~/.config/soprano-mix/settings.json`, live
  reloaded, opened from the menu bar item.
- Sparkle updates and crash reports: install with `scripts/install.sh`.
- The license and trial mode.
- UI languages other than English.

## Later

- Per-app and system-wide effects: 10-band equalizer, Audio Unit plugins, Magic Boost,
  Headphone EQ.
- Per-app AirPlay streaming and output groups (several devices at once).
- Shortcuts app actions.
- Devices window (every device's settings in one place).
- Per-app input (microphone) control.
- A Soprano Cast command to open the panel or mute an app.
- Notarized releases and a Homebrew cask, like Soprano's.

## Linux (Omarchy)

Furkan moves to Omarchy (Arch Linux, Hyprland, Wayland) later. Today only macOS builds.

- The audio backend is a rewrite: CoreAudio (`AudioObject*`, devices, process taps) becomes
  PipeWire, where per-app streams are native (`wpctl`, `pactl` sink inputs). Most of
  SoundSource's per-app control comes cheaper there.
- Build the rest of `SopranoMixCore` (about 3,200 lines, Foundation and CoreGraphics) on Linux
  (Swift through `swiftly`), with its own test target and a Linux CI job.
- Hotkeys (Carbon): binds in `hyprland.conf` calling a `soprano-mix` command. Login item
  (`SMAppService`): `exec-once` or a systemd user unit. The menu-bar panel: a Waybar module.
- The UI (about 13,200 lines of AppKit) is rebuilt on the toolkit chosen once for the family,
  in Soprano first (every app syncs its chrome from there).
