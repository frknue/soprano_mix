import AppKit
import SopranoMixCore

/// Folio's mixer slider: a 4 pt track (`bgOverlay`, 1 pt `borderStrong` edge) with an
/// ink value fill and a 12 pt raised knob. App sliders put 0–100 % on the first two
/// thirds of the track and 100–400 % on the last third, with a tick and a detent at
/// 100 % and the boost fill in `yellow`. The accent appears only as the 2 pt focus ring
/// around the knob while the slider has keyboard focus.
///
/// Drags report non-final values and the final one on mouse up; arrow keys step (shift
/// for large steps) and commit on key up; a double-click resets app sliders to 100 % and
/// balance sliders to the centre. While a drag or key step is in progress,
/// `setModelValue` leaves the value alone.
final class MixSlider: NSControl {
    enum Kind: Equatable, Sendable {
        /// 0–400 %, 100 % at two thirds, detent at 100 %.
        case app
        /// 0–100 % linear (device volume).
        case output
        /// 0–1, centre detent at 0.5.
        case balance
    }

    /// Value ↔ track position (0…1), detents and keyboard steps; pure.
    struct Mapping: Equatable, Sendable {
        let kind: Kind

        /// Where 100 % sits on an app slider's track.
        static let unityPosition = 2.0 / 3.0
        /// App sliders snap to 100 % within ±3 percentage points.
        static let appDetent = 3.0
        /// Balance sliders snap to the centre within ±0.03.
        static let balanceDetent = 0.03

        init(_ kind: Kind) {
            self.kind = kind
        }

        var range: ClosedRange<Double> {
            switch kind {
            case .app: 0...400
            case .output: 0...100
            case .balance: 0...1
            }
        }

        /// What a double-click resets to; output sliders have none.
        var resetValue: Double? {
            switch kind {
            case .app: 100
            case .output: nil
            case .balance: 0.5
            }
        }

        /// Where the value fill starts: the track's start, or the centre for balance.
        var fillOrigin: Double {
            kind == .balance ? 0.5 : range.lowerBound
        }

        /// The value a drag snaps to and how close it must come.
        var detent: (value: Double, width: Double)? {
            switch kind {
            case .app: (value: 100, width: Self.appDetent)
            case .output: nil
            case .balance: (value: 0.5, width: Self.balanceDetent)
            }
        }

        /// The track position (0…1) of `value`, clamped to the range.
        func position(for value: Double) -> Double {
            let value = clamped(value)
            switch kind {
            case .app:
                let unity = Self.unityPosition
                return value <= 100
                    ? value / 100 * unity
                    : unity + (value - 100) / 300 * (1 - unity)
            case .output:
                return value / 100
            case .balance:
                return value
            }
        }

        /// The value at track position `position` (clamped to 0…1), rounded to the
        /// kind's resolution (1 % or 0.01) and pulled onto the detent when within it.
        func value(at position: Double) -> Double {
            let position = min(max(position, 0), 1)
            let raw: Double
            switch kind {
            case .app:
                let unity = Self.unityPosition
                raw = position <= unity
                    ? position / unity * 100
                    : 100 + (position - unity) / (1 - unity) * 300
            case .output:
                raw = position * 100
            case .balance:
                raw = position
            }
            let value = rounded(clamped(raw))
            if let detent, abs(value - detent.value) <= detent.width {
                return detent.value
            }
            return value
        }

        /// One keyboard step from `value`: ±1 % (±10 % large) for percent sliders,
        /// ±0.02 (±0.1 large) for balance; rounded and clamped, never snapped.
        func stepped(_ value: Double, up: Bool, large: Bool) -> Double {
            let size: Double = kind == .balance ? (large ? 0.1 : 0.02) : (large ? 10 : 1)
            return clamped(rounded(value + (up ? size : -size)))
        }

        /// VoiceOver's value: "60 percent"; balance "centre", "40 percent left".
        func accessibilityText(for value: Double) -> String {
            switch kind {
            case .app, .output:
                return "\(Int(clamped(value).rounded())) percent"
            case .balance:
                let offset = Int(((clamped(value) - 0.5) * 200).rounded())
                if offset == 0 { return "centre" }
                return offset < 0 ? "\(-offset) percent left" : "\(offset) percent right"
            }
        }

        private func clamped(_ value: Double) -> Double {
            min(max(value, range.lowerBound), range.upperBound)
        }

        private func rounded(_ value: Double) -> Double {
            kind == .balance ? (value * 100).rounded() / 100 : value.rounded()
        }
    }

