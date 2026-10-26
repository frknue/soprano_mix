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

/// A system-wide `CGEventTap` (session, head, default) for `NX_SYSDEFINED` events. Its
/// run-loop source lives on the main run loop, so the callback runs on the main thread
/// and calls `handler` synchronously; true consumes the event, false passes it on.
///
/// While running, the tap's refcon holds a retained reference to the monitor; `stop()`
/// releases it, so the monitor stays alive for as long as its tap can call back.
@MainActor
final class VolumeKeyMonitor: VolumeKeyTapping {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var refcon: UnsafeMutableRawPointer?
    private var handler: (@MainActor (VolumeKeyEvent) -> Bool)?

    init() {}

    var isRunning: Bool { tap != nil }

    /// Starts the tap. Calling it while running only replaces the handler.
    func start(handler: @escaping @MainActor (VolumeKeyEvent) -> Bool) throws {
        if isRunning {
            self.handler = handler
            return
        }
        guard AXIsProcessTrusted() else { throw EventTapError.accessibilityDenied }

        let refcon = Unmanaged.passRetained(self).toOpaque()
        let mask = CGEventMask(1) << CGEventMask(VolumeKeyConversion.systemDefinedEventType)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: volumeKeyTapCallback,
            userInfo: refcon
        ) else {
            Unmanaged<VolumeKeyMonitor>.fromOpaque(refcon).release()
            throw EventTapError.creationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.handler = handler
        self.tap = tap
        self.runLoopSource = source
        self.refcon = refcon
    }

    /// Removes the tap; a no-op when it is not running.
    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
        handler = nil
        if let refcon {
            self.refcon = nil
            Unmanaged<VolumeKeyMonitor>.fromOpaque(refcon).release()
        }
    }

    /// Returns true to consume the event. macOS disables a tap whose callback was too
    /// slow or that secure input interrupted; it then sends a `tapDisabledBy…` event, and
    /// the tap turns itself back on and lets that event through.
    fileprivate func receive(type: CGEventType, keyEvent: VolumeKeyEvent?) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        default:
            guard let keyEvent, let handler else { return false }
            return handler(keyEvent)
        }
    }
}

/// The C callback. The run-loop source is on the main run loop, so this runs on the main
/// thread; only Sendable values (the converted event, the monitor's address) cross into
/// the main-actor closure.
private func volumeKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    var converted: VolumeKeyEvent?
    if type.rawValue == VolumeKeyConversion.systemDefinedEventType,
       let nsEvent = NSEvent(cgEvent: event),
       nsEvent.subtype.rawValue == VolumeKeyConversion.auxControlButtonsSubtype {
        converted = VolumeKeyConversion.event(data1: nsEvent.data1, flags: event.flags)
    }
    let keyEvent = converted
    let monitorAddress = Int(bitPattern: refcon)
    let consume = MainActor.assumeIsolated { () -> Bool in
        guard let pointer = UnsafeRawPointer(bitPattern: monitorAddress) else { return false }
        let monitor = Unmanaged<VolumeKeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
        return monitor.receive(type: type, keyEvent: keyEvent)
    }
    return consume ? nil : Unmanaged.passUnretained(event)
}
