import AppKit
import os.log

private let logger = Logger(subsystem: "com.vibecoded.missionstrike", category: "ContextMenu")

/// What a right-click in Mission Control landed on.
enum ContextMenuTarget: @unchecked Sendable {
    case thumbnail(MissionControlHitTester.Resolution)
    /// Empty Mission Control space: app-wide actions.
    case background
}

/// Right-click menu for window and Space thumbnails, and the empty Mission Control background.
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

    /// Apps offered by the background menu's "Quit Apps With No Windows".
    private var windowlessApps: [NSRunningApplication] = []

    private var openMenu: NSMenu?
    /// Target to open next once the current menu has closed (right-click elsewhere).
    private var pending: ContextMenuTarget?

    /// Pops up the menu at the cursor. Blocks in a nested run loop until it closes; the
    /// event tap keeps running meanwhile because its source is in the common modes.
    func show(for target: ContextMenuTarget) {
        if openMenu != nil {
            replace(with: target)
            return
        }
        var next: ContextMenuTarget? = target
        while let current = next {
            next = nil
            guard let menu = makeMenu(for: current) else { break }
            if case .thumbnail(let resolution) = current {
                self.resolution = resolution
            }
            openMenu = menu
            Self.isOpen = true
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            Self.isOpen = false
            openMenu = nil
            next = pending
            pending = nil
        }
    }

    /// Closes the open menu and, if `target` is given, opens that target's menu next.
    func replace(with target: ContextMenuTarget?) {
        pending = target
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

    private func makeMenu(for target: ContextMenuTarget) -> NSMenu? {
        guard case .thumbnail(let resolution) = target else {
            return backgroundMenu()
        }
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
            return windowMenu(appName: app?.localizedName ?? "App", target: resolution.target)
        }
    }

    // MARK: - Menus

    private func windowMenu(appName: String, target: MissionControlHitTester.Target) -> NSMenu {
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
        if case .window = target {
            menu.addItem(item("Close Other \(appName) Windows", #selector(closeOtherWindows)))
        }
        menu.addItem(item("Close All \(appName) Windows", #selector(closeAllWindows)))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(hideApp), key: "h"))
        let hideOthers = item("Hide Others", #selector(hideOtherApps), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(item("Quit \(appName)", #selector(quitApp), key: "q"))

        // Shown instead of "Quit" while ⌥ is held, like the Dock's own menu.
        let forceQuit = item("Force Quit \(appName)", #selector(forceQuitApp), key: "q")
        forceQuit.keyEquivalentModifierMask = [.command, .option]
        forceQuit.isAlternate = true
        menu.addItem(forceQuit)
        return menu
    }

    private func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        windowlessApps = AppHousekeeping.appsWithoutWindows()
        let names = windowlessApps.compactMap(\.localizedName).sorted()
        let quit = item(
            names.isEmpty ? "No Apps Without Windows" : "Quit \(names.count) Apps With No Windows",
            #selector(quitWindowlessApps)
        )
        quit.isEnabled = !names.isEmpty
        quit.toolTip = names.joined(separator: ", ")
        menu.addItem(quit)
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

    @objc private func closeOtherWindows() {
        guard let resolution, case .window(let pid, _, let windowID) = resolution.target else { return }
        MissionControlManager.shared.closeAllWindows(forPID: pid, except: windowID)
    }

    @objc private func hideOtherApps() {
        guard let app else { return }
        AppHousekeeping.hideOthers(except: app.processIdentifier)
    }

    @objc private func quitWindowlessApps() {
        for app in windowlessApps {
            app.terminate()
        }
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
