#!/bin/bash
# Build, codesign with Developer ID, notarize and staple KST2Mac — the
# full chain to produce a distributable release.
#
# Differs from build_app.sh, which stays for fast local iteration:
#   - universal binary (arm64 + x86_64), so it runs on Intel Macs too;
#   - Developer ID signature instead of ad-hoc;
#   - hardened runtime + secure timestamp, both required by the notary;
#   - submits to Apple, staples the ticket, and zips the result.
#
# Prerequisites (one-time, already done on this Mac):
#   1. Apple Developer Program enrolment.
#   2. "Developer ID Application" certificate in the Keychain.
#   3. Notary credentials stored with:
#        xcrun notarytool store-credentials "<profile>" \
#          --apple-id "<apple-id>" --team-id "<TEAMID>" \
#          --password "<app-specific-password>"
#      Override the profile with NOTARY_PROFILE=… ; it defaults to the
#      existing shack profile so no new credentials are needed.
#
# Usage:
#   ./notarize.sh                  # build + sign + notarize + staple + zip
#   ./notarize.sh --skip-build     # reuse the last release build
#   ./notarize.sh --skip-notarize  # sign only; fast iteration on signing
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="KST2Mac"
APP_BUNDLE_DIR="build/${APP_NAME}.app"
BIN_NAME="KST2Mac"
ENTITLEMENTS_FILE="KST2Mac.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-skimserver-notary}"

SKIP_BUILD=0
SKIP_NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --skip-build)    SKIP_BUILD=1 ;;
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        *) echo "unknown option: $arg"; exit 2 ;;
    esac
done

DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -E '"Developer ID Application:' \
  | head -1 \
  | sed -E 's/.*"(Developer ID Application:[^"]+)".*/\1/')}"

if [ -z "$DEVELOPER_ID_IDENTITY" ]; then
    cat <<MSG
No "Developer ID Application" certificate found in the Keychain.

Notarisation needs one — an ad-hoc signature is rejected by the notary.
Verify with: security find-identity -v -p codesigning
MSG
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    Sources/KST2MacApp/Info.plist)

echo ">> identity:  $DEVELOPER_ID_IDENTITY"
echo ">> version:   $VERSION"
echo ">> notary:    $NOTARY_PROFILE"

# --- Build ------------------------------------------------------------------

if [ "$SKIP_BUILD" -eq 0 ]; then
    # Universal: arm64 for Apple Silicon, x86_64 so it runs on an Intel
    # Mac at all. build_app.sh omits this deliberately — it costs build
    # time that fast local iteration should not pay.
    echo ">> swift build -c release --arch arm64 --arch x86_64"
    swift build -c release --arch arm64 --arch x86_64
fi

# Multi-arch output lands under .build/apple/Products/Release; the
# single-arch path is a symlink to one triple, so never copy from it here.
if [ -d ".build/apple/Products/Release" ]; then
    BUILD_OUTPUT_DIR=".build/apple/Products/Release"
else
    BUILD_OUTPUT_DIR=".build/release"
fi

echo ">> assembling $APP_BUNDLE_DIR"
rm -rf "$APP_BUNDLE_DIR"
mkdir -p "$APP_BUNDLE_DIR/Contents/MacOS" "$APP_BUNDLE_DIR/Contents/Resources"

ICON_SRC="Resources/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
    echo ">> building AppIcon.icns"
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z "$sz" "$sz"             "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png"     >/dev/null
        sips -z "$((sz*2))" "$((sz*2))" "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE_DIR/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

cp "$BUILD_OUTPUT_DIR/$BIN_NAME" "$APP_BUNDLE_DIR/Contents/MacOS/$BIN_NAME"
cp Sources/KST2MacApp/Info.plist "$APP_BUNDLE_DIR/Contents/Info.plist"

PB="/usr/libexec/PlistBuddy"
$PB -c "Add :CFBundleExecutable string $BIN_NAME" "$APP_BUNDLE_DIR/Contents/Info.plist" 2>/dev/null \
    || $PB -c "Set :CFBundleExecutable $BIN_NAME" "$APP_BUNDLE_DIR/Contents/Info.plist"
$PB -c "Add :CFBundlePackageType string APPL"     "$APP_BUNDLE_DIR/Contents/Info.plist" 2>/dev/null || true
if [ -f "$APP_BUNDLE_DIR/Contents/Resources/AppIcon.icns" ]; then
    $PB -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE_DIR/Contents/Info.plist" 2>/dev/null || true
fi

echo ">> lipo -info"
lipo -info "$APP_BUNDLE_DIR/Contents/MacOS/$BIN_NAME"

# --- Sign -------------------------------------------------------------------

# --options runtime is the hardened runtime, --timestamp a secure
# timestamp. The notary rejects a submission missing either.
echo ">> codesign (Developer ID + hardened runtime)"
codesign --force --deep \
         --sign "$DEVELOPER_ID_IDENTITY" \
         --options runtime \
         --timestamp \
         --entitlements "$ENTITLEMENTS_FILE" \
         "$APP_BUNDLE_DIR"

echo ">> codesign --verify"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE_DIR" 2>&1 | tail -4

ZIP="build/${APP_NAME}-${VERSION}.zip"
echo ">> packaging $ZIP"
rm -f "$ZIP"
# ditto, not zip: it preserves the bundle's resource forks and symlinks,
# which a plain zip mangles and the notary then rejects.
ditto -c -k --keepParent "$APP_BUNDLE_DIR" "$ZIP"

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo ">> --skip-notarize: signed but not submitted"
    exit 0
fi

# --- Notarize ---------------------------------------------------------------

echo ">> notarytool submit (this takes a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo ">> stapler staple"
xcrun stapler staple "$APP_BUNDLE_DIR"
xcrun stapler validate "$APP_BUNDLE_DIR"

# Re-zip after stapling: the ticket is attached to the .app, and the zip
# made before stapling does not contain it.
echo ">> repackaging stapled $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_BUNDLE_DIR" "$ZIP"

echo ">> Gatekeeper assessment"
spctl -a -vvv -t install "$APP_BUNDLE_DIR" 2>&1 | tail -3

cat <<MSG

Notarised: $ZIP

Verify on another Mac by unzipping and opening it — no right-click-Open
dance should be needed.
MSG
