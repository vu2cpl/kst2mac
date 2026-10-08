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
#   ./notarize.sh --skip-notarize  # sign only; fast iteration on signing
#
# Every run builds fresh. There is no --skip-build any more (2026-10-09): the
# old binary is deleted before the build, the product path is asked of SwiftPM
# rather than assumed, and the script stops if the fresh binary is missing, not
# universal, has the wrong deployment target, or is not byte-identical to what
# went into the .app. A stale v1.1.0 binary in .build/apple/ was one wrong path
# away from shipping as the next release.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="KST2Mac"
APP_BUNDLE_DIR="build/${APP_NAME}.app"
BIN_NAME="KST2Mac"
ENTITLEMENTS_FILE="KST2Mac.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-skimserver-notary}"

SKIP_NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --skip-build)    echo "--skip-build was removed: every release is built fresh"; exit 2 ;;
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

fail() { echo "ERROR: $*"; exit 1; }

# Universal: arm64 for Apple Silicon, x86_64 so it runs on an Intel Mac at
# all. build_app.sh omits this deliberately — it costs build time that fast
# local iteration should not pay.
#
# Where the product lands depends on the toolchain — the native build system
# used .build/apple/Products/Release, Swift 6.4's swiftbuild uses
# .build/out/Products/Release — so ask SwiftPM, and delete the old product
# first so that whatever is there afterwards was linked by this run.
BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
BUILD_OUTPUT_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BUILT_BIN="$BUILD_OUTPUT_DIR/$BIN_NAME"
rm -f "$BUILT_BIN"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" \
    Sources/KST2MacApp/Info.plist)   # 13.0, = Package.swift .macOS(.v13)

echo ">> swift build ${BUILD_ARGS[*]}  (macOS SDK $SDK_VER) -> $BUILD_OUTPUT_DIR"
# -isysroot for the link step: swiftbuild links through `swiftc -sdk`, which
# hands clang only --sysroot, so ld records the deployment target as the SDK
# version (sdk 13.0). macOS keys its linked-on-or-after behaviour on the
# recorded SDK, so pass the real one and check it below.
swift build "${BUILD_ARGS[@]}" \
    -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK"

[ -f "$BUILT_BIN" ] || fail "the build did not produce $BUILT_BIN"
ARCHS=" $(lipo -archs "$BUILT_BIN") "
for a in arm64 x86_64; do
    case "$ARCHS" in *" $a "*) ;; *) fail "$BUILT_BIN lacks $a (has:${ARCHS})" ;; esac
    BV="$(vtool -arch "$a" -show-build "$BUILT_BIN")"
    minos="$(awk '$1=="minos"{print $2}' <<<"$BV")"
    sdk="$(awk '$1=="sdk"{print $2}' <<<"$BV")"
    [ "$minos" = "$MIN_OS" ] || fail "$a slice has minos $minos, expected $MIN_OS"
    [ "$sdk" = "$SDK_VER" ] || fail "$a slice records sdk $sdk, expected $SDK_VER"
done
if otool -L "$BUILT_BIN" | grep -q '@rpath/'; then
    otool -L "$BUILT_BIN" | grep '@rpath/'
    fail "the binary needs @rpath dylibs this bundle does not carry"
fi
echo ">> built $(stat -f '%Sm' "$BUILT_BIN"); archs:${ARCHS}minos $MIN_OS, sdk $SDK_VER"

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

cp "$BUILT_BIN" "$APP_BUNDLE_DIR/Contents/MacOS/$BIN_NAME"
cmp -s "$BUILT_BIN" "$APP_BUNDLE_DIR/Contents/MacOS/$BIN_NAME" \
    || fail "the binary in $APP_BUNDLE_DIR is not the one just built"
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
# ditto, not zip: it preserves the bundle's symlinks, which a plain zip
# mangles and the notary then rejects. --norsrc: no AppleDouble (._*)
# sidecars for extended attributes — an unzipper that turns them into real
# files breaks the signature.
ditto -c -k --norsrc --keepParent "$APP_BUNDLE_DIR" "$ZIP"

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
ditto -c -k --norsrc --keepParent "$APP_BUNDLE_DIR" "$ZIP"
SIDECARS="$(zipinfo -1 "$ZIP" | grep -c -E '(^|/)(\._|__MACOSX)' || true)"
[ "$SIDECARS" = "0" ] || fail "$ZIP contains $SIDECARS AppleDouble entries"

echo ">> Gatekeeper assessment"
codesign --verify --deep --strict "$APP_BUNDLE_DIR"
spctl -a -vvv -t exec "$APP_BUNDLE_DIR"
shasum -a 256 "$ZIP"

cat <<MSG

Notarised: $ZIP

Verify on another Mac by unzipping and opening it — no right-click-Open
dance should be needed.
MSG
