#!/bin/bash
# Builds MissionStrike.app, signs it with the project's self-signed certificate,
# and zips it into MissionStrike/dist/. Used by the release workflow and for local builds.
#
# A stable signing certificate keeps the code signature's designated requirement the
# same across releases, so macOS keeps the Accessibility grant after updates. Ad-hoc
# signatures change with every build and make users re-grant it each time.
#
# Signing identity, in order of preference:
#   1. MISSIONSTRIKE_P12_BASE64 + MISSIONSTRIKE_P12_PASSWORD (release workflow secrets)
#   2. ~/.missionstrike-signing/MissionStrike-signing.p12 + p12-password.txt (local)
#   3. Ad-hoc, unless MISSIONSTRIKE_REQUIRE_SIGNING=1
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/MissionStrike"
DIST_DIR="$PACKAGE_DIR/dist"
APP_DIR="$DIST_DIR/MissionStrike.app"
ZIP_PATH="$DIST_DIR/MissionStrike.app.zip"
LOCAL_SIGNING_DIR="$HOME/.missionstrike-signing"

# The requirement every release must satisfy; the updater and install.sh check the same one.
REQUIREMENT="$(sed -n 's/.*static let requirement = #"\(.*\)"#.*/\1/p' \
    "$PACKAGE_DIR/Sources/MissionStrike/Services/CodeSigning.swift")"
if [ -z "$REQUIREMENT" ]; then
    echo "error: could not read the signing requirement from CodeSigning.swift" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
KEYCHAIN="$WORK_DIR/signing.keychain-db"
cleanup() {
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> Building release binary"
(cd "$PACKAGE_DIR" && swift build -c release)

echo "==> Assembling app bundle"
rm -rf "$DIST_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PACKAGE_DIR/.build/release/MissionStrike" "$APP_DIR/Contents/MacOS/"
cp "$PACKAGE_DIR/Info.plist" "$APP_DIR/Contents/"
cp "$PACKAGE_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/"

P12_PATH=""
P12_PASSWORD=""
if [ -n "${MISSIONSTRIKE_P12_BASE64:-}" ]; then
    P12_PATH="$WORK_DIR/signing.p12"
    printf '%s' "$MISSIONSTRIKE_P12_BASE64" | base64 --decode > "$P12_PATH"
    P12_PASSWORD="${MISSIONSTRIKE_P12_PASSWORD:?MISSIONSTRIKE_P12_PASSWORD is not set}"
elif [ -f "$LOCAL_SIGNING_DIR/MissionStrike-signing.p12" ]; then
    P12_PATH="$LOCAL_SIGNING_DIR/MissionStrike-signing.p12"
    P12_PASSWORD="$(cat "$LOCAL_SIGNING_DIR/p12-password.txt")"
fi

if [ -n "$P12_PATH" ]; then
    echo "==> Signing with the MissionStrike certificate"
    KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$P12_PATH" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

    codesign --force --options runtime --timestamp=none \
        --keychain "$KEYCHAIN" --sign "MissionStrike Code Signing" "$APP_DIR"
    codesign --verify --strict --deep -R="$REQUIREMENT" "$APP_DIR"
    echo "    Signature satisfies: $REQUIREMENT"
elif [ "${MISSIONSTRIKE_REQUIRE_SIGNING:-0}" = "1" ]; then
    echo "error: no signing certificate available and MISSIONSTRIKE_REQUIRE_SIGNING=1" >&2
    exit 1
else
    echo "warning: no signing certificate found; signing ad-hoc." >&2
    echo "         Accessibility will need to be re-granted after installing this build." >&2
    codesign --force --sign - "$APP_DIR"
fi

echo "==> Zipping"
(cd "$DIST_DIR" && ditto -c -k --keepParent MissionStrike.app MissionStrike.app.zip)
(cd "$DIST_DIR" && shasum -a 256 MissionStrike.app.zip > MissionStrike.app.zip.sha256)

echo "==> Done: $ZIP_PATH"
