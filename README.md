# Soprano Mix

**A per-app audio mixer for macOS, in the Soprano family.**

Soprano Mix is a copy of [SoundSource](https://rogueamoeba.com/soundsource/) in Soprano's
Folio chrome (Paper in light mode, Ink in dark mode). Its menu-bar panel lists every app
that plays sound, each with its own volume from 0 to 400 %, mute and output device, above
the controls for the system's output, input and sound-effects devices. Outputs without
hardware volume (HDMI, DisplayPort, some USB DACs) get a software volume that the keyboard's
volume keys control. Games running under CrossOver or Wine show up as themselves, so you
can turn TEKKEN 8 down without opening its settings.

It lives in the menu bar and has no Dock icon. It needs no audio driver and no kernel
extension: it is built on Core Audio process taps (macOS 14.2 or later). Behavior follows
SoundSource's documented behavior; no SoundSource code is used.

## Install

```bash
./scripts/install.sh            # release build → /Applications/Soprano Mix.app
./scripts/install.sh --restart  # same, then quits the running copy and launches the new one
```

`SOPRANO_MIX_INSTALL_DIR` installs somewhere else (an absolute directory). Without
`--restart` the installer leaves a running Soprano Mix alone and the update applies on
its next launch. `--restart` quits the running installed copy (a normal quit, so settings
are saved and routes stop; a copy that does not quit within 10 s is terminated) and
launches the new one. Launch at login is on by default.

Only one Soprano Mix runs at a time: two would tap and replay every app twice. A second
launch, of the installed app or the dev build (`com.soprano.mix.dev`), quits at once
while another one runs.

The first launch opens the permissions window once:

- **System Audio Recording** (required to change an app): click Allow and confirm macOS's
  prompt. Without it, Soprano Mix still lists every app and controls the devices, but it
  leaves every app's audio untouched.
- **Accessibility** (optional): only for the volume keys on outputs without hardware
  volume.

The icon in the menu bar (three faders) means it is running.

## The first minute

1. Play something, e.g. a song in Spotify and a video in Safari.
2. Click the faders icon in the menu bar: the panel opens with Spotify and Safari listed
   under APPS.
3. Drag Spotify's slider to 50 %: it gets quieter at once, Safari stays as it was.
4. Double-click the slider: back to 100 %, which leaves Spotify untouched again.
5. Press `⎋` or click anywhere else to close the panel.

Settings are remembered per app: Spotify plays at 50 % the next time it starts, also after
a restart of the Mac.

## The panel

From top to bottom:

- **Output**: the system output device (a menu of every output), its volume and mute, the
  balance, and its sample rate on the right. A `SOFTWARE` chip marks an output whose volume
  Soprano Mix provides (see below).
- **Input**: the system input device, its input level and mute, its sample rate.
- **Sound effects**: the device alerts and interface sounds play on, and the alert volume.
- **APPS · N**: one row per app: icon, name, a slider from 0 to 400 % with its readout,
  a level meter under the slider, the app's output device (the chip shows the device when
  it is not the system output), and mute. Apps that are not playing right now are shown
  muted grey.
- **Footer**: "settings.json · N warnings" while settings.json has problems, and the gear,
  which opens the same menu as a right click on the menu-bar icon.

While nothing plays, the list says *Nothing is playing*. While System Audio Recording is
missing, a banner above the apps asks for it: "Allow" shows macOS's prompt; once it was
denied, "Open Settings" opens System Settings → Privacy & Security at the audio recording
list, because macOS does not ask twice.

Keyboard: the panel takes the keys while it is open. `←`/`→` change the focused slider by
1 % (`⇧` for 10 %), `⎋` closes. A global hotkey can open the panel from anywhere
(`panel.hotkey`, e.g. `control+option+m`).

### Which apps are listed

Every app that plays sound, as one row per app:

- helper processes fold into their app: Chrome's, Slack's, Discord's and every Electron
  app's renderers, Safari and every app using WebKit (its GPU process plays the sound),
  XPC services;
- programs without an app bundle appear under their own name (`afplay` started from a
  terminal is "afplay", not the terminal);
