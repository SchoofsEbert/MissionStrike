import AppKit
import os.log

private let logger = Logger(subsystem: "com.vibecoded.missionstrike", category: "ContextMenu")

/// Right-click menu for window and Space thumbnails in Mission Control.
///
/// MissionStrike draws this menu itself instead of asking the Dock: the Dock exits
/// Mission Control as soon as it shows a menu of its own.
@MainActor
final class MissionControlContextMenu: NSObject {
    static let shared = MissionControlContextMenu()
    override private init() {}

    /// Target of the most recent menu; menu item actions read it. Not cleared after
    /// `popUp` returns so an action delivered late still finds its target.
    private var resolution: MissionControlHitTester.Resolution?
    private var app: NSRunningApplication?

    /// Pops up the menu at the cursor. Blocks in a nested run loop until it closes; the
    /// event tap keeps running meanwhile because its source is in the common modes.
    func show(for resolution: MissionControlHitTester.Resolution) {
        let menu: NSMenu
        switch resolution.target {
        case .removeDesktop:
            app = nil
            menu = spaceMenu()
        case .window, .legacyAXWindow:
            guard let pid = MissionControlManager.shared.pid(for: resolution) else {
                logger.warning("No app found for right-clicked window.")
                return
            }
            app = NSRunningApplication(processIdentifier: pid)
            menu = windowMenu(appName: app?.localizedName ?? "App")
        }

        self.resolution = resolution
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - Menus

    private func windowMenu(appName: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let icon = app?.icon {
            icon.size = NSSize(width: 16, height: 16)
            header.image = icon
        }
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(item("Close Window", #selector(closeWindow)))
        menu.addItem(item("Minimize Window", #selector(minimizeWindow)))
        menu.addItem(item("Close All \(appName) Windows", #selector(closeAllWindows)))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(hideApp)))
        menu.addItem(item("Quit \(appName)", #selector(quitApp)))

        // Shown instead of "Quit" while ⌥ is held, like the Dock's own menu.
        let forceQuit = item("Force Quit \(appName)", #selector(forceQuitApp))
        forceQuit.keyEquivalentModifierMask = .option
        forceQuit.isAlternate = true
        menu.addItem(forceQuit)
        return menu
    }

    private func spaceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Close Space", #selector(closeSpace)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func closeWindow() {
        perform(.close)
    }

    @objc private func minimizeWindow() {
        perform(.minimize)
    }

    @objc private func closeAllWindows() {
        perform(.closeAll)
    }

    @objc private func closeSpace() {
        guard let resolution, case .removeDesktop(let button) = resolution.target else { return }
        MissionControlManager.shared.removeDesktop(button)
    }

    @objc private func hideApp() {
        app?.hide()
    }

    @objc private func quitApp() {
        app?.terminate()
    }

    @objc private func forceQuitApp() {
        app?.forceTerminate()
    }

    private func perform(_ action: MouseAction) {
        guard let resolution else { return }
        MissionControlManager.shared.perform(resolution: resolution, action: action)
    }
}
