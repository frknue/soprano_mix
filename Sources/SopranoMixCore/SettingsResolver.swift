import Foundation

/// settings.json → `SopranoMixSettings`. Every key is optional; a bad value keeps its
/// default and becomes a `.warning` naming its dotted path ("audio.bufferFrames",
/// "apps.wine:TEKKEN 8.volume"), the value found and what is allowed.
public enum SettingsResolver {
    /// JSONC (comments, trailing commas) → settings over the defaults. A document that is
    /// not a JSON object gives `settings == nil` and one `.error` issue with its line.
    /// Every bad value is a `.warning` and keeps its default; unknown keys warn.
    public static func resolve(text: String, knownThemeIDs: Set<String>) -> SettingsResolution {
        let root: [String: Any]
        do {
            let data = try JSONCText.strictJSONData(from: text)
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard let dictionary = object as? [String: Any] else {
                let line = firstValueLine(in: String(decoding: data, as: UTF8.self))
                return failure("settings.json must be a JSON object", line: line)
            }
            root = dictionary
        } catch let error as JSONCText.ParseError {
            return failure(error.message, line: error.line)
        } catch {
            return failure("settings.json could not be read: \(error.localizedDescription)", line: 1)
        }

        var reader = Reader(knownThemeIDs: knownThemeIDs)
        let settings = reader.settings(from: root)
        return SettingsResolution(settings: settings, issues: reader.issues)
    }

    private static func failure(_ message: String, line: Int) -> SettingsResolution {
        SettingsResolution(settings: nil, issues: [ConfigIssue(severity: .error, message: message, line: line)])
    }

    /// The 1-based line of the first value in strict JSON text. Comment stripping keeps
    /// every newline, so lines match the original document.
    private static func firstValueLine(in text: String) -> Int {
        var line = 1
        for character in text {
            if character.isNewline {
                line += 1
            } else if !character.isWhitespace {
                break
            }
        }
        return line
    }
}

// MARK: - Reader

/// One resolution pass: reads sections over the defaults and collects issues.
private struct Reader {
    let knownThemeIDs: Set<String>
    var issues: [ConfigIssue] = []

    init(knownThemeIDs: Set<String>) {
        self.knownThemeIDs = knownThemeIDs
    }

    /// Theme ids that are always valid: follow Soprano, follow macOS (Folio).
    static let builtInThemes = ["soprano", "folio"]

    mutating func settings(from root: [String: Any]) -> SopranoMixSettings {
        var settings = SopranoMixSettings()
        warnUnknownKeys(in: root, path: nil, known: ["theme", "apps", "outputs", "panel", "volumeKeys", "audio", "app"])

        if let value = root["theme"] {
            if let id = value as? String, Self.builtInThemes.contains(id) || knownThemeIDs.contains(id) {
                settings.theme = id
            } else {
                let known = (Self.builtInThemes + knownThemeIDs.subtracting(Self.builtInThemes).sorted())
                    .map { "\"\($0)\"" }
                    .joined(separator: ", ")
                warn("theme: \(describe(value)) is not a known theme; kept \"\(settings.theme)\". Known themes: \(known).")
            }
        }
        if let apps = section("apps", in: root, path: nil) {
            settings.apps = self.apps(apps)
        }
        if let outputs = section("outputs", in: root, path: nil) {
            settings.outputs = self.outputs(outputs)
        }
        if let panel = section("panel", in: root, path: nil) {
            settings.panel = self.panel(panel)
        }
        if let keys = section("volumeKeys", in: root, path: nil) {
            warnUnknownKeys(in: keys, path: "volumeKeys", known: ["anyOutput", "hud"])
            bool("anyOutput", in: keys, path: "volumeKeys", into: &settings.volumeKeys.anyOutput)
            bool("hud", in: keys, path: "volumeKeys", into: &settings.volumeKeys.hud)
        }
        if let audio = section("audio", in: root, path: nil) {
            settings.audio = self.audio(audio)
        }
        if let app = section("app", in: root, path: nil) {
            warnUnknownKeys(in: app, path: "app", known: ["startAtLogin", "menuBarIcon"])
            bool("startAtLogin", in: app, path: "app", into: &settings.app.startAtLogin)
            choice("menuBarIcon", in: app, path: "app", into: &settings.app.menuBarIcon)
        }
        return settings
    }

    // MARK: Sections

