import Foundation
import SopranoMixCore

/// Fake Macs for the snapshot harness and the tests: the processes Core Audio would list
/// (grouped by the real `AudioAppResolver`), the devices, and the settings.json values each
/// scenario starts with. Every id, pid and name is fixed except Soprano Mix's own pid,
/// which is the running process's, so the resolver excludes it like the live app.
enum FixtureScenario: String, CaseIterable {
    /// The laptop at a desk: Spotify, Safari, Discord on AirPods, TEKKEN 8 under
    /// CrossOver, Music muted, System Sounds idle.
    case standard
    /// Gaming on the Odyssey G91F (no hardware volume, software volume 50 %): Steam and
    /// TEKKEN 8 under CrossOver, Discord.
    case game
    /// 14 playing apps: the app list scrolls.
    case crowded
    /// Devices only, nothing connected: the empty state.
    case quiet

    /// Soprano Mix's own pid in every scenario: this process.
    static var ownPID: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// The alert (sound effects) volume the harness starts with.
    static let alertVolume: Double = 75

    /// The connected processes, ascending by object id.
    func processes(ownPID: Int32 = FixtureScenario.ownPID) -> [AudioProcessFacts] {
        let processes: [AudioProcessFacts]
        switch self {
        case .standard:
            processes = [
                FixtureProcesses.systemSounds(objectID: 120),
                FixtureProcesses.safariGPU(objectID: 131, playing: true),
                FixtureProcesses.spotify(objectID: 134, playing: true),
                FixtureProcesses.discordHelper(objectID: 140, pid: 2318, playing: true),
                FixtureProcesses.discordHelper(objectID: 141, pid: 2325, playing: false),
                FixtureProcesses.tekken(objectID: 152, playing: true),
                FixtureProcesses.music(objectID: 160, playing: false),
                FixtureProcesses.sopranoMix(objectID: 170, pid: ownPID),
            ]
        case .game:
            processes = [
                FixtureProcesses.discordHelper(objectID: 140, pid: 2318, playing: true),
                FixtureProcesses.discordHelper(objectID: 141, pid: 2325, playing: false),
                FixtureProcesses.steam(objectID: 150, playing: true),
                FixtureProcesses.tekken(objectID: 152, playing: true),
                FixtureProcesses.sopranoMix(objectID: 170, pid: ownPID),
            ]
        case .crowded:
            processes = FixtureProcesses.crowded + [FixtureProcesses.sopranoMix(objectID: 400, pid: ownPID)]
        case .quiet:
            processes = []
        }
        return processes.sorted { $0.objectID < $1.objectID }
    }

    /// The devices and the system's defaults.
    var devices: DeviceSnapshot {
        let devices = [
            FixtureAudioDevices.speakers,
            FixtureAudioDevices.airPods,
            FixtureAudioDevices.odyssey,
            FixtureAudioDevices.microphone,
            FixtureAudioDevices.streamCam,
        ].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        switch self {
        case .game:
            return DeviceSnapshot(
                devices: devices,
                defaultOutputUID: FixtureAudioDevices.odysseyUID,
                defaultInputUID: FixtureAudioDevices.microphoneUID,
                soundEffectsUID: FixtureAudioDevices.odysseyUID
            )
        case .standard, .crowded, .quiet:
            return DeviceSnapshot(
                devices: devices,
                defaultOutputUID: FixtureAudioDevices.speakersUID,
                defaultInputUID: FixtureAudioDevices.microphoneUID,
                soundEffectsUID: FixtureAudioDevices.speakersUID
            )
        }
    }

