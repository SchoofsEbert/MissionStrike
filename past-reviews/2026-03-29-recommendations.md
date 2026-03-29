# MissionStrike — Recommendations & Ideas

> Date: March 29, 2026
> Scope: UX improvements, codebase enhancements, and new feature ideas.

---

## 🎨 UX Improvements

### 1. Confirmation Before Closing a Space

Closing a Space is a destructive, irreversible action — all windows in that Space get shuffled into adjacent Spaces. Consider adding an optional confirmation step (e.g., a brief tooltip or a "hold for 0.3s" mechanic) before executing `AXRemoveDesktop`. This could be a toggle in Settings ("Confirm before closing Spaces").

### 2. ✅ ADDRESSED — Visual Indicator for Active/Inactive State

The menu bar icon now reflects the current state. When the event tap is running and accessibility is enabled, the icon appears normally. When inactive (accessibility denied or event tap failed), an orange dot badge is drawn on the bottom-right of the icon and the tooltip changes to "MissionStrike: Inactive — check Accessibility permissions." `EventTapManager` posts a `.eventTapStateChanged` notification on start/stop, and `AppDelegate` observes both that and the `com.apple.accessibility.api` distributed notification to keep the icon in sync.

### 3. ✅ ADDRESSED — Onboarding Walkthrough

On first launch, MissionStrike now shows a 3-step onboarding window instead of opening Settings directly:

1. **Welcome** — App icon, name, and a brief description of what MissionStrike does.
2. **Accessibility Permission** — Explains why the permission is needed, shows a live granted/required status indicator, and provides a button to open System Settings. Status updates in real-time via `DistributedNotificationCenter`.
3. **How It Works** — Describes the three trigger methods: middle-click, Option+Left Click, and Space closing.

Navigation uses Back/Continue buttons with page indicator dots. "Get Started" on the final step closes the onboarding and opens the Settings window. Implemented in `OnboardingView.swift`, wired through `AppDelegate.openOnboardingWindow()`.

### 4. ✅ ADDRESSED — Notification on Permission Loss

`AppDelegate` now observes the `com.apple.accessibility.api` distributed notification. When the accessibility state transitions from `true → false`, MissionStrike stops the event tap, updates the menu bar icon to inactive, and delivers a macOS notification via `UNUserNotificationCenter` titled "MissionStrike Disabled" with instructions to re-enable permissions. Notification permission is requested at launch.

### 5. ✅ ADDRESSED — "About" & Version Info in the Menu

The status bar menu now includes an "About MissionStrike" item at the top. It opens a dedicated About window showing the app icon, name, version number (read from `CFBundleShortVersionString`/`CFBundleVersion` with a fallback for `swift run`), a brief description, a clickable link to the GitHub repository, and a copyright line. Implemented in `AboutView.swift`, wired through `AppDelegate.openAboutWindow()`.

### 6. Tooltip on Hover (Future macOS API)

If Apple ever exposes hover events in Mission Control through the Accessibility API, showing a subtle "×" badge on the window thumbnail under the cursor would make the close-on-click affordance more discoverable.

---

## 🏗️ Codebase & Architecture

### 7. Event Tap Watchdog / Auto-Recovery

macOS can silently disable an event tap if the system becomes resource-constrained or if the tap takes too long to process. The callback receives a `tapDisabledByTimeout` event type in this case. Currently, `eventTapCallback` does not handle this — if the tap is disabled, MissionStrike silently stops working until relaunch.

**Recommendation:** Check for `type == .tapDisabledByTimeout` in the callback and re-enable the tap:

```swift
if type == .tapDisabledByTimeout {
    if let tap = refcon?.assumingMemoryBound(to: CFMachPort.self).pointee {
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    return Unmanaged.passUnretained(event)
}
```

Pass the `eventTapPort` via `refcon` (the `userInfo` pointer) to make this work.

### 8. Protocol-Based Abstractions for Testability

`MissionControlActiveChecker`, `MissionControlManager`, and `EventTapManager` are all concrete classes with no protocol abstractions. Introducing protocols (e.g., `MissionControlDetecting`, `WindowClosing`) would allow injecting mock implementations for unit testing — particularly for the Mission Control detection heuristics and window-matching logic.

### 9. Unit Tests for Detection Heuristics

`MissionControlActiveChecker.isActive()` uses a specific set of heuristics (Dock-owned windows at layers 18/20, screen coverage fraction). These are ideal candidates for unit tests with mock `CGWindowListCopyWindowInfo` data. Even basic snapshot-style tests ("given this window list, is Mission Control detected?") would catch regressions when macOS changes behavior.

### 10. Extract Magic Values into a Configuration Object

Scattered constants like the `ignoredOwners` set, `missionControlOverlayLayers`, and `minimumScreenCoverageFraction` are good candidates for a single `MissionStrikeConfig` struct. This centralizes tuning knobs and makes it easier to adjust for future macOS versions.

### 11. ✅ ADDRESSED — Structured Concurrency Audit

The rapid-click racing concern is resolved by the 300ms debounce implemented in #26. The event tap callback now gates dispatched `Task` calls behind a timestamp check, ensuring only one close operation can be in-flight at a time. The fire-and-forget `Task { @MainActor in ... }` pattern is safe with the debounce in place — a serial `AsyncStream` is no longer necessary.

### 12. ✅ ADDRESSED — SwiftLint / Formatting

