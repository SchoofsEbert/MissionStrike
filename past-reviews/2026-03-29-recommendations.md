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

### 7. ✅ ADDRESSED — Event Tap Watchdog / Auto-Recovery

The event tap callback now handles `tapDisabledByTimeout` and `tapDisabledByUserInput`. When macOS disables the tap (e.g., due to resource pressure or the callback taking too long), the callback immediately re-enables it via `CGEvent.tapEnable(tap:enable:)` and logs a warning. The mach port is passed to the callback through the `userInfo`/`refcon` pointer using a heap-allocated `UnsafeMutablePointer<CFMachPort?>`, which is properly allocated in `start()` and deallocated in `stop()`. No relaunch required for recovery.

### 8. ✅ ADDRESSED — Protocol-Based Abstractions for Testability

Added `MissionControlDetecting` protocol with an `isActive() -> Bool` contract. `MissionControlActiveChecker` now conforms to it and exposes a testable pure static method `isActive(windowList:screenSizes:config:)` that takes raw data with no system dependencies. The live `isActive()` instance method is a thin wrapper that gathers `CGWindowListCopyWindowInfo` and `NSScreen.screens` data and delegates to the static method. Tests call the static method directly with mock data.

### 9. ✅ ADDRESSED — Unit Tests for Detection Heuristics

Added `MissionStrikeTests` test target with 13 tests across 2 suites using Swift Testing. Tests cover: positive detection (layer 18/20), negative detection (too small, wrong owner, wrong layer, empty list), multi-display scenarios (secondary screen coverage, too-small-for-all), fallback screen size, and custom config (custom layers, custom coverage fraction). All tests use mock `CGWindowListCopyWindowInfo`-shaped data via the pure `isActive(windowList:screenSizes:config:)` method — no system APIs involved.

### 10. ✅ ADDRESSED — Extract Magic Values into a Configuration Object

Created `MissionStrikeConfig` struct centralizing all tunable constants: `missionControlOverlayLayers`, `minimumScreenCoverageFraction`, `fallbackScreenSize`, `ignoredWindowOwners`, and `debounceInterval`. A `static let default` provides the production values. `MissionControlActiveChecker` accepts a config via its initializer and testable static method. `EventTapManager` reads the debounce interval from `MissionStrikeConfig.default`. `MissionControlManager.findTargetCGWindow` reads ignored owners from config. No more scattered magic numbers.

### 11. ✅ ADDRESSED — Structured Concurrency Audit

The rapid-click racing concern is resolved by the 300ms debounce implemented in #26. The event tap callback now gates dispatched `Task` calls behind a timestamp check, ensuring only one close operation can be in-flight at a time. The fire-and-forget `Task { @MainActor in ... }` pattern is safe with the debounce in place — a serial `AsyncStream` is no longer necessary.

### 12. ✅ ADDRESSED — SwiftLint / Formatting

