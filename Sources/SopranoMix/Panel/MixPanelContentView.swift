import AppKit
import SopranoMixCore

/// The panel's root view (top-left origin): padding 12 top and bottom, 16 at the sides;
/// the device sections 8 apart, a `borderSubtle` rule with 12 above and below, the
/// capture banner, the apps header, the scrolling app list (or the empty state), the
/// footer. `raised`, 1 pt `borderSubtle`, radius 10.
final class MixPanelContentView: PanelFlippedView {
    static let topPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 12
    static let sidePadding: CGFloat = 16
    static let sectionGap: CGFloat = 8
    static let ruleMargin: CGFloat = 12
    static let bannerGap: CGFloat = 8
    static let appsHeaderHeight: CGFloat = 28
    static let footerHeight: CGFloat = 28
    static let emptyHeight: CGFloat = 80

    var onIntent: ((PanelIntent) -> Void)?

    /// The device sections in model order; reused by role.
    private(set) var sectionViews: [DeviceSectionView] = []
    let rule = ChromeRuleView(axis: .horizontal)
    let banner = CaptureBannerView()
    let appsHeader = AppsHeaderView()
    let scrollView = NSScrollView()
    let appList = AppListView()
    let footer = PanelFooterView()
    private var theme: AppTheme = .folioPaper
    private var model: MixPanelModel?
    private var bannerHeight: CGFloat = 0

