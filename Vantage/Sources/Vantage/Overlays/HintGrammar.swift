import Carbon.HIToolbox
import CoreGraphics

/// A key press while keyboard hints are on screen.
enum HintKey: Equatable, Sendable {
    /// A letter, lowercased, as the keyboard layout types it.
    case letter(Character)
    /// Return or Enter.
    case confirm
    /// Esc.
    case cancel
    case deleteBackward
    case move(HintDirection)
    case other

    init(keyCode: Int64, characters: String) {
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: self = .confirm
        case kVK_Escape: self = .cancel
        case kVK_Delete: self = .deleteBackward
        case kVK_LeftArrow: self = .move(.left)
        case kVK_RightArrow: self = .move(.right)
        case kVK_UpArrow: self = .move(.up)
        case kVK_DownArrow: self = .move(.down)
        default: self = Self.letter(keyCode: keyCode, characters: characters).map(Self.letter) ?? .other
        }
    }

    /// The letter the layout types; for layouts without Latin letters (Cyrillic, Greek), the
    /// letter printed on that key of a US keyboard.
    private static func letter(keyCode: Int64, characters: String) -> Character? {
        guard characters.count == 1, let typed = characters.lowercased().first, typed.isLetter else { return nil }
        return typed.isASCII ? typed : usLetters[Int(keyCode)]
    }

    private static let usLetters: [Int: Character] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f",
        kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r",
        kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Y: "y", kVK_ANSI_Z: "z"
    ]
}

enum HintDirection: Sendable {
    case left, right, up, down
}

/// What to do with the selected thumbnail.
enum HintAction: CaseIterable, Sendable {
    case close
    case minimize
    case hide
    case quit
    case closeAll
    case open

    /// The letter for the action, like the ⌘ shortcuts; nil for open, which is Return.
    var letter: Character? {
        switch self {
        case .close: "w"
        case .minimize: "m"
        case .hide: "h"
        case .quit: "q"
        case .closeAll: "a"
        case .open: nil
        }
    }

    init?(letter: Character) {
        guard let action = Self.allCases.first(where: { $0.letter == letter }) else { return nil }
        self = action
    }
}

/// Labels for keyboard hints: one or two letters each, none the start of another, so a label
/// is chosen the moment its last letter is typed.
enum HintLabels {
    /// Home row first. Leaves out the action letters (W, M, H, Q, A) and F, which turns hints
    /// on and off, so a letter is never both part of a label and an action.
    static let alphabet: [Character] = Array("sdjklgeiruotypcvbnxz")
    static let toggleLetter: Character = "f"

    /// `count` labels, single letters first. Each letter given up as a single label starts a
    /// row of two-letter labels instead. Beyond `alphabet.count`² there are no more labels.
    static func make(count: Int, alphabet: [Character] = alphabet) -> [String] {
        let size = alphabet.count
        let count = min(count, size * size)
        guard count > size else { return alphabet.prefix(max(count, 0)).map { String($0) } }
        // Each prefix letter turns one single label into `size` two-letter ones.
        let prefixCount = (count - size + size - 2) / (size - 1)
        let singles = alphabet.prefix(size - prefixCount).map { String($0) }
        let doubles = alphabet.suffix(prefixCount).flatMap { first in alphabet.map { String([first, $0]) } }
        return singles + doubles.prefix(count - singles.count)
    }

    /// Indices of `frames` (AppKit screen coordinates) in reading order: rows from the top,
    /// each left to right. A frame joins a row when its centre is level with the row's first frame.
    static func readingOrder(_ frames: [CGRect]) -> [Int] {
        let byTop = frames.indices.sorted { frames[$0].maxY > frames[$1].maxY }
        var rows: [[Int]] = []
        for index in byTop {
            if let first = rows.last?.first, frames[index].midY > frames[first].minY {
                rows[rows.count - 1].append(index)
            } else {
                rows.append([index])
            }
        }
        return rows.flatMap { row in row.sorted { frames[$0].minX < frames[$1].minX } }
    }