- system processes appear with friendly names: System Sounds, Siri, Spoken Content,
  FaceTime, Hearing;
- games and programs under CrossOver or Wine appear as themselves (see below).

An app is listed while it plays, after it has played since it connected to Core Audio, or
while it has a setting (a volume other than 100 %, mute, or another output). An app that
quits is forgotten unless it has a setting. Soprano Mix never lists itself.

## Volume, boost and the limiter

Each app's slider runs from 0 to 400 %. 100 % (the tick on the slider) leaves the app
exactly as it is; double-click the slider to get back there. The first two thirds of the
slider cover 0–100 %, the last third the boost from 100 to 400 %, shown in yellow.

The scale follows loudness, not voltage: 50 % sounds half as loud (−10 dB), 200 % twice
as loud (+10 dB), 400 % +20 dB. Above 100 % a limiter keeps the boosted app from clipping
(peaks stay below −0.3 dBFS); turn it off with `audio.limiter: false`.

Mute silences one app; its volume is kept for when you unmute it.

## Per-app output

The device button on an app row sends that app to another output: music to the speakers
while a call stays on the headphones, or a game to the TV. "System output (…)" follows the
macOS output again. The choice is saved by device UID; when the device is gone, the app
plays on the system output until it comes back.

## Outputs without hardware volume

HDMI and DisplayPort monitors and some USB DACs have no volume of their own, so macOS greys
out its volume slider and the volume keys show a crossed-out speaker. Soprano Mix gives
these outputs a **software volume**: the Output slider (marked `SOFTWARE`) and, with
`volumeKeys.anyOutput` on (the default), the keyboard's volume keys change it, with
Soprano Mix's own volume HUD at the top right (`volumeKeys.hud`). `⌥⇧` with a volume key
takes quarter steps; the mute key toggles mute. The volume is saved per device under
`outputs`.

The volume keys need Accessibility, and System Audio Recording to apply the software
volume (without it the keys stay with macOS rather than show a change that never
happens). Soprano Mix never asks for Accessibility on its own: grant it in the
permissions window, and the keys start working within two seconds, without a relaunch.
On outputs with hardware volume, the keys stay with macOS.

## Games under CrossOver

Windows games and programs running under CrossOver (or Whisky, or plain Wine) show up as
themselves, not as "CrossOver" or "wine64-preloader". The name comes from the game's
folder:

| Windows path of the running program | Listed as | Settings key |
|---|---|---|
| `C:\Program Files (x86)\Steam\steamapps\common\TEKKEN 8\Polaris\Binaries\Win64\Polaris-Win64-Shipping.exe` | TEKKEN 8 | `wine:TEKKEN 8` |
| `C:\Program Files (x86)\Steam\steam.exe` and `steamwebhelper.exe` | Steam | `wine:Steam` |
| `C:\GOG Games\The Witcher 3\bin\x64\witcher3.exe` | The Witcher 3 | `wine:The Witcher 3` |
| `C:\Games\Foo\foo.exe` | foo | `wine:foo` |

So to turn TEKKEN 8 down without touching its in-game settings: open the panel while it
plays and drag its slider, or from a terminal:

```bash
"/Applications/Soprano Mix.app/Contents/MacOS/SopranoMix" set "wine:TEKKEN 8" 35
```

The setting is saved as `"wine:TEKKEN 8": { "volume": 35 }` and applies every time the
game plays again. The icon comes from the game's .exe in its CrossOver bottle, wherever
CrossOver keeps its bottles (its Bottle location preference, also on an external drive).

## Settings

Settings live in `~/.config/soprano-mix/settings.json` (`$XDG_CONFIG_HOME/soprano-mix/`
when `XDG_CONFIG_HOME` is set; `SOPRANO_MIX_CONFIG` overrides the whole path). The file is
created with comments on first launch, accepts comments and trailing commas, may be a
symlink (a dotfiles link survives), and reloads as soon as you save it. Open it from the
menu (`⌘,`). The panel and the command line write their changes into it, keeping your
comments and key order. Every key is optional.

