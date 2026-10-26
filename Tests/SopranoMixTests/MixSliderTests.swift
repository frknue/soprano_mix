import AppKit
import Testing
@testable import SopranoMix

@MainActor
struct MixSliderTests {
    private let app = MixSlider.Mapping(.app)
    private let output = MixSlider.Mapping(.output)
    private let balance = MixSlider.Mapping(.balance)

    // MARK: - Mapping

    @Test("an app slider puts 100 % at two thirds of the track and 400 % at its end")
    func appMappingBoundaries() {
        #expect(app.position(for: 0) == 0)
        #expect(abs(app.position(for: 100) - 2.0 / 3.0) < 1e-12)
        #expect(abs(app.position(for: 400) - 1) < 1e-12)
        #expect(abs(app.position(for: 50) - 1.0 / 3.0) < 1e-12)
        #expect(abs(app.position(for: 250) - 5.0 / 6.0) < 1e-12)
        #expect(app.value(at: 0) == 0)
        #expect(app.value(at: 2.0 / 3.0) == 100)
        #expect(app.value(at: 1) == 400)
    }

    @Test("positions and values outside the range clamp to its ends")
    func mappingClamps() {
        #expect(app.position(for: -20) == 0)
        #expect(app.position(for: 900) == 1)
        #expect(app.value(at: -0.5) == 0)
        #expect(app.value(at: 1.5) == 400)
        #expect(output.position(for: 140) == 1)
        #expect(output.value(at: 2) == 100)
        #expect(balance.value(at: -1) == 0)
    }

    @Test("an app slider snaps to 100 % within three points and nowhere else")
    func appDetent() {
        for percent in 97...103 {
            #expect(app.value(at: app.position(for: Double(percent))) == 100)
        }
        #expect(app.value(at: app.position(for: 96)) == 96)
        #expect(app.value(at: app.position(for: 104)) == 104)
    }

    @Test("every whole percent outside the detent survives a round trip through the track")
    func roundTrips() {
        for percent in 0...400 where abs(percent - 100) > 3 {
            #expect(app.value(at: app.position(for: Double(percent))) == Double(percent))
        }
        for percent in 0...100 {
            #expect(output.value(at: output.position(for: Double(percent))) == Double(percent))
        }
    }

    @Test("an output slider is linear with no detent")
    func outputIsLinear() {
        #expect(output.position(for: 50) == 0.5)
        #expect(output.value(at: 0.98) == 98)
        #expect(output.value(at: 0.25) == 25)
        #expect(output.resetValue == nil)
    }

    @Test("a balance slider snaps to the centre within 0.03")
    func balanceDetent() {
        #expect(balance.value(at: 0.52) == 0.5)
        #expect(balance.value(at: 0.48) == 0.5)
        #expect(balance.value(at: 0.6) == 0.6)
        #expect(balance.value(at: 0.4) == 0.4)
        #expect(balance.resetValue == 0.5)
    }

    @Test("keyboard steps are 1 % or 10 % with shift, clamped, and pass through the detent")
    func percentSteps() {
        #expect(app.stepped(60, up: true, large: false) == 61)
        #expect(app.stepped(60, up: false, large: true) == 50)
        #expect(app.stepped(99, up: true, large: false) == 100)
        #expect(app.stepped(100, up: true, large: false) == 101)
        #expect(app.stepped(395, up: true, large: true) == 400)
        #expect(app.stepped(4, up: false, large: true) == 0)
        #expect(output.stepped(100, up: true, large: false) == 100)
    }

    @Test("balance steps are 0.02 or 0.1 with shift, clamped to 0…1")
    func balanceSteps() {
        #expect(balance.stepped(0.5, up: true, large: false) == 0.52)
        #expect(balance.stepped(0.5, up: false, large: true) == 0.4)
        #expect(balance.stepped(0.95, up: true, large: true) == 1)
        #expect(balance.stepped(0.01, up: false, large: false) == 0)
    }

    // MARK: - Control

