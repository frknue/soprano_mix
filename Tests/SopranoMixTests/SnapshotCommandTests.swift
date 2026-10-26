import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

@MainActor
struct SnapshotCommandTests {
    private typealias Command = SnapshotCommand

    private func parse(_ arguments: [String]) throws -> Command.Options {
        try Command.parse(["--out", "/tmp/soprano-mix-snapshot.png"] + arguments)
    }

    // MARK: Options

    @Test("only --out is required; everything else has a default")
    func defaults() throws {
        let options = try parse([])
        #expect(options.out.path == "/tmp/soprano-mix-snapshot.png")
        #expect(options.scenario == .standard)
        #expect(options.theme == nil && options.settings == nil && options.report == nil)
        #expect(options.capture == .granted)
        #expect(!options.levels && !options.hud && !options.onboarding)
        #expect(options.actions.isEmpty)
        #expect(options.permissionCapture == .notDetermined && !options.accessibilityGranted)
    }

    @Test("a leading snapshot command word is skipped")
    func leadingCommand() throws {
        let options = try Command.parse(["snapshot", "--out", "/tmp/mix.png", "--scenario", "game"])
        #expect(options.out.path == "/tmp/mix.png")
        #expect(options.scenario == .game)
    }

    @Test("every option parses into its field")
    func everyOption() throws {
        let options = try parse([
            "--scenario", "crowded", "--theme", "folio-ink", "--settings", "/tmp/mix.jsonc",
            "--capture", "notDetermined", "--levels", "--hud", "--report", "/tmp/report.json",
            "--actions", "volume:Spotify=80 keyUp",
        ])
        #expect(options.scenario == .crowded)
        #expect(options.theme == "folio-ink")
        #expect(options.settings?.path == "/tmp/mix.jsonc")
        #expect(options.capture == .notDetermined)
        #expect(options.levels && options.hud)
        #expect(options.report?.path == "/tmp/report.json")
        #expect(options.actions == [.volume(app: "Spotify", percent: 80), .key(.up)])
    }

