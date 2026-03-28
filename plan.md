# MissionStrike Plan

Develop **MissionStrike**, a macOS utility that intercepts middle mouse clicks to close windows directly from Mission Control, leveraging global event taps and the Accessibility API.

### Steps
1. Create a macOS App project with `LSUIElement` enabled to run headlessly. Provide an `NSStatusItem` in the menu bar.
2. Implement Accessibility permission requests using `AXIsProcessTrustedWithOptions` to ensure the app can intercept events and read screen elements.
3. Establish a global `CGEventTap` to intercept `CGEventType.otherMouseDown` (middle mouse clicks) and `CGEventType.leftMouseDown` (with Option key modifier) system-wide.
4. When a middle click or Option+Left click occurs, verify if Mission Control is active (e.g., by checking if the `Dock` process is the active space manager).
5. Use `AXUIElementCreateSystemWide` and `AXUIElementCopyElementAtPosition` to inspect the UI element under the mouse cursor during Mission Control.
6. Identify the original window linked to the hovered Mission Control proxy element, and trigger its `AXClose` action to close the window, ensuring that Mission Control stays open.
7. Create a minimal settings page (Window) allowing users to configure preferences, including the ability to show or hide the menu bar icon.
8. Handle app launch events so that launching the app from the Applications folder or Launchpad opens the settings page instead of just running invisibly.
9. Add a setting to launch the app automatically at login (e.g., using `SMAppService` for modern macOS).

### Further Considerations
1. Mission Control is managed by the Dock; extracting the actual window ID from the Dock's `AXUIElement` proxy might require exploring private attributes or fallback simulation (e.g., left-clicking to focus, then sending Cmd+W).
2. The alternative trigger for users without a middle mouse button is Option + Left Click.
3. No additional visual or audio feedback is needed upon closing a window, as the window disappearing from Mission Control provides sufficient feedback.
