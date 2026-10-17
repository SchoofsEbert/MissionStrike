import AppKit
import SwiftUI

/// How far along the first-run tip is. Kept in UserDefaults, apart from the settings.
struct FirstRunHintProgress: Equatable {
    static let sessionLimit = 3
    private static let sessionsKey = "firstRunHintSessionsShown"
    private static let finishedKey = "firstRunHintFinished"

    var sessionsShown = 0
    /// MissionStrike has acted once: the tip has done its job.
    var isFinished = false

    /// Whether the next visit to Mission Control gets the tip.
    var isPending: Bool {
        !isFinished && sessionsShown < Self.sessionLimit
    }

    /// Whether to show the tip now. A visit that only restarted the session (a swipe between
    /// Spaces does) shows it again if it was showing, without counting another visit.
    func shouldShow(continuingVisit: Bool) -> Bool {
        continuingVisit ? !isFinished : isPending
    }

    mutating func shown(continuingVisit: Bool) {
        if !continuingVisit {
            sessionsShown += 1
        }
    }

    init(sessionsShown: Int = 0, isFinished: Bool = false) {
        self.sessionsShown = sessionsShown
        self.isFinished = isFinished
    }

    init(_ defaults: UserDefaults) {
        sessionsShown = defaults.integer(forKey: Self.sessionsKey)
        isFinished = defaults.bool(forKey: Self.finishedKey)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(sessionsShown, forKey: Self.sessionsKey)
        defaults.set(isFinished, forKey: Self.finishedKey)
    }
}

/// The first few times Mission Control opens, a tip at the bottom says how to close a window,
/// until MissionStrike has acted once.
@MainActor
final class FirstRunHint {
    static let shared = FirstRunHint()
    private init() {}

    private static let showDelay: Duration = .milliseconds(500)
    /// A session that starts again this soon after the tip was showing is the same visit.
    private static let sameVisit: Duration = .seconds(2)

    private let canvas = OverlayCanvas()
    private var progress = FirstRunHintProgress(.standard)
    /// When a session ended while the tip was showing.
    private var hiddenByClose: ContinuousClock.Instant?
    private var generation = 0

    var isPending: Bool {
        SettingsStore.shared.current.showFirstRunHint && progress.isPending
    }

    /// Posted from inside the tap callback at times: waits in a task.
    func missionControlDidOpen() {
        let continuingVisit = hiddenByClose.map { ContinuousClock.now - $0 < Self.sameVisit } ?? false
        hiddenByClose = nil
        let settings = SettingsStore.shared.current
        guard settings.showFirstRunHint, progress.shouldShow(continuingVisit: continuingVisit),
              let message = Self.message(for: settings) else {
            return
        }
        generation += 1
        let generation = generation
        Task { @MainActor in
            try? await Task.sleep(for: Self.showDelay)
            guard generation == self.generation, MissionControlSession.current != nil,
                  !KeyboardHints.shared.isActive, progress.shouldShow(continuingVisit: continuingVisit) else {
                return
            }
            progress.shown(continuingVisit: continuingVisit)
            progress.save(to: .standard)
            show(message)
        }
    }

    func missionControlDidClose() {
        if canvas.isVisible {
            hiddenByClose = .now
        }
        hide()
    }

    func actionSucceeded() {
        hide()
        guard !progress.isFinished else { return }
        progress.isFinished = true
        progress.save(to: .standard)
    }

    /// Hides the tip without counting anything, e.g. for the keyboard hints' own legend.
    func hide() {
        generation += 1
        canvas.hide()
    }

    private func show(_ message: String) {
        canvas.show(on: OverlayCanvas.pointerScreen.map { [$0] } ?? []) { screen in
            OverlayTip(text: message)
                .placed(in: OverlayCanvas.bottomArea(in: screen), alignment: .bottom)
        }
    }

    /// "Middle-click or ⌥-click a window to close it · Right-click for more", as the settings
    /// have it; nil when there's no click to tell about.
    static func message(for settings: Settings) -> String? {
        var parts: [String] = []
        let clicks = settings.closeClickNames
        if let first = clicks.first {
            let names = ([first.prefix(1).uppercased() + first.dropFirst()] + clicks.dropFirst()).joined(separator: " or ")
            parts.append("\(names) a window to close it")
        }
        if settings.enableContextMenu {
            parts.append("Right-click for more")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A line of text on a material capsule, for tips and the keyboard hints' legend.
struct OverlayTip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }
}
