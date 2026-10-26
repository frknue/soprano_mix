import Foundation

/// Soprano's `appearance` preference: follow macOS, or pin light or dark.
public enum SopranoAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// The two keys of Soprano's settings.json that `theme: "soprano"` follows: `theme` and
/// `appearance`. Soprano Mix's own resolver does not read Soprano's file.
public struct SopranoThemeFile: Equatable, Sendable {
    /// Soprano's default theme id: Folio, Paper or Ink by appearance.
    public static let defaultThemeID = "folio"

    public var themeID: String
    public var appearance: SopranoAppearance

    public init(themeID: String = SopranoThemeFile.defaultThemeID, appearance: SopranoAppearance = .system) {
        self.themeID = themeID
        self.appearance = appearance
    }

    /// Reads both keys from Soprano's JSONC text. Like Soprano itself, a missing key, an
    /// unknown theme id or appearance, or a document that does not parse gives the
    /// defaults (`folio`, `system`) for that key.
    public static func parse(text: String, knownThemeIDs: Set<String>) -> SopranoThemeFile {
        var file = SopranoThemeFile()
        guard let data = try? JSONCText.strictJSONData(from: text),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return file }
        if let id = root["theme"] as? String, knownThemeIDs.contains(id) {
            file.themeID = id
        }
        if let raw = root["appearance"] as? String, let appearance = SopranoAppearance(rawValue: raw) {
            file.appearance = appearance
        }
        return file
    }
}
