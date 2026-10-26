import Foundation

/// Resolves the app named on the command line (`SopranoMix set spotify 60`).
public enum AppMatcher {
    public enum Result: Equatable, Sendable {
        case match(AudioApp)
        case none
        case ambiguous([AudioApp])
    }

    /// Exact key; then name equal (case- and diacritic-insensitive); then name prefix;
    /// then name substring. A level with more than one hit is `.ambiguous`.
    public static func match(_ query: String, in apps: [AudioApp]) -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        if let exact = apps.first(where: { $0.key.rawValue == trimmed }) {
            return .match(exact)
        }

        let needle = fold(trimmed)
        let names = apps.map { (app: $0, name: fold($0.name)) }
        let levels: [(String) -> Bool] = [
            { $0 == needle },
            { $0.hasPrefix(needle) },
            { $0.contains(needle) },
        ]
        for level in levels {
            let hits = names.filter { level($0.name) }.map { $0.app }
            if hits.count == 1 { return .match(hits[0]) }
            if hits.count > 1 { return .ambiguous(hits) }
        }
        return .none
    }

    /// True when `query` looks like a settings key (contains "." or starts with "wine:"
    /// or "exe:"), so the CLI may set it while the app is not running.
    public static func isKeyLike(_ query: String) -> Bool {
        query.contains(".") || query.hasPrefix("wine:") || query.hasPrefix("exe:")
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
