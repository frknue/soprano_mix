import AppKit
import Testing
@testable import SopranoMixCore

struct KeyParsingTests {
    @Test("modifier aliases, symbols and spacing parse to one canonical spelling")
    func modifierAliases() {
        #expect(ModifierSet(settingsText: "alt") == .option)
        #expect(ModifierSet(settingsText: " Cmd + SHIFT ") == [.command, .shift])
        #expect(ModifierSet(settingsText: "⌃⌥") == [.control, .option])
        #expect(ModifierSet(settingsText: "control+option") == [.control, .option])

        let all: ModifierSet = [.command, .option, .control, .shift, .function]
        #expect(all.settingsText == "control+option+shift+command+fn")
        #expect(all.symbols == "⌃⌥⇧⌘fn")
        #expect(ModifierSet(settingsText: all.settingsText) == all)
    }

    @Test("empty, unknown or dangling modifier parts are rejected")
    func modifierRejections() {
        #expect(ModifierSet(settingsText: "") == nil)
        #expect(ModifierSet(settingsText: "hyper") == nil)
        #expect(ModifierSet(settingsText: "option+") == nil)
        #expect(ModifierSet(settingsText: "⌃x") == nil)
    }

    @Test("every named key round-trips through its settings spelling")
    func namedKeyRoundTrip() {
        for key in NamedKey.allCases {
            let spec = KeySpec.named(key)
            #expect(KeySpec(settingsText: spec.settingsText) == spec)
            #expect(KeySpec(settingsText: spec.settingsText.uppercased()) == spec)
        }
        #expect(KeySpec(settingsText: "M") == .character("m"))
        #expect(KeySpec(settingsText: "esc") == .named(.escape))
        #expect(KeySpec(settingsText: "mm") == nil)
        #expect(KeySpec.character("m").symbol == "M")
        #expect(KeySpec.named(.space).symbol == "␣")
    }

    @Test("a panel hotkey needs control, option or command plus one key")
    func panelHotkeyParsing() {
        let hotkey = PanelHotkey(settingsText: "control+option+m")
        #expect(hotkey == PanelHotkey(modifiers: [.control, .option], key: .character("m")))
        #expect(hotkey?.settingsText == "control+option+m")
        #expect(hotkey?.symbols == "⌃⌥M")
        #expect(PanelHotkey(settingsText: " Cmd + Shift + F5 ") == PanelHotkey(modifiers: [.command, .shift], key: .named(.f5)))
        #expect(PanelHotkey(settingsText: "control+option++") == PanelHotkey(modifiers: [.control, .option], key: .character("+")))

        #expect(PanelHotkey(settingsText: "m") == nil)
        #expect(PanelHotkey(settingsText: "shift+m") == nil)
        #expect(PanelHotkey(settingsText: "fn+m") == nil)
        #expect(PanelHotkey(settingsText: "control+option") == nil)
        #expect(PanelHotkey(settingsText: "control+") == nil)
        #expect(PanelHotkey(settingsText: "hyper+m") == nil)
        #expect(PanelHotkey(settingsText: "") == nil)
    }

    @Test("a panel hotkey round-trips through its settings text")
    func panelHotkeyRoundTrip() {
        let hotkeys = [
            PanelHotkey(modifiers: [.command, .option], key: .named(.space)),
            PanelHotkey(modifiers: [.control, .shift, .function], key: .character("9")),
            PanelHotkey(modifiers: .control, key: .named(.keyAboveTab)),
        ]
        for hotkey in hotkeys {
            #expect(PanelHotkey(settingsText: hotkey.settingsText) == hotkey)
        }
    }
}
