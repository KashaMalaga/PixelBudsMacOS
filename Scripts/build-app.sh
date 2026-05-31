#!/usr/bin/env bash
# Build PixelBudsBar.app and (optionally) a notarized .dmg ready for distribution.
#
# Usage:
#   ./Scripts/build-app.sh          # release build (default)
#   ./Scripts/build-app.sh --debug  # debug build for local development
#
# Environment variables (all optional; omitting them gives a local/ad-hoc build):
#   CODESIGN_IDENTITY   Developer ID Application identity string,
#                       e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARIZE_APPLE_ID   Apple ID e-mail for notarytool
#   NOTARIZE_TEAM_ID    10-character Apple Developer Team ID
#   NOTARIZE_PASSWORD   App-specific password for notarytool
#
# Outputs:
#   build/PixelBudsBar.app          — always produced
#   build/PixelBudsBar.dmg          — produced when CODESIGN_IDENTITY is set
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIG="release"
[[ "${1:-}" == "--debug" ]] && CONFIG="debug"

IDENTITY="${CODESIGN_IDENTITY:-}"
ENTITLEMENTS="$ROOT/Resources/PixelBudsBar/PixelBudsBar.entitlements"
APP_DIR="$ROOT/build/PixelBudsBar.app"
DMG_PATH="$ROOT/build/PixelBudsBar.dmg"

# ── 1. Build ──────────────────────────────────────────────────────────────────
echo "→ Building PixelBudsBar ($CONFIG)…"
swift build -c "$CONFIG" --product PixelBudsBar

BIN_PATH="$(swift build -c "$CONFIG" --product PixelBudsBar --show-bin-path)/PixelBudsBar"
[[ -x "$BIN_PATH" ]] || { echo "✗ Binary not found at $BIN_PATH"; exit 1; }

# ── 2. Assemble .app skeleton ─────────────────────────────────────────────────
echo "→ Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/PixelBudsBar"

# Copy the SPM resource bundle (holds localisation strings and other target
# resources). SPM places it next to the binary in the build output directory;
# Bundle.main looks for it inside Contents/Resources/ at runtime.
BIN_DIR="$(dirname "$BIN_PATH")"
RESOURCE_BUNDLE="$BIN_DIR/PixelBudsMacOS_PixelBudsBar.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    echo "→ Copying SPM resource bundle…"
    # The generated resource_bundle_accessor.swift resolves the bundle as:
    #   Bundle.main.bundleURL + "PixelBudsMacOS_PixelBudsBar.bundle"
    # That resolves to the .app root, NOT Contents/Resources/ — so copy it there.
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/"
else
    echo "  ⚠ SPM resource bundle not found at $RESOURCE_BUNDLE — localisations may be missing"
fi
# SwiftPM doesn't add the @executable_path/../Frameworks rpath that an embedded
# Sparkle.framework needs. Patch it into the binary now, before signing.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_DIR/Contents/MacOS/PixelBudsBar"
cp "$ROOT/Resources/PixelBudsBar/Info.plist" "$APP_DIR/Contents/Info.plist"

