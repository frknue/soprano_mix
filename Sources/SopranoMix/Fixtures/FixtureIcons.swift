import AppKit
import SopranoMixCore

/// Fake app icons: a squircle in the app's colour with its initial, or the template SF
/// Symbol of `.symbol` sources. Deterministic, so snapshots of the same scenario are
/// byte-stable. Cached per app key.
@MainActor
final class FixtureIcons: AppIconProviding {
    /// Point size of the drawn icons (rendered at 2x).
    static let side: CGFloat = 64

    private var cache: [AppKey: NSImage] = [:]

    init() {}

    func icon(for app: AudioApp) -> NSImage {
        if let cached = cache[app.key] { return cached }
        let image: NSImage
        if case let .symbol(name) = app.icon {
            image = Self.symbolIcon(name)
        } else {
            image = Self.squircle(for: app)
        }
        cache[app.key] = image
        return image
    }

    private static func symbolIcon(_ name: String) -> NSImage {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        guard let symbol else { return NSImage(size: NSSize(width: side, height: side)) }
        let configured = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side / 2, weight: .regular)) ?? symbol
        configured.isTemplate = true
        return configured
    }

    private static func squircle(for app: AudioApp) -> NSImage {
        let size = NSSize(width: side, height: side)
        let scale: CGFloat = 2
        guard let context = CGContext(
            data: nil,
            width: Int(side * scale),
            height: Int(side * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: size) }
        context.scaleBy(x: scale, y: scale)

        // The macOS icon grid: the body leaves 8 % of margin, corners at 22.5 %.
        let body = CGRect(origin: .zero, size: size).insetBy(dx: side * 0.08, dy: side * 0.08)
        let radius = body.width * 0.225
        let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.setFillColor(FixtureIconPalette.color(for: app.key).cgColor)
        context.fillPath()
        // A darker lower band gives the flat tile some depth (y grows up here).
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setFillColor(NSColor.black.withAlphaComponent(0.16).cgColor)
        context.fill(CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.3))
        context.restoreGState()

        let initial = app.name.first.map { String($0).uppercased() } ?? "?"
        let text = NSAttributedString(string: initial, attributes: [
            .font: NSFont.systemFont(ofSize: side * 0.42, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ])
        let textSize = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: NSPoint(x: body.midX - textSize.width / 2, y: body.midY - textSize.height / 2))
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: image, size: size)
    }
}

/// Fixture app colours: brand-like ones for the scenario apps, a stable hash-picked one
/// for anything else.
enum FixtureIconPalette {
    private static let colorsByKey: [String: UInt32] = [
        "com.spotify.client": 0x1DB954,
        "com.apple.Safari": 0x1E88E5,
        "com.hnc.Discord": 0x5865F2,
        "com.apple.Music": 0xFA3C55,
        "wine:TEKKEN 8": 0xB3261E,
        "wine:Steam": 0x1B2838,
        "com.google.Chrome": 0x4285F4,
        "com.tinyspeck.slackmacgap": 0x611F69,
        "us.zoom.xos": 0x2D8CFF,
        "com.microsoft.teams2": 0x5B5FC7,
        "org.mozilla.firefox": 0xE66000,
        "org.videolan.vlc": 0xFF8800,
        "com.colliderli.iina": 0x3C3C46,
        "com.apple.podcasts": 0x9933CC,
        "exe:afplay": 0x5E5E5E,
    ]

    private static let fallback: [UInt32] = [0x2BB673, 0xD9534F, 0x5C6BC0, 0x00897B, 0xC0782F, 0x8E6CC4]

    static func color(for key: AppKey) -> NSColor {
        if let hex = colorsByKey[key.rawValue] { return color(hex: hex) }
        // FNV-1a over the key: stable across runs, unlike `hashValue`.
        var hash: UInt32 = 2_166_136_261
        for byte in key.rawValue.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return color(hex: fallback[Int(hash % UInt32(fallback.count))])
    }

    static func color(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
