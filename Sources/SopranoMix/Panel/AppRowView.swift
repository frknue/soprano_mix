import AppKit
import SopranoMixCore

/// One app in the panel, 52 high. Line 1 (y 8, 18 high) from x 48: an error diamond
/// for a failed route, the name, and trailing the output chip (when not following the
/// system output), the compact output menu and the mute button. Line 2 (y 30, 16
/// high): the 0–400 % slider, the readout (44 wide) and the level meter 2 pt under the
/// track. The 24 pt icon sits at x 16, centred. Hover draws the `.hover` pill.
///
/// Rows are reused by `AppKey`; `update` never moves a slider the user is dragging.
final class AppRowView: PanelFlippedView {
    static let height: CGFloat = 52
    static let iconX: CGFloat = 16
    static let iconSide: CGFloat = 24
    static let contentX: CGFloat = 48
    static let trailingInset: CGFloat = 16
    static let line1Y: CGFloat = 8
    static let line1Height: CGFloat = 18
    static let line2Y: CGFloat = 30
    static let line2Height: CGFloat = 16
    static let readoutWidth: CGFloat = 44
    static let meterGap: CGFloat = 2
    /// The glyph tile behind template (SF Symbol) icons.
    static let glyphTileRadius: CGFloat = 5
    static let glyphPointSize: CGFloat = 14
    private static let buttonGap: CGFloat = 4
    private static let markGap: CGFloat = 6
    /// `ChromeChip`'s label font, and its 6 pt insets plus the label cell's 2 pt sides.
    private static let chipFont = ChromeFont.sans(size: 11, weight: .medium)
    private static let chipTextInset: CGFloat = 16

    let key: AppKey
    var onIntent: ((PanelIntent) -> Void)?
    private(set) var model: AppRowModel
    private(set) var isHovered = false

    let background: ChromeRowBackgroundView
    let iconTile = PanelFlippedView()
    let iconView = NSImageView()
    let statusMark: ChromeStatusMark
    let nameLabel = PanelText.label()
    let outputChip: ChromeChip
    let outputButton: DeviceMenuButton
    let muteButton: ChromeIconButton
    let slider = MixSlider(kind: .app)
    let readout = PanelText.label()
    let meter = LevelMeterView()
    private var theme: AppTheme
    private var hoverArea: NSTrackingArea?

