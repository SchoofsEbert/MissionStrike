import AppKit
import ApplicationServices

/// A window thumbnail in Mission Control: one of WindowManager's `wid` buttons (macOS 27+).
struct MissionControlThumbnail: Sendable {
    let element: AXElement
    let window: AppWindow
    let appName: String
    /// AppKit screen coordinates.
    let frame: CGRect
    /// Accessibility (top-left origin) coordinates.
    let axFrame: CGRect
}

/// A Space's button in the Spaces Bar.
struct MissionControlSpace: Sendable {
    let element: AXElement
    /// AppKit screen coordinates.
    let frame: CGRect
    let axFrame: CGRect
    /// Whether pressing the button switches to the Space.
    let canOpen: Bool
}

/// What Mission Control shows, as the overlays need it.
struct MissionControlLayout: Sendable {
    var thumbnails: [MissionControlThumbnail] = []
    /// Nil when the scan didn't look for Spaces.
    var spaces: [MissionControlSpace]?
}

/// Lists the thumbnails of the open Mission Control for the window counts and keyboard hints.
/// WindowManager's Accessibility tree is walked off the main thread, so the event tap, which
/// shares the main thread, isn't held up while it answers.
@MainActor
final class MissionControlThumbnails {
    static let shared = MissionControlThumbnails()
    private init() {}

    /// As deep as the hit tester's walks go.
    nonisolated private static let walkDepthLimit = 12

    private var cached: (layout: MissionControlLayout, at: ContinuousClock.Instant)?
    private var running: (task: Task<MissionControlLayout, Never>, includesSpaces: Bool)?
    /// Bumped by `forget()`, so a scan that started before a change isn't kept.
    private var generation = 0

    /// The open Mission Control's layout, reusing a scan made within `maxAge`. Empty outside a
    /// session and before macOS 27, whose Mission Control has no `wid` thumbnails.
    func layout(maxAge: Duration, includeSpaces: Bool = false) async -> MissionControlLayout {
        if let cached, ContinuousClock.now - cached.at < maxAge, !includeSpaces || cached.layout.spaces != nil {
            return cached.layout
        }
        if let running, running.includesSpaces || !includeSpaces {
            return await running.task.value
        }
        guard let session = MissionControlSession.current, let root = session.windowManager else {
            return MissionControlLayout()
        }
        let flipHeight: CGFloat? = session.flipsY ? session.mainDisplayHeight : nil
        let generation = generation
        let task = Task { @MainActor in
            let found = await Self.scan(root, includeSpaces: includeSpaces)
            return Self.layout(from: found, flipHeight: flipHeight, includesSpaces: includeSpaces)
        }
        running = (task, includeSpaces)
        let layout = await task.value
        if running?.task == task {
            running = nil
        }
        if generation == self.generation {
            cached = (layout, .now)
        }
        return layout
    }

    /// Thumbnails move after a window closes or a Space goes: scan again next time.
    func forget() {
        cached = nil
        running = nil
        generation += 1
    }

    // MARK: - Scanning

    private struct Found: Sendable {
        var thumbnails: [(element: AXElement, windowID: CGWindowID, frame: CGRect)] = []
        var spaces: [(element: AXElement, frame: CGRect, canOpen: Bool)] = []
        var windows: [CGWindowID: AppWindow] = [:]
    }

    @concurrent
    nonisolated private static func scan(_ root: AXElement, includeSpaces: Bool) async -> Found {
        let elements = elements(in: root, includeSpaces: includeSpaces)
        // WindowManager keeps hidden thumbnails for the windows on other Spaces; only this
        // Space's windows are on screen.
        let windows = WindowList.appWindows(withIDs: elements.thumbnails.map(\.windowID), onScreenOnly: true)
        return Found(thumbnails: elements.thumbnails, spaces: elements.spaces, windows: windows)
    }

    private static func layout(from found: Found, flipHeight: CGFloat?, includesSpaces: Bool) -> MissionControlLayout {
        func appKit(_ frame: CGRect) -> CGRect {
            flipHeight.map { ScreenCoordinates.yFlipped(frame, mainDisplayHeight: $0) } ?? frame
        }
        var names: [pid_t: String] = [:]
        let thumbnails = found.thumbnails.compactMap { thumbnail -> MissionControlThumbnail? in
            guard let window = found.windows[thumbnail.windowID] else { return nil }
            let name = names[window.pid]
                ?? NSRunningApplication(processIdentifier: window.pid)?.localizedName
                ?? window.ownerName
            names[window.pid] = name
            return MissionControlThumbnail(
                element: thumbnail.element, window: window, appName: name,
                frame: appKit(thumbnail.frame), axFrame: thumbnail.frame
            )
        }
        let spaces = found.spaces.map { space in
            MissionControlSpace(element: space.element, frame: appKit(space.frame), axFrame: space.frame, canOpen: space.canOpen)
        }
        return MissionControlLayout(thumbnails: thumbnails, spaces: includesSpaces ? spaces : nil)
    }

    /// Every thumbnail under `root` with its window ID and frame (AX space), and, if asked, every
    /// button that can remove a Space. Thumbnails' subtrees are skipped.
    nonisolated static func elements<Element: AccessibilityElement>(
        in root: Element,
        includeSpaces: Bool
    ) -> (thumbnails: [(element: Element, windowID: CGWindowID, frame: CGRect)],
          spaces: [(element: Element, frame: CGRect, canOpen: Bool)]) {
        var thumbnails: [(element: Element, windowID: CGWindowID, frame: CGRect)] = []
        var spaces: [(element: Element, frame: CGRect, canOpen: Bool)] = []
        var seen: Set<CGWindowID> = []
        func walk(_ element: Element, depth: Int, bar: CGRect?) {
            let step = element.walkStep()
            if let windowID = step.windowID {
                if seen.insert(windowID).inserted, let frame = element.frame {
                    thumbnails.append((element, windowID, frame))
                }
                return
            }
            if includeSpaces, element.hasAction("AXRemoveDesktop"), let frame = element.frame {
                spaces.append((element, spaceFrame(fromAX: frame, bar: bar), element.hasAction(kAXPressAction)))
            }
            guard depth < walkDepthLimit else { return }
            let bar = step.title == "Spaces Bar" ? element.frame : bar
            for child in step.children {
                walk(child, depth: depth + 1, bar: bar)
            }
        }
        walk(root, depth: 0, bar: nil)
        return (thumbnails, spaces)
    }

    /// WindowManager gives a Space button's centre as its position, not its top-left corner.
    /// While the Spaces Bar is collapsed the button is pushed up past the bar's top edge, and
    /// only its name shows, in the bar's lower half.
    nonisolated static func spaceFrame(fromAX frame: CGRect, bar: CGRect?) -> CGRect {
        let centred = frame.offsetBy(dx: -frame.width / 2, dy: -frame.height / 2)
        guard let bar, centred.minY < bar.minY else { return centred }
        return CGRect(x: centred.minX, y: bar.midY, width: centred.width, height: bar.height / 2)
    }
}
