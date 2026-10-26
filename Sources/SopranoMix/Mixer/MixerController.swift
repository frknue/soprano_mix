import AppKit
import SopranoMixCore

/// The mixer: groups Core Audio processes into apps, keeps the router's routes equal to
/// the plan for the effective settings (settings.json plus unsaved changes), and turns
/// panel intents, volume keys and CLI requests into setting changes and device writes
/// (ARCHITECTURE → Mixer).
@MainActor
final class MixerController {
    /// Unsaved changes are written this long after the last one (unless a final one comes first).
    static let persistDelay: TimeInterval = 0.5
    /// Meters update at 30 Hz while the panel is visible.
    static let meterInterval: TimeInterval = 1.0 / 30
    /// The sound-effects volume is written at most this often while dragged.
    static let alertWriteInterval: TimeInterval = 0.1
    static let softwareVolumeCaption = "Software volume"

    private let processes: AudioProcessSource
    private let devices: AudioDeviceControlling
    private let router: AudioRouting
    private let icons: AppIconProviding
    private let panel: MixPanelPresenting
    private let hud: VolumeHUDPresenting
    private let environment: MixerEnvironment

    /// Every connected app.
    private(set) var apps: [AudioApp] = []
    /// What the panel shows.
    private(set) var listedApps: [AudioApp] = []
    /// The plan last handed to the router.
    private(set) var plan: RoutePlan = .empty

    private var tracker = AppListTracker()
    /// Changes the panel, keys or CLI made that settings.json may not hold yet, one per path.
    private var overrides: [SettingOverride] = []
    /// Paths of overrides not written yet, in the order they first changed. Pending app
    /// volumes and software output volumes hold their routes (`heldKeys`, `heldOutputUIDs`).
    private var pendingPaths: [[String]] = []
    /// Paths whose write failed (settings.json unreadable); retried after the next
    /// settings change.
    private var failedPaths: [[String]] = []
    /// Bumped on every change and write, so only the last debounced write runs.
    private var persistGeneration = 0
    private var isPersisting = false
    /// The sound-effects volume while it is dragged (written at most every 100 ms).
    private var draggedAlertVolume: Double?
    private var lastAlertWrite: TimeInterval?
    private var didRequestCapture = false
    /// Volume keys whose down event was consumed, so their up event is consumed too.
    private var consumedKeys: Set<VolumeKey> = []

    private var isRefreshing = false
    private var needsRefresh = false
    private var wasVisible = false

    private var stopMeterTimer: (@MainActor () -> Void)?
    private var ballistics: [AppKey: MeterBallistics] = [:]
    private var lastMeterTick: TimeInterval?

    init(processes: AudioProcessSource, devices: AudioDeviceControlling, router: AudioRouting,
         icons: AppIconProviding, panel: MixPanelPresenting, hud: VolumeHUDPresenting,
         environment: MixerEnvironment) {
        self.processes = processes
        self.devices = devices
        self.router = router
        self.icons = icons
        self.panel = panel
        self.hud = hud
        self.environment = environment
    }

    func start() {
        processes.onChange = { [weak self] in self?.refresh() }
        devices.onChange = { [weak self] in self?.refresh() }
        router.onStatusChange = { [weak self] in self?.refresh() }
        panel.onIntent = { [weak self] intent in self?.handle(intent) }
        panel.onVisibilityChange = { [weak self] _ in self?.panelVisibilityDidChange() }
        processes.start()
        devices.start()
        refresh()
    }

    // MARK: - Panel

    var isPanelVisible: Bool { panel.isVisible }

    func togglePanel(anchor: NSRect?) {
        if isPanelVisible {
            hidePanel()
        } else {
            showPanel(anchor: anchor)
        }
    }

    func showPanel(anchor: NSRect?) {
        guard !isPanelVisible else {
            refresh()
            return
        }
        refresh()
        panel.show(
            model: model(settings: effectiveSettings, capture: environment.captureStatus()),
            theme: environment.theme(),
            anchor: anchor
        )
        panelVisibilityDidChange()
    }