A bad value is ignored and keeps its default; it never stops the app. Each problem is
logged; the menu shows "settings.json: N warnings" (hover it for the messages) and the
panel's footer "settings.json · N warnings". A file that is not valid JSON keeps the
last good settings running.

```jsonc
{
  // "soprano" follows Soprano's theme and appearance; "folio" follows macOS (Folio Paper
  // in light mode, Folio Ink in dark mode); or pin "folio-paper", "folio-ink" or a dark
  // theme: gruvbox-dark, catppuccin-mocha, dracula, solarized-dark, nord, tokyo-night,
  // atom-one-dark.
  "theme": "soprano",

  // Per app, written by the panel and the command line. Apps without an entry play
  // untouched. Key: the bundle id; "wine:<Name>" for CrossOver/Wine games and programs;
  // "exe:<name>" for programs without a bundle (afplay, mpv).
  "apps": {
    "com.spotify.client": { "volume": 60 },
    "wine:TEKKEN 8": { "volume": 35, "muted": false, "output": "default" }
    // volume: 0–400 percent (100 = unchanged); muted: true | false;
    // output: a device UID or name, or "default" (follow the system output)
  },

  // Software volume of outputs without hardware volume. Key: the device UID or name.
  "outputs": {
    "Odyssey G91F": { "volume": 50, "muted": false }   // volume 0–100
  },

  "panel": {
    "hotkey": null,         // e.g. "control+option+m"; null: no hotkey
    "meters": true          // level meters while the panel is open
  },

  "volumeKeys": {
    "anyOutput": true,      // volume keys for outputs without hardware volume (Accessibility)
    "hud": true             // Soprano Mix's volume HUD for them
  },

  "audio": {
    "bufferFrames": 256,    // IO buffer of every app route, 32–4096 frames
    "limiter": true         // limit apps above 100 % so they never clip
  },

  "app": {
    "startAtLogin": true,
    "menuBarIcon": "outlined"   // outlined, filled, hidden
  }
}
```

Notes:

- `volume` values are clamped into their range with a warning (`apps`: 0–400, `outputs`:
  0–100); `bufferFrames` is clamped to 32–4096.
- `output` matches a device by UID first, then by name (case-insensitive).
- `panel.hotkey`: modifiers joined with `+`, at least one of `control` (`ctrl`, `⌃`),
  `option` (`alt`, `opt`, `⌥`), `command` (`cmd`, `⌘`); `shift` and `fn` may be added; the
  last part is a key: one character, `space`, `return`, `tab`, `escape`, the arrows, or
  `f1`…`f12`. The hotkey needs no permission.
- `bufferFrames`: smaller adds less latency (256 frames at 48 kHz ≈ 5 ms) and costs more
  CPU. Raise it if a routed app crackles.
- With `menuBarIcon: "hidden"`, open the panel with the hotkey or by opening Soprano Mix
  again from Spotlight or Finder.

## Command line

The app binary doubles as a command line client for the running app:

```text
Usage: SopranoMix <command>

  list                              List the apps in the mixer: volume, mute, output, playing
  devices                           List the audio devices
  set <app> <0-400>                 Set an app's volume in percent (100 = unchanged)
  mute <app>                        Mute an app
  unmute <app>                      Unmute an app
  output <app> <device|default>     Play an app on an output (UID or name), or on the system output
  show                              Open the panel
  hide                              Close the panel
  scan [--all]                      Print every audio process and how it is grouped (no app needed)
  selftest [--gain <x>] [--seconds <n>] [--silent]
                                    Route a test tone through the live pipeline and report JSON
  snapshot --out <png> [options]    Render the panel offscreen on fixtures (development)
  help                              Show this help

<app> is a name (case-insensitive; a unique prefix is enough) or a settings key such as
com.spotify.client or "wine:TEKKEN 8". Names with spaces work quoted or unquoted
(set TEKKEN 8 35). Quote device names with spaces: output Discord "AirPods Pro".
```

