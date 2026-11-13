#!/bin/bash
# Compiles the Icon Composer icon (Vantage/Icon/Vantage.icon) into the files
# the app bundle uses: Assets.car (Liquid Glass icon for macOS 26+) and Vantage.icns
# (flat fallback for older macOS). Also refreshes the README image.
#
# Needs Xcode 26 or later (actool with .icon support). The outputs are committed, so
# release builds don't depend on the Xcode version of the build machine. Re-run this
# after editing the icon.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_DIR="$REPO_ROOT/Vantage/Icon"
OUT_DIR="$ICON_DIR/Compiled"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
xcrun actool \
    --compile "$OUT_DIR" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon Vantage \
    --output-partial-info-plist "$WORK_DIR/partial.plist" \
    "$ICON_DIR/Vantage.icon" >/dev/null

sips -s format png "$OUT_DIR/Vantage.icns" --out "$REPO_ROOT/Vantage/AppIcon.png" >/dev/null
echo "Icon compiled into $OUT_DIR"
