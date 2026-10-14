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
- 📋 **Right-click menu** — right-click a window to close, minimize, hide, or quit its app (hold ⌥ to force quit), or right-click a Space to close it.
- ⌘ **Keyboard shortcuts** — point at a window and press ⌘W to close, ⌘M to minimize, ⌘H to hide, or ⌘Q to quit its app. ⌘W on a Space closes it.
- 🔴 **Hover badge** — hold your modifier key and a traffic-light badge marks the window a click will act on: ✕ close, − minimize (⇧), or close all (⌘).
- 🎛️ **Customizable** — choose your modifier key and switch each feature on or off in Settings.
- ⏸️ **Menu bar status and Pause** — see at a glance whether MissionStrike is active, and pause it when you need Mission Control untouched.
- 🔄 **One-click auto-updates** — a What's New window shows the release notes; install and relaunch with a single click. Updates keep the Accessibility permission.
- 🛡️ **Resilient event tap** — auto-recovers if macOS disables it, with App Nap prevention.
- 🧭 **Onboarding walkthrough** on first launch to guide you through setup.

## Installation

### Quick Install (Recommended)

Run this single command in **Terminal** — it downloads the latest release, checks that it is signed by MissionStrike, removes the macOS quarantine flag, and installs the app to `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/SchoofsEbert/MissionStrike/main/install.sh | bash
```

Then launch it:

```bash
open /Applications/MissionStrike.app
```

### Manual Install

1. Go to the [Releases](https://github.com/SchoofsEbert/MissionStrike/releases) page.
2. Download the latest `MissionStrike.app.zip`.
3. Unzip the file and move `MissionStrike.app` into your `Applications` folder.
4. Because this app is not signed with a paid Apple Developer account, macOS will quarantine downloaded apps and mark them as "damaged". To fix this, open Terminal and run:
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

> ℹ️ **After updates:** since v2.6.1, every release is signed with the same MissionStrike certificate, so macOS keeps the Accessibility permission across updates. Updating from an older version asks for it one last time. If MissionStrike ever stops working after an update, open System Settings → Privacy & Security → Accessibility, remove MissionStrike, then re-add it.

## Updating

MissionStrike checks for updates automatically once every 24 hours and can also be triggered manually via **Check for Updates…** in the menu bar.

When a new version is available, a **Software Update** window shows what's new in that release, with three options:

| Option | What it does |
|---|---|
| **Install & Relaunch** | Downloads the update, verifies it is signed by MissionStrike, removes the macOS quarantine flag, replaces the app, and relaunches — fully automatic, no Terminal required. Progress is shown in the same window. |
| **View on GitHub** | Opens the GitHub release page. |
| **Later** | Closes the window. You'll be reminded on the next check. |

If the automatic install fails for any reason, the window offers a link to download the update manually.

> 💡 **Tip:** You can also re-run the install script at any time to update to the latest version:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/SchoofsEbert/MissionStrike/main/install.sh | bash
> ```

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
3. To package it into a signed `.app` bundle and zip, run `scripts/package-app.sh` from the repository root. The output lands in `MissionStrike/dist/`. Without the MissionStrike signing certificate the build is signed ad-hoc, which works but means macOS asks for Accessibility again after every build.

### Release signing

Releases are signed with a self-signed certificate (no paid Apple Developer account). Its stable signature keeps the Accessibility permission across updates, and both the in-app updater and `install.sh` refuse downloads that aren't signed with it. Each release also carries a [build provenance attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations), which you can check with `gh attestation verify MissionStrike.app.zip --repo SchoofsEbert/MissionStrike`.

## How it Works

1. A global event tap (`CGEventTap`) listens for middle-clicks, modifier+left-clicks (configurable), right-clicks, ⌘-shortcuts and modifier changes. Everything outside Mission Control passes straight through.
2. Mission Control is detected via Dock / WindowManager overlay windows (so a lonely dock bounce doesn’t count).
3. Modifier keys pick the action: plain click closes, **⇧** minimizes, **⌘** closes all windows for that app. Right-clicks open MissionStrike's own menu, and ⌘W / ⌘M / ⌘H / ⌘Q act on the window under the pointer.
4. The click is hit-tested through Accessibility:
   - **Spaces Bar** → `AXRemoveDesktop` on the Space under the cursor.
   - **Window tile (macOS 27+)** → WindowManager thumbnail `wid` → real window → close / minimize / close-all.
   - **Older Mission Control** → classic `AXWindow` close button / `AXClose`.
5. On macOS 27+, click coordinates are Y-flipped once to match AX’s top-left space (WindowManager UI and the event tap don’t agree on Y). Older macOS keeps the unflipped path.
6. While the modifier key is held, the same hit test runs about 30 times a second to place the hover badge on the window under the pointer.

Enjoy a cleaner Mission Control experience!
