import Foundation

/// Retries an action while Accessibility TCC catches up after a grant notification.
///
/// `com.apple.accessibility.api` often fires before `AXIsProcessTrusted()` flips true.
/// Callers should cancel the returned task when starting a new retry sequence or
/// when the owning UI goes away.
enum AccessibilityTrustRetry {
    /// Absolute offsets (seconds from schedule time) for follow-up checks after the
    /// immediate first attempt.
    static let retryOffsetsSeconds: [TimeInterval] = [0.3, 0.6, 1.0, 2.0, 3.0]

    /// Runs `action` immediately (asynchronously on the main actor), then again at
    /// each offset in ``retryOffsetsSeconds``.
    /// - Returns: A cancellable task; cancel it to stop further retries.
    @MainActor
    static func schedule(action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            action()
            guard !Task.isCancelled else { return }

            var previousOffset: TimeInterval = 0
            for offset in retryOffsetsSeconds {
                let gap = offset - previousOffset
                previousOffset = offset
                let nanoseconds = UInt64(gap * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                action()
            }
        }
    }
}
