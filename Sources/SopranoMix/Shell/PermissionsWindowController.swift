import AppKit
import SopranoMixCore

/// The permissions window (Soprano Tab's): a serif "Permissions" headline, then one row per
/// privacy grant with its status mark, what it enables and its button: "Allow" (macOS's
/// prompt) while System Audio Recording is not determined, else "Open System Settings".
/// Polls every second while visible, so a mark turns as soon as the user grants access.
@MainActor
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 580, height: 224)

    /// Fires on the main actor whenever a refresh sees a different status (the app delegate
    /// re-plans routes and retries the volume-key tap).
    var onStatusChange: (@MainActor (PermissionStatus) -> Void)?

    private let status: @MainActor () -> PermissionStatus
    /// nil follows `ThemeCenter.shared`.
    private let fixedTheme: AppTheme?
    private let backgroundView = ThemedBackgroundView(
        frame: NSRect(origin: .zero, size: PermissionsWindowController.contentSize)
    )
    private let heading = NSTextField(labelWithString: "Permissions")
    private let rule = ChromeRuleView(axis: .horizontal)
    private let captureRow: PermissionRowView
    private let accessibilityRow: PermissionRowView
    private var pollTimer: Timer?
    private var lastStatus: PermissionStatus?

    init(status: @escaping @MainActor () -> PermissionStatus, theme: AppTheme? = nil) {
        self.status = status
        fixedTheme = theme
        let theme = theme ?? ThemeCenter.shared.theme
        captureRow = PermissionRowView(
            name: "System audio recording",
            detail: "Change app volumes, mute apps and send them to other outputs. Required.",
            theme: theme
        )
        accessibilityRow = PermissionRowView(
            name: "Accessibility",
            detail: "Volume keys for outputs without hardware volume, like HDMI and DisplayPort. Optional.",
            theme: theme
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Soprano Mix Permissions"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = backgroundView
        window.delegate = self
        captureRow.onAction = { [weak self] in self?.captureAction() }
        accessibilityRow.onAction = { [weak self] in self?.accessibilityAction() }
        buildLayout()
        apply(theme: theme)
        refresh()
        window.center()

        if fixedTheme == nil {
            ThemeCenter.shared.addObserver(self) { [weak self] in
                self?.apply(theme: ThemeCenter.shared.theme)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Brings the window front (activating the menu-bar app) and polls while it is open.
    func show() {
        refresh()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Re-reads the status and updates the marks and buttons.
    func refresh() {
        let current = status()
        captureRow.state = Self.captureState(current.capture)
        accessibilityRow.state = Self.accessibilityState(current.accessibility)
        let previous = lastStatus
        lastStatus = current
        if let previous, previous != current {
            onStatusChange?(current)
        }
    }

    /// Renders the window's content without ordering it front (snapshot harness, tests).
    func renderImage() -> CGImage? {
        guard let window, let view = window.contentView else { return nil }
        refresh()
        view.wantsLayer = true
        // Twice: the first pass sizes the wrapping descriptions, the second their rows.
        view.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.display()
        CATransaction.flush()
        guard let layer = view.layer else { return nil }

        let scale = max(1, window.backingScaleFactor)
        let size = view.bounds.size
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(size.width * scale),
                  height: Int(size.height * scale),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        return context.makeImage()
    }

    /// Granted: success dot. Not determined: needs-input dot and "Allow". Denied: danger
    /// diamond. Unknown (the private status API is missing): a gray ring.
    private static func captureState(_ capture: CaptureStatus) -> PermissionRowView.State {
        switch capture {
        case .granted:
            PermissionRowView.State(mark: .dot, tone: .success, button: "Open System Settings", isPrimary: false, spoken: "granted")
        case .notDetermined:
            PermissionRowView.State(mark: .dot, tone: .needsInput, button: "Allow", isPrimary: true, spoken: "not allowed yet")
        case .denied:
            PermissionRowView.State(mark: .diamond, tone: .danger, button: "Open System Settings", isPrimary: true, spoken: "denied")
        case .unknown:
            PermissionRowView.State(mark: .ring, tone: .neutral, button: "Open System Settings", isPrimary: false, spoken: "unknown")
        }
    }

    /// Optional, so a missing grant is a gray ring rather than a failure.
    private static func accessibilityState(_ trusted: Bool) -> PermissionRowView.State {
        trusted
            ? PermissionRowView.State(mark: .dot, tone: .success, button: "Open System Settings", isPrimary: false, spoken: "granted")
            : PermissionRowView.State(mark: .ring, tone: .neutral, button: "Open System Settings", isPrimary: true, spoken: "missing")
    }

    private func captureAction() {
        if status().capture == .notDetermined {
            Permissions.requestCapture { [weak self] _ in
                self?.refresh()
            }
        } else {
            Permissions.openSettings(for: .audioCapture)
        }
    }

    /// While missing, macOS's own prompt adds Soprano Mix to the Accessibility list and
    /// offers to open System Settings; once granted, the button opens the pane.
    private func accessibilityAction() {
        if status().accessibility {
            Permissions.openSettings(for: .accessibility)
        } else {
            Permissions.requestAccessibility()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func apply(theme: AppTheme) {
        window?.appearance = theme.appearance.nsAppearance
        backgroundView.color = theme.colors.bgBase
        window?.backgroundColor = theme.colors.bgBase
        heading.setChromeText("Permissions", font: ChromeFont.headline, color: theme.colors.textPrimary)
        rule.color = theme.colors.borderSubtle
        captureRow.apply(theme: theme)
        accessibilityRow.apply(theme: theme)
    }

    private func buildLayout() {
        let rows: [NSView] = [captureRow, rule, accessibilityRow]
        heading.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(heading)
        for view in rows {
            view.translatesAutoresizingMaskIntoConstraints = false
            backgroundView.addSubview(view)
        }
        let inset: CGFloat = 20
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: inset),
            heading.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: inset),
            heading.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -inset),

            captureRow.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            rule.topAnchor.constraint(equalTo: captureRow.bottomAnchor, constant: 12),
            rule.heightAnchor.constraint(equalToConstant: Chrome.hairline),
            accessibilityRow.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 12),
        ])
        for view in rows {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: inset),
                view.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -inset),
            ])
        }
    }
}

