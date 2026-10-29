import AppKit
import SopranoMixCore

/// One device section at the top of the panel (output, input, sound effects):
///
/// - header row 24: eyebrow, a "SOFTWARE" outline chip when the volume is Soprano Mix's,
///   the sample rate right-aligned as a plain popup;
/// - device row 28: the full `DeviceMenuButton`;
/// - level row 24 (when there is a volume or a mute): mute button, `MixSlider` (0–100),
///   readout 40 wide;
/// - balance row 20 (output with balance): "Balance" and a 120 wide centre-detent slider
///   between "L" and "R".
final class DeviceSectionView: PanelFlippedView {
    static let headerHeight: CGFloat = 24
    static let deviceRowHeight: CGFloat = 28
    static let levelRowHeight: CGFloat = 24
    static let balanceRowHeight: CGFloat = 20
    static let readoutWidth: CGFloat = 40
    static let balanceSliderWidth: CGFloat = 120
    static let gap: CGFloat = 8

    /// The section's height for `model`.
    static func height(for model: DeviceSectionModel) -> CGFloat {
        var height = headerHeight + deviceRowHeight
        if hasLevelRow(model) {
            height += levelRowHeight
        }
        if model.balance != nil {
            height += balanceRowHeight
        }
        return height
    }

    static func hasLevelRow(_ model: DeviceSectionModel) -> Bool {
        model.volume != nil || model.isMuted != nil
    }

    let role: DeviceRole
    var onIntent: ((PanelIntent) -> Void)?
    private(set) var model: DeviceSectionModel?

    let eyebrow: ChromeEyebrowView
    let softwareChip: ChromeChip
    let sampleRatePopup = SampleRatePopup()
    let deviceButton: DeviceMenuButton
    let muteButton: ChromeIconButton
    let slider = MixSlider(kind: .output)
    let readout = PanelText.label()
    let balanceLabel = PanelText.label()
    let balanceLeftLabel = PanelText.label()
    let balanceRightLabel = PanelText.label()
    let balanceSlider = MixSlider(kind: .balance)
    private var theme: AppTheme

