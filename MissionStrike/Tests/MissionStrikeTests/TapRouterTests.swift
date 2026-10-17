@testable import MissionStrike
import Carbon.HIToolbox
import CoreGraphics
import Testing

/// Answers `TapRouter`'s questions from fixed values and counts the Mission Control checks.
@MainActor
private final class FakeTapEnvironment: TapEnvironment {
    var missionControlActive = true
    var isContextMenuOpen = false
    var menuFrame: CGRect = .null
    var dock: DockSnapshot.Verdict = .elsewhere
    var isKeyboardHintsActive = false
    var isCheatSheetPinned = false
    private(set) var missionControlChecks = 0

    func isMissionControlActive() -> Bool {
        missionControlChecks += 1
        return missionControlActive
    }

    func menuContains(_ point: CGPoint) -> Bool {
        menuFrame.contains(point)
    }

    func dockVerdict(for event: TapEvent) -> DockSnapshot.Verdict {
        dock
    }
}

@MainActor
@Suite("Tap Router")
struct TapRouterTests {
    private var state = TapState()
    private var settings = Settings.defaults
    private let environment = FakeTapEnvironment()

    private mutating func decide(_ event: TapEvent) -> TapDecision {
        TapRouter.decide(event, state: &state, settings: settings, environment: environment, debounceInterval: 0.3)
    }

    private func middleDown(at time: Double = 10, flags: CGEventFlags = []) -> TapEvent {
        TapEvent(type: .otherMouseDown, buttonNumber: 2, flags: flags, time: time)
    }

    private func optionClick(at time: Double = 10) -> TapEvent {
        TapEvent(type: .leftMouseDown, flags: .maskAlternate, time: time)
    }

    // MARK: - Mission Control clicks

    @Test("A middle-click in Mission Control is swallowed and resolved later, release included")
    mutating func middleClickInMissionControl() {
        #expect(decide(middleDown()) == .missionControlClick(.close, input: "middle-click", probeDock: false))
        #expect(decide(TapEvent(type: .otherMouseUp)) == .swallow)
        #expect(decide(TapEvent(type: .otherMouseUp)) == .pass)
    }

    @Test("A modifier-click carries the action its modifiers ask for")
    mutating func modifierClickAction() {
        let event = TapEvent(type: .leftMouseDown, flags: [.maskAlternate, .maskShift], time: 10)
        #expect(decide(event) == .missionControlClick(.minimize, input: "modifier-click", probeDock: false))
    }

    @Test("Outside Mission Control, triggers pass through and their release too")
    mutating func outsideMissionControl() {
        environment.missionControlActive = false
        #expect(decide(middleDown()) == .pass)
        #expect(decide(TapEvent(type: .otherMouseUp)) == .pass)
    }

    @Test("Plain clicks never ask whether Mission Control is open")
    mutating func plainClickIsCheap() {
        #expect(decide(TapEvent(type: .leftMouseDown, time: 10)) == .pass)
        #expect(environment.missionControlChecks == 0)
    }

    // MARK: - Debounce

    @Test("A second click within the debounce interval is swallowed with its release")
    mutating func debounce() {
        #expect(decide(optionClick(at: 10)).swallows)
        #expect(decide(TapEvent(type: .leftMouseUp)) == .swallow)

        #expect(decide(optionClick(at: 10.1)) == .swallow)
        #expect(decide(TapEvent(type: .leftMouseUp)) == .swallow)

        #expect(decide(optionClick(at: 10.5)) == .missionControlClick(.close, input: "modifier-click", probeDock: false))
    }

    @Test("Debounced clicks don't extend the debounce window")
    mutating func debounceWindowFixed() {
        _ = decide(optionClick(at: 10))
        _ = decide(optionClick(at: 10.2))
        #expect(decide(optionClick(at: 10.35)).swallows)
        #expect(state.lastProcessedClick == 10.35)
    }

    // MARK: - Releases

    @Test("A press forgets a swallowed release that never arrived")
    mutating func lostRelease() {
        _ = decide(middleDown(at: 10))
        environment.missionControlActive = false
        #expect(decide(middleDown(at: 20)) == .pass)
        #expect(decide(TapEvent(type: .otherMouseUp)) == .pass)
    }

    // MARK: - Context menu