    /// The scenario's settings.json: defaults plus its `apps` and `outputs` values.
    var settings: SopranoMixSettings {
        var settings = SopranoMixSettings()
        switch self {
        case .standard:
            settings.apps = [
                FixtureKeys.spotify: AppAudioSettings(volume: 60),
                FixtureKeys.discord: AppAudioSettings(output: FixtureAudioDevices.airPodsUID),
                FixtureKeys.tekken: AppAudioSettings(volume: 35),
                FixtureKeys.music: AppAudioSettings(muted: true),
            ]
        case .game:
            settings.apps = [FixtureKeys.tekken: AppAudioSettings(volume: 35)]
            settings.outputs = [FixtureAudioDevices.odyssey.name: OutputVolumeSettings(volume: 50)]
        case .crowded:
            settings.apps = [
                FixtureKeys.spotify: AppAudioSettings(volume: 60),
                FixtureKeys.chrome: AppAudioSettings(volume: 150),
                FixtureKeys.slack: AppAudioSettings(muted: true),
                FixtureKeys.firefox: AppAudioSettings(output: FixtureAudioDevices.airPodsUID),
                FixtureKeys.tekken: AppAudioSettings(volume: 35),
            ]
        case .quiet:
            break
        }
        return settings
    }
}

/// The app keys the scenarios and tests refer to.
enum FixtureKeys {
    static let spotify = AppKey.bundle("com.spotify.client")
    static let safari = AppKey.bundle("com.apple.Safari")
    static let discord = AppKey.bundle("com.hnc.Discord")
    static let music = AppKey.bundle("com.apple.Music")
    static let tekken = AppKey.wine("TEKKEN 8")
    static let steam = AppKey.wine("Steam")
    static let systemSounds = AppKey.bundle("com.apple.systemsoundserverd")
    static let sopranoMix = AppKey.bundle("com.soprano.mix")
    static let chrome = AppKey.bundle("com.google.Chrome")
    static let slack = AppKey.bundle("com.tinyspeck.slackmacgap")
    static let firefox = AppKey.bundle("org.mozilla.firefox")
}

/// The fixture devices, with the UIDs Core Audio reports for them.
enum FixtureAudioDevices {
    static let speakersUID = "BuiltInSpeakerDevice"
    static let airPodsUID = "BC-80-4E-EC-D9-CC:output"
    static let odysseyUID = "4C2D6778-0000-0000-2823-0104B5772278_0C80D010"
    static let microphoneUID = "BuiltInMicrophoneDevice"
    static let streamCamUID = "AppleUSBAudioEngine:Unknown Manufacturer:Logitech StreamCam:C6532B16:3"

    /// Built in, hardware volume 62 %, balance.
    static let speakers = AudioDevice(
        objectID: 82, uid: speakersUID, name: "MacBook Pro Speakers", transport: .builtIn,
        outputChannels: 2, inputChannels: 0, outputVolume: 0.62, outputMuted: false, balance: 0.5,
        sampleRate: 48_000, sampleRates: [44_100, 48_000, 88_200, 96_000]
    )
    static let airPods = AudioDevice(
        objectID: 119, uid: airPodsUID, name: "Furkan's AirPods Pro", transport: .bluetooth,
        outputChannels: 2, inputChannels: 0, outputVolume: 0.5, outputMuted: false,
        sampleRate: 48_000, sampleRates: [48_000]
    )
    /// DisplayPort, no hardware volume or mute: software volume.
    static let odyssey = AudioDevice(
        objectID: 104, uid: odysseyUID, name: "Odyssey G91F", transport: .displayPort,
        outputChannels: 2, inputChannels: 0,
        sampleRate: 48_000, sampleRates: [32_000, 44_100, 48_000]
    )
    static let microphone = AudioDevice(
        objectID: 89, uid: microphoneUID, name: "MacBook Pro Microphone", transport: .builtIn,
        outputChannels: 0, inputChannels: 1, inputVolume: 0.8, inputMuted: false,
        sampleRate: 48_000, sampleRates: [44_100, 48_000, 88_200, 96_000]
    )
    static let streamCam = AudioDevice(
        objectID: 94, uid: streamCamUID, name: "Logitech StreamCam", transport: .usb,
        outputChannels: 0, inputChannels: 2, inputVolume: 1, inputMuted: false,
        sampleRate: 48_000, sampleRates: [16_000, 24_000, 32_000, 48_000]
    )
}

/// Process facts as `LiveAudioProcessSource` reports them for real apps.
enum FixtureProcesses {
    static let crossOverPath = "/Applications/CrossOver.app"
    static let winePreloader = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine-preloader"
    static let tekkenWindowsPath = #"C:\Program Files (x86)\Steam\steamapps\common\TEKKEN 8\Polaris\Binaries\Win64\Polaris-Win64-Shipping.exe"#
    static let steamWindowsPath = #"C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe"#
    static let webKitGPUPath = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"

