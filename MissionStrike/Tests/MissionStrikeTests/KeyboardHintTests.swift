@testable import MissionStrike
import Carbon.HIToolbox
import CoreGraphics
import Testing

@Suite("Keyboard Hints")
struct KeyboardHintTests {

    // MARK: - Labels

    @Test("Up to one label per letter, all single letters in alphabet order")
    func singleLetters() {
        #expect(HintLabels.make(count: 0).isEmpty)
        #expect(HintLabels.make(count: 3) == ["s", "d", "j"])
        #expect(HintLabels.make(count: 20).count == 20)
        #expect(HintLabels.make(count: 20).allSatisfy { $0.count == 1 })
    }

    @Test("Past the alphabet, the last letters become prefixes of two-letter labels")
    func twoLetters() {
        let labels = HintLabels.make(count: 21)
        #expect(labels.count == 21)
        #expect(labels.prefix(19).allSatisfy { $0.count == 1 })
        #expect(labels.suffix(2) == ["zs", "zd"])
        #expect(!labels.contains("z"))
    }

    @Test("Labels are unique and none starts another, for any count", arguments: [1, 7, 20, 21, 39, 40, 57, 200, 400])
    func prefixFree(count: Int) {
        let labels = HintLabels.make(count: count)
        #expect(labels.count == count)
        #expect(Set(labels).count == labels.count)
        for label in labels {
            #expect(!labels.contains { $0 != label && $0.hasPrefix(label) })
        }
    }

    @Test("There are never more labels than two letters allow")
    func cap() {
        #expect(HintLabels.make(count: 1000).count == 400)
    }

    @Test("Labels never use an action letter or F")
    func noActionLetters() {
        let used = Set(HintLabels.make(count: 400).joined())
        for letter in "wmhqaf" {
            #expect(!used.contains(letter))
        }
        #expect(HintAction.allCases.compactMap(\.letter).allSatisfy { !HintLabels.alphabet.contains($0) })
    }

    // MARK: - Keys

    @Test("Letters come from what the layout types, lowercased")
    func layoutLetters() {
        #expect(HintKey(keyCode: Int64(kVK_ANSI_S), characters: "s") == .letter("s"))
        #expect(HintKey(keyCode: Int64(kVK_ANSI_S), characters: "S") == .letter("s"))
        // AZERTY: the key where QWERTY has Q types A.
        #expect(HintKey(keyCode: Int64(kVK_ANSI_Q), characters: "a") == .letter("a"))
        // AZERTY: the key where QWERTY has M types a comma, which is no letter.
        #expect(HintKey(keyCode: Int64(kVK_ANSI_M), characters: ",") == .other)
    }

    @Test("Layouts without Latin letters use the US letter on the key")
    func nonLatinLetters() {
        #expect(HintKey(keyCode: Int64(kVK_ANSI_F), characters: "а") == .letter("f"))
        #expect(HintKey(keyCode: Int64(kVK_ANSI_2), characters: "é") == .other)
    }

    @Test("Return, Esc, Delete and the arrows")
    func specialKeys() {
        #expect(HintKey(keyCode: Int64(kVK_Return), characters: "\r") == .confirm)
        #expect(HintKey(keyCode: Int64(kVK_ANSI_KeypadEnter), characters: "\u{3}") == .confirm)
        #expect(HintKey(keyCode: Int64(kVK_Escape), characters: "\u{1B}") == .cancel)
        #expect(HintKey(keyCode: Int64(kVK_Delete), characters: "\u{7F}") == .deleteBackward)
        #expect(HintKey(keyCode: Int64(kVK_LeftArrow), characters: "") == .move(.left))
        #expect(HintKey(keyCode: Int64(kVK_UpArrow), characters: "") == .move(.up))
        #expect(HintKey(keyCode: Int64(kVK_Space), characters: " ") == .other)
    }

    // MARK: - Layout

    /// Two rows in AppKit coordinates (higher Y is higher on screen), listed out of order.
    private let grid = [
        CGRect(x: 600, y: 100, width: 300, height: 200), // bottom right
        CGRect(x: 100, y: 500, width: 300, height: 200), // top left
        CGRect(x: 100, y: 110, width: 300, height: 180), // bottom left, a little lower
        CGRect(x: 600, y: 520, width: 300, height: 160) // top right, a little shorter
    ]

    @Test("Reading order: rows from the top, each left to right")
    func readingOrder() {
        #expect(HintLabels.readingOrder(grid) == [1, 3, 2, 0])
        #expect(HintLabels.readingOrder([]).isEmpty)
    }

    @Test("Arrows move to the nearest frame in line")
    func neighbours() {
        #expect(HintLabels.neighbour(of: 1, toward: .right, in: grid) == 3)
        #expect(HintLabels.neighbour(of: 1, toward: .down, in: grid) == 2)
        #expect(HintLabels.neighbour(of: 0, toward: .up, in: grid) == 3)
        #expect(HintLabels.neighbour(of: 0, toward: .left, in: grid) == 2)
        #expect(HintLabels.neighbour(of: 1, toward: .left, in: grid) == nil)
        #expect(HintLabels.neighbour(of: 1, toward: .up, in: grid) == nil)
    }

    // MARK: - Grammar

    private static let window = Set(HintAction.allCases)

    private func session(count: Int, allowed: Set<HintAction> = window) -> HintSession {
        let frames = (0..<count).map { CGRect(x: CGFloat($0 % 10) * 200, y: CGFloat($0 / 10) * -200, width: 150, height: 100) }
        return HintSession(frames: frames, allowed: Array(repeating: allowed, count: count))
    }