    @Test("Right-click in Mission Control opens the menu and swallows its release")
    mutating func rightClickOpensMenu() {
        #expect(decide(TapEvent(type: .rightMouseDown)) == .openMenu)
        #expect(decide(TapEvent(type: .rightMouseUp)) == .swallow)
    }

    @Test("Right-click passes when the menu is off or Mission Control is closed")
    mutating func rightClickPasses() {
        settings.enableContextMenu = false
        #expect(decide(TapEvent(type: .rightMouseDown)) == .pass)
        settings.enableContextMenu = true
        environment.missionControlActive = false
        #expect(decide(TapEvent(type: .rightMouseDown)) == .pass)
    }

    @Test("With the menu open, clicks on it pass and clicks elsewhere close it")
    mutating func menuOpen() {
        environment.isContextMenuOpen = true
        environment.menuFrame = CGRect(x: 100, y: 100, width: 200, height: 300)

        #expect(decide(TapEvent(type: .leftMouseDown, location: CGPoint(x: 150, y: 150))) == .pass)
        #expect(decide(TapEvent(type: .leftMouseUp)) == .pass)

        #expect(decide(TapEvent(type: .leftMouseDown, location: .zero)) == .closeMenu(reopen: false))
        #expect(decide(TapEvent(type: .leftMouseUp)) == .swallow)

        #expect(decide(TapEvent(type: .rightMouseDown, location: .zero)) == .closeMenu(reopen: true))
        #expect(decide(TapEvent(type: .rightMouseUp)) == .swallow)
    }

    @Test("With the menu open, a trigger click only closes the menu")
    mutating func menuOpenTrigger() {
        environment.isContextMenuOpen = true
        #expect(decide(middleDown()) == .closeMenu(reopen: false))
    }

    // MARK: - Dock

    @Test("A middle-click on a running app's Dock icon beats Mission Control")
    mutating func dockPrecedence() {
        settings.enableDockMiddleClick = true
        environment.dock = .runningApp
        #expect(decide(middleDown(flags: .maskAlternate)) == .dockClick(closeWindowsOnly: true))
        #expect(decide(TapEvent(type: .otherMouseUp)) == .swallow)
        #expect(environment.missionControlChecks == 0)
    }

    @Test("When the Dock can't tell, the click goes its usual way with a probe")
    mutating func dockMaybe() {
        settings.enableDockMiddleClick = true
        environment.dock = .maybe
        #expect(decide(middleDown(at: 10)) == .missionControlClick(.close, input: "middle-click", probeDock: true))

        environment.missionControlActive = false
        #expect(decide(middleDown(at: 20)) == .passAndProbeDock(closeWindowsOnly: false))
    }

    @Test("Dock middle-click off, or another button: the Dock isn't consulted")
    mutating func dockOff() {
        environment.dock = .runningApp
        #expect(decide(middleDown()) == .missionControlClick(.close, input: "middle-click", probeDock: false))
        settings.enableDockMiddleClick = true
        environment.missionControlActive = false
        #expect(decide(TapEvent(type: .otherMouseDown, buttonNumber: 3, time: 20)) == .pass)
    }

    // MARK: - Keys

    @Test("⌘W in Mission Control is swallowed to be resolved later")
    mutating func shortcut() {
        let key = TapEvent(type: .keyDown, flags: .maskCommand, keyCode: Int64(kVK_ANSI_W))
        #expect(decide(key) == .shortcut(.closeWindow, isRepeat: false))
        var repeated = key
        repeated.isAutorepeat = true
        #expect(decide(repeated) == .shortcut(.closeWindow, isRepeat: true))
    }

    @Test("Shortcuts pass when off, outside Mission Control, or for other keys")
    mutating func shortcutPasses() {
        let key = TapEvent(type: .keyDown, flags: .maskCommand, keyCode: Int64(kVK_ANSI_W))
        #expect(decide(TapEvent(type: .keyDown, flags: .maskCommand, keyCode: Int64(kVK_ANSI_A))) == .pass)
        settings.enableKeyboardShortcuts = false
        #expect(decide(key) == .pass)
        settings.enableKeyboardShortcuts = true
        environment.missionControlActive = false
        #expect(decide(key) == .pass)
    }

    // MARK: - Overlay keys

