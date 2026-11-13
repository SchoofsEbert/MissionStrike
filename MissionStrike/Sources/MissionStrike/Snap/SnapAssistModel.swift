import Carbon.HIToolbox
import CoreGraphics

/// A window Snap Assist offers for the rest of the screen.
struct SnapCandidate: Equatable, Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    /// The window's size, for the shape of its thumbnail.
    let size: CGSize
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
    /// Swallowed; the ring moves to the next card that way.
    case move(HintDirection)
    /// Swallowed; Return picks the card with the ring.
    case confirm
    /// Swallowed; Esc closes the picker.
    case cancel
    /// Swallowed; a key that closes a picker still on its way, given back with the keys held
    /// for it, in the order they were typed.
    case giveBack
    /// Passes; anything else closes the picker and goes its way.
    case dismiss

    /// The number keys by key code, so they work on every layout (AZERTY types & for 1).
    init(keyCode: Int64) {
        switch Int(keyCode) {
        case kVK_Escape: self = .cancel
        case kVK_Return, kVK_ANSI_KeypadEnter: self = .confirm
        case kVK_LeftArrow: self = .move(.left)
        case kVK_RightArrow: self = .move(.right)
        case kVK_UpArrow: self = .move(.up)
        case kVK_DownArrow: self = .move(.down)
        default: self = Self.numberKeys[Int(keyCode)].map(Self.pick) ?? .dismiss
        }
    }

    /// Whether it means something before the picker shows: a number waits for it, Esc cancels
    /// it. Arrows and Return there are someone typing on, and close it.
    var waitsForPicker: Bool {
        switch self {
        case .pick, .cancel: true
        case .move, .confirm, .dismiss, .giveBack: false
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
            result.append(SnapCandidate(windowID: id, pid: pid, appName: owner, size: bounds.size))
            // Some may turn out not to be placeable; the picker keeps the first nine of the rest.
            if result.count == maxCandidates * 2 { break }
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
        case .maximize, .restore, .nextDisplay, .previousDisplay: action
        }
    }

    /// The largest a window's cell gets, so one or two windows don't fill a whole half.
    static let maxCellSize = CGSize(width: 420, height: 320)
    static let spacing: CGFloat = 24
    /// Below each thumbnail, for its title.
    static let labelHeight: CGFloat = 30

    /// One cell per window, in a centred grid within `area` (any space with y down, as the
    /// canvas lays out), with as many columns as make the cells largest, like App Exposé.
    static func cardFrames(count: Int, in area: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let grid = area.insetBy(dx: spacing * 1.5, dy: spacing * 1.5)
        guard grid.width > 0, grid.height > 0 else { return [] }
        func cell(columns: Int) -> CGSize {
            let rows = (count + columns - 1) / columns
            return CGSize(
                width: min(maxCellSize.width, (grid.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)),
                height: min(maxCellSize.height, (grid.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))
            )
        }
        // Windows are mostly wider than tall: score a cell by the 4:3 thumbnail it holds.
        let columns = (1...count).max { lhs, rhs in
            let one = cell(columns: lhs), other = cell(columns: rhs)
            return min(one.width, (one.height - labelHeight) * 4 / 3) < min(other.width, (other.height - labelHeight) * 4 / 3)
        } ?? 1
        let size = cell(columns: columns)
        let rows = (count + columns - 1) / columns
        let totalHeight = size.height * CGFloat(rows) + spacing * CGFloat(rows - 1)
        let top = grid.minY + max(0, (grid.height - totalHeight) / 2)
        return (0..<count).map { index in
            let row = index / columns
            // The last row is centred on its own when it isn't full.
            let inRow = row == rows - 1 ? count - row * columns : columns
            let rowWidth = size.width * CGFloat(inRow) + spacing * CGFloat(inRow - 1)
            return CGRect(
                x: grid.midX - rowWidth / 2 + CGFloat(index % columns) * (size.width + spacing),
                y: top + CGFloat(row) * (size.height + spacing),
                width: size.width,
                height: size.height
            ).integral
        }
    }

    /// The thumbnail inside a cell: the window's shape, as large as fits above the label.
    static func thumbnailFrame(for windowSize: CGSize, in cell: CGSize) -> CGRect {
        let room = CGSize(width: cell.width, height: max(0, cell.height - labelHeight))
        guard windowSize.width > 0, windowSize.height > 0, room.height > 0 else { return CGRect(origin: .zero, size: room) }
        // Never larger than the window itself: a small palette would only blur.
        let scale = min(1, room.width / windowSize.width, room.height / windowSize.height)
        let size = CGSize(width: (windowSize.width * scale).rounded(), height: (windowSize.height * scale).rounded())
        let origin = CGPoint(x: ((room.width - size.width) / 2).rounded(), y: ((room.height - size.height) / 2).rounded())
        return CGRect(origin: origin, size: size)
    }

    /// The card the ring moves to from `current` with an arrow: the nearest one whose centre lies
    /// that way, favouring cards in line. With no ring yet, the first card.
    static func card(from current: Int?, moving direction: HintDirection, in cards: [CGRect]) -> Int? {
        guard let current, cards.indices.contains(current) else { return cards.isEmpty ? nil : 0 }
        let origin = CGPoint(x: cards[current].midX, y: cards[current].midY)
        var best: (index: Int, score: CGFloat)?
        for (index, card) in cards.enumerated() where index != current {
            let dx = card.midX - origin.x
            let dy = card.midY - origin.y
            let (along, across): (CGFloat, CGFloat) = switch direction {
            case .left: (-dx, dy)
            case .right: (dx, dy)
            case .up: (-dy, dx)
            case .down: (dy, dx)
            }
            guard along > 1 else { continue }
            let score = along + abs(across) * 2
            if best == nil || score < best!.score { // swiftlint:disable:this force_unwrapping
                best = (index, score)
            }
        }
        return best?.index ?? current
    }
}