    init(role: DeviceRole, theme: AppTheme) {
        self.role = role
        self.theme = theme
        eyebrow = ChromeEyebrowView(title: "", theme: theme)
        softwareChip = ChromeChip(text: "SOFTWARE", theme: theme, style: .outline)
        deviceButton = DeviceMenuButton(form: .full, accessibilityLabel: "\(Self.roleName(role)) device")
        muteButton = ChromeIconButton(
            symbolName: Self.muteSymbols(role).on,
            accessibilityLabel: "Mute",
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        // Frame-laid chrome keeps a size its own required constraints accept even while
        // hidden (layout only sizes it when visible), so it is measured before switching.
        let chipSize = NSSize(width: ceil(softwareChip.fittingSize.width), height: Chrome.chipHeight)
        for view in [eyebrow, softwareChip, muteButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
        }
        softwareChip.frame.size = chipSize
        muteButton.frame.size = NSSize(width: Chrome.iconButtonSize, height: Chrome.iconButtonSize)
        muteButton.target = self
        muteButton.action = #selector(toggleMute(_:))
        readout.alignment = .right
        for view in [eyebrow, softwareChip, sampleRatePopup, deviceButton, muteButton, slider, readout,
                     balanceLabel, balanceLeftLabel, balanceSlider, balanceRightLabel] as [NSView] {
            addSubview(view)
        }
        readout.setAccessibilityElement(false)
        balanceLabel.setAccessibilityElement(false)
        balanceLeftLabel.setAccessibilityElement(false)
        balanceRightLabel.setAccessibilityElement(false)
        slider.setAccessibilityLabel("\(Self.roleName(role)) volume")
        balanceSlider.setAccessibilityLabel("Balance")

        slider.onChange = { [weak self] value, final in
            guard let self else { return }
            readout.attributedStringValue = PanelText.plain(
                VolumeLaw.text(percent: value), font: ChromeFont.count,
                color: self.theme.colors.textMuted, alignment: .right
            )
            onIntent?(.setDeviceVolume(role, value, final: final))
        }
        balanceSlider.onChange = { [weak self] value, final in
            self?.onIntent?(.setBalance(value, final: final))
        }
        deviceButton.onSelect = { [weak self] uid in
            guard let self, let uid else { return }
            onIntent?(.setDefaultDevice(role, uid: uid))
        }
        sampleRatePopup.onSelect = { [weak self] rate in
            guard let self else { return }
            onIntent?(.setSampleRate(role, rate))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(model: DeviceSectionModel, theme: AppTheme) {
        self.model = model
        self.theme = theme
        let colors = theme.colors
        appearance = theme.appearance.nsAppearance
        setAccessibilityLabel(model.title)

        eyebrow.title = model.title
        eyebrow.apply(theme: theme)
        softwareChip.apply(theme: theme)
        softwareChip.isHidden = !model.isSoftwareVolume

        if let sampleRate = model.sampleRate {
            sampleRatePopup.isHidden = false
            sampleRatePopup.configure(sampleRate, theme: theme)
        } else {
            sampleRatePopup.isHidden = true
        }

        deviceButton.configure(
            title: model.deviceName,
            symbolName: model.deviceSymbol,
            items: model.menu,
            theme: theme
        )

        let symbols = Self.muteSymbols(role)
        if let isMuted = model.isMuted {
            muteButton.isHidden = false
            muteButton.setSymbol(
                isMuted ? symbols.off : symbols.on,
                accessibilityLabel: isMuted ? "Unmute \(model.title.lowercased())" : "Mute \(model.title.lowercased())"
            )
            muteButton.toolTip = isMuted ? "Unmute" : "Mute"
            muteButton.isToggledOn = isMuted
            muteButton.apply(theme: theme)
        } else {
            muteButton.isHidden = true
        }

        if let volume = model.volume {
            slider.isHidden = false
            readout.isHidden = false
            slider.apply(theme: theme)
            slider.isMutedLook = model.isMuted == true
            slider.setModelValue(volume)
            let text = slider.isTracking ? VolumeLaw.text(percent: slider.value) : model.volumeText
            readout.attributedStringValue = PanelText.plain(
                text, font: ChromeFont.count, color: colors.textMuted, alignment: .right
            )
        } else {
            slider.isHidden = true
            readout.isHidden = true
        }

        let hasBalance = model.balance != nil
        for view in [balanceLabel, balanceLeftLabel, balanceRightLabel, balanceSlider] as [NSView] {
            view.isHidden = !hasBalance
        }
        if let balance = model.balance {
            balanceSlider.apply(theme: theme)
            balanceSlider.setModelValue(balance)
            balanceLabel.attributedStringValue = PanelText.plain("Balance", font: ChromeFont.meta, color: colors.textMuted)
            balanceLeftLabel.attributedStringValue = PanelText.plain("L", font: ChromeFont.meta, color: colors.textMuted)
            balanceRightLabel.attributedStringValue = PanelText.plain("R", font: ChromeFont.meta, color: colors.textMuted)
        }
        layoutContents()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        guard let model else { return }
        let width = bounds.width
        var y: CGFloat = 0

        // Header row.
        let headerMidY = y + Self.headerHeight / 2
        let eyebrowText = ChromeText.eyebrow(model.title, color: theme.colors.textMuted)
        let lineHeight = PanelText.lineHeight(ChromeFont.eyebrow) + 1
        var popupWidth: CGFloat = 0
        if !sampleRatePopup.isHidden {
            popupWidth = sampleRatePopup.preferredWidth
            sampleRatePopup.frame = NSRect(
                x: width - popupWidth,
                y: (headerMidY - Chrome.controlHeight / 2).rounded(),
                width: popupWidth,
                height: Chrome.controlHeight
            )
        }
        let eyebrowWidth = min(PanelText.width(of: eyebrowText), max(0, width - popupWidth - Self.gap))
        eyebrow.frame = NSRect(x: -2, y: (headerMidY - lineHeight / 2).rounded(), width: eyebrowWidth, height: lineHeight)
        if !softwareChip.isHidden {
            let chipWidth = ceil(softwareChip.fittingSize.width)
            softwareChip.frame = NSRect(
                x: eyebrow.frame.maxX + 4,
                y: (headerMidY - Chrome.chipHeight / 2).rounded(),
                width: chipWidth,
                height: Chrome.chipHeight
            )
        }
        y += Self.headerHeight

        // Device row.
        deviceButton.frame = NSRect(x: 0, y: y, width: width, height: Self.deviceRowHeight)
        y += Self.deviceRowHeight

        // Level row.
        if Self.hasLevelRow(model) {
            let midY = y + Self.levelRowHeight / 2
            let side = Chrome.iconButtonSize
            muteButton.frame = NSRect(x: 0, y: (midY - side / 2).rounded(), width: side, height: side)
            let sliderMinX = side + Self.gap
            readout.frame = PanelText.lineFrame(
                minX: width - Self.readoutWidth, maxX: width + 2, centerY: midY, font: ChromeFont.count
            )
            slider.frame = NSRect(
                x: sliderMinX,
                y: (midY - MixSlider.hitHeight / 2).rounded(),
                width: max(0, width - Self.readoutWidth - Self.gap - sliderMinX),
                height: MixSlider.hitHeight
            )
            y += Self.levelRowHeight
        }

        // Balance row.
        if model.balance != nil {
            let midY = y + Self.balanceRowHeight / 2
            let labelMinX = Chrome.iconButtonSize + Self.gap
            let labelWidth = PanelText.width(of: balanceLabel.attributedStringValue)
            balanceLabel.frame = PanelText.lineFrame(
                minX: labelMinX - 2, maxX: labelMinX - 2 + labelWidth, centerY: midY, font: ChromeFont.meta
            )
            let leftWidth = PanelText.width(of: balanceLeftLabel.attributedStringValue)
            let leftMinX = balanceLabel.frame.maxX + Self.gap
            balanceLeftLabel.frame = PanelText.lineFrame(
                minX: leftMinX, maxX: leftMinX + leftWidth, centerY: midY, font: ChromeFont.meta
            )
            balanceSlider.frame = NSRect(
                x: balanceLeftLabel.frame.maxX,
                y: (midY - MixSlider.hitHeight / 2).rounded(),
                width: Self.balanceSliderWidth,
                height: MixSlider.hitHeight
            )
            let rightWidth = PanelText.width(of: balanceRightLabel.attributedStringValue)
            balanceRightLabel.frame = PanelText.lineFrame(
                minX: balanceSlider.frame.maxX, maxX: balanceSlider.frame.maxX + rightWidth,
                centerY: midY, font: ChromeFont.meta
            )
        }
    }

    @objc private func toggleMute(_ sender: Any?) {
        onIntent?(.toggleDeviceMute(role))
    }

    static func roleName(_ role: DeviceRole) -> String {
        switch role {
        case .output: "Output"
        case .input: "Input"
        case .soundEffects: "Sound effects"
        }
    }

    /// The mute button's symbol while sounding (`on`) and while muted (`off`).
    static func muteSymbols(_ role: DeviceRole) -> (on: String, off: String) {
        switch role {
        case .output: (on: "speaker.wave.2", off: "speaker.slash")
        case .input: (on: "mic", off: "mic.slash")
        case .soundEffects: (on: "bell", off: "bell.slash")
        }
    }
}

/// The sample-rate popup in a section header: plain text (`ChromeFont.count`, muted,
/// "48 kHz") with a chevron; a click opens a menu of the device's rates, the current one
/// checked.
final class SampleRatePopup: PanelFlippedView {
    private static let chevronSide: CGFloat = 10
    private static let chevronGap: CGFloat = 3

    /// The chosen rate in Hz; never called for the current rate.
    var onSelect: ((Double) -> Void)?
    private(set) var menuModel: SampleRateMenu?
    private let label = PanelText.label()
    private let chevron = NSImageView()
    private var theme: AppTheme = .folioPaper

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.setAccessibilityElement(false)
        chevron.setAccessibilityElement(false)
        chevron.imageScaling = .scaleProportionallyDown
        chevron.image = DeviceMenuButton.symbol("chevron.up.chevron.down", pointSize: DeviceMenuButton.chevronPointSize)
        addSubview(label)
        addSubview(chevron)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Sample rate")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The width the title and chevron need.
    var preferredWidth: CGFloat {
        PanelText.width(of: label.attributedStringValue) - 2 + Self.chevronGap + Self.chevronSide
    }

    func configure(_ menu: SampleRateMenu, theme: AppTheme) {
        menuModel = menu
        self.theme = theme
        let colors = theme.colors
        label.attributedStringValue = PanelText.plain(menu.title, font: ChromeFont.count, color: colors.textMuted)
        chevron.contentTintColor = colors.textMuted
        setAccessibilityValue(menu.title)
        layoutContents()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        let midY = bounds.height / 2
        chevron.frame = NSRect(
            x: bounds.width - Self.chevronSide,
            y: (midY - Self.chevronSide / 2).rounded(),
            width: Self.chevronSide,
            height: Self.chevronSide
        )
        label.frame = PanelText.lineFrame(
            minX: -2, maxX: chevron.frame.minX - Self.chevronGap + 2, centerY: midY, font: ChromeFont.count
        )
    }

    /// The menu as it opens now.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Sample rate")
        menu.autoenablesItems = false
        menu.appearance = theme.appearance.nsAppearance
        guard let menuModel else { return menu }
        for rate in menuModel.rates {
            let item = NSMenuItem(
                title: MixerModelBuilder.sampleRateTitle(rate),
                action: #selector(chooseItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: rate)
            item.state = rate == menuModel.selected ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// Chooses `rate` as a menu click would: only while it is still one of the current
    /// rates and not the selected one (the rates can change while the menu is open).
    func select(rate: Double) {
        guard let menuModel, menuModel.rates.contains(rate), rate != menuModel.selected else { return }
        onSelect?(rate)
    }

    @objc private func chooseItem(_ sender: NSMenuItem) {
        guard let rate = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        select(rate: rate)
    }

    private func openMenu() {
        guard let menuModel, !menuModel.rates.isEmpty else { return }
        _ = makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        openMenu()
    }

    override func accessibilityPerformPress() -> Bool {
        openMenu()
        return true
    }
}
