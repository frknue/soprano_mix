# Changelog

All notable changes to Soprano Mix are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Menu-bar mixer panel in Soprano's Folio chrome (Folio Paper in light mode, Folio Ink in dark mode) listing every app that plays sound, with its icon, a volume slider, mute, its output device and a level meter.
- Every app that outputs sound is listed as one row: browser and Electron helpers, WebKit's GPU process and XPC services fold into their app, programs without a bundle (`afplay`, `mpv`) appear under their own name, and system processes appear as System Sounds, Siri, Spoken Content, FaceTime and Hearing.
- Games and programs under CrossOver, Whisky or Wine appear as themselves, named after the game's folder (TEKKEN 8, key `wine:TEKKEN 8`) with the icon from their .exe, so a game can be turned down without its in-game settings.
- Per-app volume from 0 to 400 % on a loudness scale (50 % half as loud, 200 % twice as loud), with a limiter that keeps boosted apps from clipping (`audio.limiter`); double-click resets to 100 %.
- Per-app mute and per-app output device, falling back to the system output while the chosen device is gone.
- Output, input and sound-effects sections: pick the system device, set its volume and mute, the output balance, the input level, the alert volume and the sample rate.
- Software volume for outputs without hardware volume (HDMI, DisplayPort, some USB DACs), controlled from the panel and by the keyboard's volume keys with Soprano Mix's own HUD (`volumeKeys.anyOutput`, `volumeKeys.hud`; needs Accessibility).
- Only apps with a setting are tapped: apps at 100 % on the system output play untouched, and quitting Soprano Mix restores every app's audio.
- Optional global hotkey for the panel (`panel.hotkey`) and level meters while the panel is open (`panel.meters`).
- `~/.config/soprano-mix/settings.json` (or `$XDG_CONFIG_HOME/soprano-mix/`, or `SOPRANO_MIX_CONFIG`) with live reload; per-app settings are saved by bundle id, `wine:<Name>` or `exe:<name>`; bad values keep their default and show as "settings.json: N warnings" in the menu and the panel.
- `theme`: `soprano` (default) follows Soprano's theme and appearance, `folio` follows macOS light and dark mode, or pin `folio-paper`, `folio-ink` or one of the dark themes.
- Menu bar item with a three-fader icon (`app.menuBarIcon`: outlined, filled, hidden): left click toggles the panel, right click shows Open settings.json… (`⌘,`), Permissions…, Launch at Login (on by default), About and Quit.
- Command line: `SopranoMix list`, `devices`, `set <app> <0-400>`, `mute <app>`, `unmute <app>`, `output <app> <device|default>`, `show`, `hide` against the running app with JSON output; app names with spaces work quoted or unquoted.
- `SopranoMix scan [--all]` prints every audio process and how it is grouped into apps, without the running app or any permission.
- `SopranoMix selftest` routes a test tone through a real process tap and reports peaks, latency and pass or fail.
- Permissions window for System Audio Recording and Accessibility: it opens once on first launch, and grants made in System Settings apply without a relaunch.