/// One permission: status mark, name, what it enables, and its button (ink while the
/// grant needs the user, so the next step is obvious).
@MainActor
private final class PermissionRowView: NSView {
    enum Tone {
        case success
        case needsInput
        case danger
        case neutral
    }

    struct State: Equatable {
        var mark: ChromeStatusMark.Shape
        var tone: Tone
        var button: String
        /// The ink button.
        var isPrimary: Bool
        /// VoiceOver's status word.
        var spoken: String
    }

    var state = State(mark: .ring, tone: .neutral, button: "Open System Settings", isPrimary: false, spoken: "unknown") {
        didSet {
            guard state != oldValue else { return }
            restyle()
        }
    }
    var onAction: (@MainActor () -> Void)?

    private let mark = ChromeStatusMark()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let button: ChromeButton
    private let name: String
    private var theme: AppTheme

    init(name: String, detail: String, theme: AppTheme) {
        self.name = name
        self.theme = theme
        button = ChromeButton(title: "Open System Settings", theme: theme)
        super.init(frame: .zero)
        button.target = self
        button.action = #selector(buttonPressed)
        detailLabel.stringValue = detail
        detailLabel.font = ChromeFont.label
        detailLabel.isSelectable = false

        mark.setAccessibilityElement(false)
        for view in [mark, nameLabel, detailLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        nameLabel.lineBreakMode = .byTruncatingTail
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(mark)
        addSubview(nameLabel)
        addSubview(detailLabel)
        addSubview(button)

        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor),
            mark.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: Chrome.statusMark),
            mark.heightAnchor.constraint(equalToConstant: Chrome.statusMark),

            nameLabel.topAnchor.constraint(equalTo: topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16),

            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -16),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            button.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        button.apply(theme: theme)
        restyle()
    }

    override func layout() {
        super.layout()
        // A wrapping label reports its height for `preferredMaxLayoutWidth`; feed it the
        // width it got, then lay out again with the matching height.
        let width = detailLabel.frame.width
        if width > 0, detailLabel.preferredMaxLayoutWidth != width {
            detailLabel.preferredMaxLayoutWidth = width
            needsLayout = true
        }
    }

    private func restyle() {
        let colors = theme.colors
        mark.shape = state.mark
        mark.color = switch state.tone {
        case .success: colors.success
        case .needsInput: colors.yellow
        case .danger: colors.danger
        case .neutral: colors.gray
        }
        nameLabel.setChromeText(name, font: ChromeFont.row, color: colors.textPrimary)
        detailLabel.textColor = colors.textMuted
        button.title = state.button
        button.kind = state.isPrimary ? .ink : .standard
        setAccessibilityLabel("\(name), \(state.spoken)")
    }

    @objc private func buttonPressed() {
        onAction?()
    }
}

/// The window's base fill, drawn through its layer so offscreen renders include it.
@MainActor
private final class ThemedBackgroundView: NSView {
    var color: NSColor = .black {
        didSet { layer?.backgroundColor = color.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
