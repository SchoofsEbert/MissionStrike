import CoreGraphics

/// A tapped event, reduced to what routing looks at.
struct TapEvent: Sendable {
    var type: CGEventType
    var buttonNumber: Int64 = 0
    var flags: CGEventFlags = []
    var keyCode: Int64 = 0
    var isAutorepeat = false
    /// What a key press types on the current layout, Shift included; empty for other events.
    var characters = ""
    /// Quartz location (AX space).
    var location: CGPoint = .zero
    /// `NSEvent.mouseLocation` when the event arrived (AppKit space): what hit-testing takes.
    var pointer: CGPoint = .zero
    /// Seconds on a monotonic clock.
    var time: Double = 0
}

/// What the tap remembers between events.
struct TapState: Equatable {
    var swallowedMouseUps = SwallowedMouseUps()
    /// When the last Mission Control click was taken on, for the debounce.
    var lastProcessedClick: Double = -.infinity
}

/// What the event tap does with an event.
enum TapDecision: Equatable {
    case pass
    /// Swallowed with nothing else to do: a debounced click, or the release of a swallowed press.
    case swallow
    /// Passes; the hover badge follows the new modifiers.
    case modifiersChanged(CGEventFlags)
    /// Swallowed; once the callback returns, resolve what's under the pointer and act on it,
    /// unless a Dock probe finds a running app's icon there first.
    case missionControlClick(MouseAction, input: String, probeDock: Bool)
    /// Swallowed; once the callback returns, quit the app under the Dock icon or close its windows.
    case dockClick(closeWindowsOnly: Bool)
    /// Passes; once the callback returns, ask the Dock whether it was on a running app's icon.
    case passAndProbeDock(closeWindowsOnly: Bool)
    /// Swallowed; once the callback returns, open the context menu.
    case openMenu
    /// Swallowed; closes the open context menu, then opens one for the new point on a right-click.
    case closeMenu(reopen: Bool)
    /// Swallowed; once the callback returns, act on the hovered thumbnail or post the key again.
    case shortcut(MissionControlShortcut, isRepeat: Bool)
    /// Swallowed; F starts keyboard hints, or is posted again once there turns out to be nothing to label.
    case startKeyboardHints
    /// Swallowed; a key for the keyboard hints on screen.
    case keyboardHint(HintKey, isRepeat: Bool)
    /// Swallowed; `?` shows or hides the cheat sheet.
    case toggleCheatSheet
    /// Swallowed; Esc closes the cheat sheet opened with `?` and leaves Mission Control open.
    case closeCheatSheet

    var swallows: Bool {
        switch self {
        case .pass, .modifiersChanged, .passAndProbeDock: false
        case .swallow, .missionControlClick, .dockClick, .openMenu, .closeMenu, .shortcut, .startKeyboardHints,
             .keyboardHint, .toggleCheatSheet, .closeCheatSheet: true
        }
    }
}

/// The state routing asks about. Every answer must be cheap: routing runs inside the event
/// tap callback, which holds up all input until it returns.
@MainActor
protocol TapEnvironment {
    func isMissionControlActive() -> Bool
    var isContextMenuOpen: Bool { get }
    /// Whether a point (Quartz space) lies on the open context menu.
    func menuContains(_ point: CGPoint) -> Bool
    func dockVerdict(for event: TapEvent) -> DockSnapshot.Verdict
    /// Whether the event is on the Dock, which Mission Control leaves on screen.
    func isOnDock(_ event: TapEvent) -> Bool
    /// Whether keyboard hints are up or starting: every plain key press belongs to them then.
    var isKeyboardHintsActive: Bool { get }
    /// Whether the cheat sheet was opened with `?`, so Esc closes it.
    var isCheatSheetPinned: Bool { get }
}

