import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

@MainActor
struct MixerControllerTests {
    private let spotify = FixtureKeys.spotify
    private let safari = FixtureKeys.safari
    private let discord = FixtureKeys.discord
    private let music = FixtureKeys.music
    private let tekken = FixtureKeys.tekken

    private func volumeWrite(_ key: AppKey, _ percent: Double) -> SettingsWrite {
        SettingsWrite(path: ["apps", key.rawValue, "volume"], value: .number(percent))
    }

    // MARK: Listing and planning

    @Test("starting lists the playing apps and those with a setting, and routes only the changed ones")
    func startListsAndPlans() {
        let harness = MixerTestHarness()
        #expect(harness.controller.listedApps.map(\.key) == [discord, music, safari, spotify, tekken])
        #expect(harness.controller.plan.routes.map(\.key) == [discord, music, spotify, tekken].sorted())
        #expect(harness.controller.plan.routes.allSatisfy { $0.mode == .replace })
        #expect(harness.controller.plan.route(for: safari) == nil)
        #expect(harness.router.applied == [harness.controller.plan])
    }

    @Test("the plan goes to the router only when it changes")
    func planAppliedOnlyOnChange() {
        let harness = MixerTestHarness()
        #expect(harness.router.applied.count == 1)
        harness.controller.settingsDidChange()
        harness.processes.processes = harness.processes.processes
        harness.devices.onChange?()
        #expect(harness.router.applied.count == 1)

        harness.controller.handle(.setAppVolume(spotify, 90, final: true))
        #expect(harness.router.applied.count == 2)
        #expect(harness.router.applied.last?.route(for: spotify)?.gain == VolumeLaw.gain(percent: 90))
    }

    @Test("an app that starts playing is listed and one that disconnects is forgotten")
    func appsComeAndGo() {
        let harness = MixerTestHarness()
        harness.processes.processes.removeAll { $0.pid == 4120 }
        #expect(!harness.controller.listedApps.contains { $0.key == spotify })
        // Spotify still has a setting but no process: no route.
        #expect(harness.controller.plan.route(for: spotify) == nil)

        harness.processes.processes.append(FixtureProcesses.spotify(objectID: 500, playing: false))
        #expect(harness.controller.listedApps.contains { $0.key == spotify })
        #expect(harness.controller.plan.route(for: spotify)?.processObjectIDs == [500])
    }

    // MARK: Overrides and persistence

    @Test("an app volume applies at once and is written only when final")
    func overrideThenPersistOnFinal() {
        let harness = MixerTestHarness()
        harness.controller.handle(.setAppVolume(spotify, 80, final: false))
        #expect(harness.controller.plan.route(for: spotify)?.gain == VolumeLaw.gain(percent: 80))
        #expect(harness.writes.isEmpty)

        harness.controller.handle(.setAppVolume(spotify, 82.4, final: true))
        #expect(harness.controller.plan.route(for: spotify)?.gain == VolumeLaw.gain(percent: 82))
        #expect(harness.writes == [volumeWrite(spotify, 82)])

        // The debounce of the first change finds nothing left to write.
        harness.environment.scheduler.fireAll()
        #expect(harness.writes.count == 1)
    }

    @Test("changes during a drag are written once, with the last value, after 0.5 s")
    func debouncePersistsOnce() {
        let harness = MixerTestHarness()
        harness.controller.handle(.setAppVolume(spotify, 70, final: false))
        harness.controller.handle(.setAppVolume(spotify, 75, final: false))
        harness.controller.handle(.setAppVolume(spotify, 77, final: false))
        #expect(harness.writes.isEmpty)
        #expect(harness.environment.scheduler.pendingDelays == [0.5, 0.5, 0.5])

        harness.environment.scheduler.fireAll()
        #expect(harness.writes == [volumeWrite(spotify, 77)])
    }

    @Test("an unsaved change wins over settings.json until it is written")
    func unsavedOverrideWins() {
        let harness = MixerTestHarness()
        harness.controller.handle(.setAppVolume(spotify, 80, final: false))
        harness.settings.apps[spotify] = AppAudioSettings(volume: 40)
        harness.controller.settingsDidChange()
        #expect(harness.controller.plan.route(for: spotify)?.gain == VolumeLaw.gain(percent: 80))
    }

