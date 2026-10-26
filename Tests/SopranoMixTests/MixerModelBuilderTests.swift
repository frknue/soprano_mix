import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

@MainActor
struct MixerModelBuilderTests {
    private let icon = NSImage(size: NSSize(width: 1, height: 1))

    /// The model of a fixture scenario as the controller would build it.
    private func build(
        _ scenario: FixtureScenario = .standard,
        settings: SopranoMixSettings? = nil,
        devices: DeviceSnapshot? = nil,
        statuses: [AppKey: RouteStatus] = [:],
        capture: CaptureStatus = .granted,
        issues: Int = 0,
        alertVolume: Double? = 75
    ) -> MixPanelModel {
        let resolved = settings ?? scenario.settings
        let apps = AudioAppResolver.apps(from: scenario.processes(), ownPID: FixtureScenario.ownPID)
        var tracker = AppListTracker()
        let listed = tracker.update(apps: apps, settings: resolved)
        return MixerModelBuilder.model(
            listedApps: listed, settings: resolved, devices: devices ?? scenario.devices,
            statuses: statuses, capture: capture, settingsIssueCount: issues, alertVolume: alertVolume,
            icons: { _ in icon }
        )
    }

    private func row(_ key: AppKey, in model: MixPanelModel) -> AppRowModel? {
        model.apps.first { $0.key == key }
    }

    @Test("the sections are output, input and sound effects, each menu listing its scope with the default first")
    func sections() throws {
        let model = build()
        #expect(model.sections.map(\.title) == ["Output", "Input", "Sound effects"])
        #expect(model.sections.map(\.role) == [.output, .input, .soundEffects])

        let output = model.sections[0]
        #expect(output.deviceName == "MacBook Pro Speakers")
        #expect(output.deviceSymbol == DeviceTransport.builtIn.symbolName)
        #expect(output.menu.map(\.title) == ["MacBook Pro Speakers", "Furkan's AirPods Pro", "Odyssey G91F"])
        #expect(output.menu.map(\.isSelected) == [true, false, false])
        #expect(output.volume == 62 && output.volumeText == "62 %")
        #expect(!output.isSoftwareVolume)
        #expect(output.isMuted == false)
        #expect(output.balance == 0.5)
        #expect(output.sampleRate == SampleRateMenu(title: "48 kHz", rates: [44_100, 48_000, 88_200, 96_000], selected: 48_000))

        let input = model.sections[1]
        #expect(input.menu.map(\.title) == ["MacBook Pro Microphone", "Logitech StreamCam"])
        #expect(input.volume == 80 && input.isMuted == false)
        #expect(input.balance == nil)
        #expect(input.sampleRate?.title == "48 kHz")

        let effects = model.sections[2]
        #expect(effects.deviceName == "MacBook Pro Speakers")
        #expect(effects.menu.map(\.uid) == output.menu.map(\.uid))
        #expect(effects.volume == 75 && effects.volumeText == "75 %")
        #expect(effects.isMuted == nil && effects.sampleRate == nil && effects.balance == nil)
    }

    @Test("an output without hardware volume shows Soprano Mix's software volume and mute")
    func softwareVolume() {
        let output = build(.game).sections[0]
        #expect(output.deviceName == "Odyssey G91F")
        #expect(output.isSoftwareVolume)
        #expect(output.volume == 50 && output.volumeText == "50 %")
        #expect(output.isMuted == false)
        #expect(output.balance == nil)

        var settings = FixtureScenario.game.settings
        settings.outputs["Odyssey G91F"]?.muted = true
        #expect(build(.game, settings: settings).sections[0].isMuted == true)
    }

    @Test("an output with hardware volume but no hardware mute hides the mute button")
    func hardwareVolumeWithoutMute() {
        var devices = FixtureScenario.standard.devices
        let index = devices.devices.firstIndex { $0.uid == FixtureAudioDevices.speakersUID }
        if let index { devices.devices[index].outputMuted = nil }
        let output = build(devices: devices).sections[0]
        #expect(output.isMuted == nil)
        #expect(!output.isSoftwareVolume)
    }

    @Test("sample-rate titles keep only significant decimals")
    func sampleRateTitles() {
        #expect(MixerModelBuilder.sampleRateTitle(48_000) == "48 kHz")
        #expect(MixerModelBuilder.sampleRateTitle(44_100) == "44.1 kHz")
        #expect(MixerModelBuilder.sampleRateTitle(88_200) == "88.2 kHz")
        #expect(MixerModelBuilder.sampleRateTitle(22_050) == "22.05 kHz")
        #expect(MixerModelBuilder.sampleRateTitle(192_000) == "192 kHz")
    }

