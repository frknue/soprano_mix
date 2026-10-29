# Changelog

All notable changes to Soprano Mix are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Menu-bar mixer panel in Soprano's Folio chrome (Folio Paper in light mode, Folio Ink in dark mode) listing every app that plays sound, with its icon, a volume slider, mute, its output device and a level meter.
- Every app that outputs sound is listed as one row: browser and Electron helpers, WebKit's GPU process, XPC services and app extensions fold into their app, programs without a bundle (`afplay`, `mpv`) appear under their own name, and system processes appear as System Sounds, Siri, Spoken Content, FaceTime and Hearing.
- Games and programs under CrossOver, Whisky or Wine appear as themselves, named after the game's folder (TEKKEN 8, key `wine:TEKKEN 8`) with the icon from their .exe, so a game can be turned down without its in-game settings.
- Per-app volume from 0 to 400 % on a loudness scale (50 % half as loud, 200 % twice as loud), with a limiter that keeps boosted apps from clipping (`audio.limiter`); double-click resets to 100 %.
- Per-app mute and per-app output device, falling back to the system output while the chosen device is gone.
- Output, input and sound-effects sections: pick the system device, set its volume and mute, the output balance, the input level, the alert volume and the sample rate.
- Software volume for outputs without hardware volume (HDMI, DisplayPort, some USB DACs), controlled from the panel and by the keyboard's volume keys with Soprano Mix's own HUD (`volumeKeys.anyOutput`, `volumeKeys.hud`; needs Accessibility and System Audio Recording, without which the keys stay with macOS).
- Only apps with a setting are tapped: apps at 100 % on the system output play untouched, and quitting Soprano Mix restores every app's audio.
- Optional global hotkey for the panel (`panel.hotkey`) and level meters while the panel is open (`panel.meters`).
- `~/.config/soprano-mix/settings.json` (or `$XDG_CONFIG_HOME/soprano-mix/`, or `SOPRANO_MIX_CONFIG`) with live reload; per-app settings are saved by bundle id, `wine:<Name>` or `exe:<name>`; bad values keep their default and show as "settings.json: N warnings" in the menu and "settings.json · N warnings" in the panel's footer.
- `theme`: `soprano` (default) follows Soprano's theme and appearance, `folio` follows macOS light and dark mode, or pin `folio-paper`, `folio-ink` or one of the dark themes.
- Menu bar item with a three-fader icon (`app.menuBarIcon`: outlined, filled, hidden): left click toggles the panel, right click shows Open settings.json… (`⌘,`), Permissions…, Launch at Login (on by default), About and Quit.
- Command line: `SopranoMix list`, `devices`, `set <app> <0-400>`, `mute <app>`, `unmute <app>`, `output <app> <device|default>`, `show`, `hide` against the running app with JSON output; app names with spaces work quoted or unquoted, and a key such as `"wine:TEKKEN 8"` can be set before the game runs.
- `SopranoMix scan [--all]` prints every audio process and how it is grouped into apps, without the running app or any permission.
- `SopranoMix selftest` routes a test tone through a real process tap and reports peaks, latency and pass or fail.
- Permissions window for System Audio Recording and Accessibility: it opens once on first launch, and grants made in System Settings apply without a relaunch; once access was denied, the panel's "Open Settings" goes straight to the System Settings pane.
- Only one Soprano Mix runs at a time: a second launch (installed app or dev build) quits at once, so no app is routed twice.

### Fixed

- A routed app (Chrome, Aside …) no longer goes silent for good when its route is rebuilt, e.g. after switching the output device: Core Audio's device-change notifications could deadlock the route builder, leaving the app muted by its old tap with nothing playing it.
- The macOS volume HUD no longer gets stuck on screen with the volume pinned at the end of its range after pressing a volume key: Soprano Mix's volume-key tap ran on the main thread, and while that thread was busy macOS dropped the key's release and repeated the key until the next press. The tap now decides each key on its own thread, and every press reaches macOS whole or not at all.
- settings.json is never replaced by the template when it exists but cannot be read (not UTF-8, no permission): the change stays pending instead of wiping every app and output setting.
- A route that fails to build (a device still reconfiguring) is retried on its own after 2 s, backing off to 60 s, instead of leaving the app at full volume until some other setting changes; a failed read of the output's alive state no longer tears a working route down.
- Quitting while routes exist can no longer hang: Core Audio's notifications for the app reach the main thread through their own queue, so tearing routes down never waits on a main thread that waits on it.
- Route builds no longer make Soprano Mix re-scan every device and reinstall every listener, and a volume change is read once instead of once per notification.
- Opening the panel no longer logs Auto Layout conflicts for hidden chips and mute buttons.
