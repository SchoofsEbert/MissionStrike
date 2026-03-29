# MissionStrike — Code Review

> Review date: March 28, 2026
> Scope: Full codebase review covering correctness, safety, maintainability, and best practices.

---

## 🔴 Critical Issues

### 1. ✅ FIXED — Memory Leak in Event Tap Callback (`EventTapManager.swift:56`)

```swift
return Unmanaged.passRetained(event)
```

**Problem:** `passRetained` increments the retain count of the event every time a non-intercepted event passes through the callback. Since this fires for *every* middle-click and option-left-click outside Mission Control (and also every regular mouse event matching the mask), this is a continuous memory leak.

**Fix:** Changed to `Unmanaged.passUnretained(event)` with an explanatory comment.

---

### 2. ✅ FIXED — Unsafe Force Casts (`MissionControlManager.swift:103, 133, 177`)

```swift
AXUIElementPerformAction(closeButtonRef as! AXUIElement, ...)  // line 103
return (parentRef as! AXUIElement)                              // line 133
AXUIElementPerformAction(targetCloseBtn as! AXUIElement, ...)   // line 177
```

**Problem:** Force casts (`as!`) will crash the app at runtime if the `CFTypeRef` is not actually an `AXUIElement`. While unlikely in normal operation, Accessibility API responses can be unpredictable (e.g., under race conditions or with unusual window configurations).

**Fix:** Restructured to use `if let` nil checks on the `CFTypeRef?` first (via optional binding `let closeButtonRef`), then apply the force cast only on the non-nil value. Since `CFTypeRef` → `AXUIElement` is a CoreFoundation type cast that always succeeds (the compiler confirms this), the `as!` is safe, but the nil guard prevents acting on nil values.

---

### 3. ✅ FIXED — KVO Observer Never Removed (`AppDelegate.swift:27`)

```swift
UserDefaults.standard.addObserver(self, forKeyPath: "showMenuBarIcon", ...)
```

**Problem:** The observer is added in `applicationDidFinishLaunching` but never removed in `deinit` or `applicationWillTerminate`. In legacy KVO (which this uses), failing to remove an observer before the observer is deallocated causes a crash.

**Fix:** Migrated to the modern block-based `observe(_:options:changeHandler:)` API via `NSKeyValueObservation`. The observation token is stored as `kvoObservation` and automatically removes the observer when deallocated. Also added a `@objc dynamic var showMenuBarIcon` computed property on `UserDefaults` to enable the type-safe key path. Removed the legacy `observeValue(forKeyPath:...)` override entirely.

---

### 4. ✅ DOCUMENTED — Private API Usage (`MissionControlManager.swift:5-7`)

```swift
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError
```

**Problem:** `_AXUIElementGetWindow` is an undocumented Apple-private API. It could break without notice in any macOS update, and its use guarantees App Store rejection.

**Resolution:** Added a prominent `// MARK:` section with a multi-line `WARNING` comment documenting the risk, the purpose, the degradation behavior, and App Store implications. The fallback path already degrades gracefully.

---

## 🟠 Bugs & Logic Issues

### 5. ✅ FIXED — Unused `isMiddle` Parameter (`MissionControlManager.swift:43-45`)

```swift
func handleMouseEvent(location: CGPoint, isMiddle: Bool) {
    closeWindowAt(location: location)
}
```

**Problem:** The `isMiddle` parameter is passed from the event tap callback but never used.

**Fix:** Removed the `isMiddle` parameter from `handleMouseEvent` and updated the call site in `EventTapManager.swift` accordingly.

---

### 6. ✅ FIXED — Dead Code: `isMissionControlActive()` (`MissionControlManager.swift:39-41`)

```swift
func isMissionControlActive() -> Bool {
    return MissionControlActiveChecker.isActive()
}
```

**Problem:** This method is never called anywhere.

**Fix:** Removed the dead method entirely.

---

### 7. ✅ FIXED — Finder Incorrectly Ignored in CGWindow Fallback (`MissionControlManager.swift:144`)

```swift
let ignoredOwners = ["Dock", "Finder", "Window Server", "Wallpaper"]
```

**Problem:** Finder windows are legitimate user windows that users would want to close from Mission Control.

**Fix:** Removed "Finder" from the ignored owners list. Also changed the list to a `Set<String>` for O(1) lookups.

---

### 8. ✅ FIXED — UserDefaults Default Not Registered for `enableSpaceClosing` (`MissionControlManager.swift:86`)

