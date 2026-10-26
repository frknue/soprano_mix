import AppKit
import Testing
@testable import SopranoMixCore

struct AudioAppResolverTests {
    private let ownPID: Int32 = 900

    private let chrome = RunningAppInfo(pid: 54855, bundleID: "com.google.Chrome", name: "Google Chrome",
                                        bundlePath: "/Applications/Google Chrome.app")
    private let orbStack = RunningAppInfo(pid: 15749, bundleID: "dev.kdrag0n.MacVirt", name: "OrbStack",
                                          bundlePath: "/Applications/OrbStack.app")
    private let crossOver = RunningAppInfo(pid: 76000, bundleID: "com.codeweavers.CrossOver", name: "CrossOver",
                                           bundlePath: "/Applications/CrossOver.app")
    private let ghostty = RunningAppInfo(pid: 4000, bundleID: "com.mitchellh.ghostty", name: "Ghostty",
                                         bundlePath: "/Applications/Ghostty.app")
    private let tekkenPath = #"C:\Program Files (x86)\Steam\steamapps\common\TEKKEN 8\Polaris\Binaries\Win64\Polaris-Win64-Shipping.exe"#
    private let wineLoader = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine64-preloader"

    private func chromeHelper(object: UInt32, pid: Int32, playing: Bool) -> AudioProcessFacts {
        AudioProcessFacts(
            objectID: object,
            pid: pid,
            bundleID: "com.google.Chrome.helper",
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/155.0.8059.86/Helpers/Google Chrome Helper (Aperitif).app/Contents/MacOS/Google Chrome Helper (Aperitif)",
            responsible: chrome,
            enclosingApp: RunningAppInfo(pid: nil, bundleID: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app"),
            ownApp: RunningAppInfo(pid: pid, bundleID: "com.google.Chrome.helper", name: "Google Chrome Helper (Aperitif)", bundlePath: nil),
            isRunningOutput: playing
        )
    }

    private var chromeMain: AudioProcessFacts {
        AudioProcessFacts(
            objectID: 168,
            pid: 54855,
            bundleID: "com.google.Chrome",
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            enclosingApp: RunningAppInfo(pid: nil, bundleID: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app"),
            ownApp: chrome
        )
    }

    private var tekken: AudioProcessFacts {
        AudioProcessFacts(
            objectID: 179,
            pid: 76333,
            bundleID: "com.codeweavers.CrossOver.wineloader",
            executablePath: wineLoader,
            arguments: [tekkenPath, "-dx12"],
            wineprefix: "/Users/f/Library/Application Support/CrossOver/Bottles/Steam",
            responsible: crossOver,
            enclosingApp: RunningAppInfo(pid: nil, bundleID: "com.codeweavers.CrossOver", name: "CrossOver", bundlePath: "/Applications/CrossOver.app"),
            isRunningOutput: true
        )
    }

    @Test("a Chrome helper folds into Chrome through its responsible app")
    func chromeHelperFolds() {
        let identity = AudioAppResolver.identity(for: chromeHelper(object: 169, pid: 65904, playing: true), ownPID: ownPID)
        #expect(identity == AppIdentity(key: .bundle("com.google.Chrome"), name: "Google Chrome", kind: .app,
                                        icon: .bundle(path: "/Applications/Google Chrome.app")))
    }

    @Test("WebKit's GPU process belongs to the app embedding WebKit")
    func webKitGPU() {
        let gpu = AudioProcessFacts(
            objectID: 159,
            pid: 53557,
            bundleID: "com.apple.WebKit.GPU",
            executablePath: "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
            responsible: orbStack,
            ownApp: RunningAppInfo(pid: 53557, bundleID: "com.apple.WebKit.GPU", name: "com.apple.WebKit.GPU", bundlePath: nil)
        )
        let identity = AudioAppResolver.identity(for: gpu, ownPID: ownPID)
        #expect(identity?.key == .bundle("dev.kdrag0n.MacVirt"))
        #expect(identity?.name == "OrbStack")
        #expect(identity?.kind == .app)
    }

