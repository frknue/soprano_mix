import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

@MainActor
struct MenuBarGlyphTests {
    /// The glyph drawn black on clear at 2× (32 × 32 pixels, top row first).
    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    @Test("every style is a 16 pt template image")
    func templateImages() {
        for style in MenuBarIcon.allCases {
            let image = MenuBarGlyph.image(style: style)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 16, height: 16))
            #expect(image.accessibilityDescription == "Soprano Mix")
        }
    }

    @Test("filled caps draw differently from outlined caps")
    func filledDiffersFromOutlined() throws {
        let outlined = try bitmap(MenuBarGlyph.image(style: .outlined))
        let filled = try bitmap(MenuBarGlyph.image(style: .filled))

        #expect(outlined.tiffRepresentation != filled.tiffRepresentation)
        // The middle cap sits at y = 5 pt: a filled bar (3 pt) is thicker than a 1.5 pt
        // stroke, so beside the track it reaches pixel row 12 (y 6–6.5 pt), where the
        // outlined cap is clear.
        #expect(alpha(filled, 13, 12) > 0.5)
        #expect(alpha(outlined, 13, 12) < 0.1)
    }

    @Test("the glyph draws three tracks with caps at different heights and leaves the corners clear")
    func drawsThreeFaders() throws {
        let rep = try bitmap(MenuBarGlyph.image(style: .outlined))

        // Tracks at x = 4, 8, 12 pt (pixel columns 8, 16, 24), mid-height.
        for column in [8, 16, 24] {
            #expect(alpha(rep, column, 16) > 0.5)
        }
        // Caps reach beside their tracks only at their own height: left at y = 10, middle
        // at 5, right at 8 (pixel rows 20, 10, 16).
        #expect(alpha(rep, 5, 20) > 0.5)
        #expect(alpha(rep, 5, 10) < 0.1)
        #expect(alpha(rep, 13, 10) > 0.5)
        #expect(alpha(rep, 13, 20) < 0.1)
        #expect(alpha(rep, 21, 16) > 0.5)
        #expect(alpha(rep, 21, 10) < 0.1)
        #expect(alpha(rep, 0, 0) == 0)
        #expect(alpha(rep, 31, 31) == 0)
    }
}
