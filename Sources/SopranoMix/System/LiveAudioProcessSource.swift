import AppKit
import CoreAudio
import SopranoMixCore

/// Every Core Audio client process (`kAudioHardwarePropertyProcessObjectList`) with what
/// `AudioAppResolver` needs to group it: pid, bundle id, executable, argv (and
/// `WINEPREFIX` for Wine processes), the responsible app, the app itself and the app
/// bundle around the executable, and whether it is playing or recording. Reading all of
/// it needs no permission.
///
/// Static facts are read once per (object id, pid); the running flags are re-read when
/// their listeners fire. Listeners hop to the main actor (`addMainListener`); changes are
/// coalesced into one `onChange` per main run-loop turn.
@MainActor
final class LiveAudioProcessSource: AudioProcessSource {
    private(set) var processes: [AudioProcessFacts] = []
    var onChange: (() -> Void)?

    private struct ProcessKey: Hashable {
        var objectID: AudioObjectID
        var pid: pid_t
    }

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private var isStarted = false
    private var listListener: CoreAudioListener?
    private var processListeners: [AudioObjectID: [CoreAudioListener]] = [:]
    /// Facts without the running flags, per (object id, pid).
    private var staticFacts: [ProcessKey: AudioProcessFacts] = [:]
    private var changePending = false

