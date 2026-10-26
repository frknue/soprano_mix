import CoreGraphics
import Foundation

// Shared model types (contract file: change only together with every consumer; see
// docs/ARCHITECTURE.md). Core Audio object ids are plain UInt32 here: Core never imports
// Core Audio.

// MARK: - Apps

/// The identity under which an app's audio is grouped, listed and remembered in
/// settings.json (`apps.<rawValue>`): a bundle id, `wine:<Name>` for Wine (CrossOver)
/// programs, `exe:<name>` for programs without a bundle.
public struct AppKey: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func bundle(_ bundleID: String) -> AppKey { AppKey(rawValue: bundleID) }
    public static func wine(_ name: String) -> AppKey { AppKey(rawValue: "wine:" + name) }
    public static func executable(_ name: String) -> AppKey { AppKey(rawValue: "exe:" + name) }

    public static func < (lhs: AppKey, rhs: AppKey) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A running macOS app as the system layer saw it.
public struct RunningAppInfo: Equatable, Sendable {
    /// nil for an app bundle found on disk only (`enclosingApp`).
    public var pid: Int32?
    public var bundleID: String
    public var name: String
    /// The .app path, when known.
    public var bundlePath: String?

    public init(pid: Int32?, bundleID: String, name: String, bundlePath: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
    }
}

/// Everything the system layer knows about one Core Audio process object. Gathered by
/// `LiveAudioProcessSource`, grouped by `AudioAppResolver`.
public struct AudioProcessFacts: Equatable, Sendable {
    /// The Core Audio process object id.
    public var objectID: UInt32
    public var pid: Int32
    /// `kAudioProcessPropertyBundleID`; nil when empty.
    public var bundleID: String?
    /// `proc_pidpath`; nil when unreadable.
    public var executablePath: String?
    /// argv from `KERN_PROCARGS2`; empty when unreadable. Wine puts the Windows path of
    /// the program (`C:\…\Game.exe`) in argv[0].
    public var arguments: [String]
    /// `WINEPREFIX` from the process environment, read for Wine processes only.
    public var wineprefix: String?
    /// The app responsible for this process (`responsibility_get_pid_responsible_for_pid`),
    /// only when it differs from `pid` and has a bundle id.
    public var responsible: RunningAppInfo?
    /// The outermost `.app` bundle around `executablePath` (pid nil).
    public var enclosingApp: RunningAppInfo?
    /// `NSRunningApplication(processIdentifier: pid)` when it has a bundle id.
    public var ownApp: RunningAppInfo?
    /// `kAudioProcessPropertyIsRunningOutput`.
    public var isRunningOutput: Bool
    /// `kAudioProcessPropertyIsRunningInput`.
    public var isRunningInput: Bool

    public init(
        objectID: UInt32,
        pid: Int32,
        bundleID: String? = nil,
        executablePath: String? = nil,
        arguments: [String] = [],
        wineprefix: String? = nil,
        responsible: RunningAppInfo? = nil,
        enclosingApp: RunningAppInfo? = nil,
        ownApp: RunningAppInfo? = nil,
        isRunningOutput: Bool = false,
        isRunningInput: Bool = false
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.arguments = arguments
        self.wineprefix = wineprefix
        self.responsible = responsible
        self.enclosingApp = enclosingApp
        self.ownApp = ownApp
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
    }
}

public enum AppKind: String, Equatable, Codable, Sendable {
    /// A macOS app (or a helper folded into one).
    case app
    /// A Windows program under Wine (CrossOver, Whisky, Wine).
    case wine
    /// A bundled system process without an app (System Sounds, Siri).
    case system
    /// A program without a bundle (afplay, mpv, ffplay).
    case executable
}

/// Where an app's icon comes from; `AppIconProviding` turns it into an image.
public enum IconSource: Equatable, Hashable, Sendable {
    /// An .app bundle on disk.
    case bundle(path: String)
    /// A running app without a known bundle path.
    case runningApp(pid: Int32)
    /// A Windows program: its icon from the .exe inside the Wine prefix.
    case windowsExecutable(windowsPath: String, wineprefix: String?)
    /// A plain executable file.
    case executable(path: String?)
    /// An SF Symbol name.
    case symbol(String)
}

/// One process's resolved identity (`AudioAppResolver.identity`).
public struct AppIdentity: Equatable, Sendable {
    public var key: AppKey
    public var name: String
    public var kind: AppKind
    public var icon: IconSource

    public init(key: AppKey, name: String, kind: AppKind, icon: IconSource) {
        self.key = key
        self.name = name
        self.kind = kind
        self.icon = icon
    }
}

