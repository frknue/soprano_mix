import AppKit
import SopranoMixCore

/// The status item and the app menu. A left click toggles the mixer panel below the item;
/// a right click or control-click shows the menu, which is rebuilt each time it opens, so
/// the warning line and the Launch at Login checkmark are always current. The icon follows
/// `app.menuBarIcon` (removed while `hidden`).
@MainActor
final class MenuBarController: NSObject {
    private let settings: SettingsCenter
    private let togglePanel: @MainActor (NSRect?) -> Void
    private let openPermissions: @MainActor () -> Void
    private var statusItem: NSStatusItem?
    private var appliedIcon: MenuBarIcon?

    /// `togglePanel` gets the status item button's screen frame as the anchor.
    init(
        settings: SettingsCenter = .shared,
        togglePanel: @escaping @MainActor (NSRect?) -> Void,
        openPermissions: @escaping @MainActor () -> Void
    ) {
        self.settings = settings
        self.togglePanel = togglePanel
        self.openPermissions = openPermissions
        super.init()
        apply()
    }

    /// The status item button in screen coordinates; nil while the icon is hidden.
    var buttonScreenFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Re-applies `app.menuBarIcon`.
    func apply() {
        let icon = settings.settings.app.menuBarIcon
        guard icon != appliedIcon else { return }
        appliedIcon = icon
        guard icon != .hidden else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MenuBarGlyph.image(style: icon)
            button.toolTip = "Soprano Mix"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Shows the app menu with its top-left corner at the bottom-left of `anchor` (screen
    /// coordinates), e.g. under the panel's gear button.
    func showMenu(at anchor: NSRect) {
        _ = makeMenu().popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.minY), in: nil)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            showStatusItemMenu()
        } else {
            togglePanel(buttonScreenFrame)
        }
    }

    /// Attaches the menu for this one click, so macOS positions and highlights it like any
    /// status item menu, then detaches it again so left clicks keep toggling the panel.
    private func showStatusItemMenu() {
        guard let statusItem, let button = statusItem.button else { return }
        statusItem.menu = makeMenu()
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Open settings.json…", action: #selector(openSettingsFile), key: ","))
        let issues = settings.issues
        if !issues.isEmpty {
            let count = issues.count
            let warning = NSMenuItem(
                title: "settings.json: \(count) warning\(count == 1 ? "" : "s")",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            warning.toolTip = issues.map { issue in
                issue.line.map { "line \($0): \(issue.message)" } ?? issue.message
            }.joined(separator: "\n")
            menu.addItem(warning)
        }
        menu.addItem(item("Permissions…", action: #selector(showPermissions)))
        menu.addItem(.separator())
        let launchAtLogin = item("Launch at Login", action: #selector(toggleLaunchAtLogin))
        launchAtLogin.state = settings.settings.app.startAtLogin ? .on : .off
        menu.addItem(launchAtLogin)
        menu.addItem(item("About Soprano Mix", action: #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Soprano Mix", action: #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSettingsFile() {
        settings.openInEditor()
    }

    @objc private func showPermissions() {
        openPermissions()
    }

    /// SettingsCenter logs a failed write (e.g. settings.json does not parse).
    @objc private func toggleLaunchAtLogin() {
        settings.write(!settings.settings.app.startAtLogin, at: ["app", "startAtLogin"])
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Soprano Mix",
            .applicationVersion: AppVersion.current,
            .version: "",
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