    @Test("rows show each app's effective volume and mute, and name the output only off the system output")
    func appRows() throws {
        let model = build()
        #expect(model.apps.map(\.name) == ["Discord", "Music", "Safari", "Spotify", "TEKKEN 8"])
        #expect(model.emptyText == nil)

        let spotify = try #require(row(FixtureKeys.spotify, in: model))
        #expect(spotify.volume == 60 && spotify.volumeText == "60 %")
        #expect(!spotify.isMuted && spotify.isPlaying)
        #expect(spotify.outputName == nil)
        #expect(spotify.outputSymbol == DeviceTransport.builtIn.symbolName)

        let music = try #require(row(FixtureKeys.music, in: model))
        #expect(music.isMuted && !music.isPlaying)

        let discord = try #require(row(FixtureKeys.discord, in: model))
        #expect(discord.outputName == "Furkan's AirPods Pro")
        #expect(discord.outputSymbol == DeviceTransport.bluetooth.symbolName)
    }

    @Test("the output menu starts with the system output and marks the app's choice")
    func outputMenu() throws {
        let model = build()
        let discord = try #require(row(FixtureKeys.discord, in: model))
        #expect(discord.outputMenu.map(\.uid) == [
            nil, FixtureAudioDevices.airPodsUID, FixtureAudioDevices.speakersUID, FixtureAudioDevices.odysseyUID,
        ])
        #expect(discord.outputMenu[0].title == "System output (MacBook Pro Speakers)")
        #expect(discord.outputMenu.filter(\.isSelected).map(\.uid) == [FixtureAudioDevices.airPodsUID])

        let spotify = try #require(row(FixtureKeys.spotify, in: model))
        #expect(spotify.outputMenu.filter(\.isSelected).map(\.uid) == [nil])
    }

    @Test("an app pinned to the default device marks that device but names no output")
    func pinnedToDefaultDevice() throws {
        var settings = FixtureScenario.standard.settings
        settings.apps[FixtureKeys.spotify]?.output = "macbook pro speakers"
        let spotify = try #require(row(FixtureKeys.spotify, in: build(settings: settings)))
        #expect(spotify.outputName == nil)
        #expect(spotify.outputMenu.filter(\.isSelected).map(\.uid) == [FixtureAudioDevices.speakersUID])
    }

    @Test("a chosen output that is gone falls back to the system output")
    func missingOutputFallsBack() throws {
        var devices = FixtureScenario.standard.devices
        devices.devices.removeAll { $0.uid == FixtureAudioDevices.airPodsUID }
        let discord = try #require(row(FixtureKeys.discord, in: build(devices: devices)))
        #expect(discord.outputName == nil)
        #expect(discord.outputMenu.first?.isSelected == true)
        #expect(discord.outputMenu.count == 3)
        #expect(discord.outputSymbol == DeviceTransport.builtIn.symbolName)
    }

    @Test("route statuses become row statuses")
    func rowStatuses() {
        let model = build(statuses: [
            FixtureKeys.spotify: .running,
            FixtureKeys.tekken: .starting,
            FixtureKeys.discord: .failed("The output device is gone."),
        ])
        #expect(row(FixtureKeys.spotify, in: model)?.status == .normal)
        #expect(row(FixtureKeys.tekken, in: model)?.status == .starting)
        #expect(row(FixtureKeys.discord, in: model)?.status == .failed("The output device is gone."))
        #expect(row(FixtureKeys.safari, in: model)?.status == .normal)
    }

    @Test("the capture banner asks to allow when not determined and to open settings when denied")
    func captureBanner() {
        let text = "Allow System Audio Recording to change app volumes."
        #expect(build(capture: .notDetermined).banner == .capture(text: text, button: "Allow"))
        #expect(build(capture: .denied).banner == .capture(text: text, button: "Open Settings"))
        #expect(build(capture: .granted).banner == nil)
        #expect(build(capture: .unknown).banner == nil)
    }

    @Test("the footer counts settings.json warnings")
    func footer() {
        #expect(build(issues: 0).footerWarning == nil)
        #expect(build(issues: 1).footerWarning == "settings.json · 1 warning")
        #expect(build(issues: 3).footerWarning == "settings.json · 3 warnings")
    }

    @Test("nothing listed shows the empty text")
    func emptyState() {
        let quiet = build(.quiet)
        #expect(quiet.apps.isEmpty)
        #expect(quiet.emptyText == "Nothing is playing")
        #expect(quiet.sections.count == 3)
    }

    @Test("without devices the sections say No device and hide their controls")
    func noDevices() {
        let model = build(.quiet, devices: DeviceSnapshot(), alertVolume: nil)
        for section in model.sections {
            #expect(section.deviceName == "No device")
            #expect(section.menu.isEmpty)
            #expect(section.volume == nil && section.volumeText == "")
            #expect(section.isMuted == nil && section.sampleRate == nil && section.balance == nil)
            #expect(!section.isSoftwareVolume)
        }
    }
}
