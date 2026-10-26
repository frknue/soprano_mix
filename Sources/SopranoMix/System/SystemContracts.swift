import AppKit
import SopranoMixCore

// The seams between the live macOS layer (System/) and everything else (contract file;
// see docs/ARCHITECTURE.md → System APIs). The mixer talks to Core Audio, TCC, event
// taps and hotkeys only through these protocols; Fixtures/ implements them for tests and
// the snapshot harness.

/// Every Core Audio client process with what the resolver needs to group it.
@MainActor
protocol AudioProcessSource: AnyObject {
    /// Current processes, ascending by object id.
    var processes: [AudioProcessFacts] { get }
    /// Fired on the main actor after `processes` changed (coalesced).
    var onChange: (() -> Void)? { get set }
    /// Reads the list and installs the listeners.
    func start()
}

/// The audio devices and the system's default devices.
@MainActor
protocol AudioDeviceControlling: AnyObject {
    var snapshot: DeviceSnapshot { get }
    /// Fired on the main actor after `snapshot` changed (coalesced).
    var onChange: (() -> Void)? { get set }
    func start()
    func setDefaultDevice(_ role: DeviceRole, uid: String)
    /// Hardware volume, 0...1.
    func setVolume(_ scalar: Double, scope: DeviceScope, uid: String)
    func setMuted(_ muted: Bool, scope: DeviceScope, uid: String)
    /// 0 left … 0.5 centre … 1 right.
    func setBalance(_ balance: Double, uid: String)
    func setSampleRate(_ rate: Double, uid: String)
}

enum RouteStatus: Equatable, Sendable {
    case starting
    case running
    /// A human-readable reason ("The output device is gone.", "Core Audio error 'nope'").
    case failed(String)
}

/// Keeps the live taps, aggregate devices and IOProcs equal to a `RoutePlan`.
@MainActor
protocol AudioRouting: AnyObject {
    /// Creates, updates in place and destroys routes so the live state matches `plan`.
    /// Returns at once; building happens off the main actor.
    func apply(_ plan: RoutePlan)
    /// One entry per app route of the last applied plan.
    var statuses: [AppKey: RouteStatus] { get }
    /// nil without a master route.
    var masterStatus: RouteStatus? { get }
    /// Fired on the main actor when `statuses` or `masterStatus` changed.
    var onStatusChange: (() -> Void)? { get set }
    /// Peaks per app route since the last call (then reset).
    func takeLevels() -> [AppKey: RouteLevels]
    /// Stops and destroys every route synchronously (quit).
    func stopAll()
}

@MainActor
protocol AppIconProviding: AnyObject {
    /// Never fails: falls back to a generic icon. Cached per app key.
    func icon(for app: AudioApp) -> NSImage
}

enum EventTapError: Error, Equatable {
    case accessibilityDenied
    case creationFailed
}

/// The keyboard's volume keys (up, down, mute), system-wide.
@MainActor
protocol VolumeKeyTapping: AnyObject {
    var isRunning: Bool { get }
    /// `handler` returns true to consume the event. Throws `.accessibilityDenied` without
    /// Accessibility.
    func start(handler: @escaping @MainActor (VolumeKeyEvent) -> Bool) throws
    func stop()
}

/// The global shortcut that toggles the panel.
@MainActor
protocol PanelHotkeyRegistering: AnyObject {
    /// Replaces the registration; nil unregisters. False when macOS refused the combo.
    @discardableResult
    func register(_ hotkey: PanelHotkey?, action: @escaping @MainActor () -> Void) -> Bool
}
