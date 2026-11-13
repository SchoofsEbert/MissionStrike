import SwiftUI

extension OnboardingView {
    // MARK: - Step 5: Snapping Windows

    var snappingStep: some View {
        stepPage(title: "Snapping Windows") {
            SnappingToggle()
            featureRow(
                icon: "rectangle.split.2x1",
                title: "⌃⌥← and ⌃⌥→",
                description: "Snap the window in front to a side. Press again for a third, then two-thirds."
            )
            featureRow(
                icon: "square.grid.2x2",
                title: "Choose the Other Side",
                description: "Your other windows show in the free part. Press a number or click one to put it there."
            )
            featureRow(
                icon: "arrow.up.left.and.arrow.down.right",
                title: "⌃⌥↑ and ⌃⌥↓",
                description: "Fill the screen, or put the window back where it was."
            )
            featureRow(
                icon: "display.2",
                title: "⇧⌃⌥← and ⇧⌃⌥→",
                description: "Move the window to another display. Change any shortcut in Settings."
            )
        }
    }
}

/// Snapping is off by default: offered here so it's found.
private struct SnappingToggle: View {
    @AppStorage(SettingKey.enableWindowSnapping.rawValue)
    private var enableWindowSnapping = SettingKey.enableWindowSnapping.defaultBool

    var body: some View {
        Toggle("Snap with Shortcuts", isOn: $enableWindowSnapping)
            .toggleStyle(.switch)
            .fontWeight(.medium)
            .padding(.bottom, 4)
    }
}
