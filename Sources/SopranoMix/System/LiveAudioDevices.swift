import AudioToolbox
import CoreAudio
import Foundation
import SopranoMixCore
import os

/// The audio devices (`kAudioHardwarePropertyDevices`) without hidden ones and without
/// Soprano Mix's own aggregates, and the system's default output, input and
/// sound-effects devices. Hardware volume, mute and balance count only when settable;
/// an output without settable volume (HDMI, DisplayPort) gets software volume from the
/// mixer.
///
/// Listeners on the device list and the three defaults (system object) and on every
/// visible device's volume, mute, balance, sample rate, streams and name; devices that
/// appear get theirs, devices that go lose theirs. Listeners hop to the main actor
/// (`addMainListener`); their notifications and setter writes are coalesced into one
/// refresh per main run-loop turn, and changes into one `onChange`.
@MainActor
final class LiveAudioDevices: AudioDeviceControlling {
    private(set) var snapshot = DeviceSnapshot()
    var onChange: (() -> Void)?

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let ownDevicePrefix = "com.soprano.mix."
    /// Rates a sample-rate range offers in the menu.
    static let commonSampleRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    private let logger = Logger(subsystem: "com.soprano.mix", category: "devices")
    private var isStarted = false
    private var systemListeners: [CoreAudioListener] = []
    private var deviceListeners: [AudioObjectID: [CoreAudioListener]] = [:]
    private var changePending = false
    private var refreshPending = false
    private var reinstallPending = false

