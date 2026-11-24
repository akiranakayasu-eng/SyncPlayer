#!/bin/sh
# Build SyncPlayer.app (double-click to start, no Terminal needed).
# Usage: tools/make-app.sh [out-dir]   -> <out-dir>/SyncPlayer.app
set -e
OUT=${1:-build}
swift build -c release
APP="$OUT/SyncPlayer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SyncPlayer "$APP/Contents/MacOS/SyncPlayer"
VER=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SyncPlayer</string>
  <key>CFBundleIdentifier</key><string>com.nakayasu.syncplayer</string>
  <key>CFBundleExecutable</key><string>SyncPlayer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Mac 同士で再生の時刻を合わせるために、同じネットワークの Mac と通信します。</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
