import Foundation

/// Core Audio process objects → the apps the mixer lists: helpers, renderers, WebKit's
/// GPU process and XPC services fold into their app; Wine programs become their own app
/// (never CrossOver); unbundled programs stay themselves.
public enum AudioAppResolver {
    /// Friendly names of system processes that play audio, by bundle id or executable name.
    public static let systemNames: [String: String] = [
        "systemsoundserverd": "System Sounds",
        "com.apple.assistantd": "Siri",
        "com.apple.CoreSpeech": "Siri",
        "com.apple.corespeechd_system": "Siri",
        "com.apple.speech.speechsynthesisd": "Spoken Content",
        "com.apple.avconferenced": "FaceTime",
        "com.apple.accessibility.heard": "Hearing",
        // Only reached when a Wine process's argv (its Windows path) cannot be read; its
        // executable path is then a temporary copy with a misleading name.
        "com.codeweavers.CrossOver.wineloader": "CrossOver (Windows)",
    ]

    /// Friendly names served by several processes share one key, so they are one row
    /// and one settings entry.
    private static let systemKeys: [String: String] = [
        "Siri": "com.apple.assistantd",
    ]

    private static let wineLoaderBundleID = "com.codeweavers.CrossOver.wineloader"

    /// One process's identity; nil for Soprano Mix itself (`pid == ownPID`).
    public static func identity(for process: AudioProcessFacts, ownPID: Int32) -> AppIdentity? {
        resolved(process, ownPID: ownPID)?.identity
    }

    /// Every process grouped by identity key, sorted by name
    /// (`localizedStandardCompare`), then key.
    public static func apps(from processes: [AudioProcessFacts], ownPID: Int32) -> [AudioApp] {
        var order: [AppKey] = []
        var groups: [AppKey: [(process: AudioProcessFacts, resolution: Resolution)]] = [:]
        for process in processes {
            guard let resolution = resolved(process, ownPID: ownPID) else { continue }
            let key = resolution.identity.key
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append((process, resolution))
        }

        let apps = order.compactMap { key -> AudioApp? in
            guard let members = groups[key], let primary = primaryMember(of: members) else { return nil }
            let identity = primary.resolution.identity
            return AudioApp(
                key: key,
                name: identity.name,
                kind: identity.kind,
                icon: identity.icon,
                processObjectIDs: Array(Set(members.map { $0.process.objectID })).sorted(),
                pids: Array(Set(members.map { $0.process.pid })).sorted(),
                isPlaying: members.contains { $0.process.isRunningOutput }
            )
        }
        return apps.sorted(by: isOrderedBefore)
    }

