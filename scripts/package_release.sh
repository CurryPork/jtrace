#!/bin/zsh

set -euo pipefail

ROOT="/Users/tanxi/project/easystock"
PROJECT="$ROOT/jtrace.xcodeproj"
BUILD_DIR="$ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
DIST_DIR="$ROOT/dist"
STAGING_DIR="$BUILD_DIR/dmg-staging"
TMP_DIR="$BUILD_DIR/tmp"
APP_NAME="JTtrace.app"
APP_PATH="$DIST_DIR/$APP_NAME"
ZIP_PATH="$DIST_DIR/JTtrace-macos.zip"
DMG_RW_PATH="$TMP_DIR/JTtrace-temp.dmg"
DMG_FINAL_PATH="$DIST_DIR/JTtrace-macos.dmg"
BACKGROUND_PATH="$TMP_DIR/install-arrow.png"
VOLUME_NAME="JTtrace"
MOUNT_POINT="/Volumes/$VOLUME_NAME"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR" "$STAGING_DIR/.background" "$TMP_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme jtrace \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build

ditto "$DERIVED_DATA/Build/Products/Release/$APP_NAME" "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

BACKGROUND_PATH="$BACKGROUND_PATH" python3 - <<'PY'
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
import os

output = Path(os.environ["BACKGROUND_PATH"])
output.parent.mkdir(parents=True, exist_ok=True)

width, height = 820, 520
image = Image.new("RGBA", (width, height), (36, 37, 38, 255))
draw = ImageDraw.Draw(image)

shadow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
shadow_draw = ImageDraw.Draw(shadow)
arrow_y = height // 2 + 18
start_x = 328
end_x = 500

shadow_draw.line((start_x, arrow_y, end_x, arrow_y), fill=(0, 0, 0, 130), width=36)
shadow_draw.polygon(
    [
        (end_x + 56, arrow_y),
        (end_x - 8, arrow_y - 48),
        (end_x - 8, arrow_y + 48),
    ],
    fill=(0, 0, 0, 130),
)
shadow = shadow.filter(ImageFilter.GaussianBlur(16))
image.alpha_composite(shadow)

draw.line((start_x, arrow_y, end_x, arrow_y), fill=(91, 242, 198, 255), width=24)
draw.polygon(
    [
        (end_x + 46, arrow_y),
        (end_x - 12, arrow_y - 40),
        (end_x - 12, arrow_y + 40),
    ],
    fill=(91, 242, 198, 255),
)

image.save(output, optimize=True)
PY

cp "$BACKGROUND_PATH" "$STAGING_DIR/.background/install-arrow.png"

hdiutil create \
  -srcfolder "$STAGING_DIR" \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  "$DMG_RW_PATH" >/dev/null

if mount | grep -q "on ${MOUNT_POINT} "; then
  hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
fi

hdiutil attach "$DMG_RW_PATH" -mountpoint "$MOUNT_POINT" -noverify -nobrowse >/dev/null

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 140, 940, 660}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 16
    set background picture of viewOptions to file ".background:install-arrow.png"
    set position of item "$APP_NAME" of container window to {200, 280}
    set position of item "Applications" of container window to {620, 280}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_POINT" >/dev/null

hdiutil convert "$DMG_RW_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL_PATH" >/dev/null

rm -f "$DMG_RW_PATH"

ls -lh "$DIST_DIR"
