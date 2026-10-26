import AppKit
import SopranoMixCore

/// A 2 pt level meter under an app row's slider track: `textMuted` at 70 % alpha up to
/// the position (a `MeterScale` position, 0…1), the part at or above −1 dBFS in
/// `danger`. nil (not playing, no level) draws nothing.
final class LevelMeterView: NSView {
    static let height: CGFloat = 2
    /// The `MeterScale` position of −1 dBFS.
    static let clipPosition: Double = (MeterScale.floorDecibels + 1) / MeterScale.floorDecibels
    static let fillAlpha: CGFloat = 0.7

    var position: Double? {
        didSet {
            guard position != oldValue else { return }
            needsDisplay = true
        }
    }

    private var theme: AppTheme = .folioPaper

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let position, position > 0, bounds.width > 0 else { return }
        let colors = theme.colors
        let level = min(position, 1)
        let end = bounds.minX + bounds.width * CGFloat(level)
        let clipX = bounds.minX + bounds.width * CGFloat(Self.clipPosition)
        colors.textMuted.withAlphaComponent(Self.fillAlpha).setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: min(end, clipX) - bounds.minX, height: bounds.height).fill()
        if level >= Self.clipPosition {
            colors.danger.setFill()
            NSRect(x: clipX, y: bounds.minY, width: max(end - clipX, Chrome.hairline), height: bounds.height).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
