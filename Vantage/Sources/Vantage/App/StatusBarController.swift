import AppKit
import ApplicationServices

/// The menu bar item: a monochrome mark matching the app icon, a status line, and Pause/Resume.
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
        button.image = state == .needsAccessibility ? Self.warningImage : Self.markImage
        button.appearsDisabled = state == .paused

        switch state {
        case .active:
            statusLine.title = "Vantage is active"
            button.toolTip = "Vantage"
        case .paused:
            statusLine.title = "Vantage is paused"
            button.toolTip = "Vantage: Paused"
        case .needsAccessibility:
            statusLine.title = "Accessibility access is off"
            button.toolTip = "Vantage: Accessibility access is off"
        }
        grantAccessItem.isHidden = state != .needsAccessibility
        pauseItem.title = state == .paused ? "Resume Vantage" : "Pause Vantage"
        pauseItem.isHidden = state == .needsAccessibility
    }

    /// The app icon's V as a one-colour template.
    private static let markImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            mark(in: rect).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Vantage"
        return image
    }()

    /// The mark with an exclamation badge in the lower right, cut out of the mark.
    private static let warningImage: NSImage = {
        let badgeSymbol = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            markImage.draw(in: rect)
            let badge = NSRect(x: rect.maxX - 8.5, y: rect.minY, width: 8.5, height: 8.5)
            // Clear a ring around the badge so it reads apart from the mark.
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.25, dy: -1.25)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            badgeSymbol?.draw(in: badge)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Vantage: Accessibility access is off"
        return image
    }()

    /// The V from the icon's layer (1024-point canvas, y down), fitted to `rect`.
    private static func mark(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 214, y: 236))
        path.line(to: NSPoint(x: 382, y: 236))
        path.curve(to: NSPoint(x: 411, y: 257), controlPoint1: NSPoint(x: 397, y: 236), controlPoint2: NSPoint(x: 406, y: 243))
        path.line(to: NSPoint(x: 512, y: 590))
        path.line(to: NSPoint(x: 613, y: 257))
        path.curve(to: NSPoint(x: 642, y: 236), controlPoint1: NSPoint(x: 618, y: 243), controlPoint2: NSPoint(x: 627, y: 236))
        path.line(to: NSPoint(x: 810, y: 236))
        path.curve(to: NSPoint(x: 828, y: 262), controlPoint1: NSPoint(x: 829, y: 236), controlPoint2: NSPoint(x: 835, y: 248))
        path.line(to: NSPoint(x: 571, y: 800))
        path.curve(to: NSPoint(x: 453, y: 800), controlPoint1: NSPoint(x: 551, y: 870), controlPoint2: NSPoint(x: 473, y: 870))
        path.line(to: NSPoint(x: 196, y: 262))
        path.curve(to: NSPoint(x: 214, y: 236), controlPoint1: NSPoint(x: 189, y: 248), controlPoint2: NSPoint(x: 195, y: 236))
        path.close()

        let scale = rect.width / 660
        var transform = AffineTransform(translationByX: rect.midX, byY: rect.midY)
        transform.scale(x: scale, y: -scale)
        transform.translate(x: -512, y: -545)
        path.transform(using: transform)
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
        menu.addItem(delegateItem("About Vantage", #selector(AppDelegate.openAboutWindow)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Vantage",
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
