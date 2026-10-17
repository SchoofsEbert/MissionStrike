import AppKit
import SwiftUI

/// While the trigger modifier is held in Mission Control, each thumbnail shows a chip with its
/// app and how many windows of that app Mission Control shows, so a ⌘-click (close all) holds
/// no surprises.
@MainActor
final class WindowCountChips {
    static let shared = WindowCountChips()
    private init() {}

    struct Chip: Equatable {
        let name: String
        let count: Int
        /// The thumbnail, in AppKit screen coordinates.
        let thumbnail: CGRect

        var label: String { "\(name) · \(count)" }
    }

    /// While the modifier stays held, look again this often in case windows came or went.
    private static let refreshInterval: TimeInterval = 2
    /// Mission Control re-lays out its thumbnails after a window closes; wait for that.
    private static let relayoutDelay: Duration = .milliseconds(450)
    /// Room inside a thumbnail's corner, and on the left for the hover badge.
    private static let inset: CGFloat = 8
    private static let hoverBadgeRoom: CGFloat = 36

    private let canvas = OverlayCanvas()
    private var timer: Timer?
    private var shown: [Chip] = []

    /// Called from the event tap on every modifier change. Cheap: the thumbnails are looked up
    /// in a task once the callback has returned.
    func modifiersChanged(_ flags: CGEventFlags) {
        let settings = SettingsStore.shared.current
        guard settings.showWindowCounts,
              let mask = settings.leftClickModifier?.eventFlagMask, flags.contains(mask),
              MissionControlSession.isActive() else {
            hide()
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { WindowCountChips.shared.refresh(maxAge: .zero) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // The keyboard hints or a recent hold may have looked already.
        refresh(maxAge: .seconds(1))
    }

    /// A window closed or a Space went: count again once Mission Control has moved things.
    func layoutMayHaveChanged() {
        guard timer != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: Self.relayoutDelay)
            refresh(maxAge: .zero)
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        shown = []
        canvas.hide()
    }

    private func refresh(maxAge: Duration) {
        Task { @MainActor in
            let layout = await MissionControlThumbnails.shared.layout(maxAge: maxAge)
            // Released or closed in the meantime.
            guard timer != nil, !MissionControlContextMenu.isOpen else { return }
            let chips = Self.chips(for: layout.thumbnails.map { ($0.window.pid, $0.appName, $0.frame) })
            guard chips != shown || !canvas.isVisible else { return }
            shown = chips
            canvas.show { screen in
                let onScreen = chips.filter { NSMouseInRect(NSPoint(x: $0.thumbnail.midX, y: $0.thumbnail.midY), screen.frame, false) }
                ZStack(alignment: .topLeading) {
                    ForEach(Array(onScreen.enumerated()), id: \.offset) { _, chip in
                        WindowCountChipView(chip: chip)
                            .placed(in: OverlayCanvas.local(Self.chipArea(on: chip.thumbnail), in: screen.frame), alignment: .topTrailing)
                    }
                }
            }
        }
    }

    /// One chip per thumbnail: its app's name and how many of the thumbnails are that app's.
    static func chips(for thumbnails: [(pid: pid_t, name: String, frame: CGRect)]) -> [Chip] {
        var counts: [pid_t: Int] = [:]
        for thumbnail in thumbnails {
            counts[thumbnail.pid, default: 0] += 1
        }
        return thumbnails.map { Chip(name: $0.name, count: counts[$0.pid] ?? 0, thumbnail: $0.frame) }
    }

    /// Where a chip may sit on a thumbnail (AppKit coordinates): along the top, inside the
    /// corner and clear of the hover badge, which sits at the top left. Long names are cut short.
    static func chipArea(on thumbnail: CGRect) -> CGRect {
        let width = max(thumbnail.width - inset - hoverBadgeRoom, 0)
        return CGRect(
            x: thumbnail.maxX - inset - width,
            y: thumbnail.minY + inset,
            width: width,
            height: max(thumbnail.height - 2 * inset, 0)
        )
    }
}

/// "Safari · 4" on a small material capsule; the name gives way before the count does.
struct WindowCountChipView: View {
    let chip: WindowCountChips.Chip

    var body: some View {
        HStack(spacing: 4) {
            Text(chip.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("· \(chip.count)")
                .monospacedDigit()
                .fixedSize()
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
