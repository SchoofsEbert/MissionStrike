import Cocoa
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.vibecoded.missionstrike", category: "EventTap")

@MainActor
class EventTapManager {
    static let shared = EventTapManager()
    private init() {}

    private var eventTapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Whether the event tap is currently active and listening.
    var isRunning: Bool { eventTapPort != nil }

    func start() {
        // Don't recreate if already running
        guard !isRunning else { return }

        let eventMask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            logger.error("Failed to create event tap. Make sure Accessibility permissions are enabled.")
            return
        }

        self.eventTapPort = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            logger.info("Event tap started.")
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
        logger.info("Event tap stopped.")
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let isMiddleClick = (type == .otherMouseDown && event.getIntegerValueField(.mouseEventButtonNumber) == 2)
    let isOptionLeftClick = (type == .leftMouseDown && event.flags.contains(.maskAlternate))

    if isMiddleClick || isOptionLeftClick {
        // Run check synchronously to decide whether to swallow the event
        let isActive = MissionControlActiveChecker.isActive()

        if isActive {
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
