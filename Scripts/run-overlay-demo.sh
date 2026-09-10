#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if pgrep -x OverlayDemo >/dev/null 2>&1; then
  echo "OverlayDemo is already running (pid $(pgrep -x OverlayDemo | tr '\n' ' ')). Stop it before rebuilding." >&2
  exit 1
fi

swift build
BIN="$(swift build --show-bin-path)"

BUILD_ID="${BUILD_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
APP_DIR="/private/tmp/smart-gaze-overlay-demo/$BUILD_ID"
APP="$APP_DIR/OverlayDemo.app"
mkdir -p "$APP/Contents/MacOS"

xcrun swiftc -parse-as-library \
  -I "$BIN/Modules" \
  -framework AppKit -framework SwiftUI \
  -o "$APP/Contents/MacOS/OverlayDemo" \
  Scripts/overlay-demo.swift \
  "$BIN"/GazeKit.build/*.o \
  "$BIN"/OverlayUI.build/*.o

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.avaxml.smartgaze.overlaydemo</string>
	<key>CFBundleName</key>
	<string>OverlayDemo</string>
	<key>CFBundleExecutable</key>
	<string>OverlayDemo</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" > /dev/null
codesign --force --sign - --timestamp=none "$APP" > /dev/null

echo "$APP"
echo "Run: open '$APP'                 # interactive: Pin/Expand/Copy/Close, Escape"
echo "Run: open '$APP' --args --auto   # pin cycle, dismiss, onDismiss count=1"
echo "Run: open '$APP' --args --stale  # dismiss then re-show, real panel visible/alpha"
echo "Run: open '$APP' --args --small-bounds # expand clamping inside caller bounds"
echo "Preview flags (in-app only, system settings untouched):"
echo "  --light --dark --reduce-transparency --increase-contrast --reduce-motion"
