import AppKit
import Testing
@testable import SopranoMixCore

struct SettingsEditorTests {
    private let document = """
    // my settings
    {
      "theme": "nord", // favorite
      "audio": {
        /* keep me */
        "bufferFrames": 512
      }
    }
    """

    @Test("a Wine app key is created under a missing apps object and round-trips")
    func wineKeyRoundTrip() throws {
        var edited = try SettingsEditor.setting(35, at: ["apps", "wine:TEKKEN 8", "volume"], in: document)
        edited = try SettingsEditor.setting(true, at: ["apps", "wine:TEKKEN 8", "muted"], in: edited)
        edited = try SettingsEditor.setting("default", at: ["apps", "wine:TEKKEN 8", "output"], in: edited)
        edited = try SettingsEditor.setting(60, at: ["apps", "com.spotify.client", "volume"], in: edited)

        #expect(edited.contains("// my settings"))
        #expect(edited.contains("// favorite"))
        #expect(edited.contains("/* keep me */"))
        let resolution = SettingsResolver.resolve(text: edited, knownThemeIDs: ["nord"])
        #expect(resolution.issues.isEmpty)
        let settings = resolution.settings ?? SopranoMixSettings()
        #expect(settings.theme == "nord")
        #expect(settings.audio.bufferFrames == 512)
        #expect(settings.apps == [
            .wine("TEKKEN 8"): AppAudioSettings(volume: 35, muted: true, output: nil),
            .bundle("com.spotify.client"): AppAudioSettings(volume: 60),
        ])
    }

    @Test("replacing a value changes only that value")
    func replacesValue() throws {
        let first = try SettingsEditor.setting(40, at: ["apps", "wine:TEKKEN 8", "volume"], in: document)
        let second = try SettingsEditor.setting(80, at: ["apps", "wine:TEKKEN 8", "volume"], in: first)
        let settings = SettingsResolver.resolve(text: second, knownThemeIDs: ["nord"]).settings
        #expect(settings?.apps[.wine("TEKKEN 8")]?.volume == 80)
        #expect(second.components(separatedBy: "wine:TEKKEN 8").count == 2)
    }

    @Test("an output volume keyed by a device name with spaces is written whole")
    func outputKeyWithSpaces() throws {
        let edited = try SettingsEditor.setting(50, at: ["outputs", "Odyssey G91F", "volume"], in: "{}")
        let settings = SettingsResolver.resolve(text: edited, knownThemeIDs: []).settings
        #expect(settings?.outputs == ["Odyssey G91F": OutputVolumeSettings(volume: 50)])
    }

    @Test("an unreadable document throws an edit error with its line")
    func parseErrorThrows() {
        do {
            _ = try SettingsEditor.setting(true, at: ["panel", "meters"], in: "{\n\n  \"a\": nope\n}")
            Issue.record("expected an error")
        } catch let error as SettingsEditError {
            #expect(error.line == 3)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
