@testable import MissionStrike
import Carbon.HIToolbox
import CoreGraphics
import Testing

@MainActor
@Suite("Tap Router: Snapping")
struct TapRouterSnapTests {
    private var state = TapState()
    private var settings = Settings.defaults
    private let environment = FakeTapEnvironment()

    init() {
        settings.snapShortcuts = SnapShortcuts(SnapShortcuts.defaults)
        environment.missionControlActive = false
    }

    private mutating func decide(_ event: TapEvent) -> TapDecision {
        TapRouter.decide(event, state: &state, settings: settings, environment: environment, debounceInterval: 0.3)
    }

    private func key(_ keyCode: Int, _ flags: CGEventFlags = [.maskControl, .maskAlternate], isAutorepeat: Bool = false) -> TapEvent {
        TapEvent(type: .keyDown, flags: flags, keyCode: Int64(keyCode), isAutorepeat: isAutorepeat)
    }

    @Test("A snap shortcut is swallowed and snaps")
    mutating func snaps() {
        #expect(decide(key(kVK_LeftArrow)) == .snap(.left))
        #expect(decide(key(kVK_UpArrow)) == .snap(.maximize))
        #expect(decide(key(kVK_DownArrow)) == .snap(.restore))
    }

    @Test("Other keys never ask whether Mission Control is open")
    mutating func otherKeysAreCheap() {
        #expect(decide(key(kVK_LeftArrow, [.maskControl])) == .pass)
        #expect(decide(key(kVK_ANSI_A)) == .pass)
        #expect(environment.missionControlChecks == 0)
    }

    @Test("A held shortcut snaps once")
    mutating func autorepeat() {
        #expect(decide(key(kVK_LeftArrow, isAutorepeat: true)) == .swallow)
    }

    @Test("In Mission Control, or while Settings records a shortcut, the key goes its way")
    mutating func passesThrough() {
        environment.missionControlActive = true
        #expect(decide(key(kVK_LeftArrow)) == .pass)
        environment.missionControlActive = false
        environment.isRecordingShortcut = true
        #expect(decide(key(kVK_LeftArrow)) == .pass)
    }

    @Test("In Mission Control, a snap shortcut that is also ⌘W keeps its Mission Control meaning")
    mutating func missionControlMeaning() {
        settings.snapShortcuts = SnapShortcuts([.left: KeyShortcut(keyCode: Int64(kVK_ANSI_W), flags: .maskCommand)])
        environment.missionControlActive = true
        #expect(decide(key(kVK_ANSI_W, .maskCommand)) == .shortcut(.closeWindow, isRepeat: false))
    }

    @Test("With snapping off, the shortcuts are ordinary keys")
    mutating func off() {
        settings.snapShortcuts = SnapShortcuts()
        #expect(decide(key(kVK_LeftArrow)) == .pass)
    }
}

@MainActor
@Suite("Tap Router: Snap Assist")
struct TapRouterSnapAssistTests {
    private var state = TapState()
    private var settings = Settings.defaults
    private let environment = FakeTapEnvironment()

    init() {
        settings.snapShortcuts = SnapShortcuts(SnapShortcuts.defaults)
        environment.missionControlActive = false
        environment.snapAssistPhase = .showing
        environment.snapAssistFrame = CGRect(x: 720, y: 0, width: 720, height: 900)
        environment.snapAssistCards = [CGRect(x: 800, y: 100, width: 200, height: 120)]
    }

    private mutating func decide(_ event: TapEvent) -> TapDecision {
        TapRouter.decide(event, state: &state, settings: settings, environment: environment, debounceInterval: 0.3)
    }

    private func key(_ keyCode: Int, _ flags: CGEventFlags = []) -> TapEvent {
        TapEvent(type: .keyDown, flags: flags, keyCode: Int64(keyCode))
    }

