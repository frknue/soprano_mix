import AppKit
import SopranoMixCore

/// Opens an `NSMenu` of devices (SF Symbol per item, the selected one checked) and
/// reports the chosen item's `uid` (nil: follow the system output).
///
/// - `full`: the device row of a device section: full width, `raised` (hover fill on
///   hover), `borderStrong` edge, radius 6; transport symbol (12 pt, muted), device name
///   (`ChromeFont.row`, ink) and a chevron.
/// - `compact`: a 24 × 24 `ChromeIconButton` showing the target's transport symbol.
final class DeviceMenuButton: PanelFlippedView {
    enum Form {
        case full
        case compact
    }

    static let fullHeight: CGFloat = Chrome.controlHeightLarge
    static let compactSide: CGFloat = Chrome.iconButtonSize
    static let symbolPointSize: CGFloat = 12
    static let chevronPointSize: CGFloat = 9
    private static let symbolBox: CGFloat = 16
    private static let horizontalPadding: CGFloat = 8
    private static let gap: CGFloat = 6

    let form: Form
    /// The chosen item's `uid`; never called for the item that is already selected.
    var onSelect: ((String?) -> Void)?
    private(set) var items: [DeviceMenuItem] = []
    private(set) var title = ""
    private(set) var symbolName = DeviceTransport.unknown.symbolName

    private var theme: AppTheme = .folioPaper
    private var menuLabel: String
    private let iconButton: ChromeIconButton?
    private let symbolView = NSImageView()
    private let titleLabel = PanelText.label()
    private let chevronView = NSImageView()
    private var isHovered = false
    private var hoverArea: NSTrackingArea?

    /// `accessibilityLabel` names the menu ("Output device", "Spotify output").
    init(form: Form, accessibilityLabel: String) {
        self.form = form
        menuLabel = accessibilityLabel
        switch form {
        case .full:
            iconButton = nil
        case .compact:
            iconButton = ChromeIconButton(
                symbolName: DeviceTransport.unknown.symbolName,
                accessibilityLabel: accessibilityLabel,
                target: nil,
                action: nil
            )
        }
        super.init(frame: .zero)
        switch form {
        case .full:
            for view in [symbolView, chevronView] {
                view.imageScaling = .scaleProportionallyDown
                view.setAccessibilityElement(false)
                addSubview(view)
            }
            titleLabel.setAccessibilityElement(false)
            addSubview(titleLabel)
            chevronView.image = Self.symbol("chevron.up.chevron.down", pointSize: Self.chevronPointSize)
            setAccessibilityElement(true)
            setAccessibilityRole(.popUpButton)
            setAccessibilityLabel(accessibilityLabel)
        case .compact:
            if let iconButton {
                iconButton.translatesAutoresizingMaskIntoConstraints = true
                iconButton.target = self
                iconButton.action = #selector(openMenu(_:))
                addSubview(iconButton)
            }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, symbolName: String, items: [DeviceMenuItem], theme: AppTheme) {
        self.title = title
        self.symbolName = symbolName
        self.items = items
        self.theme = theme
        if let iconButton {
            iconButton.setSymbol(symbolName, accessibilityLabel: menuLabel)
            iconButton.toolTip = title.isEmpty ? menuLabel : "\(menuLabel): \(title)"
            iconButton.apply(theme: theme)
        } else {
            symbolView.image = Self.symbol(symbolName, pointSize: Self.symbolPointSize)
            setAccessibilityValue(title)
        }
        refresh()
        layoutContents()
    }

    /// The menu as it opens now.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: menuLabel)
        menu.autoenablesItems = false
        menu.appearance = theme.appearance.nsAppearance
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: item.title, action: #selector(chooseItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menuItem.image = Self.symbol(item.symbolName, pointSize: Self.symbolPointSize)
            menuItem.state = item.isSelected ? .on : .off
            menu.addItem(menuItem)
        }
        if form == .full {
            menu.minimumWidth = bounds.width
        }
        return menu
    }

    /// Chooses the item at `index` as a menu click would.
    func select(itemAt index: Int) {
        guard items.indices.contains(index), !items[index].isSelected else { return }
        onSelect?(items[index].uid)
    }

    @objc private func chooseItem(_ sender: NSMenuItem) {
        select(itemAt: sender.tag)
    }

    @objc func openMenu(_ sender: Any?) {
        guard !items.isEmpty else { return }
        let menu = makeMenu()
        let below = NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : bounds.minY - 4)
        isHovered = false
        _ = menu.popUp(positioning: nil, at: below, in: self)
        refresh()
    }

    // MARK: - Layout and drawing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        switch form {
        case .compact:
            iconButton?.frame = NSRect(
                x: ((bounds.width - Self.compactSide) / 2).rounded(),
                y: ((bounds.height - Self.compactSide) / 2).rounded(),
                width: Self.compactSide,
                height: Self.compactSide
            )
        case .full:
            let box = Self.symbolBox
            let midY = bounds.height / 2
            symbolView.frame = NSRect(x: Self.horizontalPadding, y: (midY - box / 2).rounded(), width: box, height: box)
            let chevronSide: CGFloat = 12
            chevronView.frame = NSRect(
                x: bounds.width - Self.horizontalPadding - chevronSide,
                y: (midY - chevronSide / 2).rounded(),
                width: chevronSide,
                height: chevronSide
            )
            titleLabel.frame = PanelText.lineFrame(
                minX: symbolView.frame.maxX + Self.gap - 2,
                maxX: chevronView.frame.minX - Self.gap + 2,
                centerY: midY,
                font: ChromeFont.row
            )
        }
    }

    private func refresh() {
        guard form == .full else { return }
        let colors = theme.colors
        appearance = theme.appearance.nsAppearance
        symbolView.contentTintColor = colors.textMuted
        chevronView.contentTintColor = colors.textMuted
        titleLabel.attributedStringValue = PanelText.plain(title, font: ChromeFont.row, color: colors.textPrimary)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard form == .full else { return }
        let colors = theme.colors
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.control,
            yRadius: Chrome.Radius.control
        )
        (isHovered ? colors.hover : colors.raised).setFill()
        shape.fill()
        shape.lineWidth = Chrome.hairline
        colors.borderStrong.setStroke()
        shape.stroke()
    }

    // MARK: - Events (full form)

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard form == .full else { return super.hitTest(point) }
        guard !isHidden else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard form == .full else {
            super.mouseDown(with: event)
            return
        }
        openMenu(nil)
    }

    override func accessibilityPerformPress() -> Bool {
        openMenu(nil)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard form == .full else { return }
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
        guard form == .full else { return }
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard form == .full else { return }
        isHovered = false
        needsDisplay = true
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    static func symbol(_ name: String, pointSize: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }
}