    /// The nearest frame in a direction from the frame at `index`, favouring ones in line with it.
    static func neighbour(of index: Int, toward direction: HintDirection, in frames: [CGRect]) -> Int? {
        let from = CGPoint(x: frames[index].midX, y: frames[index].midY)
        let scored = frames.indices.compactMap { candidate -> (index: Int, score: CGFloat)? in
            guard candidate != index else { return nil }
            let dx = frames[candidate].midX - from.x
            let dy = frames[candidate].midY - from.y
            let (along, across): (CGFloat, CGFloat) = switch direction {
            case .left: (-dx, dy)
            case .right: (dx, dy)
            case .up: (dy, dx)
            case .down: (-dy, dx)
            }
            guard along > 1 else { return nil }
            return (candidate, along + 2 * abs(across))
        }
        return scored.min { $0.score < $1.score }?.index
    }
}

/// The keyboard grammar while hints are on screen:
///
/// - Typing a label selects its thumbnail. Labels never contain an action letter, so a label
///   followed at once by an action letter works: `sw` closes the window labelled S.
/// - With a thumbnail selected: W closes it, M minimizes it, H hides its app, Q quits its app,
///   A closes all of its app's windows, Return opens it. The arrow keys move the selection.
/// - Delete takes back a typed letter, then the selection. Esc or F ends hints.
///
/// An action letter while a label is half typed only drops the half-typed label, so a slip
/// never acts on the thumbnail that was selected before.
struct HintSession: Equatable {
    enum Outcome: Equatable {
        case changed
        case unchanged
        case perform(HintAction, on: Int)
        case exit
    }

    /// One per target, in reading order.
    let labels: [String]
    /// Targets' frames, for the arrow keys.
    let frames: [CGRect]
    /// The actions each target takes: a Space can be closed or opened, not minimized.
    let allowed: [Set<HintAction>]
    private(set) var typed = ""
    private(set) var selection: Int?

    init(frames: [CGRect], allowed: [Set<HintAction>]) {
        self.frames = frames
        self.allowed = allowed
        labels = HintLabels.make(count: frames.count)
    }

    /// Whether the label at `index` still matches what has been typed.
    func matches(_ index: Int) -> Bool {
        index < labels.count && labels[index].hasPrefix(typed)
    }

    mutating func handle(_ key: HintKey) -> Outcome {
        switch key {
        case .cancel:
            return .exit
        case .letter(HintLabels.toggleLetter):
            return .exit
        case .letter(let letter):
            if let action = HintAction(letter: letter) {
                return perform(action)
            }
            return type(letter)
        case .confirm:
            return perform(.open)
        case .deleteBackward:
            if !typed.isEmpty {
                typed.removeLast()
            } else if selection != nil {
                selection = nil
            } else {
                return .unchanged
            }
            return .changed
        case .move(let direction):
            return move(direction)
        case .other:
            return .unchanged
        }
    }

    private mutating func perform(_ action: HintAction) -> Outcome {
        guard typed.isEmpty else {
            typed = ""
            return .changed
        }
        guard let selection, allowed[selection].contains(action) else { return .unchanged }
        return .perform(action, on: selection)
    }

    /// Adds a letter to the label being typed. A letter that fits no label starts over with
    /// that letter alone.
    private mutating func type(_ letter: Character) -> Outcome {
        let candidates = typed.isEmpty ? [String(letter)] : [typed + String(letter), String(letter)]
        for candidate in candidates {
            if let index = labels.firstIndex(of: candidate) {
                selection = index
                typed = ""
                return .changed
            }
            if labels.contains(where: { $0.hasPrefix(candidate) }) {
                typed = candidate
                return .changed
            }
        }
        guard !typed.isEmpty else { return .unchanged }
        typed = ""
        return .changed
    }

    private mutating func move(_ direction: HintDirection) -> Outcome {
        let hadTyped = !typed.isEmpty
        typed = ""
        guard let selection else {
            guard !labels.isEmpty else { return hadTyped ? .changed : .unchanged }
            self.selection = 0
            return .changed
        }
        guard let next = HintLabels.neighbour(of: selection, toward: direction, in: Array(frames.prefix(labels.count))) else {
            return hadTyped ? .changed : .unchanged
        }
        self.selection = next
        return .changed
    }
}
