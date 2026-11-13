import SwiftUI

extension OnboardingView {
    // MARK: - Step 3: Closing Windows

    var howItWorksStep: some View {
        stepPage(title: "Closing Windows") {
            sectionLabel("Triggers")
            featureRow(
                icon: "computermouse.fill",
                title: "Middle-Click",
                description: "Click any window in Mission Control to close it."
            )
            featureRow(
                icon: "option",
                title: "Option + Click",
                description: "No middle button? Hold Option and click. You can change the key in Settings."
            )
            featureRow(
                icon: "square.stack.3d.up",
                title: "Spaces",
                description: "The same clicks remove a Space in the bar at the top."
            )

            sectionLabel("Modifiers").padding(.top, 6)
            featureRow(
                icon: "minus.circle",
                title: "⇧ Shift + Click",
                description: "Minimize the window to the Dock instead."
            )
            featureRow(
                icon: "xmark.circle.fill",
                title: "⌘ Command + Click",
                description: "Close all of that app's windows at once."
            )
        }
    }

    // MARK: - Step 4: More Ways

    var moreWaysStep: some View {
        stepPage(title: "More Ways") {
            featureRow(
                icon: "xmark.circle",
                title: "See What a Click Will Do",
                description: "Hold Option over a window and a close button marks it. Add ⇧ to minimize or ⌘ to close all."
            )
            featureRow(
                icon: "contextualmenu.and.cursorarrow",
                title: "Right-Click Menu",
                description: "Right-click a window to close, minimize, hide or quit its app, "
                    + "or the background to quit apps with no windows."
            )
            featureRow(
                icon: "command",
                title: "Keyboard Shortcuts",
                description: "Point at a window and press ⌘W to close, ⌘M to minimize, ⌘H to hide or ⌘Q to quit."
            )
            featureRow(
                icon: "dock.rectangle",
                title: "Dock Middle-Click",
                description: "Turn it on in Settings to quit an app by middle-clicking its Dock icon."
            )
        }
    }

    // MARK: - Step 5: Snapping Windows

    var snappingStep: some View {
        stepPage(title: "Snapping Windows") {
            featureRow(
                icon: "rectangle.lefthalf.inset.filled",
                title: "Snap to a Side",
                description: "Press ⌃⌥← or ⌃⌥→. Press again for a third, then two-thirds of the screen."
            )
            featureRow(
                icon: "square.grid.2x2",
                title: "Choose the Other Side",
                description: "Your other windows show in the free part. Press a number or click one to put it there."
            )
            featureRow(
                icon: "arrow.up.left.and.arrow.down.right",
                title: "Fill and Restore",
                description: "Press ⌃⌥↑ to fill the screen, and ⌃⌥↓ to put the window back where it was."
            )
            featureRow(
                icon: "display",
                title: "Another Display",
                description: "Press ⇧⌃⌥← or ⇧⌃⌥→. You can change every shortcut in Settings."
            )
        }
    }
}