    func hidePanel() {
        guard isPanelVisible else { return }
        panel.dismiss()
        panelVisibilityDidChange()
    }

    /// Meter routes and the meter timer follow the panel; safe to call more than once.
    private func panelVisibilityDidChange() {
        let visible = panel.isVisible
        guard visible != wasVisible else { return }
        wasVisible = visible
        refresh()
    }

    // MARK: - Changes from outside

    func settingsDidChange() {
        if !failedPaths.isEmpty, !isPersisting {
            // settings.json changed (perhaps fixed): retry what could not be written.
            persistPending()
        } else {
            refresh()
        }
    }

    /// Writes every pending change now and cancels the debounce (quit).
    func flushPendingSettings() {
        guard !pendingPaths.isEmpty || !failedPaths.isEmpty else { return }
        persistPending()
    }

    func permissionDidChange() {
        refresh()
    }

    // MARK: - Intents

    func handle(_ intent: PanelIntent) {
        switch intent {
        case let .setAppVolume(key, percent, isFinal):
            requestCaptureIfUndetermined()
            change([.appVolume(key, Self.clamped(percent, to: VolumeLaw.appRange).rounded())], final: isFinal)
        case let .toggleAppMute(key):
            requestCaptureIfUndetermined()
            change([.appMuted(key, !effectiveSettings.audio(for: key).muted)], final: true)
        case let .setAppOutput(key, uid):
            requestCaptureIfUndetermined()
            change([.appOutput(key, uid)], final: true)
        case let .setDefaultDevice(role, uid):
            devices.setDefaultDevice(role, uid: uid)
        case let .setDeviceVolume(role, percent, isFinal):
            setDeviceVolume(role, percent: percent, final: isFinal)
        case let .toggleDeviceMute(role):
            toggleDeviceMute(role)
        case let .setBalance(balance, _):
            guard let device = devices.snapshot.defaultOutput, device.balance != nil else { return }
            devices.setBalance(Self.clamped(balance, to: 0...1), uid: device.uid)
        case let .setSampleRate(role, rate):
            guard let uid = devices.snapshot.uid(for: role), devices.snapshot.device(uid: uid) != nil else { return }
            devices.setSampleRate(rate, uid: uid)
        case .requestCapture:
            requestCapture()
            refresh()
        case .openSettings:
            environment.openSettingsFile()
        case let .showAppMenu(anchor):
            environment.showAppMenu(anchor)
        case .dismiss:
            hidePanel()
        }
    }

    private func setDeviceVolume(_ role: DeviceRole, percent: Double, final isFinal: Bool) {
        let snapshot = devices.snapshot
        switch role {
        case .output:
            guard let device = snapshot.defaultOutput else { return }
            if device.outputVolume != nil {
                devices.setVolume(Self.clamped(percent, to: VolumeLaw.outputRange) / 100, scope: .output, uid: device.uid)
            } else {
                requestCaptureIfUndetermined()
                let name = effectiveSettings.outputKey(for: device)
                change([.outputVolume(name, Self.clamped(percent, to: VolumeLaw.outputRange).rounded())], final: isFinal)
            }
        case .input:
            guard let device = snapshot.defaultInput, device.inputVolume != nil else { return }
            devices.setVolume(Self.clamped(percent, to: VolumeLaw.outputRange) / 100, scope: .input, uid: device.uid)
        case .soundEffects:
            setAlertVolume(Self.clamped(percent, to: VolumeLaw.outputRange), final: isFinal)
        }
    }

    /// The alert volume is written when final and at most every 100 ms while dragged; the
    /// panel shows the dragged value in between.
    private func setAlertVolume(_ percent: Double, final isFinal: Bool) {
        let now = environment.now()
        if isFinal {
            environment.setAlertVolume(percent)
            draggedAlertVolume = nil
            lastAlertWrite = nil
        } else {
            draggedAlertVolume = percent
            if lastAlertWrite.map({ now - $0 >= Self.alertWriteInterval }) ?? true {
                environment.setAlertVolume(percent)
                lastAlertWrite = now
            }
        }
        refresh()
    }