    init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        listListener = CoreAudioProperties.addMainListener(
            Self.systemObject,
            CoreAudioProperties.address(kAudioHardwarePropertyProcessObjectList)
        ) { [weak self] in
            self?.reload(notify: true)
        }
        reload(notify: false)
    }

    // MARK: - Reading

    private func reload(notify: Bool) {
        let objectIDs = (try? CoreAudioProperties.array(
            Self.systemObject,
            CoreAudioProperties.address(kAudioHardwarePropertyProcessObjectList),
            of: AudioObjectID.self
        )) ?? []
        let sorted = Array(Set(objectIDs)).sorted()
        updateProcessListeners(for: sorted)

        var result: [AudioProcessFacts] = []
        result.reserveCapacity(sorted.count)
        var liveKeys: Set<ProcessKey> = []
        for objectID in sorted {
            guard let pid = try? CoreAudioProperties.value(
                objectID, CoreAudioProperties.address(kAudioProcessPropertyPID), as: pid_t.self
            ) else { continue }
            let key = ProcessKey(objectID: objectID, pid: pid)
            liveKeys.insert(key)
            var facts: AudioProcessFacts
            if let cached = staticFacts[key] {
                facts = cached
            } else {
                facts = Self.readStaticFacts(objectID: objectID, pid: pid)
                staticFacts[key] = facts
            }
            facts.isRunningOutput = Self.flag(objectID, kAudioProcessPropertyIsRunningOutput)
            facts.isRunningInput = Self.flag(objectID, kAudioProcessPropertyIsRunningInput)
            result.append(facts)
        }
        staticFacts = staticFacts.filter { liveKeys.contains($0.key) }
        publish(result, notify: notify)
    }

    /// Re-reads one process object's running flags.
    private func runningChanged(_ objectID: AudioObjectID) {
        guard let index = processes.firstIndex(where: { $0.objectID == objectID }) else { return }
        var result = processes
        result[index].isRunningOutput = Self.flag(objectID, kAudioProcessPropertyIsRunningOutput)
        result[index].isRunningInput = Self.flag(objectID, kAudioProcessPropertyIsRunningInput)
        publish(result, notify: true)
    }

    private func publish(_ result: [AudioProcessFacts], notify: Bool) {
        guard result != processes else { return }
        processes = result
        if notify { scheduleChange() }
    }

    private func scheduleChange() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changePending = false
                self.onChange?()
            }
        }
    }

    /// Every selector that may signal a change of a process object's running flags. Core
    /// Audio (measured on macOS 27) never notifies `IsRunningOutput`/`IsRunningInput`
    /// themselves; it notifies `IsRunning` and `Devices` when a process starts or stops
    /// IO. Any of them re-reads both flags, so a process that connects first and plays
    /// a moment later is seen playing without a restart.
    private static let runningSelectors: [AudioObjectPropertySelector] = [
        kAudioProcessPropertyIsRunningOutput,
        kAudioProcessPropertyIsRunningInput,
        kAudioProcessPropertyIsRunning,
        kAudioProcessPropertyDevices,
    ]

    /// One listener per `runningSelectors` entry per live process object.
    private func updateProcessListeners(for objectIDs: [AudioObjectID]) {
        let live = Set(objectIDs)
        for (objectID, listeners) in processListeners where !live.contains(objectID) {
            listeners.forEach { $0.remove() }
            processListeners[objectID] = nil
        }
        for objectID in objectIDs where processListeners[objectID] == nil {
            var listeners: [CoreAudioListener] = []
            for selector in Self.runningSelectors {
                let listener = CoreAudioProperties.addMainListener(
                    objectID, CoreAudioProperties.address(selector)
                ) { [weak self] in
                    self?.runningChanged(objectID)
                }
                if let listener { listeners.append(listener) }
            }
            processListeners[objectID] = listeners
        }
    }

    private static func flag(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        let value = try? CoreAudioProperties.value(objectID, CoreAudioProperties.address(selector), as: UInt32.self)
        return (value ?? 0) != 0
    }

    // MARK: - Static facts

    private static func readStaticFacts(objectID: AudioObjectID, pid: pid_t) -> AudioProcessFacts {
        let bundleID = (try? CoreAudioProperties.string(
            objectID, CoreAudioProperties.address(kAudioProcessPropertyBundleID)
        )).flatMap { $0.isEmpty ? nil : $0 }
        let executablePath = ProcessInspector.executablePath(pid: pid)
        let inspected = ProcessInspector.arguments(pid: pid)
        let arguments = inspected?.arguments ?? []

        let isWine = arguments.first.map(WinePath.isWindowsPath) == true
            || executablePath.map(WinePath.isWindowsPath) == true
        var wineprefix: String?
        if isWine, let value = inspected?.environment["WINEPREFIX"], !value.isEmpty {
            wineprefix = value
        }

        let enclosingApp = executablePath
            .flatMap { WinePath.isWindowsPath($0) ? nil : ProcessInspector.outermostAppBundle(containing: $0) }
            .flatMap(appBundleInfo(atPath:))

        let ownApp = NSRunningApplication(processIdentifier: pid).flatMap { runningAppInfo($0, pid: pid) }

        var responsible: RunningAppInfo?
        if let responsiblePID = PrivateAPIs.responsiblePID(for: pid), responsiblePID != pid,
           let app = NSRunningApplication(processIdentifier: responsiblePID) {
            responsible = runningAppInfo(app, pid: responsiblePID)
        }

        return AudioProcessFacts(
            objectID: objectID,
            pid: pid,
            bundleID: bundleID,
            executablePath: executablePath,
            arguments: arguments,
            wineprefix: wineprefix,
            responsible: responsible,
            enclosingApp: enclosingApp,
            ownApp: ownApp
        )
    }

    /// A running app with a bundle id; nil without one.
    private static func runningAppInfo(_ app: NSRunningApplication, pid: pid_t) -> RunningAppInfo? {
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
        return RunningAppInfo(
            pid: pid,
            bundleID: bundleID,
            name: app.localizedName ?? bundleID,
            bundlePath: app.bundleURL?.path
        )
    }

    /// An app bundle on disk: its `CFBundleIdentifier` (required) and display name.
    private static func appBundleInfo(atPath path: String) -> RunningAppInfo? {
        guard let info = Bundle(path: path)?.infoDictionary,
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        let fileName = (path as NSString).lastPathComponent
        let fallbackName = fileName.lowercased().hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName
        let candidates = [info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String]
        let name = candidates.compactMap { $0 }.first { !$0.isEmpty } ?? fallbackName
        return RunningAppInfo(pid: nil, bundleID: bundleID, name: name, bundlePath: path)
    }
}
