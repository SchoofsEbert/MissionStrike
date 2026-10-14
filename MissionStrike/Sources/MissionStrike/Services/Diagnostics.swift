import AppKit
import ApplicationServices

/// Rolling record of recent Mission Control hits plus a system snapshot, copied from the
/// About window for bug reports. When a macOS update changes Mission Control, this shows
/// what MissionStrike saw. Window titles are never recorded.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    private init() {}

    private static let maxEvents = 25
    private let lock = NSLock()
    private var events: [String] = []
    private var overlaySnapshot = "  (Mission Control not seen since launch)"

    /// Records a click or shortcut in Mission Control and what it resolved to.
    /// Called from the event tap; the extra work only happens for Mission Control input.
    func record(_ input: String, resolution: MissionControlHitTester.Resolution?) {
        let clickPoint = NSEvent.mouseLocation
        let flipped = MissionControlHitTester.shouldYFlipForMissionControl()
        let axPoint = flipped ? ScreenCoordinates.yFlipped(clickPoint) : clickPoint
        let outcome = resolution.map(Self.describe) ?? "nothing — under pointer: \(Self.axChain(at: axPoint))"
        let line = "\(Self.time()) \(input) at \(Self.format(axPoint))\(flipped ? " (flipped)" : "") → \(outcome)"
        let overlays = Self.missionControlWindows()

        lock.lock()
        events.append(line)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        overlaySnapshot = overlays
        lock.unlock()
    }

    /// Plain-text report for pasting into a GitHub issue.
    func report() -> String {
        lock.lock()
        let recent = events.isEmpty ? "  (none yet — try clicking in Mission Control first)" : events
            .map { "  " + $0 }.joined(separator: "\n")
        let overlays = overlaySnapshot
        lock.unlock()

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return """
            MissionStrike \(version) (\(build))
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(Self.hardwareModel())
            Screens: \(Self.screens())
            Accessibility: \(AXIsProcessTrusted() ? "allowed" : "not allowed")
            Settings: \(Self.settings())

            Mission Control windows (at the last recorded event):
            \(overlays)

            Recent Mission Control input:
            \(recent)
            """
    }

    // MARK: - Pieces

    private static func describe(_ resolution: MissionControlHitTester.Resolution) -> String {
        switch resolution.target {
        case .removeDesktop: "Space"
        case .window(_, let owner, let windowID): "window \(windowID) of \(owner)"
        case .legacyAXWindow: "window (pre-macOS 27 Mission Control)"
        }
    }

    /// Role chain from the element under the point up to its ancestors, without titles.
    private static func axChain(at point: CGPoint) -> String {
        guard var element = MissionControlHitTester.element(at: point) else { return "no element" }
        var parts: [String] = []
        for _ in 0..<5 {
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            var part = MissionControlHitTester.role(of: element)
            if let subrole = subrole as? String { part += "/\(subrole)" }
            if let wid = MissionControlHitTester.readWid(element) { part += " wid=\(wid)" }
            if let frame = MissionControlHitTester.frame(of: element) { part += " \(format(frame))" }
            parts.append(part)
            guard let parent = MissionControlHitTester.parent(of: element) else { break }
            element = parent
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        return parts.joined(separator: " < ") + " [\(owner)]"
    }

    /// Dock and WindowManager windows on screen: the overlays Mission Control detection uses.
    private static func missionControlWindows() -> String {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let lines = list.compactMap { info -> String? in
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard owner == "Dock" || owner == "WindowManager",
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                return nil
            }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            return "  \(owner) layer \(layer) \(format(bounds)) alpha \(String(format: "%.2f", alpha))"
        }
        return lines.isEmpty ? "  (none)" : lines.joined(separator: "\n")
    }

    private static func settings() -> String {
        let defaults = UserDefaults.standard
        let toggles = [
            ("middleClick", "enableMiddleClick"), ("rightClickMenu", "enableContextMenu"),
            ("shortcuts", "enableKeyboardShortcuts"), ("hoverBadge", "showHoverBadge"),
            ("spaces", "enableSpaceClosing"), ("dockMiddleClick", "enableDockMiddleClick"),
            ("poof", "poofOnClose")
        ].map { "\($0.0)=\(defaults.bool(forKey: $0.1) ? "on" : "off")" }
        let modifier = "modifier=\(defaults.string(forKey: "leftClickModifier") ?? "option")"
        return ([modifier] + toggles).joined(separator: ", ")
    }

    private static func screens() -> String {
        NSScreen.screens.map { screen in
            "\(format(screen.frame)) @\(Int(screen.backingScaleFactor))x"
        }.joined(separator: ", ")
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(bytes: model.prefix { $0 != 0 }.map(UInt8.init), encoding: .utf8) ?? "unknown Mac"
    }

    private static func time() -> String {
        Date().formatted(date: .omitted, time: .standard)
    }

    private static func format(_ point: CGPoint) -> String {
        "(\(Int(point.x)), \(Int(point.y)))"
    }

    private static func format(_ rect: CGRect) -> String {
        "\(Int(rect.width))×\(Int(rect.height)) at \(format(rect.origin))"
    }
}
