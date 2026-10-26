import Foundation
import SopranoMixCore

/// The devices of a fixture scenario as an `AudioDeviceControlling`. Setters change the
/// snapshot like the hardware would (only properties the device has; scalars clamped) and
/// fire `onChange` once per change.
@MainActor
final class FixtureDevices: AudioDeviceControlling {
    var snapshot: DeviceSnapshot {
        didSet { onChange?() }
    }

    var onChange: (() -> Void)?

    init(scenario: FixtureScenario) {
        snapshot = scenario.devices
    }

    func start() {}

    func setDefaultDevice(_ role: DeviceRole, uid: String) {
        guard let device = snapshot.device(uid: uid) else { return }
        var next = snapshot
        switch role {
        case .output:
            guard device.hasOutput else { return }
            next.defaultOutputUID = uid
        case .input:
            guard device.hasInput else { return }
            next.defaultInputUID = uid
        case .soundEffects:
            guard device.hasOutput else { return }
            next.soundEffectsUID = uid
        }
        guard next != snapshot else { return }
        snapshot = next
    }

    func setVolume(_ scalar: Double, scope: DeviceScope, uid: String) {
        let value = min(max(scalar, 0), 1)
        update(uid) { device in
            switch scope {
            case .output:
                guard device.outputVolume != nil else { return }
                device.outputVolume = value
            case .input:
                guard device.inputVolume != nil else { return }
                device.inputVolume = value
            }
        }
    }

    func setMuted(_ muted: Bool, scope: DeviceScope, uid: String) {
        update(uid) { device in
            switch scope {
            case .output:
                guard device.outputMuted != nil else { return }
                device.outputMuted = muted
            case .input:
                guard device.inputMuted != nil else { return }
                device.inputMuted = muted
            }
        }
    }

    func setBalance(_ balance: Double, uid: String) {
        update(uid) { device in
            guard device.balance != nil else { return }
            device.balance = min(max(balance, 0), 1)
        }
    }

    func setSampleRate(_ rate: Double, uid: String) {
        update(uid) { device in
            guard device.sampleRates.isEmpty || device.sampleRates.contains(rate) else { return }
            device.sampleRate = rate
        }
    }

    /// Applies `change` to one device; assigns (and fires `onChange`) only when it changed.
    private func update(_ uid: String, _ change: (inout AudioDevice) -> Void) {
        guard let index = snapshot.devices.firstIndex(where: { $0.uid == uid }) else { return }
        var device = snapshot.devices[index]
        change(&device)
        guard device != snapshot.devices[index] else { return }
        snapshot.devices[index] = device
    }
}
