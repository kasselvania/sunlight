#!/bin/bash
set -euo pipefail
canvas_root="$(cd "$(dirname "$0")/../.." && pwd)"
canvas_output="$canvas_root/build/virtual-display-canvas"
canvas_bundle="$canvas_output/Virtual Display Canvas.app"
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
<key>CFBundleName</key><string>Virtual Display Canvas</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Local signing does not access a private key. SIGN can explicitly select an
# existing development identity when stable privacy grants are needed later.
codesign --force --sign "${SIGN:--}" "$canvas_bundle"
printf 'Built: %s\n' "$canvas_bundle"
