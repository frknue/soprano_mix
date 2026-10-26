import Foundation

// settings.json spellings and display symbols for the types in Keys.swift (Soprano Tab's,
// without event matching) and the panel hotkey.

extension ModifierSet {
    /// Modifier names in canonical order with their accepted spellings (lowercase).
    private static let spellings: [(member: ModifierSet, canonical: String, symbol: String, aliases: Set<String>)] = [
        (.control, "control", "⌃", ["control", "ctrl", "⌃"]),
        (.option, "option", "⌥", ["option", "alt", "opt", "⌥"]),
        (.shift, "shift", "⇧", ["shift", "⇧"]),
        (.command, "command", "⌘", ["command", "cmd", "⌘"]),
        (.function, "fn", "fn", ["fn", "function"]),
    ]

    /// "option"/"alt"/"opt"/"⌥", "command"/"cmd"/"⌘", "control"/"ctrl"/"⌃", "shift"/"⇧",
    /// "fn"/"function", joined with "+" or written as adjacent symbols ("⌃⌥"),
    /// case-insensitive, spaces ignored. nil when empty or any part is unknown.
    public init?(settingsText: String) {
        let compact = settingsText.filter { !$0.isWhitespace }.lowercased()
        guard !compact.isEmpty else { return nil }
        var result: ModifierSet = []
        for part in compact.split(separator: "+", omittingEmptySubsequences: false) {
            let name = String(part)
            if let entry = Self.spellings.first(where: { $0.aliases.contains(name) }) {
                result.insert(entry.member)
                continue
            }
            // Adjacent symbols: "⌃⌥⇧⌘".
            guard !name.isEmpty else { return nil }
            for character in name {
                guard let entry = Self.spellings.first(where: { $0.symbol.count == 1 && $0.aliases.contains(String(character)) }) else {
                    return nil
                }
                result.insert(entry.member)
            }
        }
        self = result
    }

    /// Canonical spelling: "control+option+shift+command+fn" order, only the members present.
    public var settingsText: String {
        Self.spellings.filter { contains($0.member) }.map(\.canonical).joined(separator: "+")
    }

    /// "⌃⌥⇧⌘" order, "fn" last.
    public var symbols: String {
        Self.spellings.filter { contains($0.member) }.map(\.symbol).joined()
    }
}

extension KeySpec {
    /// Alternative spellings of named keys (lowercase).
    private static let aliases: [String: NamedKey] = [
        "enter": .return,
        "esc": .escape,
        "backspace": .delete,
        "`": .keyAboveTab,
        "grave": .keyAboveTab,
        "backtick": .keyAboveTab,
        "section": .keyAboveTab,
        "spacebar": .space,
    ]

    /// A `NamedKey` raw value (case-insensitive) or alias — enter→return, esc→escape,
    /// backspace→delete, "`"/grave/backtick/section→keyAboveTab, spacebar→space —
    /// or exactly one non-space character → `.character(lowercased)`. nil otherwise.
    public init?(settingsText: String) {
        let trimmed = settingsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if let named = NamedKey.allCases.first(where: { $0.rawValue.lowercased() == lowered }) {
            self = .named(named)
        } else if let named = Self.aliases[lowered] {
            self = .named(named)
        } else if trimmed.count == 1, let character = trimmed.first {
            // Lowercasing can change a character's length; keep it as typed then.
            let lowercased = String(character).lowercased()
            self = .character(lowercased.count == 1 ? Character(lowercased) : character)
        } else {
            return nil
        }
    }

    /// Round-trips through `init(settingsText:)`.
    public var settingsText: String {
        switch self {
        case .named(let key): key.rawValue
        case .character(let character): String(character)
        }
    }

    /// Keycap legend: ⇥ ␣ ↩ esc ⌫ ⌦ ← → ↑ ↓ ↖ ↘ ⇞ ⇟ ` F1…F12; characters uppercased ("M").
    public var symbol: String {
        switch self {
        case .character(let character):
            return String(character).uppercased()
        case .named(let key):
            switch key {
            case .tab: return "⇥"
            case .space: return "␣"
            case .return: return "↩"
            case .escape: return "esc"
            case .delete: return "⌫"
            case .forwardDelete: return "⌦"
            case .left: return "←"
            case .right: return "→"
            case .up: return "↑"
            case .down: return "↓"
            case .home: return "↖"
            case .end: return "↘"
            case .pageUp: return "⇞"
            case .pageDown: return "⇟"
            case .keyAboveTab: return "`"
            case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
                return key.rawValue.uppercased()
            }
        }
    }
}

extension PanelHotkey {
    /// Modifiers that make a combination global-shortcut worthy (shift and fn alone are not).
    private static let requiredModifiers: ModifierSet = [.control, .option, .command]

    /// "control+option+m": modifiers (at least one of control, option, command) joined
    /// with "+", the last part a `KeySpec`. nil otherwise. Spaces are ignored;
    /// "control+option++" binds the "+" key.
    public init?(settingsText: String) {
        let compact = settingsText.filter { !$0.isWhitespace }
        let modifierText: Substring
        let keyText: Substring
        if compact.hasSuffix("++") {
            modifierText = compact.dropLast(2)
            keyText = "+"
        } else {
            guard let separator = compact.lastIndex(of: "+") else { return nil }
            modifierText = compact[..<separator]
            keyText = compact[compact.index(after: separator)...]
        }
        guard !modifierText.isEmpty, !keyText.isEmpty,
              let modifiers = ModifierSet(settingsText: String(modifierText)),
              !modifiers.isDisjoint(with: Self.requiredModifiers),
              let key = KeySpec(settingsText: String(keyText))
        else { return nil }
        self.init(modifiers: modifiers, key: key)
    }

    /// Round-trips through `init(settingsText:)`: "control+option+m".
    public var settingsText: String {
        "\(modifiers.settingsText)+\(key.settingsText)"
    }

    /// "⌃⌥M".
    public var symbols: String {
        modifiers.symbols + key.symbol
    }
}
