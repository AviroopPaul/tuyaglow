#!/bin/bash
# Build TuyaGlow.app (universal: Apple Silicon + Intel).
#   ./build.sh            build build/TuyaGlow.app
#   ./build.sh --zip      also make build/TuyaGlow-macos.zip for a release
# Optional: SIGN_IDENTITY="My Cert" ./build.sh   (default: ad-hoc signature)
set -euo pipefail
cd "$(dirname "$0")"
VERSION="0.1.0"
APP=build/TuyaGlow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

BINS=()
for ARCH in ${ARCHS:-arm64 x86_64}; do
  swiftc -O -whole-module-optimization -swift-version 5 -target "$ARCH-apple-macos14.0" \
    -framework AppKit -framework SwiftUI -framework ScreenCaptureKit -framework CryptoKit \
    -framework Accelerate -framework Network \
    Sources/*.swift -o "build/obj/TuyaGlow-$ARCH"
  BINS+=("build/obj/TuyaGlow-$ARCH")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/TuyaGlow"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>site.aviroop.tuyaglow</string>
<key>CFBundleName</key><string>TuyaGlow</string>
<key>CFBundleDisplayName</key><string>TuyaGlow</string>
<key>CFBundleExecutable</key><string>TuyaGlow</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>TuyaGlow talks to your Tuya smart bulb on your Wi-Fi.</string>
<key>NSScreenCaptureUsageDescription</key><string>TuyaGlow listens to your Mac's sound and reads screen colors to drive your bulb.</string>
</dict></plist>
PL

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/TuyaGlow"))"

if [ "${1:-}" = "--zip" ]; then
  ZIP="build/TuyaGlow-macos.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Zipped $ZIP"
fi
