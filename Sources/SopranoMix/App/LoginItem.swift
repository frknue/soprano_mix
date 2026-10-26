import Foundation
import OSLog
import ServiceManagement

private let loginItemLog = Logger(subsystem: "com.soprano.mix", category: "login-item")

/// Keeps the app's login item registration in line with `app.startAtLogin`.
@MainActor
enum LoginItem {
    /// Only the installed app registers: a login item for the dev build would start a
    /// second Soprano Mix at login, and only one may run.
    static let installedBundleID = "com.soprano.mix"

    /// Registers or unregisters `SMAppService.mainApp`. A no-op for an unbundled binary
    /// (`swift run`), which macOS cannot launch at login, and for every bundle id but
    /// `installedBundleID` (the dev build); errors are logged, never fatal.
    static func sync(enabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == installedBundleID else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status == .enabled || service.status == .requiresApproval else { return }
                try service.unregister()
            }
        } catch {
            let action = enabled ? "register" : "unregister"
            loginItemLog.error("Could not \(action, privacy: .public) the login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
