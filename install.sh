#!/bin/bash
# MissionStrike Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/SchoofsEbert/MissionStrike/main/install.sh | bash
#
# Downloads the latest release, removes the macOS quarantine flag,
# and moves MissionStrike.app into /Applications.

set -euo pipefail

APP_NAME="MissionStrike"
INSTALL_DIR="/Applications"
REPO="SchoofsEbert/MissionStrike"
TMP_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "🚀 Installing $APP_NAME..."

# Fetch the latest release download URL from the GitHub API
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"browser_download_url".*\.zip' \
    | head -1 \
    | cut -d '"' -f 4)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "❌ Could not find the latest release. Please check https://github.com/$REPO/releases"
    exit 1
fi

VERSION=$(echo "$DOWNLOAD_URL" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
echo "📦 Downloading $APP_NAME $VERSION..."
curl -fsSL -o "$TMP_DIR/$APP_NAME.app.zip" "$DOWNLOAD_URL"

echo "📂 Extracting..."
unzip -q "$TMP_DIR/$APP_NAME.app.zip" -d "$TMP_DIR"

echo "🔓 Removing macOS quarantine flag..."
xattr -cr "$TMP_DIR/$APP_NAME.app"

# If the app is currently running, quit it first
if pgrep -xq "$APP_NAME"; then
    echo "⏹️  Stopping running instance..."
    killall "$APP_NAME" 2>/dev/null || true
    sleep 1
fi

echo "📲 Installing to $INSTALL_DIR..."
if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi
mv "$TMP_DIR/$APP_NAME.app" "$INSTALL_DIR/"

echo ""
echo "✅ $APP_NAME $VERSION has been installed to $INSTALL_DIR/$APP_NAME.app"
echo ""
echo "   Launch it from your Applications folder or run:"
echo "   open /Applications/$APP_NAME.app"
echo ""
echo "   On first launch, macOS will ask for Accessibility permissions."
echo "   Grant them in System Settings → Privacy & Security → Accessibility."

