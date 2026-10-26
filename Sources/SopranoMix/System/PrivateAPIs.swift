import Darwin
import Foundation
import SopranoMixCore

/// Private symbols Soprano Mix needs and the public SDK does not offer: the app
/// responsible for a process (helpers, XPC services, WebKit's GPU process) and the System
/// Audio Recording (`kTCCServiceAudioCapture`) status and prompt. Resolved with `dlsym`
/// once, so the binary links nothing private and a symbol a future macOS removes
/// degrades to nil / `.unknown` / false instead of a launch failure.
enum PrivateAPIs {
    private typealias ResponsiblePIDFn = @convention(c) (pid_t) -> pid_t
    /// `TCCAccessPreflightResult TCCAccessPreflight(CFStringRef, CFDictionaryRef)`: an
    /// int-sized enum (0 granted, 1 denied, 2 not determined).
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    /// `void TCCAccessRequest(CFStringRef, CFDictionaryRef, void (^)(Boolean granted))`.
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

    private struct Symbols: @unchecked Sendable {
        let responsiblePID: ResponsiblePIDFn?
        let preflight: PreflightFn?
        let request: RequestFn?
    }

    private static let audioCaptureService = "kTCCServiceAudioCapture"

    private static let symbols: Symbols = {
        // RTLD_DEFAULT: every image already loaded (libsystem_kernel holds the
        // responsibility symbol).
        let anyImage = UnsafeMutableRawPointer(bitPattern: -2)
        let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)
        func load<T>(_ name: String, _ handle: UnsafeMutableRawPointer?) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        return Symbols(
            responsiblePID: load("responsibility_get_pid_responsible_for_pid", anyImage),
            preflight: load("TCCAccessPreflight", tcc),
            request: load("TCCAccessRequest", tcc)
        )
    }()

    /// The pid of the process responsible for `pid` (for a helper, its app; for an app,
    /// itself). nil when the symbol is missing or the answer is not a pid.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function = symbols.responsiblePID else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }

    /// System Audio Recording for this app, without prompting. `.unknown` when TCC's
    /// preflight is unavailable or answers something unexpected.
    static func audioCapturePreflight() -> CaptureStatus {
        guard let function = symbols.preflight else { return .unknown }
        switch function(audioCaptureService as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }

    /// Shows the System Audio Recording prompt (macOS answers at once when already
    /// decided). `done` runs on a TCC queue with the outcome. False, and `done` never
    /// runs, when `TCCAccessRequest` is unavailable.
    static func requestAudioCapture(_ done: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard let function = symbols.request else { return false }
        function(audioCaptureService as CFString, nil) { granted in
            done(granted)
        }
        return true
    }
}
