import AppKit
import OSLog
import SopranoMixCore

private let settingsLog = Logger(subsystem: "com.soprano.mix", category: "settings")

/// Settings, live-reloaded from settings.json (adapted from Soprano Git's `SettingsCenter`).
///
/// A document that does not parse keeps the last good settings running and is reported as
/// an error issue; bad values are warnings (logged), never launch failures.
@MainActor
final class SettingsCenter {
    static let shared = SettingsCenter(fileURL: SettingsFile.url())

    let fileURL: URL
    private(set) var settings = SopranoMixSettings.defaults
    /// Problems in the current document; an `.error` means `settings` are the last good ones.
    private(set) var issues: [ConfigIssue] = []

    private var watcher: ConfigFileWatcher?
    private let observers = ObserverList<Void>()
    private var loggedIssueIDs: Set<String> = []

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var displayPath: String { SettingsFile.displayPath(for: fileURL) }

    /// Creates the file from the template when missing, loads it, and (with `watching`)
    /// reloads it whenever it changes on disk.
    func start(watching: Bool = true) {
        do {
            try SettingsFile.ensureExists(at: fileURL)
        } catch {
            settingsLog.error("Could not create \(self.displayPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        reload()
        if watching, watcher == nil {
            let watcher = ConfigFileWatcher(url: fileURL) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reload()
                }
            }
            watcher.start()
            self.watcher = watcher
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Re-reads and resolves the file; observers fire when the settings or issues changed.
    func reload() {
        let previousSettings = settings
        let previousIssues = issues
        do {
            let text = try SettingsFile.read(at: fileURL)
            let resolution = SettingsResolver.resolve(
                text: text,
                knownThemeIDs: Set(AppTheme.options.map(\.id))
            )
            if let resolved = resolution.settings {
                settings = resolved
            }
            issues = resolution.issues
        } catch {
            issues = [ConfigIssue(severity: .error, message: "Could not read \(displayPath): \(error.localizedDescription)")]
        }
        logIssues()
        if settings != previousSettings || issues != previousIssues {
            observers.notify(())
        }
    }

    /// Sets one value in settings.json, keeping its comments and key order, and applies it.
    func write(_ value: Any, at path: [String]) throws {
        let text = (try? SettingsFile.read(at: fileURL)) ?? SettingsTemplate.text
        let edited = try SettingsEditor.setting(value, at: path, in: text)
        try SettingsFile.write(edited, to: fileURL)
        reload()
    }

    /// Handlers fire after the settings change, until `owner` is deallocated.
    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.add(owner) { _ in handler() }
    }

    /// Opens settings.json in the user's editor for JSON (TextEdit when there is none),
    /// creating it first if needed.
    func openInEditor() {
        try? SettingsFile.ensureExists(at: fileURL)
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(toOpen: fileURL) != nil {
            workspace.open(fileURL)
        } else if let textEdit = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            workspace.open([fileURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func logIssues() {
        for issue in issues where !loggedIssueIDs.contains(issue.id) {
            let location = issue.line.map { "\(displayPath):\($0)" } ?? displayPath
            switch issue.severity {
            case .error: settingsLog.error("\(location, privacy: .public): \(issue.message, privacy: .public)")
            case .warning: settingsLog.warning("\(location, privacy: .public): \(issue.message, privacy: .public)")
            }
        }
        loggedIssueIDs = Set(issues.map(\.id))
    }
}

/// Change handlers keyed by owner. An owner's handlers stop firing once the owner is
/// deallocated, so observers register `[weak self]` handlers and never unregister.
@MainActor
final class ObserverList<Value> {
    private struct Entry {
        weak var owner: AnyObject?
        let handler: @MainActor (Value) -> Void
    }

    private var entries: [Entry] = []

    func add(_ owner: AnyObject, _ handler: @escaping @MainActor (Value) -> Void) {
        entries.append(Entry(owner: owner, handler: handler))
    }

    func notify(_ value: Value) {
        entries.removeAll { $0.owner == nil }
        // Handlers may add observers; iterate over a snapshot.
        for entry in entries where entry.owner != nil {
            entry.handler(value)
        }
    }
}