    private func toggleDeviceMute(_ role: DeviceRole) {
        let snapshot = devices.snapshot
        switch role {
        case .output:
            guard let device = snapshot.defaultOutput else { return }
            if device.outputVolume == nil {
                requestCaptureIfUndetermined()
                let settings = effectiveSettings
                let name = settings.outputKey(for: device)
                change([.outputMuted(name, !settings.outputVolume(for: device).muted)], final: true)
            } else if let muted = device.outputMuted {
                devices.setMuted(!muted, scope: .output, uid: device.uid)
            }
        case .input:
            guard let device = snapshot.defaultInput, let muted = device.inputMuted else { return }
            devices.setMuted(!muted, scope: .input, uid: device.uid)
        case .soundEffects:
            break
        }
    }

    // MARK: - Volume keys

    /// True consumes the key.
    func handleVolumeKey(_ event: VolumeKeyEvent) -> Bool {
        guard event.isDown else {
            return consumedKeys.remove(event.key) != nil
        }
        let settings = effectiveSettings
        guard settings.volumeKeys.anyOutput,
              let device = devices.snapshot.defaultOutput,
              device.outputVolume == nil
        else {
            consumedKeys.remove(event.key)
            return false
        }
        consumedKeys.insert(event.key)

        let name = settings.outputKey(for: device)
        let current = settings.outputVolume(for: device)
        var next = current
        switch event.key {
        case .up, .down:
            next.volume = VolumeLaw.step(current.volume, up: event.key == .up, fine: event.fine)
            // Like macOS: changing the volume unmutes.
            next.muted = false
        case .mute:
            if !event.isRepeat { next.muted.toggle() }
        }

        var changes: [SettingOverride] = []
        if next.volume != current.volume { changes.append(.outputVolume(name, next.volume)) }
        if next.muted != current.muted { changes.append(.outputMuted(name, next.muted)) }
        if !changes.isEmpty {
            requestCaptureIfUndetermined()
            change(changes, final: false)
        }
        if settings.volumeKeys.hud {
            let model = VolumeHUDModel(
                deviceName: device.name,
                level: Self.clamped(next.volume / 100, to: 0...1),
                isMuted: next.muted,
                caption: Self.softwareVolumeCaption
            )
            hud.show(model, theme: environment.theme())
        }
        return true
    }

    // MARK: - CLI

    func handle(_ request: CLIRequest) -> CLIResponse {
        switch request {
        case .list:
            let settings = effectiveSettings
            return CLIResponse(ok: true, apps: listedApps.map { cliApp($0.key, app: $0, settings: settings) })
        case .devices:
            let settings = effectiveSettings
            let snapshot = devices.snapshot
            return CLIResponse(ok: true, devices: snapshot.devices.map { cliDevice($0, in: snapshot, settings: settings) })
        case let .setVolume(query, percent):
            return changeApp(query) { key in
                [.appVolume(key, Self.clamped(percent, to: VolumeLaw.appRange).rounded())]
            }
        case let .setMuted(query, muted):
            return changeApp(query) { key in
                [.appMuted(key, muted ?? !self.effectiveSettings.audio(for: key).muted)]
            }
        case let .setOutput(query, device):
            return changeApp(query) { key in
                // A connected device is written by UID; anything else as given (it applies
                // once a device with that UID or name appears).
                let uid = device.map { self.devices.snapshot.output(matching: $0)?.uid ?? $0 }
                return [.appOutput(key, uid)]
            }
        case .show:
            showPanel(anchor: nil)
            return CLIResponse(ok: true)
        case .hide:
            hidePanel()
            return CLIResponse(ok: true)
        }
    }

