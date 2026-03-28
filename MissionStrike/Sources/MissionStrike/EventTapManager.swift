import Cocoa
import CoreGraphics

@MainActor
class EventTapManager {
    static let shared = EventTapManager()

    private var eventTapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        let eventMask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            print("Failed to create event tap. Make sure Accessibility permissions are enabled.")
            return
        }

        self.eventTapPort = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("Event tap started.")
        }
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let isMiddleClick = (type == .otherMouseDown && event.getIntegerValueField(.mouseEventButtonNumber) == 2)
    let isOptionLeftClick = (type == .leftMouseDown && event.flags.contains(.maskAlternate))

    if isMiddleClick || isOptionLeftClick {
        let location = event.location
        Task { @MainActor in
            MissionControlManager.shared.handleMouseEvent(location: location, isMiddle: isMiddleClick)
        }

        // Return nil to completely intercept the event (blocks default action)
        return nil
    }

    return Unmanaged.passRetained(event)
}