    @Test("actions parse in order, with quoted names holding spaces")
    func actions() throws {
        let options = try parse([
            "--actions",
            #"volume:Spotify=80  mute:"TEKKEN 8" output:Discord="MacBook Pro Speakers" output:Safari=Default "#
                + "device:effects=Odyssey device:input=StreamCam devvolume:output=30 keyUp KEYDOWN keymute",
        ])
        #expect(options.actions == [
            .volume(app: "Spotify", percent: 80),
            .mute(app: "TEKKEN 8"),
            .output(app: "Discord", device: "MacBook Pro Speakers"),
            .output(app: "Safari", device: nil),
            .device(role: .soundEffects, name: "Odyssey"),
            .device(role: .input, name: "StreamCam"),
            .deviceVolume(role: .output, percent: 30),
            .key(.up),
            .key(.down),
            .key(.mute),
        ])
    }

    @Test("onboarding takes the permission states")
    func onboarding() throws {
        let options = try parse(["--onboarding", "--permissions", "capture=denied,accessibility=granted"])
        #expect(options.onboarding)
        #expect(options.permissionCapture == .denied)
        #expect(options.accessibilityGranted)
        let partial = try parse(["--onboarding", "--permissions", "accessibility=missing"])
        #expect(partial.permissionCapture == .notDetermined && !partial.accessibilityGranted)
    }

    @Test("bad input is rejected with the matching error")
    func errors() {
        #expect(throws: Command.OptionError.missingOut) { try Command.parse(["--scenario", "game"]) }
        #expect(throws: Command.OptionError.missingValue("--actions")) { try parse(["--actions"]) }
        #expect(throws: Command.OptionError.unknownOption("--screen")) { try parse(["--screen", "1512x982"]) }
        #expect(throws: Command.OptionError.badScenario("busy")) { try parse(["--scenario", "busy"]) }
        #expect(throws: Command.OptionError.badCapture("maybe")) { try parse(["--capture", "maybe"]) }
        #expect(throws: Command.OptionError.badAction("volume:Spotify=500")) { try parse(["--actions", "volume:Spotify=500"]) }
        #expect(throws: Command.OptionError.badAction("volume:Spotify")) { try parse(["--actions", "volume:Spotify"]) }
        #expect(throws: Command.OptionError.badAction("mute:")) { try parse(["--actions", "mute:"]) }
        #expect(throws: Command.OptionError.badAction("device:speakers=Odyssey")) {
            try parse(["--actions", "device:speakers=Odyssey"])
        }
        #expect(throws: Command.OptionError.badAction("devvolume:output=150")) { try parse(["--actions", "devvolume:output=150"]) }
        #expect(throws: Command.OptionError.badAction("keyLeft")) { try parse(["--actions", "keyUp keyLeft"]) }
        #expect(throws: Command.OptionError.badPermissions("capture=yes")) {
            try parse(["--onboarding", "--permissions", "capture=yes"])
        }
        #expect(throws: Command.OptionError.permissionsWithoutOnboarding) {
            try parse(["--permissions", "accessibility=granted"])
        }
    }

    // MARK: Settings and actions

    @Test("a settings file goes over the scenario's settings, keeping the entries it does not name")
    func settingsOverScenario() {
        var file = SopranoMixSettings()
        file.apps[FixtureKeys.spotify] = AppAudioSettings(volume: 20)
        file.panel.meters = false
        let merged = Command.merged(file, over: FixtureScenario.standard.settings)
        #expect(merged.audio(for: FixtureKeys.spotify).volume == 20)
        #expect(merged.audio(for: FixtureKeys.tekken).volume == 35)
        #expect(merged.audio(for: FixtureKeys.music).muted)
        #expect(!merged.panel.meters)
    }

    @Test("the harness resolves soprano and folio to Paper and folio-ink to Ink")
    func harnessThemes() {
        #expect(Command.harnessTheme("soprano").id == AppTheme.folioPaper.id)
        #expect(Command.harnessTheme("folio").id == AppTheme.folioPaper.id)
        #expect(Command.harnessTheme("folio-ink").id == AppTheme.folioInk.id)
    }

    @Test("actions resolve apps like the CLI and devices by name")
    func applyActions() throws {
        let harness = MixerTestHarness()
        try Command.apply(.output(app: "disc", device: "macbook"), to: harness.controller, devices: harness.devices.snapshot)
        try Command.apply(.device(role: .output, name: "Odyssey G91F"), to: harness.controller, devices: harness.devices.snapshot)
        #expect(harness.writes == [
            SettingsWrite(path: ["apps", FixtureKeys.discord.rawValue, "output"], value: .string(FixtureAudioDevices.speakersUID)),
        ])
        #expect(harness.devices.snapshot.defaultOutputUID == FixtureAudioDevices.odysseyUID)

        #expect(throws: Command.RenderError.self) {
            try Command.apply(.mute(app: "s"), to: harness.controller, devices: harness.devices.snapshot)
        }
        #expect(throws: Command.RenderError.self) {
            try Command.apply(.output(app: "Spotify", device: "Sonos"), to: harness.controller, devices: harness.devices.snapshot)
        }
        #expect(throws: Command.RenderError.self) {
            try Command.apply(.device(role: .input, name: "Odyssey"), to: harness.controller, devices: harness.devices.snapshot)
        }
    }

    @Test("fixed levels put exactly the first playing app near clipping")
    func fixedLevels() {
        var tracker = AppListTracker()
        let apps = AudioAppResolver.apps(from: FixtureScenario.crowded.processes(), ownPID: FixtureScenario.ownPID)
        let listed = tracker.update(apps: apps, settings: FixtureScenario.crowded.settings)
        let levels = Command.fixedLevels(for: listed)
        #expect(levels.count == 14)
        let clipping = levels.filter { $0.value.output.peak >= 0.891 }.map(\.key)
        #expect(clipping == [listed[0].key])
    }

    // MARK: Report

    @Test("the report lists the apps, the plan, the writes and the HUD")
    func reportContent() throws {
        let harness = MixerTestHarness(scenario: .game)
        _ = harness.press(.up)
        harness.environment.scheduler.fireAll()
        let report = Command.makeReport(
            controller: harness.controller, devices: harness.devices.snapshot,
            writes: harness.writes, hud: harness.hud.current
        )
        #expect(report.apps.map(\.name) == ["Discord", "Steam", "TEKKEN 8"])
        let tekken = try #require(report.apps.last)
        #expect(tekken.key == "wine:TEKKEN 8" && tekken.volume == 35 && !tekken.muted && tekken.playing)
        #expect(tekken.output == nil && tekken.outputName == "Odyssey G91F")

        let route = try #require(report.plan.routes.first { $0.key == "wine:TEKKEN 8" })
        #expect(route.mode == "replace" && route.device == "Odyssey G91F")
        #expect(route.deviceUID == FixtureAudioDevices.odysseyUID)
        #expect(route.processObjectIDs == [152])
        let master = try #require(report.plan.master)
        #expect(master.device == "Odyssey G91F")
        #expect(master.excludedProcessObjectIDs == [152])
        #expect(master.gain == (Double(VolumeLaw.gain(percent: 56.25)) * 10_000).rounded() / 10_000)

        #expect(report.settingsWrites == [SettingsWrite(path: ["outputs", "Odyssey G91F", "volume"], value: .number(56.25))])
        #expect(report.hud == SnapshotReport.HUD(deviceName: "Odyssey G91F", level: 0.5625, isMuted: false, caption: "Software volume"))
    }

    @Test("the report writes missing values as null")
    func reportJSON() throws {
        let report = SnapshotReport(
            apps: [SnapshotReport.App(key: "com.apple.Safari", name: "Safari", volume: 100, muted: false,
                                      output: nil, outputName: "MacBook Pro Speakers", playing: true)],
            plan: SnapshotReport.Plan(routes: [], master: nil),
            settingsWrites: [SettingsWrite(path: ["apps", "com.apple.Safari", "output"], value: .string("default"))],
            hud: nil
        )
        let text = String(decoding: try report.jsonData(), as: UTF8.self)
        #expect(text.contains("\"hud\" : null"))
        #expect(text.contains("\"master\" : null"))
        #expect(text.contains("\"output\" : null"))
        #expect(text.contains("\"value\" : \"default\""))
    }

    @Test("rendering the standard scenario reports what the actions changed")
    func renderStandard() throws {
        let options = try parse(["--actions", "volume:Spotify=80 output:Discord=default", "--levels"])
        let result = try Command.render(options)
        #expect(result.image.width > 0 && result.image.height > 0)
        let report = result.report
        #expect(report.apps.map(\.name) == ["Discord", "Music", "Safari", "Spotify", "TEKKEN 8"])
        #expect(report.apps.first { $0.name == "Spotify" }?.volume == 80)
        #expect(report.settingsWrites == [
            SettingsWrite(path: ["apps", "com.spotify.client", "volume"], value: .number(80)),
            SettingsWrite(path: ["apps", "com.hnc.Discord", "output"], value: .string("default")),
        ])
        // The panel is open, so Discord, now on the system output, is metered instead.
        #expect(report.plan.routes.first { $0.key == "com.hnc.Discord" }?.mode == "meter")
        #expect(report.hud == nil)
    }

    @Test("--hud renders the volume HUD after a volume key on a software-volume output")
    func renderHUD() throws {
        let result = try Command.render(try parse(["--scenario", "game", "--hud", "--actions", "keyMute"]))
        #expect(result.report.hud?.isMuted == true)
        #expect(result.report.plan.master?.gain == 0)
        #expect(throws: Command.RenderError.self) { try Command.render(try parse(["--hud"])) }
    }

    @Test("rendering leaves the process's app appearance as it found it")
    func renderRestoresAppAppearance() throws {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }
        app.appearance = nil
        _ = try Command.render(try parse(["--theme", "folio-ink", "--scenario", "quiet"]))
        #expect(app.appearance == nil)
    }
}
