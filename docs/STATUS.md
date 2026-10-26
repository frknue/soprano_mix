# Status

## Goal

Soprano Mix: a copy of SoundSource (Rogue Amoeba's per-app audio control) in the Soprano
family, Folio chrome. A menu-bar app whose panel controls every app's audio on its own
and the system's audio devices, built on Core Audio process taps (no audio driver, no
kernel extension). `docs/ROADMAP.md` lists what is deliberately not copied;
`docs/ARCHITECTURE.md` is the contract.

Two wishes from Furkan drive the details: every app that outputs sound is listed
(helpers, WebKit, unbundled programs, system processes), and CrossOver/Wine games are
their own apps, so a game like TEKKEN 8 can be turned down without its in-game settings.

## Done

Phase 1 is built (`swift build`, `swift test`: all green):

- **Apps list**: `AudioAppResolver` groups every Core Audio process object: Wine programs
  by their Windows path (`wine:TEKKEN 8`, `wine:Steam`; never folded into CrossOver),
  helpers/renderers/WebKit GPU through the responsible app, unbundled programs by
  executable (`exe:afplay`), system processes with friendly names (System Sounds, Siri).
  Apps stay listed after they stop playing until they disconnect.
- **Per-app volume** 0–400 % (loudness law: 50 % = −10 dB, 200 % = +10 dB), limiter above
  100 %, mute, per-app output device with fallback; remembered in `settings.json` under
  the app key.
- **Routes only where needed**: apps at default settings are never tapped (no latency,
  no permission). Taps are private and die with the process.
- **System devices**: output, input, sound effects: device, volume, mute, balance, input
  level, sample rate, alert volume.
- **Software volume + volume keys** for outputs without hardware volume (HDMI,
  DisplayPort: the Odyssey G91F here), with a Folio HUD.
- **Meters** while the panel is open; global panel hotkey (Carbon); CLI (`list`,
  `devices`, `set`, `mute`, `unmute`, `output`, `show`, `hide`); `scan` (read-only
  diagnosis) and `selftest` (live pipeline check); `snapshot` harness; settings.json with
  live reload; Soprano theme following; permissions window; app icon (`mix` glyph).
- **Wine icons**: extracted from the game's .exe (PE resources), found through the
  process's prefix or CrossOver's `BottleDir` preference (bottles may live on another
  volume, here `/Volumes/Extreme/VMs/Bottles`).

Verified live on this Mac (macOS 27): `SopranoMix scan` lists TEKKEN 8 (CrossOver,
playing) as `wine:TEKKEN 8` next to Google Chrome with its helpers folded in; the real
TEKKEN 8 icon is extracted from the 168 MB game executable in 14 ms. Panel, HUD and
permissions window checked in Paper and Ink through the snapshot harness.

Not yet run against real audio: no tap has been created on this Mac. The System Audio
Recording permission is still undetermined.

## Next

1. `SopranoMix selftest --silent`, then `selftest` (plays a quiet tone): first real taps;
   macOS asks the terminal for System Audio Recording. Check pass/fail and the reported
   latency.
2. `./scripts/install.sh`, launch, allow System Audio Recording; with TEKKEN 8 running,
   set it to 35 % and listen; try the volume keys on the Odyssey G91F.
3. Measure the added latency in the game (route buffer `audio.bufferFrames`, default 256).

## Open decisions

- Per-app effects (10-band EQ, Audio Units): later (`docs/ROADMAP.md`).
- GitHub repo `frknue/soprano_mix`, public like the siblings: not created yet.

## Decided

- Minimum macOS 14.2 (process taps), not the family's 14.
- Volume law: loudness-proportional percent (gain = (p/100)^(log2(10)/2)).
- Only apps with a non-default setting are tapped; meters tap read-only, only while the
  panel is open.
