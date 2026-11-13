import AppKit

extension AppDelegate: NSWindowDelegate {
    /// Drops a closed window with its views, about 20 MB for Settings; it's made again when opened.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // After the close finishes: AppKit still uses the window during it.
        DispatchQueue.main.async { [weak self] in
            guard let self, !window.isVisible else { return }
            if window === settingsWindow { settingsWindow = nil }
            if window === aboutWindow { aboutWindow = nil }
            if window === onboardingWindow { onboardingWindow = nil }
        }
    }
}