for f in "$ROOT/Sources/PixelBudsBar/Resources"/*; do
    [[ -e "$f" ]] || continue
    if [[ -d "$f" ]]; then
        cp -R "$f" "$APP_DIR/Contents/Resources/"
    else
        cp "$f" "$APP_DIR/Contents/Resources/"
    fi
done

# ── 3. Generate AppIcon.icns ──────────────────────────────────────────────────
ICON_SRC="$ROOT/Resources/PixelBudsBar/icon-source.png"
if [[ -f "$ICON_SRC" ]]; then
    echo "→ Building AppIcon.icns…"
    ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size"         "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}.png"    >/dev/null
        sips -z $((size*2)) $((size*2)) "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET_DIR"
fi

# ── 4. Embed Sparkle.framework ────────────────────────────────────────────────
# SPM downloads the Sparkle XCFramework to .build/artifacts/. Pick the macOS
# arm64+x86_64 slice and embed it in Contents/Frameworks/.
SPARKLE_XCFW="$(find "$ROOT/.build/artifacts" -name "Sparkle.xcframework" 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_XCFW" ]]; then
    echo "→ Sparkle not yet resolved — running swift package resolve…"
    swift package resolve
    SPARKLE_XCFW="$(find "$ROOT/.build/artifacts" -name "Sparkle.xcframework" 2>/dev/null | head -1)"
fi

if [[ -n "$SPARKLE_XCFW" ]]; then
    echo "→ Embedding Sparkle.framework…"
    # The universal macOS slice is named "macos-arm64_x86_64" or "macos-arm64"
    SPARKLE_FW="$(find "$SPARKLE_XCFW" -maxdepth 2 -name "Sparkle.framework" | head -1)"
    if [[ -n "$SPARKLE_FW" ]]; then
        cp -R "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
    else
        echo "  ⚠ Could not find Sparkle.framework slice inside $SPARKLE_XCFW — skipping embed"
    fi
else
    echo "  ⚠ Sparkle XCFramework not found — update checks will not work"
fi

# ── 5. Code-sign ──────────────────────────────────────────────────────────────
if [[ -n "$IDENTITY" ]]; then
    echo "→ Signing with Developer ID: $IDENTITY"

    # Sign Sparkle's inner XPC services first, then the framework, then the app.
    # Order matters: codesign verifies the chain inner → outer.
    for xpc in "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"/*.xpc; do
        [[ -e "$xpc" ]] || continue
        codesign --force --options runtime --sign "$IDENTITY" "$xpc"
    done

    SPARKLE_FW_EMBEDDED="$APP_DIR/Contents/Frameworks/Sparkle.framework"
    if [[ -d "$SPARKLE_FW_EMBEDDED" ]]; then
        codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE_FW_EMBEDDED"
    fi

    codesign --force \
             --options runtime \
             --entitlements "$ENTITLEMENTS" \
             --sign "$IDENTITY" \
             "$APP_DIR"
else
    echo "→ Ad-hoc signing (local use only; set CODESIGN_IDENTITY for a release build)…"
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "✓ Built $APP_DIR"

# ── 6. Create DMG (release builds with a real identity only) ──────────────────
if [[ -z "$IDENTITY" ]]; then
    echo ""
    echo "  Run it with:    open '$APP_DIR'"
    echo "  Or drag it to /Applications and launch from Spotlight."
    exit 0
fi

echo "→ Creating DMG…"
rm -f "$DMG_PATH"

# Temporary uncompressed image so we can set the background / layout.
TMP_DMG="$ROOT/build/tmp_pixelbudsbar.dmg"
rm -f "$TMP_DMG"

hdiutil create \
    -volname "Pixel Buds Bar" \
    -srcfolder "$APP_DIR" \
    -ov -format UDRW \
    "$TMP_DMG"

# Mount, add Applications symlink, unmount.
MOUNT_DIR="$(mktemp -d)"
hdiutil attach "$TMP_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet
ln -s /Applications "$MOUNT_DIR/Applications"
hdiutil detach "$MOUNT_DIR" -quiet
rm -rf "$MOUNT_DIR"

# Convert to compressed read-only.
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG_PATH"
rm -f "$TMP_DMG"

# Sign the DMG itself so Gatekeeper accepts the outer package.
codesign --force --sign "$IDENTITY" "$DMG_PATH"

echo "✓ Created $DMG_PATH"

# ── 7. Notarize & staple (only when credentials are provided) ─────────────────
if [[ -z "${NOTARIZE_APPLE_ID:-}" ]]; then
    echo ""
    echo "  Skipping notarization (set NOTARIZE_APPLE_ID / NOTARIZE_TEAM_ID / NOTARIZE_PASSWORD to enable)."
    exit 0
fi

echo "→ Submitting to Apple notary service…"
xcrun notarytool submit "$DMG_PATH" \
    --apple-id  "$NOTARIZE_APPLE_ID" \
    --password  "$NOTARIZE_PASSWORD" \
    --team-id   "$NOTARIZE_TEAM_ID" \
    --wait

echo "→ Stapling notarization ticket…"
xcrun stapler staple "$DMG_PATH"

echo "✓ Notarized and stapled: $DMG_PATH"