```bash
MIX="/Applications/Soprano Mix.app/Contents/MacOS/SopranoMix"
"$MIX" list
"$MIX" set spotify 60                 # a unique prefix of the name is enough
"$MIX" set TEKKEN 8 35                # names with spaces work unquoted …
"$MIX" mute "TEKKEN 8"                # … and quoted
"$MIX" output Discord "AirPods Pro"   # quote device names with spaces
"$MIX" output Discord default
```

- `<app>` matches the settings key exactly, then the name (case- and accent-insensitive),
  then a name prefix, then a substring. A query that matches several apps is an error
  listing them. A key-like query (`com.example.app`, `wine:…`, `exe:…`) without a running
  match sets that key anyway, so you can set a game's volume before starting it.
- `set` accepts `35` or `35%`.
- Output is JSON (pretty-printed, sorted keys) with exit status 0: `"ok" : true`, plus
  `apps` for `list` (`key`, `name`, `kind`, `volume`, `muted`, `output`, `outputName`,
  `playing`, `routed`, `pids`), `devices` for `devices` (`uid`, `name`, `transport`,
  `output`, `input`, `defaultOutput`, `defaultInput`, `soundEffects`, `volume`,
  `softwareVolume`, `muted`, `sampleRate`), and `app` for `set`, `mute`, `unmute` and
  `output`.
- `help` / `--help` print the usage (exit 0). Malformed arguments print the usage on
  stderr (exit 2). Errors print on stderr with exit 1: "Soprano Mix is not running.",
  "Soprano Mix did not answer.", "No app matches 'winamp'.", "'s' matches Safari,
  Spotify.".

### scan

`SopranoMix scan [--all]` needs neither the running app nor any permission. It prints
every app connected to Core Audio as Soprano Mix groups it: key, name, kind, playing,
pids, and per process the bundle id, executable path, `argv[0]` and responsible app.
Without `--all` it prints the apps that play now; `--all` adds the apps that are connected
to Core Audio but silent at the moment. It
answers "why is my app not listed" and "what is my game's key".

### selftest

`SopranoMix selftest [--gain <x>] [--seconds <n>] [--silent]` checks the live pipeline:
it plays a 440 Hz tone with `afplay`, routes it through a real process tap at the gain
(default 0.5; `--silent` uses 0) on the default output, and prints JSON with the capture
status, the measured input and output peaks, the expected output peak, the added latency
in ms, and pass or fail. It plays sound unless `--silent` and triggers the System Audio
Recording prompt for the app that runs it (your terminal, when run from one).

## Menu bar

Left click opens or closes the panel. Right click (or control-click) shows the menu: Open
settings.json… (`⌘,`), "settings.json: N warnings" while the file has problems,
Permissions…, Launch at Login, About Soprano Mix, and Quit Soprano Mix (`⌘Q`). The icon
is three faders; `app.menuBarIcon` picks `outlined`, `filled` or `hidden`.

## Permissions

The permissions window (first launch, and Permissions… in the menu) shows each permission
with a mark (a green dot when granted, a yellow dot while not asked yet, a red diamond when
denied, a grey ring when unknown or optional and missing) and its button. It updates as
soon as you grant one.

- **System audio recording** (`kTCCServiceAudioCapture`) is required to change an app's
  volume, mute or output. "Allow" shows macOS's prompt; once denied, "Open System
  Settings" opens Privacy & Security → Screen & System Audio Recording, where Soprano Mix
  is listed under "System Audio Recording Only".
- **Accessibility** is optional: only the volume keys for outputs without hardware volume
  use it.

Soprano Mix is signed with the Soprano family's shared "Soprano Local Development"
identity, so both grants survive reinstalling and rebuilding.

## How it works

- Core Audio lists every process that uses audio, with its pid, bundle id and whether it
  is playing. Reading that needs no permission; that is how the list and `scan` work.
- An app with a setting gets a **route**: a private process tap on the app's processes
  that mutes its own output while Soprano Mix reads it, a private aggregate device on the
  target output, and an IO callback that plays the tapped audio there at the app's gain
  (with the limiter above 100 %).
- **Only apps with a setting are tapped.** An app at 100 %, unmuted, on the system output
  has no route: its audio is untouched, with no added latency. A route exists only while
  the app has a setting and is connected to Core Audio.
