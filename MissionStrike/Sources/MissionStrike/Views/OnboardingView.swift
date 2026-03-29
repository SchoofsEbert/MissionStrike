import SwiftUI
import ApplicationServices

struct OnboardingView: View {
    @State private var currentStep = 0
    @State private var isAccessibilityEnabled = AXIsProcessTrusted()

    /// Called when the user finishes onboarding.
    var onComplete: () -> Void

    /// Fires when any app's accessibility trust status changes in System Settings.
    private let accessibilityChanged = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name("com.apple.accessibility.api"))

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            GeometryReader { geo in
                Capsule()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(
                                width: geo.size.width * CGFloat(currentStep + 1) / CGFloat(totalSteps),
                                height: 3
                            )
                            .animation(.easeInOut(duration: 0.35), value: currentStep)
                    }
            }
            .frame(height: 3)

            // Step content with slide transition
            ZStack {
                switch currentStep {
                case 0: welcomeStep.transition(.move(edge: .trailing))
                case 1: accessibilityStep.transition(.move(edge: .trailing))
                case 2: howItWorksStep.transition(.move(edge: .trailing))
                case 3: readyStep.transition(.move(edge: .trailing))
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: currentStep)

            Divider()

            // Navigation bar
            HStack {
                // Step indicator
                Text("Step \(currentStep + 1) of \(totalSteps)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                if currentStep > 0 && currentStep < totalSteps - 1 {
                    Button("Back") {
                        currentStep -= 1
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                }

                if currentStep < totalSteps - 1 {
                    Button("Continue") {
                        currentStep += 1
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") {
                        onComplete()
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onReceive(accessibilityChanged) { _ in
            isAccessibilityEnabled = AXIsProcessTrusted()
            if isAccessibilityEnabled {
                EventTapManager.shared.start()
                // Auto-advance past the accessibility step
                if currentStep == 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        currentStep = 2
                    }
                }
            }
        }
        .frame(width: 520, height: 460)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            if let nsImage = NSApplication.shared.applicationIconImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            }

            VStack(spacing: 8) {
                Text("Welcome to MissionStrike")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Close windows and Spaces directly from Mission Control\nwith a single click — no more hunting for tiny close buttons.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.body)
                    .frame(maxWidth: 380)
            }

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Step 2: Accessibility

    private var accessibilityStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: isAccessibilityEnabled ? "lock.open.fill" : "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(isAccessibilityEnabled ? .green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))

            VStack(spacing: 8) {
                Text("Accessibility Permission")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("MissionStrike needs Accessibility access to detect\nyour clicks in Mission Control and close windows.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.body)
                    .frame(maxWidth: 380)
            }

            // Status badge
            HStack(spacing: 8) {
                Image(systemName: isAccessibilityEnabled
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(isAccessibilityEnabled ? .green : .orange)
                Text(isAccessibilityEnabled ? "Permission Granted" : "Permission Required")
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isAccessibilityEnabled
                          ? Color.green.opacity(0.1)
                          : Color.orange.opacity(0.1))
            )

            if !isAccessibilityEnabled {
                Button {
                    let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
                    _ = AXIsProcessTrustedWithOptions(options)
                } label: {
                    Label("Open System Settings", systemImage: "gear")
                }
                .controlSize(.large)
            }

            Spacer()
        }
        .padding(24)
        .onAppear {
            isAccessibilityEnabled = AXIsProcessTrusted()
        }
    }

    // MARK: - Step 3: How It Works

    private var howItWorksStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("How It Works")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 16) {
                // Triggers
                Text("Triggers")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                featureRow(
                    icon: "computermouse.fill",
                    title: "Middle Click",
                    description: "Click any window in Mission Control to close it."
                )
                featureRow(
                    icon: "option",
                    title: "Option + Left Click",
                    description: "Hold Option and left-click — great without a middle button."
                )
                featureRow(
                    icon: "square.stack.3d.up",
                    title: "Spaces",
                    description: "Same gestures work on Spaces in the top bar."
                )

                Divider()

                // Modifiers
                Text("Action Modifiers")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                featureRow(
                    icon: "minus.circle",
                    title: "⇧ Shift + Click",
                    description: "Minimize a window to the Dock instead."
                )
                featureRow(
                    icon: "xmark.circle.fill",
                    title: "⌘ Command + Click",
                    description: "Close all windows from that app at once."
                )
            }
            .frame(maxWidth: 400)

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Step 4: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            VStack(spacing: 8) {
                Text("You're All Set!")
                    .font(.title)
                    .fontWeight(.bold)

                Text("MissionStrike is running in the background.\nLook for the icon in your menu bar.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.body)
                    .frame(maxWidth: 380)
            }

            // Quick tips
            VStack(alignment: .leading, spacing: 8) {
                tipRow(text: "Open Mission Control with a swipe up or F3")
                tipRow(text: "All settings can be changed from the menu bar")
                tipRow(text: "Updates install automatically with one click")
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
            )
            .frame(maxWidth: 360)

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Reusable Rows

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                    .font(.callout)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tipRow(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
