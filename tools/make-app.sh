#!/bin/sh
# Build SyncPlayer.app (double-click to start, no Terminal needed).
# Usage: tools/make-app.sh [out-dir]   -> <out-dir>/SyncPlayer.app
#   UNIVERSAL=1 tools/make-app.sh dist   builds for both Apple silicon and Intel (for releases)
#   VERSION=0.2.0 sets the version shown in Finder (default 0.2)
set -e
OUT=${1:-build}
if [ -n "$UNIVERSAL" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/SyncPlayer
else
  swift build -c release
  BIN=.build/release/SyncPlayer
fi
APP="$OUT/SyncPlayer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SyncPlayer"
VER=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
SHORT=${VERSION:-0.2}
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SyncPlayer</string>
  <key>CFBundleIdentifier</key><string>com.nakayasu.syncplayer</string>
  <key>CFBundleExecutable</key><string>SyncPlayer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Mac 同士で再生の時刻を合わせるために、同じネットワークの Mac と通信します。</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