/// One app as the mixer shows it: every process object with the same identity.
public struct AudioApp: Equatable, Identifiable, Sendable {
    public var key: AppKey
    public var name: String
    public var kind: AppKind
    public var icon: IconSource
    /// Ascending, unique.
    public var processObjectIDs: [UInt32]
    /// Ascending, unique.
    public var pids: [Int32]
    /// Any process is running output.
    public var isPlaying: Bool

    public var id: AppKey { key }

    public init(
        key: AppKey,
        name: String,
        kind: AppKind,
        icon: IconSource,
        processObjectIDs: [UInt32],
        pids: [Int32],
        isPlaying: Bool
    ) {
        self.key = key
        self.name = name
        self.kind = kind
        self.icon = icon
        self.processObjectIDs = processObjectIDs
        self.pids = pids
        self.isPlaying = isPlaying
    }
}

// MARK: - Devices

public enum DeviceTransport: String, CaseIterable, Codable, Sendable {
    case builtIn, usb, bluetooth, hdmi, displayPort, airPlay, thunderbolt, pci, fireWire
    case virtual, aggregate, continuity, unknown

    /// The SF Symbol the panel shows for this transport.
    public var symbolName: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .usb: "cable.connector"
        case .bluetooth: "headphones"
        case .hdmi, .displayPort, .thunderbolt: "tv"
        case .airPlay: "airplayaudio"
        case .continuity: "iphone"
        case .virtual, .aggregate: "square.stack.3d.up"
        case .pci, .fireWire, .unknown: "hifispeaker"
        }
    }
}

public enum DeviceRole: String, CaseIterable, Codable, Sendable {
    /// The default output (`kAudioHardwarePropertyDefaultOutputDevice`).
    case output
    /// The default input.
    case input
    /// The sound-effects output (`kAudioHardwarePropertyDefaultSystemOutputDevice`).
    case soundEffects
}

public enum DeviceScope: String, Codable, Sendable {
    case output, input
}

public struct AudioDevice: Equatable, Identifiable, Sendable {
    public var objectID: UInt32
    public var uid: String
    public var name: String
    public var transport: DeviceTransport
    public var outputChannels: Int
    public var inputChannels: Int
    /// Settable hardware output volume, 0...1; nil when the device has none (HDMI,
    /// DisplayPort): Soprano Mix then offers software volume.
    public var outputVolume: Double?
    /// Settable input volume (gain), 0...1; nil when none.
    public var inputVolume: Double?
    /// nil when the device has no settable mute in that scope.
    public var outputMuted: Bool?
    public var inputMuted: Bool?
    /// Settable stereo balance, 0 left … 0.5 centre … 1 right; nil when none.
    public var balance: Double?
    /// Nominal sample rate in Hz.
    public var sampleRate: Double
    /// Available nominal rates, ascending (discrete values; ranges contribute their ends).
    public var sampleRates: [Double]

    public var id: String { uid }
    public var hasOutput: Bool { outputChannels > 0 }
    public var hasInput: Bool { inputChannels > 0 }

    public init(
        objectID: UInt32,
        uid: String,
        name: String,
        transport: DeviceTransport,
        outputChannels: Int,
        inputChannels: Int,
        outputVolume: Double? = nil,
        inputVolume: Double? = nil,
        outputMuted: Bool? = nil,
        inputMuted: Bool? = nil,
        balance: Double? = nil,
        sampleRate: Double = 48_000,
        sampleRates: [Double] = [44_100, 48_000]
    ) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.transport = transport
        self.outputChannels = outputChannels
        self.inputChannels = inputChannels
        self.outputVolume = outputVolume
        self.inputVolume = inputVolume
        self.outputMuted = outputMuted
        self.inputMuted = inputMuted
        self.balance = balance
        self.sampleRate = sampleRate
        self.sampleRates = sampleRates
    }
}

public struct DeviceSnapshot: Equatable, Sendable {
    /// Visible devices (no hidden ones, none of Soprano Mix's own aggregates), sorted by name.
    public var devices: [AudioDevice]
    public var defaultOutputUID: String?
    public var defaultInputUID: String?
    public var soundEffectsUID: String?

    public init(devices: [AudioDevice] = [], defaultOutputUID: String? = nil, defaultInputUID: String? = nil, soundEffectsUID: String? = nil) {
        self.devices = devices
        self.defaultOutputUID = defaultOutputUID
        self.defaultInputUID = defaultInputUID
        self.soundEffectsUID = soundEffectsUID
    }

    public func device(uid: String?) -> AudioDevice? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    public var outputs: [AudioDevice] { devices.filter(\.hasOutput) }
    public var inputs: [AudioDevice] { devices.filter(\.hasInput) }
    public var defaultOutput: AudioDevice? { device(uid: defaultOutputUID) }
    public var defaultInput: AudioDevice? { device(uid: defaultInputUID) }
    public var soundEffects: AudioDevice? { device(uid: soundEffectsUID) }

