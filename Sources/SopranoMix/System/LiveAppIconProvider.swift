import AppKit
import SopranoMixCore
import UniformTypeIdentifiers

/// App icons by `IconSource`, cached per app key (recomputed when the key's source
/// changes). Never fails: every path ends in a generic icon.
@MainActor
final class LiveAppIconProvider: AppIconProviding {
    private struct Entry {
        var source: IconSource
        var image: NSImage
    }

    /// The size SF Symbol icons are drawn at; the panel puts template icons on a glyph tile.
    static let symbolPointSize: CGFloat = 24

    private var cache: [AppKey: Entry] = [:]

    init() {}

    func icon(for app: AudioApp) -> NSImage {
        if let entry = cache[app.key], entry.source == app.icon {
            return entry.image
        }
        let image = Self.image(for: app.icon)
        cache[app.key] = Entry(source: app.icon, image: image)
        return image
    }

    private static func image(for source: IconSource) -> NSImage {
        switch source {
        case .bundle(let path):
            return NSWorkspace.shared.icon(forFile: path)
        case .runningApp(let pid):
            return NSRunningApplication(processIdentifier: pid)?.icon ?? genericAppIcon
        case .windowsExecutable(let windowsPath, let wineprefix):
            return windowsIcon(windowsPath: windowsPath, wineprefix: wineprefix)
        case .executable(let path):
            guard let path, FileManager.default.fileExists(atPath: path) else {
                return NSWorkspace.shared.icon(for: .unixExecutable)
            }
            return NSWorkspace.shared.icon(forFile: path)
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return genericAppIcon }
            symbol.isTemplate = true
            return symbol
        }
    }

    private static var genericAppIcon: NSImage {
        NSWorkspace.shared.icon(for: .applicationBundle)
    }

    // MARK: - Windows programs

    /// The .exe's own icon (its first RT_GROUP_ICON), else CrossOver's icon, else the
    /// generic application icon.
    private static func windowsIcon(windowsPath: String, wineprefix: String?) -> NSImage {
        if let path = existingMacPath(windowsPath: windowsPath, wineprefix: wineprefix),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
           let ico = PEIconExtractor.icoData(fromPE: data),
           let image = NSImage(data: ico) {
            return image
        }
        if let crossOver = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.codeweavers.CrossOver") {
            return NSWorkspace.shared.icon(forFile: crossOver.path)
        }
        return genericAppIcon
    }

    /// The first existing macOS path of `windowsPath`: inside the process's own prefix,
    /// then inside every CrossOver bottle (alphabetical) of CrossOver's configured
    /// `BottleDir` (bottles may live on another volume) and of the default location,
    /// then `~/.wine`.
    private static func existingMacPath(windowsPath: String, wineprefix: String?) -> String? {
        let fileManager = FileManager.default
        var prefixes: [String] = []
        if let wineprefix, !wineprefix.isEmpty { prefixes.append(wineprefix) }
        let home = fileManager.homeDirectoryForCurrentUser
        var bottleDirectories: [String] = []
        if let configured = CFPreferencesCopyAppValue("BottleDir" as CFString, "com.codeweavers.CrossOver" as CFString) as? String,
           !configured.isEmpty {
            bottleDirectories.append((configured as NSString).expandingTildeInPath)
        }
        bottleDirectories.append(home.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true).path)
        for directory in bottleDirectories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                prefixes.append((directory as NSString).appendingPathComponent(name))
            }
        }
        prefixes.append(home.appendingPathComponent(".wine", isDirectory: true).path)

        var seen: Set<String> = []
        for prefix in prefixes where seen.insert(prefix).inserted {
            guard let path = WinePath.macPath(forWindowsPath: windowsPath, prefix: prefix) else { return nil }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return path
            }
        }
        return nil
    }
}
