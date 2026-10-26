import AppKit
@testable import SopranoMix
@testable import SopranoMixCore

/// A panel that draws nothing and remembers what the controller asked for. Showing and
/// dismissing report the visibility change synchronously, like `MixPanelWindow`.
@MainActor
final class RecordingPanelPresenter: MixPanelPresenting {
    private(set) var isVisible = false
    var onIntent: ((PanelIntent) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    /// The last model shown or updated.
    private(set) var model: MixPanelModel?
    private(set) var showCount = 0
    private(set) var dismissCount = 0
    /// Every `updateLevels` call, in order.
    private(set) var levelUpdates: [[AppKey: Double]] = []

    func show(model: MixPanelModel, theme: AppTheme, anchor: NSRect?) {
        self.model = model
        showCount += 1
        guard !isVisible else { return }
        isVisible = true
        onVisibilityChange?(true)
    }

    func update(model: MixPanelModel, theme: AppTheme) {
        self.model = model
    }

    func updateLevels(_ levels: [AppKey: Double]) {
        levelUpdates.append(levels)
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        dismissCount += 1
        onVisibilityChange?(false)
    }

    /// Nothing is drawn.
    func renderSnapshot(scale: CGFloat) -> CGImage? {
        nil
    }
}

/// A HUD that remembers every model it was asked to show.
@MainActor
final class RecordingHUD: VolumeHUDPresenting {
    private(set) var shown: [VolumeHUDModel] = []

    var current: VolumeHUDModel? { shown.last }

    func show(_ model: VolumeHUDModel, theme: AppTheme) {
        shown.append(model)
    }

    func renderSnapshot(scale: CGFloat) -> CGImage? {
        nil
    }
}

/// Holds one-shot and repeating work until a test fires it.
@MainActor
final class ManualMixerScheduler {
    private final class Repeating {
        let interval: TimeInterval
        let work: @MainActor () -> Void
        var isCancelled = false

        init(interval: TimeInterval, work: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.work = work
        }
    }

    private var oneShots: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
    private var repeating: [Repeating] = []

    /// Delays of the one-shot work still waiting, in scheduling order.
    var pendingDelays: [TimeInterval] { oneShots.map(\.delay) }

    /// Intervals of the repeating work not cancelled.
    var repeatingIntervals: [TimeInterval] { repeating.filter { !$0.isCancelled }.map(\.interval) }

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        oneShots.append((delay, work))
    }

    func scheduleRepeating(_ interval: TimeInterval, _ work: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let entry = Repeating(interval: interval, work: work)
        repeating.append(entry)
        return { entry.isCancelled = true }
    }

    /// Runs every waiting one-shot (work scheduled meanwhile waits).
    func fireAll() {
        let due = oneShots
        oneShots = []
        for entry in due {
            entry.work()
        }
    }

    /// One tick of every running repeating timer.
    func tick() {
        for entry in repeating where !entry.isCancelled {
            entry.work()
        }
    }
}

/// The shell side of the mixer for tests: settings.json in memory, a manual scheduler,
/// a capture status the test controls, and counters for what the controller asked for.
@MainActor
final class MixerTestEnvironment {
    let store: FixtureSettingsStore
    let scheduler = ManualMixerScheduler()
    var issueCount = 0
    var capture: CaptureStatus = .granted
    var alertVolume: Double? = FixtureScenario.alertVolume
    var clock: TimeInterval = 0
    private(set) var captureRequests = 0
    private(set) var openedSettingsFile = 0
    private(set) var appMenuAnchors: [NSRect] = []
    private var captureCallbacks: [@MainActor (CaptureStatus) -> Void] = []

    init(settings: SopranoMixSettings) {
        store = FixtureSettingsStore(settings: settings)
    }

    /// The user answers the System Audio Recording prompt.
    func answerCapture(_ status: CaptureStatus) {
        capture = status
        let callbacks = captureCallbacks
        captureCallbacks = []
        for callback in callbacks {
            callback(status)
        }
    }

    func make() -> MixerEnvironment {
        MixerEnvironment(
            settings: { self.store.settings },
            settingsIssueCount: { self.issueCount },
            theme: { AppTheme.folioPaper },
            writeSetting: { value, path in self.store.write(value, at: path) },
            schedule: { delay, work in self.scheduler.schedule(delay, work) },
            scheduleRepeating: { interval, work in self.scheduler.scheduleRepeating(interval, work) },
            now: { self.clock },
            ownPID: FixtureScenario.ownPID,
            captureStatus: { self.capture },
            requestCapture: { done in
                self.captureRequests += 1
                self.captureCallbacks.append(done)
            },
            alertVolume: { self.alertVolume },
            setAlertVolume: { self.alertVolume = $0 },
            openSettingsFile: { self.openedSettingsFile += 1 },
            showAppMenu: { self.appMenuAnchors.append($0) }
        )
    }
}

/// A started `MixerController` on a fixture scenario with a recording router, panel and
/// HUD and the test environment.
@MainActor
final class MixerTestHarness {
    let processes: FixtureProcessSource
    let devices: FixtureDevices
    let router: RecordingRouter
    let panel: RecordingPanelPresenter
    let hud: RecordingHUD
    let environment: MixerTestEnvironment
    let controller: MixerController

    init(scenario: FixtureScenario = .standard, settings: SopranoMixSettings? = nil, capture: CaptureStatus = .granted) {
        let processes = FixtureProcessSource(scenario: scenario)
        let devices = FixtureDevices(scenario: scenario)
        let router = RecordingRouter()
        let panel = RecordingPanelPresenter()
        let hud = RecordingHUD()
        let environment = MixerTestEnvironment(settings: settings ?? scenario.settings)
        environment.capture = capture
        let controller = MixerController(
            processes: processes,
            devices: devices,
            router: router,
            icons: FixtureIcons(),
            panel: panel,
            hud: hud,
            environment: environment.make()
        )
        self.processes = processes
        self.devices = devices
        self.router = router
        self.panel = panel
        self.hud = hud
        self.environment = environment
        self.controller = controller
        controller.start()
    }

    /// settings.json; assign and call `controller.settingsDidChange()` to simulate an edit.
    var settings: SopranoMixSettings {
        get { environment.store.settings }
        set { environment.store.settings = newValue }
    }

    var writes: [SettingsWrite] { environment.store.writes }

    func row(_ key: AppKey) -> AppRowModel? {
        panel.model?.apps.first { $0.key == key }
    }

    /// One key press and release; returns whether each half was consumed.
    func press(_ key: VolumeKey, fine: Bool = false) -> (down: Bool, up: Bool) {
        let down = controller.handleVolumeKey(VolumeKeyEvent(key: key, isDown: true, fine: fine))
        let up = controller.handleVolumeKey(VolumeKeyEvent(key: key, isDown: false, fine: fine))
        return (down, up)
    }
}