    /// The app rows in model order.
    var appRows: [AppRowView] { appList.rows }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MixPanelGeometry.width, height: 200))
        rule.translatesAutoresizingMaskIntoConstraints = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = appList
        for view in [rule, banner, appsHeader, scrollView, footer] as [NSView] {
            addSubview(view)
        }
        appList.onIntent = { [weak self] intent in self?.onIntent?(intent) }
        banner.onAction = { [weak self] in self?.onIntent?(.requestCapture) }
        footer.onOpenSettings = { [weak self] in self?.onIntent?(.openSettings) }
        footer.onShowMenu = { [weak self] anchor in self?.onIntent?(.showAppMenu(anchor: anchor)) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Soprano Mix")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Configures every part for `model` and returns the heights the window sizes from.
    func apply(_ model: MixPanelModel, theme: AppTheme) -> MixPanelGeometry.ContentMetrics {
        self.model = model
        self.theme = theme
        let colors = theme.colors
        let innerWidth = MixPanelGeometry.width - Self.sidePadding * 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        appearance = theme.appearance.nsAppearance
        layer?.backgroundColor = colors.raised.cgColor
        layer?.borderColor = colors.borderSubtle.cgColor
        layer?.borderWidth = Chrome.hairline
        layer?.cornerRadius = Chrome.Radius.popover
        layer?.masksToBounds = true

        applySections(model.sections, theme: theme)
        rule.color = colors.borderSubtle

        if case .capture(let text, let button) = model.banner {
            banner.isHidden = false
            bannerHeight = banner.configure(text: text, buttonTitle: button, theme: theme, width: innerWidth)
        } else {
            banner.isHidden = true
            bannerHeight = 0
        }

        appsHeader.configure(count: model.apps.count, theme: theme)
        appList.update(apps: model.apps, emptyText: model.emptyText, theme: theme)
        footer.configure(warning: model.footerWarning, theme: theme)
        CATransaction.commit()

        var fixed = Self.topPadding
        fixed += model.sections.map(DeviceSectionView.height(for:)).reduce(0, +)
        fixed += Self.sectionGap * CGFloat(max(0, model.sections.count - 1))
        fixed += Self.ruleMargin * 2 + Chrome.hairline
        if bannerHeight > 0 {
            fixed += bannerHeight + Self.bannerGap
        }
        fixed += Self.appsHeaderHeight + Self.footerHeight + Self.bottomPadding
        return MixPanelGeometry.ContentMetrics(fixedHeight: fixed, listHeight: appList.contentHeight)
    }

    private func applySections(_ sections: [DeviceSectionModel], theme: AppTheme) {
        var reused: [DeviceSectionView] = []
        for section in sections {
            let view = sectionViews.first { $0.role == section.role && !reused.contains($0) }
                ?? makeSection(role: section.role, theme: theme)
            view.update(model: section, theme: theme)
            reused.append(view)
        }
        for view in sectionViews where !reused.contains(view) {
            view.removeFromSuperview()
        }
        sectionViews = reused
    }

    private func makeSection(role: DeviceRole, theme: AppTheme) -> DeviceSectionView {
        let view = DeviceSectionView(role: role, theme: theme)
        view.onIntent = { [weak self] intent in self?.onIntent?(intent) }
        addSubview(view)
        return view
    }

    /// Places every part for a panel of `size`; the app list gets what remains between
    /// the apps header and the footer.
    func layoutPanel(size: NSSize) {
        guard let model else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameSize(size)
        let x = Self.sidePadding
        let innerWidth = size.width - Self.sidePadding * 2
        var y = Self.topPadding
        for (view, section) in zip(sectionViews, model.sections) {
            view.frame = NSRect(x: x, y: y, width: innerWidth, height: DeviceSectionView.height(for: section))
            y = view.frame.maxY + Self.sectionGap
        }
        if !sectionViews.isEmpty {
            y -= Self.sectionGap
        }
        y += Self.ruleMargin
        rule.frame = NSRect(x: x, y: y, width: innerWidth, height: Chrome.hairline)
        y += Chrome.hairline + Self.ruleMargin
        if !banner.isHidden {
            banner.frame = NSRect(x: x, y: y, width: innerWidth, height: bannerHeight)
            y += bannerHeight + Self.bannerGap
        }
        appsHeader.frame = NSRect(x: x, y: y, width: innerWidth, height: Self.appsHeaderHeight)
        y += Self.appsHeaderHeight
        let footerY = size.height - Self.bottomPadding - Self.footerHeight
        footer.frame = NSRect(x: x, y: footerY, width: innerWidth, height: Self.footerHeight)
        let viewport = max(0, footerY - y)
        scrollView.frame = NSRect(x: 0, y: y, width: size.width, height: viewport)
        appList.setFrameSize(NSSize(width: size.width, height: max(appList.contentHeight, viewport)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        CATransaction.commit()
    }

    /// Scrolls the app list back to its first row.
    func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func setLevels(_ levels: [AppKey: Double]) {
        appList.setLevels(levels)
    }
}

// MARK: - App list

/// The scroll view's document: the app rows, reused by `AppKey`, or the empty state.
final class AppListView: PanelFlippedView {
    var onIntent: ((PanelIntent) -> Void)?
    /// The rows in model order.
    private(set) var rows: [AppRowView] = []
    let emptyLabel = PanelText.label()
    private(set) var contentHeight: CGFloat = MixPanelContentView.emptyHeight
    private var levels: [AppKey: Double] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(apps: [AppRowModel], emptyText: String?, theme: AppTheme) {
        var byKey: [AppKey: AppRowView] = [:]
        for row in rows {
            byKey[row.key] = row
        }
        var ordered: [AppRowView] = []
        for app in apps {
            if let row = byKey.removeValue(forKey: app.key) {
                row.update(model: app, theme: theme)
                ordered.append(row)
            } else {
                let row = AppRowView(model: app, theme: theme)
                row.onIntent = { [weak self] intent in self?.onIntent?(intent) }
                addSubview(row)
                ordered.append(row)
            }
        }
        for row in byKey.values {
            row.removeFromSuperview()
        }
        rows = ordered
        let width = MixPanelGeometry.width
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * AppRowView.height, width: width, height: AppRowView.height)
            row.setLevel(levels[row.key])
        }

        if rows.isEmpty {
            contentHeight = MixPanelContentView.emptyHeight
            emptyLabel.isHidden = false
            let font = ChromeFont.empty
            emptyLabel.attributedStringValue = PanelText.plain(
                emptyText ?? "", font: font, color: theme.colors.textMuted, alignment: .center
            )
            emptyLabel.frame = PanelText.lineFrame(
                minX: MixPanelContentView.sidePadding,
                maxX: width - MixPanelContentView.sidePadding,
                centerY: MixPanelContentView.emptyHeight / 2,
                font: font
            )
        } else {
            contentHeight = CGFloat(rows.count) * AppRowView.height
            emptyLabel.isHidden = true
        }
    }

    func setLevels(_ levels: [AppKey: Double]) {
        self.levels = levels
        for row in rows {
            row.setLevel(levels[row.key])
        }
    }
}

// MARK: - Apps header

/// Eyebrow "APPS" and " · N" (`ChromeFont.count`, muted), 28 high.
final class AppsHeaderView: PanelFlippedView {
    let eyebrow: ChromeEyebrowView
    let countLabel = PanelText.label()

