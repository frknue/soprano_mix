import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

@MainActor
struct FixtureScenarioTests {
    private func apps(_ scenario: FixtureScenario) -> [AudioApp] {
        AudioAppResolver.apps(from: scenario.processes(), ownPID: FixtureScenario.ownPID)
    }

    private func listed(_ scenario: FixtureScenario) -> [AudioApp] {
        var tracker = AppListTracker()
        return tracker.update(apps: apps(scenario), settings: scenario.settings)
    }

    @Test("the standard scenario lists exactly Discord, Music, Safari, Spotify and TEKKEN 8")
    func standardList() {
        #expect(listed(.standard).map(\.name) == ["Discord", "Music", "Safari", "Spotify", "TEKKEN 8"])
    }

    @Test("System Sounds is connected but not listed while it is idle without a setting")
    func systemSoundsHidden() throws {
        let systemSounds = try #require(apps(.standard).first { $0.key == FixtureKeys.systemSounds })
        #expect(systemSounds.name == "System Sounds")
        #expect(systemSounds.kind == .system)
        #expect(!systemSounds.isPlaying)
        #expect(!listed(.standard).contains { $0.key == FixtureKeys.systemSounds })
    }

    @Test("Soprano Mix is in every scenario's processes but never an app")
    func sopranoMixExcluded() {
        for scenario in FixtureScenario.allCases where scenario != .quiet {
            #expect(scenario.processes().contains { $0.pid == FixtureScenario.ownPID }, "\(scenario)")
            #expect(!apps(scenario).contains { $0.key == FixtureKeys.sopranoMix }, "\(scenario)")
            #expect(!apps(scenario).contains { $0.pids.contains(FixtureScenario.ownPID) }, "\(scenario)")
        }
    }