    static let hitHeight: CGFloat = 16
    static let trackHeight: CGFloat = 4
    static let knobDiameter: CGFloat = 12
    /// The focus ring's stroke and its gap outside the knob.
    static let focusRingWidth: CGFloat = 2
    static let focusRingGap: CGFloat = 2
    /// The 1 × 8 pt tick at 100 % on app sliders.
    static let unityTickHeight: CGFloat = 8

    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124
    private static let downArrow: UInt16 = 125
    private static let upArrow: UInt16 = 126

    let mapping: Mapping
    /// Every change: the value and whether it is final (mouse up, key up, reset).
    var onChange: ((Double, _ final: Bool) -> Void)?
    /// The current value, clamped to the mapping's range.
    var value: Double {
        didSet {
            let clamped = min(max(value, mapping.range.lowerBound), mapping.range.upperBound)
            if clamped != value {
                value = clamped
            }
            guard value != oldValue else { return }
            needsDisplay = true
            updateLayers()
        }
    }

    /// Muted rows draw the value fill in `textMuted` (boost included).
    var isMutedLook = false {
        didSet {
            guard isMutedLook != oldValue else { return }
            needsDisplay = true
        }
    }

    /// True from mouse down to mouse up.
    private(set) var isDragging = false
    /// True from an arrow key's step to its key up.
    private(set) var isKeyStepping = false
    /// A drag or key step is in progress: model updates must not move the knob.
    var isTracking: Bool { isDragging || isKeyStepping }
    /// True while the slider is first responder through the keyboard.
    private(set) var showsFocusMark = false {
        didSet {
            guard showsFocusMark != oldValue else { return }
            updateLayers()
        }
    }

    private var theme: AppTheme = .folioPaper
    private var dragOffset: CGFloat = 0
    private var dragChanged = false
    private let knobLayer = CALayer()
    private let focusLayer = CAShapeLayer()

