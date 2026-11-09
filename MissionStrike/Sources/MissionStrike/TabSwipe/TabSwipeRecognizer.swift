import CoreGraphics

/// Turns three-finger touches into tab switches: one per stretch of sideways travel, so a
/// longer swipe goes further and swiping back returns. Works on where the fingers are, not how
/// fast they move, so a slow swipe counts as much as a quick one. Pure, so it can be tested
/// without a trackpad.
struct TabSwipeRecognizer {
    enum Step: Equatable {
        case previous
        case next
    }

    static let fingerCount = 3

    private enum Phase: Equatable {
        case idle
        /// Measuring from `anchor`, the fingers' centre at touch-down or at the last step.
        /// After a step the swipe is horizontal: vertical drift no longer cancels it.
        case tracking(anchor: CGPoint, hasStepped: Bool)
        /// Not a tab swipe (vertical, or more fingers): ignored until fewer than three touch.
        case ignored
    }

    private var phase = Phase.idle
    private let firstStep: CGFloat
    private let repeatStep: CGFloat
    private let verticalLimit: CGFloat

    init(config: MissionStrikeConfig = .default) {
        firstStep = config.tabSwipeFirstStep
        repeatStep = config.tabSwipeRepeatStep
        verticalLimit = config.tabSwipeVerticalLimit
    }

    /// Takes the normalized positions of the fingers on the trackpad; returns a step when the
    /// swipe has travelled far enough for one.
    mutating func update(touching positions: [CGPoint]) -> Step? {
        guard positions.count >= Self.fingerCount else {
            phase = .idle
            return nil
        }
        // A fourth finger makes it another gesture, also once it lifts again.
        guard positions.count == Self.fingerCount else {
            phase = .ignored
            return nil
        }
        let centre = CGPoint(
            x: positions.reduce(0) { $0 + $1.x } / CGFloat(positions.count),
            y: positions.reduce(0) { $0 + $1.y } / CGFloat(positions.count)
        )

        switch phase {
        case .ignored:
            return nil
        case .idle:
            phase = .tracking(anchor: centre, hasStepped: false)
            return nil
        case .tracking(let anchor, let hasStepped):
            let dx = centre.x - anchor.x
            let dy = centre.y - anchor.y
            if !hasStepped, abs(dy) >= verticalLimit, abs(dy) > abs(dx) {
                phase = .ignored
                return nil
            }
            guard abs(dx) >= (hasStepped ? repeatStep : firstStep), hasStepped || abs(dx) > abs(dy) else {
                return nil
            }
            phase = .tracking(anchor: centre, hasStepped: true)
            return dx > 0 ? .next : .previous
        }
    }
}
