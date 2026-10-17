import AppKit
import QuartzCore

/// Optional "poof" cloud where a window or Space was closed (off by default).
///
/// `NSAnimationEffect.poof` draws below Mission Control's overlay, so only its sound
/// came through. The puff is drawn in our own panel instead, at the hover badge's level.
@MainActor
enum CloseEffect {
    private static let size: CGFloat = 96
    private static let duration: CFTimeInterval = 0.45
    private static let sound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/"
            + "SystemSounds/dock/poof item off dock.aif",
        byReference: true
    )

    /// `point` is in AppKit screen coordinates.
    static func play(at point: NSPoint) {
        guard SettingsStore.shared.current.poofOnClose else { return }

        let frame = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none

        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: frame.size)
        let view = NSView(frame: root.frame)
        // Layer-hosting: assign the layer before turning on wantsLayer.
        view.layer = root
        view.wantsLayer = true
        panel.contentView = view
        addPuffs(to: root)

        panel.orderFrontRegardless()
        sound?.stop()
        sound?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            panel.orderOut(nil)
        }
    }

    /// A ring of soft cloud puffs around a centre puff that swell, drift outward and fade.
    /// With Reduce Motion they only fade, in place.
    private static func addPuffs(to root: CALayer) {
        let reduceMotion = ActionFeedback.reduceMotion
        let centre = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
        let puffCount = 7
        let spread = size * 0.26

        for index in 0...puffCount {
            let isCentre = index == puffCount
            let angle = CGFloat(index) / CGFloat(puffCount) * 2 * .pi + 0.4
            let diameter = size * (isCentre ? 0.42 : 0.3)
            let offset = isCentre ? .zero : CGPoint(x: cos(angle) * spread, y: sin(angle) * spread)

            let puff = CALayer()
            puff.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            puff.cornerRadius = diameter / 2
            puff.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
            puff.borderColor = NSColor(white: 0.75, alpha: 1).cgColor
            puff.borderWidth = 1
            puff.shadowColor = NSColor.black.cgColor
            puff.shadowOpacity = 0.25
            puff.shadowRadius = 3
            puff.shadowOffset = CGSize(width: 0, height: -1)
            puff.position = CGPoint(x: centre.x + offset.x * 1.2, y: centre.y + offset.y * 1.2)
            puff.opacity = 0
            root.addSublayer(puff)

            let drift = CABasicAnimation(keyPath: "position")
            drift.fromValue = NSValue(point: CGPoint(x: centre.x + offset.x * 0.4, y: centre.y + offset.y * 0.4))
            drift.toValue = NSValue(point: CGPoint(x: centre.x + offset.x * 1.5, y: centre.y + offset.y * 1.5))

            let swell = CAKeyframeAnimation(keyPath: "transform.scale")
            swell.values = [0.3, 1.0, 1.15]
            swell.keyTimes = [0, 0.4, 1]

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.95, 0.9, 0]
            fade.keyTimes = [0, 0.15, 0.55, 1]

            let group = CAAnimationGroup()
            group.animations = reduceMotion ? [fade] : [drift, swell, fade]
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            puff.add(group, forKey: "poof")
        }
    }
}
