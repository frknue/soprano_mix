import AppKit
import ApplicationServices
import SopranoMixCore

/// The keyboard's volume keys as `NX_SYSDEFINED` events (subtype 8, aux control buttons).
enum VolumeKeyConversion {
    /// `NX_SYSDEFINED`.
    static let systemDefinedEventType: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`.
    static let auxControlButtonsSubtype: Int16 = 8

    /// The volume key in an aux-control event's `data1`: key code in bits 16–31
    /// (`NX_KEYTYPE_SOUND_UP` 0, `…_DOWN` 1, `…_MUTE` 7), key state in bits 8–15 (0xA
    /// down, 0xB up), repeat in bit 0. `fine` when Option and Shift are both held. nil for
    /// other keys (brightness, media) and other states.
    static func event(data1: Int, flags: CGEventFlags) -> VolumeKeyEvent? {
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyState = (data1 & 0xFF00) >> 8
        let isRepeat = data1 & 0x1 == 1

        let key: VolumeKey
        switch keyCode {
        case 0: key = .up
        case 1: key = .down
        case 7: key = .mute
        default: return nil
        }

        let isDown: Bool
        switch keyState {
        case 0xA: isDown = true
        case 0xB: isDown = false
        default: return nil
        }

        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        return VolumeKeyEvent(key: key, isDown: isDown, isRepeat: isRepeat, fine: fine)
    }
}

/// A system-wide `CGEventTap` (session, head, default) for `NX_SYSDEFINED` events, on its
/// own thread and run loop. The callback decides each volume key there through a
/// `VolumeKeyGate` and never waits for the main thread: macOS gives an active tap about a
/// second, then disables it and drops what it held, and a lost key-up makes macOS repeat
/// the key (and keep its volume HUD up) until the next press. Every volume key then
/// reaches `handler` on the main queue with the decision.
///
/// The tap thread owns a retained reference to the shared state and releases it after its
/// run loop ends, so no callback outlives it.
@MainActor
final class VolumeKeyMonitor: VolumeKeyTapping {
    private struct RunningTap {
        let tap: CFMachPort
        let source: CFRunLoopSource
        let runLoop: CFRunLoop
    }

    private let state = VolumeKeyTapState()
    private var running: RunningTap?

    init() {}

    var isRunning: Bool { running != nil }

    func setIntercepts(_ intercepts: Bool) {
        state.setIntercepts(intercepts)
    }

    func start(handler: @escaping @MainActor @Sendable (VolumeKeyEvent, Bool) -> Void) throws {
        state.setHandler(handler)
        guard running == nil else { return }
        guard AXIsProcessTrusted() else {
            state.setHandler(nil)
            throw EventTapError.accessibilityDenied
        }

        let refcon = Unmanaged.passRetained(state).toOpaque()
        let mask = CGEventMask(1) << CGEventMask(VolumeKeyConversion.systemDefinedEventType)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: volumeKeyTapCallback,
            userInfo: refcon
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Unmanaged<VolumeKeyTapState>.fromOpaque(refcon).release()
            state.setHandler(nil)
            throw EventTapError.creationFailed
        }
        state.begin(tap: tap)

        let thread = VolumeKeyTapThread(source: source, refcon: refcon)
        let runLoop = thread.start()
        CGEvent.tapEnable(tap: tap, enable: true)
        running = RunningTap(tap: tap, source: source, runLoop: runLoop)
    }

    /// Removes the tap; a no-op when it is not running.
    func stop() {
        guard let running else { return }
        self.running = nil
        state.end()
        CGEvent.tapEnable(tap: running.tap, enable: false)
        CFRunLoopSourceInvalidate(running.source)
        CFMachPortInvalidate(running.tap)
        CFRunLoopStop(running.runLoop)
    }
}

/// What the tap thread and the main thread share, behind a lock.
private final class VolumeKeyTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = VolumeKeyGate()
    private var tap: CFMachPort?
    private var handler: (@MainActor @Sendable (VolumeKeyEvent, Bool) -> Void)?

    func setIntercepts(_ intercepts: Bool) {
        lock.withLock { gate.intercepts = intercepts }
    }

    func setHandler(_ handler: (@MainActor @Sendable (VolumeKeyEvent, Bool) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    /// A new tap: no press is known yet.
    func begin(tap: CFMachPort) {
        lock.withLock {
            self.tap = tap
            gate = VolumeKeyGate(intercepts: gate.intercepts)
        }
    }

    func end() {
        lock.withLock {
            tap = nil
            handler = nil
        }
    }

    /// On the tap thread. True consumes the event.
    func decide(_ event: VolumeKeyEvent) -> Bool {
        let (consumed, handler) = lock.withLock { (gate.consumes(event), self.handler) }
        if let handler {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler(event, consumed) }
            }
        }
        return consumed
    }

    /// On the tap thread, after macOS disabled the tap (a slow callback or secure input).
    func reenable() {
        guard let tap = lock.withLock({ tap }) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

/// The tap's thread: adds the run-loop source to its own run loop and runs it until the
/// source is invalidated or the loop stopped, then releases the tap's state reference.
private final class VolumeKeyTapThread: @unchecked Sendable {
    private let source: CFRunLoopSource
    private let refcon: UnsafeMutableRawPointer
    private var runLoop: CFRunLoop?
    private let started = DispatchSemaphore(value: 0)

    init(source: CFRunLoopSource, refcon: UnsafeMutableRawPointer) {
        self.source = source
        self.refcon = refcon
    }

    /// Starts the thread and returns its run loop once the source is on it.
    func start() -> CFRunLoop {
        let thread = Thread { [self] in
            let current = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(current, source, .commonModes)
            runLoop = current
            started.signal()
            CFRunLoopRun()
            Unmanaged<VolumeKeyTapState>.fromOpaque(refcon).release()
        }
        thread.name = "com.soprano.mix.volume-keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        return runLoop!
    }
}

/// The C callback, on the tap thread.
private func volumeKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<VolumeKeyTapState>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        state.reenable()
        return Unmanaged.passUnretained(event)
    default:
        break
    }
    guard type.rawValue == VolumeKeyConversion.systemDefinedEventType,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == VolumeKeyConversion.auxControlButtonsSubtype,
          let keyEvent = VolumeKeyConversion.event(data1: nsEvent.data1, flags: event.flags)
    else { return Unmanaged.passUnretained(event) }
    return state.decide(keyEvent) ? nil : Unmanaged.passUnretained(event)
}
