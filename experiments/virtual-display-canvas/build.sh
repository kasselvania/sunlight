#!/bin/bash
set -euo pipefail
: "${SIGN:?Set SIGN to an existing development identity; use SIGN=- only for isolated checks}"
canvas_root="$(cd "$(dirname "$0")/../.." && pwd)"
canvas_output="${VIRTUAL_CANVAS_BUILD_DIR:-$canvas_root/build/virtual-display-canvas}"
canvas_bundle="$canvas_output/Sunlight Canvas Lab.app"
mkdir -p "$canvas_bundle/Contents/MacOS"
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror -O2 \
    -mmacosx-version-min=15.0 \
    -framework AppKit -framework QuartzCore -framework ScreenCaptureKit \
    -framework CoreMedia -framework CoreVideo -framework IOSurface -framework ImageIO \
    "$canvas_root/experiments/virtual-display-canvas/main.m" \
    -o "$canvas_bundle/Contents/MacOS/VirtualDisplayCanvas"
cat > "$canvas_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VirtualDisplayCanvas</string>
<key>CFBundleIdentifier</key><string>com.kasselvania.sunlight.virtualcanvas</string>
<key>CFBundleName</key><string>Sunlight Canvas Lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# An explicitly selected development identity keeps this app's privacy identity
# stable across rebuilds. No key is created or exported. SIGN=- is for isolated
# checks only; the installed app is signed with an existing development key.
codesign --force --sign "$SIGN" "$canvas_bundle"
codesign --verify --strict "$canvas_bundle"
printf 'Built: %s\n' "$canvas_bundle"
