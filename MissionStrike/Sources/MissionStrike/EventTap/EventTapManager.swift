import Cocoa
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "EventTap")

extension Notification.Name {
    /// Posted on the default `NotificationCenter` whenever the event tap starts or stops.
    static let eventTapStateChanged = Notification.Name("io.github.schoofsebert.missionstrike.eventTapStateChanged")

    /// Posted when `CGEvent.tapCreate` fails entirely (e.g., on MDM-managed Apple Silicon Macs).
    static let eventTapCreationFailed = Notification.Name("io.github.schoofsebert.missionstrike.eventTapCreationFailed")
}

@MainActor
class EventTapManager {
    static let shared = EventTapManager()
    private init() {}

    private var eventTapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Debounce and swallowed releases, kept between callbacks.
    fileprivate var tapState = TapState()

    /// Heap-allocated storage for the mach port pointer, passed to the
    /// callback via `refcon` so it can re-enable the tap on timeout.
    private var tapPortPointer: UnsafeMutablePointer<CFMachPort?>?

    /// Whether the event tap is currently active and listening.
    var isRunning: Bool { eventTapPort != nil }

    /// Paused from the menu bar: the tap stays off (no per-event cost) until resumed,
    /// even when Accessibility changes would normally restart it. Not persisted.
    private(set) var isPaused = false

    func pause() {
        isPaused = true
        stop()
    }

    func resume() {
        isPaused = false
        start()
    }

    func start() {
        // Don't recreate if already running, or while paused
        guard !isRunning, !isPaused else { return }

        // Allocate stable storage for the port pointer before creating the tap
        let pointer = UnsafeMutablePointer<CFMachPort?>.allocate(capacity: 1)
        pointer.initialize(to: nil)
        self.tapPortPointer = pointer

        let eventMask = (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << systemDefinedEventType)
            | (1 << dockGestureEventType)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: eventTapCallback,
            userInfo: UnsafeMutableRawPointer(pointer)
        ) else {
            logger.error("Failed to create event tap. Make sure Accessibility permissions are enabled.")
            pointer.deinitialize(count: 1)
            pointer.deallocate()
            self.tapPortPointer = nil
            NotificationCenter.default.post(name: .eventTapCreationFailed, object: nil)
            return
        }

        // Store the port in both the instance property and the heap pointer
        self.eventTapPort = tap
        pointer.pointee = tap

        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        DockIconCache.shared.startObserving()
        MissionControlOverlays.startObserving()

        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            logger.info("Event tap started.")
            NotificationCenter.default.post(name: .eventTapStateChanged, object: nil)
        }
    }

    func stop() {
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tap = eventTapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.eventTapPort = nil
        }
        if let pointer = tapPortPointer {
            pointer.deinitialize(count: 1)
            pointer.deallocate()
            self.tapPortPointer = nil
        }
        logger.info("Event tap stopped.")
        NotificationCenter.default.post(name: .eventTapStateChanged, object: nil)
    }
}

/// Media and special keys, including the Mission Control key (`NX_SYSDEFINED`).
private let systemDefinedEventType: UInt32 = 14
/// Trackpad swipes that drive Mission Control and Spaces (private `kCGSEventDockControl`).
private let dockGestureEventType: UInt32 = 30

/// The callback's arguments, handed to main-actor code it calls synchronously. The callback
/// already runs on the main thread, so nothing crosses threads.
private struct TapCallbackArguments: @unchecked Sendable {
    let type: CGEventType
    let event: CGEvent
    let refcon: UnsafeMutableRawPointer?
}

// MARK: - Event Tap Callback

/// The tap's run loop source lives on the main run loop, so the callback runs on the main
/// actor. Returns nil to swallow the event.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let arguments = TapCallbackArguments(type: type, event: event, refcon: refcon)
    let swallow = MainActor.assumeIsolated {
        EventTapManager.shared.handle(arguments.type, arguments.event, refcon: arguments.refcon)
    }
    // passUnretained: the caller owns the event, we must not retain it
    return swallow ? nil : Unmanaged.passUnretained(event)
}

extension EventTapManager {
    /// Handles one tapped event; true to swallow it. Only cheap state is consulted here: work
    /// that asks other apps through Accessibility runs after the callback has returned.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Bool {
        let start = ContinuousClock.now
        let signpost = performanceSignposter.beginInterval("Tap callback")
        defer {
            performanceSignposter.endInterval("Tap callback", signpost)
            Diagnostics.shared.recordCallback(duration: .now - start)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Diagnostics.shared.recordTapDisabled(byTimeout: type == .tapDisabledByTimeout)
            handleTapDisabled(refcon: refcon)
            return false
        }
        // Keys MissionStrike posted again after deciding not to act on them.
        if event.getIntegerValueField(.eventSourceUserData) == replayedEventMarker {
            return false
        }
        if type.rawValue == systemDefinedEventType || type.rawValue == dockGestureEventType {
            MissionControlSession.reset()
            HoverBadgeController.shared.dismissFlash()
            return false
        }
        // A click on a confirmation badge is for the badge's own panel: let it through, and
        // keep the badge until the panel has it.
        if type == .leftMouseDown, ConfirmationBadges.shared.contains(NSEvent.mouseLocation) {
            return false
        }