    /// The CrossOver bottle the games run in.
    static var steamBottle: String {
        NSHomeDirectory() + "/Library/Application Support/CrossOver/Bottles/Steam"
    }

    static let safari = RunningAppInfo(pid: 812, bundleID: "com.apple.Safari", name: "Safari", bundlePath: "/Applications/Safari.app")
    static let discord = RunningAppInfo(pid: 2301, bundleID: "com.hnc.Discord", name: "Discord", bundlePath: "/Applications/Discord.app")
    static let crossOver = RunningAppInfo(pid: 7310, bundleID: "com.codeweavers.CrossOver", name: "CrossOver", bundlePath: crossOverPath)

    // MARK: Standard and game

    static func systemSounds(objectID: UInt32) -> AudioProcessFacts {
        AudioProcessFacts(
            objectID: objectID, pid: 389, bundleID: "com.apple.systemsoundserverd",
            executablePath: "/usr/libexec/systemsoundserverd", arguments: ["/usr/libexec/systemsoundserverd"]
        )
    }

    /// Safari plays through WebKit's GPU process, which reports Safari as responsible.
    static func safariGPU(objectID: UInt32, playing: Bool) -> AudioProcessFacts {
        AudioProcessFacts(
            objectID: objectID, pid: 813, bundleID: "com.apple.WebKit.GPU",
            executablePath: webKitGPUPath, arguments: [webKitGPUPath],
            responsible: safari, isRunningOutput: playing
        )
    }

    static func spotify(objectID: UInt32, playing: Bool) -> AudioProcessFacts {
        bundledApp(objectID: objectID, pid: 4120, bundleID: "com.spotify.client", name: "Spotify",
                   bundlePath: "/Applications/Spotify.app", executable: "Spotify", playing: playing)
    }

    static func music(objectID: UInt32, playing: Bool) -> AudioProcessFacts {
        bundledApp(objectID: objectID, pid: 1544, bundleID: "com.apple.Music", name: "Music",
                   bundlePath: "/System/Applications/Music.app", executable: "Music", playing: playing)
    }

    /// One of Discord's Electron renderer helpers; Discord is responsible for it.
    static func discordHelper(objectID: UInt32, pid: Int32, playing: Bool) -> AudioProcessFacts {
        let path = "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)"
        return AudioProcessFacts(
            objectID: objectID, pid: pid, bundleID: "com.hnc.Discord.helper",
            executablePath: path, arguments: [path, "--type=renderer"],
            responsible: discord,
            enclosingApp: RunningAppInfo(pid: nil, bundleID: "com.hnc.Discord", name: "Discord", bundlePath: "/Applications/Discord.app"),
            isRunningOutput: playing
        )
    }

    static func tekken(objectID: UInt32, playing: Bool) -> AudioProcessFacts {
        wineProcess(objectID: objectID, pid: 7402, windowsPath: tekkenWindowsPath, playing: playing)
    }

    static func steam(objectID: UInt32, playing: Bool) -> AudioProcessFacts {
        wineProcess(objectID: objectID, pid: 7380, windowsPath: steamWindowsPath, playing: playing)
    }

    /// A Windows program under CrossOver: Wine's loader inside CrossOver.app, the Windows
    /// path in argv[0], CrossOver responsible.
    static func wineProcess(objectID: UInt32, pid: Int32, windowsPath: String, playing: Bool) -> AudioProcessFacts {
        AudioProcessFacts(
            objectID: objectID, pid: pid, bundleID: "com.codeweavers.CrossOver.wineloader",
            executablePath: winePreloader, arguments: [windowsPath],
            wineprefix: steamBottle,
            responsible: crossOver,
            enclosingApp: RunningAppInfo(pid: nil, bundleID: crossOver.bundleID, name: crossOver.name, bundlePath: crossOverPath),
            isRunningOutput: playing
        )
    }

