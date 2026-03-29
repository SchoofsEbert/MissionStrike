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

    private let totalSteps = 3

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: accessibilityStep
                case 2: howItWorksStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation bar
            HStack {
                // Page indicator dots
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { index in
                        Circle()
                            .fill(index == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                if currentStep > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentStep -= 1
                        }
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                }

                if currentStep < totalSteps - 1 {
                    Button("Continue") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentStep += 1
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") {
                        onComplete()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .onReceive(accessibilityChanged) { _ in
            isAccessibilityEnabled = AXIsProcessTrusted()
            if isAccessibilityEnabled {
                EventTapManager.shared.start()
            }
        }
        .frame(width: 440, height: 340)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()

            if let nsImage = NSApplication.shared.applicationIconImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
            }

            Text("Welcome to MissionStrike")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Close windows and Spaces directly from Mission Control\nwith a single click — no more hunting for tiny close buttons.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.body)
                .frame(maxWidth: 340)

            Spacer()
        }
        .padding()
    }

    // MARK: - Step 2: Accessibility

    private var accessibilityStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            Text("Accessibility Permission")
                .font(.title2)
                .fontWeight(.semibold)

            Text("MissionStrike needs Accessibility access to detect your clicks\nin Mission Control and close windows on your behalf.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.body)
                .frame(maxWidth: 340)

            HStack(spacing: 8) {
                Image(systemName: isAccessibilityEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isAccessibilityEnabled ? .green : .orange)
                Text(isAccessibilityEnabled ? "Permission Granted" : "Permission Required")
                    .fontWeight(.medium)
            }
            .padding(.top, 4)

            if !isAccessibilityEnabled {
                Button("Open System Settings") {
                    let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
                    _ = AXIsProcessTrustedWithOptions(options)
                }
                .controlSize(.large)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            isAccessibilityEnabled = AXIsProcessTrusted()
        }
    }

    // MARK: - Step 3: How It Works

    private var howItWorksStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("How It Works")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 14) {
                triggerRow(
                    icon: "computermouse.fill",
                    title: "Middle Click",
                    description: "Click any window in Mission Control\nwith your middle mouse button to close it."
                )

                triggerRow(
                    icon: "option",
                    title: "Option + Left Click",
                    description: "Hold Option and left-click — perfect\nif you don't have a middle mouse button."
                )

                triggerRow(
                    icon: "square.stack.3d.up",
                    title: "Close Spaces",
                    description: "Same gestures work on Spaces in the\ntop bar — no more waiting for the ×."
                )
            }
            .frame(maxWidth: 360)

            Spacer()
        }
        .padding()
    }

    private func triggerRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

