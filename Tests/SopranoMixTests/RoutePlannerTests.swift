import AppKit
import Testing
@testable import SopranoMixCore

struct RoutePlannerTests {
    private let speakers = AudioDevice(objectID: 82, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                                       transport: .builtIn, outputChannels: 2, inputChannels: 0, outputVolume: 0.6)
    private let airPods = AudioDevice(objectID: 119, uid: "BC-80-4E-EC-D9-CC:output", name: "Furkan’s AirPods Pro",
                                      transport: .bluetooth, outputChannels: 2, inputChannels: 0, outputVolume: 0.5)
    private let monitor = AudioDevice(objectID: 104, uid: "4C2D6778-0000-0000-2823-0104B5772278_0C80D010", name: "Odyssey G91F",
                                      transport: .displayPort, outputChannels: 2, inputChannels: 0)
    private let microphone = AudioDevice(objectID: 89, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                         transport: .builtIn, outputChannels: 0, inputChannels: 1)

    private func devices(defaultOutput: String) -> DeviceSnapshot {
        DeviceSnapshot(devices: [airPods, speakers, microphone, monitor], defaultOutputUID: defaultOutput,
                       defaultInputUID: microphone.uid, soundEffectsUID: speakers.uid)
    }

    private let spotify = AudioApp(key: .bundle("com.spotify.client"), name: "Spotify", kind: .app, icon: .symbol("app"),
                                   processObjectIDs: [10], pids: [100], isPlaying: true)
    private let tekken = AudioApp(key: .wine("TEKKEN 8"), name: "TEKKEN 8", kind: .wine, icon: .symbol("app"),
                                  processObjectIDs: [20, 21], pids: [200, 201], isPlaying: true)
    private let safari = AudioApp(key: .bundle("com.apple.Safari"), name: "Safari", kind: .app, icon: .symbol("app"),
                                  processObjectIDs: [30], pids: [300], isPlaying: true)
    private let music = AudioApp(key: .bundle("com.apple.Music"), name: "Music", kind: .app, icon: .symbol("app"),
                                 processObjectIDs: [40], pids: [400], isPlaying: false)

    private var apps: [AudioApp] { [spotify, tekken, safari, music] }

    private func plan(_ settings: SopranoMixSettings, defaultOutput: String? = nil, metered: Set<AppKey> = [],
                      canCapture: Bool = true, apps: [AudioApp]? = nil) -> RoutePlan {
        RoutePlanner.plan(apps: apps ?? self.apps, settings: settings,
                          devices: devices(defaultOutput: defaultOutput ?? speakers.uid),
                          meteredKeys: metered, canCapture: canCapture)
    }

    @Test("without capture permission or a default output nothing is routed")
    func noCaptureNoRoutes() {
        var settings = SopranoMixSettings()
        settings.apps[spotify.key] = AppAudioSettings(volume: 50)
        #expect(plan(settings, canCapture: false) == .empty)
        let noDefault = RoutePlanner.plan(apps: apps, settings: settings, devices: DeviceSnapshot(devices: [speakers]),
                                          meteredKeys: [], canCapture: true)
        #expect(noDefault == .empty)
    }

    @Test("default settings route nothing")
    func defaultSettingsNoRoutes() {
        #expect(plan(.defaults) == .empty)
        #expect(plan(.defaults, defaultOutput: monitor.uid) == .empty)
    }

    @Test("volume, mute and another output each create a replace route sorted by key")
    func replaceRoutes() {
        var settings = SopranoMixSettings()
        settings.apps[spotify.key] = AppAudioSettings(volume: 50)
        settings.apps[tekken.key] = AppAudioSettings(muted: true)
        settings.apps[safari.key] = AppAudioSettings(output: "furkan’s airpods pro")
        settings.audio.bufferFrames = 128
        let result = plan(settings)
        #expect(result.routes.map(\.key) == [safari.key, spotify.key, tekken.key])
        #expect(result.routes.allSatisfy { $0.mode == .replace && $0.bufferFrames == 128 })
        #expect(result.route(for: spotify.key)?.gain == VolumeLaw.gain(percent: 50))
        #expect(result.route(for: spotify.key)?.outputDeviceUID == speakers.uid)
        #expect(result.route(for: tekken.key)?.gain == 0)
        #expect(result.route(for: tekken.key)?.processObjectIDs == [20, 21])
        #expect(result.route(for: safari.key)?.outputDeviceUID == airPods.uid)
        #expect(result.route(for: safari.key)?.gain == 1)
        #expect(result.master == nil)
    }

    @Test("an app without process objects gets no route")
    func noProcessesNoRoute() {
        var settings = SopranoMixSettings()
        settings.apps[spotify.key] = AppAudioSettings(volume: 50)
        var gone = spotify
        gone.processObjectIDs = []
        #expect(plan(settings, apps: [gone]) == .empty)
    }

