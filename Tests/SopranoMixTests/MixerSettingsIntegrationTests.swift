import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

// MixerController against the real SettingsCenter, wired the way AppDelegate wires it:
// a write reloads synchronously and re-enters the controller, which the in-memory
// fixture store does not do.
@MainActor
struct MixerSettingsIntegrationTests {
    private let tekken = AppKey.wine("TEKKEN 8")

    @Test("drags, debounced writes, no-op writes, hand edits, a broken file and quit all reach settings.json and the routes")
    func realSettingsCenter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mix-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try Data(#"{ "outputs": { "Odyssey G91F": { "volume": 50 } }, "apps": { "wine:TEKKEN 8": { "volume": 35 } } }"#.utf8).write(to: url)
        let center = SettingsCenter(fileURL: url)
        center.start(watching: false)

        let scheduler = ManualMixerScheduler()
        let router = RecordingRouter()
        let environment = MixerEnvironment(
            settings: { center.settings },
            settingsIssueCount: { center.issues.count },
            theme: { AppTheme.folioPaper },
            writeSetting: { value, path in center.write(value, at: path) },
            schedule: { delay, work in scheduler.schedule(delay, work) },
            scheduleRepeating: { interval, work in scheduler.scheduleRepeating(interval, work) },
            now: { 0 },
            ownPID: FixtureScenario.ownPID,
            captureStatus: { .granted },
            requestCapture: { done in done(.granted) },
            alertVolume: { 50 },
            setAlertVolume: { _ in },
            openSettingsFile: {},
            showAppMenu: { _ in }
        )
        let controller = MixerController(
            processes: FixtureProcessSource(scenario: .game), devices: FixtureDevices(scenario: .game), router: router,
            icons: FixtureIcons(), panel: RecordingPanelPresenter(), hud: RecordingHUD(), environment: environment
        )
        center.addObserver(controller) { [weak controller] in controller?.settingsDidChange() }
        controller.start()

        func gain() -> Float? { router.applied.last?.route(for: tekken)?.gain }
        func soft() -> Float { VolumeLaw.gain(percent: 50) }   // game scenario: monitor at 50 % software volume
        func fileVolume() throws -> Double? {
            let text = try String(contentsOf: url, encoding: .utf8)
            return SettingsResolver.resolve(text: text, knownThemeIDs: []).settings?.apps[tekken]?.volume
        }
        func handEdit(_ json: String) throws {
            try Data(json.utf8).write(to: url)
            center.reload()
        }

        #expect(gain() == VolumeLaw.gain(percent: 35) * soft())

        // 1. Drag, final on mouse up.
        controller.handle(.setAppVolume(tekken, 60, final: false))
        #expect(gain() == VolumeLaw.gain(percent: 60) * soft())
        controller.handle(.setAppVolume(tekken, 100, final: false))
        #expect(gain() == soft())   // held through 100 %
        controller.handle(.setAppVolume(tekken, 20, final: true))
        #expect(try fileVolume() == 20)
        #expect(gain() == VolumeLaw.gain(percent: 20) * soft())

        // 2. Hand edit applies.
        try handEdit(#"{ "outputs": { "Odyssey G91F": { "volume": 50 } }, "apps": { "wine:TEKKEN 8": { "volume": 50 } } }"#)
        #expect(gain() == VolumeLaw.gain(percent: 50) * soft())

        // 3. A write equal to the file, then a hand edit: the edit must win.
        controller.handle(.setAppVolume(tekken, 50, final: true))
        try handEdit(#"{ "outputs": { "Odyssey G91F": { "volume": 50 } }, "apps": { "wine:TEKKEN 8": { "volume": 10 } } }"#)
        #expect(gain() == VolumeLaw.gain(percent: 10) * soft())

        // 4. Debounced write.
        controller.handle(.setAppVolume(tekken, 70, final: false))
        #expect(try fileVolume() == 10)
        scheduler.fireAll()
        #expect(try fileVolume() == 70)

        // 5. Broken file: the change stays in force and is written once the file parses.
        try handEdit("{ not json")
        controller.handle(.setAppVolume(tekken, 30, final: true))
        #expect(gain() == VolumeLaw.gain(percent: 30) * soft())
        try handEdit(#"{ "outputs": { "Odyssey G91F": { "volume": 50 } }, "apps": { "wine:TEKKEN 8": { "volume": 90 } } }"#)
        #expect(try fileVolume() == 30)
        #expect(gain() == VolumeLaw.gain(percent: 30) * soft())

        // 6. Quit flushes a pending change.
        controller.handle(.setAppVolume(tekken, 45, final: false))
        controller.flushPendingSettings()
        #expect(try fileVolume() == 45)

        // 7. Back to 100 % final: the route goes.
        controller.handle(.setAppVolume(tekken, 100, final: true))
        #expect(gain() == nil || router.applied.last?.route(for: tekken) == nil)
        #expect(router.applied.last?.master != nil)
    }
}
