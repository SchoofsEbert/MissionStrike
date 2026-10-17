import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Standard window shortcuts applied to the thumbnail under the cursor in Mission Control.
enum MissionControlShortcut: Sendable {
    case closeWindow
    case minimizeWindow
    case hideApp
    case quitApp

    /// The shortcut for a ⌘-key press, or nil for keys MissionStrike leaves alone.
    init?(keyCode: Int64) {
        switch Int(keyCode) {
        case kVK_ANSI_W: self = .closeWindow
        case kVK_ANSI_M: self = .minimizeWindow
        case kVK_ANSI_H: self = .hideApp
        case kVK_ANSI_Q: self = .quitApp
        default: return nil
        }
    }

    /// The shortcut for a key press with exactly ⌘ held; nil for anything else.
    init?(keyCode: Int64, flags: CGEventFlags) {
        let modifiers = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard modifiers == .maskCommand else { return nil }
        self.init(keyCode: keyCode)
    }

    /// Whether the shortcut can act on what the hit-test found: only ⌘W acts on a Space,
    /// and only while Space closing is on.
    func applies(to target: MissionControlHitTester.Target, spaceClosingEnabled: Bool) -> Bool {
        guard case .removeDesktop = target else { return true }
        return self == .closeWindow && spaceClosingEnabled
    }
}

/// Marks key presses MissionStrike posts again after deciding not to act on them, so the
/// tap lets them through. Hardware events carry 0 here.
let replayedEventMarker: Int64 = 0x4D53_5452

extension MissionControlManager {
    /// ⌘W / ⌘M / ⌘H / ⌘Q act on the hovered thumbnail while Mission Control is open.
    /// `TapRouter` swallows the key, since only an Accessibility hit-test can tell whether a
    /// thumbnail takes it, and that must not hold up the event tap. This runs once the callback
    /// has returned: it acts on the hovered thumbnail, or posts the key again when there is
    /// nothing for it to act on, so the key reaches the system as if it had passed through.
    func handle(_ shortcut: MissionControlShortcut, isRepeat: Bool, at pointer: CGPoint, replay: CGEvent) {
        let hit = MissionControlHitTester.resolve(clickPoint: pointer)
        // Mission Control closed in the meantime: neither act nor send ⌘W to the app now in front.
        guard MissionControlSession.isActive(maxAge: .zero) else { return }
        Diagnostics.shared.record("shortcut", resolution: hit)
        guard let resolution = hit,
              shortcut.applies(to: resolution.target, spaceClosingEnabled: Self.isSpaceClosingEnabled) else {
            replay.setIntegerValueField(.eventSourceUserData, value: replayedEventMarker)
            replay.post(tap: .cgSessionEventTap)
            return
        }
        // Swallow key repeats without acting: holding ⌘W must not close a window per repeat,
        // nor leak ⌘W through to the app behind Mission Control.
        guard !isRepeat else { return }
        perform(shortcut, on: resolution)
    }

    /// Runs a keyboard shortcut on the hovered thumbnail. ⌘W on a Space removes it.
    func perform(_ shortcut: MissionControlShortcut, on resolution: MissionControlHitTester.Resolution) {
        switch shortcut {
        case .closeWindow:
            if case .removeDesktop(let button) = resolution.target {
                removeDesktop(button)
            } else {
                perform(resolution: resolution, action: .close)
            }
        case .minimizeWindow:
            perform(resolution: resolution, action: .minimize)
        case .hideApp, .quitApp:
            guard let pid = pid(for: resolution),
                  let app = NSRunningApplication(processIdentifier: pid) else { return }
            if shortcut == .hideApp {
                app.hide()
            } else {
                app.terminate()
            }
        }
    }
}
