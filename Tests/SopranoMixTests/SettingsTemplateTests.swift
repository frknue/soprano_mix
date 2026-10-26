import AppKit
import Testing
@testable import SopranoMixCore

struct SettingsTemplateTests {
    @Test("the template resolves to exactly the defaults with no issues")
    func resolvesToDefaults() {
        let resolution = SettingsResolver.resolve(text: SettingsTemplate.text, knownThemeIDs: [])
        #expect(resolution.issues.isEmpty)
        #expect(resolution.settings == .defaults)
    }

    @Test("the template documents every key and the allowed menu bar icons")
    func documentsEveryKey() {
        let text = SettingsTemplate.text
        let keys = ["theme", "apps", "outputs", "panel", "hotkey", "meters", "volumeKeys", "anyOutput", "hud",
                    "audio", "bufferFrames", "limiter", "app", "startAtLogin", "menuBarIcon", "volume", "muted", "output"]
        for key in keys {
            #expect(text.contains(key), "missing \(key)")
        }
        for icon in MenuBarIcon.allCases {
            #expect(text.contains("\"\(icon.rawValue)\""), "missing \(icon.rawValue)")
        }
        #expect(text.contains("32–4096"))
        #expect(text.contains("0–400"))
        #expect(text.contains("exe:"))
        #expect(text.contains("SopranoMix scan"))
    }

    @Test("the app examples sit in comments only")
    func examplesAreComments() {
        for example in ["com.spotify.client", "wine:TEKKEN 8"] {
            let lines = SettingsTemplate.text.split(separator: "\n").filter { $0.contains(example) }
            #expect(!lines.isEmpty, "missing \(example)")
            #expect(lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
        }
    }

    @Test("editing the template keeps its comments and adds a Wine app")
    func editableTemplate() throws {
        let edited = try SettingsEditor.setting(35, at: ["apps", "wine:TEKKEN 8", "volume"], in: SettingsTemplate.text)
        #expect(edited.contains("// Soprano Mix settings."))
        let resolution = SettingsResolver.resolve(text: edited, knownThemeIDs: [])
        #expect(resolution.issues.isEmpty)
        #expect(resolution.settings?.apps.count == 1)
        #expect(resolution.settings?.apps[.wine("TEKKEN 8")] == AppAudioSettings(volume: 35))
    }
}
