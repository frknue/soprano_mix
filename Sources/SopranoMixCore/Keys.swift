import Foundation

// Keys for the panel hotkey (Soprano Tab's key model). Parsing and display strings live
// in `KeyParsing.swift` (see docs/ARCHITECTURE.md → Core APIs).

/// Modifier keys.
public struct ModifierSet: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let control = ModifierSet(rawValue: 1 << 2)
    public static let shift = ModifierSet(rawValue: 1 << 3)
    public static let function = ModifierSet(rawValue: 1 << 4)
}

/// A key identified by its physical position (virtual key code), independent of the
/// keyboard layout. Codes are ANSI-positional.
public enum NamedKey: String, CaseIterable, Hashable, Sendable {
    case tab
    case space
    case `return`
    case escape
    case delete
    case forwardDelete
    case left
    case right
    case up
    case down
    case home
    case end
    case pageUp
    case pageDown
    /// The key above Tab (` on US layouts, ^ on German ones).
    case keyAboveTab
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    /// macOS virtual key codes (Carbon `kVK_*`).
    public var keyCodes: [UInt16] {
        switch self {
        case .tab: [0x30]
        case .space: [0x31]
        case .return: [0x24, 0x4C] // Return and keypad Enter
        case .escape: [0x35]
        case .delete: [0x33]
        case .forwardDelete: [0x75]
        case .left: [0x7B]
        case .right: [0x7C]
        case .down: [0x7D]
        case .up: [0x7E]
        case .home: [0x73]
        case .end: [0x77]
        case .pageUp: [0x74]
        case .pageDown: [0x79]
        case .keyAboveTab: [0x32] // kVK_ANSI_Grave
        case .f1: [0x7A]
        case .f2: [0x78]
        case .f3: [0x63]
        case .f4: [0x76]
        case .f5: [0x60]
        case .f6: [0x61]
        case .f7: [0x62]
        case .f8: [0x64]
        case .f9: [0x65]
        case .f10: [0x6D]
        case .f11: [0x67]
        case .f12: [0x6F]
        }
    }
}

/// One key in settings.json: by position (`tab`, `keyAboveTab`, arrows …) or by the
/// character it types on the current layout (`w`, `q` …), so letter shortcuts follow
/// German and other layouts.
public enum KeySpec: Hashable, Sendable {
    case named(NamedKey)
    /// Lowercased; resolved to a key code on the current layout when registered.
    case character(Character)
}