    private func key(_ code: Int, _ characters: String, flags: CGEventFlags = [], isRepeat: Bool = false) -> TapEvent {
        TapEvent(type: .keyDown, flags: flags, keyCode: Int64(code), isAutorepeat: isRepeat, characters: characters)
    }

    @Test("F in Mission Control starts keyboard hints; F held down doesn't start them again")
    mutating func startHints() {
        #expect(decide(key(kVK_ANSI_F, "f")) == .startKeyboardHints)
        #expect(decide(key(kVK_ANSI_F, "F", flags: .maskShift)) == .startKeyboardHints)
        #expect(decide(key(kVK_ANSI_F, "f", isRepeat: true)) == .pass)
        #expect(decide(key(kVK_ANSI_F, "ƒ", flags: .maskAlternate)) == .pass)
    }

    @Test("F passes outside Mission Control or with keyboard hints off")
    mutating func startHintsPasses() {
        settings.enableKeyboardHints = false
        #expect(decide(key(kVK_ANSI_F, "f")) == .pass)
        settings.enableKeyboardHints = true
        environment.missionControlActive = false
        #expect(decide(key(kVK_ANSI_F, "f")) == .pass)
    }

    @Test("Typing anything else never asks whether Mission Control is open")
    mutating func plainTypingIsCheap() {
        #expect(decide(key(kVK_ANSI_S, "s")) == .pass)
        #expect(decide(key(kVK_Escape, "\u{1B}")) == .pass)
        #expect(decide(key(kVK_Return, "\r")) == .pass)
        #expect(environment.missionControlChecks == 0)
    }

    @Test("While keyboard hints are up, every plain key is theirs, repeats too")
    mutating func hintKeys() {
        environment.isKeyboardHintsActive = true
        #expect(decide(key(kVK_ANSI_S, "s")) == .keyboardHint(.letter("s"), isRepeat: false))
        #expect(decide(key(kVK_ANSI_W, "W", flags: .maskShift)) == .keyboardHint(.letter("w"), isRepeat: false))
        #expect(decide(key(kVK_DownArrow, "", flags: [.maskNumericPad, .maskSecondaryFn], isRepeat: true))
            == .keyboardHint(.move(.down), isRepeat: true))
        #expect(decide(key(kVK_ANSI_Slash, "?", flags: .maskShift)) == .keyboardHint(.other, isRepeat: false))
    }

    @Test("While keyboard hints are up, ⌘ keys still reach the shortcuts")
    mutating func hintsLeaveShortcuts() {
        environment.isKeyboardHintsActive = true
        #expect(decide(key(kVK_ANSI_W, "w", flags: .maskCommand)) == .shortcut(.closeWindow, isRepeat: false))
    }

    @Test("Once Mission Control has closed, keys pass even if hints think they're up")
    mutating func hintKeysAfterClose() {
        environment.isKeyboardHintsActive = true
        environment.missionControlActive = false
        #expect(decide(key(kVK_ANSI_S, "s")) == .pass)
    }

    @Test("? toggles the cheat sheet, whatever key types it")
    mutating func cheatSheetKey() {
        #expect(decide(key(kVK_ANSI_Slash, "?", flags: .maskShift)) == .toggleCheatSheet)
        #expect(decide(key(kVK_ANSI_M, "?", flags: .maskShift)) == .toggleCheatSheet)
        #expect(decide(key(kVK_ANSI_Slash, "?", flags: .maskShift, isRepeat: true)) == .pass)
        settings.showCheatSheet = false
        #expect(decide(key(kVK_ANSI_Slash, "?", flags: .maskShift)) == .pass)
    }

    @Test("Esc closes a cheat sheet opened with ?, and otherwise goes to Mission Control")
    mutating func cheatSheetEscape() {
        #expect(decide(key(kVK_Escape, "\u{1B}")) == .pass)
        environment.isCheatSheetPinned = true
        #expect(decide(key(kVK_Escape, "\u{1B}")) == .closeCheatSheet)
        #expect(decide(key(kVK_ANSI_S, "s")) == .pass)
    }

    @Test("Modifier changes pass and drive the hover badge")
    mutating func modifiers() {
        let decision = decide(TapEvent(type: .flagsChanged, flags: .maskAlternate))
        #expect(decision == .modifiersChanged(.maskAlternate))
        #expect(!decision.swallows)
    }
}
