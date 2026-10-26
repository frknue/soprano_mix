import Foundation

// Messages between `SopranoMix <command>` and the running app, JSON over the
// CFMessagePort "<bundle id>.cli" (CLIServer / CLIClient in the app target).

public enum CLIRequest: Codable, Equatable, Sendable {
    case list
    case devices
    /// `app` goes through `AppMatcher`; percent in `VolumeLaw.appRange`.
    case setVolume(app: String, percent: Double)
    /// nil toggles.
    case setMuted(app: String, muted: Bool?)
    /// `device` is a UID or name; nil follows the system output.
    case setOutput(app: String, device: String?)
    case show
    case hide
}

/// One app in `list` output (and the app a change applied to).
public struct CLIApp: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var kind: String
    public var volume: Double
    public var muted: Bool
    /// The settings value: a device UID or name; nil follows the system output.
    public var output: String?
    /// The device the app plays on now.
    public var outputName: String?
    public var playing: Bool
    /// A route (tap) is active for it.
    public var routed: Bool
    public var pids: [Int32]

    public init(key: String, name: String, kind: String, volume: Double, muted: Bool, output: String?,
                outputName: String?, playing: Bool, routed: Bool, pids: [Int32]) {
        self.key = key
        self.name = name
        self.kind = kind
        self.volume = volume
        self.muted = muted
        self.output = output
        self.outputName = outputName
        self.playing = playing
        self.routed = routed
        self.pids = pids
    }
}

public struct CLIDevice: Codable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var transport: String
    public var output: Bool
    public var input: Bool
    public var defaultOutput: Bool
    public var defaultInput: Bool
    public var soundEffects: Bool
    /// Hardware output volume in percent, or the software volume; nil without either.
    public var volume: Double?
    public var softwareVolume: Bool
    public var muted: Bool?
    public var sampleRate: Double

    public init(uid: String, name: String, transport: String, output: Bool, input: Bool, defaultOutput: Bool,
                defaultInput: Bool, soundEffects: Bool, volume: Double?, softwareVolume: Bool, muted: Bool?,
                sampleRate: Double) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.output = output
        self.input = input
        self.defaultOutput = defaultOutput
        self.defaultInput = defaultInput
        self.soundEffects = soundEffects
        self.volume = volume
        self.softwareVolume = softwareVolume
        self.muted = muted
        self.sampleRate = sampleRate
    }
}

public struct CLIResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var apps: [CLIApp]?
    public var devices: [CLIDevice]?
    /// The app a `setVolume` / `setMuted` / `setOutput` applied to.
    public var app: CLIApp?

    public init(ok: Bool, error: String? = nil, apps: [CLIApp]? = nil, devices: [CLIDevice]? = nil, app: CLIApp? = nil) {
        self.ok = ok
        self.error = error
        self.apps = apps
        self.devices = devices
        self.app = app
    }

    public static func failure(_ message: String) -> CLIResponse {
        CLIResponse(ok: false, error: message)
    }
}
