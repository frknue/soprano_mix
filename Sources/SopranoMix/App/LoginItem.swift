import Foundation
import OSLog
import ServiceManagement

private let loginItemLog = Logger(subsystem: "com.soprano.mix", category: "login-item")

/// Keeps the app's login item registration in line with `app.startAtLogin`.
@MainActor
enum LoginItem {
    /// Registers or unregisters `SMAppService.mainApp`. A no-op for an unbundled binary
    /// (`swift run`), which macOS cannot launch at login; errors are logged, never fatal.
    static func sync(enabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
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
