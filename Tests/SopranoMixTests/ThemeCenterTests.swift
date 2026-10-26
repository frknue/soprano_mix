import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

@MainActor
struct ThemeCenterTests {
    /// The macOS appearance the center sees; tests flip it.
    @MainActor
    private final class SystemBox {
        var appearance: AppTheme.Appearance
        /// What the center last set `NSApp.appearance` to (`.some(nil)` = follow macOS).
        var applicationAppearance: NSAppearance.Name??

        init(_ appearance: AppTheme.Appearance) {
            self.appearance = appearance
        }
    }

    private struct Fixture {
        let directory: URL
        let mixURL: URL
        let sopranoURL: URL
        let settings: SettingsCenter
        let system: SystemBox
        let center: ThemeCenter
    }

    /// Mix's and Soprano's settings.json in a fresh temporary directory; nothing is watched.
    private func makeFixture(mix: String, soprano: String?, system: AppTheme.Appearance) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-mix-theme-\(UUID().uuidString)", isDirectory: true)
        let mixURL = directory.appendingPathComponent("mix.json")
        let sopranoURL = directory.appendingPathComponent("soprano.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SettingsFile.write(mix, to: mixURL)
        if let soprano {
            try SettingsFile.write(soprano, to: sopranoURL)
        }
        let settings = SettingsCenter(fileURL: mixURL)
        settings.start(watching: false)
        let box = SystemBox(system)
        let center = ThemeCenter(
            sopranoSettingsURL: sopranoURL,
            settings: settings,
            systemAppearance: { box.appearance },
            setApplicationAppearance: { box.applicationAppearance = .some($0?.name) }
        )
        center.start(watching: false)
        return Fixture(directory: directory, mixURL: mixURL, sopranoURL: sopranoURL, settings: settings, system: box, center: center)
    }

    @Test("folio follows the macOS appearance and notifies when it flips")
    func folioFollowsSystem() throws {
        let fixture = try makeFixture(mix: #"{ "theme": "folio" }"#, soprano: nil, system: .light)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let owner = NSObject()
        var notifications = 0
        fixture.center.addObserver(owner) { notifications += 1 }
        #expect(fixture.center.theme.id == AppTheme.folioPaper.id)

        fixture.system.appearance = .dark
        fixture.center.systemAppearanceDidChange()

        #expect(fixture.center.theme.id == AppTheme.folioInk.id)
        #expect(notifications == 1)
        fixture.center.systemAppearanceDidChange()
        #expect(notifications == 1)
        withExtendedLifetime(owner) {}
    }

    @Test("soprano follows Soprano's theme and its appearance, system meaning macOS")
    func sopranoFollowsThemeAndAppearance() throws {
        let fixture = try makeFixture(mix: #"{ "theme": "soprano" }"#, soprano: #"{ "theme": "folio", "appearance": "dark" }"#, system: .light)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(fixture.center.theme.id == AppTheme.folioInk.id)

        try SettingsFile.write(#"{ "theme": "folio", "appearance": "system" }"#, to: fixture.sopranoURL)
        fixture.center.systemAppearanceDidChange()
        #expect(fixture.center.theme.id == AppTheme.folioPaper.id)

        try SettingsFile.write(#"{ "theme": "nord", "appearance": "light" }"#, to: fixture.sopranoURL)
        fixture.center.systemAppearanceDidChange()
        #expect(fixture.center.theme.id == AppTheme.nord.id)
    }

    @Test("without Soprano's settings, soprano is folio on the macOS appearance")
    func missingSopranoFileIsFolio() throws {
        let fixture = try makeFixture(mix: #"{ "theme": "soprano" }"#, soprano: nil, system: .dark)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(fixture.center.theme.id == AppTheme.folioInk.id)
    }

    @Test("pinned themes ignore both the macOS and Soprano's appearance")
    func pinnedThemesIgnoreAppearance() throws {
        let fixture = try makeFixture(mix: #"{ "theme": "folio-paper" }"#, soprano: #"{ "appearance": "dark" }"#, system: .dark)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(fixture.center.theme.id == AppTheme.folioPaper.id)

        fixture.system.appearance = .light
        fixture.center.systemAppearanceDidChange()
        #expect(fixture.center.theme.id == AppTheme.folioPaper.id)
    }

    @Test("a theme change in settings.json applies on reload and notifies observers")
    func settingsChangeAppliesTheme() throws {
        let fixture = try makeFixture(mix: #"{ "theme": "folio-paper" }"#, soprano: nil, system: .light)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let owner = NSObject()
        var notifications = 0
        fixture.center.addObserver(owner) { notifications += 1 }

        try SettingsFile.write(#"{ "theme": "folio-ink" }"#, to: fixture.mixURL)
        fixture.settings.reload()

        #expect(fixture.center.theme.id == AppTheme.folioInk.id)
        #expect(notifications == 1)
        withExtendedLifetime(owner) {}
    }

    @Test("the app appearance is unset while the theme follows macOS and pinned otherwise")
    func applicationAppearanceFollowsTheTheme() throws {
        let cases: [(mix: String, soprano: String?, expected: NSAppearance.Name?)] = [
            (#"{ "theme": "folio" }"#, nil, nil),
            (#"{ "theme": "soprano" }"#, #"{ "theme": "folio", "appearance": "system" }"#, nil),
            (#"{ "theme": "soprano" }"#, #"{ "theme": "folio", "appearance": "light" }"#, .aqua),
            (#"{ "theme": "soprano" }"#, #"{ "theme": "nord", "appearance": "system" }"#, .darkAqua),
            (#"{ "theme": "folio-ink" }"#, nil, .darkAqua),
            (#"{ "theme": "folio-paper" }"#, nil, .aqua),
            (#"{ "theme": "dracula" }"#, nil, .darkAqua),
        ]
        for (mix, soprano, expected) in cases {
            let fixture = try makeFixture(mix: mix, soprano: soprano, system: .dark)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            #expect(fixture.system.applicationAppearance == .some(expected), "\(mix) \(soprano ?? "")")
        }
    }

    @Test("by default the center sets the real NSApp.appearance")
    func defaultSetterDrivesTheApplication() throws {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-mix-theme-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mixURL = directory.appendingPathComponent("mix.json")
        try SettingsFile.write(#"{ "theme": "folio-ink" }"#, to: mixURL)
        let settings = SettingsCenter(fileURL: mixURL)
        settings.start(watching: false)
        let center = ThemeCenter(
            sopranoSettingsURL: directory.appendingPathComponent("soprano.json"),
            settings: settings,
            systemAppearance: { .light }
        )
        center.start(watching: false)
        #expect(app.appearance?.name == .darkAqua)

        try SettingsFile.write(#"{ "theme": "folio" }"#, to: mixURL)
        settings.reload()
        #expect(app.appearance == nil)
        #expect(center.theme.id == AppTheme.folioPaper.id)
    }
}