Added `.swiftlint.yml` with a rule set tailored to the project: `.build` and `Package.swift` excluded, line length set to 140/200, opt-in rules enabled (e.g., `empty_count`, `closure_spacing`, `modifier_order`, `sorted_first_last`), and thresholds tuned for the Accessibility API-heavy codebase. All existing source files were fixed to pass with **0 violations**. Intentional `force_cast` sites (CFTypeRef → AXUIElement, documented in code review #2) use inline `swiftlint:disable:this` comments.

### 13. Logging Levels Review

All successful close actions log at `.info` level. Consider demoting routine successes to `.debug` and reserving `.info` for state transitions (tap started, permissions changed). This keeps the Console cleaner during normal operation while still capturing events when debugging with `log stream`.

---

## 🚀 New Feature Ideas

### 14. Close All Windows of an App (Modifier + Middle Click)

Add a "power close" gesture: **Cmd + Middle Click** (or **Cmd + Option + Left Click**) on any window in Mission Control to close *all* windows belonging to that app. This would be incredibly useful for cleaning up browser or Finder clutter. The PID is already extracted — iterate all `AXWindow` elements for that PID and close each one.

### 15. Minimize Instead of Close (Shift + Middle Click)

Not every window needs to be destroyed. Offering **Shift + Middle Click** to *minimize* a window to the Dock (via `AXMinimize` action) would give users a non-destructive alternative. This could be gated behind a Settings toggle.

### 16. Customizable Trigger Bindings

Currently the triggers are hardcoded (middle-click + Option+Left Click). A settings UI letting users choose their preferred modifier keys (Control, Command, Shift, Option) for the left-click trigger — or disable the middle-click trigger entirely — would accommodate different workflows and mouse configurations.

### 17. App Exclusion List (Whitelist / Blacklist)

Some users may want to protect certain apps from accidental closure (e.g., a long-running terminal session or a virtual machine). A simple list in Settings where users can add app names/bundle IDs to an "exclude from closing" list would add a safety net.

### 18. Auto-Update via Sparkle

Since the app is distributed outside the Mac App Store, integrating [Sparkle](https://sparkle-project.org/) for automatic updates would be a significant quality-of-life improvement. Users currently have to manually check GitHub Releases.

### 19. Stage Manager Support

macOS Ventura+ introduced Stage Manager as an alternative window management mode. Investigating whether MissionStrike's event tap and Accessibility approach can work within Stage Manager's overlay would expand the app's usefulness. The AX tree structure under Stage Manager may differ from Mission Control.

### 20. Multi-Display Awareness

The current `MissionControlActiveChecker` only checks `NSScreen.main`. On multi-monitor setups, Mission Control spans all displays. The screen coverage check should iterate `NSScreen.screens` and match the Dock overlay bounds against the correct display, preventing false negatives on secondary screens.

### 21. Close Counter / Statistics

A lightweight stat tracker ("You've closed 142 windows and 7 Spaces this month") shown in the Settings window or About panel would be a fun, motivating addition. Stored in UserDefaults or a small SQLite/SwiftData store.

### 22. Undo Last Close

Implement a brief "undo window" by remembering the last-closed window's app and title. A global hotkey (e.g., **Cmd+Z** while in Mission Control) or a transient notification with an "Undo" button could re-open the app or restore the window. This is inherently limited (not all apps support restoring closed windows), but for apps that support `NSDocument` or restoration, it could work.

### 23. Hide from Dock While Keeping Menu Bar Accessible

`LSUIElement` is already `true`, which hides the Dock icon. But if the user hides the menu bar icon too, there's no way to access Settings other than re-launching the app. Consider adding a global keyboard shortcut (e.g., **Ctrl+Option+M**) that always opens the Settings window, regardless of menu bar visibility.

### 24. Homebrew Cask Distribution

Publishing a Homebrew Cask formula (`brew install --cask missionstrike`) would make installation and updates trivial for power users and remove the `xattr -cr` friction entirely.

---

## 🛡️ Robustness & Edge Cases

### 25. Graceful Handling of `CGEvent.tapCreate` Failure on Apple Silicon

On some Apple Silicon Macs with specific security configurations (e.g., MDM-managed devices), event tap creation can fail even with Accessibility enabled. The current code logs an error but gives the user no actionable feedback. Consider surfacing this as a user-visible alert with troubleshooting steps.

### 26. ✅ ADDRESSED — Rapid Click Debouncing

The event tap callback now implements a 300ms timestamp-based debounce using `mach_absolute_time()`. If a click arrives within 300ms of the last processed click, it is silently swallowed (returns `nil`) and logged at `.debug` level. The timestamp is stored in a `nonisolated(unsafe)` file-private variable, which is safe because the callback always runs on the same run-loop thread. This prevents racing close operations from double-clicks.

### 27. Coordinate System Edge Cases

`CGEvent.location` returns coordinates in the global display coordinate space, while `CGWindowListCopyWindowInfo` bounds use the same space — but Retina scaling and display arrangement offsets can cause subtle mismatches. Verifying correct behavior on mixed-DPI multi-monitor setups would prevent hard-to-reproduce bugs.

### 28. Handle App Nap

As a background utility with no visible windows (most of the time), macOS may aggressively apply App Nap, potentially delaying event tap processing. Consider setting `ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Event tap listening")` to prevent App Nap from throttling the run loop.

---

## Summary

| Category | Count |
|----------|-------|
| 🎨 UX Improvements | 6 |
| 🏗️ Codebase & Architecture | 7 |
| 🚀 New Features | 11 |
| 🛡️ Robustness & Edge Cases | 4 |
| **Total** | **28** |

### Top 5 High-Impact, Low-Effort Picks

1. **#7 — Event Tap Watchdog** — Prevents silent failure; a few lines of code.
2. **#14 — Close All Windows of an App** — Killer feature; PID infrastructure already exists.
3. **#26 — Rapid Click Debouncing** — Quick win for reliability.
4. **#4 — Notification on Permission Loss** — Saves users from confusion.
5. **#20 — Multi-Display Awareness** — Fixes a real bug for multi-monitor users.

