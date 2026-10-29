import AppKit
import OSLog
import SopranoMixCore

private let appLog = Logger(subsystem: "com.soprano.mix", category: "app")

/// The composition root: settings → theme → live audio objects → panel and HUD → mixer →
/// volume keys → panel hotkey → menu bar → login item → CLI server.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the first launch opened the permissions window.
    private static let didRequestPermissionsKey = "didRequestPermissions"
    /// Every flavour's bundle id starts with this (installed `com.soprano.mix`, dev
    /// `com.soprano.mix.dev`); only one of them may run, or every app is routed twice.
    private static let bundleIDPrefix = "com.soprano.mix"
    /// How often the capture status, the alert volume and a missing Accessibility grant
    /// are re-read (never prompting).
    private static let pollInterval: TimeInterval = 2

    private var router: LiveAudioRouter?
    private var controller: MixerController?
    private var volumeKeys: VolumeKeyMonitor?
    private var hotkey: CarbonPanelHotkey?
    private var appliedHotkey: PanelHotkey??
    private var menuBar: MenuBarController?
    private var cliServer: CLIServer?
    private var permissionsWindow: PermissionsWindowController?
    private var poll: Timer?
    private var appliedStartAtLogin: Bool?
    /// System Audio Recording as last read; the mixer reads this, never TCC per call.
    private var captureStatus: CaptureStatus = .unknown
    /// The alert volume as last read or set; the mixer reads this, never AppleScript per call.
    private var alertVolume: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.anotherInstanceIsRunning() else {
            appLog.notice("Another Soprano Mix is running; quitting.")
            NSApp.terminate(nil)
            return
        }
        let settings = SettingsCenter.shared
        settings.start()
        ThemeCenter.shared.start()
        captureStatus = Permissions.captureStatus
        alertVolume = AlertVolume.get()

        let processes = LiveAudioProcessSource()
        let devices = LiveAudioDevices()
        let router = LiveAudioRouter()
        let icons = LiveAppIconProvider()
        let panel = MixPanelWindow()
        let hud = VolumeHUD()
        let controller = MixerController(
            processes: processes,
            devices: devices,
            router: router,
            icons: icons,
            panel: panel,
            hud: hud,
            environment: environment()
        )
        self.router = router
        self.controller = controller
        let volumeKeys = VolumeKeyMonitor()
        self.volumeKeys = volumeKeys
        controller.onVolumeKeyInterceptChange = { [weak volumeKeys] intercepts in
            volumeKeys?.setIntercepts(intercepts)
        }
        controller.start()

        hotkey = CarbonPanelHotkey()
        menuBar = MenuBarController(
            togglePanel: { [weak self] anchor in
                self?.controller?.togglePanel(anchor: anchor)
            },
            openPermissions: { [weak self] in
                self?.showPermissions()
            }
        )
        panel.isShellClick = { [weak self] point in
            self?.menuBar?.buttonScreenFrame?.contains(point) == true
        }
        applyVolumeKeys()
        applyHotkey()
        applyLoginItem()

        let cliServer = CLIServer(controller: controller)
        cliServer.start()
        self.cliServer = cliServer

        settings.addObserver(self) { [weak self] in
            self?.settingsDidChange()
        }
        ThemeCenter.shared.addObserver(self) { [weak self] in
            self?.controller?.settingsDidChange()
        }
        startPolling()

        onboardIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cliServer?.stop()
        poll?.invalidate()
        volumeKeys?.stop()
        hotkey?.register(nil) {}
        // Debounced slider values reach settings.json before the routes go.
        controller?.flushPendingSettings()
        router?.stopAll()
        SettingsCenter.shared.stop()
    }

    /// Reopening from Spotlight or Finder opens the panel (the way back while the menu-bar
    /// icon is hidden).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showPanel(anchor: menuBar?.buttonScreenFrame)
        return false
    }

    // MARK: - Composition

    private func environment() -> MixerEnvironment {
        MixerEnvironment(
            settings: { SettingsCenter.shared.settings },
            settingsIssueCount: { SettingsCenter.shared.issues.count },
            theme: { ThemeCenter.shared.theme },
            writeSetting: { value, path in
                SettingsCenter.shared.write(value, at: path)
            },
            schedule: { delay, work in
                guard delay > 0 else {
                    work()
                    return
                }
                let scheduled = ScheduledWork(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        scheduled.run()
                    }
                }
            },
            scheduleRepeating: { interval, work in
                let repeating = RepeatingWork(work)
                let timer = Timer(timeInterval: interval, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        repeating.run()
                    }
                }
                // Common modes: meters keep moving while a slider is dragged or a menu is open.
                RunLoop.main.add(timer, forMode: .common)
                repeating.timer = timer
                return { repeating.cancel() }
            },
            now: { ProcessInfo.processInfo.systemUptime },
            ownPID: getpid(),
            captureStatus: { [weak self] in
                self?.captureStatus ?? .unknown
            },
            requestCapture: { [weak self] completion in
                self?.requestCapture(completion)
            },
            alertVolume: { [weak self] in
                self?.alertVolume
            },
            setAlertVolume: { [weak self] percent in
                guard percent.isFinite else { return }
                AlertVolume.set(percent)
                // AlertVolume stores whole percents in 0...100.
                self?.alertVolume = min(max(percent, 0), 100).rounded()
            },
            openSettingsFile: { SettingsCenter.shared.openInEditor() },
            showAppMenu: { [weak self] anchor in
                self?.menuBar?.showMenu(at: anchor)
            }
        )
    }

    /// Any other running Soprano Mix, installed or dev.
    private static func anotherInstanceIsRunning() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return bundleID.hasPrefix(bundleIDPrefix)
                && app.processIdentifier != ownPID
                && !app.isTerminated
        }
    }

    // MARK: - Settings

    private func settingsDidChange() {
        controller?.settingsDidChange()
        applyVolumeKeys()
        applyHotkey()
        menuBar?.apply()
        applyLoginItem()
    }

    private func applyLoginItem() {
        let enabled = SettingsCenter.shared.settings.app.startAtLogin
        guard enabled != appliedStartAtLogin else { return }
        appliedStartAtLogin = enabled
        LoginItem.sync(enabled: enabled)
    }

    /// Registers `panel.hotkey` when it changed; the hotkey toggles the panel below the
    /// status item (top right of the screen while the icon is hidden).
    private func applyHotkey() {
        guard let hotkey else { return }
        let wanted = SettingsCenter.shared.settings.panel.hotkey
        guard appliedHotkey != .some(wanted) else { return }
        appliedHotkey = .some(wanted)
        let registered = hotkey.register(wanted) { [weak self] in
            guard let self else { return }
            self.controller?.togglePanel(anchor: self.menuBar?.buttonScreenFrame)
        }
        if let wanted, !registered {
            appLog.error("macOS refused the panel hotkey \(wanted.settingsText, privacy: .public)")
        }
    }

    // MARK: - Volume keys, capture and alert volume

    /// Runs the volume-key tap while `volumeKeys.anyOutput` is on and Accessibility is
    /// granted; while it is missing, the poll retries.
    private func applyVolumeKeys() {
        guard let volumeKeys, let controller else { return }
        let wanted = SettingsCenter.shared.settings.volumeKeys.anyOutput
        if !wanted {
            if volumeKeys.isRunning {
                volumeKeys.stop()
            }
        } else if !volumeKeys.isRunning, Permissions.isAccessibilityTrusted {
            do {
                try volumeKeys.start { [weak controller] event, consumed in
                    controller?.handleVolumeKey(event, consumed: consumed)
                }
            } catch {
                appLog.error("Could not start the volume-key tap: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Every 2 s: grants made in System Settings and alert-volume changes made elsewhere
    /// apply without a relaunch. Never prompts.
    private func startPolling() {
        guard poll == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollSystemState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func pollSystemState() {
        captureStatusMayHaveChanged(Permissions.captureStatus)
        let volume = AlertVolume.get()
        if volume != alertVolume {
            alertVolume = volume
            controller?.settingsDidChange()
        }
        applyVolumeKeys()
    }

    /// The panel banner's button and the first change that needs a route: macOS's prompt
    /// while the status is not determined, else System Settings → Privacy → Audio Capture
    /// (denied, or a status the private API cannot tell).
    private func requestCapture(_ completion: @escaping @MainActor (CaptureStatus) -> Void) {
        let current = Permissions.captureStatus
        guard current == .notDetermined else {
            Permissions.openSettings(for: .audioCapture)
            captureStatusMayHaveChanged(current)
            completion(current)
            return
        }
        Permissions.requestCapture { [weak self] status in
            self?.captureStatusMayHaveChanged(status)
            completion(status)
        }
    }

    private func captureStatusMayHaveChanged(_ status: CaptureStatus) {
        guard status != captureStatus else { return }
        captureStatus = status
        controller?.permissionDidChange()
        permissionsWindow?.refresh()
    }

    /// The first launch with System Audio Recording not determined opens the permissions
    /// window once; the panel's banner asks after that.
    private func onboardIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didRequestPermissionsKey) else { return }
        guard captureStatus == .notDetermined else { return }
        defaults.set(true, forKey: Self.didRequestPermissionsKey)
        showPermissions()
    }

    private func showPermissions() {
        let window = permissionsWindow ?? PermissionsWindowController(status: { Permissions.status })
        if permissionsWindow == nil {
            window.onStatusChange = { [weak self] status in
                self?.captureStatusMayHaveChanged(status.capture)
                self?.applyVolumeKeys()
            }
            permissionsWindow = window
        }
        window.show()
    }
}

/// One `MixerEnvironment.schedule` job.
@MainActor
private final class ScheduledWork {
    private var work: (@MainActor () -> Void)?

    init(_ work: @escaping @MainActor () -> Void) {
        self.work = work
    }

    func run() {
        let work = self.work
        self.work = nil
        work?()
    }
}

/// One `MixerEnvironment.scheduleRepeating` job; cancelling stops its timer.
@MainActor
private final class RepeatingWork {
    var timer: Timer?
    private var work: (@MainActor () -> Void)?

    init(_ work: @escaping @MainActor () -> Void) {
        self.work = work
    }

    func run() {
        work?()
    }

    func cancel() {
        work = nil
        timer?.invalidate()
        timer = nil
    }
}
