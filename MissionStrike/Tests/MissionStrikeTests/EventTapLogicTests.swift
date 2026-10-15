@testable import MissionStrike
import Carbon.HIToolbox
import CoreGraphics
import Testing

@Suite("Mouse Action")
struct MouseActionTests {

    @Test("No action modifier closes the window")
    func plainClose() {
        #expect(MouseAction(flags: []) == .close)
        #expect(MouseAction(flags: .maskAlternate) == .close)
    }

    @Test("⇧ minimizes, ⌘ closes all, and ⌘ wins over ⇧")
    func actionModifiers() {
        #expect(MouseAction(flags: .maskShift) == .minimize)
        #expect(MouseAction(flags: .maskCommand) == .closeAll)
        #expect(MouseAction(flags: [.maskCommand, .maskShift]) == .closeAll)
    }

    @Test("The hover badge shows what the click will do")
    func hoverBadgeMatchesAction() {
        #expect(HoverBadgeStyle(flags: [.maskAlternate]) == .close)
        #expect(HoverBadgeStyle(flags: [.maskAlternate, .maskShift]) == .minimize)
        #expect(HoverBadgeStyle(flags: [.maskAlternate, .maskCommand]) == .closeAll)
    }
}

@Suite("Click Trigger")
struct ClickTriggerTests {

    private func matches(
        _ type: CGEventType,
        button: Int64 = 0,
        flags: CGEventFlags = [],
        middleClick: Bool = true,
        modifier: TriggerModifier? = TriggerModifier.option
    ) -> Bool {
        ClickTrigger.matches(
            type: type,
            buttonNumber: button,
            flags: flags,
            middleClickEnabled: middleClick,
            leftClickModifier: modifier
        )
    }

    @Test("Middle-click triggers only when enabled, and only for button 2")
    func middleClick() {
        #expect(matches(.otherMouseDown, button: 2))
        #expect(!matches(.otherMouseDown, button: 2, middleClick: false))
        #expect(!matches(.otherMouseDown, button: 3))
    }

    @Test("Left-click triggers only with the configured modifier")
    func leftClick() {
        #expect(matches(.leftMouseDown, flags: .maskAlternate))
        #expect(matches(.leftMouseDown, flags: [.maskAlternate, .maskShift]))
        #expect(!matches(.leftMouseDown))
        #expect(!matches(.leftMouseDown, flags: .maskControl))
        #expect(matches(.leftMouseDown, flags: .maskControl, modifier: TriggerModifier.control))
    }

    @Test("A disabled or unknown modifier never triggers")
    func disabledModifier() {
        #expect(!matches(.leftMouseDown, flags: .maskAlternate, modifier: TriggerModifier.disabled))
        #expect(!matches(.leftMouseDown, flags: .maskAlternate, modifier: nil))
    }

    @Test("Right-clicks are not click triggers")
    func rightClick() {
        #expect(!matches(.rightMouseDown, flags: .maskAlternate))
    }
}

@Suite("Swallowed Mouse-Ups")
struct SwallowedMouseUpsTests {

    @Test("The release of a swallowed press is swallowed once")
    func swallowOnce() {
        var ups = SwallowedMouseUps()
        ups.swallowRelease(of: .rightMouseDown)
        let swallowed1 = ups.consume(.rightMouseUp)
        #expect(swallowed1)
        let swallowed2 = ups.consume(.rightMouseUp)
        #expect(!swallowed2)
    }

    @Test("Other buttons' releases pass through")
    func otherButtons() {
        var ups = SwallowedMouseUps()
        ups.swallowRelease(of: .otherMouseDown)
        let swallowed3 = ups.consume(.leftMouseUp)
        #expect(!swallowed3)
        let swallowed4 = ups.consume(.rightMouseUp)
        #expect(!swallowed4)
        let swallowed5 = ups.consume(.otherMouseUp)
        #expect(swallowed5)
    }

    @Test("A new press forgets a release that never arrived")
    func lostRelease() {
        var ups = SwallowedMouseUps()
        ups.swallowRelease(of: .leftMouseDown)
        ups.forgetLostRelease(beforePress: .leftMouseDown)
        let swallowed6 = ups.consume(.leftMouseUp)
        #expect(!swallowed6)
    }

    @Test("A press only forgets its own button's release")
    func lostReleaseOtherButton() {
        var ups = SwallowedMouseUps()
        ups.swallowRelease(of: .leftMouseDown)
        ups.forgetLostRelease(beforePress: .rightMouseDown)
        let swallowed7 = ups.consume(.leftMouseUp)
        #expect(swallowed7)
    }

    @Test("Only ups count as mouse-ups")
    func isMouseUp() {
        #expect(SwallowedMouseUps.isMouseUp(.leftMouseUp))
        #expect(SwallowedMouseUps.isMouseUp(.otherMouseUp))
        #expect(!SwallowedMouseUps.isMouseUp(.leftMouseDown))
        #expect(!SwallowedMouseUps.isMouseUp(.keyDown))
    }
}

@Suite("Mission Control Shortcuts")
struct MissionControlShortcutTests {

    @Test("⌘W, ⌘M, ⌘H and ⌘Q map to their actions")
    func mappedKeys() {
        #expect(MissionControlShortcut(keyCode: Int64(kVK_ANSI_W), flags: .maskCommand) == .closeWindow)
        #expect(MissionControlShortcut(keyCode: Int64(kVK_ANSI_M), flags: .maskCommand) == .minimizeWindow)
        #expect(MissionControlShortcut(keyCode: Int64(kVK_ANSI_H), flags: .maskCommand) == .hideApp)
        #expect(MissionControlShortcut(keyCode: Int64(kVK_ANSI_Q), flags: .maskCommand) == .quitApp)
    }

    @Test("Other keys are left alone")
    func unmappedKey() {
        #expect(MissionControlShortcut(keyCode: Int64(kVK_ANSI_A), flags: .maskCommand) == nil)
    }

    @Test("Only ⌘ on its own counts; ⌥⌘H and ⇧⌘W pass through")
    func extraModifiers() {
        #expect(MissionControlShortcut(keyCode: Int64(kVK_ANSI_W), flags: []) == nil)
        #expect(MissionControlShortcut(keyCode: Int64(kVK_ANSI_W), flags: [.maskCommand, .maskShift]) == nil)
        #expect(MissionControlShortcut(keyCode: Int64(kVK_ANSI_H), flags: [.maskCommand, .maskAlternate]) == nil)
    }

    @Test("Caps Lock and other non-modifier flags don't block a shortcut")
    func ignoresOtherFlags() {
        #expect(MissionControlShortcut(keyCode: Int64(kVK_ANSI_W), flags: [.maskCommand, .maskAlphaShift]) == .closeWindow)
    }
}
