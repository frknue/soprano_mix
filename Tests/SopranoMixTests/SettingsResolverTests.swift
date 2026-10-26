import AppKit
import Testing
@testable import SopranoMixCore

struct SettingsResolverTests {
    private func resolve(_ text: String, themes: Set<String> = ["nord", "folio-ink"]) -> SettingsResolution {
        SettingsResolver.resolve(text: text, knownThemeIDs: themes)
    }

    private func warns(_ resolution: SettingsResolution, _ fragment: String) -> Bool {
        resolution.issues.contains { $0.severity == .warning && $0.message.contains(fragment) }
    }

    @Test("an empty object resolves to the defaults without issues")
    func emptyObject() {
        let resolution = resolve("{}")
        #expect(resolution.settings == .defaults)
        #expect(resolution.issues.isEmpty)
    }

    @Test("comments, trailing commas and every section apply over the defaults")
    func fullDocument() {
        let resolution = resolve("""
        // header
        {
          "theme": "nord",
          "apps": {
            "com.spotify.client": { "volume": 60 },
            "wine:TEKKEN 8": { "volume": 35, "muted": true, "output": "Odyssey G91F" },
            "exe:afplay": { "output": "DEFAULT" },
          },
          "outputs": { "Odyssey G91F": { "volume": 50, "muted": false } },
          "panel": { "hotkey": "control+option+m", "meters": false },
          "volumeKeys": { "anyOutput": false, "hud": false },
          "audio": { "bufferFrames": 512, "limiter": false },
          "app": { "startAtLogin": false, "menuBarIcon": "filled" }, /* trailing */
        }
        """)
        #expect(resolution.issues.isEmpty)
        let settings = resolution.settings ?? SopranoMixSettings()
        #expect(settings.theme == "nord")
        #expect(settings.apps[.bundle("com.spotify.client")] == AppAudioSettings(volume: 60))
        #expect(settings.apps[.wine("TEKKEN 8")] == AppAudioSettings(volume: 35, muted: true, output: "Odyssey G91F"))
        #expect(settings.apps[.executable("afplay")] == AppAudioSettings())
        #expect(settings.outputs["Odyssey G91F"] == OutputVolumeSettings(volume: 50))
        #expect(settings.panel == PanelSettings(hotkey: PanelHotkey(modifiers: [.control, .option], key: .character("m")), meters: false))
        #expect(settings.volumeKeys == VolumeKeySettings(anyOutput: false, hud: false))
        #expect(settings.audio == AudioEngineSettings(bufferFrames: 512, limiter: false))
        #expect(settings.app == AppBehaviorSettings(startAtLogin: false, menuBarIcon: .filled))
    }

    @Test("a document that is not an object is an error with its line and no settings")
    func notAnObject() {
        let array = resolve("// comment\n\n[1, 2]")
        #expect(array.settings == nil)
        #expect(array.issues == [ConfigIssue(severity: .error, message: "settings.json must be a JSON object", line: 3)])

        let broken = resolve("{\n  \"theme\": \n}")
        #expect(broken.settings == nil)
        #expect(broken.issues.count == 1)
        #expect(broken.issues.first?.severity == .error)
        #expect(broken.issues.first?.line != nil)
    }

    @Test("volumes are clamped to their ranges with a warning")
    func clampsVolumes() {
        let resolution = resolve("""
        {
          "apps": { "a.b": { "volume": 900 }, "c.d": { "volume": -5 }, "e.f": { "volume": 62.5 } },
          "outputs": { "HDMI": { "volume": 140 } }
        }
        """)
        let settings = resolution.settings ?? SopranoMixSettings()
        #expect(settings.apps[AppKey(rawValue: "a.b")]?.volume == 400)
        #expect(settings.apps[AppKey(rawValue: "c.d")]?.volume == 0)
        #expect(settings.apps[AppKey(rawValue: "e.f")]?.volume == 62.5)
        #expect(settings.outputs["HDMI"]?.volume == 100)
        #expect(warns(resolution, "apps.a.b.volume"))
        #expect(warns(resolution, "apps.c.d.volume"))
        #expect(warns(resolution, "outputs.HDMI.volume"))
        #expect(resolution.issues.count == 3)
    }