```swift
let enableSpaceClosing = UserDefaults.standard.object(forKey: "enableSpaceClosing") as? Bool ?? true
```

**Problem:** Inconsistent default registration — `showMenuBarIcon` used `register(defaults:)` but `enableSpaceClosing` used manual nil-coalescing.

**Fix:** Both defaults are now registered together in `AppDelegate.applicationDidFinishLaunching`:
```swift
UserDefaults.standard.register(defaults: [
    "showMenuBarIcon": true,
    "enableSpaceClosing": true
])
```
The read site in `MissionControlManager` now uses `UserDefaults.standard.bool(forKey:)` directly.

---

### 9. ✅ FIXED — `AXUIElementPerformAction` Return Values Ignored

**Problem:** `AXUIElementPerformAction` calls were not checked for success throughout `MissionControlManager.swift`.

**Fix:** All `AXUIElementPerformAction` calls now check the return value and log success/failure via `Logger` with the error code.

---

## 🟡 Deprecations & Compatibility

### 10. ✅ FIXED — Deprecated `NSImage.lockFocus` / `unlockFocus` (`AppDelegate.swift:9-14`)

```swift
newImage.lockFocus()
// ...drawing...
newImage.unlockFocus()
```

**Problem:** `lockFocus` and `unlockFocus` are deprecated since macOS 14 (Sonoma).

**Fix:** Replaced with the modern block-based initializer:
```swift
NSImage(size: newSize, flipped: false) { rect in
    self.draw(in: rect, ...)
    return true
}
```

---

### 11. ✅ FIXED — Deprecated `NSApp.activate(ignoringOtherApps:)` (`AppDelegate.swift:97`)

```swift
NSApp.activate(ignoringOtherApps: true)
```

**Problem:** Deprecated since macOS 14.

**Fix:** Bumped deployment target to macOS 14 (Sonoma), allowing direct use of `NSApp.activate()` without any `#available` shim.

---

### 12. ✅ FIXED — Deprecated `onChange(of:)` Closure Signature (`SettingsView.swift:48`)

```swift
.onChange(of: launchAtLogin) { newValue in
```

**Problem:** The single-parameter `onChange(of:perform:)` is deprecated since macOS 14.

**Fix:** Bumped deployment target to macOS 14, enabling the modern zero-argument `onChange(of:) { }` closure. Extracted the toggle logic into a `private func toggleLaunchAtLogin()` method for clarity.

---

### 13. ✅ FIXED — `@discardableResult` Warning on `AXIsProcessTrustedWithOptions` (`SettingsView.swift:37`)

```swift
AXIsProcessTrustedWithOptions(options)
```

**Problem:** The return value is intentionally unused, generating a compiler warning.

**Fix:** Prefixed with `_ = AXIsProcessTrustedWithOptions(options)`.

---

## 🔵 Architecture & Design

### 14. ✅ FIXED — No Way to Stop or Restart the Event Tap

**Problem:** `EventTapManager` had a `start()` method but no `stop()`. No cleanup was possible.

**Fix:** Added a `stop()` method that:
- Removes the run loop source via `CFRunLoopRemoveSource`
- Disables the tap via `CGEvent.tapEnable`
- Invalidates the mach port via `CFMachPortInvalidate`
- Nils out both stored references

Added a public `isRunning` computed property. `start()` guards with `guard !isRunning` to prevent duplicate taps.

---

### 15. ✅ FIXED — Settings Window Opens on Every Launch (`AppDelegate.swift:36`)

```swift
func applicationDidFinishLaunching(_ aNotification: Notification) {
    // ...
    openSettingsWindow()
}
```

**Problem:** With "Launch at Login" enabled, the settings window opens every time macOS boots.

**Fix:** Added a `hasLaunchedBefore` UserDefaults flag. Settings window only opens on the very first launch. Subsequent launches (including Login Items auto-start) run silently. Users can still open settings via the menu bar icon or by re-launching the app (handled by `applicationShouldHandleReopen`).

---

### 16. ✅ FIXED — Mission Control Detection Uses Fragile Heuristics (`MissionControlManager.swift:21-26`)

```swift
if owner == "Dock" && (layer == 18 || layer == 20) {
    if bounds.width > 800 && bounds.height > 600 {
```

**Problem:** Magic numbers that could change across macOS versions and fail on smaller displays.

