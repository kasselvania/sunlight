#!/bin/bash
set -euo pipefail

lab_root="$(cd "$(dirname "$0")/../.." && pwd)"
lab_source="$lab_root/experiments/native-mirrors"
lab_output="${MIRROR_LAB_BUILD_DIR:-$lab_root/build/native-mirrors}"
mkdir -p "$lab_output"

# Deliberately independent of Sunlight's package script, bootstrap and Dock helper.
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror \
    -mmacosx-version-min=15.0 -O2 \
    -framework AppKit -framework QuartzCore -framework ApplicationServices \
    "$lab_source/main.m" -o "$lab_output/NativeMirrorLab"

for lab_role in Viewer Fixture; do
    lab_bundle="$lab_output/Native Mirror $lab_role.app"
    mkdir -p "$lab_bundle/Contents/MacOS"
    cp "$lab_output/NativeMirrorLab" "$lab_bundle/Contents/MacOS/NativeMirrorLab"
    lab_identifier="com.kasselvania.sunlight.mirrorlab.$(echo "$lab_role" | tr '[:upper:]' '[:lower:]')"
    cat > "$lab_bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NativeMirrorLab</string>
<key>CFBundleIdentifier</key><string>$lab_identifier</string>
<key>CFBundleName</key><string>Native Mirror $lab_role</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    if [ "$lab_role" = Fixture ]; then
        /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$lab_bundle/Contents/Info.plist"
    fi
    codesign --force --sign - "$lab_bundle"
done

"$lab_output/NativeMirrorLab" --inspect > "$lab_output/inspection.json"
printf 'Built: %s\nInspection: %s\n' \
    "$lab_output/Native Mirror Viewer.app" "$lab_output/inspection.json"