    @Test("a written change is dropped once settings.json holds it, so later edits of the file apply")
    func overrideDroppedOnceFileMatches() {
        let harness = MixerTestHarness()
        harness.controller.handle(.setAppVolume(spotify, 80, final: true))
        harness.controller.settingsDidChange()
        harness.settings.apps[spotify] = AppAudioSettings(volume: 40)
        harness.controller.settingsDidChange()
        #expect(harness.controller.plan.route(for: spotify)?.gain == VolumeLaw.gain(percent: 40))
    }

    @Test("app volumes are clamped to 0–400 and rounded to whole percents")
    func appVolumeClampedAndRounded() {
        let harness = MixerTestHarness()
        harness.controller.handle(.setAppVolume(spotify, 512, final: true))
        harness.controller.handle(.setAppVolume(tekken, -3, final: true))
        #expect(harness.writes == [volumeWrite(spotify, 400), volumeWrite(tekken, 0)])
        #expect(harness.controller.plan.route(for: spotify)?.limiter == true)
        #expect(harness.controller.plan.route(for: tekken)?.gain == 0)
    }

    @Test("mute toggles against the effective setting and output choices write the UID or default")
    func muteAndOutputIntents() {
        let harness = MixerTestHarness()
        harness.controller.handle(.toggleAppMute(music))
        harness.controller.handle(.toggleAppMute(spotify))
        harness.controller.handle(.setAppOutput(spotify, uid: FixtureAudioDevices.airPodsUID))
        harness.controller.handle(.setAppOutput(discord, uid: nil))
        #expect(harness.writes == [
            SettingsWrite(path: ["apps", music.rawValue, "muted"], value: .bool(false)),
            SettingsWrite(path: ["apps", spotify.rawValue, "muted"], value: .bool(true)),
            SettingsWrite(path: ["apps", spotify.rawValue, "output"], value: .string(FixtureAudioDevices.airPodsUID)),
            SettingsWrite(path: ["apps", discord.rawValue, "output"], value: .string("default")),
        ])
        #expect(harness.controller.plan.route(for: music) == nil)
        #expect(harness.controller.plan.route(for: spotify)?.gain == 0)
        #expect(harness.controller.plan.route(for: spotify)?.outputDeviceUID == FixtureAudioDevices.airPodsUID)
        #expect(harness.controller.plan.route(for: discord) == nil)
    }

    // MARK: Devices

    @Test("hardware device changes go to the device, never to settings.json")
    func hardwareDeviceIntents() {
        let harness = MixerTestHarness()
        harness.controller.handle(.setDeviceVolume(.output, 40, final: true))
        harness.controller.handle(.toggleDeviceMute(.output))
        harness.controller.handle(.setBalance(0.25, final: true))
        harness.controller.handle(.setSampleRate(.output, 96_000))
        harness.controller.handle(.setDeviceVolume(.input, 30, final: true))
        harness.controller.handle(.toggleDeviceMute(.input))
        harness.controller.handle(.setDefaultDevice(.input, uid: FixtureAudioDevices.streamCamUID))

        let speakers = harness.devices.snapshot.device(uid: FixtureAudioDevices.speakersUID)
        #expect(speakers?.outputVolume == 0.4)
        #expect(speakers?.outputMuted == true)
        #expect(speakers?.balance == 0.25)
        #expect(speakers?.sampleRate == 96_000)
        let microphone = harness.devices.snapshot.device(uid: FixtureAudioDevices.microphoneUID)
        #expect(microphone?.inputVolume == 0.3)
        #expect(microphone?.inputMuted == true)
        #expect(harness.devices.snapshot.defaultInputUID == FixtureAudioDevices.streamCamUID)
        #expect(harness.writes.isEmpty)
    }

    @Test("an output without hardware volume gets the software volume and mute in settings.json")
    func softwareOutputIntents() {
        let harness = MixerTestHarness(scenario: .game)
        harness.controller.handle(.setDeviceVolume(.output, 30.4, final: true))
        harness.controller.handle(.toggleDeviceMute(.output))
        #expect(harness.writes == [
            SettingsWrite(path: ["outputs", "Odyssey G91F", "volume"], value: .number(30)),
            SettingsWrite(path: ["outputs", "Odyssey G91F", "muted"], value: .bool(true)),
        ])
        #expect(harness.controller.plan.master?.gain == 0)
        #expect(harness.devices.snapshot.defaultOutput?.outputVolume == nil)
    }

    @Test("the sound-effects volume goes to the alert volume")
    func soundEffectsVolume() {
        let harness = MixerTestHarness()
        harness.controller.showPanel(anchor: nil)
        harness.controller.handle(.setDeviceVolume(.soundEffects, 20, final: true))
        #expect(harness.environment.alertVolume == 20)
        #expect(harness.panel.model?.sections.last?.volume == 20)
        #expect(harness.writes.isEmpty)
    }

    @Test("an app whose output device disappears falls back to the system output and returns with it")
    func outputDeviceGoneFallsBack() {
        let harness = MixerTestHarness()
        #expect(harness.controller.plan.route(for: discord)?.outputDeviceUID == FixtureAudioDevices.airPodsUID)

        harness.devices.snapshot.devices.removeAll { $0.uid == FixtureAudioDevices.airPodsUID }
        #expect(harness.controller.plan.route(for: discord) == nil)
        harness.controller.showPanel(anchor: nil)
        #expect(harness.row(discord)?.outputName == nil)
        #expect(harness.row(discord)?.outputMenu.first?.isSelected == true)
        // The setting stays, so the app goes back once the device returns.
        #expect(harness.settings.audio(for: discord).output == FixtureAudioDevices.airPodsUID)
        harness.controller.hidePanel()

        harness.devices.snapshot.devices.append(FixtureAudioDevices.airPods)
        #expect(harness.controller.plan.route(for: discord)?.outputDeviceUID == FixtureAudioDevices.airPodsUID)
    }

    // MARK: Capture permission

    @Test("without a capture decision nothing is routed and the first change asks once")
    func captureNotDetermined() {
        let harness = MixerTestHarness(capture: .notDetermined)
        #expect(harness.controller.plan == .empty)
        #expect(harness.router.applied.isEmpty)
        #expect(harness.environment.captureRequests == 0)

        harness.controller.handle(.setAppVolume(spotify, 50, final: true))
        harness.controller.handle(.toggleAppMute(safari))
        #expect(harness.environment.captureRequests == 1)
        #expect(harness.controller.plan == .empty)
        #expect(harness.writes.count == 2)

        harness.environment.answerCapture(.granted)
        #expect(harness.controller.plan.route(for: spotify)?.gain == VolumeLaw.gain(percent: 50))
        #expect(harness.controller.plan.route(for: safari)?.gain == 0)
    }

    @Test("denied capture routes nothing and changes do not ask again")
    func captureDenied() {
        let harness = MixerTestHarness(capture: .denied)
        harness.controller.handle(.setAppVolume(spotify, 50, final: true))
        #expect(harness.environment.captureRequests == 0)
        #expect(harness.controller.plan == .empty)
    }

    @Test("the banner's button asks for capture every time")
    func requestCaptureIntent() {
        let harness = MixerTestHarness(capture: .notDetermined)
        harness.controller.handle(.requestCapture)
        harness.controller.handle(.requestCapture)
        #expect(harness.environment.captureRequests == 2)
        harness.controller.handle(.setAppVolume(spotify, 50, final: true))
        #expect(harness.environment.captureRequests == 2)
    }

    // MARK: Panel and meters

    @Test("toggling shows and hides the panel; dismiss closes it")
    func panelVisibility() {
        let harness = MixerTestHarness()
        harness.controller.togglePanel(anchor: NSRect(x: 900, y: 1000, width: 24, height: 22))
        #expect(harness.controller.isPanelVisible)
        #expect(harness.panel.model?.apps.map(\.key) == harness.controller.listedApps.map(\.key))
        harness.controller.togglePanel(anchor: nil)
        #expect(!harness.controller.isPanelVisible)
        harness.controller.showPanel(anchor: nil)
        harness.panel.onIntent?(.dismiss)
        #expect(!harness.controller.isPanelVisible)
        #expect(harness.panel.showCount == 2)
    }

    @Test("meters run only while the panel is visible: output peaks for changed apps, input peaks for metered ones")
    func meters() throws {
        let harness = MixerTestHarness()
        #expect(harness.environment.scheduler.repeatingIntervals.isEmpty)

        harness.controller.showPanel(anchor: nil)
        #expect(harness.environment.scheduler.repeatingIntervals == [MixerController.meterInterval])
        #expect(harness.controller.plan.route(for: safari)?.mode == .meter)

        harness.router.levels = [
            spotify: RouteLevels(input: StereoLevel(left: 1, right: 1), output: StereoLevel(left: 0.1, right: 0.05)),
            safari: RouteLevels(input: StereoLevel(left: 0.2, right: 0.5), output: .silent),
        ]
        harness.environment.scheduler.tick()
        let levels = try #require(harness.panel.levelUpdates.last)
        #expect(levels[spotify] == MeterScale.position(forAmplitude: 0.1))
        #expect(levels[safari] == MeterScale.position(forAmplitude: 0.5))
        #expect(levels[tekken] == 0)
        #expect(levels[music] == nil)

        harness.controller.hidePanel()
        #expect(harness.environment.scheduler.repeatingIntervals.isEmpty)
        #expect(harness.controller.plan.route(for: safari) == nil)
    }

    @Test("meters fall at their rate between frames")
    func meterBallistics() throws {
        let harness = MixerTestHarness()
        harness.controller.showPanel(anchor: nil)
        harness.router.levels = [safari: RouteLevels(input: StereoLevel(left: 1, right: 1), output: .silent)]
        harness.controller.tickMeters()
        harness.router.levels = [:]
        harness.environment.clock += 0.5
        harness.controller.tickMeters()
        let levels = try #require(harness.panel.levelUpdates.last)
        // 24 dB/s over a 60 dB scale: half a second falls 0.2.
        #expect(abs((levels[safari] ?? 0) - 0.8) < 1e-9)
    }

    @Test("panel.meters off plans no meter routes and runs no meter timer")
    func metersOff() {
        var settings = FixtureScenario.standard.settings
        settings.panel.meters = false
        let harness = MixerTestHarness(settings: settings)
        harness.controller.showPanel(anchor: nil)
        #expect(harness.controller.plan.routes.allSatisfy { $0.mode == .replace })
        #expect(harness.environment.scheduler.repeatingIntervals.isEmpty)
    }

    // MARK: Volume keys

    @Test("volume keys pass through to macOS on an output with hardware volume")
    func volumeKeysIgnoredWithHardwareVolume() {
        let harness = MixerTestHarness()
        let up = harness.press(.up)
        let mute = harness.press(.mute)
        #expect(!up.down && !up.up && !mute.down && !mute.up)
        #expect(harness.hud.shown.isEmpty)
        #expect(harness.devices.snapshot.defaultOutput?.outputVolume == 0.62)
    }

    @Test("volume keys change the software volume, show the HUD and persist after 0.5 s")
    func volumeKeysSoftwareVolume() {
        let harness = MixerTestHarness(scenario: .game)
        let up = harness.press(.up)
        #expect(up.down && up.up)
        #expect(harness.hud.current == VolumeHUDModel(
            deviceName: "Odyssey G91F", level: 0.5625, isMuted: false, caption: "Software volume"
        ))
        #expect(harness.controller.plan.master?.gain == VolumeLaw.gain(percent: 56.25))
        #expect(harness.writes.isEmpty)
        #expect(harness.environment.scheduler.pendingDelays == [0.5])

        harness.environment.scheduler.fireAll()
        #expect(harness.writes == [SettingsWrite(path: ["outputs", "Odyssey G91F", "volume"], value: .number(56.25))])
    }

    @Test("the mute key toggles the software mute and a volume key unmutes")
    func volumeKeysMute() {
        let harness = MixerTestHarness(scenario: .game)
        _ = harness.press(.mute)
        #expect(harness.hud.current?.isMuted == true)
        #expect(harness.controller.plan.master?.gain == 0)
        #expect(harness.controller.handleVolumeKey(VolumeKeyEvent(key: .mute, isDown: true, isRepeat: true)))
        #expect(harness.hud.current?.isMuted == true)

        _ = harness.press(.down)
        #expect(harness.hud.current == VolumeHUDModel(
            deviceName: "Odyssey G91F", level: 0.4375, isMuted: false, caption: "Software volume"
        ))
    }

    @Test("without the HUD setting volume keys still work but show nothing; without anyOutput they pass")
    func volumeKeySettings() {
        var settings = FixtureScenario.game.settings
        settings.volumeKeys.hud = false
        let quiet = MixerTestHarness(scenario: .game, settings: settings)
        #expect(quiet.press(.up).down)
        #expect(quiet.hud.shown.isEmpty)

        settings.volumeKeys.anyOutput = false
        let off = MixerTestHarness(scenario: .game, settings: settings)
        #expect(!off.press(.up).down)
        #expect(off.controller.plan.master?.gain == VolumeLaw.gain(percent: 50))
    }

    // MARK: CLI

    @Test("the CLI lists the listed apps with their effective settings and devices")
    func cliList() throws {
        let harness = MixerTestHarness()
        let list = harness.controller.handle(.list)
        #expect(list.ok)
        let apps = try #require(list.apps)
        #expect(apps.map(\.name) == ["Discord", "Music", "Safari", "Spotify", "TEKKEN 8"])
        let discordApp = try #require(apps.first)
        #expect(discordApp.output == FixtureAudioDevices.airPodsUID)
        #expect(discordApp.outputName == "Furkan's AirPods Pro")
        #expect(discordApp.routed)
        #expect(discordApp.pids == [2318, 2325])
        let safariApp = try #require(apps.first { $0.key == safari.rawValue })
        #expect(!safariApp.routed && safariApp.playing && safariApp.volume == 100)
        #expect(apps.first { $0.key == tekken.rawValue }?.kind == "wine")

        let devices = try #require(harness.controller.handle(.devices).devices)
        #expect(devices.count == 5)
        let speakers = try #require(devices.first { $0.uid == FixtureAudioDevices.speakersUID })
        #expect(speakers.defaultOutput && speakers.soundEffects && speakers.volume == 62 && !speakers.softwareVolume)
        let odyssey = try #require(devices.first { $0.uid == FixtureAudioDevices.odysseyUID })
        #expect(odyssey.softwareVolume && odyssey.volume == 100 && odyssey.muted == false)
    }

    @Test("the CLI sets a matched app and answers with it")
    func cliSetsMatchedApp() throws {
        let harness = MixerTestHarness()
        let response = harness.controller.handle(.setVolume(app: "spot", percent: 25))
        #expect(response.ok)
        #expect(response.app?.name == "Spotify")
        #expect(response.app?.volume == 25)
        #expect(harness.writes == [volumeWrite(spotify, 25)])

        let muted = harness.controller.handle(.setMuted(app: "Music", muted: nil))
        #expect(muted.app?.muted == false)
        let output = harness.controller.handle(.setOutput(app: "TEKKEN 8", device: "odyssey g91f"))
        #expect(output.app?.output == FixtureAudioDevices.odysseyUID)
        #expect(output.app?.outputName == "Odyssey G91F")
    }

    @Test("the CLI reports an ambiguous query with every match and an unknown one by name")
    func cliErrors() {
        let harness = MixerTestHarness()
        let ambiguous = harness.controller.handle(.setVolume(app: "s", percent: 50))
        #expect(!ambiguous.ok)
        #expect(ambiguous.error == "'s' matches Safari, Spotify, System Sounds.")
        let none = harness.controller.handle(.setMuted(app: "Zoom", muted: true))
        #expect(none.error == "No app matches 'Zoom'.")
        #expect(harness.writes.isEmpty)
    }

    @Test("a key-like query sets an app that is not running")
    func cliKeyLikeQuery() throws {
        let harness = MixerTestHarness()
        let bundle = harness.controller.handle(.setVolume(app: "com.apple.podcasts", percent: 30))
        let app = try #require(bundle.app)
        #expect(app.key == "com.apple.podcasts" && app.name == "com.apple.podcasts" && app.kind == "app")
        #expect(!app.playing && app.pids.isEmpty && !app.routed)

        let game = try #require(harness.controller.handle(.setMuted(app: "wine:ELDEN RING", muted: true)).app)
        #expect(game.name == "ELDEN RING" && game.kind == "wine" && game.muted)
        #expect(harness.writes == [
            volumeWrite(AppKey(rawValue: "com.apple.podcasts"), 30),
            SettingsWrite(path: ["apps", "wine:ELDEN RING", "muted"], value: .bool(true)),
        ])
    }

    @Test("show and hide from the CLI open and close the panel")
    func cliShowHide() {
        let harness = MixerTestHarness()
        #expect(harness.controller.handle(.show).ok)
        #expect(harness.controller.isPanelVisible)
        #expect(harness.controller.handle(.hide).ok)
        #expect(!harness.controller.isPanelVisible)
    }
}