    /// Soprano Mix itself (it plays its routes' audio); the resolver drops it by pid.
    static func sopranoMix(objectID: UInt32, pid: Int32) -> AudioProcessFacts {
        bundledApp(objectID: objectID, pid: pid, bundleID: "com.soprano.mix", name: "Soprano Mix",
                   bundlePath: "/Applications/Soprano Mix.app", executable: "SopranoMix", playing: true)
    }

    /// An app playing from its own main process.
    static func bundledApp(objectID: UInt32, pid: Int32, bundleID: String, name: String, bundlePath: String,
                           executable: String, playing: Bool) -> AudioProcessFacts {
        let path = bundlePath + "/Contents/MacOS/" + executable
        return AudioProcessFacts(
            objectID: objectID, pid: pid, bundleID: bundleID,
            executablePath: path, arguments: [path],
            enclosingApp: RunningAppInfo(pid: nil, bundleID: bundleID, name: name, bundlePath: bundlePath),
            ownApp: RunningAppInfo(pid: pid, bundleID: bundleID, name: name, bundlePath: bundlePath),
            isRunningOutput: playing
        )
    }

    /// A helper process folded into its app through the responsible pid.
    static func helper(objectID: UInt32, pid: Int32, bundleID: String, path: String, app: RunningAppInfo) -> AudioProcessFacts {
        AudioProcessFacts(
            objectID: objectID, pid: pid, bundleID: bundleID,
            executablePath: path, arguments: [path],
            responsible: app,
            enclosingApp: RunningAppInfo(pid: nil, bundleID: app.bundleID, name: app.name, bundlePath: app.bundlePath),
            isRunningOutput: true
        )
    }

    // MARK: Crowded

    /// 14 playing apps: bundled apps, helpers, WebKit, an unbundled program and a game.
    static var crowded: [AudioProcessFacts] {
        let chrome = RunningAppInfo(pid: 3100, bundleID: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app")
        let slack = RunningAppInfo(pid: 3200, bundleID: "com.tinyspeck.slackmacgap", name: "Slack", bundlePath: "/Applications/Slack.app")
        let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/155.0.8059.86/Helpers/Google Chrome Helper (Aperitif).app/Contents/MacOS/Google Chrome Helper (Aperitif)"
        let slackHelper = "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"
        return [
            spotify(objectID: 300, playing: true),
            safariGPU(objectID: 301, playing: true),
            discordHelper(objectID: 302, pid: 2318, playing: true),
            music(objectID: 303, playing: true),
            helper(objectID: 304, pid: 3104, bundleID: "com.google.Chrome.helper", path: chromeHelper, app: chrome),
            helper(objectID: 305, pid: 3207, bundleID: "com.tinyspeck.slackmacgap.helper", path: slackHelper, app: slack),
            bundledApp(objectID: 306, pid: 3300, bundleID: "us.zoom.xos", name: "zoom.us",
                       bundlePath: "/Applications/zoom.us.app", executable: "zoom.us", playing: true),
            bundledApp(objectID: 307, pid: 3400, bundleID: "com.microsoft.teams2", name: "Microsoft Teams",
                       bundlePath: "/Applications/Microsoft Teams.app", executable: "MSTeams", playing: true),
            bundledApp(objectID: 308, pid: 3500, bundleID: "org.mozilla.firefox", name: "Firefox",
                       bundlePath: "/Applications/Firefox.app", executable: "firefox", playing: true),
            bundledApp(objectID: 309, pid: 3600, bundleID: "org.videolan.vlc", name: "VLC",
                       bundlePath: "/Applications/VLC.app", executable: "VLC", playing: true),
            bundledApp(objectID: 310, pid: 3700, bundleID: "com.colliderli.iina", name: "IINA",
                       bundlePath: "/Applications/IINA.app", executable: "IINA", playing: true),
            bundledApp(objectID: 311, pid: 3800, bundleID: "com.apple.podcasts", name: "Podcasts",
                       bundlePath: "/System/Applications/Podcasts.app", executable: "Podcasts", playing: true),
            AudioProcessFacts(
                objectID: 312, pid: 3900, executablePath: "/usr/bin/afplay",
                arguments: ["afplay", "/Users/furkan/Music/take-five.m4a"], isRunningOutput: true
            ),
            tekken(objectID: 313, playing: true),
        ]
    }
}

// MARK: - settings.json in memory

/// One JSON value of a settings write.
enum SettingValue: Equatable, Encodable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case null

