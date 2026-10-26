# Status

## Goal

Soprano Mix: a copy of SoundSource (Rogue Amoeba's per-app audio control) in the Soprano
family, Folio chrome. A menu-bar app whose panel controls every app's audio on its own
and the system's audio devices, built on Core Audio process taps (no audio driver, no
kernel extension). `docs/ROADMAP.md` lists what is deliberately not copied.

### Scope (phase 1)

- **Apps list.** Every process currently playing audio (Core Audio process objects with
  running output), grouped by app (helper processes like browser renderers fold into
  their app), with icon and name. Apps that stop playing stay listed while they have a
  non-default setting.
- **Per-app volume.** Slider from 0 to 400 %; above 100 % is boost with a limiter so it
  doesn't clip. Mute toggle. The setting applies as soon as the app plays again and is
  remembered per bundle id across launches.
- **Per-app output device.** Send one app's audio to a different output than the system
  default (e.g. music to the speakers, calls to the headphones); falls back to the
  default when that device disappears.
- **System devices.** Output, input and sound-effects device: pick the device, volume,
  mute, balance, input level, sample rate.
- **Menu bar.** Icon opens the panel; optional global hotkey for the panel; level meters
  per app.
- **Volume keys for any output.** The keyboard volume keys also work for outputs without
  hardware volume (HDMI, DisplayPort), like SoundSource's Super Volume Keys.
- **Family baseline.** `~/.config/soprano-mix/settings.json` with live reload, launch at
  login, permissions window, command line (`list`, `set <app> <volume>`, `mute <app>`),
  offscreen `snapshot` harness, Soprano theme following.

### How per-app volume works (to be verified in a spike first)

1. List processes: `kAudioHardwarePropertyProcessObjectList`, then per process
   `kAudioProcessPropertyBundleID`, `…PID`, `…IsRunningOutput`.
2. For each controlled app, a `CATapDescription` on its process objects with
   `muteBehavior = .mutedWhenTapped` (`AudioHardwareCreateProcessTap`, macOS 14.2+) so
   the original output goes silent.
3. A private aggregate device containing the target output device and the tap; its
   IOProc copies the tapped audio to the output with the app's gain (and limiter).
4. Permission: the first tap triggers macOS's "System Audio Recording" prompt
   (`NSAudioCaptureUsageDescription` in Info.plist); there is no API to ask up front.

Open-source references for the mechanism: [AudioCap](https://github.com/insidegui/AudioCap)
(Apple's process tap API, minimal sample),
[Levels](https://github.com/jasonbacong/Levels) (per-app mixer on process taps).
Read for the API only; don't copy code.

## Done

- Project directory, goal and scope (this file, `README.md`, `docs/ROADMAP.md`,
  `AGENTS.md`).

## Next

1. Spike: one app (e.g. Music) tapped, muted and replayed at 50 % and 200 % on the
   default output; measure the added latency and check AirPods and HDMI outputs.
2. Write `docs/ARCHITECTURE.md` as the contract (modules, contract files, settings
   schema, harness), modelled on Soprano Tab's.
3. Scaffold from Soprano Tab: `Package.swift`, `Support/`, `scripts/` (sign, package,
   install, dev, sync-soprano-chrome), vendored chrome.
4. Build phase 1.

## Open decisions

- Minimum macOS: process taps need 14.2; the family baseline is 14.
- Per-app effects (10-band EQ, Audio Units): phase 1 or later (`docs/ROADMAP.md` says later).
- GitHub repo `frknue/soprano_mix`, public like the siblings: not created yet.
