import AppKit
import ApplicationServices

/// The menu bar item: a monochrome burst matching the app icon, a status line, and Pause/Resume.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()
    override private init() {}

    private var statusItem: NSStatusItem?
    private weak var delegate: AppDelegate?

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let grantAccessItem = NSMenuItem(title: "Grant Access…", action: nil, keyEquivalent: "")
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

        // Template images: macOS tints them for light/dark menu bars. Paused shows the
        // dimmed look macOS uses for inactive items; missing permission adds a warning badge.
        button.image = state == .needsAccessibility ? Self.warningImage : Self.burstImage
        button.appearsDisabled = state == .paused

        switch state {
        case .active:
            statusLine.title = "MissionStrike is active"
            button.toolTip = "MissionStrike"
        case .paused:
            statusLine.title = "MissionStrike is paused"
            button.toolTip = "MissionStrike: Paused"
        case .needsAccessibility:
            statusLine.title = "Accessibility access is off"
            button.toolTip = "MissionStrike: Accessibility access is off"
        }
        grantAccessItem.isHidden = state != .needsAccessibility
        pauseItem.title = state == .paused ? "Resume MissionStrike" : "Pause MissionStrike"
        pauseItem.isHidden = state == .needsAccessibility
    }

    /// The app icon's burst as a one-colour template: the outer burst with the core cut out.
    private static let burstImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let shape = burst(in: rect, points: 12, outer: 0.95, inner: 0.5,
                              jitter: [1.0, 0.82, 0.95, 0.78, 1.05, 0.86, 0.92, 0.8, 1.0, 0.84, 0.97, 0.79])
            shape.append(burst(in: rect, points: 10, outer: 0.42, inner: 0.24, jitter: [1]).reversed)
            shape.windingRule = .evenOdd
            NSColor.black.setFill()
            shape.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MissionStrike"
        return image
    }()

    /// The burst with an exclamation badge in the lower right, cut out of the burst.
    private static let warningImage: NSImage = {
        let badgeSymbol = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            burstImage.draw(in: rect)
            let badge = NSRect(x: rect.maxX - 8.5, y: rect.minY, width: 8.5, height: 8.5)
            // Clear a ring around the badge so it reads apart from the burst.
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.25, dy: -1.25)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            badgeSymbol?.draw(in: badge)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MissionStrike: Accessibility access is off"
        return image
    }()

    /// Star polygon centred in `rect`; radii are fractions of half the width, and
    /// `jitter` scales successive tips to make the burst irregular like the app icon.
    private static func burst(
        in rect: NSRect, points: Int, outer: CGFloat, inner: CGFloat, jitter: [CGFloat]
    ) -> NSBezierPath {
        let path = NSBezierPath()
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        for index in 0..<(points * 2) {
            let isTip = index.isMultiple(of: 2)
            let radius = (isTip ? outer * jitter[(index / 2) % jitter.count] : inner) * rect.width / 2
            let angle = CGFloat.pi * CGFloat(index) / CGFloat(points)
            let point = NSPoint(x: centre.x + radius * sin(angle), y: centre.y + radius * cos(angle))
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.close()
        return path
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
        AccessibilityPermission.request()
    }
}
