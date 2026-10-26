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
    /// How often missing permissions are re-checked (never prompting).
    private static let permissionPollInterval: TimeInterval = 2

    private var router: LiveAudioRouter?
    private var controller: MixerController?
    private var volumeKeys: VolumeKeyMonitor?
    private var hotkey: CarbonPanelHotkey?
    private var appliedHotkey: PanelHotkey??
    private var menuBar: MenuBarController?
    private var cliServer: CLIServer?
    private var permissionsWindow: PermissionsWindowController?
    private var permissionPoll: Timer?
    private var lastCaptureStatus: CaptureStatus?
    private var appliedStartAtLogin: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.anotherInstanceIsRunning() else {
            NSApp.terminate(nil)
            return
        }
        let settings = SettingsCenter.shared
        settings.start()
        ThemeCenter.shared.start()

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
        lastCaptureStatus = Permissions.captureStatus
        controller.start()

        volumeKeys = VolumeKeyMonitor()
        hotkey = CarbonPanelHotkey()
        menuBar = MenuBarController(
            togglePanel: { [weak self] anchor in
                self?.controller?.togglePanel(anchor: anchor)
            },
            openPermissions: { [weak self] in
                self?.showPermissions()
            }
        )
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

        onboardIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cliServer?.stop()
        permissionPoll?.invalidate()
        volumeKeys?.stop()
        hotkey?.register(nil) {}
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
                do {
                    try SettingsCenter.shared.write(value, at: path)
                } catch {
                    appLog.error("Could not write \(path.joined(separator: "."), privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
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
            captureStatus: { Permissions.captureStatus },
            requestCapture: { [weak self] completion in
                Permissions.requestCapture { status in
                    self?.captureStatusMayHaveChanged(status)
                    completion(status)
                }
            },
            alertVolume: { AlertVolume.get() },
            setAlertVolume: { AlertVolume.set($0) },
            openSettingsFile: { SettingsCenter.shared.openInEditor() },
            showAppMenu: { [weak self] anchor in
                self?.menuBar?.showMenu(at: anchor)
            }
        )
    }

    private static func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != ownPID && !$0.isTerminated }
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

    // MARK: - Volume keys and permissions

    /// Runs the volume-key tap while `volumeKeys.anyOutput` is on and Accessibility is
    /// granted; while it is missing, the permission poll retries.
    private func applyVolumeKeys() {
        guard let volumeKeys, let controller else { return }
        let wanted = SettingsCenter.shared.settings.volumeKeys.anyOutput
        if !wanted {
            if volumeKeys.isRunning {
                volumeKeys.stop()
            }
        } else if !volumeKeys.isRunning, Permissions.isAccessibilityTrusted {
            do {
                try volumeKeys.start { [weak controller] event in
                    controller?.handleVolumeKey(event) ?? false
                }
            } catch {
                appLog.error("Could not start the volume-key tap: \(String(describing: error), privacy: .public)")
            }
        }
        updatePermissionPoll()
    }

    /// Polls every 2 s while the volume keys wait for Accessibility or System Audio
    /// Recording is not granted, so a grant made in System Settings applies without a
    /// relaunch. Never prompts.
    private func updatePermissionPoll() {
        let waitsForAccessibility = SettingsCenter.shared.settings.volumeKeys.anyOutput
            && volumeKeys?.isRunning == false
        let waitsForCapture = !(lastCaptureStatus?.allowsRoutes ?? true)
        if waitsForAccessibility || waitsForCapture {
            guard permissionPoll == nil else { return }
            let timer = Timer(timeInterval: Self.permissionPollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pollPermissions()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            permissionPoll = timer
        } else {
            permissionPoll?.invalidate()
            permissionPoll = nil
        }
    }

    private func pollPermissions() {
        captureStatusMayHaveChanged(Permissions.captureStatus)
        applyVolumeKeys()
    }

    private func captureStatusMayHaveChanged(_ status: CaptureStatus) {
        guard status != lastCaptureStatus else { return }
        lastCaptureStatus = status
        controller?.permissionDidChange()
        permissionsWindow?.refresh()
        updatePermissionPoll()
    }

    /// The first launch with System Audio Recording not determined opens the permissions
    /// window once; the panel's banner asks after that.
    private func onboardIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didRequestPermissionsKey) else { return }
        guard Permissions.captureStatus == .notDetermined else { return }
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
