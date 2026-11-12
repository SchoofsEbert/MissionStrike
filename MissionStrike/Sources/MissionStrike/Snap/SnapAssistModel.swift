import Carbon.HIToolbox
import CoreGraphics

/// A window Snap Assist offers for the rest of the screen.
struct SnapCandidate: Equatable, Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    /// Filled in once Accessibility has answered; window-list titles need Screen Recording.
    var title: String?
}

/// What Accessibility said about the candidates' apps.
struct SnapCandidateDetails: Sendable {
    /// Apps that answered; for the others, nothing is known.
    var answered: Set<pid_t> = []
    /// The windows of answering apps that can be placed, with their titles (empty if none).
    var titles: [CGWindowID: String] = [:]
}

/// What a key or click does while Snap Assist is up.
enum SnapAssistInput: Equatable, Sendable {
    /// Swallowed; the window at this index fills the rest.
    case pick(Int)
    /// Swallowed; Esc closes the picker.
    case cancel
    /// Passes; anything else closes the picker and goes its way.
    case dismiss

    /// The number keys, by key code so they work on every layout (AZERTY types & for 1).
    init(keyCode: Int64) {
        if let index = Self.numberKeys[Int(keyCode)] {
            self = .pick(index)
        } else {
            self = keyCode == kVK_Escape ? .cancel : .dismiss
        }
    }

    private static let numberKeys: [Int: Int] = [
        kVK_ANSI_1: 0, kVK_ANSI_2: 1, kVK_ANSI_3: 2, kVK_ANSI_4: 3, kVK_ANSI_5: 4,
        kVK_ANSI_6: 5, kVK_ANSI_7: 6, kVK_ANSI_8: 7, kVK_ANSI_9: 8,
        kVK_ANSI_Keypad1: 0, kVK_ANSI_Keypad2: 1, kVK_ANSI_Keypad3: 2, kVK_ANSI_Keypad4: 3, kVK_ANSI_Keypad5: 4,
        kVK_ANSI_Keypad6: 5, kVK_ANSI_Keypad7: 6, kVK_ANSI_Keypad8: 7, kVK_ANSI_Keypad9: 8
    ]
}

enum SnapAssistModel {
    /// One per number key.
    static let maxCandidates = 9
    private static let minimumSize: CGFloat = 50

    /// The snapped window, to leave out of the offer.
    struct Snapped {
        let windowID: CGWindowID?
        let pid: pid_t
        /// The frame it took (AX space, as window-list bounds are), for when its ID is unknown.
        let frame: CGRect
    }

    /// The app windows on screen, front to back as the window list has them, without the
    /// snapped one, MissionStrike's own, system windows, small helpers and windows of apps
    /// that aren't regular apps (`isRegularApp`).
    static func candidates(
        in windowList: [[String: Any]],
        excluding snapped: Snapped,
        ownPID: pid_t,
        isRegularApp: (pid_t) -> Bool,
        ignoredOwners: Set<String> = MissionStrikeConfig.default.ignoredWindowOwners
    ) -> [SnapCandidate] {
        var result: [SnapCandidate] = []
        var regular: [pid_t: Bool] = [:]
        for info in windowList {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID, id != snapped.windowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let owner = info[kCGWindowOwnerName as String] as? String, !ignoredOwners.contains(owner),
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= minimumSize, bounds.height >= minimumSize else {
                continue
            }
            if snapped.windowID == nil, pid == snapped.pid, SnapLayout.isClose(bounds, snapped.frame) {
                continue
            }
            let isRegular = regular[pid] ?? isRegularApp(pid)
            regular[pid] = isRegular
            guard isRegular else { continue }
            result.append(SnapCandidate(windowID: id, pid: pid, appName: owner))
            if result.count == maxCandidates { break }
        }
        return result
    }

    /// The edge the picked window hugs: the one across from the snapped window.
    static func opposite(of action: SnapAction) -> SnapAction {
        switch action {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        case .maximize, .nextDisplay, .previousDisplay: action
        }
    }

    static let cardSize = CGSize(width: 220, height: 132)
    static let spacing: CGFloat = 16

    /// The cards' frames, a centred grid within `area` (any coordinate space with y down, as the
    /// canvas lays out). Cards shrink to fit a narrow or short area.
    static func cardFrames(count: Int, in area: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let grid = area.insetBy(dx: spacing * 2, dy: spacing * 2)
        guard grid.width > 0, grid.height > 0 else { return [] }
        let fitting = Int((grid.width + spacing) / (cardSize.width + spacing))
        let columns = max(1, min(count, fitting))
        let rows = (count + columns - 1) / columns
        let width = min(cardSize.width, (grid.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let height = min(cardSize.height, (grid.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))
        let totalWidth = width * CGFloat(columns) + spacing * CGFloat(columns - 1)
        let totalHeight = height * CGFloat(rows) + spacing * CGFloat(rows - 1)
        let origin = CGPoint(x: grid.midX - totalWidth / 2, y: grid.minY + max(0, (grid.height - totalHeight) / 2))
        return (0..<count).map { index in
            CGRect(
                x: origin.x + CGFloat(index % columns) * (width + spacing),
                y: origin.y + CGFloat(index / columns) * (height + spacing),
                width: width,
                height: height
            ).integral
        }
    }
}