/// Decides what the event tap does with each event. Pure apart from `state`, so it can be
/// tested without a tap, Mission Control or the Dock.
@MainActor
enum TapRouter {
    static func decide(
        _ event: TapEvent,
        state: inout TapState,
        settings: Settings,
        environment: some TapEnvironment,
        debounceInterval: Double = MissionStrikeConfig.default.debounceInterval
    ) -> TapDecision {
        switch event.type {
        case .flagsChanged:
            return .modifiersChanged(event.flags)
        case .keyDown:
            return key(event, settings: settings, environment: environment)
        default:
            break
        }

        if SwallowedMouseUps.isMouseUp(event.type) {
            return state.swallowedMouseUps.consume(event.type) ? .swallow : .pass
        }
        state.swallowedMouseUps.forgetLostRelease(beforePress: event.type)

        // While the context menu is open: clicks on the menu work as usual, a right-click
        // elsewhere swaps the menu, and any other click only closes the menu so Mission
        // Control stays open. The Dock has its own menu, so a right-click there only closes ours.
        if environment.isContextMenuOpen {
            if environment.menuContains(event.location) {
                return .pass
            }
            state.swallowedMouseUps.swallowRelease(of: event.type)
            return .closeMenu(reopen: event.type == .rightMouseDown && !environment.isOnDock(event))
        }

        if event.type == .rightMouseDown {
            guard settings.enableContextMenu, environment.isMissionControlActive(),
                  !environment.isOnDock(event) else { return .pass }
            state.swallowedMouseUps.swallowRelease(of: event.type)
            return .openMenu
        }

        // Middle-clicks on a running app's Dock icon come first, in or out of Mission Control.
        // When the cached Dock layout can't tell, the click goes its usual way and the Dock is
        // asked once the callback has returned.
        let closeWindowsOnly = event.flags.contains(.maskAlternate)
        var probeDock = false
        if event.type == .otherMouseDown, event.buttonNumber == 2, settings.enableDockMiddleClick {
            switch environment.dockVerdict(for: event) {
            case .runningApp:
                state.swallowedMouseUps.swallowRelease(of: event.type)
                return .dockClick(closeWindowsOnly: closeWindowsOnly)
            case .maybe:
                probeDock = true
            case .elsewhere:
                break
            }
        }
        let pass: TapDecision = probeDock ? .passAndProbeDock(closeWindowsOnly: closeWindowsOnly) : .pass

        let isTrigger = ClickTrigger.matches(
            type: event.type,
            buttonNumber: event.buttonNumber,
            flags: event.flags,
            middleClickEnabled: settings.enableMiddleClick,
            leftClickModifier: settings.leftClickModifier
        )
        guard isTrigger else { return pass }

        // Debounce: ignore clicks that arrive too soon after the last processed one.
        if event.time - state.lastProcessedClick < debounceInterval {
            state.swallowedMouseUps.swallowRelease(of: event.type)
            return .swallow
        }

        guard environment.isMissionControlActive() else { return pass }
        state.lastProcessedClick = event.time
        // Always swallow while Mission Control is up so empty/near-miss clicks do not fall
        // through as normal Mission Control clicks.
        state.swallowedMouseUps.swallowRelease(of: event.type)
        return .missionControlClick(
            MouseAction(flags: event.flags),
            input: event.type == .otherMouseDown ? "middle-click" : "modifier-click",
            probeDock: probeDock
        )
    }

    /// Plain keys go to the overlays first; anything they don't take, to the ⌘ shortcuts.
    private static func key(
        _ event: TapEvent,
        settings: Settings,
        environment: some TapEnvironment
    ) -> TapDecision {
        // The menu never has the keyboard (MissionStrike isn't the active app), so Esc would
        // close Mission Control and leave the menu stranded on the desktop.
        if environment.isContextMenuOpen,
           HintKey(keyCode: event.keyCode, characters: event.characters) == .cancel {
            return .closeMenu(reopen: false)
        }
        if event.flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskControl]),
           let decision = overlayKey(event, settings: settings, environment: environment) {
            return decision
        }
        return shortcut(for: event, settings: settings, environment: environment)
    }

    /// Plain key presses (no ⌘, ⌥ or ⌃) the overlays take while Mission Control is open: all of
    /// them while keyboard hints are up, F to start them, `?` for the cheat sheet, and Esc to
    /// close a cheat sheet opened with `?`. Nil for every other key, which goes on its way.
    private static func overlayKey(
        _ event: TapEvent,
        settings: Settings,
        environment: some TapEnvironment
    ) -> TapDecision? {
        let key = HintKey(keyCode: event.keyCode, characters: event.characters)
        let decision: TapDecision
        if environment.isKeyboardHintsActive {
            decision = .keyboardHint(key, isRepeat: event.isAutorepeat)
        } else if event.isAutorepeat {
            return nil
        } else if settings.showCheatSheet, event.characters == "?" {
            decision = .toggleCheatSheet
        } else if environment.isCheatSheetPinned, key == .cancel {
            decision = .closeCheatSheet
        } else if settings.enableKeyboardHints, key == .letter(HintLabels.toggleLetter) {
            decision = .startKeyboardHints
        } else {
            return nil
        }
        // Asked last, so typing outside Mission Control only pays for the check on these keys.
        return environment.isMissionControlActive() ? decision : nil
    }

    /// ⌘W / ⌘M / ⌘H / ⌘Q while Mission Control is open. Whether a thumbnail takes the key is
    /// only known after an Accessibility hit-test, so the key is swallowed now and posted again
    /// later if nothing takes it.
    private static func shortcut(
        for event: TapEvent,
        settings: Settings,
        environment: some TapEnvironment
    ) -> TapDecision {
        guard let shortcut = MissionControlShortcut(keyCode: event.keyCode, flags: event.flags),
              settings.enableKeyboardShortcuts,
              environment.isMissionControlActive() else {
            return .pass
        }
        return .shortcut(shortcut, isRepeat: event.isAutorepeat)
    }
}
