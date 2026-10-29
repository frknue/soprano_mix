import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

@MainActor
struct SettingsCenterTests {
    /// A settings.json path inside a fresh temporary directory that does not exist yet.
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-mix-settings-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    private func removeDirectory(of url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("a missing settings file is created from the template and resolves to the defaults")
    func createsMissingFileFromTemplate() throws {
        let url = temporaryFileURL()
        defer { removeDirectory(of: url) }
        let center = SettingsCenter(fileURL: url)

        center.start(watching: false)

        #expect(try SettingsFile.read(at: url) == SettingsTemplate.text)
        #expect(center.settings == .defaults)
        #expect(center.issues.isEmpty)
    }

    @Test("the settings path honours SOPRANO_MIX_CONFIG first, then XDG_CONFIG_HOME, then ~/.config")
    func settingsPathPrecedence() {
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.config/soprano-mix/settings.json"
        #expect(SettingsFile.url(environment: [:]).path == defaultPath)
        #expect(SettingsFile.url(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"]).path == "/tmp/xdg/soprano-mix/settings.json")
        #expect(SettingsFile.url(environment: [
            "XDG_CONFIG_HOME": "/tmp/xdg",
            "SOPRANO_MIX_CONFIG": "/tmp/mix/custom.json",
        ]).path == "/tmp/mix/custom.json")
        #expect(SettingsFile.url(environment: ["SOPRANO_MIX_CONFIG": ""]).path == defaultPath)
    }

    @Test("an edited file applies on reload and notifies observers once per change")
    func reloadAppliesEdits() throws {
        let url = temporaryFileURL()
        defer { removeDirectory(of: url) }
        let center = SettingsCenter(fileURL: url)
        center.start(watching: false)
        let owner = NSObject()
        var notifications = 0
        center.addObserver(owner) { notifications += 1 }

        try SettingsFile.write(
            #"{ "apps": { "wine:TEKKEN 8": { "volume": 35 } }, "app": { "menuBarIcon": "filled" } }"#,
            to: url
        )
        center.reload()

        #expect(center.settings.audio(for: .wine("TEKKEN 8")).volume == 35)
        #expect(center.settings.app.menuBarIcon == .filled)
        #expect(notifications == 1)

        center.reload()
        #expect(notifications == 1)
        withExtendedLifetime(owner) {}
    }

    @Test("a document that does not parse keeps the last good settings and reports an error")
    func invalidDocumentKeepsLastGoodSettings() throws {
        let url = temporaryFileURL()
        defer { removeDirectory(of: url) }
        let center = SettingsCenter(fileURL: url)
        center.start(watching: false)
        try SettingsFile.write(#"{ "audio": { "bufferFrames": 512 } }"#, to: url)
        center.reload()

        try SettingsFile.write(#"{ "audio": { "bufferFrames": "#, to: url)
        center.reload()

        #expect(center.settings.audio.bufferFrames == 512)
        #expect(center.issues.contains { $0.severity == .error })

        try SettingsFile.write(#"{ "audio": { "bufferFrames": 1024 } }"#, to: url)
        center.reload()

        #expect(center.settings.audio.bufferFrames == 1024)
        #expect(!center.issues.contains { $0.severity == .error })
    }

    @Test("writing a value goes through the editor: comments stay and the value applies")
    func writePreservesComments() throws {
        let url = temporaryFileURL()
        defer { removeDirectory(of: url) }
        try SettingsFile.write(
            """
            // My mixer.
            {
              // Follow Soprano.
              "theme": "soprano",
              "apps": {
                // Too loud.
                "com.spotify.client": { "volume": 60 }
              }
            }

            """,
            to: url
        )
        let center = SettingsCenter(fileURL: url)
        center.start(watching: false)

        #expect(center.write(35, at: ["apps", "wine:TEKKEN 8", "volume"]))
        #expect(center.write(false, at: ["app", "startAtLogin"]))

        let text = try SettingsFile.read(at: url)
        #expect(text.contains("// My mixer."))
        #expect(text.contains("// Follow Soprano."))
        #expect(text.contains("// Too loud."))
        #expect(center.settings.audio(for: .wine("TEKKEN 8")).volume == 35)
        #expect(center.settings.audio(for: .bundle("com.spotify.client")).volume == 60)
        #expect(center.settings.app.startAtLogin == false)
        #expect(center.settings.theme == "soprano")
    }

    @Test("writing to a symlinked settings file edits the target and keeps the link")
    func writeFollowsSymlinks() throws {
        let url = temporaryFileURL()
        defer { removeDirectory(of: url) }
        let target = url.deletingLastPathComponent().appendingPathComponent("dotfiles.json")
        try SettingsFile.write("{}\n", to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let center = SettingsCenter(fileURL: url)
        center.start(watching: false)

        #expect(center.write(false, at: ["panel", "meters"]))

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
        #expect(try SettingsFile.read(at: target).contains("meters"))
        #expect(center.settings.panel.meters == false)
    }

    @Test("a write into a document that does not parse fails and leaves the file as it was")
    func writeIntoBrokenDocumentFails() throws {
        let url = temporaryFileURL()
        defer { removeDirectory(of: url) }
        let center = SettingsCenter(fileURL: url)
        center.start(watching: false)
        let broken = #"{ "audio": { "bufferFrames": "#
        try SettingsFile.write(broken, to: url)
        center.reload()

        #expect(!center.write(35, at: ["apps", "wine:TEKKEN 8", "volume"]))

        #expect(try SettingsFile.read(at: url) == broken)
        #expect(center.settings.audio(for: .wine("TEKKEN 8")).volume == 100)
    }

    @Test("a write into a file that is not UTF-8 fails and leaves its bytes alone")
    func writeIntoUnreadableFileFails() throws {
        let url = temporaryFileURL()
        defer { removeDirectory(of: url) }
        let center = SettingsCenter(fileURL: url)
        center.start(watching: false)
        // Latin-1 "Küche": not UTF-8.
        let bytes = Data(#"{ "outputs": { "K"#.utf8) + Data([0xFC]) + Data(#"che": { "volume": 40 } } }"#.utf8)
        try bytes.write(to: url)

        #expect(!center.write(35, at: ["apps", "wine:TEKKEN 8", "volume"]))

        #expect(try Data(contentsOf: url) == bytes)
    }
}