Added `.swiftlint.yml` with a rule set tailored to the project: `.build` and `Package.swift` excluded, line length set to 140/200, opt-in rules enabled (e.g., `empty_count`, `closure_spacing`, `modifier_order`, `sorted_first_last`), and thresholds tuned for the Accessibility API-heavy codebase. All existing source files were fixed to pass with **0 violations**. Intentional `force_cast` sites (CFTypeRef → AXUIElement, documented in code review #2) use inline `swiftlint:disable:this` comments.

### 13. ✅ ADDRESSED — Logging Levels Review

Audited all log statements across the codebase. Demoted 5 routine success messages in `MissionControlManager.swift` from `.info` to `.debug` (closed window/Space confirmations, CGWindow target identification). `.info` is now reserved for state transitions (tap started/stopped, permissions granted/revoked, first launch). `.warning` and `.error` levels were already used correctly. The Console is now clean during normal operation; use `log stream --level debug` to see per-close details.

---

## 🚀 New Feature Ideas

### 14. ✅ ADDRESSED — Close All Windows of an App (Modifier + Middle Click)

**Cmd + Middle Click** (or **Cmd + configured-modifier + Left Click**) on any window in Mission Control now closes all windows belonging to that app. `MissionControlManager.closeAllWindowsForApp` extracts the PID from the clicked element (with CGWindow fallback), enumerates all `AXWindow` elements for that PID, and presses each close button. If triggered from the Spaces bar, it falls back to normal Space closing. The action is determined in the event tap callback by checking for `maskCommand` in the event flags.

### 15. ✅ ADDRESSED — Minimize Instead of Close (Shift + Middle Click)

**Shift + Middle Click** (or **Shift + configured-modifier + Left Click**) now minimizes a window to the Dock instead of closing it. `MissionControlManager.minimizeWindow` sets the `kAXMinimizedAttribute` to `true` on the target window, with a CGWindow fallback path. Spaces bar clicks are ignored (minimizing a Space doesn't make sense). The action is determined in the event tap callback by checking for `maskShift` in the event flags.

### 16. ✅ ADDRESSED — Customizable Trigger Bindings

The event tap trigger is now fully configurable via Settings:
- **Middle Mouse Click** — toggle on/off (default: on)
- **Left Click Modifier** — picker with ⌥ Option (default), ⌃ Control, or Disabled

Action modifiers layer on top of any trigger: +⌘ Cmd = close all, +⇧ Shift = minimize. Preferences are read from UserDefaults in the event tap callback (thread-safe). The `TriggerModifier` enum maps each option to its `CGEventFlags` mask. Option and Control are offered as trigger modifiers; Command and Shift are reserved for action modifiers to avoid conflicts.

### 17. App Exclusion List (Whitelist / Blacklist)

Some users may want to protect certain apps from accidental closure (e.g., a long-running terminal session or a virtual machine). A simple list in Settings where users can add app names/bundle IDs to an "exclude from closing" list would add a safety net.

### 18. ✅ ADDRESSED — Auto-Update via GitHub Releases API

Instead of the heavyweight Sparkle framework, a lightweight `UpdateChecker` polls the GitHub Releases API (`/repos/SchoofsEbert/MissionStrike/releases/latest`). It compares the `tag_name` against the running `CFBundleShortVersionString` using semantic version comparison. On launch, an automatic background check runs once per 24 hours (timestamp stored in UserDefaults). A "Check for Updates…" menu item triggers an immediate check. If an update is found, an alert offers a "Download" button that opens the GitHub release page in the browser. No external dependencies, no self-hosting — fully GitHub-powered.

### 19. Stage Manager Support

macOS Ventura+ introduced Stage Manager as an alternative window management mode. Investigating whether MissionStrike's event tap and Accessibility approach can work within Stage Manager's overlay would expand the app's usefulness. The AX tree structure under Stage Manager may differ from Mission Control.

### 20. ✅ ADDRESSED — Multi-Display Awareness

`MissionControlActiveChecker.isActive()` now checks all connected displays instead of only `NSScreen.main`. Screen thresholds are pre-computed from `NSScreen.screens` and each Dock overlay is tested against every screen's minimum dimensions using `contains`. This fixes false negatives on multi-monitor setups where the overlay for a smaller secondary screen would fail the size check against the primary. Single-monitor behavior is identical. Includes a fallback for the edge case where `NSScreen.screens` is empty.

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

### 25. ✅ ADDRESSED — Graceful Handling of `CGEvent.tapCreate` Failure on Apple Silicon

On some Apple Silicon Macs with specific security configurations (e.g., MDM-managed devices), event tap creation can fail even with Accessibility enabled. `EventTapManager` now posts an `.eventTapCreationFailed` notification when `CGEvent.tapCreate` returns `nil`. `AppDelegate` observes this notification and presents an `NSAlert` with a clear explanation and actionable troubleshooting steps: re-adding the app in Accessibility settings, restarting the Mac, and contacting IT if the device is MDM-managed. The alert offers three buttons: "Open Accessibility Settings" (deep-links to the preference pane), "Retry" (attempts `start()` again), and "Quit".

### 26. ✅ ADDRESSED — Rapid Click Debouncing

The event tap callback now implements a 300ms timestamp-based debounce using `mach_absolute_time()`. If a click arrives within 300ms of the last processed click, it is silently swallowed (returns `nil`) and logged at `.debug` level. The timestamp is stored in a `nonisolated(unsafe)` file-private variable, which is safe because the callback always runs on the same run-loop thread. This prevents racing close operations from double-clicks.

### 27. Coordinate System Edge Cases

`CGEvent.location` returns coordinates in the global display coordinate space, while `CGWindowListCopyWindowInfo` bounds use the same space — but Retina scaling and display arrangement offsets can cause subtle mismatches. Verifying correct behavior on mixed-DPI multi-monitor setups would prevent hard-to-reproduce bugs.

### 28. ✅ ADDRESSED — Handle App Nap

`AppDelegate.applicationDidFinishLaunching` now calls `ProcessInfo.processInfo.beginActivity(options:reason:)` with `.userInitiated` and `.idleSystemSleepDisabled` flags. This prevents macOS from applying App Nap to MissionStrike, ensuring the event tap run loop remains responsive even when the app has no visible windows. The activity token is stored for the lifetime of the app.

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