        let tapEvent = TapEvent(type, event)
        let decision = TapRouter.decide(
            tapEvent,
            state: &tapState,
            settings: SettingsStore.shared.current,
            environment: LiveTapEnvironment()
        )
        carryOut(decision, for: tapEvent, event)

        // A press MissionStrike lets through can close Mission Control (Esc, a click on a window or
        // the background). Mission Control's windows only go once its closing animation is over,
        // so drop the confirmation badge now rather than waiting for them.
        if !decision.swallows, type == .keyDown || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            MissionControlSession.inputPassedThrough()
            HoverBadgeController.shared.dismissFlash()
        }
        return decision.swallows
    }

    /// Starts what a decision asks for. Anything that hit-tests is deferred until after the
    /// callback, so the event isn't held up by a slow app.
    private func carryOut(_ decision: TapDecision, for tapEvent: TapEvent, _ event: CGEvent) {
        let pointer = tapEvent.pointer
        let closeWindowsOnly = tapEvent.flags.contains(.maskAlternate)
        switch decision {
        case .pass, .swallow:
            break

        case .modifiersChanged(let flags):
            HoverBadgeController.shared.modifiersChanged(flags)
            MissionControlOverlays.modifiersChanged(flags)

        case .missionControlClick(let action, let input, let probeDock):
            let dockCandidates = DockMiddleClick.candidates(location: tapEvent.location, pointer: pointer)
            Task { @MainActor in
                if probeDock, DockMiddleClick.perform(at: dockCandidates, closeWindowsOnly: closeWindowsOnly) {
                    return
                }
                MissionControlManager.shared.handleClick(action, input: input, at: pointer)
            }

        case .dockClick(let closeWindowsOnly), .passAndProbeDock(let closeWindowsOnly):
            let dockCandidates = DockMiddleClick.candidates(location: tapEvent.location, pointer: pointer)
            Task { @MainActor in
                DockMiddleClick.perform(at: dockCandidates, closeWindowsOnly: closeWindowsOnly)
            }

        case .openMenu:
            // popUp runs a nested run loop, which must not start inside this callback.
            Task { @MainActor in
                MissionControlContextMenu.shared.show(at: pointer)
            }

        case .closeMenu(let reopen):
            // Already on the main thread inside the menu's tracking loop.
            MissionControlContextMenu.shared.replace(withMenuAt: reopen ? pointer : nil)

        case .shortcut(let shortcut, let isRepeat):
            guard let replay = event.copy() else { return }
            Task { @MainActor in
                MissionControlManager.shared.handle(shortcut, isRepeat: isRepeat, at: pointer, replay: replay)
            }
        }
    }

    /// Watchdog: macOS disables the tap if the callback takes too long.
    /// Re-enable it immediately to recover without requiring a relaunch.
    private func handleTapDisabled(refcon: UnsafeMutableRawPointer?) {
        // Revoking Accessibility also disables the tap. Re-enabling it then fights
        // macOS and can stall system-wide input, so tear it down instead.
        guard AXIsProcessTrusted() else {
            logger.warning("Event tap disabled after Accessibility was revoked — stopping it.")
            // Not from inside the tap's own callback.
            Task { @MainActor in EventTapManager.shared.stop() }
            return
        }
        if let refcon,
           let tap = refcon.assumingMemoryBound(to: CFMachPort?.self).pointee {
            CGEvent.tapEnable(tap: tap, enable: true)
            logger.warning("Event tap was disabled by macOS — re-enabled automatically.")
        }
    }
}

private extension TapEvent {
    init(_ type: CGEventType, _ event: CGEvent) {
        self.init(
            type: type,
            buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
            flags: event.flags,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            location: event.location,
            pointer: NSEvent.mouseLocation,
            time: ProcessInfo.processInfo.systemUptime
        )
    }
}

/// Cheap answers for `TapRouter`: window-list lookups and cached state, no Accessibility.
@MainActor
private struct LiveTapEnvironment: TapEnvironment {
    func isMissionControlActive() -> Bool {
        MissionControlSession.isActive()
    }

    var isContextMenuOpen: Bool {
        MissionControlContextMenu.isOpen
    }

    func menuContains(_ point: CGPoint) -> Bool {
        MissionControlContextMenu.menuContains(point)
    }

    func dockVerdict(for event: TapEvent) -> DockSnapshot.Verdict {
        DockIconCache.shared.verdict(at: DockMiddleClick.candidates(location: event.location, pointer: event.pointer))
    }
}