    /// Resolves `query` through `AppMatcher` (a key-like query sets that key even while
    /// the app is not running), applies and persists the changes, answers with the app.
    private func changeApp(_ query: String, _ changes: (AppKey) -> [SettingOverride]) -> CLIResponse {
        let key: AppKey
        switch AppMatcher.match(query, in: apps) {
        case let .match(app):
            key = app.key
        case let .ambiguous(matches):
            return .failure("'\(query)' matches \(matches.map(\.name).joined(separator: ", ")).")
        case .none:
            guard AppMatcher.isKeyLike(query) else { return .failure("No app matches '\(query)'.") }
            key = AppKey(rawValue: query)
        }
        requestCaptureIfUndetermined()
        change(changes(key), final: true)
        let app = apps.first { $0.key == key }
        return CLIResponse(ok: true, app: cliApp(key, app: app, settings: effectiveSettings))
    }

    private func cliApp(_ key: AppKey, app: AudioApp?, settings: SopranoMixSettings) -> CLIApp {
        let audio = settings.audio(for: key)
        let snapshot = devices.snapshot
        let target = snapshot.output(matching: audio.output) ?? snapshot.defaultOutput
        return CLIApp(
            key: key.rawValue,
            name: app?.name ?? Self.displayName(for: key),
            kind: (app?.kind ?? Self.kind(for: key)).rawValue,
            volume: audio.volume,
            muted: audio.muted,
            output: audio.output,
            outputName: target?.name,
            playing: app?.isPlaying ?? false,
            routed: plan.route(for: key)?.mode == .replace,
            pids: app?.pids ?? []
        )
    }

    private func cliDevice(_ device: AudioDevice, in snapshot: DeviceSnapshot, settings: SopranoMixSettings) -> CLIDevice {
        let isSoftware = device.hasOutput && device.outputVolume == nil
        let software = settings.outputVolume(for: device)
        let volume: Double?
        let muted: Bool?
        if device.hasOutput {
            volume = device.outputVolume.map(MixerModelBuilder.percent(fromScalar:)) ?? software.volume
            muted = isSoftware ? software.muted : device.outputMuted
        } else {
            volume = nil
            muted = device.inputMuted
        }
        return CLIDevice(
            uid: device.uid,
            name: device.name,
            transport: device.transport.rawValue,
            output: device.hasOutput,
            input: device.hasInput,
            defaultOutput: device.uid == snapshot.defaultOutputUID,
            defaultInput: device.uid == snapshot.defaultInputUID,
            soundEffects: device.uid == snapshot.soundEffectsUID,
            volume: volume,
            softwareVolume: isSoftware,
            muted: muted,
            sampleRate: device.sampleRate
        )
    }

    /// The name of an app that is not running, from its key.
    private static func displayName(for key: AppKey) -> String {
        for prefix in ["wine:", "exe:"] where key.rawValue.hasPrefix(prefix) {
            return String(key.rawValue.dropFirst(prefix.count))
        }
        return key.rawValue
    }

    private static func kind(for key: AppKey) -> AppKind {
        if key.rawValue.hasPrefix("wine:") { return .wine }
        if key.rawValue.hasPrefix("exe:") { return .executable }
        return .app
    }

    // MARK: - Meters

    /// One meter frame: the router's peaks since the last frame through one
    /// `MeterBallistics` per app, to the panel. Output peaks for replace routes, input
    /// peaks for meter routes; playing listed apps without a route show no meter.
    func tickMeters() {
        guard isPanelVisible else { return }
        let levels = router.takeLevels()
        let now = environment.now()
        let elapsed = lastMeterTick.map { max(0, now - $0) } ?? Self.meterInterval
        lastMeterTick = now
        var positions: [AppKey: Double] = [:]
        var next: [AppKey: MeterBallistics] = [:]
        for app in listedApps where app.isPlaying {
            guard let route = plan.route(for: app.key) else { continue }
            let level = levels[app.key].map { route.mode == .replace ? $0.output : $0.input } ?? .silent
            var meter = ballistics[app.key] ?? MeterBallistics()
            positions[app.key] = meter.update(peak: level.peak, elapsed: elapsed)
            next[app.key] = meter
        }
        ballistics = next
        panel.updateLevels(positions)
    }