    /// Bool, Int, Double, String or NSNull as `SettingsEditor` takes them; anything else
    /// by its description.
    init(_ value: Any) {
        if let string = value as? String {
            self = .string(string)
        } else if type(of: value) == Bool.self, let bool = value as? Bool {
            self = .bool(bool)
        } else if let int = value as? Int {
            self = .number(Double(int))
        } else if let double = value as? Double {
            self = .number(double)
        } else if value is NSNull {
            self = .null
        } else {
            self = .string(String(describing: value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(bool): try container.encode(bool)
        case let .number(number): try container.encode(number)
        case let .string(string): try container.encode(string)
        case .null: try container.encodeNil()
        }
    }
}

/// One `writeSetting` call.
struct SettingsWrite: Equatable, Encodable {
    var path: [String]
    var value: SettingValue
}

/// settings.json in memory for the harness and the tests: every `writeSetting` is
/// recorded and applied as if the written file had been reloaded.
@MainActor
final class FixtureSettingsStore {
    /// What `environment.settings()` returns; assign to simulate an edit of the file.
    var settings: SopranoMixSettings
    /// Every successful write, in order.
    private(set) var writes: [SettingsWrite] = []
    /// Simulates a settings.json that cannot be written (e.g. it does not parse).
    var failsWrites = false
    /// Writes refused while `failsWrites`.
    private(set) var failedWriteCount = 0

    init(settings: SopranoMixSettings) {
        self.settings = settings
    }

    /// False (and nothing changes) while `failsWrites`.
    @discardableResult
    func write(_ value: Any, at path: [String]) -> Bool {
        guard !failsWrites else {
            failedWriteCount += 1
            return false
        }
        let value = SettingValue(value)
        writes.append(SettingsWrite(path: path, value: value))
        settings = Self.applying(value, at: path, to: settings)
        return true
    }

    /// `settings` with one written value applied like `SettingsResolver` would read it
    /// (volumes clamped, "default" output meaning the system output). Paths the mixer
    /// never writes leave the settings unchanged.
    static func applying(_ value: SettingValue, at path: [String], to settings: SopranoMixSettings) -> SopranoMixSettings {
        var settings = settings
        if path.count == 3, path[0] == "apps", !path[1].isEmpty {
            let key = AppKey(rawValue: path[1])
            var audio = settings.audio(for: key)
            switch (path[2], value) {
            case let ("volume", .number(number)):
                audio.volume = min(max(number, VolumeLaw.appRange.lowerBound), VolumeLaw.appRange.upperBound)
            case let ("muted", .bool(muted)):
                audio.muted = muted
            case let ("output", .string(output)):
                audio.output = output.isEmpty || output.caseInsensitiveCompare("default") == .orderedSame ? nil : output
            case ("output", .null):
                audio.output = nil
            default:
                return settings
            }
            settings.apps[key] = audio
        } else if path.count == 3, path[0] == "outputs", !path[1].isEmpty {
            var output = settings.outputs[path[1]] ?? .default
            switch (path[2], value) {
            case let ("volume", .number(number)):
                output.volume = min(max(number, VolumeLaw.outputRange.lowerBound), VolumeLaw.outputRange.upperBound)
            case let ("muted", .bool(muted)):
                output.muted = muted
            default:
                return settings
            }
            settings.outputs[path[1]] = output
        } else {
            switch (path.joined(separator: "."), value) {
            case let ("panel.meters", .bool(on)): settings.panel.meters = on
            case let ("volumeKeys.anyOutput", .bool(on)): settings.volumeKeys.anyOutput = on
            case let ("volumeKeys.hud", .bool(on)): settings.volumeKeys.hud = on
            case let ("audio.limiter", .bool(on)): settings.audio.limiter = on
            case let ("app.startAtLogin", .bool(on)): settings.app.startAtLogin = on
            case let ("theme", .string(theme)): settings.theme = theme
            default: break
            }
        }
        return settings
    }
}