- Software volume for outputs without hardware volume is one more route: a tap of
  everything playing on that output (except apps with their own route and Soprano Mix
  itself), replayed at the software volume.
- Meters use the same kind of tap without muting the app, only while the panel is open.
- No route is created without System Audio Recording, because a tap read without it
  delivers silence.
- Taps and aggregate devices belong to the Soprano Mix process. **Quitting (or a crash)
  restores every app's audio at once**: Core Audio removes them with the process.

## Troubleshooting

- **An app is not listed.** It is listed once it plays. Run `SopranoMix scan --all` while
  it plays: if it is not there, it does not play through Core Audio; if it is listed under
  another name (its parent app, or its game folder), use that row or key.
- **The sliders do nothing.** The banner in the panel says System Audio Recording is
  missing: click Allow, or Open Settings and turn Soprano Mix on under System Audio
  Recording Only.
- **An app row shows a red diamond.** Its route failed; hover the name for the reason
  (often the output device disappeared). Pick another output, or quit and reopen Soprano
  Mix to rebuild every route.
- **Volume keys do nothing on the TV or monitor.** Grant Accessibility and System Audio
  Recording in the permissions window, and check `volumeKeys.anyOutput`. Keys pass to macOS on outputs with hardware
  volume. While a password field has focus, macOS Secure Input blocks every keyboard tap.
- **A routed app crackles or stutters.** Raise `audio.bufferFrames` (512 or 1024).
- **A routed app lags behind the picture.** Lower `audio.bufferFrames`; Bluetooth outputs
  add their own latency on top.
- **An app stays silent after Soprano Mix quit.** Core Audio removes the taps with the
  process; if an app still plays nothing, quit and reopen that app.
- **The CLI says "Soprano Mix is not running."** Start the app; the dev build
  (`com.soprano.mix.dev`) and the installed app have separate CLI ports, so use the binary
  of the app you started.
- **Soprano Mix quits right after it starts.** Another Soprano Mix runs (the installed
  app or the dev build); quit that one first.

## Development

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools PATH="/opt/homebrew/opt/swift/bin:$PATH"
swift build
swift test
./scripts/dev.sh                      # build, package and launch Soprano Mix Dev.app
.build/debug/SopranoMix snapshot --out /tmp/mix.png
.build/debug/SopranoMix snapshot --out /tmp/mix.png --scenario game --theme folio-ink --levels
.build/debug/SopranoMix snapshot --out /tmp/mix.png --actions "volume:spotify=250 output:discord=default"
.build/debug/SopranoMix snapshot --out /tmp/hud.png --scenario game --actions "keyUp keyUp" --hud
.build/debug/SopranoMix snapshot --out /tmp/perm.png --onboarding --permissions capture=notDetermined,accessibility=missing
./scripts/render-app-icon.sh          # re-render Sources/SopranoMix/Resources/AppIcon.icns
```

`DEVELOPER_DIR` pins the Command Line Tools SDK, because Homebrew Swift can't read Xcode's
newer one. `snapshot` runs the real mixer and panel on fake processes and devices
offscreen, without permissions or audio (`--scenario standard|game|crowded|quiet`,
`--settings <jsonc>`, `--capture granted|notDetermined|denied`, `--report <json>`).

`scripts/dev.sh` quits a running Soprano Mix Dev and waits for it to exit, packages the new
build and opens it. Since only one Soprano Mix runs at a time, it stops with a hint
instead of launching while the installed app runs: quit that first. The dev app
(`com.soprano.mix.dev`) shares settings.json with the installed app, has its own
permissions, never registers as a login item, and its command line only reaches the dev
app. Signing uses `SOPRANO_MIX_CODESIGN_IDENTITY` / `SOPRANO_MIX_CODESIGN_KEYCHAIN`
when set, else the shared local identity. The design system
(`Sources/SopranoMix/Vendored/`) comes from Soprano; update it with
`scripts/sync-soprano-chrome.sh` instead of editing it here. `docs/ARCHITECTURE.md`
describes the modules, and `docs/ROADMAP.md` lists what is not copied from SoundSource.

## License

[MIT](LICENSE).
