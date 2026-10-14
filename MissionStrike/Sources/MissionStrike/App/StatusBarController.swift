import AppKit
import ApplicationServices

/// The menu bar item: a monochrome Mission Control symbol, a status line, and Pause/Resume.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()
    override private init() {}

    private var statusItem: NSStatusItem?
    private weak var delegate: AppDelegate?

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let grantAccessItem = NSMenuItem(title: "Grant Accessibility Access…", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private enum State {
        case active
        case paused
        case needsAccessibility
    }

    private var state: State {
        if EventTapManager.shared.isPaused { return .paused }
        return EventTapManager.shared.isRunning && AXIsProcessTrusted() ? .active : .needsAccessibility
    }

    func setVisible(_ visible: Bool, delegate: AppDelegate) {
        self.delegate = delegate
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.menu = makeMenu()
            statusItem = item
            refresh()
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Updates the icon and menu to the current state.
    func refresh() {
        guard let button = statusItem?.button else { return }
        let state = self.state

        // Template symbol: macOS tints it for light/dark menu bars. Paused or missing
        // permission shows the dimmed look macOS uses for inactive menu bar items.
        let image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "MissionStrike")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = state != .active

        switch state {
        case .active:
            statusLine.title = "MissionStrike is active"
            button.toolTip = "MissionStrike"
        case .paused:
            statusLine.title = "MissionStrike is paused"
            button.toolTip = "MissionStrike: Paused"
        case .needsAccessibility:
            statusLine.title = "Needs Accessibility permission"
            button.toolTip = "MissionStrike: Needs Accessibility permission"
        }
        grantAccessItem.isHidden = state != .needsAccessibility
        pauseItem.title = state == .paused ? "Resume MissionStrike" : "Pause MissionStrike"
        pauseItem.isHidden = state == .needsAccessibility
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        grantAccessItem.target = self
        grantAccessItem.action = #selector(grantAccess)
        menu.addItem(grantAccessItem)

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)

        menu.addItem(.separator())
        menu.addItem(delegateItem("Settings…", #selector(AppDelegate.openSettingsWindow), key: ","))
        menu.addItem(delegateItem("Check for Updates…", #selector(AppDelegate.checkForUpdates)))
        menu.addItem(delegateItem("About MissionStrike", #selector(AppDelegate.openAboutWindow)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit MissionStrike",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        return menu
    }

    private func delegateItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = delegate
        return item
    }

    @objc private func togglePause() {
        if EventTapManager.shared.isPaused {
            EventTapManager.shared.resume()
        } else {
            EventTapManager.shared.pause()
        }
        refresh()
    }

    @objc private func grantAccess() {
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
