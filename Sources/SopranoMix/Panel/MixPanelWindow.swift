import AppKit
import SopranoMixCore

/// The menu-bar panel: a borderless non-activating `NSPanel` 380 wide, 4 pt below the
/// status item and right-aligned to it, as tall as its content up to 80 % of the visible
/// height (the app list scrolls beyond). It becomes key so sliders take arrow keys;
/// Escape and clicks in other apps dismiss it (clicks on the status item are the
/// shell's). Off screen (snapshot harness, tests) it lays out and renders but never
/// orders in.
@MainActor
final class MixPanelWindow: MixPanelPresenting {
    /// Keeps the panel off screen while still laying it out. A process whose activation
    /// policy is `.prohibited` (the snapshot harness, the test runner) is treated the
    /// same way.
    static var offscreen = false

    private(set) var isVisible = false
    var onIntent: ((PanelIntent) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    let content = MixPanelContentView()
    let panel: MixPanel
    private var model: MixPanelModel?
    private var theme: AppTheme = .folioPaper
    private var visibleFrame = MixPanelGeometry.fallbackVisibleFrame
    private var clickMonitor: Any?

    init() {
        // Windows need the shared application, which a test runner has not created yet.
        _ = NSApplication.shared
        panel = MixPanel()
        panel.contentView = content
        content.onIntent = { [weak self] intent in self?.onIntent?(intent) }
        panel.onEscape = { [weak self] in self?.dismissByUser() }
    }

    private var isOffscreen: Bool {
        Self.offscreen || NSApplication.shared.activationPolicy() == .prohibited
    }

    // MARK: - MixPanelPresenting

    func show(model: MixPanelModel, theme: AppTheme, anchor: NSRect?) {
        let wasVisible = isVisible
        self.model = model
        self.theme = theme
        visibleFrame = Self.visibleFrame(for: anchor)
        let metrics = content.apply(model, theme: theme)
        let heights = MixPanelGeometry.heights(for: metrics, visibleFrame: visibleFrame)
        let frame = MixPanelGeometry.frame(height: heights.panel, anchor: anchor, visibleFrame: visibleFrame)
        place(frame)
        if !wasVisible {
            content.scrollToTop()
        }
        isVisible = true
        if !isOffscreen {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            if !wasVisible {
                panel.makeFirstResponder(nil)
            }
            installClickMonitor()
        }
        if !wasVisible {
            onVisibilityChange?(true)
        }
    }

    func update(model: MixPanelModel, theme: AppTheme) {
        self.model = model
        self.theme = theme
        let metrics = content.apply(model, theme: theme)
        let heights = MixPanelGeometry.heights(for: metrics, visibleFrame: visibleFrame)
        let current = panel.frame
        let frame = current.width > 0 && current.height > 1
            ? MixPanelGeometry.frame(height: heights.panel, keepingTopOf: current)
            : MixPanelGeometry.frame(height: heights.panel, anchor: nil, visibleFrame: visibleFrame)
        place(frame)
    }

    func updateLevels(_ levels: [AppKey: Double]) {
        content.setLevels(levels)
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        removeClickMonitor()
        if panel.isVisible {
            panel.orderOut(nil)
        }
        onVisibilityChange?(false)
    }

    func renderSnapshot(scale: CGFloat) -> CGImage? {
        guard model != nil else { return nil }
        return PanelRendering.snapshot(
            of: content,
            scale: scale,
            shadow: theme.colors.shadowE2,
            radius: Chrome.Radius.popover,
            background: theme.colors.bgBase
        )
    }

    // MARK: - Placement

    private func place(_ frame: NSRect) {
        panel.appearance = theme.appearance.nsAppearance
        if panel.frame != frame {
            panel.setFrame(frame, display: !isOffscreen && panel.isVisible)
        }
        content.layoutPanel(size: frame.size)
        panel.invalidateShadow()
    }

    /// The visible frame of the screen holding `anchor`, else of the main screen.
    private static func visibleFrame(for anchor: NSRect?) -> NSRect {
        if let anchor {
            let center = NSPoint(x: anchor.midX, y: anchor.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen.visibleFrame
            }
        }
        return (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? MixPanelGeometry.fallbackVisibleFrame
    }

    // MARK: - Dismissal

    /// Escape or a click outside: report the intent, then hide.
    private func dismissByUser() {
        guard isVisible else { return }
        onIntent?(.dismiss)
        dismiss()
    }

    /// Clicks in other apps close the panel. Clicks in our own windows (the status item)
    /// never reach a global monitor; the shell handles those.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Global monitors run on the main thread.
            MainActor.assumeIsolated {
                self?.dismissByUser()
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }
}

/// The borderless, non-activating panel: floats over every app and Space (full-screen
/// ones too) at the pop-up menu level, never hides when another app is active, and
/// becomes key so its sliders take the arrow keys. Escape reports `onEscape`.
final class MixPanel: NSPanel {
    var onEscape: (() -> Void)?
    private static let escapeKeyCode: UInt16 = 53

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: MixPanelGeometry.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        autorecalculatesKeyViewLoop = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The panel's size and place; pure, so it is testable without a screen.
enum MixPanelGeometry {
    static let width: CGFloat = 380
    /// Gap between the status item and the panel's top edge.
    static let anchorGap: CGFloat = 4
    /// Inset from the screen's right edge without an anchor.
    static let screenInset: CGFloat = 8
    static let maxHeightFraction: CGFloat = 0.8
    /// Used when no screen is known (a process without a window server connection).
    static let fallbackVisibleFrame = NSRect(x: 0, y: 0, width: 1512, height: 949)

    /// The heights the content needs: everything but the app list, and the app list's
    /// full height (rows or the empty state).
    struct ContentMetrics: Equatable {
        var fixedHeight: CGFloat
        var listHeight: CGFloat
    }

    struct Heights: Equatable {
        var panel: CGFloat
        /// The app list's viewport.
        var list: CGFloat
    }

    /// The content's full height up to 80 % of the visible height; the app list scrolls
    /// beyond. The fixed parts never shrink: a screen too short for them gets a panel as
    /// tall as they are with an empty list viewport.
    static func heights(for metrics: ContentMetrics, visibleFrame: NSRect) -> Heights {
        let limit = floor(visibleFrame.height * maxHeightFraction)
        let full = metrics.fixedHeight + metrics.listHeight
        let panel = min(full, max(limit, metrics.fixedHeight))
        return Heights(panel: panel, list: max(0, panel - metrics.fixedHeight))
    }

    /// Below `anchor` (4 pt gap, right edges aligned), else at the top right of
    /// `visibleFrame`; clamped into `visibleFrame`. AppKit coordinates.
    static func frame(height: CGFloat, anchor: NSRect?, visibleFrame: NSRect) -> NSRect {
        var x: CGFloat
        let top: CGFloat
        if let anchor {
            x = anchor.maxX - width
            top = min(anchor.minY - anchorGap, visibleFrame.maxY)
        } else {
            x = visibleFrame.maxX - screenInset - width
            top = visibleFrame.maxY - anchorGap
        }
        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - width)
        let y = max(top - height, visibleFrame.minY)
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    /// `current` resized to `height` with its top edge kept.
    static func frame(height: CGFloat, keepingTopOf current: NSRect) -> NSRect {
        NSRect(x: current.minX, y: current.maxY - height, width: current.width, height: height)
    }
}