    override init(frame: NSRect) {
        eyebrow = ChromeEyebrowView(title: "Apps", theme: .folioPaper)
        super.init(frame: frame)
        eyebrow.translatesAutoresizingMaskIntoConstraints = true
        countLabel.setAccessibilityElement(false)
        addSubview(eyebrow)
        addSubview(countLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(count: Int, theme: AppTheme) {
        let colors = theme.colors
        eyebrow.apply(theme: theme)
        countLabel.attributedStringValue = PanelText.plain(" · \(count)", font: ChromeFont.count, color: colors.textMuted)
        eyebrow.setAccessibilityLabel("Apps, \(count)")
        layoutContents()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        let midY = bounds.height / 2
        let eyebrowWidth = PanelText.width(of: ChromeText.eyebrow(eyebrow.title, color: .labelColor))
        let lineHeight = PanelText.lineHeight(ChromeFont.eyebrow) + 1
        eyebrow.frame = NSRect(x: -2, y: (midY - lineHeight / 2).rounded(), width: eyebrowWidth, height: lineHeight)
        let countWidth = PanelText.width(of: countLabel.attributedStringValue)
        countLabel.frame = PanelText.lineFrame(
            minX: eyebrow.frame.maxX - 4,
            maxX: min(bounds.width, eyebrow.frame.maxX - 4 + countWidth),
            centerY: midY,
            font: ChromeFont.count
        )
    }
}

// MARK: - Capture banner

/// System Audio Recording is missing: a NEEDS INPUT dot, the text (`ChromeFont.label`,
/// ink, wrapping) and an ink button, on `needsInputWash`, radius 6.
final class CaptureBannerView: PanelFlippedView {
    static let verticalPadding: CGFloat = 8
    static let horizontalPadding: CGFloat = 10
    static let gap: CGFloat = 8

    var onAction: (() -> Void)?
    let mark = ChromeStatusMark(shape: .dot)
    let textLabel = NSTextField(wrappingLabelWithString: "")
    let button: ChromeButton

    override init(frame: NSRect) {
        button = ChromeButton(title: "", theme: .folioPaper, kind: .ink)
        super.init(frame: frame)
        mark.translatesAutoresizingMaskIntoConstraints = true
        button.translatesAutoresizingMaskIntoConstraints = true
        textLabel.translatesAutoresizingMaskIntoConstraints = true
        textLabel.isSelectable = false
        button.target = self
        button.action = #selector(pressed(_:))
        layer?.cornerRadius = Chrome.Radius.control
        addSubview(mark)
        addSubview(textLabel)
        addSubview(button)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Lays the banner out for `width` and returns its height.
    func configure(text: String, buttonTitle: String, theme: AppTheme, width: CGFloat) -> CGFloat {
        let colors = theme.colors
        layer?.backgroundColor = colors.needsInputWash.cgColor
        layer?.cornerRadius = Chrome.Radius.control
        mark.set(status: .needsInput, colors: colors)
        button.title = buttonTitle
        button.apply(theme: theme)
        textLabel.attributedStringValue = ChromeText.attributed(
            text, font: ChromeFont.label, color: colors.textPrimary, lineBreakMode: .byWordWrapping
        )
        setAccessibilityLabel(text)

        let buttonWidth = ceil(button.intrinsicContentSize.width)
        let markSide = Chrome.statusMark
        let textMinX = Self.horizontalPadding + markSide + Self.gap
        let buttonMinX = width - Self.horizontalPadding - buttonWidth
        let textWidth = max(0, buttonMinX - Self.gap - textMinX)
        let textHeight = ceil(
            textLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth + 4, height: 1000)).height
                ?? PanelText.lineHeight(ChromeFont.label)
        )
        let height = max(Chrome.controlHeight, textHeight) + Self.verticalPadding * 2
        let midY = height / 2
        setFrameSize(NSSize(width: width, height: height))
        mark.frame = NSRect(x: Self.horizontalPadding, y: (midY - markSide / 2).rounded(), width: markSide, height: markSide)
        textLabel.frame = NSRect(x: textMinX - 2, y: (midY - textHeight / 2).rounded(), width: textWidth + 4, height: textHeight)
        button.frame = NSRect(
            x: buttonMinX,
            y: (midY - Chrome.controlHeight / 2).rounded(),
            width: buttonWidth,
            height: Chrome.controlHeight
        )
        return height
    }

    @objc private func pressed(_ sender: Any?) {
        onAction?()
    }
}

// MARK: - Footer

/// 28 high: "settings.json · N warnings" (meta, `yellow`, opens settings.json) on the
/// left while issues exist; the gear (app menu) on the right.
final class PanelFooterView: PanelFlippedView {
    var onOpenSettings: (() -> Void)?
    /// The gear's rect in screen coordinates.
    var onShowMenu: ((NSRect) -> Void)?
    let warningButton = NSButton(title: "", target: nil, action: nil)
    let gearButton: ChromeIconButton

