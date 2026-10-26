# Soprano Mix

**A per-app audio mixer for macOS, in the Soprano family.**

Soprano Mix will be a copy of [SoundSource](https://rogueamoeba.com/soundsource/) in
Soprano's Folio chrome (Paper in light mode, Ink in dark mode): a menu-bar panel that
lists every app playing audio, each with its own volume slider, mute, boost above 100 %
and output device, above the controls for the system's output, input and sound-effects
devices. It lives in the menu bar and has no Dock icon. Behavior follows SoundSource's
documented behavior; no SoundSource code is used.

Nothing is built yet. Goal and scope: `docs/STATUS.md`; what is deliberately left out:
`docs/ROADMAP.md`.

## Why

macOS has no per-app volume control: the system slider sets the output device only.
Since macOS 14.2, Core Audio process taps let an app capture another process's audio,
mute its original output and play it again at its own gain on any device, so a mixer
needs no virtual audio driver.

## License

[MIT](LICENSE).
