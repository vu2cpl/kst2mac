#!/bin/bash
# Build KST Mac as a standalone .app bundle for drag-to-Applications install.
#
# Output: build/KST Mac.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="KST Mac"
APP_BUNDLE_DIR="build/${APP_NAME}.app"
BIN_NAME="KSTMac"

echo ">> swift build -c release"
swift build -c release

echo ">> assembling $APP_BUNDLE_DIR"
rm -rf "$APP_BUNDLE_DIR"
mkdir -p "$APP_BUNDLE_DIR/Contents/MacOS"
mkdir -p "$APP_BUNDLE_DIR/Contents/Resources"

# Optional app icon: drop a 1024x1024 PNG at Resources/AppIcon.png and it
# gets packed into AppIcon.icns. Missing icon is non-fatal — the app just
# shows the generic macOS one.
ICON_SRC="Resources/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
    echo ">> building AppIcon.icns from $ICON_SRC"
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z "$sz" "$sz"             "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png"     >/dev/null
        sips -z "$((sz*2))" "$((sz*2))" "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE_DIR/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

cp ".build/release/$BIN_NAME" "$APP_BUNDLE_DIR/Contents/MacOS/$BIN_NAME"
cp Sources/KSTMacApp/Info.plist "$APP_BUNDLE_DIR/Contents/Info.plist"

PB="/usr/libexec/PlistBuddy"
$PB -c "Add :CFBundleExecutable string $BIN_NAME" "$APP_BUNDLE_DIR/Contents/Info.plist" 2>/dev/null \
    || $PB -c "Set :CFBundleExecutable $BIN_NAME" "$APP_BUNDLE_DIR/Contents/Info.plist"
$PB -c "Add :CFBundlePackageType string APPL"     "$APP_BUNDLE_DIR/Contents/Info.plist" 2>/dev/null || true
if [ -f "$APP_BUNDLE_DIR/Contents/Resources/AppIcon.icns" ]; then
    $PB -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE_DIR/Contents/Info.plist" 2>/dev/null || true
    $PB -c "Add :CFBundleIconName string AppIcon" "$APP_BUNDLE_DIR/Contents/Info.plist" 2>/dev/null || true
fi

# Ad-hoc sign so Gatekeeper lets it launch locally. The entitlements file
# only asks for outgoing network access; the app is not sandboxed because
# it needs the Keychain item and a plain TCP socket.
ENTITLEMENTS_FILE="KSTMac.entitlements"
ENTITLEMENTS_ARGS=()
[ -f "$ENTITLEMENTS_FILE" ] && ENTITLEMENTS_ARGS=(--entitlements "$ENTITLEMENTS_FILE")
codesign --force --sign - "${ENTITLEMENTS_ARGS[@]}" "$APP_BUNDLE_DIR/Contents/MacOS/$BIN_NAME" 2>&1 | tail -2 || true
codesign --force --sign - "${ENTITLEMENTS_ARGS[@]}" "$APP_BUNDLE_DIR" 2>&1 | tail -2 || true

cat <<MSG

Build complete: $APP_BUNDLE_DIR

Install:
    cp -R "$APP_BUNDLE_DIR" /Applications/
    open "/Applications/${APP_NAME}.app"

MSG