    @Test("a Wine game under CrossOver is its own app, never CrossOver")
    func wineGame() {
        let identity = AudioAppResolver.identity(for: tekken, ownPID: ownPID)
        #expect(identity == AppIdentity(
            key: .wine("TEKKEN 8"),
            name: "TEKKEN 8",
            kind: .wine,
            icon: .windowsExecutable(windowsPath: tekkenPath, wineprefix: "/Users/f/Library/Application Support/CrossOver/Bottles/Steam")
        ))
    }

    @Test("a Windows executable path counts when argv is unreadable")
    func wineExecutablePath() {
        let process = AudioProcessFacts(objectID: 5, pid: 5, executablePath: #"C:\Games\Doom\doom.exe"#, responsible: crossOver)
        #expect(AudioAppResolver.identity(for: process, ownPID: ownPID)?.key == .wine("doom"))
    }

    @Test("Steam's web helper under Wine is Steam")
    func steamWebHelper() {
        let helper = AudioProcessFacts(
            objectID: 180,
            pid: 76400,
            bundleID: "com.codeweavers.CrossOver.wineloader",
            executablePath: wineLoader,
            arguments: [#"C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe"#, "--type=renderer"],
            responsible: crossOver
        )
        let identity = AudioAppResolver.identity(for: helper, ownPID: ownPID)
        #expect(identity?.key == .wine("Steam"))
        #expect(identity?.name == "Steam")
        #expect(identity?.kind == .wine)
    }

    @Test("afplay started from a terminal stays afplay")
    func unbundledProgram() {
        let afplay = AudioProcessFacts(objectID: 190, pid: 81000, executablePath: "/usr/bin/afplay",
                                       arguments: ["afplay", "/tmp/tone.wav"], responsible: ghostty, isRunningOutput: true)
        #expect(AudioAppResolver.identity(for: afplay, ownPID: ownPID)
            == AppIdentity(key: .executable("afplay"), name: "afplay", kind: .executable, icon: .executable(path: "/usr/bin/afplay")))

        let unreadable = AudioProcessFacts(objectID: 191, pid: 81001, arguments: ["/opt/homebrew/bin/mpv"])
        #expect(AudioAppResolver.identity(for: unreadable, ownPID: ownPID)?.key == .executable("mpv"))
        let anonymous = AudioProcessFacts(objectID: 192, pid: 81002)
        #expect(AudioAppResolver.identity(for: anonymous, ownPID: ownPID)?.name == "pid 81002")
    }

    @Test("system processes get friendly names and symbols")
    func systemProcesses() {
        let sounds = AudioProcessFacts(objectID: 138, pid: 340, bundleID: "com.apple.systemsoundserverd",
                                       executablePath: "/usr/libexec/systemsoundserverd")
        #expect(AudioAppResolver.identity(for: sounds, ownPID: ownPID)
            == AppIdentity(key: .bundle("com.apple.systemsoundserverd"), name: "System Sounds", kind: .system, icon: .symbol("bell")))

        let siri = AudioProcessFacts(objectID: 149, pid: 51626, bundleID: "com.apple.assistantd",
                                     executablePath: "/System/Library/PrivateFrameworks/AssistantServices.framework/Versions/A/Support/assistantd")
        #expect(AudioAppResolver.identity(for: siri, ownPID: ownPID)
            == AppIdentity(key: .bundle("com.apple.assistantd"), name: "Siri", kind: .system, icon: .symbol("waveform")))

        let replay = AudioProcessFacts(objectID: 157, pid: 51550, bundleID: "com.apple.replayd", executablePath: "/usr/libexec/replayd")
        #expect(AudioAppResolver.identity(for: replay, ownPID: ownPID)
            == AppIdentity(key: .bundle("com.apple.replayd"), name: "replayd", kind: .system, icon: .symbol("speaker.wave.2")))
    }

    @Test("an app bundle process without a running app folds into its enclosing app")
    func enclosingApp() {
        let process = AudioProcessFacts(
            objectID: 155,
            pid: 73314,
            bundleID: "net.whatsapp.WhatsApp.ServiceExtension",
            executablePath: "/Applications/WhatsApp.app/Contents/PlugIns/ServiceExtension.appex/Contents/MacOS/ServiceExtension",
            enclosingApp: RunningAppInfo(pid: nil, bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", bundlePath: "/Applications/WhatsApp.app")
        )
        #expect(AudioAppResolver.identity(for: process, ownPID: ownPID)
            == AppIdentity(key: .bundle("net.whatsapp.WhatsApp"), name: "WhatsApp", kind: .app, icon: .bundle(path: "/Applications/WhatsApp.app")))
    }

    @Test("Soprano Mix's own process is excluded")
    func ownProcessExcluded() {
        let own = AudioProcessFacts(objectID: 200, pid: ownPID, bundleID: "com.soprano.mix",
                                    ownApp: RunningAppInfo(pid: ownPID, bundleID: "com.soprano.mix", name: "Soprano Mix", bundlePath: nil),
                                    isRunningOutput: true)
        #expect(AudioAppResolver.identity(for: own, ownPID: ownPID) == nil)
        #expect(AudioAppResolver.apps(from: [own], ownPID: ownPID).isEmpty)
    }

    @Test("helpers group under the main app's name and icon with sorted unique ids")
    func groupingKeepsMainApp() {
        let processes = [
            chromeHelper(object: 170, pid: 65905, playing: false),
            chromeHelper(object: 169, pid: 65904, playing: true),
            chromeMain,
            chromeHelper(object: 169, pid: 65904, playing: true),
        ]
        let apps = AudioAppResolver.apps(from: processes, ownPID: ownPID)
        #expect(apps.count == 1)
        let app = apps.first
        #expect(app?.key == .bundle("com.google.Chrome"))
        #expect(app?.name == "Google Chrome")
        #expect(app?.icon == .bundle(path: "/Applications/Google Chrome.app"))
        #expect(app?.processObjectIDs == [168, 169, 170])
        #expect(app?.pids == [54855, 65904, 65905])
        #expect(app?.isPlaying == true)
    }

    @Test("without the app itself the lowest pid names the group")
    func lowestPIDNamesGroup() {
        let high = AudioProcessFacts(objectID: 1, pid: 300, bundleID: "a.helper",
                                     responsible: RunningAppInfo(pid: 100, bundleID: "a.app", name: "Later Name", bundlePath: nil))
        let low = AudioProcessFacts(objectID: 2, pid: 200, bundleID: "a.helper",
                                    responsible: RunningAppInfo(pid: 100, bundleID: "a.app", name: "Earlier Name", bundlePath: nil))
        let apps = AudioAppResolver.apps(from: [high, low], ownPID: ownPID)
        #expect(apps.map(\.name) == ["Earlier Name"])
        #expect(apps.first?.icon == .runningApp(pid: 100))
        #expect(apps.first?.isPlaying == false)
    }

    @Test("apps sort by name, then key, and Wine games list beside macOS apps")
    func sorting() {
        let processes = [
            tekken,
            chromeMain,
            AudioProcessFacts(objectID: 190, pid: 81000, executablePath: "/usr/bin/afplay"),
            AudioProcessFacts(objectID: 191, pid: 81001, bundleID: "z.second", ownApp: RunningAppInfo(pid: 81001, bundleID: "z.second", name: "Same", bundlePath: nil)),
            AudioProcessFacts(objectID: 192, pid: 81002, bundleID: "a.first", ownApp: RunningAppInfo(pid: 81002, bundleID: "a.first", name: "Same", bundlePath: nil)),
            AudioProcessFacts(objectID: 193, pid: 81003, bundleID: "com.apple.systemsoundserverd", executablePath: "/usr/libexec/systemsoundserverd"),
        ]
        let apps = AudioAppResolver.apps(from: processes, ownPID: ownPID)
        #expect(apps.map(\.key.rawValue) == ["exe:afplay", "com.google.Chrome", "a.first", "z.second", "com.apple.systemsoundserverd", "wine:TEKKEN 8"])
    }
}
