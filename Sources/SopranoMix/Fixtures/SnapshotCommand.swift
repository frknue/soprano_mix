import AppKit
import SopranoMixCore

/// What a snapshot run ended with, written by `--report` for agents to check behavior
/// without reading pixels.
struct SnapshotReport: Equatable, Encodable {
    /// One listed app as the controller sees it after the actions.
    struct App: Equatable, Encodable {
        var key: String
        var name: String
        var volume: Double
        var muted: Bool
        /// The settings value (device UID or name); null follows the system output.
        var output: String?
        /// The device the app plays on now.
        var outputName: String?
        var playing: Bool

        private enum CodingKeys: String, CodingKey {
            case key, name, volume, muted, output, outputName, playing
        }

        /// Writes missing values as `null` instead of omitting them.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key)
            try container.encode(name, forKey: .name)
            try container.encode(volume, forKey: .volume)
            try container.encode(muted, forKey: .muted)
            try container.encode(output, forKey: .output)
            try container.encode(outputName, forKey: .outputName)
            try container.encode(playing, forKey: .playing)
        }
    }

    struct Route: Equatable, Encodable {
        var key: String
        /// "replace" or "meter".
        var mode: String
        /// Linear, to 4 decimals.
        var gain: Double
        var limiter: Bool
        /// The output device's name (its UID when unknown).
        var device: String
        var deviceUID: String
        var processObjectIDs: [UInt32]
    }

    struct Master: Equatable, Encodable {
        var device: String
        var deviceUID: String
        var gain: Double
        var excludedProcessObjectIDs: [UInt32]
    }

    struct Plan: Equatable, Encodable {
        var routes: [Route]
        var master: Master?

        private enum CodingKeys: String, CodingKey {
            case routes, master
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(routes, forKey: .routes)
            try container.encode(master, forKey: .master)
        }
    }

    struct HUD: Equatable, Encodable {
        var deviceName: String
        var level: Double
        var isMuted: Bool
        var caption: String
    }

    var apps: [App]
    var plan: Plan
    /// Every `writeSetting`, in order.
    var settingsWrites: [SettingsWrite]
    /// The HUD's last model while it shows; null otherwise.
    var hud: HUD?

    static let empty = SnapshotReport(apps: [], plan: Plan(routes: [], master: nil), settingsWrites: [], hud: nil)

    private enum CodingKeys: String, CodingKey {
        case apps, plan, settingsWrites, hud
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apps, forKey: .apps)
        try container.encode(plan, forKey: .plan)
        try container.encode(settingsWrites, forKey: .settingsWrites)
        try container.encode(hud, forKey: .hud)
    }

    /// Pretty-printed JSON with sorted keys.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// `SopranoMix snapshot --out <png> …` (see `usage`).
///
/// Runs the real `MixerController`, `MixPanelWindow` and `VolumeHUD` on a fixture scenario
/// with an immediate scheduler, offscreen: no Dock icon, no activation, no persisted
/// state, no permission. Shows the panel, replays `--actions`, optionally feeds fixed
/// meter levels, then writes the panel (or the HUD, or the permissions window) as a PNG
/// and the report as JSON.
@MainActor
enum SnapshotCommand {
    /// One `--actions` token.
    enum Action: Equatable {
        /// `volume:<app>=<pct>`.
        case volume(app: String, percent: Double)
        /// `mute:<app>` toggles.
        case mute(app: String)
        /// `output:<app>=<device|default>`; nil follows the system output.
        case output(app: String, device: String?)
        /// `device:<output|input|effects>=<device>`.
        case device(role: DeviceRole, name: String)
        /// `devvolume:<output|input|effects>=<pct>`.
        case deviceVolume(role: DeviceRole, percent: Double)
        /// `keyUp`, `keyDown`, `keyMute`: one press and release.
        case key(VolumeKey)
    }

    struct Options: Equatable {
        var out: URL
        var scenario: FixtureScenario = .standard
        var theme: String?
        var settings: URL?
        var capture: CaptureStatus = .granted
        var levels = false
        var actions: [Action] = []
        var hud = false
        var onboarding = false
        /// `--permissions` (with `--onboarding`).
        var permissionCapture: CaptureStatus = .notDetermined
        var accessibilityGranted = false
        var report: URL?
    }

    enum OptionError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case unknownOption(String)
        case missingOut
        case badScenario(String)
        case badCapture(String)
        case badAction(String)
        case badPermissions(String)
        case permissionsWithoutOnboarding

