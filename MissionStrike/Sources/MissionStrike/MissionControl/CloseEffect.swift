import AppKit

/// Optional "poof" cloud where a window or Space was closed (off by default).
@MainActor
enum CloseEffect {
    static func play(for resolution: MissionControlHitTester.Resolution) {
        let point = resolution.thumbnailFrame.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        play(at: point)
    }

    /// `point` is in AppKit screen coordinates.
    static func play(at point: NSPoint) {
        guard UserDefaults.standard.bool(forKey: "poofOnClose") else { return }
        NSAnimationEffect.poof.show(centeredAt: point, size: NSSize(width: 72, height: 72))
    }
}