    @Test("arrow keys report non-final steps and the key up commits the value")
    func arrowKeysStepAndCommit() throws {
        let slider = MixSlider(kind: .app)
        slider.value = 60
        var reports: [(Double, Bool)] = []
        slider.onChange = { reports.append(($0, $1)) }

        slider.keyDown(with: try key(.keyDown, code: 124))
        slider.keyDown(with: try key(.keyDown, code: 124, shift: true))
        slider.keyUp(with: try key(.keyUp, code: 124))
        slider.keyDown(with: try key(.keyDown, code: 123))
        slider.keyUp(with: try key(.keyUp, code: 123))

        #expect(reports.map { $0.0 } == [61, 71, 71, 70, 70])
        #expect(reports.map { $0.1 } == [false, false, true, false, true])
    }

    @Test("a drag reports non-final values and mouse up reports the final one")
    func dragReportsFinalOnMouseUp() throws {
        let slider = MixSlider(kind: .output)
        slider.frame = NSRect(x: 0, y: 0, width: 112, height: MixSlider.hitHeight)
        slider.value = 0
        var reports: [(Double, Bool)] = []
        slider.onChange = { reports.append(($0, $1)) }
        let track = slider.trackRect

        slider.mouseDown(with: try mouse(.leftMouseDown, x: track.minX + track.width / 2))
        slider.mouseDragged(with: try mouse(.leftMouseDragged, x: track.minX + track.width * 0.75))
        #expect(slider.isDragging)
        slider.mouseUp(with: try mouse(.leftMouseUp, x: track.minX + track.width * 0.75))

        #expect(reports.map { $0.0 } == [50, 75, 75])
        #expect(reports.map { $0.1 } == [false, false, true])
        #expect(!slider.isDragging)
    }

    @Test("a model value never moves a slider while it is being dragged")
    func modelValueWaitsForDrag() throws {
        let slider = MixSlider(kind: .app)
        slider.frame = NSRect(x: 0, y: 0, width: 312, height: MixSlider.hitHeight)
        let track = slider.trackRect
        slider.mouseDown(with: try mouse(.leftMouseDown, x: track.minX + track.width / 3))
        let dragged = slider.value

        slider.setModelValue(300)
        #expect(slider.value == dragged)

        slider.mouseUp(with: try mouse(.leftMouseUp, x: track.minX + track.width / 3))
        slider.setModelValue(300)
        #expect(slider.value == 300)
    }

    @Test("a double-click resets an app slider to 100 % and a balance slider to the centre, as final values")
    func doubleClickResets() throws {
        let appSlider = MixSlider(kind: .app)
        appSlider.frame = NSRect(x: 0, y: 0, width: 200, height: MixSlider.hitHeight)
        appSlider.value = 250
        var appReports: [(Double, Bool)] = []
        appSlider.onChange = { appReports.append(($0, $1)) }
        appSlider.mouseDown(with: try mouse(.leftMouseDown, x: 20, clickCount: 2))
        #expect(appSlider.value == 100)
        #expect(appReports.count == 1 && appReports[0] == (100, true))

        let balanceSlider = MixSlider(kind: .balance)
        balanceSlider.frame = NSRect(x: 0, y: 0, width: 120, height: MixSlider.hitHeight)
        balanceSlider.value = 0.2
        balanceSlider.mouseDown(with: try mouse(.leftMouseDown, x: 10, clickCount: 2))
        #expect(balanceSlider.value == 0.5)
    }

    @Test("VoiceOver increments step by one percent and commit at once")
    func accessibilityIncrementCommits() {
        let slider = MixSlider(kind: .app)
        slider.value = 400
        var reports: [(Double, Bool)] = []
        slider.onChange = { reports.append(($0, $1)) }

        #expect(!slider.accessibilityPerformIncrement())
        #expect(slider.accessibilityPerformDecrement())
        #expect(reports.count == 1 && reports[0] == (399, true))
        #expect(slider.accessibilityRole() == .slider)
    }

    // MARK: - Events

    private func key(_ type: NSEvent.EventType, code: UInt16, shift: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: shift ? [.shift] : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: code
        ))
    }

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, clickCount: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: x, y: MixSlider.hitHeight / 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }
}
