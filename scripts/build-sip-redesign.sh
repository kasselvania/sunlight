#!/bin/bash
# Development bundle for the SIP-enabled redesign. Uses Sunlight's real Swift
# target, the existing Canvas Lab identity and no injected/privileged helper.
set -euo pipefail
: "${SIGN:?Select the existing development signing identity to preserve privacy grants}"
if [[ "$SIGN" == "-" ]]; then
  echo "The installed redesign requires a stable development signing identity." >&2
  exit 1
fi
sip_root="$(cd "$(dirname "$0")/.." && pwd)"
sip_scratch="$sip_root/build/sip-redesign-swift"
sip_output="$sip_root/build/sip-redesign"
sip_bundle="$sip_output/SunlightCanvasLab.bundle"
mkdir -p "$sip_output"
swift build --package-path "$sip_root" --scratch-path "$sip_scratch" -c debug
sip_binary_dir="$(swift build --package-path "$sip_root" --scratch-path "$sip_scratch" -c debug --show-bin-path)"
mkdir -p "$sip_bundle/Contents/Helpers" "$sip_bundle/Contents/MacOS" "$sip_bundle/Contents/Resources" "$sip_bundle/Contents/Frameworks"
cp "$sip_binary_dir/Sunlight" "$sip_bundle/Contents/MacOS/Sunlight"
cp "$sip_binary_dir/Sunlight" "$sip_bundle/Contents/Helpers/SunlightBankHost"
cp "$sip_root/Info.plist" "$sip_bundle/Contents/Info.plist"
cp "$sip_root/Resources/Sunlight.icns" "$sip_bundle/Contents/Resources/"
sip_sparkle="$sip_binary_dir/Sparkle.framework"
if [[ ! -d "$sip_sparkle" ]]; then
  sip_sparkle="$(/usr/bin/find "$sip_scratch/artifacts" -maxdepth 8 -type d -path '*/macos*/Sparkle.framework' -print -quit)"
fi
test -d "$sip_sparkle"
# Preserve the dependency's original signature. This development app does not
# enable hardened-runtime library validation, and never starts its updater.
ditto "$sip_sparkle" "$sip_bundle/Contents/Frameworks/Sparkle.framework"
python3 - "$sip_bundle/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info.update(CFBundleIdentifier="com.kasselvania.sunlight.virtualcanvas",
            CFBundleName="Sunlight Canvas Lab", CFBundleDisplayName="Sunlight Canvas Lab",
            CFBundleVersion="36", LSUIElement=False, SunlightSIPRedesign=True)
info.pop("NSAppleEventsUsageDescription", None)
path.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign "$SIGN" --identifier com.kasselvania.sunlight.bankhost "$sip_bundle/Contents/Helpers/SunlightBankHost"
codesign --force --sign "$SIGN" "$sip_bundle"
codesign --verify --strict --deep "$sip_bundle"
echo "Built $sip_bundle"
if [[ "${1:-}" == "--install" ]]; then
  sip_install="$HOME/Applications/Sunlight Canvas Lab.app"
  if pgrep -f '^/Users/[^/]+/Applications/Sunlight Canvas Lab.app/Contents/(MacOS|Helpers)/' >/dev/null; then
    echo "Quit Sunlight Canvas Lab before replacing its running bundle." >&2
    exit 1
  fi
  if [[ -d "$sip_install" ]]; then
    sip_existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$sip_install/Contents/Info.plist")
    [[ "$sip_existing_id" == "com.kasselvania.sunlight.virtualcanvas" ]]
    sip_backup="$(mktemp -d "$sip_output/previous.XXXXXX")"
    mv "$sip_install" "$sip_backup/SunlightCanvasLab.bundle"
  fi
  ditto "$sip_bundle" "$sip_install"
  codesign --verify --strict --deep "$sip_install"
  echo "Installed $sip_install"
fi
