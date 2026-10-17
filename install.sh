#!/bin/bash
# MissionStrike Installer
# Download this immutable release asset first, then run: bash install.sh
#
# Downloads the latest release, verifies its pinned signature, stages it on the
# /Applications volume, and swaps it in while retaining a rollback copy.

set -euo pipefail

APP_NAME="MissionStrike"
INSTALL_DIR="/Applications"
REPO="SchoofsEbert/MissionStrike"
# Every release is signed with MissionStrike's own certificate; refuse anything else.
# Keep in sync with MissionStrike/Sources/MissionStrike/Services/CodeSigning.swift.
REQUIREMENT='identifier "io.github.schoofsebert.missionstrike" and certificate leaf = H"4db8f2724be711f4ad297925bac86fb1a77e8037"'
TMP_DIR="$(mktemp -d)"
STAGE_DIR=""
BACKUP_APP=""
INSTALLED_NEW_APP=0

rollback() {
    local status=$?
    if [ "$status" -ne 0 ] && [ -n "$BACKUP_APP" ] && [ -d "$BACKUP_APP" ]; then
        echo "↩️  Restoring the previous $APP_NAME installation..." >&2
        if [ "$INSTALLED_NEW_APP" -eq 1 ] && [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
            rm -rf "$INSTALL_DIR/$APP_NAME.app"
        fi
        mv "$BACKUP_APP" "$INSTALL_DIR/$APP_NAME.app" || \
            echo "❌ Could not restore $BACKUP_APP. Restore it manually." >&2
    fi
    [ -z "$STAGE_DIR" ] || rm -rf "$STAGE_DIR"
    rm -rf "$TMP_DIR"
    exit "$status"
}
trap rollback EXIT

echo "🚀 Installing $APP_NAME..."

if [ ! -d "$INSTALL_DIR" ] || [ ! -w "$INSTALL_DIR" ]; then
    echo "❌ $INSTALL_DIR is not writable by $(id -un)." >&2
    echo "   Ask an administrator to install MissionStrike, or make /Applications writable first." >&2
    exit 1
fi

# Fetch the latest release download URL from the GitHub API.
DOWNLOAD_URL=$(curl -fsSL --proto '=https' --tlsv1.2 "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"browser_download_url".*/MissionStrike\.app\.zip"' \
    | head -1 \
    | cut -d '"' -f 4)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "❌ Could not find the latest release. Please check https://github.com/$REPO/releases" >&2
    exit 1
fi

VERSION=$(echo "$DOWNLOAD_URL" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true)
echo "📦 Downloading $APP_NAME ${VERSION:-latest}..."
curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP_DIR/$APP_NAME.app.zip" "$DOWNLOAD_URL"

echo "📂 Extracting..."
ditto -x -k "$TMP_DIR/$APP_NAME.app.zip" "$TMP_DIR"

DOWNLOADED_APP="$TMP_DIR/$APP_NAME.app"
if [ ! -d "$DOWNLOADED_APP" ]; then
    echo "❌ The archive did not contain $APP_NAME.app." >&2
    exit 1
fi

echo "🔏 Verifying signature..."
if ! codesign --verify --strict --deep -R="$REQUIREMENT" "$DOWNLOADED_APP" 2>/dev/null; then
    echo "❌ The downloaded app is not signed by MissionStrike. Aborting." >&2
    exit 1
fi

ARCHITECTURES=$(lipo -archs "$DOWNLOADED_APP/Contents/MacOS/$APP_NAME")
if ! printf '%s\n' "$ARCHITECTURES" | tr ' ' '\n' | grep -qx 'arm64'; then
    echo "❌ The downloaded app is not an Apple-silicon build (found: $ARCHITECTURES)." >&2
    exit 1
fi

echo "🔓 Removing macOS quarantine flag..."
xattr -cr "$DOWNLOADED_APP"

# Staging inside /Applications makes the final moves same-volume. Do this before stopping
# the running app so a failed download or verification never disrupts the old install.
STAGE_DIR=$(mktemp -d "$INSTALL_DIR/.MissionStrike-install.XXXXXX")
mv "$DOWNLOADED_APP" "$STAGE_DIR/$APP_NAME.app"

if pgrep -xq "$APP_NAME"; then
    echo "⏹️  Stopping running instance..."
    killall "$APP_NAME" 2>/dev/null || true
    sleep 1
fi

echo "📲 Installing to $INSTALL_DIR..."
if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    BACKUP_APP="$INSTALL_DIR/.$APP_NAME.backup.$RANDOM"
    mv "$INSTALL_DIR/$APP_NAME.app" "$BACKUP_APP"
fi
mv "$STAGE_DIR/$APP_NAME.app" "$INSTALL_DIR/$APP_NAME.app"
INSTALLED_NEW_APP=1

if [ -n "$BACKUP_APP" ]; then
    rm -rf "$BACKUP_APP"
    BACKUP_APP=""
fi

echo ""
echo "✅ $APP_NAME ${VERSION:-latest} has been installed to $INSTALL_DIR/$APP_NAME.app"
echo ""
echo "   Launch it from your Applications folder or run:"
echo "   open /Applications/$APP_NAME.app"
echo ""
echo "   On first launch, macOS will ask for Accessibility permissions."
echo "   Grant them in System Settings → Privacy & Security → Accessibility."
