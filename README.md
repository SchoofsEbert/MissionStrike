# MissionStrike

**MissionStrike** is a lightweight, background macOS utility that solves a simple personal frustration: **Closing windows directly from Mission Control**. 

Simply enter Mission Control and middle-click on any window to close it, without having to focus it first or lose your Mission Control overview. Don't have a middle mouse button? Hold `Option` and `Left Click` instead!

---

> 🤖 **Note:** This entire application (including this README) was completely "vibe-coded". It was built as an experiment to test AI-driven development and solve a personal workflow frustration—without the author needing to write or know any Swift!

## Features

- 🖱️ Middle-click to quickly close windows in Mission Control.
- ⌨️ Alternatively, use `Option` + `Left Click`.
- ⚙️ Runs silently in the background with a minimal footprint.
- 🎛️ Simple Settings menu to toggle "Launch at Login" and hide the menu bar icon.
- 🧠 Powered by global Event Taps and macOS Accessibility APIs.

## Installation

You can download and install the app seamlessly using the pre-compiled releases.

1. Go to the [Releases](https://github.com/YOUR_GITHUB_USERNAME/MISSIONSTRIKE_REPOSITORY/releases) page.
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
4. Re-launch the app (or use the menu bar icon to access Settings).

*If you accidentally denied the prompt, simply navigate to the Accessibility settings manually, hit the `+` button, and add `MissionStrike.app` from your Applications folder.*

> ⚠️ **Troubleshooting:** If the app is running but clicks are not being intercepted (and the switch in Settings is `ON`), macOS might have cached an older signature. Select `MissionStrike.app` in the Accessibility window, click the `-` (minus) button to remove it completely, then manually click `+` and re-add the app from your Applications folder.

## Building from Source

If you prefer to build the project yourself (requires Xcode or the Swift Command Line tools):

1. Clone the repository:
   ```bash
   git clone https://github.com/YOUR_GITHUB_USERNAME/MISSIONSTRIKE_REPOSITORY.git
   cd MISSIONSTRIKE_REPOSITORY/MissionStrike
   ```
2. Build the project:
   ```bash
   swift build -c release
   ```
3. To package it into a `.app` bundle manually, you can use the provided GitHub Actions workflow as a reference or wrap the executable generated in `.build/release/MissionStrike` into a standard macOS app directory structure.

## How it Works
1. A global event tap (`CGEventTap`) listens specifically for middle clicks or option-left-clicks.
2. When triggered, the app queries macOS CoreGraphics (`checkCGWindows`) to analyze the physical geometry of windows sitting exactly under your cursor.
3. The underlying process ID (PID) and window identity are extracted.
4. MissionStrike climbs the Accessibility tree (`AXUIElement`) corresponding to that window and triggers a programmatic `AXPress` on its native Close button.

Enjoy a cleaner Mission Control experience!