    @Test("A label selects its thumbnail, and an action letter acts on it")
    func selectThenAct() {
        var hints = session(count: 3)
        #expect(hints.handle(.letter("d")) == .changed)
        #expect(hints.selection == 1)
        #expect(hints.handle(.letter("w")) == .perform(.close, on: 1))
        #expect(hints.handle(.letter("m")) == .perform(.minimize, on: 1))
        #expect(hints.handle(.letter("h")) == .perform(.hide, on: 1))
        #expect(hints.handle(.letter("q")) == .perform(.quit, on: 1))
        #expect(hints.handle(.letter("a")) == .perform(.closeAll, on: 1))
        #expect(hints.handle(.confirm) == .perform(.open, on: 1))
    }

    @Test("Without a selection, actions do nothing")
    func actionWithoutSelection() {
        var hints = session(count: 3)
        #expect(hints.handle(.letter("w")) == .unchanged)
        #expect(hints.handle(.confirm) == .unchanged)
    }

    @Test("Two-letter labels select on their second letter")
    func twoLetterLabel() {
        var hints = session(count: 25)
        let label = hints.labels[24]
        #expect(label.count == 2)
        let letters = Array(label)
        #expect(hints.handle(.letter(letters[0])) == .changed)
        #expect(hints.typed == String(letters[0]))
        #expect(hints.selection == nil)
        #expect(hints.matches(24))
        #expect(!hints.matches(0))
        #expect(hints.handle(.letter(letters[1])) == .changed)
        #expect(hints.selection == 24)
        #expect(hints.typed.isEmpty)
        #expect(hints.handle(.letter("w")) == .perform(.close, on: 24))
    }

    @Test("A letter that fits no label starts a new one")
    func startOver() {
        var hints = session(count: 25)
        #expect(hints.labels.suffix(6) == ["zs", "zd", "zj", "zk", "zl", "zg"])
        _ = hints.handle(.letter("z"))
        // No label starts "zz", but "z" starts some.
        #expect(hints.handle(.letter("z")) == .changed)
        #expect(hints.typed == "z")
        // No label starts "zx", but "x" alone is one.
        #expect(hints.handle(.letter("x")) == .changed)
        #expect(hints.typed.isEmpty)
        #expect(hints.selection == 18)
    }

    @Test("Letters outside every label are ignored")
    func unusedLetter() {
        var hints = session(count: 3)
        #expect(hints.handle(.letter("z")) == .unchanged)
        #expect(hints.selection == nil)
    }

    @Test("An action letter while a label is half typed only drops the half")
    func actionMidLabel() {
        var hints = session(count: 25)
        _ = hints.handle(.letter("s"))
        let prefix = Array(hints.labels[24])[0]
        _ = hints.handle(.letter(prefix))
        #expect(hints.handle(.letter("w")) == .changed)
        #expect(hints.typed.isEmpty)
        #expect(hints.selection == 0)
        #expect(hints.handle(.letter("w")) == .perform(.close, on: 0))
    }

    @Test("Delete takes back a typed letter, then the selection")
    func deleteBackward() {
        var hints = session(count: 25)
        _ = hints.handle(.letter("s"))
        _ = hints.handle(.letter(Array(hints.labels[24])[0]))
        #expect(hints.handle(.deleteBackward) == .changed)
        #expect(hints.typed.isEmpty && hints.selection == 0)
        #expect(hints.handle(.deleteBackward) == .changed)
        #expect(hints.selection == nil)
        #expect(hints.handle(.deleteBackward) == .unchanged)
    }

    @Test("Arrows select the first thumbnail, then move the selection")
    func arrows() {
        var hints = session(count: 3)
        #expect(hints.handle(.move(.right)) == .changed)
        #expect(hints.selection == 0)
        #expect(hints.handle(.move(.right)) == .changed)
        #expect(hints.selection == 1)
        #expect(hints.handle(.move(.up)) == .unchanged)
        #expect(hints.handle(.move(.left)) == .changed)
        #expect(hints.selection == 0)
    }

    @Test("Esc and F end hints")
    func exit() {
        var hints = session(count: 3)
        #expect(hints.handle(.cancel) == .exit)
        #expect(hints.handle(.letter("f")) == .exit)
    }

    @Test("A thumbnail only takes the actions it allows")
    func allowedActions() {
        var hints = session(count: 2, allowed: [.close, .open])
        _ = hints.handle(.letter("s"))
        #expect(hints.handle(.letter("m")) == .unchanged)
        #expect(hints.handle(.letter("w")) == .perform(.close, on: 0))
        #expect(hints.handle(.confirm) == .perform(.open, on: 0))
    }

    @Test("Other keys change nothing")
    func otherKeys() {
        var hints = session(count: 3)
        #expect(hints.handle(.other) == .unchanged)
    }

    // MARK: - Legend

    @Test("The legend shows how to pick, then what the selection can do")
    func legend() {
        #expect(KeyboardHints.legend(for: nil).map(\.key) == [nil, "esc"])
        #expect(KeyboardHints.legend(for: Set(HintAction.allCases)).map(\.key) == ["W", "M", "H", "Q", "A", "↩", "esc"])
        #expect(KeyboardHints.legend(for: [.close, .open]).map(\.text) == ["Close", "Open", "Stop"])
    }
}