    private func setMetersRunning(_ running: Bool) {
        if running {
            guard stopMeterTimer == nil else { return }
            lastMeterTick = nil
            stopMeterTimer = environment.scheduleRepeating(Self.meterInterval) { [weak self] in
                self?.tickMeters()
            }
        } else if let stop = stopMeterTimer {
            stopMeterTimer = nil
            stop()
            ballistics = [:]
            lastMeterTick = nil
        }
    }

    // MARK: - Overrides

    /// settings.json with every unsaved change on top.
    private var effectiveSettings: SopranoMixSettings {
        var settings = environment.settings()
        for entry in overrides {
            entry.apply(to: &settings)
        }
        return settings
    }

    /// Applies `changes` at once (re-plan), then writes them now (`final`) or 0.5 s after
    /// the last change.
    private func change(_ changes: [SettingOverride], final isFinal: Bool) {
        for entry in changes {
            if let index = overrides.firstIndex(where: { $0.path == entry.path }) {
                overrides[index] = entry
            } else {
                overrides.append(entry)
            }
            if !pendingPaths.contains(entry.path) {
                pendingPaths.append(entry.path)
            }
        }
        if isFinal {
            // Writes, then re-plans once with the routes no longer held.
            persistPending()
        } else {
            refresh()
            persistGeneration += 1
            let generation = persistGeneration
            environment.schedule(Self.persistDelay) { [weak self] in
                guard let self, self.persistGeneration == generation else { return }
                self.persistPending()
            }
        }
    }

    /// Writes every pending and failed path. A failed write stays (retried after the next
    /// settings change); overrides the file then holds are dropped, since a write that
    /// changes nothing fires no settings change.
    private func persistPending() {
        guard !isPersisting else { return }
        isPersisting = true
        // A debounced write still waiting finds nothing to do.
        persistGeneration += 1
        var paths = failedPaths
        for path in pendingPaths where !paths.contains(path) {
            paths.append(path)
        }
        pendingPaths = []
        failedPaths = []
        for path in paths {
            guard let entry = overrides.first(where: { $0.path == path }) else { continue }
            if !environment.writeSetting(entry.value, path) {
                failedPaths.append(path)
            }
        }
        isPersisting = false
        refresh()
    }

    /// Apps whose volume change is still in progress keep their route (`heldKeys`).
    private var heldKeys: Set<AppKey> {
        var keys: Set<AppKey> = []
        for case let .appVolume(key, _) in overrides where pendingPaths.contains(["apps", key.rawValue, "volume"]) {
            keys.insert(key)
        }
        return keys
    }

    /// Outputs whose software volume change is still in progress keep their master route.
    private func heldOutputUIDs(in snapshot: DeviceSnapshot) -> Set<String> {
        var uids: Set<String> = []
        for case let .outputVolume(name, _) in overrides where pendingPaths.contains(["outputs", name, "volume"]) {
            for device in snapshot.outputs
            where device.uid == name || device.name.caseInsensitiveCompare(name) == .orderedSame {
                uids.insert(device.uid)
            }
        }
        return uids
    }

    // MARK: - Capture

    /// The first change that needs a route while capture is not determined asks for it.
    private func requestCaptureIfUndetermined() {
        guard !didRequestCapture, environment.captureStatus() == .notDetermined else { return }
        requestCapture()
    }