    /// `apps`: keys taken as given (bundle ids, "wine:<Name>", "exe:<name>"; dots, colons
    /// and spaces are part of the key).
    private mutating func apps(_ object: [String: Any]) -> [AppKey: AppAudioSettings] {
        var result: [AppKey: AppAudioSettings] = [:]
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                warn("apps: an empty app key is not an app; dropped.")
                continue
            }
            let path = "apps.\(key)"
            guard let entry = value as? [String: Any] else {
                warn("\(path): \(describe(value)) is not an object; dropped.")
                continue
            }
            warnUnknownKeys(in: entry, path: path, known: ["volume", "muted", "output"])
            var audio = AppAudioSettings()
            percent("volume", in: entry, path: path, range: VolumeLaw.appRange, into: &audio.volume)
            bool("muted", in: entry, path: path, into: &audio.muted)
            if let output = entry["output"] {
                if output is NSNull {
                    audio.output = nil
                } else if let name = output as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    audio.output = name.caseInsensitiveCompare("default") == .orderedSame ? nil : name
                } else {
                    warn("\(path).output: \(describe(output)) is not a device UID or name, \"default\" or null; kept \"default\".")
                }
            }
            result[AppKey(rawValue: key)] = audio
        }
        return result
    }

    /// `outputs`: software volume per device UID or name.
    private mutating func outputs(_ object: [String: Any]) -> [String: OutputVolumeSettings] {
        var result: [String: OutputVolumeSettings] = [:]
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                warn("outputs: an empty device key is not a device; dropped.")
                continue
            }
            let path = "outputs.\(key)"
            guard let entry = value as? [String: Any] else {
                warn("\(path): \(describe(value)) is not an object; dropped.")
                continue
            }
            warnUnknownKeys(in: entry, path: path, known: ["volume", "muted"])
            var output = OutputVolumeSettings()
            percent("volume", in: entry, path: path, range: VolumeLaw.outputRange, into: &output.volume)
            bool("muted", in: entry, path: path, into: &output.muted)
            result[key] = output
        }
        return result
    }

    private mutating func panel(_ object: [String: Any]) -> PanelSettings {
        let path = "panel"
        warnUnknownKeys(in: object, path: path, known: ["hotkey", "meters"])
        var panel = PanelSettings()
        if let value = object["hotkey"] {
            if value is NSNull {
                panel.hotkey = nil
            } else if let text = value as? String, let hotkey = PanelHotkey(settingsText: text) {
                panel.hotkey = hotkey
            } else {
                warn("\(path).hotkey: \(describe(value)) is not a shortcut like \"control+option+m\" (control, option or command plus a key) or null; no hotkey.")
            }
        }
        bool("meters", in: object, path: path, into: &panel.meters)
        return panel
    }

    private mutating func audio(_ object: [String: Any]) -> AudioEngineSettings {
        let path = "audio"
        warnUnknownKeys(in: object, path: path, known: ["bufferFrames", "limiter"])
        var audio = AudioEngineSettings()
        if let value = object["bufferFrames"] {
            let range = AudioEngineSettings.bufferFramesRange
            if let frames = integer(value) {
                let clamped = min(max(range.lowerBound, frames), range.upperBound)
                if clamped != frames {
                    warn("\(path).bufferFrames: \(frames) is outside \(range.lowerBound)–\(range.upperBound); clamped to \(clamped).")
                }
                audio.bufferFrames = clamped
            } else {
                warn("\(path).bufferFrames: \(describe(value)) is not a whole number of frames; kept \(audio.bufferFrames).")
            }
        }
        bool("limiter", in: object, path: path, into: &audio.limiter)
        return audio
    }

    // MARK: Helpers

    private mutating func warn(_ message: String) {
        issues.append(ConfigIssue(severity: .warning, message: message))
    }

    private func join(_ path: String?, _ key: String) -> String {
        path.map { "\($0).\(key)" } ?? key
    }

    private mutating func warnUnknownKeys(in object: [String: Any], path: String?, known: Set<String>) {
        for key in object.keys.sorted() where !known.contains(key) {
            warn("Unknown setting \"\(join(path, key))\".")
        }
    }

    /// The object at `key`, or nil (with a warning when present but not an object).
    private mutating func section(_ key: String, in object: [String: Any], path: String?) -> [String: Any]? {
        guard let value = object[key] else { return nil }
        guard let section = value as? [String: Any] else {
            warn("\(join(path, key)): \(describe(value)) is not an object; ignored.")
            return nil
        }
        return section
    }

    private mutating func bool(_ key: String, in object: [String: Any], path: String, into target: inout Bool) {
        guard let value = object[key] else { return }
        if let flag = boolean(value) {
            target = flag
        } else {
            warn("\(path).\(key): \(describe(value)) is not true or false; kept \(target).")
        }
    }

    /// A JSON number clamped to `range` (with a warning when outside).
    private mutating func percent(
        _ key: String,
        in object: [String: Any],
        path: String,
        range: ClosedRange<Double>,
        into target: inout Double
    ) {
        guard let value = object[key] else { return }
        guard let found = number(value) else {
            warn("\(path).\(key): \(describe(value)) is not a number of percent (\(format(range.lowerBound))–\(format(range.upperBound))); kept \(format(target)).")
            return
        }
        let clamped = min(max(range.lowerBound, found), range.upperBound)
        if clamped != found {
            warn("\(path).\(key): \(format(found)) is outside \(format(range.lowerBound))–\(format(range.upperBound)); clamped to \(format(clamped)).")
        }
        target = clamped
    }

    /// An enum value by its rawValue; a bad value warns with the allowed values.
    private mutating func choice<Value: RawRepresentable & CaseIterable>(
        _ key: String,
        in object: [String: Any],
        path: String,
        into target: inout Value
    ) where Value.RawValue == String {
        guard let value = object[key] else { return }
        if let raw = value as? String, let parsed = Value(rawValue: raw) {
            target = parsed
        } else {
            let allowed = Value.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            warn("\(path).\(key): \(describe(value)) is not one of \(allowed); kept \"\(target.rawValue)\".")
        }
    }

    /// JSON booleans only (JSONSerialization gives NSNumber for both numbers and booleans).
    private func boolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Any finite JSON number (not a boolean).
    private func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// JSON numbers without a fractional part.
    private func integer(_ value: Any) -> Int? {
        guard let double = number(value), double == double.rounded(), abs(double) < 1e9 else { return nil }
        return Int(double)
    }

    /// "60", "62.5".
    private func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private func describe(_ value: Any) -> String {
        switch value {
        case is NSNull:
            return "null"
        case let string as String:
            return "\"\(string)\""
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case is [Any]:
            return "an array"
        case is [String: Any]:
            return "an object"
        default:
            return String(describing: value)
        }
    }
}
