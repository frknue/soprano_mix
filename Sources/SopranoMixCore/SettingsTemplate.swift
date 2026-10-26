import Foundation

/// The commented settings.json written on first launch: the schema is the documentation.
/// Every value is the default, so the template resolves to `SopranoMixSettings.defaults`;
/// allowed values are generated from the types so they never drift.
public enum SettingsTemplate {
    /// The commented settings.json written on first launch. Resolves to `.defaults` with
    /// no issues; documents every key with its default and allowed values.
    public static let text: String = """
    // Soprano Mix settings. JSON with comments; saved changes apply immediately.
    // Every key is optional. Unknown keys and bad values are ignored with a warning.
    {
      // "soprano" follows Soprano's theme and appearance (~/.config/soprano/settings.json);
      // "folio" follows macOS (Folio Paper in light mode, Folio Ink in dark mode);
      // or a Soprano theme id: "folio-paper", "folio-ink", "gruvbox-dark", "nord" …
      "theme": "soprano",

      // Per-app audio, written by the panel and by `SopranoMix set|mute|unmute|output`.
      // Apps without an entry play untouched. The key names the app:
      //   - its bundle id: "com.spotify.client"
      //   - "wine:<Name>" for CrossOver / Wine games and programs: "wine:TEKKEN 8"
      //     (the game folder, e.g. …\\steamapps\\common\\TEKKEN 8\\…, or the .exe name)
      //   - "exe:<name>" for programs without an app bundle: "exe:afplay", "exe:mpv"
      // `SopranoMix scan` and `SopranoMix list` print the key of every app.
      // Each entry:
      //   volume: \(range(VolumeLaw.appRange)) percent, default 100 (100 = unchanged,
      //           above 100 boosts, limited so it never clips)
      //   muted:  true | false, default false
      //   output: a device UID or name, or "default" (follow the system output), default "default"
      // Examples:
      //   "com.spotify.client": { "volume": 60 },
      //   "wine:TEKKEN 8": { "volume": 35, "muted": false, "output": "default" }
      "apps": {},

      // Software volume of outputs without hardware volume (HDMI, DisplayPort, some USB
      // DACs), written by the panel and the volume keys. Key: the device UID or name.
      //   volume: \(range(VolumeLaw.outputRange)) percent, default 100
      //   muted:  true | false, default false
      // Example:
      //   "Odyssey G91F": { "volume": 50, "muted": false }
      "outputs": {},

      "panel": {
        // Global shortcut that opens the panel: modifiers joined with "+" (at least one of
        // "control" (ctrl, ⌃), "option" (alt, opt, ⌥), "command" (cmd, ⌘); "shift" and "fn"
        // may be added) and a key: one character ("m"), "space", "return", "tab",
        // "escape", arrows ("left" …), "f1"…"f12". Example: "control+option+m". null: none.
        "hotkey": null,
        // Level meters for playing apps while the panel is open.
        "meters": true
      },

      "volumeKeys": {
        // The volume keys change the software volume of outputs without hardware volume
        // (needs Accessibility). false leaves the keys to macOS.
        "anyOutput": true,
        // Show Soprano Mix's volume HUD for those changes.
        "hud": true
      },

      "audio": {
        // IO buffer of every app route, in frames (\(AudioEngineSettings.bufferFramesRange.lowerBound)–\(AudioEngineSettings.bufferFramesRange.upperBound)).
        // Smaller adds less latency (256 at 48 kHz ≈ 5 ms) and costs more CPU.
        "bufferFrames": 256,
        // Limit apps above 100 % so they never clip.
        "limiter": true
      },

      "app": {
        // Start Soprano Mix when you log in.
        "startAtLogin": true,
        // \(values(MenuBarIcon.self)) ("hidden": the hotkey or opening the app shows the panel)
        "menuBarIcon": "outlined"
      }
    }

    """

    /// `"a" | "b" | "c"` for an enum's settings.json spellings.
    private static func values<Value: RawRepresentable & CaseIterable>(_: Value.Type) -> String where Value.RawValue == String {
        Value.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " | ")
    }

    /// "0–400".
    private static func range(_ range: ClosedRange<Double>) -> String {
        "\(Int(range.lowerBound))–\(Int(range.upperBound))"
    }
}