        var description: String {
            switch self {
            case let .missingValue(option): "\(option) needs a value"
            case let .unknownOption(option): "unknown option \(option)"
            case .missingOut: "--out <png> is required"
            case let .badScenario(value):
                "--scenario must be one of \(FixtureScenario.allCases.map(\.rawValue).joined(separator: ", ")), got \(value)"
            case let .badCapture(value): "--capture must be granted, notDetermined or denied, got \(value)"
            case let .badAction(token):
                "unknown action \"\(token)\" (use volume:<app>=<0-400>, mute:<app>, output:<app>=<device|default>, "
                    + "device:<output|input|effects>=<device>, devvolume:<output|input|effects>=<0-100>, keyUp, keyDown, keyMute)"
            case let .badPermissions(value):
                "--permissions must be capture=granted|notDetermined|denied,accessibility=granted|missing, got \(value)"
            case .permissionsWithoutOnboarding: "--permissions needs --onboarding"
            }
        }
    }

    struct RenderError: Error, CustomStringConvertible {
        var description: String
    }

    nonisolated static let usage = """
    usage: SopranoMix snapshot --out <png> [--scenario standard|game|crowded|quiet] [--theme <id>]
                               [--settings <jsonc>] [--capture granted|notDetermined|denied] [--levels]
                               [--actions "<action> …"] [--hud]
                               [--onboarding [--permissions capture=granted|notDetermined|denied,accessibility=granted|missing]]
                               [--report <json>]
      actions: volume:<app>=<0-400> mute:<app> output:<app>=<device|default>
               device:<output|input|effects>=<device> devvolume:<output|input|effects>=<0-100>
               keyUp keyDown keyMute
      <app> as the CLI matches it (name, prefix or key), <device> by name; quote names with
      spaces: output:Discord="MacBook Pro Speakers"
    """

    // MARK: - Options

    /// The options after `snapshot` (a leading "snapshot" is skipped).
    nonisolated static func parse(_ commandLine: [String]) throws -> Options {
        let arguments = commandLine.first == "snapshot" ? Array(commandLine.dropFirst()) : commandLine
        var out: URL?
        var options = Options(out: URL(fileURLWithPath: "/dev/null"))
        var sawPermissions = false
        var index = 0
        func value(_ option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw OptionError.missingValue(option) }
            return arguments[index]
        }
        func fileURL(_ path: String) -> URL {
            URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
        }
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--out": out = fileURL(try value(option))
            case "--report": options.report = fileURL(try value(option))
            case "--settings": options.settings = fileURL(try value(option))
            case "--theme": options.theme = try value(option)
            case "--levels": options.levels = true
            case "--hud": options.hud = true
            case "--onboarding": options.onboarding = true
            case "--scenario":
                let text = try value(option)
                guard let scenario = FixtureScenario(rawValue: text) else { throw OptionError.badScenario(text) }
                options.scenario = scenario
            case "--capture":
                let text = try value(option)
                guard let status = captureStatus(text) else { throw OptionError.badCapture(text) }
                options.capture = status
            case "--actions":
                options.actions = try actionTokens(try value(option)).map(action)
            case "--permissions":
                let text = try value(option)
                let granted = try permissions(text)
                options.permissionCapture = granted.capture
                options.accessibilityGranted = granted.accessibility
                sawPermissions = true
            default:
                throw OptionError.unknownOption(option)
            }
            index += 1
        }
        guard let out else { throw OptionError.missingOut }
        if sawPermissions, !options.onboarding { throw OptionError.permissionsWithoutOnboarding }
        options.out = out
        return options
    }

    /// granted | notDetermined | denied, any case.
    private nonisolated static func captureStatus(_ text: String) -> CaptureStatus? {
        switch text.lowercased() {
        case "granted": .granted
        case "notdetermined": .notDetermined
        case "denied": .denied
        default: nil
        }
    }

    /// Splits at whitespace outside double quotes; the quotes themselves are dropped.
    nonisolated static func actionTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if character.isWhitespace, !inQuotes {
                if hasToken { tokens.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    nonisolated static func action(_ token: String) throws -> Action {
        switch token.lowercased() {
        case "keyup": return .key(.up)
        case "keydown": return .key(.down)
        case "keymute": return .key(.mute)
        default: break
        }
        guard let colon = token.firstIndex(of: ":") else { throw OptionError.badAction(token) }
        let verb = token[..<colon].lowercased()
        let argument = String(token[token.index(after: colon)...])
        /// "<left>=<right>" split at the last "=", both sides non-empty.
        func pair() throws -> (String, String) {
            guard let equals = argument.lastIndex(of: "=") else { throw OptionError.badAction(token) }
            let left = String(argument[..<equals]).trimmingCharacters(in: .whitespaces)
            let right = String(argument[argument.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !left.isEmpty, !right.isEmpty else { throw OptionError.badAction(token) }
            return (left, right)
        }
        func percent(_ text: String, in range: ClosedRange<Double>) throws -> Double {
            guard let value = Double(text), range.contains(value) else { throw OptionError.badAction(token) }
            return value
        }
        func role(_ text: String) throws -> DeviceRole {
            switch text.lowercased() {
            case "output": return .output
            case "input": return .input
            case "effects", "soundeffects": return .soundEffects
            default: throw OptionError.badAction(token)
            }
        }
        switch verb {
        case "volume":
            let (app, value) = try pair()
            return .volume(app: app, percent: try percent(value, in: VolumeLaw.appRange))
        case "mute":
            let app = argument.trimmingCharacters(in: .whitespaces)
            guard !app.isEmpty else { throw OptionError.badAction(token) }
            return .mute(app: app)
        case "output":
            let (app, device) = try pair()
            return .output(app: app, device: device.lowercased() == "default" ? nil : device)
        case "device":
            let (name, device) = try pair()
            return .device(role: try role(name), name: device)
        case "devvolume":
            let (name, value) = try pair()
            return .deviceVolume(role: try role(name), percent: try percent(value, in: VolumeLaw.outputRange))
        default:
            throw OptionError.badAction(token)
        }
    }

    /// "capture=granted,accessibility=missing"; omitted entries keep notDetermined / missing.
    private nonisolated static func permissions(_ text: String) throws -> (capture: CaptureStatus, accessibility: Bool) {
        var capture = CaptureStatus.notDetermined
        var accessibility = false
        for entry in text.split(separator: ",") {
            let pair = entry.split(separator: "=", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2 else { throw OptionError.badPermissions(text) }
            switch pair[0].lowercased() {
            case "capture":
                guard let status = captureStatus(pair[1]) else { throw OptionError.badPermissions(text) }
                capture = status
            case "accessibility":
                switch pair[1].lowercased() {
                case "granted": accessibility = true
                case "missing": accessibility = false
                default: throw OptionError.badPermissions(text)
                }
            default:
                throw OptionError.badPermissions(text)
            }
        }
        return (capture, accessibility)
    }

    // MARK: - Running

    /// `arguments` excludes the executable: ["snapshot", "--out", "/tmp/mix.png"].
    static func run(arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n\(usage)\n".utf8))
            return 2
        }
        // In-memory registration domain only: nothing is written to the user's defaults.
        UserDefaults.standard.register(defaults: [
            "ApplePersistenceIgnoreState": true,
            "NSQuitAlwaysKeepsWindows": false,
        ])
        let app = NSApplication.shared
        // No Dock icon, no menu bar, never activated: nothing appears on the user's screen.
        app.setActivationPolicy(.prohibited)
        do {
            let result = try render(options)
            try writePNG(result.image, to: options.out)
            if let reportURL = options.report {
                try createParentDirectory(of: reportURL)
                try result.report.jsonData().write(to: reportURL)
            }
            print(options.out.path)
            return 0
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            return 1
        }
    }

    /// Mutable state the environment closures share.
    private final class HarnessState {
        var alertVolume: Double? = FixtureScenario.alertVolume
    }

    /// The testable core: the rendered image (2x) and the report.
    static func render(_ options: Options) throws -> (image: CGImage, report: SnapshotReport) {
        let (settings, issueCount) = try resolveSettings(options)
        let theme = harnessTheme(settings.theme)
        // Popovers and text the theme does not draw follow the app's appearance; restore it
        // afterwards so callers in the same process (tests) keep their own.
        let previousAppearance = NSApplication.shared.appearance
        NSApplication.shared.appearance = theme.appearance.nsAppearance
        defer { NSApplication.shared.appearance = previousAppearance }
        MixPanelWindow.offscreen = true
        VolumeHUD.offscreen = true

        if options.onboarding {
            let status = PermissionStatus(capture: options.permissionCapture, accessibility: options.accessibilityGranted)
            let controller = PermissionsWindowController(status: { status }, theme: theme)
            guard let image = controller.renderImage() else {
                throw RenderError(description: "the permissions window did not render")
            }
            return (image, .empty)
        }

        let processes = FixtureProcessSource(scenario: options.scenario)
        let devices = FixtureDevices(scenario: options.scenario)
        let router = RecordingRouter()
        let panel = MixPanelWindow()
        let hud = VolumeHUD()
        let store = FixtureSettingsStore(settings: settings)
        let state = HarnessState()
        let capture = options.capture
        let environment = MixerEnvironment(
            settings: { store.settings },
            settingsIssueCount: { issueCount },
            theme: { theme },
            writeSetting: { value, path in store.write(value, at: path) },
            schedule: { _, work in work() },
            // The harness draws one meter frame itself (`tickMeters`), after the levels.
            scheduleRepeating: { _, _ in {} },
            now: { 0 },
            ownPID: FixtureScenario.ownPID,
            captureStatus: { capture },
            // The harness never prompts: the request answers with the given status.
            requestCapture: { done in done(capture) },
            alertVolume: { state.alertVolume },
            setAlertVolume: { state.alertVolume = $0 },
            openSettingsFile: {},
            showAppMenu: { _ in }
        )
        let controller = MixerController(
            processes: processes,
            devices: devices,
            router: router,
            icons: FixtureIcons(),
            panel: panel,
            hud: hud,
            environment: environment
        )
        controller.start()
        if !options.hud {
            controller.showPanel(anchor: nil)
        }

        for action in options.actions {
            try apply(action, to: controller, devices: devices.snapshot)
            // The written settings.json reloads.
            controller.settingsDidChange()
        }

        if options.levels {
            router.levels = fixedLevels(for: controller.listedApps)
            controller.tickMeters()
        }

        let rendered = options.hud ? hud.renderSnapshot(scale: 2) : panel.renderSnapshot(scale: 2)
        guard let image = rendered else {
            throw RenderError(description: options.hud
                ? "the HUD is not showing: --hud needs keyUp, keyDown or keyMute on an output without hardware volume (e.g. --scenario game)"
                : "the panel did not render")
        }
        let report = makeReport(controller: controller, devices: devices.snapshot, writes: store.writes, hud: hud.current)
        return (image, report)
    }

    /// The harness resolves themes against a light system appearance, so it never reads
    /// Soprano's settings or the Mac's mode: the default (`soprano`), `folio` and
    /// `folio-paper` render Folio Paper; `folio-ink` and the third-party themes are dark.
    static func harnessTheme(_ id: String) -> AppTheme {
        AppTheme.theme(for: id == "soprano" ? AppTheme.folioId : id, appearance: .light)
    }

    /// The scenario's settings, `--settings` over them, then `--theme`; and the file's
    /// issue count (the panel's footer).
    static func resolveSettings(_ options: Options) throws -> (settings: SopranoMixSettings, issueCount: Int) {
        var settings = options.scenario.settings
        var issueCount = 0
        let knownThemeIDs = Set(AppTheme.options.map(\.id))
        if let url = options.settings {
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw RenderError(description: "cannot read \(url.path): \(error.localizedDescription)")
            }
            let resolution = SettingsResolver.resolve(text: text, knownThemeIDs: knownThemeIDs)
            guard let resolved = resolution.settings else {
                let message = resolution.issues.map(issueText).joined(separator: "; ")
                throw RenderError(description: "\(url.path): \(message)")
            }
            for issue in resolution.issues {
                FileHandle.standardError.write(Data("snapshot: \(url.lastPathComponent): \(issueText(issue))\n".utf8))
            }
            settings = merged(resolved, over: settings)
            issueCount = resolution.issues.count
        }
        if let theme = options.theme {
            guard theme == "soprano" || AppTheme.isKnownId(theme) else {
                throw RenderError(description: "unknown theme \(theme) (soprano, \(AppTheme.options.map(\.id).joined(separator: ", ")))")
            }
            settings.theme = theme
        }
        return (settings, issueCount)
    }

    /// A `--settings` file over the scenario's settings: the file's values win; the
    /// scenario's `apps` and `outputs` entries it does not name stay.
    static func merged(_ file: SopranoMixSettings, over scenario: SopranoMixSettings) -> SopranoMixSettings {
        var settings = file
        settings.apps = scenario.apps.merging(file.apps) { _, fromFile in fromFile }
        settings.outputs = scenario.outputs.merging(file.outputs) { _, fromFile in fromFile }
        return settings
    }

    private static func issueText(_ issue: ConfigIssue) -> String {
        issue.line.map { "line \($0): \(issue.message)" } ?? issue.message
    }

    // MARK: - Actions

    static func apply(_ action: Action, to controller: MixerController, devices: DeviceSnapshot) throws {
        switch action {
        case let .volume(app, percent):
            controller.handle(.setAppVolume(try appKey(app, in: controller.apps), percent, final: true))
        case let .mute(app):
            controller.handle(.toggleAppMute(try appKey(app, in: controller.apps)))
        case let .output(app, device):
            let key = try appKey(app, in: controller.apps)
            let uid = try device.map { try self.device($0, among: devices.outputs).uid }
            controller.handle(.setAppOutput(key, uid: uid))
        case let .device(role, name):
            let candidates = role == .input ? devices.inputs : devices.outputs
            controller.handle(.setDefaultDevice(role, uid: try device(name, among: candidates).uid))
        case let .deviceVolume(role, percent):
            controller.handle(.setDeviceVolume(role, percent, final: true))
        case let .key(key):
            _ = controller.handleVolumeKey(VolumeKeyEvent(key: key, isDown: true))
            _ = controller.handleVolumeKey(VolumeKeyEvent(key: key, isDown: false))
        }
    }

    /// The app as the CLI resolves it (a key-like query names an app that is not running).
    static func appKey(_ query: String, in apps: [AudioApp]) throws -> AppKey {
        switch AppMatcher.match(query, in: apps) {
        case let .match(app):
            return app.key
        case let .ambiguous(matches):
            throw RenderError(description: "'\(query)' matches \(matches.map(\.name).joined(separator: ", ")).")
        case .none:
            guard AppMatcher.isKeyLike(query) else { throw RenderError(description: "No app matches '\(query)'.") }
            return AppKey(rawValue: query)
        }
    }

    /// A device by UID, name, then unique name prefix, then unique name substring (case-
    /// and diacritic-insensitive).
    static func device(_ query: String, among devices: [AudioDevice]) throws -> AudioDevice {
        if let byUID = devices.first(where: { $0.uid == query }) { return byUID }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let levels: [(AudioDevice) -> Bool] = [
            { $0.name.compare(query, options: options) == .orderedSame },
            { $0.name.range(of: query, options: options.union(.anchored)) != nil },
            { $0.name.range(of: query, options: options) != nil },
        ]
        for level in levels {
            let hits = devices.filter(level)
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 {
                throw RenderError(description: "'\(query)' matches \(hits.map(\.name).joined(separator: ", ")).")
            }
        }
        throw RenderError(description: "No device matches '\(query)'.")
    }

    // MARK: - Levels

    /// Fixed peaks for the playing listed apps, in list order; the first is near clipping
    /// (above −1 dBFS), every other below.
    static func fixedLevels(for apps: [AudioApp]) -> [AppKey: RouteLevels] {
        let clipping: Float = 0.97
        let others: [Float] = [0.42, 0.63, 0.18, 0.5, 0.3, 0.75, 0.1]
        var levels: [AppKey: RouteLevels] = [:]
        for (index, app) in apps.filter(\.isPlaying).enumerated() {
            let peak = index == 0 ? clipping : others[(index - 1) % others.count]
            let level = StereoLevel(left: peak, right: peak * 0.92)
            levels[app.key] = RouteLevels(input: level, output: level)
        }
        return levels
    }

    // MARK: - Report

    static func makeReport(controller: MixerController, devices: DeviceSnapshot, writes: [SettingsWrite],
                           hud: VolumeHUDModel?) -> SnapshotReport {
        let apps = (controller.handle(CLIRequest.list).apps ?? []).map { app in
            SnapshotReport.App(
                key: app.key, name: app.name, volume: app.volume, muted: app.muted,
                output: app.output, outputName: app.outputName, playing: app.playing
            )
        }
        func name(_ uid: String) -> String { devices.device(uid: uid)?.name ?? uid }
        func rounded(_ gain: Float) -> Double { (Double(gain) * 10_000).rounded() / 10_000 }
        let plan = controller.plan
        let routes = plan.routes.map { route in
            SnapshotReport.Route(
                key: route.key.rawValue, mode: route.mode.rawValue, gain: rounded(route.gain), limiter: route.limiter,
                device: name(route.outputDeviceUID), deviceUID: route.outputDeviceUID,
                processObjectIDs: route.processObjectIDs
            )
        }
        let master = plan.master.map { spec in
            SnapshotReport.Master(
                device: name(spec.outputDeviceUID), deviceUID: spec.outputDeviceUID,
                gain: rounded(spec.gain), excludedProcessObjectIDs: spec.excludedProcessObjectIDs
            )
        }
        return SnapshotReport(
            apps: apps,
            plan: SnapshotReport.Plan(routes: routes, master: master),
            settingsWrites: writes,
            hud: hud.map { SnapshotReport.HUD(deviceName: $0.deviceName, level: $0.level, isMuted: $0.isMuted, caption: $0.caption) }
        )
    }

    // MARK: - Output

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try createParentDirectory(of: url)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RenderError(description: "PNG encoding failed")
        }
        try data.write(to: url)
    }

    private static func createParentDirectory(of url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}
