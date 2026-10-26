import Foundation

/// A settings.json edit that could not be applied, positioned in the original text.
public struct SettingsEditError: Error, Equatable, Sendable {
    public let message: String
    /// 1-based line in the edited document.
    public let line: Int

    public init(message: String, line: Int) {
        self.message = message
        self.line = line
    }
}

/// Surgical writes into settings.json that keep the user's comments and layout.
public enum SettingsEditor {
    /// Sets `value` (Bool, Int, Double, String, [Any], [String: Any], NSNull) at `path`,
    /// creating missing objects and keeping comments and key order (vendored `JSONCText`).
    /// Path elements are whole object keys: `["apps", "wine:TEKKEN 8", "volume"]` writes
    /// the "wine:TEKKEN 8" entry of "apps", whatever dots, colons or spaces it holds.
    /// Throws `SettingsEditError` when the document is not a JSON object.
    public static func setting(_ value: Any, at path: [String], in text: String) throws -> String {
        do {
            return try JSONCText.setting(value, at: path, in: text)
        } catch let error as JSONCText.ParseError {
            throw SettingsEditError(message: error.message, line: error.line)
        }
    }
}
