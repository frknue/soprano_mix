# Soprano Mix

Per-app audio mixer for macOS in the Soprano family: a copy of SoundSource (per-app
volume, mute, boost and output device; system output, input and sound-effects devices)
in Soprano's Folio chrome (Paper light, Ink dark). Swift 6 + programmatic AppKit (no
storyboards/xibs/SwiftUI), SPM, macOS 14.2+, menu-bar app (no Dock icon), hand-packaged
`.app` via `scripts/install.sh`. Built on Core Audio process taps, no audio driver.
GitHub: [`frknue/soprano_mix`](https://github.com/frknue/soprano_mix) (public).

**State: phase 1 built, not yet run against real audio** (no tap created on this Mac).
Goal, scope and next steps: `docs/STATUS.md`. Left out: `docs/ROADMAP.md`. Keep both
current.

## Template

Soprano Tab (`~/git/private/soprano-tab`) is the closest sibling and the template for
layout, scripts and conventions; Soprano Cast (`~/git/private/soprano-cast`) the second
reference. Mirror their structure instead of inventing a new one:

- `Sources/SopranoMixCore/` pure logic, Foundation + CoreGraphics only, no AppKit,
  everything `public`; `Sources/SopranoMix/System/` the only place that touches Core
  Audio, taps, event taps and private symbols, behind protocols in
  `System/SystemContracts.swift`; `App/`, `Shell/`, `Fixtures/` (fake processes and
  devices, `snapshot` harness).
- `docs/ARCHITECTURE.md` is the contract, written before the code.
- Chrome and `JSONCText` vendored from Soprano (`~/git/private/soprano`) by
  `scripts/sync-soprano-chrome.sh`; never edit vendored files here.
- Bundle id `com.soprano.mix` (dev `com.soprano.mix.dev`), settings
  `~/.config/soprano-mix/settings.json` (`SOPRANO_MIX_CONFIG` overrides), CLI over
  CFMessagePort `<bundle id>.cli`, signed with the shared "Soprano Local Development"
  identity so the System Audio Recording and Accessibility grants survive rebuilds.

## Commands

Homebrew Swift with the Command Line Tools SDK; pin `DEVELOPER_DIR` on every direct
Swift command:

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools PATH="/opt/homebrew/opt/swift/bin:$PATH"
swift build
swift test
swift test --filter RoutePlannerTests
.build/debug/SopranoMix scan [--all]     # live processes as the mixer groups them; read-only, no permission
.build/debug/SopranoMix snapshot --out /tmp/mix.png --levels --report /tmp/mix.json
.build/debug/SopranoMix snapshot --out /tmp/mix-ink.png --scenario game --theme folio-ink
.build/debug/SopranoMix snapshot --out /tmp/hud.png --scenario game --actions "keyDown" --hud
.build/debug/SopranoMix snapshot --out /tmp/perm.png --onboarding --permissions capture=notDetermined,accessibility=missing
./scripts/dev.sh --build-only             # package .build/debug/Soprano Mix Dev.app (com.soprano.mix.dev)
./scripts/install.sh                      # release build → /Applications/Soprano Mix.app
```

`ld: warning: building for macOS-14.2 …` link warnings are expected. `selftest` creates
real taps and plays a tone: run it only on Furkan's go (it triggers the System Audio
Recording prompt for the terminal).

## Verification

- Source changes: `swift build` and `swift test`. Tests (swift-testing) never touch real
  audio devices, taps, the user's settings or defaults.
- UI: only through the offscreen `snapshot` harness on fixtures; read the PNG, check
  Folio Paper and Ink.
- Never launch the GUI, `./scripts/dev.sh` without `--build-only`, or `selftest` unless
  Furkan asks: the app mutes and re-routes real apps' audio and triggers the System
  Audio Recording prompt. Only one Soprano Mix (installed or dev) runs at a time.
- CrossOver/Wine grouping and "is every app listed" questions: check `scan --all`
  against `ps -axww -o pid,command` (Wine puts the Windows path in argv[0]).

## Commits and changelog

- Push, open PRs or create tags only when Furkan asks.
- Short imperative subjects with `feat:` / `fix:` / `docs:` / `test:` / `chore:`.
- `CHANGELOG.md` (Keep a Changelog, `## [Unreleased]`) starts with the first
  user-visible feature.