    /// Name (`localizedStandardCompare`), then key: the order of every app list.
    public static func isOrderedBefore(_ lhs: AudioApp, _ rhs: AudioApp) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order == .orderedSame { return lhs.key < rhs.key }
        return order == .orderedAscending
    }

    // MARK: Rules

    private struct Resolution {
        var identity: AppIdentity
        /// Rule 5: the process is the app itself.
        var isAppItself: Bool
    }

    /// The group's face: the app itself (rule 5), else the lowest pid (then object id).
    private static func primaryMember(
        of members: [(process: AudioProcessFacts, resolution: Resolution)]
    ) -> (process: AudioProcessFacts, resolution: Resolution)? {
        if let itself = members.filter({ $0.resolution.isAppItself }).min(by: { isLower($0.process, $1.process) }) {
            return itself
        }
        return members.min { isLower($0.process, $1.process) }
    }

    private static func isLower(_ lhs: AudioProcessFacts, _ rhs: AudioProcessFacts) -> Bool {
        (lhs.pid, lhs.objectID) < (rhs.pid, rhs.objectID)
    }

    /// The identity rules, first match wins (docs/ARCHITECTURE.md → Grouping processes).
    private static func resolved(_ process: AudioProcessFacts, ownPID: Int32) -> Resolution? {
        // 1. Soprano Mix itself.
        if process.pid == ownPID { return nil }

        // 2. Wine: before the bundle rules, because Wine's loader lives inside CrossOver.app.
        let candidates = [process.arguments.first, process.executablePath].compactMap { $0 }
        if let windowsPath = candidates.first(where: WinePath.isWindowsPath) {
            let name = WinePath.appName(forWindowsPath: windowsPath)
            return Resolution(
                identity: AppIdentity(
                    key: .wine(name),
                    name: name,
                    kind: .wine,
                    icon: .windowsExecutable(windowsPath: windowsPath, wineprefix: process.wineprefix)
                ),
                isAppItself: false
            )
        }

        // 3. Unbundled program: never folds into the app that launched it.
        if process.bundleID == nil, process.enclosingApp == nil {
            let name = lastComponent(process.executablePath)
                ?? lastComponent(process.arguments.first)
                ?? "pid \(process.pid)"
            return Resolution(
                identity: AppIdentity(key: .executable(name), name: name, kind: .executable, icon: .executable(path: process.executablePath)),
                isAppItself: false
            )
        }

        // A Wine process whose Windows path could not be read: CrossOver may be its
        // responsible app, but folding a game into the CrossOver launcher would hide it.
        if process.bundleID == wineLoaderBundleID {
            return systemResolution(process)
        }

        // 4. The responsible app: helpers, renderers, WebKit GPU, XPC services.
        if let responsible = process.responsible, responsible.pid != process.pid {
            return Resolution(
                identity: AppIdentity(
                    key: .bundle(responsible.bundleID),
                    name: responsible.name,
                    kind: .app,
                    icon: icon(for: responsible, fallback: responsible.pid.map { .runningApp(pid: $0) })
                ),
                isAppItself: false
            )
        }

        // 5. The app itself.
        if let ownApp = process.ownApp {
            return Resolution(
                identity: AppIdentity(
                    key: .bundle(ownApp.bundleID),
                    name: ownApp.name,
                    kind: .app,
                    icon: icon(for: ownApp, fallback: .runningApp(pid: process.pid))
                ),
                isAppItself: true
            )
        }

        // 6. A process inside an app bundle.
        if let enclosing = process.enclosingApp {
            return Resolution(
                identity: AppIdentity(
                    key: .bundle(enclosing.bundleID),
                    name: enclosing.name,
                    kind: .app,
                    icon: icon(for: enclosing, fallback: .executable(path: process.executablePath))
                ),
                isAppItself: false
            )
        }

        // 7. A bundled system process (rule 3 guarantees a bundle id here).
        return systemResolution(process)
    }

    private static func systemResolution(_ process: AudioProcessFacts) -> Resolution {
        let bundleID = process.bundleID ?? ""
        let executable = lastComponent(process.executablePath)
        let name = systemNames[bundleID]
            ?? executable.flatMap { systemNames[$0] }
            ?? executable
            ?? bundleID
        let symbol = switch name {
        case "System Sounds": "bell"
        case "Siri": "waveform"
        default: "speaker.wave.2"
        }
        return Resolution(
            identity: AppIdentity(key: .bundle(systemKeys[name] ?? bundleID), name: name, kind: .system, icon: .symbol(symbol)),
            isAppItself: false
        )
    }

    /// `.bundle(path:)` when the app's path is known, else `fallback`, else a generic symbol.
    private static func icon(for app: RunningAppInfo, fallback: IconSource?) -> IconSource {
        if let path = app.bundlePath, !path.isEmpty { return .bundle(path: path) }
        if let pid = app.pid { return .runningApp(pid: pid) }
        return fallback ?? .symbol("app")
    }

    /// The last non-empty "/" component of a path; nil for nil or empty.
    private static func lastComponent(_ path: String?) -> String? {
        guard let path else { return nil }
        guard let last = path.split(separator: "/").last.map(String.init), !last.isEmpty else { return nil }
        return last
    }
}