    override init(frame: NSRect) {
        gearButton = ChromeIconButton(symbolName: "gearshape", accessibilityLabel: "Soprano Mix menu", target: nil, action: nil)
        super.init(frame: frame)
        gearButton.translatesAutoresizingMaskIntoConstraints = true
        gearButton.target = self
        gearButton.action = #selector(showMenu(_:))
        warningButton.translatesAutoresizingMaskIntoConstraints = true
        warningButton.isBordered = false
        warningButton.setButtonType(.momentaryChange)
        warningButton.focusRingType = .none
        warningButton.target = self
        warningButton.action = #selector(openSettings(_:))
        addSubview(warningButton)
        addSubview(gearButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(warning: String?, theme: AppTheme) {
        gearButton.apply(theme: theme)
        if let warning {
            warningButton.isHidden = false
            let title = PanelText.plain(warning, font: ChromeFont.meta, color: theme.colors.yellow)
            warningButton.attributedTitle = title
            warningButton.attributedAlternateTitle = title
            warningButton.setAccessibilityLabel(warning)
            warningButton.toolTip = "Open settings.json"
        } else {
            warningButton.isHidden = true
        }
        layoutContents()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        let midY = bounds.height / 2
        let side = Chrome.iconButtonSize
        gearButton.frame = NSRect(x: bounds.width - side, y: (midY - side / 2).rounded(), width: side, height: side)
        let width = min(
            ceil(warningButton.attributedTitle.size().width) + 4,
            max(0, gearButton.frame.minX - 8)
        )
        let height = PanelText.lineHeight(ChromeFont.meta) + 4
        warningButton.frame = NSRect(x: 0, y: (midY - height / 2).rounded(), width: width, height: height)
    }

    @objc private func openSettings(_ sender: Any?) {
        onOpenSettings?()
    }

    @objc private func showMenu(_ sender: Any?) {
        let local = gearButton.convert(gearButton.bounds, to: nil)
        let anchor = gearButton.window?.convertToScreen(local) ?? local
        onShowMenu?(anchor)
    }
}

// MARK: - Shared helpers

/// A layer-backed view with a top-left origin; every panel and HUD view lays out in it.
class PanelFlippedView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
}

/// Text helpers for frame-laid-out labels.
@MainActor
enum PanelText {
    /// A single-line, non-editable label laid out by frame.
    static func label() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = true
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.wraps = false
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    static func plain(
        _ text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .natural,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) -> NSAttributedString {
        ChromeText.attributed(text, font: font, color: color, alignment: alignment, lineBreakMode: lineBreakMode)
    }

    /// The width a label needs to show `text` untruncated, including the text cell's
    /// 2 pt padding on each side.
    static func width(of text: NSAttributedString) -> CGFloat {
        text.length == 0 ? 0 : ceil(text.size().width) + 4
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// A one-line label frame spanning `minX…maxX`, vertically centred on `centerY`.
    static func lineFrame(minX: CGFloat, maxX: CGFloat, centerY: CGFloat, font: NSFont) -> CGRect {
        let height = lineHeight(font) + 1
        return CGRect(x: minX, y: (centerY - height / 2).rounded(), width: max(0, maxX - minX), height: height)
    }
}

/// Offscreen rendering of a floating surface with its elevation shadow and contact ring.
@MainActor
enum PanelRendering {
    /// `view` on a `background` canvas padded for `shadow`, at `scale`.
    static func snapshot(
        of view: NSView,
        scale: CGFloat,
        shadow: ThemeShadow,
        radius: CGFloat,
        background: NSColor
    ) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = max(1, scale)
        let padding = ceil(shadow.blur + shadow.offsetY)
        let canvas = CGSize(width: size.width + padding * 2, height: size.height + padding * 2)
        let pixelWidth = Int((canvas.width * scale).rounded())
        let pixelHeight = Int((canvas.height * scale).rounded())
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(background.cgColor)
        context.fill(CGRect(origin: .zero, size: canvas))
        render(view, in: context, at: CGPoint(x: padding, y: padding), shadow: shadow, radius: radius)
        return context.makeImage()
    }

    /// Renders `view`'s layer tree into `context` with its bottom-left corner at `origin`
    /// (`context` uses a bottom-left origin), casting `shadow` and stroking its contact
    /// ring. Works for a window that was never on screen: `cacheDisplay` makes AppKit
    /// build and draw every view's layer, then Core Animation renders the tree.
    static func render(_ view: NSView, in context: CGContext, at origin: CGPoint, shadow: ThemeShadow, radius: CGFloat) {
        let bounds = view.bounds
        if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: rep)
        }
        guard let layer = view.layer else { return }
        let rect = CGRect(origin: origin, size: bounds.size)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -shadow.offsetY),
            blur: shadow.blur,
            color: shadow.color.withAlphaComponent(CGFloat(shadow.opacity)).cgColor
        )
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.translateBy(x: origin.x, y: origin.y)
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        context.endTransparencyLayer()
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(shadow.ring.cgColor)
        context.setLineWidth(1)
        context.addPath(CGPath(
            roundedRect: rect.insetBy(dx: -0.5, dy: -0.5),
            cornerWidth: radius + 0.5,
            cornerHeight: radius + 0.5,
            transform: nil
        ))
        context.strokePath()
        context.restoreGState()
    }
}
