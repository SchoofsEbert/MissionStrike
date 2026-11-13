import SwiftUI
import ApplicationServices

struct OnboardingView: View {
    @State private var currentStep = 0
    /// Direction of the last step change; decides which side pages enter and leave from.
    @State private var isMovingForward = true
    @State private var isAccessibilityEnabled = AXIsProcessTrusted()
    @State private var accessibilityRetryTask: Task<Void, Never>?
    @AppStorage(SettingKey.enableWindowSnapping.rawValue)
    private var enableWindowSnapping = SettingKey.enableWindowSnapping.defaultBool

    /// Called when the user finishes onboarding.
    var onComplete: () -> Void

    /// Fires when any app's accessibility trust status changes in System Settings.
    private let accessibilityChanged = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name("com.apple.accessibility.api"))

    private let totalSteps = 6

    var body: some View {
        VStack(spacing: 0) {
            // Step content: a short directional slide with a cross-fade
            ZStack {
                switch currentStep {
                case 0: welcomeStep.transition(stepTransition)
                case 1: accessibilityStep.transition(stepTransition)
                case 2: howItWorksStep.transition(stepTransition)
                case 3: moreWaysStep.transition(stepTransition)
                case 4: snappingStep.transition(stepTransition)
                case 5: readyStep.transition(stepTransition)
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Divider()

            // Navigation bar
            HStack {
                pageDots

                Spacer()

                if currentStep > 0 && currentStep < totalSteps - 1 {
                    Button("Back") {
                        go(to: currentStep - 1)
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                }

                if currentStep == 1 && !isAccessibilityEnabled {
                    Button("Skip for Now") {
                        go(to: currentStep + 1)
                    }
                } else if currentStep == 4 && !enableWindowSnapping {
                    Button("Not Now") {
                        go(to: currentStep + 1)
                    }
                    Button("Turn On") {
                        enableWindowSnapping = true
                        go(to: currentStep + 1)
                    }
                    .keyboardShortcut(.defaultAction)
                } else if currentStep < totalSteps - 1 {
                    Button("Continue") {
                        go(to: currentStep + 1)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(isAccessibilityEnabled ? "Get Started" : "Done") {
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
            accessibilityRetryTask?.cancel()
            accessibilityRetryTask = AccessibilityTrustRetry.schedule {
                applyAccessibilityGrantIfNeeded()
            }
        }
        .task(id: isAccessibilityEnabled) {
            // The change notification is not always sent, so also check while access is off.
            while !isAccessibilityEnabled && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                applyAccessibilityGrantIfNeeded()
            }
        }
        .onDisappear {
            accessibilityRetryTask?.cancel()
            accessibilityRetryTask = nil
        }
        .frame(width: 520, height: 500)
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
                Text("Welcome to Vantage")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Close windows and Spaces directly from Mission Control with a single click, "
                     + "and snap windows into place from the keyboard.")
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

                Text("Vantage needs Accessibility access to detect your clicks in Mission Control and close windows.")
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
                Button("Open System Settings", systemImage: "gear", action: AccessibilityPermission.request)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }

            Spacer()
        }
        .padding(24)
        .animation(.smooth(duration: 0.3), value: isAccessibilityEnabled)
        .onAppear {
            isAccessibilityEnabled = AXIsProcessTrusted()
        }
    }

    // MARK: - Step 6: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: isAccessibilityEnabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(isAccessibilityEnabled ? .green : .orange)
                .contentTransition(.symbolEffect(.replace))

            VStack(spacing: 8) {
                Text(isAccessibilityEnabled ? "You're All Set!" : "Almost There")
                    .font(.title)
                    .fontWeight(.bold)

                Text(isAccessibilityEnabled
                     ? "Vantage is running in the background. Look for the icon in your menu bar."
                     : "Vantage needs Accessibility access before it can close windows. "
                        + "You can also grant it later from the menu bar.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.body)
                    .frame(maxWidth: 380)
            }

            if !isAccessibilityEnabled {
                Button("Grant Access", systemImage: "lock.shield", action: AccessibilityPermission.request)
                .controlSize(.large)
            }

            // Quick tips
            VStack(alignment: .leading, spacing: 8) {
                tipRow(text: "Open Mission Control with a swipe up or F3")
                tipRow(text: "Pause Vantage or open Settings from the menu bar")
                tipRow(text: "Updates show what's new and install with one click")
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
        .animation(.smooth(duration: 0.3), value: isAccessibilityEnabled)
    }

    private func applyAccessibilityGrantIfNeeded() {
        let wasTrusted = isAccessibilityEnabled
        isAccessibilityEnabled = AXIsProcessTrusted()
        guard isAccessibilityEnabled, !wasTrusted else { return }

        EventTapManager.shared.start()
        // Auto-advance past the accessibility step
        if currentStep == 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                go(to: 2)
            }
        }
    }

    // MARK: - Navigation

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<totalSteps, id: \.self) { step in
                Circle()
                    .fill(Color.primary.opacity(step == currentStep ? 0.7 : 0.2))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(currentStep + 1) of \(totalSteps)")
    }

    /// Pages slide a short distance in the direction of travel while cross-fading.
    private var stepTransition: AnyTransition {
        let distance: CGFloat = 40
        return .asymmetric(
            insertion: .offset(x: isMovingForward ? distance : -distance).combined(with: .opacity),
            removal: .offset(x: isMovingForward ? -distance : distance).combined(with: .opacity)
        )
    }

    private func go(to step: Int) {
        guard step != currentStep, (0..<totalSteps).contains(step) else { return }
        // Set the direction in its own update first: the outgoing page keeps the
        // transition from its last render, so it must already point the right way.
        isMovingForward = step > currentStep
        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.35)) {
                currentStep = step
            }
        }
    }
}

// MARK: - Layout Helpers

extension OnboardingView {
    /// Title plus left-aligned rows, centred vertically on the page.
    func stepPage<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: 400, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    // MARK: - Reusable Rows

    func featureRow(icon: String, title: String, description: String) -> some View {
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
