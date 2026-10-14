import Cocoa
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.vibecoded.missionstrike", category: "EventTap")

extension Notification.Name {
    /// Posted on the default `NotificationCenter` whenever the event tap starts or stops.
    static let eventTapStateChanged = Notification.Name("com.vibecoded.missionstrike.eventTapStateChanged")

    /// Posted when `CGEvent.tapCreate` fails entirely (e.g., on MDM-managed Apple Silicon Macs).
    static let eventTapCreationFailed = Notification.Name("com.vibecoded.missionstrike.eventTapCreationFailed")
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

/// Mouse-up types whose mouse-down was swallowed for the context menu. The ups are
/// swallowed too; otherwise they reach Mission Control (or land on the fresh menu).
nonisolated(unsafe) private var mouseUpsToSwallow: Set<CGEventType> = []

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

    if type == .keyDown || type == .flagsChanged {
        return handleKeyboardEvent(type: type, event: event)
    }

    if isMouseUp(type) {
        return mouseUpsToSwallow.remove(type) == nil ? Unmanaged.passUnretained(event) : nil
    }
    forgetLostMouseUp(beforePress: type)

    if MissionControlContextMenu.isOpen {
        return handleMouseWhileMenuOpen(type: type, event: event)
    }

    if type == .rightMouseDown {
        return handleRightMouseDown(event)
    }

    // Determine if this event matches a configured trigger
    let flags = event.flags
    let isTrigger: Bool

    if type == .otherMouseDown && event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
        // Middle click — check if enabled in preferences
        isTrigger = UserDefaults.standard.bool(forKey: "enableMiddleClick")
    } else if type == .leftMouseDown {
        // Left click — check configured modifier
        let modifierRaw = UserDefaults.standard.string(forKey: "leftClickModifier") ?? "option"
        if let modifier = TriggerModifier(rawValue: modifierRaw),
           let mask = modifier.eventFlagMask {
            isTrigger = flags.contains(mask)
        } else {
            isTrigger = false
        }
    } else {
        isTrigger = false
    }

    guard isTrigger else {
        return Unmanaged.passUnretained(event)
    }

    // Debounce: ignore clicks that arrive too soon after the last processed one
    let now = mach_absolute_time()
    let elapsedNano = machTimeToNanoseconds(now - lastProcessedClickTime)
    let elapsedSeconds = Double(elapsedNano) / 1_000_000_000

    if elapsedSeconds < debounceInterval {
        logger.debug("Click debounced (\(String(format: "%.0f", elapsedSeconds * 1000))ms since last).")
        return nil
    }

    // Run check synchronously to decide whether to swallow the event
    let isActive = MissionControlActiveChecker().isActive()

    if isActive {
        // Single resolve from the live cursor. HitTester applies an OS-gated Y-flip
        // when Mission Control’s AX space is mirrored vs click coordinates (macOS 27+).
        let clickPoint = NSEvent.mouseLocation
        let resolution = MissionControlHitTester.resolve(clickPoint: clickPoint)

        lastProcessedClickTime = now

        if let resolution {
            let action: MouseAction
            if flags.contains(.maskCommand) {
                action = .closeAll
            } else if flags.contains(.maskShift) {
                action = .minimize
            } else {
                action = .close
            }

            Task { @MainActor in
                MissionControlManager.shared.perform(resolution: resolution, action: action)
            }
        }
        // Always swallow while Mission Control is up so empty/near-miss middle-clicks
        // do not fall through as normal MC clicks.
        return nil
    }

    // passUnretained: the caller owns the event, we must not retain it
    return Unmanaged.passUnretained(event)
}

/// ⌘-shortcuts act on the hovered thumbnail; modifier changes drive the hover badge.
private func handleKeyboardEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    guard type == .flagsChanged else {
        return handleMissionControlShortcut(event)
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
    guard UserDefaults.standard.bool(forKey: "enableContextMenu"),
          MissionControlActiveChecker().isActive() else {
        return Unmanaged.passUnretained(event)
    }

    let target = contextMenuTarget(at: NSEvent.mouseLocation)
    mouseUpsToSwallow.insert(.rightMouseUp)
    // Async: popUp runs a nested run loop and must not block this callback.
    Task { @MainActor in
        MissionControlContextMenu.shared.show(for: target)
    }
    return nil
}

private func contextMenuTarget(at point: CGPoint) -> ContextMenuTarget {
    MissionControlHitTester.resolve(clickPoint: point).map(ContextMenuTarget.thumbnail) ?? .background
}

/// While the context menu is open: clicks on the menu work as usual, a right-click
/// elsewhere swaps the menu, and any other click only closes the menu so
/// Mission Control stays open.
private func handleMouseWhileMenuOpen(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if MissionControlContextMenu.menuContains(event.location) {
        return Unmanaged.passUnretained(event)
    }

    var next: ContextMenuTarget?
    switch type {
    case .rightMouseDown:
        mouseUpsToSwallow.insert(.rightMouseUp)
        next = contextMenuTarget(at: NSEvent.mouseLocation)
    case .leftMouseDown:
        mouseUpsToSwallow.insert(.leftMouseUp)
    default:
        mouseUpsToSwallow.insert(.otherMouseUp)
    }
    let target = next
    // The tap's run loop source lives on the main run loop, so this already runs on
    // the main thread inside the menu's tracking loop.
    MainActor.assumeIsolated {
        MissionControlContextMenu.shared.replace(with: target)
    }
    return nil
}

private func isMouseUp(_ type: CGEventType) -> Bool {
    switch type {
    case .leftMouseUp, .rightMouseUp, .otherMouseUp: true
    default: false
    }
}

/// A new press means any up still pending from an earlier swallowed press was lost
/// (e.g. while the tap was disabled). Forget it so it can't eat this press's release.
private func forgetLostMouseUp(beforePress type: CGEventType) {
    switch type {
    case .leftMouseDown: mouseUpsToSwallow.remove(.leftMouseUp)
    case .rightMouseDown: mouseUpsToSwallow.remove(.rightMouseUp)
    case .otherMouseDown: mouseUpsToSwallow.remove(.otherMouseUp)
    default: break
    }
}

/// Converts a `mach_absolute_time` delta to nanoseconds.
private func machTimeToNanoseconds(_ ticks: UInt64) -> UInt64 {
    var timebaseInfo = mach_timebase_info_data_t()
    mach_timebase_info(&timebaseInfo)
    return ticks * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
}
