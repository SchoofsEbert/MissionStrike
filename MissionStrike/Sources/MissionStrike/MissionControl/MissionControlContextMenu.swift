import AppKit
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "ContextMenu")

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
    /// Point to open the next menu at once the current menu has closed (right-click elsewhere).
    private var pending: CGPoint?

    /// Pops up the menu for whatever is under `point`. Blocks in a nested run loop until it
    /// closes; the event tap keeps running meanwhile because its source is in the common modes.
    func show(at point: CGPoint) {
        if openMenu != nil {
            replace(withMenuAt: point)
            return
        }
        var next: CGPoint? = point
        while let point = next {
            next = nil
            let current = Self.target(at: point)
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

    /// Closes the open menu and, if `point` is given, opens the menu for that point next.
    func replace(withMenuAt point: CGPoint?) {
        pending = point
        openMenu?.cancelTrackingWithoutAnimation()
    }

    private static func target(at point: CGPoint) -> ContextMenuTarget {
        let resolution = MissionControlHitTester.resolve(clickPoint: point)
        Diagnostics.shared.record("right-click", resolution: resolution)
        return resolution.map(ContextMenuTarget.thumbnail) ?? .background
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

    /// Lists the windowless apps by name and icon: click one to quit just that app,
    /// or quit them all at once.
    private func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        windowlessApps = AppHousekeeping.appsWithoutWindows()
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }

        guard !windowlessApps.isEmpty else {
            let none = NSMenuItem(title: "No Apps Without Windows", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return menu
        }

        menu.addItem(.sectionHeader(title: "Apps With No Windows"))
        for app in windowlessApps {
            let appItem = item(app.localizedName ?? "Unknown App", #selector(quitWindowlessApp(_:)))
            appItem.representedObject = app
            appItem.toolTip = "Quit \(app.localizedName ?? "this app")"
            if let icon = app.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                appItem.image = icon
            }
            menu.addItem(appItem)
        }
        menu.addItem(.separator())
        let count = windowlessApps.count
        menu.addItem(item(
            count == 1 ? "Quit \(windowlessApps[0].localizedName ?? "App")" : "Quit All \(count) Apps",
            #selector(quitWindowlessApps)
        ))
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

    @objc private func quitWindowlessApp(_ sender: NSMenuItem) {
        (sender.representedObject as? NSRunningApplication)?.terminate()
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
