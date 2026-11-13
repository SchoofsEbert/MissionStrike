import AppKit
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "TabSwipe")

/// Swiping left or right with three fingers switches tabs in the app in front, with ⌃⇧⇥ and ⌃⇥,
/// in the apps the settings allow.
///
/// A tap of its own, listen-only: touches never wait for it, and the main tap's callback stays
/// as it is. It exists only while the setting is on and the main tap runs, so Pause and a
/// revoked Accessibility grant stop it too.
@MainActor
final class TabSwipe {
    static let shared = TabSwipe()
    private init() {}

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var recognizer = TabSwipeRecognizer()
    private var observers: [NSObjectProtocol] = []

    func startObserving() {
        guard observers.isEmpty else { return }
        observers = [Notification.Name.eventTapStateChanged, UserDefaults.didChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TabSwipe.shared.sync() }
            }
        }
        sync()
    }

    private func sync() {
        // Read from UserDefaults: SettingsStore may not have reloaded yet when this runs.
        let shouldRun = EventTapManager.shared.isRunning && UserDefaults.standard.bool(.enableTabSwipe)
        if shouldRun, tap == nil {
            start()
        } else if !shouldRun, tap != nil {
            stop()
        }
    }

    private func start() {
        // Touches are on gesture events at the HID level.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << gestureEventType,
            callback: tabSwipeCallback,
            userInfo: nil
        ) else {
            logger.error("Failed to create the tab swipe tap.")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("Tab swipe started.")
    }

    private func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        recognizer = TabSwipeRecognizer()
        logger.info("Tab swipe stopped.")
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Without Accessibility the main tap stops, and this one with it.
            if let tap, AXIsProcessTrusted() {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard type.rawValue == gestureEventType,
              let touches = NSEvent(cgEvent: event)?.touches(matching: .touching, in: nil),
              let step = recognizer.update(touching: touches.map(\.normalizedPosition)) else { return }
        let settings = SettingsStore.shared.current
        guard settings.tabSwipeApps.allows(NSWorkspace.shared.frontmostApplication?.bundleIdentifier),
              // The tab would switch in the app behind Mission Control.
              !MissionControlSession.isActive() else { return }
        post(step)
        // A tick per tab while the fingers are still on the trackpad.
        if settings.tabSwipeHaptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func post(_ step: TabSwipeRecognizer.Step) {
        let flags: CGEventFlags = step == .next ? .maskControl : [.maskControl, .maskShift]
        for keyDown in [true, false] {
            guard let key = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Tab), keyDown: keyDown) else {
                return
            }
            key.flags = flags
            // The main tap lets it through without routing it.
            key.setIntegerValueField(.eventSourceUserData, value: replayedEventMarker)
            key.post(tap: .cgSessionEventTap)
        }
    }
}

/// `NSEventTypeGesture`: the trackpad's touches.
private let gestureEventType: CGEventType.RawValue = 29

private struct TabSwipeCallbackArguments: @unchecked Sendable {
    let type: CGEventType
    let event: CGEvent
}

/// Runs on the main run loop, so on the main actor. Listen-only: the return value is ignored.
private func tabSwipeCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let arguments = TabSwipeCallbackArguments(type: type, event: event)
    MainActor.assumeIsolated {
        TabSwipe.shared.handle(arguments.type, arguments.event)
    }
    return Unmanaged.passUnretained(event)
}
