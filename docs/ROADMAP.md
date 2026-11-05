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

Furkan wechselt später auf Omarchy (Arch Linux, Hyprland, Wayland). Heute baut die App nur auf
macOS.

- Das Audio-Backend wird neu geschrieben: aus CoreAudio (`AudioObject*`, Geräte, Process Taps)
  wird PipeWire, wo Streams pro App eingebaut sind (`wpctl`, `pactl`-Sink-Inputs). Der Großteil
  von SoundSources Steuerung pro App ist dort günstiger.
- Den Rest von `SopranoMixCore` (etwa 3.200 Zeilen, Foundation und CoreGraphics) auf Linux bauen
  (Swift über `swiftly`), mit eigenem Testtarget und einem Linux-CI-Job.
- Hotkeys (Carbon): Bindings in `hyprland.conf`, die einen `soprano-mix`-Befehl aufrufen.
  Anmeldeobjekt (`SMAppService`): `exec-once` oder eine systemd-User-Unit. Das
  Menüleisten-Panel: ein Waybar-Modul.
- Die UI (etwa 13.200 Zeilen AppKit) wird auf dem Toolkit neu gebaut, das einmal für die ganze
  Familie gewählt wird, zuerst in Soprano (jede App synct ihr Chrome von dort).
