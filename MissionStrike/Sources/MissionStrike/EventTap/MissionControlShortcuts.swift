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
}

/// ⌘W / ⌘M / ⌘H / ⌘Q act on the hovered thumbnail while Mission Control is open.
/// Everything else (other keys, other modifiers, no thumbnail under the cursor) passes through.
/// Runs on the event tap callback, so the cheap key checks come before the Mission Control check.
func handleMissionControlShortcut(_ event: CGEvent) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    guard let shortcut = MissionControlShortcut(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags
          ),
          UserDefaults.standard.bool(forKey: "enableKeyboardShortcuts"),
          MissionControlActiveChecker().isActive() else {
        return pass
    }
    let hit = MissionControlHitTester.resolve(clickPoint: NSEvent.mouseLocation)
    Diagnostics.shared.record("shortcut", resolution: hit)
    guard let resolution = hit else {
        return pass
    }

    if case .removeDesktop = resolution.target, shortcut != .closeWindow {
        return pass
    }
    // Swallow key repeats without acting: holding ⌘W must not close a window per repeat,
    // nor leak ⌘W through to the app behind Mission Control.
    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
        return nil
    }

    Task { @MainActor in
        MissionControlManager.shared.perform(shortcut, on: resolution)
    }
    return nil
}

extension MissionControlManager {
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
