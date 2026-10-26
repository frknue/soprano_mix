import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

@MainActor
struct MixPanelWindowTests {
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1512, height: 949)

    init() {
        MixPanelWindow.offscreen = true
    }

    // MARK: - Rows

    @Test("a model with three apps produces three rows in model order")
    func rowsFollowModelOrder() {
        let window = MixPanelWindow()
        window.show(model: model(apps: [app("Discord"), app("Spotify"), app("TEKKEN 8")]), theme: .folioPaper, anchor: nil)

        #expect(window.isVisible)
        #expect(window.content.appRows.map(\.key.rawValue) == ["key.Discord", "key.Spotify", "key.TEKKEN 8"])
        #expect(window.content.sectionViews.map(\.role) == [.output, .input, .soundEffects])
    }

    @Test("an update with a reordered and a removed app reuses the surviving rows")
    func updateReusesRows() {
        let window = MixPanelWindow()
        window.show(model: model(apps: [app("Discord"), app("Spotify"), app("TEKKEN 8")]), theme: .folioPaper, anchor: nil)
        let before = Dictionary(uniqueKeysWithValues: window.content.appRows.map { ($0.key, $0) })

        window.update(model: model(apps: [app("TEKKEN 8"), app("Discord"), app("Music")]), theme: .folioInk)

        let after = window.content.appRows
        #expect(after.map(\.key.rawValue) == ["key.TEKKEN 8", "key.Discord", "key.Music"])
        #expect(after[0] === before[AppKey(rawValue: "key.TEKKEN 8")])
        #expect(after[1] === before[AppKey(rawValue: "key.Discord")])
        #expect(!before.values.contains { $0 === after[2] })
        #expect(before[AppKey(rawValue: "key.Spotify")]?.superview == nil)
    }

    @Test("an update never moves a slider that is being dragged, but updates the rest of the row")
    func dragSurvivesUpdate() throws {
        let window = MixPanelWindow()
        window.show(model: model(apps: [app("Spotify", volume: 60)]), theme: .folioPaper, anchor: nil)
        let row = try #require(window.content.appRows.first)
        let slider = row.slider
        let track = slider.trackRect
        let point = slider.convert(NSPoint(x: track.minX + track.width / 3, y: slider.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        slider.mouseDown(with: down)
        #expect(slider.isDragging)
        let dragged = slider.value

        window.update(model: model(apps: [app("Spotify", volume: 10, muted: true)]), theme: .folioPaper)

        #expect(window.content.appRows.first === row)
        #expect(slider.value == dragged)
        #expect(row.muteButton.isToggledOn)
    }

    @Test("meters show only for playing apps")
    func levelsOnlyForPlayingApps() {
        let window = MixPanelWindow()
        window.show(model: model(apps: [app("Music", playing: false), app("Spotify")]), theme: .folioPaper, anchor: nil)

        window.updateLevels([AppKey(rawValue: "key.Music"): 0.5, AppKey(rawValue: "key.Spotify"): 0.8])

        #expect(window.content.appRows.map(\.meter.position) == [nil, 0.8])
    }

    @Test("an empty model shows the empty state instead of rows")
    func emptyModelShowsEmptyState() {
        let window = MixPanelWindow()
        window.show(model: model(apps: [], emptyText: "Nothing is playing"), theme: .folioInk, anchor: nil)

        #expect(window.content.appRows.isEmpty)
        #expect(!window.content.appList.emptyLabel.isHidden)
        #expect(window.content.appList.emptyLabel.stringValue == "Nothing is playing")
    }

    @Test("the snapshot is the panel padded for its shadow")
    func snapshotIsPadded() throws {
        let window = MixPanelWindow()
        #expect(window.renderSnapshot(scale: 2) == nil)
        window.show(model: model(apps: [app("Spotify")]), theme: .folioPaper, anchor: nil)

        let image = try #require(window.renderSnapshot(scale: 2))
        #expect(image.width > Int(MixPanelGeometry.width * 2))
        #expect(CGFloat(image.height) > window.panel.frame.height * 2)
    }

    // MARK: - Geometry

    @Test("the panel fits short content and clamps at 80 % of the visible height")
    func heightClampsAtEightyPercent() {
        let short = MixPanelGeometry.heights(
            for: .init(fixedHeight: 380, listHeight: 3 * AppRowView.height),
            visibleFrame: visibleFrame
        )
        #expect(short == .init(panel: 380 + 156, list: 156))

        let tall = MixPanelGeometry.heights(
            for: .init(fixedHeight: 380, listHeight: 30 * AppRowView.height),
            visibleFrame: visibleFrame
        )
        #expect(tall.panel == floor(949 * 0.8))
        #expect(tall.list == floor(949 * 0.8) - 380)
    }

    @Test("a screen too short for the fixed parts keeps them whole with an empty list viewport")
    func fixedPartsNeverShrink() {
        let heights = MixPanelGeometry.heights(
            for: .init(fixedHeight: 500, listHeight: 520),
            visibleFrame: NSRect(x: 0, y: 0, width: 1024, height: 600)
        )
        #expect(heights == .init(panel: 500, list: 0))
    }

    @Test("the panel opens 4 pt below the status item, right-aligned to it")
    func frameUnderAnchor() {
        let anchor = NSRect(x: 1200, y: 949, width: 30, height: 24)
        let frame = MixPanelGeometry.frame(height: 500, anchor: anchor, visibleFrame: visibleFrame)
        #expect(frame == NSRect(x: 1230 - 380, y: 949 - 4 - 500, width: 380, height: 500))
    }

    @Test("a status item near the screen's left edge keeps the panel inside the visible frame")
    func frameClampsToVisibleFrame() {
        let anchor = NSRect(x: 100, y: 949, width: 30, height: 24)
        let frame = MixPanelGeometry.frame(height: 500, anchor: anchor, visibleFrame: visibleFrame)
        #expect(frame.minX == visibleFrame.minX)
        #expect(frame.maxY == 945)
    }

    @Test("without an anchor the panel sits at the top right of the visible frame")
    func frameWithoutAnchor() {
        let frame = MixPanelGeometry.frame(height: 400, anchor: nil, visibleFrame: visibleFrame)
        #expect(frame.maxX == visibleFrame.maxX - MixPanelGeometry.screenInset)
        #expect(frame.maxY == visibleFrame.maxY - MixPanelGeometry.anchorGap)
    }

    @Test("an update resizes the panel and keeps its top edge")
    func updateKeepsTopEdge() {
        let window = MixPanelWindow()
        window.show(model: model(apps: [app("Spotify")]), theme: .folioPaper, anchor: nil)
        let before = window.panel.frame

        window.update(model: model(apps: [app("Spotify"), app("Safari"), app("Discord")]), theme: .folioPaper)

        let after = window.panel.frame
        #expect(after.maxY == before.maxY)
        #expect(after.height == before.height + 2 * AppRowView.height)
    }

    // MARK: - Intents

    @Test("row controls report their app's intents")
    func rowIntents() throws {
        let window = MixPanelWindow()
        var intents: [PanelIntent] = []
        window.onIntent = { intents.append($0) }
        window.show(model: model(apps: [app("Spotify", volume: 60)]), theme: .folioPaper, anchor: nil)
        let row = try #require(window.content.appRows.first)
        let key = AppKey(rawValue: "key.Spotify")

        row.muteButton.performClick(nil)
        _ = row.slider.accessibilityPerformIncrement()
        row.outputButton.select(itemAt: 1)

        #expect(intents == [
            .toggleAppMute(key),
            .setAppVolume(key, 61, final: true),
            .setAppOutput(key, uid: "airpods"),
        ])
    }

    @Test("device section controls report their role's intents")
    func sectionIntents() throws {
        let window = MixPanelWindow()
        var intents: [PanelIntent] = []
        window.onIntent = { intents.append($0) }
        window.show(model: model(apps: []), theme: .folioPaper, anchor: nil)
        let output = try #require(window.content.sectionViews.first { $0.role == .output })

        output.deviceButton.select(itemAt: 1)
        output.muteButton.performClick(nil)
        _ = output.slider.accessibilityPerformDecrement()
        _ = output.balanceSlider.accessibilityPerformIncrement()
        output.sampleRatePopup.select(rate: 44_100)

        #expect(intents == [
            .setDefaultDevice(.output, uid: "airpods"),
            .toggleDeviceMute(.output),
            .setDeviceVolume(.output, 59, final: true),
            .setBalance(0.52, final: true),
            .setSampleRate(.output, 44_100),
        ])
    }

    @Test("choosing the device that is already selected reports nothing")
    func selectedDeviceIsNoOp() throws {
        let window = MixPanelWindow()
        var intents: [PanelIntent] = []
        window.onIntent = { intents.append($0) }
        window.show(model: model(apps: [app("Spotify")]), theme: .folioPaper, anchor: nil)
        let output = try #require(window.content.sectionViews.first)

        output.deviceButton.select(itemAt: 0)
        window.content.appRows[0].outputButton.select(itemAt: 0)
        output.sampleRatePopup.select(rate: 48_000)

        #expect(intents.isEmpty)
    }

    @Test("the banner button requests capture, the footer warning opens settings and the gear shows the app menu")
    func bannerAndFooterIntents() {
        let window = MixPanelWindow()
        var intents: [PanelIntent] = []
        window.onIntent = { intents.append($0) }
        var panelModel = model(apps: [app("Spotify")])
        panelModel.banner = .capture(text: "Allow System Audio Recording to change app volumes.", button: "Allow")
        panelModel.footerWarning = "settings.json · 2 warnings"
        window.show(model: panelModel, theme: .folioPaper, anchor: nil)

        window.content.banner.button.performClick(nil)
        window.content.footer.warningButton.performClick(nil)
        window.content.footer.gearButton.performClick(nil)

        #expect(intents.count == 3)
        #expect(intents.prefix(2) == [.requestCapture, .openSettings])
        if case .showAppMenu = intents.last {} else {
            Issue.record("the gear did not show the app menu: \(String(describing: intents.last))")
        }
    }

    @Test("the banner sits above the apps header and adds to the panel's height")
    func bannerAddsHeight() {
        let window = MixPanelWindow()
        window.show(model: model(apps: [app("Spotify")]), theme: .folioPaper, anchor: nil)
        let without = window.panel.frame.height

        var panelModel = model(apps: [app("Spotify")])
        panelModel.banner = .capture(text: "Allow System Audio Recording to change app volumes.", button: "Open Settings")
        window.update(model: panelModel, theme: .folioPaper)

        #expect(!window.content.banner.isHidden)
        #expect(window.content.banner.frame.maxY <= window.content.appsHeader.frame.minY)
        #expect(window.panel.frame.height > without)
    }

    @Test("Escape reports a dismissal and hides the panel")
    func escapeDismisses() {
        let window = MixPanelWindow()
        var intents: [PanelIntent] = []
        var visibility: [Bool] = []
        window.onIntent = { intents.append($0) }
        window.onVisibilityChange = { visibility.append($0) }
        window.show(model: model(apps: [app("Spotify")]), theme: .folioPaper, anchor: nil)

        window.panel.cancelOperation(nil)

        #expect(!window.isVisible)
        #expect(intents == [.dismiss])
        #expect(visibility == [true, false])

        window.dismiss()
        #expect(visibility == [true, false])
    }

    // MARK: - Fixtures

    private func app(_ name: String, volume: Double = 100, muted: Bool = false, playing: Bool = true) -> AppRowModel {
        AppRowModel(
            key: AppKey(rawValue: "key.\(name)"),
            name: name,
            icon: NSImage(size: NSSize(width: 24, height: 24)),
            volume: volume,
            volumeText: "\(Int(volume)) %",
            isMuted: muted,
            isPlaying: playing,
            outputName: nil,
            outputSymbol: "laptopcomputer",
            outputMenu: [
                DeviceMenuItem(uid: nil, title: "System output (MacBook Pro Speakers)", symbolName: "laptopcomputer", isSelected: true),
                DeviceMenuItem(uid: "airpods", title: "Furkan's AirPods Pro", symbolName: "headphones", isSelected: false),
            ],
            status: .normal
        )
    }

    private func model(apps: [AppRowModel], emptyText: String? = nil) -> MixPanelModel {
        let outputs = [
            DeviceMenuItem(uid: "builtin", title: "MacBook Pro Speakers", symbolName: "laptopcomputer", isSelected: true),
            DeviceMenuItem(uid: "airpods", title: "Furkan's AirPods Pro", symbolName: "headphones", isSelected: false),
        ]
        return MixPanelModel(
            sections: [
                DeviceSectionModel(
                    role: .output, title: "Output", deviceName: "MacBook Pro Speakers", deviceSymbol: "laptopcomputer",
                    menu: outputs, volume: 60, volumeText: "60 %", isSoftwareVolume: false, isMuted: false,
                    balance: 0.5, sampleRate: SampleRateMenu(title: "48 kHz", rates: [44_100, 48_000], selected: 48_000)
                ),
                DeviceSectionModel(
                    role: .input, title: "Input", deviceName: "MacBook Pro Microphone", deviceSymbol: "laptopcomputer",
                    menu: [], volume: 50, volumeText: "50 %", isSoftwareVolume: false, isMuted: false,
                    balance: nil, sampleRate: nil
                ),
                DeviceSectionModel(
                    role: .soundEffects, title: "Sound effects", deviceName: "MacBook Pro Speakers",
                    deviceSymbol: "laptopcomputer", menu: outputs, volume: 75, volumeText: "75 %",
                    isSoftwareVolume: false, isMuted: nil, balance: nil, sampleRate: nil
                ),
            ],
            apps: apps,
            emptyText: apps.isEmpty ? (emptyText ?? "Nothing is playing") : nil,
            banner: nil,
            footerWarning: nil
        )
    }
}
