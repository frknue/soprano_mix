import AppKit
import Carbon
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

@MainActor
struct CarbonPanelHotkeyTests {
    @Test("each modifier maps to its Carbon flag and combinations add up")
    func modifiers() {
        #expect(CarbonPanelHotkey.carbonModifiers([]) == 0)
        #expect(CarbonPanelHotkey.carbonModifiers(.command) == UInt32(cmdKey))
        #expect(CarbonPanelHotkey.carbonModifiers(.option) == UInt32(optionKey))
        #expect(CarbonPanelHotkey.carbonModifiers(.control) == UInt32(controlKey))
        #expect(CarbonPanelHotkey.carbonModifiers(.shift) == UInt32(shiftKey))
        #expect(CarbonPanelHotkey.carbonModifiers([.control, .option]) == UInt32(controlKey | optionKey))
        #expect(
            CarbonPanelHotkey.carbonModifiers([.command, .option, .control, .shift])
                == UInt32(cmdKey | optionKey | controlKey | shiftKey)
        )
    }

    @Test("fn has no Carbon hotkey flag and is dropped")
    func functionDropped() {
        #expect(CarbonPanelHotkey.carbonModifiers([.function]) == 0)
        #expect(CarbonPanelHotkey.carbonModifiers([.function, .control]) == UInt32(controlKey))
    }

    @Test("named keys register their positional key code, Return its main key")
    func namedKeys() {
        #expect(CarbonPanelHotkey.keyCode(forNamed: .space) == UInt16(kVK_Space))
        #expect(CarbonPanelHotkey.keyCode(forNamed: .return) == UInt16(kVK_Return))
        #expect(CarbonPanelHotkey.keyCode(forNamed: .escape) == UInt16(kVK_Escape))
        #expect(CarbonPanelHotkey.keyCode(forNamed: .keyAboveTab) == UInt16(kVK_ANSI_Grave))
        #expect(CarbonPanelHotkey.keyCode(forNamed: .f12) == UInt16(kVK_F12))
        #expect(CarbonPanelHotkey.keyCode(forNamed: .up) == UInt16(kVK_UpArrow))
    }
}
