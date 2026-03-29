<p align="center">
  <img src="MissionStrike/AppIcon.png" width="128" height="128" alt="MissionStrike Icon">
</p>

<h1 align="center">MissionStrike</h1>

<p align="center">
  <strong>A lightweight macOS utility that lets you close, minimize, and manage windows directly from Mission Control.</strong>
</p>

---

> 🤖 **Note:** This entire application (including this README) was completely "vibe-coded". It was built as an experiment to test AI-driven development and solve a personal workflow frustration—without the author needing to write or know any Swift!

## Features

- 🖱️ **Middle-click** to close windows in Mission Control.
- ⌨️ **Option + Left Click** as an alternative (configurable modifier key).
- 🗂️ **Close Spaces** — click a Space thumbnail in the Spaces Bar to remove it instantly.
- 📦 **⌘ Cmd + Click** — close *all* windows of an app at once.
- ➖ **⇧ Shift + Click** — minimize a window to the Dock instead of closing it.
- 🎛️ **Customizable triggers** — choose your preferred modifier key or disable triggers in Settings.
- 🔄 **Auto-update checker** — notifies you when a new release is available on GitHub.
- 🛡️ **Resilient event tap** — auto-recovers if macOS disables it, with App Nap prevention.
- ⚙️ Runs silently in the background with a minimal menu bar presence.
- 🧭 **Onboarding walkthrough** on first launch to guide you through setup.

## Installation

You can download and install the app seamlessly using the pre-compiled releases.

1. Go to the [Releases](https://github.com/SchoofsEbert/MissionStrike/releases) page.
2. Download the latest `MissionStrike.app.zip`.
3. Unzip the file and move `MissionStrike.app` into your `Applications` folder.
4. Because this app is not signed with a paid Apple Developer account, macOS will likely mark it as "damaged". To fix this, open Terminal and run:
   ```bash
   xattr -cr /Applications/MissionStrike.app
   ```
5. Launch the app.

### Initial Setup & Permissions

Because this app intercepts mouse clicks and needs to ask the system to close un-focused windows, macOS requires you to grant it Accessibility permissions.

1. Upon first launch, macOS will likely prompt you about Accessibility permissions.
2. Open **System Settings** > **Privacy & Security** > **Accessibility**.
3. Toggle the switch next to **MissionStrike** to ON.
4. The app will automatically detect the permission change and start working — no re-launch needed!

*If you accidentally denied the prompt, simply navigate to the Accessibility settings manually, hit the `+` button, and add `MissionStrike.app` from your Applications folder.*

> ⚠️ **Troubleshooting:** If the app is running but clicks are not being intercepted (and the switch in Settings is `ON`), macOS might have cached an older signature. Select `MissionStrike.app` in the Accessibility window, click the `-` (minus) button to remove it completely, then manually click `+` and re-add the app from your Applications folder.

## Building from Source

If you prefer to build the project yourself (requires Xcode or the Swift Command Line tools):

1. Clone the repository:
   ```bash
   git clone https://github.com/SchoofsEbert/MissionStrike.git
   cd MissionStrike/MissionStrike
   ```
2. Build the project:
   ```bash
   swift build -c release
   ```
3. To package it into a `.app` bundle manually, you can use the provided GitHub Actions workflow as a reference or wrap the executable generated in `.build/release/MissionStrike` into a standard macOS app directory structure.

## How it Works

1. A global event tap (`CGEventTap`) listens for middle-clicks and modifier+left-clicks (configurable).
2. When triggered in Mission Control, modifier keys determine the action:
   - **No modifier** → close the window under the cursor.
   - **⇧ Shift** → minimize the window to the Dock.
   - **⌘ Command** → close all windows belonging to that app.
3. If the click lands on the **Spaces Bar**, the app identifies the Space thumbnail and triggers an `AXRemoveDesktop` action immediately.
4. Otherwise, the underlying process ID (PID) and window identity are extracted via CoreGraphics.
5. MissionStrike climbs the Accessibility tree (`AXUIElement`) to find the target window and performs the action programmatically.

Enjoy a cleaner Mission Control experience!
