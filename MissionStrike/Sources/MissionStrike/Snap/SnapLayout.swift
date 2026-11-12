import CoreGraphics

/// Where a snap shortcut puts the window in front.
enum SnapAction: String, CaseIterable, Sendable {
    case left
    case right
    case top
    case bottom
    case maximize
    case nextDisplay
    case previousDisplay

    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Top"
        case .bottom: "Bottom"
        case .maximize: "Fill Screen"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        }
    }

    /// Moves the window to another screen instead of placing it on its own.
    var isDisplayMove: Bool {
        self == .nextDisplay || self == .previousDisplay
    }
}

/// The frames snapping uses, all in AX space (top-left origin) within a screen's visible area.
/// Pressing a side's shortcut again steps through half, a third and two-thirds.
enum SnapLayout {
    /// Share of the area a side takes at each step.
    static let fractions: [CGFloat] = [1.0 / 2, 1.0 / 3, 2.0 / 3]

    /// How close a window's frame must be to count as already at a snap position.
    static let tolerance: CGFloat = 2

    static func stepCount(for action: SnapAction) -> Int {
        switch action {
        case .left, .right, .top, .bottom: fractions.count
        case .maximize, .nextDisplay, .previousDisplay: 1
        }
    }

    static func frame(for action: SnapAction, step: Int, in area: CGRect) -> CGRect {
        let fraction = fractions[step % fractions.count]
        let width = (area.width * fraction).rounded()
        let height = (area.height * fraction).rounded()
        return switch action {
        case .left: CGRect(x: area.minX, y: area.minY, width: width, height: area.height)
        case .right: CGRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
        case .top: CGRect(x: area.minX, y: area.minY, width: area.width, height: height)
        case .bottom: CGRect(x: area.minX, y: area.maxY - height, width: area.width, height: height)
        case .maximize, .nextDisplay, .previousDisplay: area
        }
    }

    /// The rest of the area next to a snapped frame, for another window; nil when nothing's left.
    static func complement(of action: SnapAction, step: Int, in area: CGRect) -> CGRect? {
        let snapped = frame(for: action, step: step, in: area)
        return switch action {
        case .left: CGRect(x: snapped.maxX, y: area.minY, width: area.maxX - snapped.maxX, height: area.height)
        case .right: CGRect(x: area.minX, y: area.minY, width: snapped.minX - area.minX, height: area.height)
        case .top: CGRect(x: area.minX, y: snapped.maxY, width: area.width, height: area.maxY - snapped.maxY)
        case .bottom: CGRect(x: area.minX, y: area.minY, width: area.width, height: snapped.minY - area.minY)
        case .maximize, .nextDisplay, .previousDisplay: nil
        }
    }

    /// Which step a press goes to. The last snap counts when it was this action on this window
    /// and the window hasn't moved since; it's compared to the frame the window actually took,
    /// as apps like Terminal round their size. Otherwise a window already at a step (snapped by
    /// another tool) moves on from there.
    static func nextStep(
        for action: SnapAction,
        windowFrame: CGRect,
        area: CGRect,
        last: SnapRecord?,
        windowID: CGWindowID?
    ) -> Int {
        let count = stepCount(for: action)
        if let last, last.action == action, last.windowID == windowID, isClose(last.frame, windowFrame) {
            return (last.step + 1) % count
        }
        if let step = (0..<count).first(where: { isClose(frame(for: action, step: $0, in: area), windowFrame) }) {
            return (step + 1) % count
        }
        return 0
    }

    /// Where a press puts a window at `windowFrame`: the frame, and the step and area it came
    /// from. Nil when it has nowhere to go, such as a display move with one screen.
    static func plan(
        _ action: SnapAction,
        windowFrame: CGRect,
        areas: [CGRect],
        last: SnapRecord?,
        windowID: CGWindowID?
    ) -> (frame: CGRect, step: Int, area: CGRect)? {
        guard let area = area(for: windowFrame, in: areas) else { return nil }
        if action.isDisplayMove {
            return frame(movingToDisplay: action, from: windowFrame, in: areas).map { ($0, 0, area) }
        }
        let step = nextStep(for: action, windowFrame: windowFrame, area: area, last: last, windowID: windowID)
        return (frame(for: action, step: step, in: area), step, area)
    }

    /// A window that took another size than asked, put back against the edge its action hugs,
    /// so a right or bottom snap neither leaves a gap nor runs off the screen.
    static func anchored(_ taken: CGRect, for action: SnapAction, target: CGRect, in area: CGRect) -> CGRect {
        var origin = target.origin
        switch action {
        case .right: origin.x = max(area.minX, area.maxX - taken.width)
        case .bottom: origin.y = max(area.minY, area.maxY - taken.height)
        case .left, .top, .maximize, .nextDisplay, .previousDisplay: break
        }
        return CGRect(origin: origin, size: taken.size)
    }

    /// The frame on the next screen to the right (or left), wrapping around, at the same place
    /// relative to its area: a snapped window stays snapped the same way. Nil with one screen.
    static func frame(movingToDisplay action: SnapAction, from windowFrame: CGRect, in areas: [CGRect]) -> CGRect? {
        guard areas.count > 1, let source = area(for: windowFrame, in: areas) else { return nil }
        let ordered = areas.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
        guard let index = ordered.firstIndex(of: source) else { return nil }
        let offset = action == .previousDisplay ? ordered.count - 1 : 1
        let target = ordered[(index + offset) % ordered.count]
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        let frame = CGRect(
            x: target.minX + (windowFrame.minX - source.minX) * scaleX,
            y: target.minY + (windowFrame.minY - source.minY) * scaleY,
            width: windowFrame.width * scaleX,
            height: windowFrame.height * scaleY
        ).integral
        // A window partly off its screen stays whole on the new one.
        return frame.intersection(target).isNull ? target : frame.intersection(target)
    }

    /// The screen area a window snaps within: the one it overlaps most, else the first.
    static func area(for windowFrame: CGRect, in areas: [CGRect]) -> CGRect? {
        let overlaps = areas.map { area -> CGFloat in
            let overlap = area.intersection(windowFrame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }) else { return nil }
        return overlaps[best] > 0 ? areas[best] : areas.first
    }

    static func isClose(_ one: CGRect, _ other: CGRect) -> Bool {
        abs(one.minX - other.minX) <= tolerance && abs(one.minY - other.minY) <= tolerance
            && abs(one.width - other.width) <= tolerance && abs(one.height - other.height) <= tolerance
    }
}

/// The last snap, to tell a repeated press from a first one.
struct SnapRecord: Equatable, Sendable {
    let action: SnapAction
    let step: Int
    let windowID: CGWindowID?
    /// The frame the window took, which may differ from the one asked for.
    let frame: CGRect
}
