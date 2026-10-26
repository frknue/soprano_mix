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
