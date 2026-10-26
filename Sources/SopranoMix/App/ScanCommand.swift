import AppKit
import SopranoMixCore

/// `SopranoMix scan [--all]`: the connected apps as `AudioAppResolver` groups them, with
/// every process behind each, plus the audio devices. Needs no running app, no tap and no
/// permission: the tool for "why is my app not listed".
@MainActor
enum ScanCommand {
    static let usage = """
    Usage: SopranoMix scan [--all]

    Prints the apps connected to Core Audio as Soprano Mix groups them (key, name, kind,
    playing, pids and every process: bundle id, executable path, argv[0], responsible
    app) and the audio devices, as JSON.

      --all    include apps that are connected but not playing
      --help   show this help
    """

    /// `arguments` excludes the executable: ["scan", "--all"].
    static func run(arguments: [String]) -> Int32 {
        var options = arguments
        if options.first == "scan" { options.removeFirst() }
        var includeAll = false
        for option in options {
            switch option {
            case "--all":
                includeAll = true
            case "--help", "-h", "help":
                print(usage)
                return 0
            default:
                FileHandle.standardError.write(Data("Unknown option '\(option)'.\n\n\(usage)\n".utf8))
                return 1
            }
        }

        let processSource = LiveAudioProcessSource()
        processSource.start()
        let devices = LiveAudioDevices()
        devices.start()

        let report = makeReport(
            processes: processSource.processes,
            snapshot: devices.snapshot,
            ownPID: getpid(),
            includeAll: includeAll
        )
        do {
            let data = try JSONSerialization.data(
                withJSONObject: report,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            print(String(decoding: data, as: UTF8.self))
            return 0
        } catch {
            FileHandle.standardError.write(Data("Could not encode the scan: \(error)\n".utf8))
            return 1
        }
    }

    /// The JSON object `scan` prints: `apps` (playing ones unless `includeAll`) and
    /// `devices`. Missing values are JSON null.
    static func makeReport(
        processes: [AudioProcessFacts],
        snapshot: DeviceSnapshot,
        ownPID: Int32,
        includeAll: Bool
    ) -> [String: Any] {
        let factsByObject = Dictionary(processes.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
        let apps = AudioAppResolver.apps(from: processes, ownPID: ownPID)
            .filter { includeAll || $0.isPlaying }

        let appObjects: [[String: Any]] = apps.map { app in
            let processObjects: [[String: Any]] = app.processObjectIDs.compactMap { objectID in
                guard let facts = factsByObject[objectID] else { return nil }
                return [
                    "objectID": Int(facts.objectID),
                    "pid": Int(facts.pid),
                    "bundleID": json(facts.bundleID),
                    "executablePath": json(facts.executablePath),
                    "argv0": json(facts.arguments.first),
                    "responsible": json(facts.responsible?.bundleID),
                    "runningOutput": facts.isRunningOutput,
                ]
            }
            return [
                "key": app.key.rawValue,
                "name": app.name,
                "kind": app.kind.rawValue,
                "playing": app.isPlaying,
                "pids": app.pids.map { Int($0) },
                "processes": processObjects,
            ]
        }

        let deviceObjects: [[String: Any]] = snapshot.devices.map { device in
            [
                "uid": device.uid,
                "name": device.name,
                "transport": device.transport.rawValue,
                "channels": ["output": device.outputChannels, "input": device.inputChannels],
                "hardwareVolume": json(device.outputVolume.map { ($0 * 1000).rounded() / 1000 }),
                "defaultOutput": device.uid == snapshot.defaultOutputUID,
                "defaultInput": device.uid == snapshot.defaultInputUID,
                "soundEffects": device.uid == snapshot.soundEffectsUID,
            ]
        }

        return ["apps": appObjects, "devices": deviceObjects]
    }

    private static func json(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static func json(_ value: Double?) -> Any {
        if let value { return value }
        return NSNull()
    }
}