    private func requestCapture() {
        didRequestCapture = true
        environment.requestCapture { [weak self] _ in
            self?.permissionDidChange()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        guard !isRefreshing else {
            // A callback during the refresh (a router status, a write) runs it again after.
            needsRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsRefresh = false
            refreshOnce()
        } while needsRefresh
    }

    private func refreshOnce() {
        let fileSettings = environment.settings()
        // Written changes the file now holds are no longer needed.
        overrides.removeAll { entry in
            !pendingPaths.contains(entry.path) && !failedPaths.contains(entry.path) && entry.isSatisfied(by: fileSettings)
        }
        var settings = fileSettings
        for entry in overrides {
            entry.apply(to: &settings)
        }
        let snapshot = devices.snapshot
        let capture = environment.captureStatus()

        apps = AudioAppResolver.apps(from: processes.processes, ownPID: environment.ownPID)
        listedApps = tracker.update(apps: apps, settings: settings)

        let visible = panel.isVisible
        let metersOn = visible && settings.panel.meters
        let meteredKeys: Set<AppKey> = metersOn ? Set(listedApps.filter(\.isPlaying).map(\.key)) : []
        let next = RoutePlanner.plan(
            apps: apps,
            settings: settings,
            devices: snapshot,
            meteredKeys: meteredKeys,
            canCapture: capture.allowsRoutes,
            heldKeys: heldKeys,
            heldOutputUIDs: heldOutputUIDs(in: snapshot)
        )
        if next != plan {
            plan = next
            router.apply(next)
        }
        setMetersRunning(metersOn)
        if visible {
            panel.update(model: model(settings: settings, capture: capture), theme: environment.theme())
        }
    }

    private func model(settings: SopranoMixSettings, capture: CaptureStatus) -> MixPanelModel {
        MixerModelBuilder.model(
            listedApps: listedApps,
            settings: settings,
            devices: devices.snapshot,
            statuses: router.statuses,
            capture: capture,
            settingsIssueCount: environment.settingsIssueCount(),
            alertVolume: draggedAlertVolume ?? environment.alertVolume(),
            icons: { app in self.icons.icon(for: app) }
        )
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard !value.isNaN else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// One settings.json value the mixer changed, kept in memory until the file holds it.
enum SettingOverride: Equatable {
    case appVolume(AppKey, Double)
    case appMuted(AppKey, Bool)
    /// nil follows the system output ("default").
    case appOutput(AppKey, String?)
    /// Keyed by the `outputs` key (`SopranoMixSettings.outputKey(for:)`).
    case outputVolume(String, Double)
    case outputMuted(String, Bool)

    /// The settings path `writeSetting` gets.
    var path: [String] {
        switch self {
        case let .appVolume(key, _): ["apps", key.rawValue, "volume"]
        case let .appMuted(key, _): ["apps", key.rawValue, "muted"]
        case let .appOutput(key, _): ["apps", key.rawValue, "output"]
        case let .outputVolume(name, _): ["outputs", name, "volume"]
        case let .outputMuted(name, _): ["outputs", name, "muted"]
        }
    }

    /// The JSON value: whole percents as integers, "default" for the system output.
    var value: Any {
        switch self {
        case let .appVolume(_, volume), let .outputVolume(_, volume):
            if volume.rounded() == volume { return Int(volume) }
            return volume
        case let .appMuted(_, muted), let .outputMuted(_, muted):
            return muted
        case let .appOutput(_, output):
            return output ?? "default"
        }
    }

    func apply(to settings: inout SopranoMixSettings) {
        switch self {
        case let .appVolume(key, volume):
            settings.apps[key, default: AppAudioSettings.default].volume = volume
        case let .appMuted(key, muted):
            settings.apps[key, default: AppAudioSettings.default].muted = muted
        case let .appOutput(key, output):
            settings.apps[key, default: AppAudioSettings.default].output = output
        case let .outputVolume(name, volume):
            settings.outputs[name, default: OutputVolumeSettings.default].volume = volume
        case let .outputMuted(name, muted):
            settings.outputs[name, default: OutputVolumeSettings.default].muted = muted
        }
    }

    /// The file already holds this value.
    func isSatisfied(by settings: SopranoMixSettings) -> Bool {
        switch self {
        case let .appVolume(key, volume): settings.audio(for: key).volume == volume
        case let .appMuted(key, muted): settings.audio(for: key).muted == muted
        case let .appOutput(key, output): settings.audio(for: key).output == output
        case let .outputVolume(name, volume): (settings.outputs[name] ?? .default).volume == volume
        case let .outputMuted(name, muted): (settings.outputs[name] ?? .default).muted == muted
        }
    }
}