**Fix:**
- Extracted layer values to a named constant: `missionControlOverlayLayers: Set<Int> = [18, 20]`
- Extracted size threshold to a named constant: `minimumScreenCoverageFraction: CGFloat = 0.5`
- Size check is now relative to the main screen: `bounds.width > mainScreenSize.width * 0.5`
- Added comments documenting which macOS versions these values were observed on (13–15)

---

### 17. ✅ FIXED — Timer-Based Accessibility Polling (`SettingsView.swift:11, 70-72`)

**Problem:** Polling `AXIsProcessTrusted()` every 1 second via `Timer.publish` is wasteful for a state that changes rarely.

**Fix:** Removed the timer entirely. Replaced with an event-driven approach using `DistributedNotificationCenter` listening for `com.apple.accessibility.api` — macOS fires this notification the moment any app's accessibility trust changes in System Settings. Also added `.onAppear` to refresh the status when the settings window is (re)opened. Zero CPU wake-ups while idle.

---

### 18. ✅ FIXED — Thread Safety of `MissionControlActiveChecker`

**Problem:** No explicit threading contract despite being called from the event tap thread.

**Fix:** Marked the class as `final class MissionControlActiveChecker: Sendable` and added a documentation comment explaining the threading contract: all internal calls use thread-safe CoreGraphics APIs, and the class is intentionally nonisolated so it can be called synchronously from the event tap callback.

---

### 19. ✅ FIXED — Singleton Pattern Without Access Control

**Problem:** `EventTapManager` and `MissionControlManager` initializers were not `private`.

**Fix:** Added `private init() {}` to both classes.

---

## ⚪ Minor / Style

### 20. ✅ FIXED — Excessive `print()` Statements

**Problem:** All logging used `print()` with no structure or filtering.

**Fix:** Replaced all `print()` calls across all files with `os.log.Logger`. Each file creates a logger with `subsystem: "com.vibecoded.missionstrike"` and an appropriate `category` ("EventTap", "MissionControl", "AppDelegate", "Settings"). Log levels are used appropriately: `.info` for success, `.warning` for non-fatal failures, `.error` for errors.

---

### 21. ⏭️ SKIPPED — Missing Access Control Modifiers

Most classes, methods, and properties use the default `internal` access level. For a single-target app this is acceptable. The singleton `private init()` changes (#19) address the most important case.

---

### 22. ⏭️ SKIPPED — `swift-tools-version: 6.2` is Aggressive (`Package.swift:1`)

This is a project-policy decision. The project currently compiles and the strict concurrency model catches real bugs. Left as-is.

---

### 23. ⏭️ SKIPPED — No Automated Tests

Out of scope for this review pass. The Mission Control detection heuristics and window-matching logic could be unit tested with mock data in a future iteration.

---

### 24. ✅ FIXED — README Contains Placeholder URLs

```
https://github.com/YOUR_GITHUB_USERNAME/MISSIONSTRIKE_REPOSITORY
```

**Problem:** Placeholder URLs in the README.

**Fix:** Updated to `https://github.com/SchoofsEbert/MissionStrike`.

---

### 25. ✅ FIXED — App Does Not Start Working After Granting Accessibility Permissions

**Problem:** On first launch, `applicationDidFinishLaunching` calls `EventTapManager.shared.start()`. If Accessibility permissions are not yet granted, `CGEvent.tapCreate()` returns `nil` and `start()` exits early. Nothing ever calls `start()` again — the user must quit and relaunch the app for the event tap to be created.

**Fix:** The `SettingsView` already listens for accessibility changes via `DistributedNotificationCenter` (#17). When it detects a `false → true` transition in `refreshAccessibilityStatus()`, it calls `EventTapManager.shared.start()` immediately. No extra timers or polling — the notification fires the moment permissions are granted. This works because the settings window is always open on first launch (the only time the user needs to grant permissions).

---

## Summary

| Severity | Count | Addressed |
|----------|-------|-----------|
| 🔴 Critical | 4 | 3 fixed, 1 documented |
| 🟠 Bug / Logic | 5 | 5 fixed |
| 🟡 Deprecation | 4 | 4 fixed |
| 🔵 Architecture | 7 | 7 fixed |
| ⚪ Minor / Style | 5 | 2 fixed, 3 skipped |
| **Total** | **25** | **21 fixed, 1 documented, 3 skipped** |

All changes compile successfully with `swift build` on macOS 14+ (Sonoma). Deployment target bumped from macOS 13 → 14 to eliminate all deprecation `#available` shims and use modern SwiftUI/AppKit APIs directly.