    init(model: AppRowModel, theme: AppTheme) {
        key = model.key
        self.model = model
        self.theme = theme
        background = ChromeRowBackgroundView(theme: theme)
        statusMark = ChromeStatusMark(shape: .diamond, color: theme.colors.danger)
        outputChip = ChromeChip(text: "", theme: theme, style: .outline)
        outputButton = DeviceMenuButton(form: .compact, accessibilityLabel: "\(model.name) output")
        muteButton = ChromeIconButton(symbolName: "speaker.wave.2", accessibilityLabel: "Mute", target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: MixPanelGeometry.width, height: Self.height))
        for view in [background, statusMark, outputChip, muteButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
        }
        iconTile.layer?.cornerRadius = Self.glyphTileRadius
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        iconTile.addSubview(iconView)
        readout.alignment = .right
        readout.setAccessibilityElement(false)
        nameLabel.setAccessibilityElement(false)
        muteButton.target = self
        muteButton.action = #selector(toggleMute(_:))
        for view in [background, iconTile, statusMark, nameLabel, outputChip, outputButton, muteButton,
                     slider, meter, readout] as [NSView] {
            addSubview(view)
        }
        slider.onChange = { [weak self] value, final in
            guard let self else { return }
            readout.attributedStringValue = PanelText.plain(
                VolumeLaw.text(percent: value), font: ChromeFont.count,
                color: self.theme.colors.textMuted, alignment: .right
            )
            onIntent?(.setAppVolume(key, value, final: final))
        }
        outputButton.onSelect = { [weak self] uid in
            guard let self else { return }
            onIntent?(.setAppOutput(key, uid: uid))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        update(model: model, theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(model: AppRowModel, theme: AppTheme) {
        self.model = model
        self.theme = theme
        let colors = theme.colors
        appearance = theme.appearance.nsAppearance
        setAccessibilityLabel(model.name)

        background.apply(theme: theme)
        background.style = isHovered ? .hover : .none

        if model.icon.isTemplate {
            iconTile.layer?.backgroundColor = colors.glyphTile.cgColor
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.glyphPointSize, weight: .regular)
            iconView.contentTintColor = colors.textMuted
        } else {
            iconTile.layer?.backgroundColor = nil
            iconView.symbolConfiguration = nil
            iconView.contentTintColor = nil
        }
        iconView.image = model.icon

        if case .failed(let reason) = model.status {
            statusMark.isHidden = false
            statusMark.set(status: .error, colors: colors)
            toolTip = reason
            nameLabel.toolTip = reason
        } else {
            statusMark.isHidden = true
            toolTip = nil
            nameLabel.toolTip = nil
        }

        let nameColor = model.isMuted || !model.isPlaying ? colors.textMuted : colors.textPrimary
        nameLabel.attributedStringValue = PanelText.plain(model.name, font: ChromeFont.row, color: nameColor)

        if let outputName = model.outputName {
            outputChip.isHidden = false
            outputChip.text = outputName
        } else {
            outputChip.isHidden = true
        }
        outputChip.apply(theme: theme)

        outputButton.configure(
            title: model.outputName ?? "",
            symbolName: model.outputSymbol,
            items: model.outputMenu,
            theme: theme
        )

        muteButton.setSymbol(
            model.isMuted ? "speaker.slash" : "speaker.wave.2",
            accessibilityLabel: model.isMuted ? "Unmute \(model.name)" : "Mute \(model.name)"
        )
        muteButton.toolTip = model.isMuted ? "Unmute" : "Mute"
        muteButton.isToggledOn = model.isMuted
        muteButton.apply(theme: theme)

        slider.apply(theme: theme)
        slider.isMutedLook = model.isMuted
        slider.setModelValue(model.volume)
        slider.setAccessibilityLabel("\(model.name) volume")
        let readoutText = slider.isTracking ? VolumeLaw.text(percent: slider.value) : model.volumeText
        readout.attributedStringValue = PanelText.plain(
            readoutText, font: ChromeFont.count, color: colors.textMuted, alignment: .right
        )

        meter.apply(theme: theme)
        if !model.isPlaying {
            meter.position = nil
        }
        layoutContents()
    }

    /// The meter position (`MeterScale`, 0…1); not-playing rows never show one.
    func setLevel(_ position: Double?) {
        meter.position = model.isPlaying ? position : nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        let width = bounds.width
        background.frame = bounds

        let side = Self.iconSide
        iconTile.frame = NSRect(x: Self.iconX, y: ((Self.height - side) / 2).rounded(), width: side, height: side)
        if model.icon.isTemplate {
            let glyph = Self.glyphPointSize
            let inset = ((side - glyph) / 2).rounded()
            iconView.frame = NSRect(x: inset, y: inset, width: glyph, height: glyph)
        } else {
            iconView.frame = iconTile.bounds
        }

        // Line 1, trailing to leading.
        let line1MidY = Self.line1Y + Self.line1Height / 2
        let buttonSide = Chrome.iconButtonSize
        let buttonY = (line1MidY - buttonSide / 2).rounded()
        muteButton.frame = NSRect(x: width - Self.trailingInset - buttonSide, y: buttonY, width: buttonSide, height: buttonSide)
        outputButton.frame = NSRect(
            x: muteButton.frame.minX - Self.buttonGap - buttonSide, y: buttonY, width: buttonSide, height: buttonSide
        )
        var nameMaxX = outputButton.frame.minX - Self.buttonGap
        if !outputChip.isHidden, let outputName = model.outputName {
            let maxChipWidth = max(0, (nameMaxX - Self.contentX) / 2)
            // ChromeChip lays its label out at full width and never truncates, so the
            // text is shortened to the room the chip gets; the full name is the tooltip.
            let shown = PanelText.truncated(outputName, font: Self.chipFont, maxWidth: maxChipWidth - Self.chipTextInset)
            if outputChip.text != shown { outputChip.text = shown }
            outputChip.toolTip = shown == outputName ? nil : outputName
            let chipWidth = min(ceil(outputChip.fittingSize.width), maxChipWidth)
            outputChip.frame = NSRect(
                x: nameMaxX - chipWidth,
                y: (line1MidY - Chrome.chipHeight / 2).rounded(),
                width: chipWidth,
                height: Chrome.chipHeight
            )
            nameMaxX = outputChip.frame.minX - Self.markGap
        }

        var nameMinX = Self.contentX
        if !statusMark.isHidden {
            let mark = Chrome.statusMark
            statusMark.frame = NSRect(x: nameMinX, y: (line1MidY - mark / 2).rounded(), width: mark, height: mark)
            nameMinX += mark + Self.markGap
        }
        nameLabel.frame = PanelText.lineFrame(minX: nameMinX - 2, maxX: nameMaxX + 2, centerY: line1MidY, font: ChromeFont.row)

        // Line 2.
        let line2MidY = Self.line2Y + Self.line2Height / 2
        let readoutMinX = width - Self.trailingInset - Self.readoutWidth
        readout.frame = PanelText.lineFrame(minX: readoutMinX, maxX: readoutMinX + Self.readoutWidth + 2, centerY: line2MidY, font: ChromeFont.count)
        slider.frame = NSRect(
            x: Self.contentX,
            y: Self.line2Y,
            width: max(0, readoutMinX - Self.contentX),
            height: Self.line2Height
        )
        let track = slider.convert(slider.trackRect, to: self)
        meter.frame = NSRect(
            x: track.minX,
            y: track.maxY + Self.meterGap,
            width: track.width,
            height: LevelMeterView.height
        )
    }

    @objc private func toggleMute(_ sender: Any?) {
        onIntent?(.toggleAppMute(key))
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            setHovered(false)
        }
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        background.style = hovered ? .hover : .none
    }
}
