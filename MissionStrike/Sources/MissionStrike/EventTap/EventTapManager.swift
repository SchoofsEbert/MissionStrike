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

/// Minimum interval (in seconds) between processed clicks to prevent
/// racing close operations on rapid double-clicks.
private let debounceInterval: TimeInterval = MissionStrikeConfig.default.debounceInterval

/// Timestamp of the last click that was actually processed.
/// Only accessed from the run-loop thread (event tap callback), so no lock is needed.
nonisolated(unsafe) private var lastProcessedClickTime: UInt64 = 0

/// Releases of swallowed presses. Only accessed from the run-loop thread (event tap callback).
nonisolated(unsafe) private var swallowedMouseUps = SwallowedMouseUps()

/// The event a callback is handling, for main-actor code it calls synchronously. The callback
/// already runs on the main thread, so nothing is shared across threads.
private struct TappedEvent: @unchecked Sendable {
    let event: CGEvent
    init(_ event: CGEvent) { self.event = event }
}

/// Media and special keys, including the Mission Control key (`NX_SYSDEFINED`).
private let systemDefinedEventType: UInt32 = 14
/// Trackpad swipes that drive Mission Control and Spaces (private `kCGSEventDockControl`).
private let dockGestureEventType: UInt32 = 30

// MARK: - Event Tap Callback

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        return handleTapDisabled(event: event, refcon: refcon)
    }
    // Keys MissionStrike posted again after deciding not to act on them.
    if event.getIntegerValueField(.eventSourceUserData) == replayedEventMarker {
        return Unmanaged.passUnretained(event)
    }
    if type.rawValue == systemDefinedEventType || type.rawValue == dockGestureEventType {
        dismissConfirmationBadge()
        return Unmanaged.passUnretained(event)
    }

    let result = handleInput(type: type, event: event)
    // A press MissionStrike lets through can close Mission Control (Esc, a click on a window or
    // the background). Mission Control's windows only go once its closing animation is over,
    // so drop the confirmation badge now rather than waiting for them.
    if result != nil, type == .keyDown || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
        dismissConfirmationBadge()
    }
    return result
}

private func dismissConfirmationBadge() {
    // The tap's run loop source lives on the main run loop.
    MainActor.assumeIsolated {
        HoverBadgeController.shared.dismissFlash()
    }
}

private func handleInput(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

    if type == .keyDown || type == .flagsChanged {
        return handleKeyboardEvent(type: type, event: event)
    }

    if SwallowedMouseUps.isMouseUp(type) {
        return swallowedMouseUps.consume(type) ? nil : Unmanaged.passUnretained(event)
    }
    swallowedMouseUps.forgetLostRelease(beforePress: type)

    if MissionControlContextMenu.isOpen {
        return handleMouseWhileMenuOpen(type: type, event: event)
    }

    if type == .rightMouseDown {
        return handleRightMouseDown(event)
    }

    let flags = event.flags
    // The tap's run loop source lives on the main run loop.
    let settings = MainActor.assumeIsolated { SettingsStore.shared.current }
    // Middle-clicks on a running app's Dock icon come first, in or out of Mission Control.
    // When the cached Dock layout can't tell, the click goes its usual way and the Dock is
    // asked once the callback has returned.
    var dockProbe: [CGPoint]?
    if type == .otherMouseDown {
        let verdict = DockMiddleClick.verdict(for: event, enabled: settings.enableDockMiddleClick)
        let candidates = DockMiddleClick.candidates(for: event)
        if verdict == .runningApp {
            swallowedMouseUps.swallowRelease(of: type)
            Task { @MainActor in
                DockMiddleClick.perform(at: candidates, closeWindowsOnly: flags.contains(.maskAlternate))
            }
            return nil
        }
        dockProbe = verdict == .maybe ? candidates : nil
    }

    let isTrigger = ClickTrigger.matches(
        type: type,
        buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
        flags: flags,
        middleClickEnabled: settings.enableMiddleClick,
        leftClickModifier: settings.leftClickModifier
    )
    guard isTrigger else {
        probeDock(dockProbe, flags: flags)
        return Unmanaged.passUnretained(event)
    }

    // Debounce: ignore clicks that arrive too soon after the last processed one
    let now = mach_absolute_time()
    let elapsedNano = machTimeToNanoseconds(now - lastProcessedClickTime)
    let elapsedSeconds = Double(elapsedNano) / 1_000_000_000

    if elapsedSeconds < debounceInterval {
        logger.debug("Click debounced (\(String(format: "%.0f", elapsedSeconds * 1000))ms since last).")
        swallowedMouseUps.swallowRelease(of: type)
        return nil
    }

    // Run check synchronously to decide whether to swallow the event
    let isActive = MissionControlActiveChecker().isActive()

    if isActive {
        lastProcessedClickTime = now
        swallowedMouseUps.swallowRelease(of: type)
        // Hit-testing asks the Dock and WindowManager through Accessibility, which can be
        // slow. The click is swallowed whatever it hits, so resolve after the callback returns
        // rather than holding up input. HitTester applies an OS-gated Y-flip when Mission
        // Control's AX space is mirrored vs click coordinates (macOS 27+).
        let clickPoint = NSEvent.mouseLocation
        let input = type == .otherMouseDown ? "middle-click" : "modifier-click"
        let action = MouseAction(flags: flags)
        Task { @MainActor in
            if let dockProbe,
               DockMiddleClick.perform(at: dockProbe, closeWindowsOnly: flags.contains(.maskAlternate)) {
                return
            }
            let resolution = MissionControlHitTester.resolve(clickPoint: clickPoint)
            Diagnostics.shared.record(input, resolution: resolution)
            // Mission Control may have closed while the click waited to be resolved;
            // acting then would close a window the user can no longer see being targeted.
            guard let resolution, MissionControlActiveChecker().isActive() else { return }
            MissionControlManager.shared.perform(resolution: resolution, action: action)
        }
        // Always swallow while Mission Control is up so empty/near-miss middle-clicks
        // do not fall through as normal MC clicks.
        return nil
    }

    probeDock(dockProbe, flags: flags)
    // passUnretained: the caller owns the event, we must not retain it
    return Unmanaged.passUnretained(event)
}

