import AppKit
import SopranoMixCore

/// Turns the mixer's state into the `MixPanelModel` the panel draws (ARCHITECTURE → Mixer,
/// Model text): the output, input and sound-effects sections, one row per listed app, the
/// capture banner, the empty text and the settings footer.
enum MixerModelBuilder {
    static let emptyText = "Nothing is playing"
    static let captureBannerText = "Allow System Audio Recording to change app volumes."
    static let noDeviceName = "No device"

    static func model(listedApps: [AudioApp], settings: SopranoMixSettings, devices: DeviceSnapshot,
                      statuses: [AppKey: RouteStatus], capture: CaptureStatus,
                      settingsIssueCount: Int, alertVolume: Double?,
                      icons: (AudioApp) -> NSImage) -> MixPanelModel {
        let rows = listedApps.map { app in
            appRow(app, settings: settings, devices: devices, status: statuses[app.key], icon: icons(app))
        }
        return MixPanelModel(
            sections: [
                outputSection(settings: settings, devices: devices),
                inputSection(devices: devices),
                soundEffectsSection(devices: devices, alertVolume: alertVolume),
            ],
            apps: rows,
            emptyText: rows.isEmpty ? emptyText : nil,
            banner: banner(for: capture),
            footerWarning: footerWarning(issueCount: settingsIssueCount)
        )
    }

    /// "48 kHz", "44.1 kHz", "22.05 kHz".
    static func sampleRateTitle(_ hz: Double) -> String {
        var text = String(format: "%.3f", hz / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + " kHz"
    }

    /// "System output (MacBook Pro Speakers)": the first entry of every app's output menu.
    static func systemOutputTitle(_ defaultOutput: AudioDevice?) -> String {
        defaultOutput.map { "System output (\($0.name))" } ?? "System output"
    }

    /// A Core Audio volume scalar (0...1) as a percent, to 0.1 %.
    static func percent(fromScalar scalar: Double) -> Double {
        (scalar * 1000).rounded() / 10
    }

    // MARK: - Device sections

    private static func outputSection(settings: SopranoMixSettings, devices: DeviceSnapshot) -> DeviceSectionModel {
        let device = devices.defaultOutput
        let isSoftware = device.map { $0.outputVolume == nil } ?? false
        let volume: Double? = device.map { device in
            device.outputVolume.map(percent(fromScalar:)) ?? settings.outputVolume(for: device).volume
        }
        let isMuted: Bool? = device.flatMap { device -> Bool? in
            device.outputVolume == nil ? settings.outputVolume(for: device).muted : device.outputMuted
        }
        return DeviceSectionModel(
            role: .output,
            title: "Output",
            deviceName: device?.name ?? noDeviceName,
            deviceSymbol: symbol(device),
            menu: deviceMenu(devices.outputs, selectedUID: devices.defaultOutputUID),
            volume: volume,
            volumeText: volumeText(volume),
            isSoftwareVolume: isSoftware,
            isMuted: isMuted,
            balance: device?.balance,
            sampleRate: device.map(sampleRateMenu)
        )
    }

    private static func inputSection(devices: DeviceSnapshot) -> DeviceSectionModel {
        let device = devices.defaultInput
        let volume = device?.inputVolume.map(percent(fromScalar:))
        return DeviceSectionModel(
            role: .input,
            title: "Input",
            deviceName: device?.name ?? noDeviceName,
            deviceSymbol: symbol(device),
            menu: deviceMenu(devices.inputs, selectedUID: devices.defaultInputUID),
            volume: volume,
            volumeText: volumeText(volume),
            isSoftwareVolume: false,
            isMuted: device?.inputMuted,
            balance: nil,
            sampleRate: device.map(sampleRateMenu)
        )
    }

    private static func soundEffectsSection(devices: DeviceSnapshot, alertVolume: Double?) -> DeviceSectionModel {
        let device = devices.soundEffects
        return DeviceSectionModel(
            role: .soundEffects,
            title: "Sound effects",
            deviceName: device?.name ?? noDeviceName,
            deviceSymbol: symbol(device),
            menu: deviceMenu(devices.outputs, selectedUID: devices.soundEffectsUID),
            volume: alertVolume,
            volumeText: volumeText(alertVolume),
            isSoftwareVolume: false,
            isMuted: nil,
            balance: nil,
            sampleRate: nil
        )
    }

    /// Every candidate device, the selected one first and marked.
    private static func deviceMenu(_ candidates: [AudioDevice], selectedUID: String?) -> [DeviceMenuItem] {
        let selected = candidates.filter { $0.uid == selectedUID }
        let others = candidates.filter { $0.uid != selectedUID }
        return (selected + others).map { device in
            DeviceMenuItem(
                uid: device.uid,
                title: device.name,
                symbolName: device.transport.symbolName,
                isSelected: device.uid == selectedUID
            )
        }
    }

    private static func sampleRateMenu(_ device: AudioDevice) -> SampleRateMenu {
        let rates = device.sampleRates.isEmpty ? [device.sampleRate] : device.sampleRates
        return SampleRateMenu(title: sampleRateTitle(device.sampleRate), rates: rates, selected: device.sampleRate)
    }

    private static func symbol(_ device: AudioDevice?) -> String {
        (device?.transport ?? .unknown).symbolName
    }

    private static func volumeText(_ percent: Double?) -> String {
        percent.map { VolumeLaw.text(percent: $0) } ?? ""
    }

    // MARK: - App rows

    private static func appRow(_ app: AudioApp, settings: SopranoMixSettings, devices: DeviceSnapshot,
                               status: RouteStatus?, icon: NSImage) -> AppRowModel {
        let audio = settings.audio(for: app.key)
        let defaultOutput = devices.defaultOutput
        // The chosen device while it exists; a missing one falls back to the system output.
        let chosen = devices.output(matching: audio.output)
        let target = chosen ?? defaultOutput
        let outputName: String? = chosen.flatMap { device -> String? in
            device.uid == devices.defaultOutputUID ? nil : device.name
        }
        let systemItem = DeviceMenuItem(
            uid: nil,
            title: systemOutputTitle(defaultOutput),
            symbolName: symbol(defaultOutput),
            isSelected: chosen == nil
        )
        let deviceItems = devices.outputs.map { device in
            DeviceMenuItem(
                uid: device.uid,
                title: device.name,
                symbolName: device.transport.symbolName,
                isSelected: device.uid == chosen?.uid
            )
        }
        return AppRowModel(
            key: app.key,
            name: app.name,
            icon: icon,
            volume: audio.volume,
            volumeText: VolumeLaw.text(percent: audio.volume),
            isMuted: audio.muted,
            isPlaying: app.isPlaying,
            outputName: outputName,
            outputSymbol: symbol(target),
            outputMenu: [systemItem] + deviceItems,
            status: rowStatus(status)
        )
    }

    private static func rowStatus(_ status: RouteStatus?) -> AppRowStatus {
        switch status {
        case nil, .running: .normal
        case .starting: .starting
        case let .failed(reason): .failed(reason)
        }
    }

    // MARK: - Banner and footer

    private static func banner(for capture: CaptureStatus) -> PanelBanner? {
        switch capture {
        case .notDetermined: .capture(text: captureBannerText, button: "Allow")
        case .denied: .capture(text: captureBannerText, button: "Open Settings")
        case .granted, .unknown: nil
        }
    }

    private static func footerWarning(issueCount: Int) -> String? {
        switch issueCount {
        case ..<1: nil
        case 1: "settings.json · 1 warning"
        default: "settings.json · \(issueCount) warnings"
        }
    }
}
