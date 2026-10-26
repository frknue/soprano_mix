import AppKit
import SopranoMixCore

/// The volume HUD for outputs Soprano Mix controls in software: a borderless 240 × 56
/// panel at the top right of the main screen (8 pt below the menu bar, 8 pt from the
/// right edge): `raised`, 1 pt `borderSubtle`, radius 10, e2 shadow; the speaker symbol,
/// the device name and caption, and a 4 pt track showing the level. It stays 1.2 s after
/// the last `show`, then fades out over 200 ms (at once under Reduce Motion). It ignores
/// the mouse.
@MainActor
final class VolumeHUD: VolumeHUDPresenting {
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// Keeps the HUD off screen while still laying it out (snapshot harness, tests); a
    /// `.prohibited` process is treated the same way.
    static var offscreen = false
    static let size = NSSize(width: 240, height: 56)
    static let visibleDuration: TimeInterval = 1.2
    static let fadeDuration: TimeInterval = 0.2
    static let screenInset: CGFloat = 8

    private(set) var current: VolumeHUDModel?
    let view = VolumeHUDView()
    private let panel: NSPanel
    private let schedule: Scheduler
    private var lastShown: (model: VolumeHUDModel, theme: AppTheme)?
    /// Bumped on every show so a stale timer or fade completion does nothing.
    private var generation = 0

    convenience init() {
        self.init(schedule: { delay, work in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                work()
            }
        })
    }

    /// `schedule` runs `work` once after the delay (tests inject their own clock).
    init(schedule: @escaping Scheduler) {
        _ = NSApplication.shared
        self.schedule = schedule
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.contentView = view
    }

    private var isOffscreen: Bool {
        Self.offscreen || NSApplication.shared.activationPolicy() == .prohibited
    }

    func show(_ model: VolumeHUDModel, theme: AppTheme) {
        generation += 1
        let shown = generation
        current = model
        lastShown = (model: model, theme: theme)
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? MixPanelGeometry.fallbackVisibleFrame
        let frame = Self.frame(in: visibleFrame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.appearance = theme.appearance.nsAppearance
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.configure(model, theme: theme)
        CATransaction.commit()
        if !isOffscreen {
            // A zero-length group also cancels a fade-out still running.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            panel.orderFrontRegardless()
            panel.invalidateShadow()
        }
        schedule(Self.visibleDuration) { [weak self] in
            self?.hide(shown)
        }
    }

    func renderSnapshot(scale: CGFloat) -> CGImage? {
        guard let lastShown else { return nil }
        if view.bounds.size != Self.size {
            view.frame = NSRect(origin: .zero, size: Self.size)
            view.configure(lastShown.model, theme: lastShown.theme)
        }
        return PanelRendering.snapshot(
            of: view,
            scale: scale,
            shadow: lastShown.theme.colors.shadowE2,
            radius: Chrome.Radius.popover,
            background: lastShown.theme.colors.bgBase
        )
    }

    /// Top right of `visibleFrame`, 8 pt in from its top and right edges.
    static func frame(in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.maxX - screenInset - size.width,
            y: visibleFrame.maxY - screenInset - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func hide(_ shown: Int) {
        guard shown == generation, current != nil else { return }
        current = nil
        guard panel.isVisible else { return }
        guard !isOffscreen, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit runs animation completions on the main thread.
            MainActor.assumeIsolated { self?.finishFade(shown) }
        })
    }

    private func finishFade(_ shown: Int) {
        guard shown == generation else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }
}

/// The HUD's content (top-left origin): the speaker symbol centred on the left, the
/// device name and the caption on one line, the level track under them.
final class VolumeHUDView: PanelFlippedView {
    static let padding: CGFloat = 16
    static let symbolBox: CGFloat = 18
    static let symbolPointSize: CGFloat = 13
    static let textX: CGFloat = 44
    static let textCenterY: CGFloat = 19
    static let trackY: CGFloat = 34

    let symbolView = NSImageView()
    let nameLabel = PanelText.label()
    let captionLabel = PanelText.label()
    let track = VolumeHUDTrackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        symbolView.imageScaling = .scaleProportionallyDown
        captionLabel.alignment = .right
        for view in [symbolView, nameLabel, captionLabel, track] as [NSView] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ model: VolumeHUDModel, theme: AppTheme) {
        let colors = theme.colors
        appearance = theme.appearance.nsAppearance
        layer?.backgroundColor = colors.raised.cgColor
        layer?.borderColor = colors.borderSubtle.cgColor
        layer?.borderWidth = Chrome.hairline
        layer?.cornerRadius = Chrome.Radius.popover
        layer?.masksToBounds = true

        symbolView.image = DeviceMenuButton.symbol(
            model.isMuted ? "speaker.slash" : "speaker.wave.2",
            pointSize: Self.symbolPointSize
        )
        symbolView.contentTintColor = colors.textPrimary
        nameLabel.attributedStringValue = PanelText.plain(model.deviceName, font: ChromeFont.label, color: colors.textPrimary)
        captionLabel.attributedStringValue = PanelText.plain(
            model.caption, font: ChromeFont.meta, color: colors.textMuted, alignment: .right
        )
        track.configure(level: model.level, isMuted: model.isMuted, theme: theme)
        let percent = Int((min(max(model.level, 0), 1) * 100).rounded())
        setAccessibilityLabel(
            "\(model.deviceName), \(model.isMuted ? "muted" : "\(percent) percent"), \(model.caption)"
        )

        let width = bounds.width
        let box = Self.symbolBox
        symbolView.frame = NSRect(x: Self.padding, y: ((bounds.height - box) / 2).rounded(), width: box, height: box)
        let textMaxX = width - Self.padding
        let captionWidth = min(PanelText.width(of: captionLabel.attributedStringValue), (textMaxX - Self.textX) / 2)
        captionLabel.frame = PanelText.lineFrame(
            minX: textMaxX - captionWidth + 2, maxX: textMaxX + 2, centerY: Self.textCenterY, font: ChromeFont.meta
        )
        nameLabel.frame = PanelText.lineFrame(
            minX: Self.textX - 2, maxX: captionLabel.frame.minX - 4, centerY: Self.textCenterY, font: ChromeFont.label
        )
        track.frame = NSRect(x: Self.textX, y: Self.trackY, width: max(0, textMaxX - Self.textX), height: MixSlider.trackHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The HUD's 4 pt track, drawn like `MixSlider`'s without a knob.
final class VolumeHUDTrackView: NSView {
    private(set) var level: Double = 0
    private var isMuted = false
    private var theme: AppTheme = .folioPaper

    func configure(level: Double, isMuted: Bool, theme: AppTheme) {
        self.level = min(max(level, 0), 1)
        self.isMuted = isMuted
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        let fillWidth = bounds.width * CGFloat(level)
        let fills: [(NSRect, NSColor)] = fillWidth > 0
            ? [(NSRect(x: bounds.minX, y: bounds.minY, width: fillWidth, height: bounds.height),
                isMuted ? colors.textMuted : colors.textPrimary)]
            : []
        MixSlider.drawTrack(bounds, fills: fills, colors: colors)
    }
}
