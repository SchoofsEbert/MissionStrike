<p align="center">
  <img src="MissionStrike/AppIcon.png" width="128" height="128" alt="MissionStrike Icon">
</p>

<h1 align="center">MissionStrike</h1>

<p align="center">
  <strong>Close, minimize and manage windows straight from Mission Control.</strong>
</p>

---

> 🤖 **Note:** This entire application (including this README) was completely "vibe-coded". It was built as an experiment to test AI-driven development and solve a personal workflow frustration—without the author needing to write or know any Swift!

## Features

In Mission Control, point at a window or Space and:

| Action | Does |
|---|---|
| **Middle-click** or **⌥ Option + click** | Close the window or Space |
| **⇧ Shift + click** | Minimize the window |
| **⌘ Command + click** | Close all of that app's windows |
| **⌘W / ⌘M / ⌘H / ⌘Q** | Close, minimize, hide or quit |
| **Right-click** | A menu with all of the above, plus Close Others and Hide Others. Right-click the background to quit apps with no windows. |

Hold your modifier key and a small badge shows which window a click will hit. If an app asks to confirm a close, such as to save changes, a badge on the window says so, and Mission Control stays open. Optionally, middle-click a Dock icon to quit the app, or add a poof when closing. You can switch each feature on or off and change the modifier key in Settings.

## Installation

### Homebrew (recommended)

```bash
brew install --cask schoofsebert/tap/missionstrike
```

### Install script

```bash
curl -fsSLO https://github.com/SchoofsEbert/MissionStrike/releases/latest/download/install.sh
bash install.sh
```

The script is downloaded from a GitHub Release, then downloads the latest app release, checks its signature and installs it to `/Applications`.

### Manual

Download `MissionStrike.app.zip` from [Releases](https://github.com/SchoofsEbert/MissionStrike/releases), move the app to `Applications`, and clear the quarantine flag macOS puts on unsigned downloads:

```bash
xattr -cr /Applications/MissionStrike.app
```

> ℹ️ Releases are signed with MissionStrike's own certificate rather than a paid Apple Developer ID. That's why Homebrew and the script remove the quarantine flag for you.

### Accessibility permission

MissionStrike needs Accessibility access to see clicks in Mission Control and close windows. The setup guide on first launch walks you through it. Updates keep the permission.

## Updating

MissionStrike checks for updates once a day; you can also check from the menu bar. A window shows what's new, and **Install & Relaunch** downloads the update, verifies its signature and restarts the app.

Homebrew leaves updates to the app, so `brew upgrade` only updates MissionStrike with `--greedy`.

## Building from Source

Requires an Apple-silicon Mac, Xcode or the Swift command line tools. MissionStrike is Apple-silicon only.

```bash
git clone https://github.com/SchoofsEbert/MissionStrike.git
cd MissionStrike
scripts/package-app.sh
```

The signed app and zip end up in `MissionStrike/dist/`. Without the MissionStrike signing certificate the build is signed ad hoc, so macOS asks for Accessibility again after every build.

### Release signing

Releases are signed with a self-signed certificate; the in-app updater and `install.sh` reject downloads that aren't. Each release also has a [build provenance attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations): `gh attestation verify MissionStrike.app.zip --repo SchoofsEbert/MissionStrike`.

The `release` GitHub Actions environment must require reviewers and allow deployment only from protected `v*` tags. Keep the signing P12 and password as secrets scoped to that environment. If the certificate is lost or compromised, create a replacement certificate, update the pinned requirement in `CodeSigning.swift` and `install.sh`, update the environment secrets, and publish recovery instructions: existing installations will need to reinstall and grant Accessibility again because the signing identity changes.

## How it Works

1. A global event tap listens for clicks, ⌘ shortcuts and modifier keys. Everything outside Mission Control passes straight through.
2. Mission Control is detected by the Dock and WindowManager overlay windows.
3. The click is hit-tested through Accessibility:
   - **Spaces Bar** → `AXRemoveDesktop` on the Space under the cursor.
   - **Window thumbnail (macOS 27+)** → the thumbnail's `wid` → the real window → close, minimize or close all.
   - **Older Mission Control** → the classic `AXWindow` close button.
4. On macOS 27+, click coordinates are flipped vertically to match Accessibility's top-left origin.

If something doesn't work, **About → Copy Diagnostics** copies what MissionStrike saw (never window titles) for a bug report.
