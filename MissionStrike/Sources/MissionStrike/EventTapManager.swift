import Cocoa
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.vibecoded.missionstrike", category: "EventTap")

extension Notification.Name {
    /// Posted on the default `NotificationCenter` whenever the event tap starts or stops.
    static let eventTapStateChanged = Notification.Name("com.vibecoded.missionstrike.eventTapStateChanged")
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

    func start() {
        // Don't recreate if already running
        guard !isRunning else { return }

        // Allocate stable storage for the port pointer before creating the tap
        let pointer = UnsafeMutablePointer<CFMachPort?>.allocate(capacity: 1)
        pointer.initialize(to: nil)
        self.tapPortPointer = pointer

        let eventMask = (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)

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

// MARK: - Event Tap Callback

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Watchdog: macOS disables the tap if the callback takes too long.
    // Re-enable it immediately to recover without requiring a relaunch.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon,
           let tap = refcon.assumingMemoryBound(to: CFMachPort?.self).pointee {
            CGEvent.tapEnable(tap: tap, enable: true)
            logger.warning("Event tap was disabled by macOS — re-enabled automatically.")
        }
        return Unmanaged.passUnretained(event)
    }

    let isMiddleClick = (type == .otherMouseDown && event.getIntegerValueField(.mouseEventButtonNumber) == 2)
    let isOptionLeftClick = (type == .leftMouseDown && event.flags.contains(.maskAlternate))

    if isMiddleClick || isOptionLeftClick {
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
            lastProcessedClickTime = now
            let location = event.location
            Task { @MainActor in
                MissionControlManager.shared.handleMouseEvent(location: location)
            }

            // Return nil to completely intercept the event (blocks default action)
            return nil
        }
    }

    // passUnretained: the caller owns the event, we must not retain it
    return Unmanaged.passUnretained(event)
}

/// Converts a `mach_absolute_time` delta to nanoseconds.
private func machTimeToNanoseconds(_ ticks: UInt64) -> UInt64 {
    var timebaseInfo = mach_timebase_info_data_t()
    mach_timebase_info(&timebaseInfo)
    return ticks * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
}
