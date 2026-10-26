import Foundation

/// Windows paths of programs running under Wine (CrossOver, Whisky, plain Wine).
public enum WinePath {
    /// `^[A-Za-z]:\\` — what Wine (CrossOver, Whisky, plain Wine) puts in a process's
    /// argv[0] (and sometimes its executable path).
    public static func isWindowsPath(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars.prefix(3))
        guard scalars.count == 3 else { return false }
        let letter = scalars[0].value
        let isASCIILetter = (65...90).contains(letter) || (97...122).contains(letter)
        return isASCIILetter && scalars[1] == ":" && scalars[2] == "\\"
    }

    /// The app's display name from a Windows executable path, case kept:
    /// …\steamapps\common\<Game>\… → "<Game>";
    /// …\Program Files[ (x86)]\Steam\… → "Steam";
    /// …\Program Files[ (x86)]\<Folder>\… → "<Folder>" (not "Common Files");
    /// …\GOG Games\<Game>\… and …\Epic Games\<Game>\… → "<Game>";
    /// else the file name without ".exe" (any case).
    public static func appName(forWindowsPath path: String) -> String {
        let components = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        let lowered = components.map { $0.lowercased() }
        // Directories only: the last component is the file.
        let lastDirectory = components.count - 2

        // Steam games: …\steamapps\common\<Game>\…
        if lastDirectory >= 2 {
            for index in 0...(lastDirectory - 2) where lowered[index] == "steamapps" && lowered[index + 1] == "common" {
                return components[index + 2]
            }
        }
        // GOG and Epic installs: …\GOG Games\<Game>\…, …\Epic Games\<Game>\…
        if lastDirectory >= 1 {
            for index in 0...(lastDirectory - 1) where lowered[index] == "gog games" || lowered[index] == "epic games" {
                return components[index + 1]
            }
        }
        // …\Program Files[ (x86)]\Steam\… and …\Program Files[ (x86)]\<Folder>\…
        if lastDirectory >= 1 {
            for index in 0...(lastDirectory - 1) where lowered[index] == "program files" || lowered[index] == "program files (x86)" {
                let folder = lowered[index + 1]
                if folder == "steam" { return "Steam" }
                if folder != "common files" { return components[index + 1] }
            }
        }

        guard let file = components.last else { return path }
        if file.lowercased().hasSuffix(".exe"), file.count > 4 {
            return String(file.dropLast(4))
        }
        return file
    }

    /// The macOS path of a Windows path inside a Wine prefix: "C:\a\b.exe" →
    /// "<prefix>/drive_c/a/b.exe"; "Z:\Users\x" → "/Users/x"; other drive letters →
    /// "<prefix>/dosdevices/<letter>:/…" (lowercase letter). nil when not a Windows path.
    public static func macPath(forWindowsPath path: String, prefix: String) -> String? {
        guard isWindowsPath(path), let first = path.first else { return nil }
        let letter = String(first).lowercased()
        let rest = String(path.dropFirst(3)).replacingOccurrences(of: "\\", with: "/")
        var base = prefix
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        switch letter {
        case "c": return "\(base)/drive_c/\(rest)"
        case "z": return "/\(rest)"
        default: return "\(base)/dosdevices/\(letter):/\(rest)"
        }
    }
}
