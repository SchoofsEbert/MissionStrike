import AppKit
import ApplicationServices
import os

/// Intervals for Instruments' Points of Interest: the tap callback, hit-tests and actions.
let performanceSignposter = OSSignposter(subsystem: "io.github.schoofsebert.missionstrike", category: .pointsOfInterest)

/// Rolling record of recent Mission Control hits plus a system snapshot, copied from the
/// About window for bug reports. When a macOS update changes Mission Control, this shows
/// what MissionStrike saw. Times are relative and positions rounded; window titles are
/// never recorded.
@MainActor
final class Diagnostics {
    static let shared = Diagnostics()
    private init() {}

    private static let maxEvents = 25
    /// Positions in the report are rounded to this many points.
    private static let positionGrid: CGFloat = 20
    /// A callback slower than this holds up input noticeably.
    private static let slowCallback: Duration = .milliseconds(10)

    private var events: [(time: ContinuousClock.Instant, line: String)] = []
    private var overlaySnapshot = "  (Mission Control not seen since launch)"
    private var tapHealth = TapHealth()

    /// How the event tap callback has been doing since launch.
    private struct TapHealth {
        var callbacks = 0
        var total: Duration = .zero
        var slowest: Duration = .zero
        var slow = 0
        var disabledByTimeout = 0
        var disabledByUserInput = 0
    }

    /// Records a click or shortcut in Mission Control and what it resolved to. Called after
    /// the action, never from inside the event tap callback.
    /// - Parameter pointer: Where the input happened (`NSEvent.mouseLocation` space).
    func record(_ input: String, at pointer: CGPoint, resolution: MissionControlHitTester.Resolution?) {
        let flipped = MissionControlHitTester.shouldYFlipForMissionControl()
        let axPoint = flipped ? ScreenCoordinates.yFlipped(pointer) : pointer
        let outcome = resolution.map(Self.describe) ?? "nothing — under pointer: \(Self.axChain(at: axPoint))"
        events.append((.now, "\(input) near \(Self.format(axPoint))\(flipped ? " (flipped)" : "") → \(outcome)"))
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        // The window list Mission Control was last detected from; no need to copy it again.
        overlaySnapshot = Self.missionControlWindows(in: MissionControlSession.lastWindowList)
    }

    /// Called at the end of every tap callback; only adds up numbers.
    func recordCallback(duration: Duration) {
        tapHealth.callbacks += 1
        tapHealth.total += duration
        tapHealth.slowest = max(tapHealth.slowest, duration)
        if duration > Self.slowCallback { tapHealth.slow += 1 }
    }

    func recordTapDisabled(byTimeout: Bool) {
        if byTimeout {
            tapHealth.disabledByTimeout += 1
        } else {
            tapHealth.disabledByUserInput += 1
        }
    }

    /// Plain-text report for pasting into a GitHub issue.
    func report() -> String {
        let now = ContinuousClock.now
        let recent = events.isEmpty ? "  (none yet — try clicking in Mission Control first)" : events
            .map { "  \(Self.age(now - $0.time)) \($0.line)" }.joined(separator: "\n")

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return """
            MissionStrike \(version) (\(build))
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(Self.hardwareModel())
            Screens: \(Self.screens())
            Accessibility: \(AXIsProcessTrusted() ? "allowed" : "not allowed")
            Settings: \(Self.settings())
            Event tap: \(tapSummary())

            Mission Control windows (at the last recorded event):
            \(overlaySnapshot)

            Recent Mission Control input:
            \(recent)
            """
    }

    // MARK: - Pieces

    private func tapSummary() -> String {
        let health = tapHealth
        guard health.callbacks > 0 else { return "no events yet" }
        let average = health.total / health.callbacks
        return "\(health.callbacks) events, average \(Self.milliseconds(average)), slowest \(Self.milliseconds(health.slowest)), "
            + "\(health.slow) over \(Self.milliseconds(Self.slowCallback)); "
            + "disabled by macOS \(health.disabledByTimeout)× for timeout, \(health.disabledByUserInput)× for user input"
    }

    private static func describe(_ resolution: MissionControlHitTester.Resolution) -> String {
        switch resolution.target {
        case .removeDesktop: "Space"
        case .window(_, let owner, let windowID): "window \(windowID) of \(owner)"
        case .legacyAXWindow: "window (pre-macOS 27 Mission Control)"
        }
    }

    /// Role chain from the element under the point up to its ancestors, without titles.
    private static func axChain(at point: CGPoint) -> String {
        guard var element = AXElement.at(point) else { return "no element" }
        var parts: [String] = []
        for _ in 0..<5 {
            var part = element.role ?? ""
            if let subrole = element.subrole { part += "/\(subrole)" }
            if let wid = element.thumbnailWindowID { part += " wid=\(wid)" }
            if let frame = element.frame { part += " \(format(frame))" }
            parts.append(part)
            guard let parent = element.parent else { break }
            element = parent
        }
        let pid = element.pid ?? 0
        let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        return parts.joined(separator: " < ") + " [\(owner)]"
    }

    /// Dock and WindowManager windows on screen: the overlays Mission Control detection uses.
    private static func missionControlWindows(in list: [[String: Any]]) -> String {
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
        return SettingKey.allCases.map { key in
            let value = key.defaultValue is Bool ? (defaults.bool(key) ? "on" : "off") : defaults.string(key)
            return "\(key.diagnosticsName)=\(value)"
        }.joined(separator: ", ")
    }

    /// Sizes and scale only: where the screens sit relative to each other is left out.
    private static func screens() -> String {
        NSScreen.screens.enumerated().map { index, screen in
            let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height)) @\(Int(screen.backingScaleFactor))x"
            return index == 0 ? size + " (main)" : size
        }.joined(separator: ", ")
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(bytes: model.prefix { $0 != 0 }.map(UInt8.init), encoding: .utf8) ?? "unknown Mac"
    }

    /// How long before the report something happened, instead of the time of day.
    static func age(_ elapsed: Duration) -> String {
        let seconds = Int(elapsed.components.seconds)
        return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m \(seconds % 60)s ago"
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f ms", value)
    }

    /// Rounded to `positionGrid`: enough to tell the Spaces strip from a thumbnail, no more.
    static func format(_ point: CGPoint) -> String {
        "(\(rounded(point.x)), \(rounded(point.y)))"
    }

    private static func format(_ rect: CGRect) -> String {
        "\(rounded(rect.width))×\(rounded(rect.height)) at \(format(rect.origin))"
    }

    private static func rounded(_ value: CGFloat) -> Int {
        Int((value / positionGrid).rounded() * positionGrid)
    }
}
