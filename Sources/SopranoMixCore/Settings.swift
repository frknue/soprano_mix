import Foundation

// Every settings.json type with its default (contract file; see docs/ARCHITECTURE.md →
// Settings). Resolution lives in `SettingsResolver.swift`, the commented first-launch
// file in `SettingsTemplate.swift`.

/// One app's audio (`apps.<key>`).
public struct AppAudioSettings: Equatable, Sendable {
    /// Percent, `VolumeLaw.appRange` (0...400); 100 leaves the app unchanged.
    public var volume: Double = 100
    public var muted = false
    /// An output device UID or name; nil follows the system output ("default" in JSON).
    public var output: String?

    public init(volume: Double = 100, muted: Bool = false, output: String? = nil) {
        self.volume = volume
        self.muted = muted
        self.output = output
    }

    public static let `default` = AppAudioSettings()

    /// 100 %, not muted, following the system output.
    public var isDefault: Bool { volume == 100 && !muted && output == nil }
}

/// The software volume of an output without hardware volume (`outputs.<uid or name>`).
public struct OutputVolumeSettings: Equatable, Sendable {
    /// Percent, `VolumeLaw.outputRange` (0...100).
    public var volume: Double = 100
    public var muted = false

    public init(volume: Double = 100, muted: Bool = false) {
        self.volume = volume
        self.muted = muted
    }

    public static let `default` = OutputVolumeSettings()
}

/// The global shortcut that toggles the panel.
public struct PanelHotkey: Equatable, Sendable {
    public var modifiers: ModifierSet
    public var key: KeySpec

    public init(modifiers: ModifierSet, key: KeySpec) {
        self.modifiers = modifiers
        self.key = key
    }
}

public struct PanelSettings: Equatable, Sendable {
    /// nil: no hotkey.
    public var hotkey: PanelHotkey?
    /// Level meters for playing apps while the panel is open.
    public var meters = true

    public init(hotkey: PanelHotkey? = nil, meters: Bool = true) {
        self.hotkey = hotkey
        self.meters = meters
    }
}

public struct VolumeKeySettings: Equatable, Sendable {
    /// The volume keys change the software volume of outputs without hardware volume
    /// (needs Accessibility).
    public var anyOutput = true
    /// Show Soprano Mix's volume HUD for those changes.
    public var hud = true

    public init(anyOutput: Bool = true, hud: Bool = true) {
        self.anyOutput = anyOutput
        self.hud = hud
    }
}

public struct AudioEngineSettings: Equatable, Sendable {
    /// IO buffer of every route's aggregate device, in frames. Smaller adds less latency
    /// (256 at 48 kHz ≈ 5 ms per buffer) and costs more CPU.
    public var bufferFrames = 256
    /// Limit boosted apps (above 100 %) so they never clip.
    public var limiter = true

    public init(bufferFrames: Int = 256, limiter: Bool = true) {
        self.bufferFrames = bufferFrames
        self.limiter = limiter
    }

    public static let bufferFramesRange = 32...4096
}

public enum MenuBarIcon: String, CaseIterable, Sendable {
    case outlined
    case filled
    case hidden
}

public struct AppBehaviorSettings: Equatable, Sendable {
    /// Registered as a login item (SMAppService) whenever this is true.
    public var startAtLogin = true
    public var menuBarIcon: MenuBarIcon = .outlined

    public init(startAtLogin: Bool = true, menuBarIcon: MenuBarIcon = .outlined) {
        self.startAtLogin = startAtLogin
        self.menuBarIcon = menuBarIcon
    }
}

public struct SopranoMixSettings: Equatable, Sendable {
    /// A Soprano theme id ("folio" follows macOS), or "soprano" to follow the theme and
    /// appearance in ~/.config/soprano/settings.json.
    public var theme = "soprano"
    public var apps: [AppKey: AppAudioSettings] = [:]
    /// Keyed by device UID or name, as written.
    public var outputs: [String: OutputVolumeSettings] = [:]
    public var panel = PanelSettings()
    public var volumeKeys = VolumeKeySettings()
    public var audio = AudioEngineSettings()
    public var app = AppBehaviorSettings()

    public init() {}

    public static let defaults = SopranoMixSettings()

    /// `apps[key]`, else the default.
    public func audio(for key: AppKey) -> AppAudioSettings {
        apps[key] ?? .default
    }

    /// The software volume of an output: `outputs[uid]`, else `outputs[name]`
    /// (case-insensitive), else the default.
    public func outputVolume(for device: AudioDevice) -> OutputVolumeSettings {
        if let byUID = outputs[device.uid] { return byUID }
        if let byName = outputs.first(where: { $0.key.caseInsensitiveCompare(device.name) == .orderedSame }) {
            return byName.value
        }
        return .default
    }

    /// The `outputs` key to write for a device: an existing UID or name entry, else the name.
    public func outputKey(for device: AudioDevice) -> String {
        if outputs[device.uid] != nil { return device.uid }
        if let byName = outputs.keys.first(where: { $0.caseInsensitiveCompare(device.name) == .orderedSame }) {
            return byName
        }
        return device.name
    }
}

/// A problem found while resolving settings.json. Issues never block startup: a bad
/// value keeps its default and is reported (Soprano's `ConfigIssue`).
public struct ConfigIssue: Equatable, Identifiable, Sendable {
    public enum Severity: Equatable, Sendable {
        /// The document could not be read at all; the last good settings stay in force.
        case error
        /// One key was ignored; everything else applied.
        case warning
    }

    public let severity: Severity
    public let message: String
    /// 1-based line in settings.json, when the problem has a position.
    public var line: Int?

    public init(severity: Severity, message: String, line: Int? = nil) {
        self.severity = severity
        self.message = message
        self.line = line
    }

    public var id: String { "\(severity)-\(line ?? 0)-\(message)" }
}

/// The result of resolving settings.json text.
public struct SettingsResolution: Equatable, Sendable {
    /// nil when the document could not be parsed (keep the last good settings);
    /// `issues` then holds one `.error`.
    public var settings: SopranoMixSettings?
    public var issues: [ConfigIssue]

    public init(settings: SopranoMixSettings?, issues: [ConfigIssue]) {
        self.settings = settings
        self.issues = issues
    }
}