    @Test("TEKKEN 8 under CrossOver is its own Wine app with its Windows executable as icon")
    func tekkenIsWineApp() throws {
        let tekken = try #require(apps(.standard).first { $0.key == FixtureKeys.tekken })
        #expect(tekken.key.rawValue == "wine:TEKKEN 8")
        #expect(tekken.kind == .wine)
        #expect(tekken.isPlaying)
        #expect(tekken.icon == .windowsExecutable(
            windowsPath: FixtureProcesses.tekkenWindowsPath,
            wineprefix: NSHomeDirectory() + "/Library/Application Support/CrossOver/Bottles/Steam"
        ))
        #expect(!apps(.standard).contains { $0.key.rawValue.hasPrefix("com.codeweavers.") })
    }

    @Test("helpers and WebKit's GPU process fold into the app responsible for them")
    func helpersFold() throws {
        let standard = apps(.standard)
        let safari = try #require(standard.first { $0.key == FixtureKeys.safari })
        #expect(safari.name == "Safari" && safari.kind == .app && safari.pids == [813])
        let discord = try #require(standard.first { $0.key == FixtureKeys.discord })
        #expect(discord.processObjectIDs == [140, 141])
        #expect(discord.isPlaying)
        #expect(!standard.contains { $0.key.rawValue.hasSuffix(".helper") || $0.key.rawValue == "com.apple.WebKit.GPU" })
    }

    @Test("the standard settings hold Spotify 60 %, Discord on the AirPods, TEKKEN 8 35 % and Music muted")
    func standardSettings() {
        let settings = FixtureScenario.standard.settings
        #expect(settings.audio(for: FixtureKeys.spotify).volume == 60)
        #expect(settings.audio(for: FixtureKeys.discord).output == FixtureAudioDevices.airPodsUID)
        #expect(settings.audio(for: FixtureKeys.tekken).volume == 35)
        #expect(settings.audio(for: FixtureKeys.music).muted)
        #expect(settings.outputs.isEmpty)
    }

    @Test("the standard devices: built-in default with hardware volume, AirPods, and a DisplayPort monitor without")
    func standardDevices() throws {
        let devices = FixtureScenario.standard.devices
        let output = try #require(devices.defaultOutput)
        #expect(output.name == "MacBook Pro Speakers" && output.transport == .builtIn)
        #expect(output.outputVolume == 0.62 && output.balance != nil)
        #expect(devices.outputs.map(\.name).sorted() == ["Furkan's AirPods Pro", "MacBook Pro Speakers", "Odyssey G91F"])
        #expect(devices.output(matching: "Odyssey G91F")?.outputVolume == nil)
        #expect(devices.output(matching: "Odyssey G91F")?.transport == .displayPort)
        #expect(devices.defaultInput?.name == "MacBook Pro Microphone")
        #expect(devices.inputs.map(\.name).sorted() == ["Logitech StreamCam", "MacBook Pro Microphone"])
        #expect(Set(devices.devices.map(\.uid)).count == devices.devices.count)
    }

    @Test("game plays on the monitor at 50 % software volume, Steam and TEKKEN 8 apart")
    func game() {
        let scenario = FixtureScenario.game
        #expect(listed(scenario).map(\.name) == ["Discord", "Steam", "TEKKEN 8"])
        #expect(listed(scenario).filter { $0.kind == .wine }.map(\.key) == [FixtureKeys.steam, FixtureKeys.tekken])
        let output = scenario.devices.defaultOutput
        #expect(output?.name == "Odyssey G91F" && output?.outputVolume == nil)
        if let output {
            #expect(scenario.settings.outputVolume(for: output).volume == 50)
        }
        #expect(scenario.settings.audio(for: FixtureKeys.tekken).volume == 35)
    }

    @Test("crowded lists 14 playing apps of every kind")
    func crowded() {
        let crowded = listed(.crowded)
        #expect(crowded.count == 14)
        #expect(crowded.allSatisfy { $0.isPlaying })
        #expect(Set(crowded.map(\.kind)) == [.app, .wine, .executable])
    }

    @Test("quiet has devices but nothing connected")
    func quiet() {
        #expect(FixtureScenario.quiet.processes().isEmpty)
        #expect(FixtureScenario.quiet.devices.defaultOutput != nil)
        #expect(listed(.quiet).isEmpty)
    }

    @Test("every scenario's process objects are unique and ascending")
    func processObjectsAscending() {
        for scenario in FixtureScenario.allCases {
            let ids = scenario.processes().map(\.objectID)
            #expect(ids == ids.sorted(), "\(scenario)")
            #expect(Set(ids).count == ids.count, "\(scenario)")
        }
    }

    @Test("a fixture process source reports every change")
    func processSourceChanges() {
        let source = FixtureProcessSource(scenario: .standard)
        var changes = 0
        source.onChange = { changes += 1 }
        source.start()
        #expect(changes == 0)
        source.processes.removeAll()
        #expect(changes == 1)
        #expect(source.processes.isEmpty)
    }

    @Test("fixture device setters change only what the device has, once per change")
    func deviceSetters() {
        let devices = FixtureDevices(scenario: .standard)
        var changes = 0
        devices.onChange = { changes += 1 }

        devices.setVolume(0.3, scope: .output, uid: FixtureAudioDevices.speakersUID)
        devices.setVolume(1.5, scope: .input, uid: FixtureAudioDevices.microphoneUID)
        #expect(devices.snapshot.device(uid: FixtureAudioDevices.speakersUID)?.outputVolume == 0.3)
        #expect(devices.snapshot.device(uid: FixtureAudioDevices.microphoneUID)?.inputVolume == 1)
        #expect(changes == 2)

        // The monitor has no hardware volume, mute or balance; 22.05 kHz is not offered;
        // a microphone cannot be the output; nothing changes.
        devices.setVolume(0.3, scope: .output, uid: FixtureAudioDevices.odysseyUID)
        devices.setMuted(true, scope: .output, uid: FixtureAudioDevices.odysseyUID)
        devices.setBalance(0.2, uid: FixtureAudioDevices.odysseyUID)
        devices.setSampleRate(22_050, uid: FixtureAudioDevices.speakersUID)
        devices.setDefaultDevice(.output, uid: FixtureAudioDevices.microphoneUID)
        devices.setVolume(0.3, scope: .output, uid: FixtureAudioDevices.speakersUID)
        #expect(changes == 2)

        devices.setDefaultDevice(.output, uid: FixtureAudioDevices.odysseyUID)
        devices.setDefaultDevice(.soundEffects, uid: FixtureAudioDevices.airPodsUID)
        devices.setMuted(true, scope: .output, uid: FixtureAudioDevices.speakersUID)
        #expect(devices.snapshot.defaultOutputUID == FixtureAudioDevices.odysseyUID)
        #expect(devices.snapshot.soundEffectsUID == FixtureAudioDevices.airPodsUID)
        #expect(devices.snapshot.device(uid: FixtureAudioDevices.speakersUID)?.outputMuted == true)
        #expect(changes == 5)
    }

    @Test("the recording router records plans, reports every route running and hands out its levels")
    func recordingRouter() {
        let router = RecordingRouter()
        var statusChanges = 0
        router.onStatusChange = { statusChanges += 1 }
        let plan = RoutePlan(
            routes: [
                RouteSpec(key: FixtureKeys.spotify, processObjectIDs: [134], outputDeviceUID: FixtureAudioDevices.speakersUID,
                          gain: 0.5, mode: .replace, limiter: false, bufferFrames: 256),
                RouteSpec(key: FixtureKeys.safari, processObjectIDs: [131], outputDeviceUID: FixtureAudioDevices.speakersUID,
                          gain: 1, mode: .meter, limiter: false, bufferFrames: 256),
            ],
            master: MasterRouteSpec(outputDeviceUID: FixtureAudioDevices.odysseyUID, gain: 0.5, excludedProcessObjectIDs: [134], bufferFrames: 256)
        )
        router.apply(plan)
        router.apply(plan)
        #expect(router.applied == [plan, plan])
        #expect(router.statuses == [FixtureKeys.spotify: .running, FixtureKeys.safari: .running])
        #expect(router.masterStatus == .running)
        #expect(statusChanges == 1)

        let levels = [FixtureKeys.spotify: RouteLevels(input: StereoLevel(left: 0.5, right: 0.4), output: .silent)]
        router.levels = levels
        #expect(router.takeLevels() == levels)

        router.stopAll()
        #expect(router.statuses.isEmpty && router.masterStatus == nil)
        #expect(statusChanges == 2)
    }

    @Test("fixture icons are cached per app: squircles for apps, template symbols for system processes")
    func icons() throws {
        let provider = FixtureIcons()
        let standard = apps(.standard)
        let spotify = try #require(standard.first { $0.key == FixtureKeys.spotify })
        let systemSounds = try #require(standard.first { $0.key == FixtureKeys.systemSounds })
        let first = provider.icon(for: spotify)
        #expect(provider.icon(for: spotify) === first)
        #expect(first.size == NSSize(width: FixtureIcons.side, height: FixtureIcons.side))
        #expect(!first.isTemplate)
        #expect(provider.icon(for: systemSounds).isTemplate)
    }

    @Test("the settings store records writes and applies them like a reload")
    func settingsStore() {
        let store = FixtureSettingsStore(settings: FixtureScenario.standard.settings)
        store.write(500, at: ["apps", "com.spotify.client", "volume"])
        store.write("default", at: ["apps", "com.hnc.Discord", "output"])
        store.write(true, at: ["apps", "wine:Steam", "muted"])
        store.write(56.25, at: ["outputs", "Odyssey G91F", "volume"])
        #expect(store.settings.audio(for: FixtureKeys.spotify).volume == 400)
        #expect(store.settings.audio(for: FixtureKeys.discord).output == nil)
        #expect(store.settings.audio(for: FixtureKeys.steam).muted)
        #expect(store.settings.outputs["Odyssey G91F"]?.volume == 56.25)
        #expect(store.writes.map(\.value) == [.number(500), .string("default"), .bool(true), .number(56.25)])
        #expect(store.writes.first?.path == ["apps", "com.spotify.client", "volume"])
    }
}