    @Test("buffer frames take whole numbers only and clamp to 32 to 4096")
    func bufferFrames() {
        let low = resolve(#"{ "audio": { "bufferFrames": 8 } }"#)
        #expect(low.settings?.audio.bufferFrames == 32)
        #expect(warns(low, "audio.bufferFrames"))

        let high = resolve(#"{ "audio": { "bufferFrames": 100000 } }"#)
        #expect(high.settings?.audio.bufferFrames == 4096)

        let fraction = resolve(#"{ "audio": { "bufferFrames": 256.5 } }"#)
        #expect(fraction.settings?.audio.bufferFrames == 256)
        #expect(warns(fraction, "audio.bufferFrames"))

        let whole = resolve(#"{ "audio": { "bufferFrames": 1024.0 } }"#)
        #expect(whole.settings?.audio.bufferFrames == 1024)
        #expect(whole.issues.isEmpty)
    }

    @Test("bad values warn and keep their defaults")
    func badValuesKeepDefaults() {
        let resolution = resolve("""
        {
          "theme": "mission-control",
          "apps": { "wine:TEKKEN 8": { "volume": "loud", "muted": 1, "output": "" } },
          "panel": { "hotkey": "shift+m", "meters": "yes" },
          "volumeKeys": { "anyOutput": 0 },
          "audio": { "limiter": null },
          "app": { "menuBarIcon": "sparkly" }
        }
        """)
        let settings = resolution.settings ?? SopranoMixSettings()
        #expect(settings.theme == "soprano")
        #expect(settings.apps[.wine("TEKKEN 8")] == AppAudioSettings())
        #expect(settings.panel == PanelSettings())
        #expect(settings.volumeKeys == VolumeKeySettings())
        #expect(settings.audio == AudioEngineSettings())
        #expect(settings.app.menuBarIcon == .outlined)
        for path in ["theme", "apps.wine:TEKKEN 8.volume", "apps.wine:TEKKEN 8.muted", "apps.wine:TEKKEN 8.output",
                     "panel.hotkey", "panel.meters", "volumeKeys.anyOutput", "audio.limiter", "app.menuBarIcon"] {
            #expect(warns(resolution, path + ":"), "no warning for \(path)")
        }
        #expect(resolution.issues.allSatisfy { $0.severity == .warning })
    }

    @Test("the default output spelling and null both follow the system output")
    func defaultOutput() {
        let settings = resolve("""
        { "apps": { "a.one": { "output": "default", "volume": 50 }, "a.two": { "output": null, "volume": 50 },
                    "a.three": { "output": "Default", "volume": 50 } } }
        """).settings
        #expect(settings?.apps[AppKey(rawValue: "a.one")]?.output == nil)
        #expect(settings?.apps[AppKey(rawValue: "a.two")]?.output == nil)
        #expect(settings?.apps[AppKey(rawValue: "a.three")]?.output == nil)
    }

    @Test("unknown keys warn with their dotted path, app keys stay whole")
    func unknownKeys() {
        let resolution = resolve("""
        {
          "colour": "red",
          "apps": { "wine:TEKKEN 8": { "volume": 35, "pan": 0.5 } },
          "audio": { "sampleRate": 48000 }
        }
        """)
        #expect(warns(resolution, "\"colour\""))
        #expect(warns(resolution, "\"apps.wine:TEKKEN 8.pan\""))
        #expect(warns(resolution, "\"audio.sampleRate\""))
        #expect(resolution.settings?.apps[.wine("TEKKEN 8")]?.volume == 35)
        #expect(resolution.issues.count == 3)
    }

    @Test("empty app and output keys and non-object entries are dropped with a warning")
    func droppedEntries() {
        let resolution = resolve(#"{ "apps": { "": { "volume": 10 }, "com.x": 50 }, "outputs": { " ": {} }, "panel": [] }"#)
        #expect(resolution.settings?.apps.isEmpty == true)
        #expect(resolution.settings?.outputs.isEmpty == true)
        #expect(resolution.settings?.panel == PanelSettings())
        #expect(resolution.issues.count == 4)
    }

    @Test("theme accepts soprano, folio and known theme ids")
    func themes() {
        #expect(resolve(#"{ "theme": "folio" }"#, themes: []).settings?.theme == "folio")
        #expect(resolve(#"{ "theme": "soprano" }"#, themes: []).settings?.theme == "soprano")
        #expect(resolve(#"{ "theme": "folio-ink" }"#).settings?.theme == "folio-ink")
        let unknown = resolve(#"{ "theme": "folio-ink" }"#, themes: [])
        #expect(unknown.settings?.theme == "soprano")
        #expect(unknown.issues.count == 1)
    }

    @Test("a hotkey of null means none, without a warning")
    func nullHotkey() {
        let resolution = resolve(#"{ "panel": { "hotkey": null } }"#)
        #expect(resolution.settings?.panel.hotkey == nil)
        #expect(resolution.issues.isEmpty)
    }
}