    @Test("Number keys pick by key code, Esc closes, and other keys close and pass")
    mutating func keys() {
        #expect(decide(key(kVK_ANSI_1)) == .snapAssist(.pick(0)))
        #expect(decide(key(kVK_ANSI_Keypad9)) == .snapAssist(.pick(8)))
        #expect(decide(key(kVK_Escape)) == .snapAssist(.cancel))
        #expect(decide(key(kVK_ANSI_A)) == .snapAssist(.dismiss))
        #expect(!TapDecision.snapAssist(.dismiss).swallows)
        #expect(decide(key(kVK_ANSI_1, .maskCommand)) == .snapAssist(.dismiss))
    }

    @Test("Arrows move the ring and keep moving while held; Return picks")
    mutating func arrowsAndReturn() {
        #expect(decide(key(kVK_RightArrow)) == .snapAssist(.move(.right)))
        #expect(decide(TapEvent(type: .keyDown, keyCode: Int64(kVK_RightArrow), isAutorepeat: true)) == .snapAssist(.move(.right)))
        #expect(decide(key(kVK_Return)) == .snapAssist(.confirm))
        #expect(decide(key(kVK_ANSI_KeypadEnter)) == .snapAssist(.confirm))
    }

    @Test("Another snap shortcut snaps again instead of closing the picker")
    mutating func snapAgain() {
        #expect(decide(key(kVK_LeftArrow, [.maskControl, .maskAlternate])) == .snap(.left))
    }

    @Test("A click on a card picks it and swallows its release; elsewhere on the picker it's swallowed")
    mutating func clicksOnPicker() {
        #expect(decide(TapEvent(type: .leftMouseDown, pointer: CGPoint(x: 850, y: 150))) == .snapAssist(.pick(0)))
        #expect(decide(TapEvent(type: .leftMouseUp)) == .swallow)
        #expect(decide(TapEvent(type: .leftMouseDown, pointer: CGPoint(x: 1200, y: 800))) == .swallow)
        #expect(decide(TapEvent(type: .leftMouseUp)) == .swallow)
    }

    @Test("A held number or Esc repeats into nothing once the picker has closed")
    mutating func heldKeys() {
        #expect(decide(key(kVK_ANSI_2)) == .snapAssist(.pick(1)))
        environment.snapAssistPhase = .idle
        #expect(decide(TapEvent(type: .keyDown, keyCode: Int64(kVK_ANSI_2), isAutorepeat: true)) == .swallow)
        #expect(decide(key(kVK_ANSI_2)) == .pass)
        #expect(decide(TapEvent(type: .keyDown, keyCode: Int64(kVK_ANSI_2), isAutorepeat: true)) == .pass)
    }

    @Test("Before the picker is up, a number waits for it, Esc cancels it, and anything else closes it and goes its way")
    mutating func pending() {
        environment.snapAssistPhase = .pending
        #expect(decide(key(kVK_ANSI_1)) == .snapAssist(.pick(0)))
        #expect(decide(key(kVK_Escape)) == .snapAssist(.cancel))
        #expect(decide(key(kVK_LeftArrow)) == .snapAssist(.dismiss))
        #expect(decide(key(kVK_Return)) == .snapAssist(.dismiss))
        #expect(decide(key(kVK_ANSI_A)) == .snapAssist(.dismiss))
        #expect(decide(TapEvent(type: .leftMouseDown, pointer: CGPoint(x: 850, y: 150))) == .snapAssist(.dismiss))
        #expect(decide(TapEvent(type: .leftMouseUp)) == .pass)
    }

    @Test("While the picker shows, keys and clicks never ask whether Mission Control is open")
    mutating func showingIsCheap() {
        _ = decide(key(kVK_ANSI_1))
        _ = decide(TapEvent(type: .leftMouseDown, pointer: CGPoint(x: 850, y: 150)))
        #expect(environment.missionControlChecks == 0)
    }

    @Test("A click outside the picker closes it and goes its way")
    mutating func clickOutside() {
        #expect(decide(TapEvent(type: .leftMouseDown, pointer: CGPoint(x: 100, y: 100))) == .snapAssist(.dismiss))
        #expect(decide(TapEvent(type: .leftMouseUp)) == .pass)
    }
}
