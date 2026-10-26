import AppKit
import SopranoMixCore

// The seam between the mixer (Mixer/) and its views (Panel/) and the shell (contract
// file; see docs/ARCHITECTURE.md → Mixer, Visual design). Views receive finished models
// and report intents; they never read settings, devices or routes themselves.

/// One entry of a device menu.
struct DeviceMenuItem: Equatable {
    /// nil: follow the system output (first item of an app's output menu).
    var uid: String?
    var title: String
    /// SF Symbol (`DeviceTransport.symbolName`).
    var symbolName: String
    var isSelected: Bool
}

struct SampleRateMenu: Equatable {
    /// "48 kHz", "44.1 kHz".
    var title: String
    /// Ascending, in Hz.
    var rates: [Double]
    var selected: Double
}

/// One of the three device sections at the top of the panel.
struct DeviceSectionModel: Equatable {
    var role: DeviceRole
    /// "Output", "Input", "Sound effects" (the eyebrow view uppercases it).
    var title: String
    /// "No device" when there is none.
    var deviceName: String
    var deviceSymbol: String
    var menu: [DeviceMenuItem]
    /// 0...100; nil hides the slider.
    var volume: Double?
    var volumeText: String
    /// The output's volume is Soprano Mix's software volume (shows the SOFTWARE chip).
    var isSoftwareVolume: Bool
    /// nil hides the mute button.
    var isMuted: Bool?
    /// 0...1, 0.5 centre; nil hides the balance row.
    var balance: Double?
    /// nil hides the sample-rate popup.
    var sampleRate: SampleRateMenu?
}

enum AppRowStatus: Equatable {
    case normal
    case starting
    /// Danger diamond before the name; the reason is the tooltip.
    case failed(String)
}

/// One app row.
struct AppRowModel: Equatable {
    var key: AppKey
    var name: String
    var icon: NSImage
    /// 0...400.
    var volume: Double
    /// "60 %".
    var volumeText: String
    var isMuted: Bool
    var isPlaying: Bool
    /// The target device's name when the app does not follow the system output.
    var outputName: String?
    /// The target device's transport symbol.
    var outputSymbol: String
    /// "System output (<name>)" first, then every output device.
    var outputMenu: [DeviceMenuItem]
    var status: AppRowStatus
}

enum PanelBanner: Equatable {
    /// System Audio Recording is missing: `button` is "Allow" (not determined) or
    /// "Open Settings" (denied).
    case capture(text: String, button: String)
}

struct MixPanelModel: Equatable {
    /// Output, input, sound effects.
    var sections: [DeviceSectionModel]
    var apps: [AppRowModel]
    /// "Nothing is playing" when `apps` is empty, else nil.
    var emptyText: String?
    var banner: PanelBanner?
    /// "settings.json · 2 warnings" while settings.json has issues.
    var footerWarning: String?
}

/// What the user did in the panel.
enum PanelIntent: Equatable {
    /// Percent 0...400; `final` on mouse up / key up (persists at once).
    case setAppVolume(AppKey, Double, final: Bool)
    case toggleAppMute(AppKey)
    /// nil follows the system output.
    case setAppOutput(AppKey, uid: String?)
    case setDefaultDevice(DeviceRole, uid: String)
    /// Percent 0...100: hardware or software volume (output), input volume, alert volume
    /// (sound effects).
    case setDeviceVolume(DeviceRole, Double, final: Bool)
    case toggleDeviceMute(DeviceRole)
    /// 0...1 on the default output.
    case setBalance(Double, final: Bool)
    case setSampleRate(DeviceRole, Double)
    /// The capture banner's button.
    case requestCapture
    case openSettings
    /// The footer gear; the rect is the gear in screen coordinates.
    case showAppMenu(anchor: NSRect)
    /// Escape or a click outside.
    case dismiss
}

@MainActor
protocol MixPanelPresenting: AnyObject {
    var isVisible: Bool { get }
    var onIntent: ((PanelIntent) -> Void)? { get set }
    var onVisibilityChange: ((Bool) -> Void)? { get set }
    /// Shows below `anchor` (the status item button, screen coordinates), else at the
    /// top right of the main screen.
    func show(model: MixPanelModel, theme: AppTheme, anchor: NSRect?)
    /// Re-renders in place; keeps an active slider drag and the scroll position.
    func update(model: MixPanelModel, theme: AppTheme)
    /// Meter positions (`MeterScale`, 0...1) for playing listed apps; others show none.
    func updateLevels(_ levels: [AppKey: Double])
    func dismiss()
    /// The panel as it would show now, offscreen, with its e2 shadow (harness).
    func renderSnapshot(scale: CGFloat) -> CGImage?
}

struct VolumeHUDModel: Equatable {
    var deviceName: String
    /// 0...1.
    var level: Double
    var isMuted: Bool
    /// "Software volume".
    var caption: String
}

@MainActor
protocol VolumeHUDPresenting: AnyObject {
    /// Shows or refreshes the HUD; it hides itself 1.2 s after the last call.
    func show(_ model: VolumeHUDModel, theme: AppTheme)
    /// The model shown last while visible (harness reports).
    var current: VolumeHUDModel? { get }
    func renderSnapshot(scale: CGFloat) -> CGImage?
}

/// Everything the mixer needs from the shell, as closures so tests and the harness can
/// inject them.
struct MixerEnvironment {
    var settings: @MainActor () -> SopranoMixSettings
    var settingsIssueCount: @MainActor () -> Int
    var theme: @MainActor () -> AppTheme
    /// Persists one value at a settings path (`SettingsEditor` semantics), e.g.
    /// `(60, ["apps", "com.spotify.client", "volume"])`.
    /// False when settings.json could not be written (it does not parse); the mixer keeps
    /// the change pending and writes it again after the next settings change.
    var writeSetting: @MainActor (Any, [String]) -> Bool
    /// Runs `work` once after `delay` seconds (0: at once).
    var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// Runs `work` every `interval` seconds until the returned closure is called.
    var scheduleRepeating: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    /// Monotonic seconds (meter ballistics).
    var now: @MainActor () -> TimeInterval
    var ownPID: Int32
    var captureStatus: @MainActor () -> CaptureStatus
    var requestCapture: @MainActor (@escaping @MainActor (CaptureStatus) -> Void) -> Void
    /// The alert (sound effects) volume in percent; nil when unknown.
    var alertVolume: @MainActor () -> Double?
    var setAlertVolume: @MainActor (Double) -> Void
    var openSettingsFile: @MainActor () -> Void
    var showAppMenu: @MainActor (NSRect) -> Void
}
