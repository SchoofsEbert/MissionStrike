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

    /// True while a menu is on screen. Read by the event tap callback, which runs on
    /// the main thread inside the menu's tracking loop.
    nonisolated(unsafe) static var isOpen = false

    /// Target of the most recent menu; menu item actions read it. Not cleared after
    /// `popUp` returns so an action delivered late still finds its target.
    private var resolution: MissionControlHitTester.Resolution?
    private var app: NSRunningApplication?

    private var openMenu: NSMenu?
    /// Target to open next once the current menu has closed (right-click on another thumbnail).
    private var pending: MissionControlHitTester.Resolution?

    /// Pops up the menu at the cursor. Blocks in a nested run loop until it closes; the
    /// event tap keeps running meanwhile because its source is in the common modes.
    func show(for resolution: MissionControlHitTester.Resolution) {
        if openMenu != nil {
            replace(with: resolution)
            return
        }
        var next: MissionControlHitTester.Resolution? = resolution
        while let current = next {
            next = nil
            guard let menu = makeMenu(for: current) else { break }
            self.resolution = current
            openMenu = menu
            Self.isOpen = true
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            Self.isOpen = false
            openMenu = nil
            next = pending
            pending = nil
        }
    }

    /// Closes the open menu and, if `resolution` is given, opens that target's menu next.
    func replace(with resolution: MissionControlHitTester.Resolution?) {
        pending = resolution
        openMenu?.cancelTrackingWithoutAnimation()
    }

    /// Whether a point (Quartz global coordinates) lies on one of our menu windows.
    nonisolated static func menuContains(_ point: CGPoint) -> Bool {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let ownPID = Int(getpid())
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            guard info[kCGWindowOwnerPID as String] as? Int == ownPID,
                  info[kCGWindowLayer as String] as? Int == menuLevel,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                return false
            }
            return bounds.contains(point)
        }
    }

    private func makeMenu(for resolution: MissionControlHitTester.Resolution) -> NSMenu? {
        switch resolution.target {
        case .removeDesktop:
            app = nil
            return spaceMenu()
        case .window, .legacyAXWindow:
            guard let pid = MissionControlManager.shared.pid(for: resolution) else {
                logger.warning("No app found for right-clicked window.")
                return nil
            }
            app = NSRunningApplication(processIdentifier: pid)
            return windowMenu(appName: app?.localizedName ?? "App")
        }
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

        menu.addItem(item("Close Window", #selector(closeWindow), key: "w"))
        menu.addItem(item("Minimize Window", #selector(minimizeWindow), key: "m"))
        menu.addItem(item("Close All \(appName) Windows", #selector(closeAllWindows)))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(hideApp), key: "h"))
        menu.addItem(item("Quit \(appName)", #selector(quitApp), key: "q"))

        // Shown instead of "Quit" while ⌥ is held, like the Dock's own menu.
        let forceQuit = item("Force Quit \(appName)", #selector(forceQuitApp), key: "q")
        forceQuit.keyEquivalentModifierMask = [.command, .option]
        forceQuit.isAlternate = true
        menu.addItem(forceQuit)
        return menu
    }

    private func spaceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Close Space", #selector(closeSpace), key: "w"))
        return menu
    }

    /// `key` shows the matching Mission Control shortcut (⌘ + key) next to the item.
    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
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