    @Test("the limiter runs only above 100 percent and only when enabled")
    func limiterAboveHundred() {
        var settings = SopranoMixSettings()
        settings.apps[spotify.key] = AppAudioSettings(volume: 250)
        settings.apps[tekken.key] = AppAudioSettings(volume: 100, output: airPods.uid)
        settings.apps[safari.key] = AppAudioSettings(volume: 80)
        let result = plan(settings)
        #expect(result.route(for: spotify.key)?.limiter == true)
        #expect(result.route(for: tekken.key)?.limiter == false)
        #expect(result.route(for: safari.key)?.limiter == false)

        settings.audio.limiter = false
        #expect(plan(settings).route(for: spotify.key)?.limiter == false)
    }

    @Test("a missing per-app output falls back to the default output")
    func missingOutputFallsBack() {
        var settings = SopranoMixSettings()
        settings.apps[spotify.key] = AppAudioSettings(output: "Unplugged USB DAC")
        settings.apps[tekken.key] = AppAudioSettings(volume: 60, output: "Unplugged USB DAC")
        settings.apps[safari.key] = AppAudioSettings(output: microphone.uid)
        let result = plan(settings)
        #expect(result.route(for: spotify.key) == nil)
        #expect(result.route(for: safari.key) == nil)
        #expect(result.route(for: tekken.key)?.outputDeviceUID == speakers.uid)
    }

    @Test("naming the default output explicitly is not a route")
    func explicitDefaultOutput() {
        var settings = SopranoMixSettings()
        settings.apps[spotify.key] = AppAudioSettings(output: "MacBook Pro Speakers")
        #expect(plan(settings) == .empty)
    }

    @Test("meter routes cover metered playing apps without a replace route")
    func meterRoutes() {
        var settings = SopranoMixSettings()
        settings.apps[spotify.key] = AppAudioSettings(volume: 50)
        let result = plan(settings, metered: [spotify.key, tekken.key, music.key])
        #expect(result.routes.map(\.key) == [spotify.key, tekken.key])
        #expect(result.route(for: spotify.key)?.mode == .replace)
        let meter = result.route(for: tekken.key)
        #expect(meter == RouteSpec(key: tekken.key, processObjectIDs: [20, 21], outputDeviceUID: speakers.uid,
                                   gain: 1, mode: .meter, limiter: false, bufferFrames: 256))
    }

    @Test("software volume on a hardware-less default output adds a master route excluding replaced processes")
    func masterRoute() {
        var settings = SopranoMixSettings()
        settings.outputs["Odyssey G91F"] = OutputVolumeSettings(volume: 50)
        settings.apps[tekken.key] = AppAudioSettings(volume: 35)
        settings.apps[safari.key] = AppAudioSettings(output: airPods.uid)
        let result = plan(settings, defaultOutput: monitor.uid, metered: [spotify.key])
        #expect(result.master == MasterRouteSpec(outputDeviceUID: monitor.uid, gain: VolumeLaw.gain(percent: 50),
                                                 excludedProcessObjectIDs: [20, 21, 30], bufferFrames: 256))
    }

    @Test("full software volume needs no master route, muted output plays silence")
    func masterRouteBoundaries() {
        var settings = SopranoMixSettings()
        #expect(plan(settings, defaultOutput: monitor.uid).master == nil)
        settings.outputs[monitor.uid] = OutputVolumeSettings(volume: 100, muted: true)
        #expect(plan(settings, defaultOutput: monitor.uid).master?.gain == 0)
        settings.outputs["MacBook Pro Speakers"] = OutputVolumeSettings(volume: 10)
        #expect(plan(settings).master == nil)
    }

    @Test("the software gain multiplies into app routes on that device")
    func softwareGainMultiplies() {
        var settings = SopranoMixSettings()
        settings.outputs["odyssey g91f"] = OutputVolumeSettings(volume: 50)
        settings.apps[tekken.key] = AppAudioSettings(volume: 200)
        settings.apps[spotify.key] = AppAudioSettings(volume: 50, output: airPods.uid)
        let result = plan(settings, defaultOutput: monitor.uid)
        let outputGain = VolumeLaw.gain(percent: 50)
        #expect(RoutePlanner.softwareGain(for: monitor, settings: settings) == outputGain)
        #expect(result.route(for: tekken.key)?.gain == VolumeLaw.gain(percent: 200) * outputGain)
        #expect(result.route(for: spotify.key)?.gain == VolumeLaw.gain(percent: 50))
    }

    @Test("outputs with hardware volume have a software gain of one")
    func hardwareVolumeGain() {
        var settings = SopranoMixSettings()
        settings.outputs[speakers.name] = OutputVolumeSettings(volume: 20, muted: true)
        #expect(RoutePlanner.softwareGain(for: speakers, settings: settings) == 1)
        #expect(RoutePlanner.softwareGain(for: monitor, settings: .defaults) == 1)
    }
}