    public func uid(for role: DeviceRole) -> String? {
        switch role {
        case .output: defaultOutputUID
        case .input: defaultInputUID
        case .soundEffects: soundEffectsUID
        }
    }

    /// An output device by UID, else by name (case-insensitive); nil for nil or no match.
    public func output(matching query: String?) -> AudioDevice? {
        guard let query, !query.isEmpty else { return nil }
        let outputs = outputs
        if let byUID = outputs.first(where: { $0.uid == query }) { return byUID }
        return outputs.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    }
}

// MARK: - Levels and routes

/// Linear peak amplitudes (1 = 0 dBFS).
public struct StereoLevel: Equatable, Sendable {
    public var left: Float
    public var right: Float

    public init(left: Float, right: Float) {
        self.left = left
        self.right = right
    }

    public static let silent = StereoLevel(left: 0, right: 0)
    public var peak: Float { max(left, right) }

    /// The louder of both, channel by channel.
    public func merged(with other: StereoLevel) -> StereoLevel {
        StereoLevel(left: max(left, other.left), right: max(right, other.right))
    }
}

/// One route's peaks since the last read: tapped input and what went to the device.
public struct RouteLevels: Equatable, Sendable {
    public var input: StereoLevel
    public var output: StereoLevel

    public init(input: StereoLevel, output: StereoLevel) {
        self.input = input
        self.output = output
    }

    public static let silent = RouteLevels(input: .silent, output: .silent)
}

public enum TapMode: String, Equatable, Codable, Sendable {
    /// Mute the app's own output (`.mutedWhenTapped`) and play it again at `gain`.
    case replace
    /// Read the app's audio for its meter only (`.unmuted`); nothing is written.
    case meter
}

/// One app route the router keeps alive.
public struct RouteSpec: Equatable, Sendable {
    public var key: AppKey
    /// The app's Core Audio process objects, ascending.
    public var processObjectIDs: [UInt32]
    public var outputDeviceUID: String
    /// Linear gain (0 when muted), software output gain included.
    public var gain: Float
    public var mode: TapMode
    public var limiter: Bool
    public var bufferFrames: Int

    public init(key: AppKey, processObjectIDs: [UInt32], outputDeviceUID: String, gain: Float, mode: TapMode, limiter: Bool, bufferFrames: Int) {
        self.key = key
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        self.gain = gain
        self.mode = mode
        self.limiter = limiter
        self.bufferFrames = bufferFrames
    }
}

/// The software-volume route of an output without hardware volume: every process on it
/// except Soprano Mix and the excluded ones, played again at `gain`.
public struct MasterRouteSpec: Equatable, Sendable {
    public var outputDeviceUID: String
    public var gain: Float
    /// Process objects with their own replace route, ascending. The router adds Soprano
    /// Mix's own process object.
    public var excludedProcessObjectIDs: [UInt32]
    public var bufferFrames: Int

    public init(outputDeviceUID: String, gain: Float, excludedProcessObjectIDs: [UInt32], bufferFrames: Int) {
        self.outputDeviceUID = outputDeviceUID
        self.gain = gain
        self.excludedProcessObjectIDs = excludedProcessObjectIDs
        self.bufferFrames = bufferFrames
    }
}

public struct RoutePlan: Equatable, Sendable {
    /// Sorted by key.
    public var routes: [RouteSpec]
    public var master: MasterRouteSpec?

    public init(routes: [RouteSpec] = [], master: MasterRouteSpec? = nil) {
        self.routes = routes
        self.master = master
    }

    public static let empty = RoutePlan()

    public func route(for key: AppKey) -> RouteSpec? {
        routes.first { $0.key == key }
    }
}

// MARK: - Volume keys

public enum VolumeKey: String, Equatable, Sendable {
    case up, down, mute
}

/// One volume key press or release from the keyboard (`NX_SYSDEFINED`, subtype 8).
public struct VolumeKeyEvent: Equatable, Sendable {
    public var key: VolumeKey
    public var isDown: Bool
    public var isRepeat: Bool
    /// Option+Shift held: quarter steps, like macOS.
    public var fine: Bool

    public init(key: VolumeKey, isDown: Bool, isRepeat: Bool = false, fine: Bool = false) {
        self.key = key
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.fine = fine
    }
}

// MARK: - Permission

/// System Audio Recording (`kTCCServiceAudioCapture`).
public enum CaptureStatus: String, Equatable, Codable, Sendable {
    case granted
    case denied
    case notDetermined
    /// The private TCC preflight is unavailable; routes are attempted.
    case unknown

    /// Routes may be created.
    public var allowsRoutes: Bool { self == .granted || self == .unknown }
}