    init(kind: Kind) {
        mapping = Mapping(kind)
        value = mapping.fillOrigin
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: Self.hitHeight))
        wantsLayer = true
        clipsToBounds = false
        focusRingType = .none
        focusLayer.fillColor = nil
        focusLayer.lineWidth = Self.focusRingWidth
        focusLayer.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        updateLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
        updateLayers()
    }

    /// Takes a value from the model unless the user is moving the slider.
    func setModelValue(_ newValue: Double) {
        guard !isTracking else { return }
        value = newValue
    }

    override var doubleValue: Double {
        get { value }
        set { value = newValue }
    }

    // MARK: - Geometry

    /// The 4 pt track; the knob's centre travels from its start to its end.
    var trackRect: NSRect {
        let inset = Self.knobDiameter / 2
        return NSRect(
            x: bounds.minX + inset,
            y: (bounds.midY - Self.trackHeight / 2).rounded(),
            width: max(0, bounds.width - inset * 2),
            height: Self.trackHeight
        )
    }

    private func x(forPosition position: Double) -> CGFloat {
        let track = trackRect
        return track.minX + CGFloat(position) * track.width
    }

    private var knobRect: NSRect {
        let centerX = x(forPosition: mapping.position(for: value))
        let side = Self.knobDiameter
        return NSRect(x: centerX - side / 2, y: (bounds.midY - side / 2).rounded(), width: side, height: side)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayers()
    }

    // MARK: - Drawing

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        let track = trackRect
        guard track.width > 0 else { return }
        let fill = isMutedLook ? colors.textMuted : colors.textPrimary
        var segments: [(from: Double, to: Double, color: NSColor)] = []
        let origin = mapping.fillOrigin
        switch mapping.kind {
        case .app:
            let boost = isMutedLook ? colors.textMuted : colors.yellow
            segments.append((from: origin, to: min(value, 100), color: fill))
            if value > 100 {
                segments.append((from: 100, to: value, color: boost))
            }
        case .output, .balance:
            segments.append((from: min(origin, value), to: max(origin, value), color: fill))
        }
        let fills = segments.compactMap { segment -> (NSRect, NSColor)? in
            let start = x(forPosition: mapping.position(for: segment.from))
            let end = x(forPosition: mapping.position(for: segment.to))
            guard end > start else { return nil }
            return (NSRect(x: start, y: track.minY, width: end - start, height: track.height), segment.color)
        }
        Self.drawTrack(track, fills: fills, colors: colors)

        if mapping.kind == .app {
            let tickX = x(forPosition: Mapping.unityPosition).rounded(.down)
            colors.textMuted.setFill()
            NSRect(
                x: tickX,
                y: (bounds.midY - Self.unityTickHeight / 2).rounded(),
                width: Chrome.hairline,
                height: Self.unityTickHeight
            ).fill()
        }
    }

    /// The Folio track: `bgOverlay` with a 1 pt `borderStrong` edge, radius 2, then each
    /// fill clipped to the track's shape. Shared with the volume HUD.
    static func drawTrack(_ track: NSRect, fills: [(NSRect, NSColor)], colors: ThemeColors) {
        let radius = track.height / 2
        let shape = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        colors.bgOverlay.setFill()
        shape.fill()
        let edge = NSBezierPath(
            roundedRect: track.insetBy(dx: 0.5, dy: 0.5),
            xRadius: radius - 0.5,
            yRadius: radius - 0.5
        )
        edge.lineWidth = Chrome.hairline
        colors.borderStrong.setStroke()
        edge.stroke()
        guard !fills.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        for (rect, color) in fills {
            color.setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The knob and the focus ring live in sublayers so the ring (and the knob's soft
    /// shadow) may extend past the 16 pt hit height.
    private func updateLayers() {
        let colors = theme.colors
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer, knobLayer.superlayer !== layer {
            layer.masksToBounds = false
            layer.addSublayer(knobLayer)
            layer.addSublayer(focusLayer)
        }
        let knob = knobRect
        knobLayer.frame = knob
        knobLayer.cornerRadius = Self.knobDiameter / 2
        knobLayer.backgroundColor = colors.bgRaised.cgColor
        knobLayer.borderWidth = Chrome.hairline
        knobLayer.borderColor = colors.borderStrong.cgColor
        let shadow = colors.shadowE2
        knobLayer.shadowColor = shadow.color.cgColor
        knobLayer.shadowOpacity = shadow.opacity
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = CGSize(width: 0, height: knobLayer.contentsAreFlipped() ? 1 : -1)
        knobLayer.isHidden = trackRect.width <= 0

        let ringInset = Self.focusRingGap + Self.focusRingWidth / 2
        focusLayer.frame = layer?.bounds ?? bounds
        focusLayer.path = CGPath(ellipseIn: knob.insetBy(dx: -ringInset, dy: -ringInset), transform: nil)
        focusLayer.strokeColor = colors.focusMark.cgColor
        focusLayer.isHidden = !showsFocusMark || knobLayer.isHidden
        CATransaction.commit()
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        showsFocusMark = false
        isKeyStepping = false
        if event.clickCount >= 2, let reset = mapping.resetValue {
            isDragging = false
            value = reset
            report(final: true)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let knob = knobRect
        dragOffset = knob.insetBy(dx: -2, dy: -2).contains(point) ? point.x - knob.midX : 0
        dragChanged = false
        isDragging = true
        drag(to: point.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        drag(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        if dragChanged {
            report(final: true)
        }
    }

    private func drag(to locationX: CGFloat) {
        let track = trackRect
        guard track.width > 0 else { return }
        let position = Double((locationX - dragOffset - track.minX) / track.width)
        let newValue = mapping.value(at: position)
        guard newValue != value else { return }
        value = newValue
        dragChanged = true
        report(final: false)
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            showsFocusMark = NSApplication.shared.currentEvent?.type == .keyDown
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            showsFocusMark = false
            if isKeyStepping {
                isKeyStepping = false
                report(final: true)
            }
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        guard let up = Self.direction(for: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        showsFocusMark = true
        step(up: up, large: event.modifierFlags.contains(.shift))
    }

    override func keyUp(with event: NSEvent) {
        guard Self.direction(for: event.keyCode) != nil else {
            super.keyUp(with: event)
            return
        }
        guard isKeyStepping else { return }
        isKeyStepping = false
        report(final: true)
    }

    /// One keyboard step, reported as non-final until the key comes up.
    func step(up: Bool, large: Bool) {
        isKeyStepping = true
        let newValue = mapping.stepped(value, up: up, large: large)
        guard newValue != value else { return }
        value = newValue
        report(final: false)
    }

    private static func direction(for keyCode: UInt16) -> Bool? {
        switch keyCode {
        case rightArrow, upArrow: true
        case leftArrow, downArrow: false
        default: nil
        }
    }

    // MARK: - Accessibility

    override func accessibilityValue() -> Any? {
        mapping.accessibilityText(for: value)
    }

    override func accessibilityPerformIncrement() -> Bool {
        commitStep(up: true)
    }

    override func accessibilityPerformDecrement() -> Bool {
        commitStep(up: false)
    }

    private func commitStep(up: Bool) -> Bool {
        let newValue = mapping.stepped(value, up: up, large: false)
        guard newValue != value else { return false }
        value = newValue
        report(final: true)
        return true
    }

    // MARK: - Reporting

    private func report(final: Bool) {
        onChange?(value, final)
        if let action {
            sendAction(action, to: target)
        }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}
