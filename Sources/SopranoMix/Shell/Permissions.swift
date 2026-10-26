import AppKit
import ApplicationServices
import SopranoMixCore

/// The two privacy grants Soprano Mix uses.
struct PermissionStatus: Equatable {
    /// Required: System Audio Recording, needed to read the process taps behind every
    /// changed app volume, mute and output.
    var capture: CaptureStatus
    /// Optional: the volume-key tap for outputs without hardware volume.
    var accessibility: Bool
}

/// Reads and requests the privacy grants.
@MainActor
enum Permissions {
    enum Kind {
        case audioCapture
        case accessibility
    }

    /// System Audio Recording, from the private TCC preflight (`unknown` without it).
    static var captureStatus: CaptureStatus { PrivateAPIs.audioCapturePreflight() }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static var status: PermissionStatus {
        PermissionStatus(capture: captureStatus, accessibility: isAccessibilityTrusted)
    }

    /// Shows macOS's System Audio Recording prompt (macOS asks only while the status is not
    /// determined) and reports the status afterwards on the main actor. Without the private
    /// request API, opens the matching System Settings pane and reports the current status.
    static func requestCapture(_ completion: @escaping @MainActor (CaptureStatus) -> Void) {
        let callback = CaptureCallback(completion)
        let requested = PrivateAPIs.requestAudioCapture { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    callback.run(Permissions.captureStatus)
                }
            }
        }
        if !requested {
            openSettings(for: .audioCapture)
            completion(captureStatus)
        }
    }

    /// Shows macOS's Accessibility prompt (once per call while not trusted), which also adds
    /// the app to the list in System Settings.
    static func requestAccessibility() {
        // The value of `kAXTrustedCheckOptionPrompt`: the imported global is a mutable C
        // variable, which Swift 6 rejects as not concurrency-safe.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the matching pane of System Settings → Privacy & Security.
    static func openSettings(for kind: Kind) {
        let anchor = switch kind {
        case .audioCapture: "Privacy_AudioCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Carries a main-actor completion through the TCC callback, which may run on any thread;
/// it is only ever called on the main actor.
private final class CaptureCallback: @unchecked Sendable {
    private let work: @MainActor (CaptureStatus) -> Void

    init(_ work: @escaping @MainActor (CaptureStatus) -> Void) {
        self.work = work
    }

    @MainActor
    func run(_ status: CaptureStatus) {
        work(status)
    }
}
