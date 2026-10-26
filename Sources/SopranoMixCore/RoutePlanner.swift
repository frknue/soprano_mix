import Foundation

/// Settings + connected apps + devices → the routes (taps) that must exist. Apps with
/// default settings get none, so their audio stays untouched.
public enum RoutePlanner {
    public static func plan(
        apps: [AudioApp],
        settings: SopranoMixSettings,
        devices: DeviceSnapshot,
        meteredKeys: Set<AppKey>,
        canCapture: Bool
    ) -> RoutePlan {
        guard canCapture, let defaultUID = devices.defaultOutputUID else { return .empty }
        let defaultDevice = devices.defaultOutput
        let bufferFrames = settings.audio.bufferFrames

        var routes: [RouteSpec] = []
        var replaced: Set<AppKey> = []
        for app in apps where !app.processObjectIDs.isEmpty {
            let audio = settings.audio(for: app.key)
            let target = devices.output(matching: audio.output) ?? defaultDevice
            let targetUID = target?.uid ?? defaultUID
            guard audio.volume != 100 || audio.muted || targetUID != defaultUID else { continue }
            let outputGain = target.map { softwareGain(for: $0, settings: settings) } ?? 1
            routes.append(RouteSpec(
                key: app.key,
                processObjectIDs: app.processObjectIDs,
                outputDeviceUID: targetUID,
                gain: audio.muted ? 0 : VolumeLaw.gain(percent: audio.volume) * outputGain,
                mode: .replace,
                limiter: settings.audio.limiter && audio.volume > 100,
                bufferFrames: bufferFrames
            ))
            replaced.insert(app.key)
        }

        for app in apps where meteredKeys.contains(app.key) && app.isPlaying && !app.processObjectIDs.isEmpty && !replaced.contains(app.key) {
            routes.append(RouteSpec(
                key: app.key,
                processObjectIDs: app.processObjectIDs,
                outputDeviceUID: defaultUID,
                gain: 1,
                mode: .meter,
                limiter: false,
                bufferFrames: bufferFrames
            ))
        }
        routes.sort { $0.key < $1.key }

        var master: MasterRouteSpec?
        if let defaultDevice, defaultDevice.outputVolume == nil {
            let gain = softwareGain(for: defaultDevice, settings: settings)
            if gain != 1 {
                let excluded = Set(routes.filter { $0.mode == .replace }.flatMap(\.processObjectIDs))
                master = MasterRouteSpec(
                    outputDeviceUID: defaultDevice.uid,
                    gain: gain,
                    excludedProcessObjectIDs: excluded.sorted(),
                    bufferFrames: bufferFrames
                )
            }
        }
        return RoutePlan(routes: routes, master: master)
    }

    /// The software gain of an output: 1 with hardware volume (`outputVolume != nil`),
    /// else `outputs[uid] ?? outputs[name]` through `VolumeLaw.gain`, 0 when muted.
    public static func softwareGain(for device: AudioDevice, settings: SopranoMixSettings) -> Float {
        guard device.outputVolume == nil else { return 1 }
        let output = settings.outputVolume(for: device)
        return output.muted ? 0 : VolumeLaw.gain(percent: output.volume)
    }
}
