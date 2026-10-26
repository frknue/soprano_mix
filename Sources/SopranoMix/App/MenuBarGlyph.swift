import AppKit
import SopranoMixCore

/// Soprano Mix's Folio 16 pt menu-bar glyph, drawn in code on a 16-unit grid with a
/// top-left origin: three vertical fader tracks (1.5 pt strokes, round caps) with a short
/// horizontal cap on each at a different height. `outlined` strokes the caps as 1.5 pt
/// lines across their tracks; `filled` draws them as filled rounded bars.
enum MenuBarGlyph {
    static let side: CGFloat = 16
    static let lineWidth: CGFloat = 1.5

    /// (track x, cap y): left cap low, middle cap high, right cap in between.
    private static let faders: [(x: CGFloat, capY: CGFloat)] = [(4, 10), (8, 5), (12, 8)]

    /// The status item's template image; `.hidden` draws the outlined glyph.
    static func image(style: MenuBarIcon) -> NSImage {
        let filled = style == .filled
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            NSColor.black.set()
            for fader in faders {
                let track = NSBezierPath()
                track.move(to: NSPoint(x: fader.x, y: 2.75))
                track.line(to: NSPoint(x: fader.x, y: 13.25))
                stroke(track)
                if filled {
                    let bar = NSRect(x: fader.x - 2.25, y: fader.capY - 1.5, width: 4.5, height: 3)
                    NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
                } else {
                    let cap = NSBezierPath()
                    cap.move(to: NSPoint(x: fader.x - 1.75, y: fader.capY))
                    cap.line(to: NSPoint(x: fader.x + 1.75, y: fader.capY))
                    stroke(cap)
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Soprano Mix"
        return image
    }

    private static func stroke(_ path: NSBezierPath) {
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}
