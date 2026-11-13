import AppKit

extension SnapAssist {
    // MARK: - Closing on its own

    func installObservers() {
        guard observers.isEmpty else { return }
        let dismiss: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                if SnapAssist.shared.phase != .idle { SnapAssist.shared.dismiss() }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification].map {
            workspace.addObserver(forName: $0, object: nil, queue: .main, using: dismiss)
        }
        // The session's coordinates are for the screens as they were.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: dismiss
        ))
    }

    /// Only while the picker shows: the cards light up under the pointer.
    func startTrackingPointer() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            MainActor.assumeIsolated { SnapAssist.shared.pointerMoved() }
        }
    }

    func stopTrackingPointer() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }
}