/// Asks the Dock about a middle-click that passed through, once the callback has returned.
private func probeDock(_ candidates: [CGPoint]?, flags: CGEventFlags) {
    guard let candidates else { return }
    Task { @MainActor in
        DockMiddleClick.perform(at: candidates, closeWindowsOnly: flags.contains(.maskAlternate))
    }
}

/// ⌘-shortcuts act on the hovered thumbnail; modifier changes drive the hover badge.
private func handleKeyboardEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    guard type == .flagsChanged else {
        // The tap's run loop source lives on the main run loop.
        let tapped = TappedEvent(event)
        let swallowed = MainActor.assumeIsolated { handleMissionControlShortcut(tapped.event) }
        return swallowed ? nil : Unmanaged.passUnretained(event)
    }
    let flags = event.flags
    Task { @MainActor in
        HoverBadgeController.shared.modifiersChanged(flags)
    }
    return Unmanaged.passUnretained(event)
}

/// Watchdog: macOS disables the tap if the callback takes too long.
/// Re-enable it immediately to recover without requiring a relaunch.
private func handleTapDisabled(event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // Revoking Accessibility also disables the tap. Re-enabling it then fights
    // macOS and can stall system-wide input, so tear it down instead.
    guard AXIsProcessTrusted() else {
        logger.warning("Event tap disabled after Accessibility was revoked — stopping it.")
        Task { @MainActor in EventTapManager.shared.stop() }
        return Unmanaged.passUnretained(event)
    }
    if let refcon,
       let tap = refcon.assumingMemoryBound(to: CFMachPort?.self).pointee {
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.warning("Event tap was disabled by macOS — re-enabled automatically.")
    }
    return Unmanaged.passUnretained(event)
}

/// Right-click in Mission Control opens MissionStrike's context menu: for the window or
/// Space under the pointer, or app-wide actions on empty space.
private func handleRightMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
    guard MainActor.assumeIsolated({ SettingsStore.shared.current.enableContextMenu }),
          MissionControlActiveChecker().isActive() else {
        return Unmanaged.passUnretained(event)
    }

    let point = NSEvent.mouseLocation
    swallowedMouseUps.swallowRelease(of: .rightMouseDown)
    // Async: popUp runs a nested run loop and must not block this callback, and the
    // menu hit-tests the point itself, after the callback returns.
    Task { @MainActor in
        MissionControlContextMenu.shared.show(at: point)
    }
    return nil
}

/// While the context menu is open: clicks on the menu work as usual, a right-click
/// elsewhere swaps the menu, and any other click only closes the menu so
/// Mission Control stays open.
private func handleMouseWhileMenuOpen(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if MissionControlContextMenu.menuContains(event.location) {
        return Unmanaged.passUnretained(event)
    }

    swallowedMouseUps.swallowRelease(of: type)
    let next: CGPoint? = type == .rightMouseDown ? NSEvent.mouseLocation : nil
    // The tap's run loop source lives on the main run loop, so this already runs on
    // the main thread inside the menu's tracking loop.
    MainActor.assumeIsolated {
        MissionControlContextMenu.shared.replace(withMenuAt: next)
    }
    return nil
}

/// Converts a `mach_absolute_time` delta to nanoseconds.
private func machTimeToNanoseconds(_ ticks: UInt64) -> UInt64 {
    var timebaseInfo = mach_timebase_info_data_t()
    mach_timebase_info(&timebaseInfo)
    return ticks * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
}