    init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let deviceList: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDevices]
        let defaults: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ]
        for selector in deviceList {
            let listener = CoreAudioProperties.addMainListener(
                Self.systemObject, CoreAudioProperties.address(selector)
            ) { [weak self] in
                self?.scheduleRefresh(reinstallListeners: true)
            }
            if let listener { systemListeners.append(listener) }
        }
        for selector in defaults {
            let listener = CoreAudioProperties.addMainListener(
                Self.systemObject, CoreAudioProperties.address(selector)
            ) { [weak self] in
                self?.scheduleRefresh(reinstallListeners: false)
            }
            if let listener { systemListeners.append(listener) }
        }
        refresh(notify: false, reinstallListeners: true)
    }

    // MARK: - Setters

    func setDefaultDevice(_ role: DeviceRole, uid: String) {
        guard let device = resolve(uid) else { return }
        let selector: AudioObjectPropertySelector = switch role {
        case .output: kAudioHardwarePropertyDefaultOutputDevice
        case .input: kAudioHardwarePropertyDefaultInputDevice
        case .soundEffects: kAudioHardwarePropertyDefaultSystemOutputDevice
        }
        write(device, on: Self.systemObject, CoreAudioProperties.address(selector), "set default \(role.rawValue) to \(uid)")
    }

    func setVolume(_ scalar: Double, scope: DeviceScope, uid: String) {
        guard let device = resolve(uid) else { return }
        guard let address = Self.volumeAddress(device, scope: Self.coreAudioScope(scope)) else {
            logger.error("set \(scope.rawValue, privacy: .public) volume of \(uid, privacy: .public): no settable volume")
            return
        }
        let value = Float32(min(max(scalar, 0), 1))
        write(value, on: device, address, "set \(scope.rawValue) volume of \(uid)")
    }

    func setMuted(_ muted: Bool, scope: DeviceScope, uid: String) {
        guard let device = resolve(uid) else { return }
        let address = CoreAudioProperties.address(kAudioDevicePropertyMute, Self.coreAudioScope(scope))
        write(UInt32(muted ? 1 : 0), on: device, address, "set \(scope.rawValue) mute of \(uid)")
    }

    func setBalance(_ balance: Double, uid: String) {
        guard let device = resolve(uid) else { return }
        let address = CoreAudioProperties.address(
            kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioObjectPropertyScopeOutput
        )
        write(Float32(min(max(balance, 0), 1)), on: device, address, "set balance of \(uid)")
    }

    func setSampleRate(_ rate: Double, uid: String) {
        guard let device = resolve(uid), rate > 0 else { return }
        let address = CoreAudioProperties.address(kAudioDevicePropertyNominalSampleRate)
        write(Float64(rate), on: device, address, "set sample rate of \(uid) to \(rate)")
    }

    private func resolve(_ uid: String) -> AudioObjectID? {
        guard let device = CoreAudioProperties.device(forUID: uid) else {
            logger.error("no audio device with UID \(uid, privacy: .public)")
            return nil
        }
        return device
    }

    private func write<T>(_ value: T, on object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ operation: String) {
        do {
            try CoreAudioProperties.setValue(value, on: object, address)
        } catch {
            logger.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        // The property's own listener usually fires too; both land in one refresh.
        scheduleRefresh(reinstallListeners: false)
    }

    // MARK: - Reading

    private func refresh(notify: Bool, reinstallListeners: Bool) {
        let deviceIDs = (try? CoreAudioProperties.array(
            Self.systemObject, CoreAudioProperties.address(kAudioHardwarePropertyDevices), of: AudioObjectID.self
        )) ?? []
        let devices = deviceIDs.compactMap(Self.readDevice).sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.uid < rhs.uid
            }
        }
        if reinstallListeners {
            updateDeviceListeners(for: devices.map { AudioObjectID($0.objectID) })
        }
        let next = DeviceSnapshot(
            devices: devices,
            defaultOutputUID: Self.defaultUID(kAudioHardwarePropertyDefaultOutputDevice),
            defaultInputUID: Self.defaultUID(kAudioHardwarePropertyDefaultInputDevice),
            soundEffectsUID: Self.defaultUID(kAudioHardwarePropertyDefaultSystemOutputDevice)
        )
        guard next != snapshot else { return }
        snapshot = next
        if notify { scheduleChange() }
    }

    /// One refresh per main run-loop turn, however many notifications arrive (a volume
    /// change notifies volume, scalar and mute at once).
    private func scheduleRefresh(reinstallListeners: Bool) {
        reinstallPending = reinstallPending || reinstallListeners
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPending = false
                let reinstall = self.reinstallPending
                self.reinstallPending = false
                self.refresh(notify: true, reinstallListeners: reinstall)
            }
        }
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

    /// Per-device listeners: volume, mute (both scopes), balance, nominal sample rate,
    /// stream configuration (both scopes) and name. Devices already listened to keep
    /// theirs, so the device-list churn of Soprano Mix's own aggregates (filtered out of
    /// `deviceIDs`) re-installs nothing.
    private func updateDeviceListeners(for deviceIDs: [AudioObjectID]) {
        let visible = Set(deviceIDs)
        for (device, listeners) in deviceListeners where !visible.contains(device) {
            listeners.forEach { $0.remove() }
            deviceListeners[device] = nil
        }
        let output = kAudioObjectPropertyScopeOutput
        let input = kAudioObjectPropertyScopeInput
        let global = kAudioObjectPropertyScopeGlobal
        let addresses: [AudioObjectPropertyAddress] = [
            CoreAudioProperties.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, output),
            CoreAudioProperties.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, input),
            CoreAudioProperties.address(kAudioDevicePropertyVolumeScalar, output),
            CoreAudioProperties.address(kAudioDevicePropertyVolumeScalar, input),
            CoreAudioProperties.address(kAudioDevicePropertyMute, output),
            CoreAudioProperties.address(kAudioDevicePropertyMute, input),
            CoreAudioProperties.address(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, output),
            CoreAudioProperties.address(kAudioDevicePropertyNominalSampleRate, global),
            CoreAudioProperties.address(kAudioDevicePropertyAvailableNominalSampleRates, global),
            CoreAudioProperties.address(kAudioDevicePropertyStreamConfiguration, output),
            CoreAudioProperties.address(kAudioDevicePropertyStreamConfiguration, input),
            CoreAudioProperties.address(kAudioObjectPropertyName, global),
        ]
        for device in deviceIDs where deviceListeners[device] == nil {
            var listeners: [CoreAudioListener] = []
            for address in addresses where CoreAudioProperties.has(device, address) {
                let listener = CoreAudioProperties.addMainListener(device, address) { [weak self] in
                    self?.scheduleRefresh(reinstallListeners: false)
                }
                if let listener { listeners.append(listener) }
            }
            deviceListeners[device] = listeners
        }
    }

    private static func defaultUID(_ selector: AudioObjectPropertySelector) -> String? {
        guard let device = try? CoreAudioProperties.value(
            systemObject, CoreAudioProperties.address(selector), as: AudioObjectID.self
        ), device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        let uid = try? CoreAudioProperties.string(device, CoreAudioProperties.address(kAudioDevicePropertyDeviceUID))
        return uid.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func readDevice(_ device: AudioObjectID) -> AudioDevice? {
        let hidden = try? CoreAudioProperties.value(
            device, CoreAudioProperties.address(kAudioDevicePropertyIsHidden), as: UInt32.self
        )
        guard (hidden ?? 0) == 0,
              let uid = try? CoreAudioProperties.string(device, CoreAudioProperties.address(kAudioDevicePropertyDeviceUID)),
              !uid.isEmpty, !uid.hasPrefix(ownDevicePrefix) else { return nil }
        let name = (try? CoreAudioProperties.string(device, CoreAudioProperties.address(kAudioObjectPropertyName)))
            .flatMap { $0.isEmpty ? nil : $0 } ?? uid
        let transportCode = (try? CoreAudioProperties.value(
            device, CoreAudioProperties.address(kAudioDevicePropertyTransportType), as: UInt32.self
        )) ?? 0
        let output = kAudioObjectPropertyScopeOutput
        let input = kAudioObjectPropertyScopeInput

        let nominal = (try? CoreAudioProperties.value(
            device, CoreAudioProperties.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self
        )) ?? 0
        let ranges = (try? CoreAudioProperties.array(
            device, CoreAudioProperties.address(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self
        )) ?? []
        let rates = sampleRates(from: ranges.map { (minimum: $0.mMinimum, maximum: $0.mMaximum) }, nominal: nominal)

        return AudioDevice(
            objectID: device,
            uid: uid,
            name: name,
            transport: transport(for: transportCode),
            outputChannels: CoreAudioProperties.channelCount(device, scope: output),
            inputChannels: CoreAudioProperties.channelCount(device, scope: input),
            outputVolume: volume(device, scope: output),
            inputVolume: volume(device, scope: input),
            outputMuted: muted(device, scope: output),
            inputMuted: muted(device, scope: input),
            balance: settableFloat(device, CoreAudioProperties.address(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, output)),
            sampleRate: nominal > 0 ? nominal : (rates.first ?? 48_000),
            sampleRates: rates
        )
    }

    /// The first settable volume of a scope: the virtual main volume (what the menu bar
    /// changes), else the main element's scalar volume.
    private static func volumeAddress(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress? {
        let candidates = [
            CoreAudioProperties.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope),
            CoreAudioProperties.address(kAudioDevicePropertyVolumeScalar, scope),
        ]
        return candidates.first { address in
            CoreAudioProperties.has(device, address) && CoreAudioProperties.isSettable(device, address)
        }
    }

    private static func volume(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Double? {
        guard let address = volumeAddress(device, scope: scope),
              let value = try? CoreAudioProperties.value(device, address, as: Float32.self) else { return nil }
        return min(max(Double(value), 0), 1)
    }

    private static func muted(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool? {
        let address = CoreAudioProperties.address(kAudioDevicePropertyMute, scope)
        guard CoreAudioProperties.has(device, address), CoreAudioProperties.isSettable(device, address),
              let value = try? CoreAudioProperties.value(device, address, as: UInt32.self) else { return nil }
        return value != 0
    }

    private static func settableFloat(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Double? {
        guard CoreAudioProperties.has(device, address), CoreAudioProperties.isSettable(device, address),
              let value = try? CoreAudioProperties.value(device, address, as: Float32.self) else { return nil }
        return min(max(Double(value), 0), 1)
    }

    private static func coreAudioScope(_ scope: DeviceScope) -> AudioObjectPropertyScope {
        switch scope {
        case .output: kAudioObjectPropertyScopeOutput
        case .input: kAudioObjectPropertyScopeInput
        }
    }

    // MARK: - Pure mapping

    private static func fourCC(_ text: StaticString) -> UInt32 {
        text.withUTF8Buffer { buffer in buffer.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    }

    /// `kAudioDevicePropertyTransportType` → transport. Bluetooth LE counts as Bluetooth,
    /// every Continuity Capture type as continuity, AVB as unknown.
    static func transport(for code: UInt32) -> DeviceTransport {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeHDMI: .hdmi
        case kAudioDeviceTransportTypeDisplayPort: .displayPort
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeThunderbolt: .thunderbolt
        case kAudioDeviceTransportTypePCI: .pci
        case kAudioDeviceTransportTypeFireWire: .fireWire
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate, fourCC("fgrp"): .aggregate
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless,
             fourCC("ccap"): .continuity
        default: .unknown
        }
    }

    /// Available nominal rates, ascending and unique: a discrete value (min == max) as
    /// is; a real range contributes the common rates inside it (its ends when none
    /// fall inside). The nominal rate is always included.
    static func sampleRates(from ranges: [(minimum: Double, maximum: Double)], nominal: Double) -> [Double] {
        var rates: Set<Double> = []
        for range in ranges where range.minimum > 0 && range.maximum >= range.minimum {
            if range.minimum == range.maximum {
                rates.insert(range.minimum)
                continue
            }
            let inside = commonSampleRates.filter { $0 >= range.minimum && $0 <= range.maximum }
            if inside.isEmpty {
                rates.insert(range.minimum)
                rates.insert(range.maximum)
            } else {
                rates.formUnion(inside)
            }
        }
        if nominal > 0 { rates.insert(nominal) }
        return rates.sorted()
    }
}
